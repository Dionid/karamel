#!/usr/bin/env bash
# A browser prefill URL is not an PR and must never enter coordination/spec trace;
# a created or reused PR is recorded with the target gh reports. gh is
# tests/fake-gh, git's push is stubbed: no network.

set -euo pipefail
export GITHUB_TOKEN=fixture

skill="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
workspace="$tmp/workspace"
checkout="$workspace/worktrees/reporting/step/project"
mkdir -p "$checkout" "$tmp/bin"
printf '{}\n' > "$workspace/harness.json"
printf '{"repos":{"project":{"branch":"main"}}}\n' > "$workspace/repos.json"

git init -q -b main "$checkout"
git -C "$checkout" config user.name Tester
git -C "$checkout" config user.email tester@example.invalid
git -C "$checkout" remote add origin git@github.com:group/project.git
printf 'seed\n' > "$checkout/file"
git -C "$checkout" add file
git -C "$checkout" commit -qm seed
git -C "$checkout" switch -qc feature/reporting/step
printf 'changed\n' >> "$checkout/file"
printf 'test: reporting\n' > "$tmp/message"
cat > "$tmp/description" <<'EOF'
## Что и зачем

Проверить отчётность commit-and-mr.

## Изменения

- Тест: фиксирует coordination handoff.

## Инфраструктура, схема, зависимости

Нет.

## Как проверить

Запустить reporting.test.sh.

## Риски и что осталось

Нет.

## Changelog

Нет.
EOF

real_git="$(command -v git)"
cat > "$tmp/bin/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then
    printf 'pushed\n' >> "$tmp/pushes"
    printf 'pushed\n'
    exit 0
  fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin/git"
ln -s "$skill/tests/fake-gh" "$tmp/bin/gh"
mkdir -p "$tmp/gh-state"
export FAKE_GH_STATE="$tmp/gh-state"

out="$(
  cd "$workspace"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project \
      --message-file "$tmp/message" --no-mr -- file
)"

grep -q '^MR_STATE=not-created$' <<<"$out"
grep -q '^MR_URL=$' <<<"$out"
grep -q '^PREFILL_URL=https://github.com/group/project/compare/' <<<"$out"

if find "$workspace/.coordination/tasks" -type f -maxdepth 1 2>/dev/null | grep -q .; then
  echo "unconfirmed prefill URL was recorded as an PR" >&2
  exit 1
fi

printf 'second change\n' >> "$checkout/file"
printf 'test: record stepped reporting\n' > "$tmp/message"

confirmed="$({
  cd "$workspace"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project \
      --message-file "$tmp/message" \
      --mr-description-file "$tmp/description" -- file
})"

grep -q '^MR_STATE=created$' <<<"$confirmed"
grep -q '^MR_URL=https://github.com/group/project/pull/1$' <<<"$confirmed"
jq -e '.[0].title == "Draft: test: record stepped reporting" and .[0].baseRefName == "main" and .[0].isDraft == true' \
  "$tmp/gh-state/mrs.json" >/dev/null
jq -e '.[0].body | contains("## Что и зачем")' "$tmp/gh-state/mrs.json" >/dev/null

record="$(find "$workspace/.coordination/tasks" -maxdepth 1 -type f -print -quit)"
jq -e '.task == "reporting/step"' "$record" >/dev/null
jq -e \
  '.repos["worktrees/reporting/step/project"].targetBranch == "main"
   and .repos["worktrees/reporting/step/project"].mrState == "opened"' \
  "$record" >/dev/null

# --existing-mr: the same PR, found through gh, never a second one.
printf 'third change\n' >> "$checkout/file"
printf 'test: review fix\n' > "$tmp/message"
existing="$({
  cd "$workspace"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project \
      --message-file "$tmp/message" --existing-mr -- file
})"
grep -q '^MR_STATE=existing$' <<<"$existing"
grep -q '^MR_URL=https://github.com/group/project/pull/1$' <<<"$existing"
grep -q '^TARGET_BRANCH=main$' <<<"$existing"
jq -e 'length == 1' "$tmp/gh-state/mrs.json" >/dev/null

# --existing-mr with a body: the open PR's description is replaced.
sed 's/Проверить отчётность commit-and-mr./Обновлённое описание./' "$tmp/description" > "$tmp/description2"
printf 'fourth change\n' >> "$checkout/file"
printf 'test: refresh description\n' > "$tmp/message"
refreshed="$({
  cd "$workspace"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project \
      --message-file "$tmp/message" --existing-mr \
      --mr-description-file "$tmp/description2" -- file
})"
grep -q '^MR_STATE=existing$' <<<"$refreshed"
jq -e 'length == 1 and (.[0].body | contains("Обновлённое описание."))' \
  "$tmp/gh-state/mrs.json" >/dev/null

# --description-only: a description read back from GitHub — managed task block
# and all — replaces the open PR's description; nothing is committed or pushed,
# and the PR ends up with one task block, not two.
jq -r '.[0].body' "$tmp/gh-state/mrs.json" > "$tmp/readback"
grep -qF '<!-- task-link:start -->' "$tmp/readback" \
  || { echo "the created PR carries no task block to read back" >&2; exit 1; }
