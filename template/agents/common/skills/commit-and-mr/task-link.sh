#!/usr/bin/env bash
#
# task-link.sh — the task block of an PR description: who wrote the branch and
# every other PR of the same task.
#
# Two modes. The default renders the block offline — stdout only, no network —
# so run.sh can create the PR with it already in the description. --update is
# the live pass, through gh: it finds the PR of every checkout of the task and
# rewrites the block in each open one, so MRs opened earlier learn about the
# ones opened after them. run.sh calls it after every PR it opens or reuses.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  task-link.sh --task <task> [--self <checkout>] [--workspace <root>]
  task-link.sh --task <task> --self <checkout> --stale-siblings
  task-link.sh --task <task> --update [--dry-run] [--quiet] [--workspace <root>]

Prints the managed task block of an PR description: who wrote the branch, and
every other PR of the same task.

  --task             the worktree task under worktrees/
  --self             the checkout whose PR is being created, as
                     worktrees/<task>/<repo> or just <repo> — it is the row
                     marked "этот PR", and the one --stale-siblings excludes
  --workspace        the workspace root (default: resolved from this script)
  --stale-siblings   instead of the block, the PR URLs the local coordination
                     record knows as open for the task, --self excluded — one
                     per line
  --update           live mode: look up every checkout's PR with gh and
                     rewrite the block in each open one. Prints LINKED= /
                     UNCHANGED= / SKIPPED= / FAILED= per checkout and TASK_*
                     totals; exits non-zero only when a lookup or write failed.
                     Without a usable gh: TASK_SKIPPED=gh-unavailable,
                     exit 0, and the recorded PR URLs to link by hand on stderr
  --dry-run          with --update: print the descriptions, write nothing
  --quiet            with --update: print only failures
EOF
}

task=""
self=""
workspace=""
mode="block"
dry_run=0
quiet=0

while (($# > 0)); do
  case "$1" in
    --task)
      task="${2:-}"
      shift 2
      ;;
    --self)
      self="${2:-}"
      shift 2
      ;;
    --workspace)
      workspace="${2:-}"
      shift 2
      ;;
    --stale-siblings)
      mode="stale"
      shift
      ;;
    --update)
      mode="update"
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --quiet)
      quiet=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$task" ]]; then
  usage >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib.sh
. "$script_dir/lib.sh"

if [[ -z "$workspace" ]]; then
  if ! workspace="$(find_real_workspace_root "$script_dir")"; then
    echo "error: no harness.json above $script_dir — not inside the workspace" >&2
    exit 1
  fi
fi

task_dir="$workspace/worktrees/$task"

if [[ ! -d "$task_dir" ]]; then
  echo "error: no such task worktree: worktrees/$task" >&2
  exit 1
fi

# --self may arrive either way round: run.sh knows the checkout relative to the
# workspace root, a human typing this by hand knows the repo directory.
self="${self#"worktrees/$task/"}"
self="${self%/}"

# base_of <repo-name> — the branch its MRs target. From the manifest, because it
# differs per repo (`development` in one, `main` in the next), or the personal
# base <owner>-<base>; `main` for a checkout the manifest does not describe.
# The shared resolver in lib.sh, so this never disagrees with run.sh.
base_of() {
  resolve_task_base "$workspace" "$1"
}

# An unusable owner is reported once, here, rather than as an empty base inside
# every `git log` range below.
workspace_owner "$workspace" >/dev/null || exit 1

