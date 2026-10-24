#!/usr/bin/env bash
# A checkout under worktrees/<task>/<repo> that carries a regular harness.json of
# its own (left by `./ops sync` run inside a agent-workspace worktree) must still
# resolve to the workspace root above it: in run.sh, which otherwise refuses with
# "worktree must be under worktrees/<task>/", and in lib.sh's find_workspace_root,
# which run.sh, preflight.sh and harness_base_branch share. A workspace that itself
# sits under some worktrees/ directory must stay resolvable through the fallback.

set -euo pipefail
export GITHUB_TOKEN=fixture

skill="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fails=0
expect() {
  local what="$1" expected="$2" actual="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$what" "$expected" "$actual" >&2
    fails=$((fails + 1))
  fi
}

workspace="$tmp/workspace"
checkout="$workspace/worktrees/task/agent-workspace"
mkdir -p "$checkout"
workspace="$(cd "$workspace" && pwd)"
printf '{"baseBranch":"development"}\n' > "$workspace/harness.json"
printf '{"repos":{"agent-workspace":{"branch":"development"}}}\n' > "$workspace/repos.json"
git init -q -b development "$checkout"
# The stray marker: a regular file, not the symlink find_real_workspace_root already skipped.
printf '{"baseBranch":"stray"}\n' > "$checkout/harness.json"

# shellcheck source=../lib.sh
. "$skill/lib.sh"

expect "find_real_workspace_root skips the worktree's own harness.json" \
  "$workspace" "$(find_real_workspace_root "$checkout")"
expect "find_workspace_root defers to the real root" \
  "$workspace" "$(find_workspace_root "$checkout")"
expect "harness_base_branch reads the workspace manifest, not the stray one" \
  "development" "$(harness_base_branch "$checkout")"

# A workspace that itself lives under some worktrees/ directory has no "real"
# root by that rule; find_workspace_root falls back to the nearest marker.
nested="$tmp/worktrees/outer/ws"
mkdir -p "$nested/sub"
nested="$(cd "$nested" && pwd)"
printf '{}\n' > "$nested/harness.json"
expect "find_workspace_root falls back to the nearest harness.json" \
  "$nested" "$(find_workspace_root "$nested/sub")"

# run.sh: resolution must pass the worktrees/<task>/ gate and stop at the next
# check, an empty message file — before anything is staged or pushed.
: > "$tmp/message"
run_reaches_message_check() {
  local label="$1" checkout="$2" output rc
  set +e
  output="$(bash "$skill/run.sh" --worktree "$checkout" --repo agent-workspace \
    --message-file "$tmp/message" --no-mr -- file 2>&1)"
  rc=$?
  set -e
  expect "$label: run.sh exits 1 on the empty message" "1" "$rc"
  if [[ "$output" != *"message file is empty"* ]]; then
    printf 'FAIL: %s: run.sh did not reach the message check:\n%s\n' "$label" "$output" >&2
    fails=$((fails + 1))
  fi
  if [[ "$output" == *"must be under worktrees"* ]]; then
    printf 'FAIL: %s: run.sh took the worktree for the workspace root:\n%s\n' "$label" "$output" >&2
    fails=$((fails + 1))
  fi
  expect "$label: run.sh left the checkout uncommitted" "" \
    "$(git -C "$checkout" log --oneline 2>/dev/null || true)"
}

run_reaches_message_check "stray harness.json" "$checkout"

# run.sh resolves like preflight.sh: a workspace that itself sits under some
# worktrees/ directory is found by the nearest-marker fallback, not refused.
fallback_checkout="$nested/worktrees/t/agent-workspace"
mkdir -p "$fallback_checkout"
printf '{"repos":{"agent-workspace":{"branch":"development"}}}\n' > "$nested/repos.json"
git init -q -b development "$fallback_checkout"
run_reaches_message_check "workspace under worktrees/" "$fallback_checkout"

if ((fails > 0)); then
  printf '%d failure(s)\n' "$fails" >&2
  exit 1
fi
printf 'commit-and-mr real workspace root: OK\n'
