#!/usr/bin/env bash
# The write-path preconditions of a snapshot run: where it would push, and who
# it would push as. Both are checked before the Notion walk, so a wrong answer
# costs an error message instead of the whole walk.
#
# These are write-path preconditions, not input guards: they must REFUSE,
# loudly, rather than fall back to something plausible. The fallback the target
# resolution replaced was the workspace's own git origin, which silently stopped
# being the right answer when knowledge/ moved into its own repository — the
# next run would have pushed the whole mirror back into the harness repo as an
# ordinary-looking Draft MR.
#
# So each case below asserts the refusal as well as the resolution, and the
# refusal has to name the variable: a die() that only says "cannot resolve"
# leaves the operator with no next move.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../run.sh
. "$SKILL/run.sh"

fail=0
tmp="$(mktemp -d)"
# The refusal cases below must not be opened by a stray value in the real .env
# that run.sh just loaded through gl_load.
unset NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT
trap 'rm -rf "$tmp"' EXIT

# target_project_url reads $WORKSPACE_ROOT/repos.json and $SNAPSHOT_DIR.
# shellcheck disable=SC2034  # read by target_project_url, sourced from run.sh
SNAPSHOT_DIR="knowledge/references"

manifest() {  # manifest <json>
  WORKSPACE_ROOT="$tmp"
  printf '%s\n' "$1" > "$tmp/repos.json"
}

# resolves <want-url> <label>
resolves() {
  local want="$1" label="$2" got
  if ! got="$(NOTION_SNAPSHOT_PROJECT="" target_project_url 2>/dev/null)"; then
    echo "$label — expected '$want', but the resolver refused" >&2
    fail=1
    return
  fi
  if [[ "$got" != "$want" ]]; then
    echo "$label — want '$want', got '$got'" >&2
    fail=1
  fi
}

# refuses <label>  — must exit non-zero AND name the variable
refuses() {
  local label="$1" variable="${2:-NOTION_SNAPSHOT_PROJECT}" out rc=0
  out="$(NOTION_SNAPSHOT_PROJECT="" target_project_url 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "$label — expected a refusal, got '$out'" >&2
    fail=1
    return
  fi
  if [[ "$out" != *"$variable"* ]]; then
    echo "$label — refused without naming $variable: '$out'" >&2
    fail=1
  fi
}

# override_resolves <override> <want-url> <label>
override_resolves() {
  local override="$1" want="$2" label="$3" got
  if ! got="$(NOTION_SNAPSHOT_PROJECT="$override" target_project_url 2>/dev/null)"; then
    echo "$label — expected '$want', but the resolver refused" >&2
    fail=1
    return
  fi
  if [[ "$got" != "$want" ]]; then
    echo "$label — want '$want', got '$got'" >&2
    fail=1
  fi
}

# override_refuses <override> <label>  — non-zero AND names the variable
override_refuses() {
  local override="$1" label="$2" out rc=0
  out="$(NOTION_SNAPSHOT_PROJECT="$override" target_project_url 2>&1)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "$label — expected a refusal, got '$out'" >&2
    fail=1
    return
  fi
  if [[ "$out" != *NOTION_SNAPSHOT_PROJECT* ]]; then
    echo "$label — refused without naming NOTION_SNAPSHOT_PROJECT: '$out'" >&2
    fail=1
  fi
}

url="git@github.com:group/knowledge-repo.git"

# The manifest alone is enough: packages/ is empty in CI, and specRoot inside
# knowledge/ is the manifest's own statement about which repo owns knowledge.
manifest "{\"always\":[\"harness\",\"knowledge-repo\"],\"repos\":{
  \"harness\":{\"url\":\"git@github.com:group/harness.git\"},
  \"knowledge-repo\":{\"specRoot\":\"knowledge/specs\",\"url\":\"$url\"}}}"
resolves "$url" "single always entry with a knowledge/ specRoot"

# No candidate: nothing in always claims knowledge/.
manifest '{"always":["harness"],"repos":{"harness":{"url":"git@github.com:group/harness.git"}}}'
refuses "no always entry holds knowledge/"

