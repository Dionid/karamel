#!/usr/bin/env bash
#
# harness_base_branch — which branch the team repository is based on, for
# commit-and-mr's own worktree and the MRs it opens against it.
#
# `main` used to be a literal, and its failure is silent in the way harness
# failures usually are: a repository that moved to `development` still forks a
# `main` that nobody merges into, the worktree looks right, and the PR lands
# against a branch that is weeks behind. So what is checked here is that the
# answer comes from harness.json, and that a manifest with neither field still
# answers `main`.
#
# `baseBranch` is the second half of that: a workspace whose live checkout
# serves one branch and whose work forks from another says so in its own
# field, and the fallback chain below is what keeps every workspace that never
# split the two answering exactly as it did before.

set -euo pipefail
export GITHUB_TOKEN=fixture

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=../lib.sh
. "$script_dir/../lib.sh"

failures=0

check() {
  local name expected actual
  name="$1"
  expected="$2"
  actual="$3"

  if [[ "$expected" == "$actual" ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s\n' "$name"
    printf '    expected: %q\n' "$expected"
    printf '    actual:   %q\n' "$actual"
    failures=$((failures + 1))
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

make_checkout() { # make_checkout <dir> <origin-url>
  git init --quiet "$1"
  git -C "$1" remote add origin "$2"
}

# The ordinary case: harness.json names the branch its worktrees fork from.
root="$tmp/ws"
mkdir -p "$root"
cat > "$root/harness.json" <<'JSON'
{
  "branch": "development"
}
JSON

make_checkout "$root" "https://github.com/org/team-repo.git"

check "the team repository takes .branch" \
  "development" "$(harness_base_branch "$root")"

mkdir -p "$root/worktrees/task/team-repo"
make_checkout "$root/worktrees/task/team-repo" "https://github.com/org/team-repo.git"
check "a worktree checkout answers the workspace branch" \
  "development" "$(harness_base_branch "$root/worktrees/task/team-repo")"

# A manifest written before the field existed: every workspace out there has one,
# and the skill may not start guessing for it.
old="$tmp/old"
mkdir -p "$old"
cat > "$old/harness.json" <<'JSON'
{
  "branchPrefix": "feature/"
}
JSON

make_checkout "$old" "https://github.com/org/team-repo.git"

check "no .branch falls back to main" \
  "main" "$(harness_base_branch "$old")"

# The split a deployed runtime needs: the live checkout stays on `main`, which is
# what `branch` keeps saying, while worktrees fork from `development` and MRs
# target it. `baseBranch` outranks `branch`.
split="$tmp/split"
mkdir -p "$split"
cat > "$split/harness.json" <<'JSON'
{
  "branch": "main",
  "baseBranch": "development"
}
JSON

make_checkout "$split" "https://github.com/org/team-repo.git"

check ".baseBranch outranks .branch" \
  "development" "$(harness_base_branch "$split")"

# Outside a workspace there is no manifest to read and no reason to fail loudly:
# the callers treat this as "the usual default" and carry on.
make_checkout "$tmp/loose" "https://github.com/org/something.git"
check "a checkout outside any workspace answers main" \
  "main" "$(harness_base_branch "$tmp/loose")"

if (( failures > 0 )); then
  printf 'FAILED: %d\n' "$failures"
  exit 1
fi

printf 'all checks passed\n'
