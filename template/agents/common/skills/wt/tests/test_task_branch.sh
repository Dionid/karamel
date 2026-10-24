#!/usr/bin/env bash
# Workspace's own repo can use clone-url without joining repos.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"
mkdir -p "$WS/agents/common/skills/"{wt,commit-and-mr}
cp "$ROOT/agents/common/skills/wt/wt" "$WS/agents/common/skills/wt/wt"
cp "$ROOT/agents/common/skills/commit-and-mr/lib.sh" "$WS/agents/common/skills/commit-and-mr/lib.sh"
cp "$ROOT/agents/common/skills/commit-and-mr/"{env.py,redact.py} "$WS/agents/common/skills/commit-and-mr/"
printf '{"branchPrefix":"codex/","baseBranch":"main"}\n' > "$WS/harness.json"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
git init -q -b main "$TMP/source"
printf 'base\n' > "$TMP/source/file"
git -C "$TMP/source" add file
git -C "$TMP/source" commit -qm fixture
run() { bash "$WS/agents/common/skills/wt/wt" clone-url "$@"; }
run first "$TMP/source" --name harness --task-branch
DEST="$WS/worktrees/first/harness"
[ "$(git -C "$DEST" branch --show-current)" = codex/first ]
sha="$(git -C "$DEST" rev-parse HEAD)"
run first "$TMP/source" --name harness --task-branch
[ "$(git -C "$DEST" rev-parse HEAD)" = "$sha" ]
# Existing clone on its default branch can be adopted without cloning again.
run existing "$TMP/source" --name harness
run existing "$TMP/source" --name harness --task-branch
[ "$(git -C "$WS/worktrees/existing/harness" branch --show-current)" = codex/existing ]
if run first "$TMP/other" --name harness --task-branch 2>/dev/null; then exit 1; fi
printf 'dirty\n' >> "$DEST/file"
if run first "$TMP/source" --name harness --task-branch 2>/dev/null; then exit 1; fi
git -C "$DEST" restore file
git -C "$DEST" switch -qc foreign
if run first "$TMP/source" --name harness --task-branch 2>/dev/null; then exit 1; fi
[ "$(git -C "$DEST" branch --show-current)" = foreign ]
[ "$(git -C "$DEST" rev-parse HEAD)" = "$sha" ]
printf 'ok: clone-url task branch creation, idempotence and refusals\n'
