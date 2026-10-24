#!/usr/bin/env bash
set -euo pipefail

# The user's own git config is neutralised, because this test asserts what a
# specific `insteadOf` expands to and any global rewrite of the same prefix wins
# or loses unpredictably. That is not hypothetical: cloning in a container with
# no SSH key requires exactly such a rewrite
# (`url.https://github.com/.insteadOf = git@github.com:`), so without these two
# variables the test fails for everyone who set one up — a red suite that says
# nothing about the code under test.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
ENSURE="$ROOT/agents/common/skills/clone/ensure-repository"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

git init -q "$TEST_ROOT/repository"
git -C "$TEST_ROOT/repository" remote add origin git@github.com:example/repository.git

expanded="$({
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0='url.https://oauth2:canary@github.com/.insteadOf' \
  GIT_CONFIG_VALUE_0='git@github.com:' \
  git -C "$TEST_ROOT/repository" remote get-url origin
})"
raw="$({
  GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0='url.https://oauth2:canary@github.com/.insteadOf' \
  GIT_CONFIG_VALUE_0='git@github.com:' \
  git -C "$TEST_ROOT/repository" config --get remote.origin.url
})"

[[ "$expanded" == https://oauth2:canary@github.com/example/repository.git ]]
[[ "$raw" == git@github.com:example/repository.git ]]
grep -Fq 'config --get remote.origin.url' "$ENSURE" \
  || { echo 'ensure-repository must inspect the stored origin without applying insteadOf' >&2; exit 1; }
