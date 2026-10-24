#!/usr/bin/env bash
# A parent trace must include MR handoffs owned by stepped child tasks.

set -euo pipefail

source_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
workspace="$tmp/workspace"
code="$workspace/worktrees/reporting/step/code"
spec="$workspace/worktrees/reporting/spec"

mkdir -p \
  "$workspace/.claude/skills/commit-and-mr" \
  "$workspace/.claude/skills/spec-trace" \
  "$workspace/.coordination/tasks" \
  "$code" \
  "$spec/openspec/changes/archive-token"

cp "$source_root/skills/commit-and-mr/lib.sh" \
  "$workspace/.claude/skills/commit-and-mr/lib.sh"
cp "$source_root/skills/spec-trace/trace.sh" \
  "$source_root/skills/spec-trace/spec-checkout-lib.sh" \
  "$workspace/.claude/skills/spec-trace/"

printf '{}\n' > "$workspace/harness.json"
cat > "$workspace/repos.json" <<'EOF'
{
  "always": ["spec"],
  "repos": {
    "code": {"branch": "main", "url": "git@github.com:group/code.git"},
    "spec": {"branch": "main", "url": "git@github.com:group/spec.git"}
  }
}
EOF

git init -q -b main "$code"
git -C "$code" config user.name Tester
git -C "$code" config user.email tester@example.invalid
printf 'base\n' > "$code/file"
git -C "$code" add file
git -C "$code" commit -qm base
git -C "$code" branch feature/reporting/base
git -C "$code" switch -qc feature/reporting/step
printf 'step\n' >> "$code/file"
git -C "$code" commit -qam step

git init -q -b feature/reporting "$spec"
git -C "$spec" config user.name Tester
git -C "$spec" config user.email tester@example.invalid
printf 'spec\n' > "$spec/spec.txt"
git -C "$spec" add spec.txt
git -C "$spec" commit -qm spec

cat > "$workspace/.coordination/tasks/00-parent.json" <<'EOF'
{
  "task": "reporting",
  "repos": {
    "worktrees/reporting/spec": {
      "mrUrl": "https://github.com/group/spec/pull/3",
      "mrState": "opened",
      "targetBranch": "main"
    }
  }
}
EOF

cat > "$workspace/.coordination/tasks/10-child.json" <<'EOF'
{
  "task": "reporting/step",
  "repos": {
    "worktrees/reporting/step/code": {
      "mrUrl": "https://github.com/group/code/pull/7",
      "mrState": "opened",
      "targetBranch": "feature/reporting/base"
    }
  }
}
EOF

out="$(
  WORKSPACE_COORDINATION_ROOT="$workspace" \
    "$workspace/.claude/skills/spec-trace/trace.sh" \
      --task reporting --change archive-token --print
)"

grep -Fq '| step/code | `feature/reporting/step` | `feature/reporting/base` | [!7]' <<<"$out"
grep -Fq -- '- `' <<<"$out"

echo "ok: parent trace reads stepped child MR target"
