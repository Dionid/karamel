#!/usr/bin/env bash
# shellcheck disable=SC2034  # snapshot main reads the mocked return variables
# Execute snapshot publication against a local bare repository. GitHub PR calls
# are stubbed to prove that subsequent changes keep the fixed branch's PR.
set -euo pipefail
SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../run.sh
. "$SKILL/run.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
WORKSPACE_ROOT="$TMP/ws"
mkdir -p "$WORKSPACE_ROOT"
printf '%s\n' '{"always":["store"],"repos":{"store":{"url":"https://github.com/owner/knowledge.git","knowledgeRoot":"."}}}' > "$WORKSPACE_ROOT/repos.json"
git init -q -b main "$TMP/seed"
printf 'base\n' > "$TMP/seed/base"
git -C "$TMP/seed" add base
git -C "$TMP/seed" commit -qm fixture
git clone -q --bare "$TMP/seed" "$TMP/origin.git"
NOTION_SNAPSHOT_GIT_EMAIL=t@example.test
SNAPSHOT_DIR=""
configured_roots() { echo demo; }
target_project_url() { echo https://github.com/owner/knowledge.git; }
gl_require_gh() { return 0; }
gl_git_url() { printf 'ref: refs/heads/main\tHEAD\n'; }
gl_clone() { git clone -q "$TMP/origin.git" "$2"; }
gl_git() { local checkout="$1"; shift; git -C "$checkout" "$@"; }
gl_fetch() { git -C "$1" fetch -q origin "$2"; }
gl_push() { git -C "$1" push -q origin "$2"; }
notion_sh() {
  local out=''
  while (($#)); do
    case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac
  done
  mkdir -p "$out"
  printf '%s\n' "$SNAPSHOT_BODY" > "$out/INDEX.md"
  printf 'PAGES=1\n'
}
gl_mr_find() {
  [[ -f "$TMP/pr" ]] || return 1
  MR_URL=https://github.com/owner/knowledge/pull/1
}
gl_mr_create() {
  printf 'created\n' >> "$TMP/creates"
  touch "$TMP/pr"
  MR_URL=https://github.com/owner/knowledge/pull/1
}
SNAPSHOT_BODY=first
out="$(main)"
grep -q 'MR_STATE=created' <<< "$out"
grep -q 'MR_URL=https://github.com/owner/knowledge/pull/1' <<< "$out"
[[ "$(git --git-dir="$TMP/origin.git" show notion/snapshot:references/demo/INDEX.md)" == first ]]
if git --git-dir="$TMP/origin.git" cat-file -e notion/snapshot:knowledge 2>/dev/null; then
  echo 'snapshot recreated knowledge/ despite knowledgeRoot="."' >&2
  exit 1
fi
SNAPSHOT_BODY=second
out="$(main)"
grep -q 'MR_STATE=existing' <<< "$out"
[[ "$(wc -l < "$TMP/creates" | tr -d ' ')" = 1 ]]
out="$(main)"
grep -q 'SNAPSHOT_STATE=unchanged' <<< "$out"
grep -q 'MR_STATE=existing' <<< "$out"
[[ "$(wc -l < "$TMP/creates" | tr -d ' ')" = 1 ]]
echo 'ok: snapshots create one PR and reuse it across changes and unchanged runs'
