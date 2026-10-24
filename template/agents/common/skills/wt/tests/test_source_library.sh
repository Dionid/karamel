#!/usr/bin/env bash
# Updated task sources and generated symlinks must use their own sibling helpers;
# the owning workspace still supplies state, config and credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"
SOURCE="$WS/worktrees/source/harness/agents/common/skills"
mkdir -p "$SOURCE/"{wt,clone,commit-and-mr} "$WS/.claude/skills/commit-and-mr"
cp "$ROOT/agents/common/skills/wt/wt" "$SOURCE/wt/wt"
cp "$ROOT/agents/common/skills/clone/"{clone.sh,ensure-repository} "$SOURCE/clone/"
cp "$ROOT/agents/common/skills/commit-and-mr/"{lib.sh,env.py,redact.py} "$SOURCE/commit-and-mr/"
printf '{"branchPrefix":"codex/","baseBranch":"main"}\n' > "$WS/harness.json"
printf '{}\n' > "$WS/worktrees/source/harness/workspace.json"
printf 'echo wrong-root-library >&2; exit 97\n' > "$WS/.claude/skills/commit-and-mr/lib.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
git init -q -b main "$TMP/seed"
printf 'base\n' > "$TMP/seed/file"
git -C "$TMP/seed" add file
git -C "$TMP/seed" commit -qm fixture
bash "$SOURCE/wt/wt" clone-url task "$TMP/seed" --name harness --task-branch >/dev/null
[[ "$(git -C "$WS/worktrees/task/harness" branch --show-current)" == codex/task ]]
ln -s "$SOURCE/wt" "$WS/.claude/skills/wt"
bash "$WS/.claude/skills/wt/wt" clone-url task "$TMP/seed" --name harness --task-branch >/dev/null
printf '{"repos":{"sample":{"url":"%s","branch":"main"}}}\n' "$TMP/seed" > "$WS/repos.json"
bash "$SOURCE/clone/clone.sh" sample >/dev/null
[[ -d "$WS/packages/sample/.git" ]]
echo 'source helpers: nested sources and generated symlinks use current sibling version'