# Two candidates: picking the first silently is exactly the bug this replaced.
manifest "{\"always\":[\"a\",\"b\"],\"repos\":{
  \"a\":{\"specRoot\":\"knowledge/specs\",\"url\":\"git@github.com:group/a.git\"},
  \"b\":{\"specRoot\":\"knowledge/other\",\"url\":\"git@github.com:group/b.git\"}}}"
refuses "two knowledge repositories in always"

# Resolved, but the manifest has no url to push to.
manifest '{"always":["k"],"repos":{"k":{"specRoot":"knowledge/specs"}}}'
refuses "knowledge repository without a url"

# No manifest at all.
WORKSPACE_ROOT="$tmp/empty"
mkdir -p "$WORKSPACE_ROOT"
refuses "no repos.json"

# A checked-out knowledge/ counts too, without any specRoot.
WORKSPACE_ROOT="$tmp"
mkdir -p "$tmp/packages/on-disk/knowledge"
manifest "{\"always\":[\"on-disk\"],\"repos\":{\"on-disk\":{\"url\":\"$url\"}}}"
resolves "$url" "always entry whose packages/ checkout holds knowledge/"

# --- an explicit override is checked against the manifest -------------------
#
# Not belt-and-braces: the value that was right before knowledge/ moved out of
# the harness repository still resolves, clones and pushes. A stale .env is
# indistinguishable from a configured one right up until the mirror lands in
# the wrong repository, as an ordinary-looking Draft MR.
WORKSPACE_ROOT="$tmp"
rm -rf "$tmp/packages"
manifest "{\"always\":[\"knowledge-repo\"],\"repos\":{
  \"knowledge-repo\":{\"specRoot\":\"knowledge/specs\",\"url\":\"$url\"}}}"

override_resolves "$url" "$url" "override equal to the manifest url"
# The same project named as "group/path" — on the default instance, which
# the manifest url also names. Spelling must not count as a mismatch.
override_resolves "group/knowledge-repo" "https://github.com/group/knowledge-repo.git" \
  "override as a bare group/path for the manifest repository"

# The pre-move value: a real project, reachable, and the wrong one.
override_refuses "git@github.com:group/harness.git" "override naming another project"
override_refuses "group/harness" "override naming another project as group/path"

# The deliberate case still has a way out, and only this one variable opens it.
got="$(NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT=yes \
  NOTION_SNAPSHOT_PROJECT="git@example.com:x/y.git" target_project_url 2>/dev/null)"
if [[ "$got" != "git@example.com:x/y.git" ]]; then
  echo "NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT=yes — want 'git@example.com:x/y.git', got '$got'" >&2
  fail=1
fi

# Nothing to check against: the manifest names no knowledge repository, so the
# override is the only answer there is. Refusing here would leave no way to run.
manifest '{"always":["harness"],"repos":{"harness":{"url":"git@github.com:group/harness.git"}}}'
override_resolves "git@example.com:x/y.git" "git@example.com:x/y.git" \
  "override with no manifest candidate to compare against"

# The authored store moves into a project directory, while Notion stays in a
# non-always repository. Neither checkout contents nor always ordering can
# retarget the mirror.
manifest "{\"always\":[\"new\"],\"notionSnapshotRepo\":\"old\",\"repos\":{
  \"new\":{\"knowledgeRoot\":\"projects/pay/knowledge\",\"url\":\"git@github.com:group/new.git\"},
  \"old\":{\"url\":\"$url\"}}}"
mkdir -p "$tmp/packages/new/knowledge"
resolves "$url" "explicit mirror remains outside always"
override_refuses "git@github.com:group/new.git" "authored repository override cannot retarget mirror"

