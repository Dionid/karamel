#!/usr/bin/env bash
# Snapshot the team's Notion into markdown files in a team repository.
#
#   run.sh [--root <name>]... [--all] [--depth N|max] [--no-dbs] [--no-links]
#          [--dry-run] [--keep <dir>] [--branch <name>] [--title <mr-title>]
#
# Walks every configured Notion root with the core `notion` skill, writes the
# pages under <dir>/<root>/ of the target repository, and pushes a fixed branch
# over HTTPS with the gh credential helper. The first push of the branch is
# followed by `gh mr create --draft`; later pushes update that same MR.
#
# The target repository, directory and branch are configuration, not
# hardcoded:
#
#   NOTION_SNAPSHOT_PROJECT   "group/path" or full git/https URL of the repo to
#                             snapshot into. Unset: repos.json notionSnapshotRepo;
#                             without it, legacy always discovery.
#                             It is NOT this workspace's own origin:
#                             guessing the target would push the mirror into
#                             whatever repo the run happened to start in, and an
#                             unresolvable target is a refusal before any write.
#   NOTION_SNAPSHOT_DIR       directory inside that repo. Default:
#                             knowledge/references
#   NOTION_SNAPSHOT_BRANCH    the fixed branch this snapshot accumulates on.
#                             Default: notion/snapshot
#   NOTION_SNAPSHOT_GIT_EMAIL committer email in the temporary checkout. The
#                             target project's push rules decide which addresses
#                             are accepted; the built-in default is a local
#                             placeholder and a project with an email push rule
#                             will reject it.
#
# The snapshot REPLACES the tree it covers: a page deleted or renamed in Notion
# disappears from the commit, which is the whole point of a snapshot and the
# reason each root's directory is cleared before it is rewritten. Only the
# roots actually walked in this run are touched.
#
# GitHub uses the shared GITHUB_TOKEN loader; notion.sh reads NOTION_TOKEN.
# No credential value is printed.
# The repo is cloned into a temporary directory removed on exit.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run.sh [--root <name>]... [--all] [--depth N|max] [--no-dbs] [--no-links]
         [--allow-partial] [--dry-run] [--no-push] [--keep <dir>]
         [--branch <name>] [--title <mr-title>]

  --root     one configured Notion root (repeatable; default: every root)
  --all      every root in notion.json — the default, spelled out
  --depth    override the walk depth for every root walked (default: each
             root's own maxDepth from the manifest)
  --no-dbs   do NOT descend into database rows; they are walked by default,
             which is what makes a root that is little more than one inline
             database come out as its rows rather than as a single line
  --no-links do NOT follow Notion links found in page text; they are followed
             by default, so a page is reached through whatever points at it and
             not only through the parent that owns it
  --link-depth N
             how many link hops past the tree to follow (default 2)
  --cache DIR
             keep each page's markdown beside its last_edited_time, so the
             next run re-fetches only what changed
  --resume   continue an interrupted walk from --cache instead of starting the
             root over; cached pages cost nothing. Needs --cache
  --max-pages N
             stop after N pages per root and refuse to commit that run,
             because a walk cut short is indistinguishable from pages deleted
             in Notion (default 2000; 0 = no budget)
  --allow-partial
             commit a walk that could not read part of the tree; without it
             such a run refuses, because the pages it failed to read would be
             committed as deletions
  --dry-run  walk Notion and report what the commit would change, write nothing
  --no-push  walk Notion and stop at the dump — no clone and no MR;
             this is the mode for someone without MR rights in the target repo
  --keep DIR keep the raw dump in DIR instead of a temporary directory
  --branch   override the fixed branch this run accumulates on (env
             NOTION_SNAPSHOT_BRANCH, default notion/snapshot)
  --title    MR title of a newly opened review

One run is one request per Notion page at ~3/s, so a full snapshot takes
minutes, not seconds.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

# Корень воркспейса держат generated-маркер `harness.json` и tracked-манифест
# `workspace.json`, доступный также в свежем клоне и CI.
find_workspace_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/harness.json" || -f "$dir/workspace.json" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

SKILL_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(find_workspace_root)" || die "no harness.json above this skill"

# A sibling skill: the built tree first, the layer it is built FROM as a
# `agents/common/` — but only the layer is in a fresh clone, and building the
# tree needs the engine clone, which a product repository's pipeline has no way
# CI at all, and the gate silently covers less than it claims to.
resolve_skill_path() {
  local rel="$1" candidate
  for candidate in "$SKILL_DIR/../$rel" "$WORKSPACE_ROOT/.claude/skills/$rel" \
                   "$WORKSPACE_ROOT/agents/common/skills/$rel"; do
    [[ -e "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

CORE_LIB="$(resolve_skill_path commit-and-mr/lib.sh)" \
  || die "commit-and-mr/lib.sh is missing in both .claude/ and agents/ — run: ./ops sync"
# shellcheck source=/dev/null
. "$CORE_LIB"

# Load the workspace .env (including GitHub configuration) BEFORE reading
# a single NOTION_SNAPSHOT_* variable below. Those variables may live only in
# .env, never in this process's own environment — reading them first would
# silently fall back to this workspace's own defaults (its own origin, its own
# base branch) instead of the configured target, and nothing would say so.
gl_load "$WORKSPACE_ROOT"
WORKSPACE_ROOT="$GL_WORKSPACE_ROOT"

SNAPSHOT_DIR="${NOTION_SNAPSHOT_DIR:-knowledge/references}"
DEFAULT_BRANCH="${NOTION_SNAPSHOT_BRANCH:-notion/snapshot}"
# Named once, so the precondition that refuses it and the config that would set
# it cannot drift apart.
PLACEHOLDER_GIT_EMAIL="notion-snapshot@localhost"

notion_sh() {
  local script
  script="$(resolve_skill_path notion/notion.sh)" \
    || die "the notion skill is missing in both .claude/ and agents/ — run: ./ops sync"
  [[ -x "$script" ]] || die "the notion skill at $script is not executable"
  "$script" "$@"
}

# Which roots notion.json declares, in manifest order.
configured_roots() {
  local manifest name
  manifest="$WORKSPACE_ROOT/notion.json"
  [[ -f "$manifest" ]] || die "no Notion manifest at $manifest — nothing to snapshot"
  while IFS= read -r name; do
    # A root name becomes a path component under $SNAPSHOT_DIR/, and the
    # directory it names is deleted before being rewritten. `..` or a slash in
    # it would send that delete somewhere else in the repo.
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$name" != "." && "$name" != ".." ]] \
      || die "root name '$name' in notion.json is not usable as a directory name"
    printf '%s\n' "$name"
  done < <(jq -r '.roots | keys_unsorted[]' "$manifest")
}

# Legacy snapshot discovery, only when notionSnapshotRepo is absent.
#
# Compatibility with the original knowledge/ convention: a
# candidate is an `always` entry whose checkout actually holds `knowledge/`, or
# whose `specRoot` in the manifest points inside `knowledge/`. The second half
# matters because `packages/` is empty in a fresh clone and in CI, and "not
# checked out" is not "has no knowledge".
#
# Prints one `<name>\t<url>` line per candidate, so the caller can refuse on
# zero and on more than one rather than picking silently.
knowledge_repo_candidates() {
  local manifest="$WORKSPACE_ROOT/repos.json" line rest name specroot url
  [[ -f "$manifest" ]] || return 1
  # Split by hand rather than with `IFS=$'\t' read -r name specroot url`: tab is
  # an IFS *whitespace* character, so bash collapses a run of them into one
  # delimiter, and an entry without a specRoot would silently hand its url to
  # the wrong variable.
  while IFS= read -r line; do
    name="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    specroot="${rest%%$'\t'*}"
    url="${rest#*$'\t'}"
    [[ -n "$name" ]] || continue
    if [[ -d "$WORKSPACE_ROOT/packages/$name/knowledge" ]] \
      || [[ "$specroot" == "knowledge" || "$specroot" == knowledge/* ]]; then
      printf '%s\t%s\n' "$name" "$url"
    fi
  done < <(jq -r '
    (.always // [])[] as $n
    | [$n, (.repos[$n].specRoot // ""), (.repos[$n].url // "")] | @tsv
  ' "$manifest")
}

# The snapshot repository this manifest names, as "<name>\t<url>".
#
# On failure it prints a one-line reason on STDOUT and returns 1, so both
# callers can phrase their own error around it: an unset NOTION_SNAPSHOT_PROJECT
# has to refuse, while an explicit one only loses the cross-check.
manifest_target() {
  local manifest="$WORKSPACE_ROOT/repos.json" candidates names url

  if [[ ! -f "$manifest" ]]; then
    printf 'there is no %s to resolve the knowledge repository from\n' "$manifest"
    return 1
  fi
  if jq -e 'has("notionSnapshotRepo")' "$manifest" >/dev/null 2>&1; then
    names="$(jq -r '.notionSnapshotRepo | select(type == "string")' "$manifest")"
    [[ "$names" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
      printf 'invalid notionSnapshotRepo in %s\n' "$manifest"
      return 1
    }
    url="$(jq -r --arg n "$names" '.repos[$n].url // empty' "$manifest")"
    [[ -n "$url" ]] || {
      printf 'notionSnapshotRepo %s has no repository url in %s\n' "$names" "$manifest"
      return 1
    }
    printf '%s\t%s\n' "$names" "$url"
    return 0
  fi
  if ! candidates="$(knowledge_repo_candidates)"; then
    printf '%s could not be read\n' "$manifest"
    return 1
  fi
  if [[ -z "$candidates" ]]; then
    printf "no 'always' repository in %s holds knowledge/ (looked for packages/<repo>/knowledge and for a specRoot under knowledge/)\n" "$manifest"
    return 1
  fi

  names="$(cut -f1 <<<"$candidates" | paste -sd, -)"
  if [[ "$(wc -l <<<"$candidates")" -ne 1 ]]; then
    printf '%s names more than one knowledge repository (%s)\n' "$manifest" "$names"
    return 1
  fi

  url="$(cut -f2 <<<"$candidates")"
  if [[ -z "$url" ]]; then
    printf "the knowledge repository '%s' has no url in %s\n" "$names" "$manifest"
    return 1
  fi

  printf '%s\t%s\n' "$names" "$url"
}

# Check the destination in the cloned repository before replacing a mirror.
validate_snapshot_path() {
  python3 - "$1" "$2" <<'PYSAFE'
from pathlib import Path
import sys
checkout = Path(sys.argv[1]).resolve()
target = (checkout / sys.argv[2]).resolve()
if not target.is_relative_to(checkout):
    sys.exit("NOTION_SNAPSHOT_DIR escapes snapshot checkout")
PYSAFE
}

# host/path of a project url, for comparison only. A subshell on purpose:
# proj_from_url publishes PROJ_HOST/PROJ_PATH, and main reads those for the real
# target a few lines later — comparing must not overwrite them.
project_identity() (
  proj_from_url "$1" >/dev/null 2>&1 || return 1
  printf '%s/%s\n' "$PROJ_HOST" "$PROJ_PATH"
)

# The target comes from the manifest or a deliberate override. Never infer the
# publication repository from this workspace's own origin: knowledge may live
# in a separate repository, and silently pushing there would misplace the dump.
# An explicit override is cross-checked against the manifest for the same
# reason, and that is not belt-and-braces: the value that was correct before
# knowledge/ moved out still resolves, still clones and still pushes, so a stale
# .env is indistinguishable from a configured one until the mirror lands in the
# wrong repository. The manifest is resolved even when an override is set so
# there is something to check it against; when the manifest cannot name a single
# knowledge repository there is nothing to compare, and the override stands
# alone — which is exactly the case an override exists for.
# NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT=yes is the deliberate way out.
target_project_url() {
  local resolved reason="" resolved_name="" resolved_url=""
  # Explicit null is a workspace publication opt-out; env cannot re-enable it.
  if [[ -f "$WORKSPACE_ROOT/repos.json" ]] && jq -e \
    'has("notionSnapshotRepo") and .notionSnapshotRepo == null' \
    "$WORKSPACE_ROOT/repos.json" >/dev/null 2>&1; then
    die "snapshot publishing is disabled by notionSnapshotRepo=null in $WORKSPACE_ROOT/repos.json — use notion for reading or --no-push for a local dump"
  fi
  case "$SNAPSHOT_DIR" in
    knowledge/references | knowledge/references/*) ;;
    *) die "NOTION_SNAPSHOT_DIR must stay under knowledge/references" ;;
  esac
  case "/$SNAPSHOT_DIR/" in
    */../* | */./* | *\\*) die "unsafe NOTION_SNAPSHOT_DIR" ;;
  esac
  if resolved="$(manifest_target)"; then
    resolved_name="${resolved%%$'\t'*}"
    resolved_url="${resolved#*$'\t'}"
  else
    reason="$resolved"
    if [[ -f "$WORKSPACE_ROOT/repos.json" ]] && jq -e 'has("notionSnapshotRepo")' "$WORKSPACE_ROOT/repos.json" >/dev/null 2>&1; then
      die "NOTION_SNAPSHOT_PROJECT cannot bypass invalid notionSnapshotRepo: $reason"
    fi
  fi

  if [[ -n "${NOTION_SNAPSHOT_PROJECT-}" ]]; then
    local override_url want got
    case "$NOTION_SNAPSHOT_PROJECT" in
      *://* | *:*) override_url="$NOTION_SNAPSHOT_PROJECT" ;;
      # A bare "group/path" lives on the default instance.
      *) override_url="https://github.com/${NOTION_SNAPSHOT_PROJECT#/}.git" ;;
    esac

    if [[ -n "$resolved_url" && "${NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT-}" != "yes" ]]; then
      want="$(project_identity "$resolved_url")" || want=""
      got="$(project_identity "$override_url")" || got=""
      [[ -n "$got" && "$got" == "$want" ]] \
        || die "NOTION_SNAPSHOT_PROJECT='$NOTION_SNAPSHOT_PROJECT' is not the snapshot repository $resolved_name ($resolved_url) that $WORKSPACE_ROOT/repos.json names — refusing before the Notion walk, because a snapshot pushed to the wrong project looks like an ordinary Draft MR; fix NOTION_SNAPSHOT_PROJECT, or set NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT=yes if this target is deliberate"
    fi

    printf '%s\n' "$override_url"
    return 0
  fi

  [[ -n "$resolved_url" ]] \
    || die "NOTION_SNAPSHOT_PROJECT is not set and $reason — set NOTION_SNAPSHOT_PROJECT to the project that owns $SNAPSHOT_DIR"

  printf 'RESOLVED_TARGET_FROM=repos.json snapshot entry %s\n' "$resolved_name" >&2
  printf '%s\n' "$resolved_url"
}

# The committer identity is a write-path precondition too, and it is checked
# here — next to the project resolution, before the Notion walk — for exactly
# the reason the resolution moved here: push rules on the target project reject
# the push at the very end, and that throws away every minute the walk cost.
#
# run.sh deliberately does NOT enforce a domain allowlist. Which addresses a
# project accepts is that project's push rule, and this is the shared layer;
# SKILL.md and env.example carry this team's list. Only the two cases that are
# wrong under any push rule are refused here: unset, and the built-in
# placeholder, which no rule that bothers to check an address will accept.
require_committer_identity() {
  local email="${NOTION_SNAPSHOT_GIT_EMAIL-}"

  [[ -n "$email" ]] \
    || die "NOTION_SNAPSHOT_GIT_EMAIL is not set — the target project's push rules check the committer address, and a rejected push discards the whole Notion walk; set it in .env (SKILL.md lists the addresses this team's projects accept)"

  [[ "$email" != "$PLACEHOLDER_GIT_EMAIL" ]] \
    || die "NOTION_SNAPSHOT_GIT_EMAIL is still the built-in placeholder $PLACEHOLDER_GIT_EMAIL, which push rules that check the address will reject — set a real committer address in .env (SKILL.md lists the addresses this team's projects accept)"
}

# Is this walk safe to commit as a snapshot? Pure, because the failure it
# guards is invisible afterwards: `dump` exits 0 whether it read the tree or
# gave up on it (retries exhausted, integration disconnected, 429s), and a walk
# that read nothing produces the same files as a Notion root that was emptied.
# Committed, that second reading deletes the snapshot — so the answer is
# computed from the walk's own report, before anything is deleted.
#
#   $1  the walk's PAGES value, possibly empty
#   $2  the rest of the walk's output (SKIPPED_PAGES=yes shows up here)
#   $3  did the caller pass --allow-partial: yes | no
#
# prints: ok | partial | refuse:empty | refuse:partial | refuse:budget
walk_verdict() {
  local pages="$1" walked="$2" partial="$3"

  if [[ -z "$pages" || "$pages" == "0" ]]; then
    printf 'refuse:empty\n'
    return 0
  fi
  if grep -q '^BUDGET_EXHAUSTED=yes' <<<"$walked"; then
    # The walk stopped early, so the pages it never reached look exactly like
    # pages deleted in Notion — and this script replaces the tree it covers.
    # --allow-partial does not cover this: that flag is for a known hole the
    # caller has looked at, and a budget cut is an unknown one.
    printf 'refuse:budget\n'
    return 0
  fi
  if grep -q '^SKIPPED_PAGES=yes' <<<"$walked"; then
    # The pages below a skipped one were never read, so committing this walk
    # deletes exactly the part that failed. Someone has to say that is fine.
    [[ "$partial" == "yes" ]] && { printf 'partial\n'; return 0; }
    printf 'refuse:partial\n'
    return 0
  fi
  printf 'ok\n'
}

# The TRUNCATED_PAGES block of a walk summary as a nested markdown list:
#   Title (<uuid>) — unreadable blocks: N
# becomes
#   - [Title](https://app.notion.com/p/<hex>) — нечитаемых блоков: N
truncated_pages_md() {  # truncated_pages_md <walk-summary>
  sed -n '/^TRUNCATED_PAGES=yes$/,/^(/p' <<<"$1" \
    | sed -E -n 's/^(.*) \(([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})\) — unreadable blocks: (.*)$/  - [\1](https:\/\/app.notion.com\/p\/\2\3\4\5\6) — нечитаемых блоков: \7/p'
}

# The README of the snapshot tree, rewritten whole every run: what is in here,
# where it came from, and the fact that editing it changes nothing in Notion.
write_readme() {  # <file> <date> <roots...>
  local file="$1" today="$2"
  shift 2
  {
    printf '# Слепок Notion\n\n'
    printf 'Выгрузка страниц Notion в markdown, снятая скиллом `notion-snapshot`\n'
    printf 'из корней, объявленных в `notion.json`. Снято: %s.\n\n' "$today"
    printf '| Корень | Каталог | Карта |\n| --- | --- | --- |\n'
    local r
    for r in "$@"; do
      printf '| `%s` | [`%s/%s/`](%s/) | [`INDEX.md`](%s/INDEX.md) |\n' \
        "$r" "$SNAPSHOT_DIR" "$r" "$r" "$r"
    done
    printf '\n**Это копия, а не источник.** Правка файла здесь не меняет страницу\n'
    printf 'в Notion; каждый следующий прогон перезаписывает каталог корня целиком,\n'
    printf 'поэтому правка потеряется. Менять надо страницу в Notion — её адрес\n'
    printf 'стоит в `url` фронтматтера каждого файла.\n'
  } > "$file"
}

SCRATCH_DIRS=()
cleanup() {
  local d
  for d in ${SCRATCH_DIRS[@]+"${SCRATCH_DIRS[@]}"}; do
    [[ -z "$d" ]] || rm -rf "$d"
  done
}

main() {
  local -a roots=() dump_flags=()
  local depth="" dbs="" links="" link_depth="" max_pages="" cache="" resume="no"
  local dry="no" keep="" branch="$DEFAULT_BRANCH" title=""
  local partial="no" push="yes"

  while (($# > 0)); do
    case "$1" in
      --root)    [[ -n "${2:-}" ]] || die "--root needs a name"; roots+=("$2"); shift 2 ;;
      --all)     roots=(); shift ;;
      --depth)   [[ -n "${2:-}" ]] || die "--depth needs a value"; depth="$2"; shift 2 ;;
      --dbs)     dbs="yes"; shift ;;
      --no-dbs)  dbs="no"; shift ;;
      --links)   links="yes"; shift ;;
      --no-links) links="no"; shift ;;
      --link-depth) [[ -n "${2:-}" ]] || die "--link-depth needs a number"; link_depth="$2"; shift 2 ;;
      --max-pages)  [[ -n "${2:-}" ]] || die "--max-pages needs a number"; max_pages="$2"; shift 2 ;;
      --cache)      [[ -n "${2:-}" ]] || die "--cache needs a directory"; cache="$2"; shift 2 ;;
      --resume)     resume="yes"; shift ;;
      --allow-partial) partial="yes"; shift ;;
      --dry-run) dry="yes"; shift ;;
      --no-push) push="no"; shift ;;
      --keep)    [[ -n "${2:-}" ]] || die "--keep needs a directory"; keep="$2"; shift 2 ;;
      --branch)  [[ -n "${2:-}" ]] || die "--branch needs a name"; branch="$2"; shift 2 ;;
      --title)   [[ -n "${2:-}" ]] || die "--title needs a value"; title="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *)         usage >&2; exit 1 ;;
    esac
  done

  # Not `mapfile`: absent on the bash 3.2 that ships as /bin/bash on macOS, and
  # this skill has to run there without a newer bash first in PATH.
  local -a all_roots=()
  local __root_line
  while IFS= read -r __root_line; do
    all_roots+=("$__root_line")
  done < <(configured_roots)
  ((${#all_roots[@]} > 0)) || die "notion.json declares no roots"

  if ((${#roots[@]} == 0)); then
    roots=("${all_roots[@]}")
  else
    local r known
    for r in "${roots[@]}"; do
      known="no"
      local k
      for k in "${all_roots[@]}"; do [[ "$k" == "$r" ]] && known="yes"; done
      [[ "$known" == "yes" ]] \
        || die "root '$r' is not in notion.json (have: ${all_roots[*]})"
    done
  fi

  # Both walks are deep by default in the `notion` skill now, so only an
  # explicit choice is forwarded: an unset flag leaves the decision to that
  # skill and to the root's own manifest entry.
  [[ -z "$depth" ]] || dump_flags+=(--depth "$depth")
  case "$dbs" in yes) dump_flags+=(--dbs) ;; no) dump_flags+=(--no-dbs) ;; esac
  case "$links" in yes) dump_flags+=(--links) ;; no) dump_flags+=(--no-links) ;; esac
  [[ -z "$link_depth" ]] || dump_flags+=(--link-depth "$link_depth")
  [[ -z "$max_pages" ]] || dump_flags+=(--max-pages "$max_pages")
  # A root too large to walk in one sitting is finished across several runs:
  # the cache carries what is already read, --resume replays it for free.
  [[ -z "$cache" ]] || dump_flags+=(--cache "$cache")
  [[ "$resume" == "no" ]] || dump_flags+=(--resume)

  # Resolve the target and its default branch before the Notion walk: an
  # unreachable project or a missing gh login must not cost the minutes of a
  # full snapshot.
  local project_url=""
  if [[ "$push" == "yes" ]]; then
    project_url="$(target_project_url)"
    require_committer_identity
    proj_from_url "$project_url" >/dev/null || die "cannot parse a project from '$project_url'"
    # Verify token-backed GitHub access before the expensive Notion walk.
    gl_require_gh "$PROJ_HOST" || die "GitHub unavailable — use --no-push --keep <dir> for a local snapshot"

    # Into a file, not $(…): GL_TRANSPORT names the transport the call took.
    local symref ls_log
    ls_log="$(mktemp)"
    gl_git_url "$project_url" ls-remote --symref "$project_url" HEAD > "$ls_log" 2>/dev/null || true
    symref="$(sed -n 's#^ref: refs/heads/\(.*\)\tHEAD$#\1#p' "$ls_log")"
    rm -f "$ls_log"
    [[ -n "$symref" ]] \
      || die "git ls-remote --symref $project_url не назвал ветку по умолчанию — нечего задать как TARGET_BRANCH"
    TARGET_BRANCH="$symref"

    printf 'TARGET_PROJECT=%s\nTARGET_BRANCH=%s\nTRANSPORT=%s\n' \
      "$PROJ_PATH" "$TARGET_BRANCH" "${GL_TRANSPORT:-none}" >&2
  fi
  trap cleanup EXIT

  local today dump_root
  today="$(date +%F)"
  if [[ -n "$keep" ]]; then
    mkdir -p "$keep"
    dump_root="$keep"
  else
    dump_root="$(mktemp -d)"
    SCRATCH_DIRS+=("$dump_root")
  fi

  # --- the walk ------------------------------------------------------------
  local r out pages="" summary="" from_cache=""
  for r in "${roots[@]}"; do
    out="$dump_root/$r"
    # `dump` only creates and adds, so a directory left over from an earlier run
    # would survive into the copy below. The snapshot is a replacement, so the
    # dump it is made from starts empty.
    rm -rf "${out:?}"
    echo "== walking Notion root '$r'" >&2
    local walked
    walked="$(notion_sh dump "$r" --layout nested --out "$out" \
      ${dump_flags[@]+"${dump_flags[@]}"})" \
      || die "notion dump failed for root '$r'"
    printf '%s\n' "$walked" >&2
    pages="$(sed -n 's/^PAGES=//p' <<<"$walked" | tail -n 1)"

    local verdict
    verdict="$(walk_verdict "$pages" "$walked" "$partial")"
    case "$verdict" in
      refuse:empty)
        die "обход корня '$r' не прочитал ни одной страницы (PAGES=${pages:-?}) — это выглядело бы как удаление всего слепка, поэтому ничего не пишу. Проверьте NOTION_TOKEN, доступ интеграции к странице и лимиты Notion" ;;
      refuse:partial)
        die "в корне '$r' часть поддерева не прочиталась (SKIPPED_PAGES) — эти страницы уехали бы в коммит как удалённые. Почините доступ интеграции или запустите с --allow-partial, если так и надо" ;;
      refuse:budget)
        die "обход корня '$r' упёрся в бюджет страниц (BUDGET_EXHAUSTED) и не дошёл до конца — непрочитанное уехало бы в коммит как удалённое. Поднимите --max-pages, либо сузьте обход: --depth, --link-depth, --no-links" ;;
    esac

    summary+="- \`$r\`: ${pages} страниц"
    # A resumed run has to say so in the artefact, not only in the docs. Every
    # other kind of incomplete walk either refuses or is acknowledged by a
    # human; --resume is the one where the page count is full, the tree is
    # whole, and the bodies are of unknown age. Unlabelled it reads in the MR
    # exactly like a snapshot taken today — which is how a month-old copy would
    # ship under today's date with an empty diff.
    if [[ "$resume" == "yes" ]]; then
      from_cache="$(sed -n 's/^FROM_CACHE=//p' <<<"$walked" | tail -n 1)"
      summary+=", из них ${from_cache:-?} из кэша (--resume: тела страниц не перепроверялись)"
    fi
    [[ "$verdict" != "partial" ]] \
      || summary+=", часть поддерева не прочиталась (SKIPPED_PAGES, принято --allow-partial)"
    if grep -q '^UNREACHABLE_LINKS=yes' <<<"$walked"; then
      # Not a hole in the snapshot — pages this tree points at and the
      # integration cannot open. Said out loud so the page count is not read as
      # "everything linked from here is in here".
      summary+=", часть ссылок ведёт в недоступные интеграции страницы (UNREACHABLE_LINKS)"
    fi
    if grep -q '^TRUNCATED_PAGES=yes' <<<"$walked"; then
      summary+=", есть обрезанные страницы (TRUNCATED_PAGES):"$'\n'
      # The pages themselves, not just the flag: a reviewer of the MR has to be
      # able to open exactly the ones whose copy is missing blocks.
      summary+="$(truncated_pages_md "$walked")"
    fi
    summary+=$'\n'
  done

  # --- the dump, and nothing else ------------------------------------------
  if [[ "$push" == "no" ]]; then
    [[ -n "$keep" ]] || echo "note: --no-push without --keep leaves the dump in a temporary directory" >&2
    printf 'SNAPSHOT_STATE=dump-only\nDUMP_DIR=%s\n%s' "$dump_root" "$summary"
    # Keep it: the whole point of this mode is that the caller reads the files.
    SCRATCH_DIRS=()
    return 0
  fi

  # --- the repository ------------------------------------------------------
  local work
  work="$(mktemp -d)"
  SCRATCH_DIRS+=("$work")

  gl_clone "$project_url" "$work" --quiet || die "clone failed — нет доступа к $PROJ_PATH этим кредом"
  git -C "$work" config user.name "${NOTION_SNAPSHOT_GIT_NAME:-notion-snapshot}"
  # No default: this path is push-only, and require_committer_identity refused
  # both the unset and the placeholder address before the walk even started.
  git -C "$work" config user.email "$NOTION_SNAPSHOT_GIT_EMAIL"

  local exists="no"
  if gl_git "$work" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    exists="yes"
    gl_fetch "$work" "$branch" >/dev/null
  fi
  if [[ "$exists" == "yes" ]]; then
    git -C "$work" checkout --quiet -B "$branch" FETCH_HEAD
  else
    git -C "$work" checkout --quiet -B "$branch" "origin/$TARGET_BRANCH"
  fi

  # Replace, don't merge: a page gone from Notion has to be gone from here.
  # The `:?` guards are not ceremony — an empty root name would turn this into
  # `rm -rf` of the whole snapshot tree, which the diff would then present as a
  # deliberate deletion of every page.
  for r in "${roots[@]}"; do
    validate_snapshot_path "$work" "$SNAPSHOT_DIR/$r" \
      || die "NOTION_SNAPSHOT_DIR escapes snapshot checkout"
    rm -rf "${work:?}/${SNAPSHOT_DIR:?}/${r:?}"
    mkdir -p "$work/$SNAPSHOT_DIR"
    cp -R "$dump_root/$r" "$work/$SNAPSHOT_DIR/$r"
  done
  # Every root the tree holds, not only the ones walked now: a run with --root
  # leaves the others in place, and the README has to keep naming them. Only
  # roots notion.json declares, though: the same directory also holds material
  # nobody snapshotted (hand-written references, a root since dropped from the
  # manifest), and listing it here would call it a Notion copy and link an
  # INDEX.md it does not have.
  local -a present=()
  local one name k
  for one in "$work/$SNAPSHOT_DIR"/*/; do
    one="${one%/}"
    [[ -d "$one" ]] || continue
    name="${one##*/}"
    for k in "${all_roots[@]}"; do
      if [[ "$k" == "$name" ]]; then present+=("$name"); break; fi
    done
  done
  write_readme "$work/$SNAPSHOT_DIR/README.md" "$today" ${present[@]+"${present[@]}"}

  git -C "$work" add -A "$SNAPSHOT_DIR"
  if git -C "$work" diff --cached --quiet; then
    local unchanged_state="none" unchanged_url=""
    if [[ "$exists" == "yes" ]]; then
      if gl_mr_find "$work" "$branch"; then
        unchanged_state="existing"
        unchanged_url="$MR_URL"
      elif (($? == 2)); then
        unchanged_state="unknown"
      fi
    fi
    printf 'SNAPSHOT_STATE=unchanged\nBRANCH=%s\nCHANGED_FILES=0\nMR_STATE=%s\nMR_URL=%s\n%s' \
      "$branch" "$unchanged_state" "$unchanged_url" "$summary"
    return 0
  fi

  local stat
  stat="$(git -C "$work" diff --cached --shortstat)"
  local changed
  changed="$(git -C "$work" diff --cached --name-only | wc -l | tr -d ' ')"

  if [[ "$dry" == "yes" ]]; then
    printf 'SNAPSHOT_STATE=dry-run\nBRANCH=%s\nCHANGED_FILES=%s\nDIFF=%s\n%s' \
      "$branch" "$changed" "$stat" "$summary"
    git -C "$work" diff --cached --name-status | head -60
    return 0
  fi

  git -C "$work" -c commit.gpgsign=false commit --quiet \
    -m "$(printf 'notion: слепок %s\n\nКорни: %s\n%s' "$today" "${roots[*]}" "$stat")"

  local mr_title="${title:-notion: слепок базы знаний}" mr_desc push_output mr_url mr_state
  mr_desc="$(printf 'Слепок Notion, снятый скиллом `notion-snapshot`.\n\nПоследний прогон: %s\n\n%s\nИзменения в этом прогоне: %s\n\nЭто копия, а не источник: правки здесь не уезжают в Notion, и следующий прогон перезаписывает каталог корня целиком.\n' \
    "$today" "$summary" "$stat")"
  if ! push_output="$(gl_push "$work" "$branch")"; then
    printf '%s\n' "$push_output" >&2
    die "push of $branch failed — the commit is made, nothing is pushed"
  fi
  printf '%s\n' "$push_output" >&2

  # The fixed branch has at most one open MR. Found: the push already updated
  # it. Not found: open it now. gh could not tell (2): do not open a second
  # one on a guess.
  mr_url=""
  local find_rc=0
  gl_mr_find "$work" "$branch" || find_rc=$?
  if ((find_rc == 0)); then
    mr_state="existing"
    mr_url="$MR_URL"
  elif ((find_rc == 1)); then
    if gl_mr_create "$work" "$branch" "$TARGET_BRANCH" "Draft: $mr_title" "$mr_desc"; then
      mr_state="created"
      mr_url="$MR_URL"
    else
      mr_state="create-failed"
    fi
  else
    mr_state="unknown"
  fi

  printf 'SNAPSHOT_STATE=committed\nCOMMIT_SHA=%s\nCHANGED_FILES=%s\nDIFF=%s\n%s' \
    "$(git -C "$work" rev-parse --short HEAD)" "$changed" "$stat" "$summary"
  printf 'MR_STATE=%s\nMR_URL=%s\nBRANCH=%s\nMR_TRANSPORT=https-gh\n' "$mr_state" "$mr_url" "$branch"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