# set_range <dir> <base> — the git log argument list, in RANGE_ARGS, and whether
# the branch carries work of its own, in RANGE_AHEAD.
# Falls back to the tip commit alone: once a branch is merged `origin/<base>..HEAD`
# is empty, and an empty range would report no author at all.
set_range() {
  local dir base count
  dir="$1"
  base="$2"
  RANGE_ARGS=()

  if git -C "$dir" rev-parse --verify --quiet "origin/$base" > /dev/null 2>&1; then
    RANGE_ARGS=("origin/$base..HEAD")
  elif git -C "$dir" rev-parse --verify --quiet "$base" > /dev/null 2>&1; then
    RANGE_ARGS=("$base..HEAD")
  fi

  RANGE_AHEAD=0

  if ((${#RANGE_ARGS[@]})); then
    count="$(git -C "$dir" rev-list --count "${RANGE_ARGS[0]}" 2>/dev/null || printf '0')"
    RANGE_AHEAD="$count"
    ((count > 0)) || RANGE_ARGS=(-1 HEAD)
  else
    # No base to compare against — treat the branch as carrying work rather than
    # dropping it silently.
    RANGE_AHEAD=1
    RANGE_ARGS=(-1 HEAD)
  fi
}

# uniq_lines — the lines it is given, blanks dropped, order preserved.
uniq_lines() {
  awk 'NF && !seen[$0]++'
}

# join_code — the lines it is given as `a`, `b`, `c`.
#
# Not `paste -sd ', '`: paste takes a LIST of delimiter characters and cycles
# through it, so two names come out joined by a bare comma and only a third one
# ever gets the space. awk also leaves a name containing a comma alone.
join_code() {
  awk '{ printf "%s`%s`", (NR > 1 ? ", " : ""), $0 } END { if (NR) print "" }'
}

# author_line <dir> — "**Автор:** `Name <email>` · агент: `Name`".
#
# The human comes from the commits themselves rather than from `git config`, so a
# branch two people pushed onto reports both identities. The agent comes from the
# Co-Authored-By trailer run.sh appends, which is the only record in this
# workspace of which model produced the commit.
author_line() {
  local dir humans agents line
  dir="$1"

  # --reverse so the list reads in the order the work happened; git log is
  # newest-first, and the first author of a branch is the one a reader expects
  # to see first.
  humans="$(git -C "$dir" log --reverse "${RANGE_ARGS[@]}" --pretty='%an <%ae>' 2>/dev/null | uniq_lines || true)"
  agents="$(
    git -C "$dir" log --reverse "${RANGE_ARGS[@]}" \
      --pretty='%(trailers:key=Co-Authored-By,valueonly)' 2>/dev/null \
      | sed 's/ *<[^>]*>$//' | uniq_lines || true
  )"

  if [[ -n "$humans" ]]; then
    line="**Автор:** $(printf '%s\n' "$humans" | join_code)"
  else
    line="**Автор:** _не определён из истории ветки_"
  fi

  if [[ -n "$agents" ]]; then
    line="$line · агент: $(printf '%s\n' "$agents" | join_code)"
  fi

  printf '%s\n' "$line"
}

# coord_repos — the task's `repos` map from the local coordination record, or
# `{}`.
#
# The offline source of sibling PR URLs: what earlier run.sh calls recorded
# locally. No record, no link — never an invented one. --update asks GitHub
# instead and does not read this.
coord_repos() {
  local coord raw
  coord="$workspace/.claude/skills/coordination/coord"
  [[ -x "$coord" ]] || coord="$script_dir/../coordination/coord"
  [[ -x "$coord" ]] || coord="$workspace/agents/common/skills/coordination/coord"
  [[ -x "$coord" ]] || { printf '{}\n'; return 0; }

  raw="$("$coord" status "$task" --json 2>/dev/null || true)"
  [[ -n "$raw" ]] || { printf '{}\n'; return 0; }

  printf '%s' "$raw" \
    | jq -c --arg t "$task" \
      '[.tasks[]? | select(.task == $t) | .repos // {}] | add // {}' 2>/dev/null \
    || printf '{}\n'
}

# mr_of <repos-json> <checkout-rel-from-root> lives in lib.sh, next to the
# selector it shares with every other reader of the coordination record.

# ------------------------------------------------------------------ --update
#
# Pass one collects every checkout of the task and the PR of its branch;
# nothing is written yet, because the block names all of them and cannot be
# built until the last one is known. Pass two writes the block into each open
# PR, marking the row of the PR being written.
if [[ "$mode" == "update" ]]; then
  gl_load "$workspace"

  # Access is required to refresh existing GitHub PR descriptions.
  gh_host=""
  while read -r rel; do
    [[ -n "$rel" ]] || continue
    if gh_host="$(gl_host_from_url "$(git -C "$task_dir/$rel" remote get-url origin 2>/dev/null || true)" 2>/dev/null)"; then
      break
    fi
    gh_host=""
  done < <(task_checkouts "$task_dir")

  if [[ -n "$gh_host" ]] && ! gl_require_gh "$gh_host" 2>/dev/null; then
    echo "warning: gh is not usable for $gh_host — the task block was not refreshed in any PR of $task; $(gl_gh_missing_hint "$gh_host")" >&2
    known_urls="$(coord_repos | jq -r '.[] | select((.mrState // "") | test("^(merged|closed|locked)$") | not) | .mrUrl // empty' 2>/dev/null || true)"
    if [[ -n "$known_urls" ]]; then
      echo "  link these MRs of $task to each other by hand:" >&2
      printf '%s\n' "$known_urls" | sed 's/^/    /' >&2
    fi
    printf 'TASK_SKIPPED=gh-unavailable\n'
    exit 0
  fi

  rels=()
  rows=()
  authors=()
  iids=()
  urls=()
  dirs=()
  descriptions=()
  open_count=0
  failed=0

  say() { ((quiet)) || printf '%s\n' "$1"; }

  while read -r rel; do
    [[ -n "$rel" ]] || continue

    dir="$task_dir/$rel"
    branch="$(git -C "$dir" branch --show-current 2>/dev/null || true)"

    if [[ -z "$branch" ]]; then
      say "SKIPPED=$rel detached-head"
      continue
    fi

    set_range "$dir" "$(base_of "$(basename "$rel")")"

    lookup_rc=0
    gl_mr_find "$dir" "$branch" --all || lookup_rc=$?

    if ((lookup_rc == 2)); then
      printf 'FAILED=%s lookup\n' "$rel" >&2
      failed=$((failed + 1))
      continue
    fi

    if ((lookup_rc == 1)); then
      ((RANGE_AHEAD > 0)) || continue
      rels+=("$rel")
      rows+=("$(printf '| %s | `%s` | _MR не открыт_ |' "$rel" "$branch")")
      authors+=("")
      iids+=("")
      urls+=("")
      dirs+=("")
      descriptions+=("")
      say "SKIPPED=$rel no-mr"
      continue
    fi

    rels+=("$rel")
    rows+=("$(printf '| %s | `%s` | [#%s](%s) · %s |' "$rel" "$branch" "$MR_IID" "$MR_URL" "$MR_STATE")")
    authors+=("$(author_line "$dir")")
    urls+=("$MR_URL")

    if [[ "$MR_STATE" == "opened" ]]; then
      iids+=("$MR_IID")
      dirs+=("$dir")
      descriptions+=("$MR_DESCRIPTION")
      open_count=$((open_count + 1))
    else
      iids+=("")
      dirs+=("")
      descriptions+=("")
      say "SKIPPED=$rel mr-$MR_STATE"
    fi
  done < <(task_checkouts "$task_dir")

  linked=0
  unchanged=0

  for i in "${!rels[@]}"; do
    [[ -n "${iids[$i]}" ]] || continue

    block="$(
      printf '%s\n' "$TASK_BLOCK_START"
      printf '### Задача `%s`\n\n' "$task"
      printf '%s\n' "${authors[$i]}"

      if ((${#rows[@]} > 1)); then
        printf '\nЭта задача разложена на несколько репозиториев — вот все её PR:\n\n'
        printf '| Репозиторий | Ветка | PR |\n'
        printf '| --- | --- | --- |\n'

        for j in "${!rows[@]}"; do
          if ((j == i)); then
            # Inside the last cell, not after the row: text past the closing
            # pipe is not part of the table and GitHub drops it.
            printf '%s← этот PR |\n' "${rows[$j]%|}"
          else
            printf '%s\n' "${rows[$j]}"
          fi
        done

        printf '\n_Таблицу обновляет `task-link.sh --update` при каждом PR задачи, открытом или обновлённом через commit-and-mr._\n'
      fi

      printf '%s\n' "$TASK_BLOCK_END"
    )"

    # A description this splice cannot write without eating something — two
    # live markers, or a fence hiding one — is this PR's failure, not the run's.
    if ! updated="$(splice_task_block "${descriptions[$i]}" "$block")"; then
      printf 'FAILED=%s %s ambiguous-markers\n' "${rels[$i]}" "${urls[$i]}" >&2
      failed=$((failed + 1))
      continue
    fi

    # GitHub hands descriptions back without the trailing newline the splice
    # prints, so compare without it.
    if [[ "${updated%$'\n'}" == "${descriptions[$i]%$'\n'}" ]]; then
      say "UNCHANGED=${rels[$i]} ${urls[$i]}"
      unchanged=$((unchanged + 1))
      continue
    fi

    if ((dry_run)); then
      printf 'WOULD-LINK=%s %s\n' "${rels[$i]}" "${urls[$i]}"
      printf '%s\n---\n' "$updated"
      continue
    fi

    if gl_mr_update_description "${dirs[$i]}" "${iids[$i]}" "$updated"; then
      say "LINKED=${rels[$i]} ${urls[$i]}"
      linked=$((linked + 1))
    else
      printf 'FAILED=%s %s\n' "${rels[$i]}" "${urls[$i]}" >&2
      failed=$((failed + 1))
    fi
  done

  if ((quiet == 0)); then
    printf 'TASK_MRS=%s\n' "$open_count"
    printf 'TASK_LINKED=%s\n' "$linked"
    printf 'TASK_UNCHANGED=%s\n' "$unchanged"
    printf 'TASK_FAILED=%s\n' "$failed"
  fi

  ((failed == 0))
  exit
fi

repos_json="$(coord_repos)"

rels=()
rows=()
self_index=-1
stale=()

while read -r rel; do
  [[ -n "$rel" ]] || continue

  dir="$task_dir/$rel"
  branch="$(git -C "$dir" branch --show-current 2>/dev/null || true)"

  # Detached HEAD has no branch, so it has no PR to name.
  [[ -n "$branch" ]] || continue

  set_range "$dir" "$(base_of "$(basename "$rel")")"

  IFS=$'\t' read -r mr_url mr_state < <(mr_of "$repos_json" "worktrees/$task/$rel")

  if [[ "$rel" == "$self" ]]; then
    self_index="${#rels[@]}"
    rels+=("$rel")
    # No link: this PR does not exist yet — gh creates it with this very text.
    # Naming it anything else would be a guessed URL; --update links it later.
    rows+=("$(printf '| %s | `%s` | _этот MR_ |' "$rel" "$branch")")
    continue
  fi

  if [[ -n "$mr_url" ]]; then
    rels+=("$rel")
    rows+=("$(printf '| %s | `%s` | [#%s](%s) · %s |' \
      "$rel" "$branch" "${mr_url##*/}" "$mr_url" "${mr_state:-?}")")

    # An PR the local record knows as open: --stale-siblings lists these.
    case "$mr_state" in
      merged|closed|locked) ;;
      *) stale+=("$mr_url") ;;
    esac
    continue
  fi

  # A checkout with nothing of its own on the branch is one `wt new` added from
  # the manifest's `always` list and the task never touched. Listing it as a
  # missing PR would promise a review that is not coming.
  ((RANGE_AHEAD > 0)) || continue

  rels+=("$rel")
  rows+=("$(printf '| %s | `%s` | _MR не открыт_ |' "$rel" "$branch")")
done < <(task_checkouts "$task_dir")

if [[ "$mode" == "stale" ]]; then
  ((${#stale[@]} == 0)) || printf '%s\n' "${stale[@]}"
  exit 0
fi

# The author line describes the branch this PR is for. Without --self there is
# no such branch, so the block degrades to the table alone rather than naming
# some other checkout's author.
author=""
if ((self_index >= 0)); then
  set_range "$task_dir/$self" "$(base_of "$(basename "$self")")"
  author="$(author_line "$task_dir/$self")"
fi

printf '%s\n' "$TASK_BLOCK_START"
printf '### Задача `%s`\n' "$task"

if [[ -n "$author" ]]; then
  printf '\n%s\n' "$author"
fi

# A single-row table is noise: it says "this PR is this PR". The table earns its
# place only when the task really is spread over several checkouts.
if ((${#rows[@]} > 1)); then
  printf '\nЭта задача разложена на несколько репозиториев — вот все её PR:\n\n'
  printf '| Репозиторий | Ветка | PR |\n'
  printf '| --- | --- | --- |\n'
  printf '%s\n' "${rows[@]}"
  # Said in the block itself: if the --update pass after creation fails, the
  # reader of this PR is the one who would otherwise assume the table is live.
  printf '\n_Таблица собрана офлайн перед созданием этого PR; `task-link.sh --update` заменяет её живыми ссылками._\n'
fi

printf '%s\n' "$TASK_BLOCK_END"