manifest '{"always":["new"],"notionSnapshotRepo":"missing","repos":{"new":{"specRoot":"knowledge/specs","url":"git@github.com:group/new.git"}}}'
refuses "unknown explicit snapshot repository cannot fall back to always"
override_refuses "$url" "override cannot bypass broken snapshot configuration"
manifest '{"always":[],"notionSnapshotRepo":"../old","repos":{"../old":{"url":"git@github.com:group/old.git"}}}'
refuses "unsafe snapshot repository name"
manifest '{"always":[],"notionSnapshotRepo":"old","repos":{"old":{}}}'
refuses "explicit snapshot repository without url"
manifest "{\"always\":[],\"notionSnapshotRepo\":\"old\",\"repos\":{\"old\":{\"url\":\"$url\"}}}"
for unsafe in /tmp/mirror knowledge/references/../facts projects/pay/knowledge/references; do
  SNAPSHOT_DIR="$unsafe" refuses "mirror directory $unsafe must be rejected" NOTION_SNAPSHOT_DIR
done

# Root knowledge layout drives both discovery and the bounded write directory.
manifest "{\"always\":[\"root-store\"],\"repos\":{\"root-store\":{\"knowledgeRoot\":\".\",\"url\":\"$url\"}}}"
SNAPSHOT_DIR=""
resolves "$url" "explicit root knowledge repository without packages"
[[ "$(snapshot_directory)" == references ]] || fail=1
[[ "$(snapshot_directory references/team)" == references/team ]] || fail=1
for unsafe in knowledge/references references/../facts /tmp/mirror references-elsewhere; do
  SNAPSHOT_DIR="$unsafe" refuses "root mirror must reject $unsafe" NOTION_SNAPSHOT_DIR
done
manifest "{\"always\":[],\"notionSnapshotRepo\":\"mirror\",\"repos\":{\"mirror\":{\"knowledgeRoot\":\"projects/pay\",\"url\":\"$url\"}}}"
resolves "$url" "dedicated mirror uses its own configured root"
[[ "$(snapshot_directory)" == projects/pay/references ]] || fail=1
SNAPSHOT_DIR="references" refuses "dedicated mirror cannot use authored root" NOTION_SNAPSHOT_DIR
manifest "{\"always\":[\"authored\"],\"repos\":{\"authored\":{\"knowledgeRoot\":\".\",\"url\":\"$url\"},\"foreign\":{\"knowledgeRoot\":\"archive\",\"url\":\"https://github.com/group/foreign.git\"}}}"
[[ "$(NOTION_SNAPSHOT_PROJECT=group/foreign snapshot_directory)" == archive/references ]] || fail=1
[[ "$(NOTION_SNAPSHOT_PROJECT=group/unknown snapshot_directory)" == knowledge/references ]] || fail=1
NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT=yes override_resolves group/foreign https://github.com/group/foreign.git "foreign override uses its own manifest root"
if NOTION_SNAPSHOT_PROJECT=group/foreign snapshot_directory references >/dev/null 2>&1; then
  echo "foreign override accepted another repository's root" >&2
  fail=1
fi
manifest "{\"always\":[],\"notionSnapshotRepo\":\"mirror\",\"repos\":{\"mirror\":{\"knowledgeRoot\":\"../escape\",\"url\":\"$url\"}}}"
refuses "unsafe snapshot knowledge root" NOTION_SNAPSHOT_DIR
# shellcheck disable=SC2034  # consumed by sourced entrypoint and functions
SNAPSHOT_DIR="knowledge/references"

# Explicit null disables publication, even with stale or deliberate env overrides.
# A legacy candidate on disk must not reopen discovery after removal.
manifest '{"always":["new"],"notionSnapshotRepo":null,"repos":{"new":{"specRoot":"knowledge/specs","url":"git@github.com:group/new.git"}}}'
mkdir -p "$tmp/packages/new/knowledge"
for override in "" "$url" "git@github.com:group/new.git"; do
  for foreign in "" yes; do
    rc=0
    out="$(NOTION_SNAPSHOT_PROJECT="$override" \
      NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT="$foreign" target_project_url 2>&1)" || rc=$?
    if [[ "$rc" -eq 0 || "$out" != *"snapshot publishing is disabled"* || "$out" != *"notionSnapshotRepo=null"* ]]; then
      echo "disabled publishing escaped or lacked a clear refusal: '$out'" >&2
      fail=1
    fi
  done
done