sed -i.bak 's/Обновлённое описание./Только описание./' "$tmp/readback"
before="$(git -C "$checkout" rev-parse HEAD)"
pushes_before="$(wc -l < "$tmp/pushes")"
desc_only="$({
  cd "$workspace"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project --existing-mr \
      --mr-description-file "$tmp/readback" --description-only 2>"$tmp/desc-only.err"
})" || { cat "$tmp/desc-only.err" >&2; echo "--description-only failed" >&2; exit 1; }
grep -q '^MR_STATE=existing$' <<<"$desc_only"
grep -q '^MR_URL=https://github.com/group/project/pull/1$' <<<"$desc_only"
grep -q '^COMMIT_SHA=$' <<<"$desc_only"
grep -q '^note: dropped 1 managed' "$tmp/desc-only.err"
[[ "$(git -C "$checkout" rev-parse HEAD)" == "$before" ]] || { echo "--description-only made a commit" >&2; exit 1; }
[[ "$(wc -l < "$tmp/pushes")" == "$pushes_before" ]] || { echo "--description-only pushed" >&2; exit 1; }
jq -e 'length == 1
       and (.[0].body | contains("Только описание."))
       and ([.[0].body | scan("<!-- task-link:start -->")] | length == 1)' \
  "$tmp/gh-state/mrs.json" >/dev/null \
  || { echo "--description-only: wrong description in the PR" >&2; jq -r '.[0].body' "$tmp/gh-state/mrs.json" >&2; exit 1; }
grep -qx -- 'edit' "$tmp/gh-state/log"

# --description-only commits nothing, so paths or a message file are refused.
if (
  cd "$workspace"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project --existing-mr \
      --mr-description-file "$tmp/readback" --description-only -- file
) >/dev/null 2>&1; then
  echo "--description-only accepted paths" >&2
  exit 1
fi

# A start marker with no end is not guessed at: refused before anything happens.
printf '<!-- task-link:start -->\nhalf a block\n\n' | cat - "$tmp/description" > "$tmp/half"
if (
  cd "$workspace"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project --existing-mr \
      --mr-description-file "$tmp/half" --description-only
) >/dev/null 2>&1; then
  echo "an unterminated managed block was accepted" >&2
  exit 1
fi

# before anything is staged or committed. With a fallback the run goes on —
printf 'fifth change\n' >> "$checkout/file"
before="$(git -C "$checkout" rev-parse HEAD)"
if (
  cd "$workspace"
  unset GITHUB_TOKEN
  FAKE_GH_AUTH=fail AGENT_SESSION_ID=reporting-test \
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project \
      --message-file "$tmp/message" --existing-mr -- file
) >/dev/null 2>&1; then
  echo "run.sh succeeded without a gh login" >&2
  exit 1
fi
[[ "$(git -C "$checkout" rev-parse HEAD)" == "$before" ]] || { echo "commit made without a gh login" >&2; exit 1; }
[[ -z "$(git -C "$checkout" diff --cached --name-only)" ]] || { echo "paths staged without a gh login" >&2; exit 1; }

# gh refuses the create: the push stands, the state says so, no URL is made up.
git -C "$checkout" switch -qc feature/reporting/other
printf 'sixth change\n' >> "$checkout/file"
printf 'test: create refused\n' > "$tmp/message"
set +e
refused="$({
  cd "$workspace"
  FAKE_GH_CREATE=fail WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project \
      --message-file "$tmp/message" \
      --mr-description-file "$tmp/description" -- file 2>/dev/null
})"
refused_rc=$?
set -e
[[ "$refused_rc" == 1 ]] || { echo "refused create exited $refused_rc" >&2; exit 1; }
grep -q '^MR_STATE=create-failed$' <<<"$refused"
grep -q '^MR_URL=$' <<<"$refused"
grep -q '^PREFILL_URL=https://github.com/group/project/compare/' <<<"$refused"

# --description-only on a branch with no open PR: an error, nothing created.
mrs_before="$(jq length "$tmp/gh-state/mrs.json")"
set +e
no_mr="$({
  cd "$workspace"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project --existing-mr \
      --mr-description-file "$tmp/description" --description-only 2>/dev/null
})"
no_mr_rc=$?
set -e
[[ "$no_mr_rc" == 1 ]] || { echo "--description-only without an PR exited $no_mr_rc" >&2; exit 1; }
grep -q '^MR_STATE=not-created$' <<<"$no_mr"
[[ "$(jq length "$tmp/gh-state/mrs.json")" == "$mrs_before" ]] || { echo "--description-only created an PR" >&2; exit 1; }

# gh cannot list the branch's MRs (non-JSON on stdout): "unknown" is never
# "none" — no PR is created, the run says unconfirmed and fails.
git -C "$checkout" switch -qc feature/reporting/unlisted
printf 'seventh change\n' >> "$checkout/file"
printf 'test: list garbage\n' > "$tmp/message"
: > "$tmp/gh-state/log"
set +e
unlisted="$({
  cd "$workspace"
  FAKE_GH_LIST=garbage WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$checkout" --repo project \
      --message-file "$tmp/message" \
      --mr-description-file "$tmp/description" -- file 2>/dev/null
})"
unlisted_rc=$?
set -e
[[ "$unlisted_rc" == 1 ]] || { echo "unlistable MRs exited $unlisted_rc" >&2; exit 1; }
grep -q '^MR_STATE=unconfirmed$' <<<"$unlisted"
grep -q '^MR_URL=$' <<<"$unlisted"
grep -q '^PREFILL_URL=https://github.com/group/project/compare/' <<<"$unlisted"
if grep -qx -- 'create' "$tmp/gh-state/log"; then
  echo "gh pr create ran although the lookup failed" >&2
  exit 1
fi
[[ "$(jq length "$tmp/gh-state/mrs.json")" == "$mrs_before" ]] || { echo "an PR was created after a failed lookup" >&2; exit 1; }

echo "ok: prefill is separate; created and existing MRs are recorded; gh refusals are named; description-only and unconfirmed lookups never commit or create"