# Exercise the actual entrypoint: refusal precedes both the walk and git access.
# Local dump-only reading remains usable with the same disabled manifest.
printf '%s\n' '{"roots":{"team":{}}}' > "$tmp/notion.json"
notion_sh() { touch "$tmp/walk-called"; printf 'PAGES=1\n'; }
gl_require_gh() { touch "$tmp/git-called"; return 1; }
rc=0
out="$(unset NOTION_SNAPSHOT_GIT_EMAIL; \
  NOTION_SNAPSHOT_PROJECT="$url" NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT=yes \
  main --keep "$tmp/dump" 2>&1)" || rc=$?
if [[ "$rc" -eq 0 || "$out" != *"snapshot publishing is disabled"* \
      || -e "$tmp/walk-called" || -e "$tmp/git-called" || -e "$tmp/dump" ]]; then
  echo "disabled entrypoint did not refuse before side effects: '$out'" >&2
  fail=1
fi
out="$(main --no-push --keep "$tmp/dump" 2>&1)"
if [[ "$out" != *SNAPSHOT_STATE=dump-only* || ! -e "$tmp/walk-called" || -e "$tmp/git-called" ]]; then
  echo "disabled publishing blocked dump-only reading: '$out'" >&2
  fail=1
fi

# A checked-in symlink in the old mirror must not redirect replacement into
# a sibling project; a normal absent destination remains valid.
mkdir -p "$tmp/snapshot/knowledge" "$tmp/outside"
ln -s "$tmp/outside" "$tmp/snapshot/knowledge/references"
if validate_snapshot_path "$tmp/snapshot" knowledge/references/pay 2>/dev/null; then
  echo "symlink escaped snapshot checkout without a refusal" >&2
  fail=1
fi
rm "$tmp/snapshot/knowledge/references"
validate_snapshot_path "$tmp/snapshot" knowledge/references/pay
mkdir -p "$tmp/root-snapshot"
ln -s "$tmp/outside" "$tmp/root-snapshot/references"
if validate_snapshot_path "$tmp/root-snapshot" references/pay 2>/dev/null; then
  echo "root references symlink escaped snapshot checkout" >&2
  fail=1
fi

# --- the committer identity -------------------------------------------------
#
# Checked beside the project resolution and for the same reason: push rules on
# the target reject the push at the very end, after the walk, the clone and the
# tree replacement have all been paid for.

# identity_refuses <label> <value>  — the literal UNSET means "not in the env".
# A subshell rather than a fresh `bash -c . run.sh`: re-sourcing run.sh would
# re-run gl_load and let the real workspace .env put the variable back, so the
# unset case would quietly test nothing.
identity_refuses() {
  local label="$1" value="$2" out rc=0
  if [[ "$value" == UNSET ]]; then
    out="$(unset NOTION_SNAPSHOT_GIT_EMAIL; require_committer_identity 2>&1)" || rc=$?
  else
    # shellcheck disable=SC2034  # read by require_committer_identity, next command
    out="$(NOTION_SNAPSHOT_GIT_EMAIL="$value"; require_committer_identity 2>&1)" || rc=$?
  fi
  if [[ "$rc" -eq 0 ]]; then
    echo "$label — expected a refusal, got '$out'" >&2
    fail=1
    return
  fi
  if [[ "$out" != *NOTION_SNAPSHOT_GIT_EMAIL* ]]; then
    echo "$label — refused without naming NOTION_SNAPSHOT_GIT_EMAIL: '$out'" >&2
    fail=1
  fi
}

identity_refuses "NOTION_SNAPSHOT_GIT_EMAIL unset" UNSET
identity_refuses "NOTION_SNAPSHOT_GIT_EMAIL empty" ""
identity_refuses "NOTION_SNAPSHOT_GIT_EMAIL left at the built-in placeholder" \
  "notion-snapshot@localhost"

# A real address passes. run.sh does not police the domain: which addresses a
# project accepts is that project's push rule, and run.sh is the shared layer.
if ! NOTION_SNAPSHOT_GIT_EMAIL="someone@example.com" require_committer_identity 2>/dev/null; then
  echo "a configured NOTION_SNAPSHOT_GIT_EMAIL was refused" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: notion-snapshot target resolution" >&2
  exit 1
fi
echo "ok: snapshot write-path preconditions (target project, committer identity)"
