#!/usr/bin/env bash
#
# The task block: the offline render (author line, table of the task's MRs from
# local coordination records), the description run.sh creates the PR with, and
# the live --update pass that links every open PR of the task both ways.
#
# No network and no GitHub: gh is tests/fake-gh and git's push is stubbed.

set -euo pipefail
export GITHUB_TOKEN=fixture

skill="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
coord="$skill/../coordination/coord"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0

check() {
  local name expected actual
  name="$1"
  expected="$2"
  actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s\n    expected: %q\n    actual:   %q\n' "$name" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

contains() {
  local name haystack needle
  name="$1"
  haystack="$2"
  needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s\n    missing: %q\n    in:       %q\n' "$name" "$needle" "$haystack"
    failures=$((failures + 1))
  fi
}

lacks() {
  local name haystack needle
  name="$1"
  haystack="$2"
  needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s\n    unexpected: %q\n    in:          %q\n' "$name" "$needle" "$haystack"
    failures=$((failures + 1))
  fi
}

workspace="$tmp/workspace"
mkdir -p "$workspace"
printf '{}\n' > "$workspace/harness.json"
printf '%s\n' \
  '{"repos":{"project":{"branch":"main"},"shared":{"branch":"main"},"docs":{"branch":"main"},"solo":{"branch":"main"},"pb":{"branch":"main","personalBase":true}}}' \
  > "$workspace/repos.json"

# The committer is config, the author is the environment: this runtime exports
# GIT_AUTHOR_NAME/EMAIL, and a test that only set `git config user.name` would
# silently record whoever ran it instead of the identity it means to assert.
seed() {
  local dir="$1"
  git init -q -b main "$dir"
  git -C "$dir" config user.name Tester
  git -C "$dir" config user.email tester@example.invalid
  git -C "$dir" remote add origin "git@github.com:group/$(basename "$dir").git"
  printf 'seed\n' > "$dir/file"
  git -C "$dir" add file
  GIT_AUTHOR_NAME=Seeder GIT_AUTHOR_EMAIL=seeder@example.invalid \
    GIT_COMMITTER_NAME=Seeder GIT_COMMITTER_EMAIL=seeder@example.invalid \
    git -C "$dir" commit -qm seed
  git -C "$dir" switch -qc feature/linking
}

# commit <dir> <name> <email> <subject> — one commit authored by that identity,
# carrying the Co-Authored-By trailer run.sh appends.
commit() {
  local dir="$1" name="$2" email="$3" subject="$4"
  printf '%s\n' "$subject" >> "$dir/file"
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" \
    GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" \
    git -C "$dir" commit -qam "$subject

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
}

# --- a task spread over several checkouts ---------------------------------
mkdir -p "$workspace/worktrees/linking"
seed "$workspace/worktrees/linking/project"
seed "$workspace/worktrees/linking/shared"
# Added by `wt new` from the manifest's `always` list and never touched: a
# branch with no commits of its own.
seed "$workspace/worktrees/linking/docs"

commit "$workspace/worktrees/linking/project" "managed runtime agent" author@example.com "feat: first"
commit "$workspace/worktrees/linking/shared" "managed runtime agent" author@example.com "feat: shared"

WORKSPACE_COORDINATION_ROOT="$workspace" "$coord" record-mr \
  --task linking --repo shared --checkout worktrees/linking/shared \
  --branch feature/linking \
  --sha "$(git -C "$workspace/worktrees/linking/shared" rev-parse HEAD)" \
  --url https://github.com/group/shared/pull/12 --state created --target main

block() {
  WORKSPACE_COORDINATION_ROOT="$workspace" \
    bash "$skill/task-link.sh" --task linking --workspace "$workspace" "$@"
}

multi="$(block --self worktrees/linking/project)"

contains "the author line names the git identity of the commits" "$multi" \
  '**Автор:** `managed runtime agent <author@example.com>` · агент: `Claude Opus 5 (1M context)`'
contains "the table links the sibling PR" "$multi" \
  '| shared | `feature/linking` | [#12](https://github.com/group/shared/pull/12) · opened |'
contains "the PR being created is marked, not linked" "$multi" \
  '| project | `feature/linking` | _этот MR_ |'
contains "the offline table says it is replaced later" "$multi" 'Таблица собрана офлайн перед созданием этого PR'
lacks "an untouched always-checkout is not promised a review" "$multi" '| docs |'
contains "the block is marked as generated" "$multi" '<!-- task-link:start -->'

# A checkout that carries commits but has no PR yet is named as such: the next
# repo of the task is committed after this one, and its row has to say so.
commit "$workspace/worktrees/linking/docs" "managed runtime agent" author@example.com "docs: note"
with_pending="$(block --self worktrees/linking/project)"
contains "a branch with work and no PR says so" "$with_pending" \
  '| docs | `feature/linking` | _MR не открыт_ |'

# Two people on one branch are both named.
commit "$workspace/worktrees/linking/project" "Second Human" second@example.invalid "fix: second"
two="$(block --self worktrees/linking/project)"
contains "a branch two people pushed onto names both" "$two" \
  '**Автор:** `managed runtime agent <author@example.com>`, `Second Human <second@example.invalid>` · агент: `Claude Opus 5 (1M context)`'

# --- a record with checkout: "" (not absent) must still match by key ------
#
# `coord record-mr` run without `--checkout` writes `"checkout": ""` — an
# empty string, not absent or `null`. The jq `//` fallback operator only
# substitutes for `null`/`false`, never for `""`, so matching on
# `.value.checkout // .key` stops at the empty string and never reaches the
# record's key. This is a standalone task so the extra sibling cannot change
# the sibling counts the "linking" assertions above and below depend on.
mkdir -p "$workspace/worktrees/key-fallback"
seed "$workspace/worktrees/key-fallback/self"
seed "$workspace/worktrees/key-fallback/sibling"
commit "$workspace/worktrees/key-fallback/self" "managed runtime agent" author@example.com "feat: self"
commit "$workspace/worktrees/key-fallback/sibling" "managed runtime agent" author@example.com "feat: sibling"

# `--repo` is whatever the record's key ends up being; here it is set to
# exactly the lookup key `mr_of` is given (`worktrees/<task>/<rel>`) so the
# key fallback, and only the key fallback, can match it.
WORKSPACE_COORDINATION_ROOT="$workspace" "$coord" record-mr \
  --task key-fallback --repo worktrees/key-fallback/sibling \
  --branch feature/linking \
  --sha "$(git -C "$workspace/worktrees/key-fallback/sibling" rev-parse HEAD)" \
  --url https://github.com/group/sibling/pull/13 --state created --target main

empty_checkout="$(
  WORKSPACE_COORDINATION_ROOT="$workspace" \
    bash "$skill/task-link.sh" --task key-fallback --workspace "$workspace" \
      --self worktrees/key-fallback/self
)"
contains "a record with an empty (not absent) checkout still matches by key" \
  "$empty_checkout" \
  '| sibling | `feature/linking` | [#13](https://github.com/group/sibling/pull/13) · opened |'

# --- the siblings that cannot learn about the new PR ----------------------
stale="$(block --self worktrees/linking/project --stale-siblings)"
check "the already-open sibling PR is reported as unreachable" \
  "https://github.com/group/shared/pull/12" "$stale"

# --- a task in one repository ---------------------------------------------
mkdir -p "$workspace/worktrees/solo-task"
seed "$workspace/worktrees/solo-task/solo"
commit "$workspace/worktrees/solo-task/solo" "managed runtime agent" author@example.com "feat: solo"

single="$(
  WORKSPACE_COORDINATION_ROOT="$workspace" \
    bash "$skill/task-link.sh" --task solo-task --workspace "$workspace" \
      --self worktrees/solo-task/solo
)"
contains "a single-repo task still names its author" "$single" \
  '**Автор:** `managed runtime agent <author@example.com>`'
lacks "a single-repo task gets no table" "$single" '| Репозиторий |'
single_stale="$(
  WORKSPACE_COORDINATION_ROOT="$workspace" \
    bash "$skill/task-link.sh" --task solo-task --workspace "$workspace" \
      --self worktrees/solo-task/solo --stale-siblings
)"
check "a single-repo task warns about nothing" "" "$single_stale"

# --- an unusable workspace owner -------------------------------------------
# Only a personalBase repo needs the owner: a task without one still renders,
# and a task with one fails loudly instead of logging against an empty base.
rc=0
bad_owner="$(
  WORKSPACE_COORDINATION_ROOT="$workspace" WORKSPACE_OWNER='a b' \
    bash "$skill/task-link.sh" --task solo-task --workspace "$workspace" \
      --self worktrees/solo-task/solo 2>&1
)" || rc=$?
check "an invalid owner does not stop a task without personalBase repos" 0 "$rc"
contains "an invalid owner still renders the author" "$bad_owner" \
  '**Автор:** `managed runtime agent <author@example.com>`'

mkdir -p "$workspace/worktrees/pb-task"
seed "$workspace/worktrees/pb-task/pb"
commit "$workspace/worktrees/pb-task/pb" "managed runtime agent" author@example.com "feat: pb"
rc=0
bad_owner_pb="$(
  WORKSPACE_COORDINATION_ROOT="$workspace" WORKSPACE_OWNER='a b' \
    bash "$skill/task-link.sh" --task pb-task --workspace "$workspace" \
      --self worktrees/pb-task/pb 2>&1
)" || rc=$?
check "an invalid owner fails a task with a personalBase repo" 1 "$rc"
contains "the failure names the owner" "$bad_owner_pb" "workspace owner 'a b'"

# --- run.sh creates the PR with the block, then links every open PR --------
#
# gh is tests/fake-gh; git's push is stubbed. The sibling PR !12 already
# exists in the fake GitHub with a description a human wrote.
mkdir -p "$tmp/bin" "$tmp/gh-state"
real_git="$(command -v git)"
cat > "$tmp/bin/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then
    printf 'pushed\n'
    exit 0
  fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$tmp/bin/git"
ln -s "$skill/tests/fake-gh" "$tmp/bin/gh"
export FAKE_GH_STATE="$tmp/gh-state"
mrs="$tmp/gh-state/mrs.json"

# iid 12 for the sibling; the fake numbers new MRs length+1, so the one run.sh
# opens below is !2 — distinct from it either way.
jq -n '[{project: "https://github.com/group/shared", number: 12,
         url: "https://github.com/group/shared/pull/12",
         state: "OPEN", headRefName: "feature/linking", baseRefName: "main",
         title: "Draft: shared", body: "Текст, написанный человеком."}]' > "$mrs"

cat > "$tmp/description" <<'EOF'
## Что и зачем

Проверить блок задачи.

## Изменения

- Тест: описание уходит вместе с блоком.

## Инфраструктура, схема, зависимости

Нет.

## Как проверить

Запустить task-link.test.sh.

## Риски и что осталось

Нет.

## Changelog

Нет.
EOF

run_push() {
  local label="$1"
  shift
  printf 'feat: %s\n' "$label" >> "$workspace/worktrees/linking/project/file"
  printf 'feat: %s\n' "$label" > "$tmp/message"
  WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
    bash "$skill/run.sh" \
      --worktree "$workspace/worktrees/linking/project" --repo project \
      --message-file "$tmp/message" "$@" -- file
}

out="$(run_push with-block --mr-description-file "$tmp/description" 2>"$tmp/warnings")"
check "the PR is created" "https://github.com/group/project/pull/2" \
  "$(sed -n 's/^MR_URL=//p' <<<"$out")"

created="$(jq -r '.[] | select(.number == 2) | .body' "$mrs")"
sibling="$(jq -r '.[] | select(.number == 12) | .body' "$mrs")"

contains "the new PR carries the block" "$created" '<!-- task-link:start -->'
contains "the new PR carries the author line" "$created" '**Автор:** `'
contains "the new PR names the agent from the trailer" "$created" \
  '· агент: `Claude Opus 5 (1M context)`'
contains "the new PR keeps the authored body" "$created" '## Что и зачем'
contains "the block sits above the authored body" "$created" \
  "$(printf '<!-- task-link:end -->\n\n## Что и зачем')"
contains "after --update the new PR links itself, marked" "$created" \
  '[#2](https://github.com/group/project/pull/2) · opened ← этот PR |'
contains "after --update the new PR links the sibling" "$created" \
  '[#12](https://github.com/group/shared/pull/12) · opened |'

contains "the sibling opened earlier now links back" "$sibling" \
  '[#2](https://github.com/group/project/pull/2) · opened |'
contains "the sibling marks its own row" "$sibling" \
  '[#12](https://github.com/group/shared/pull/12) · opened ← этот PR |'
contains "the sibling keeps what a human wrote" "$sibling" 'Текст, написанный человеком.'
check "the sibling has exactly one block" 1 "$(grep -c 'task-link:start' <<<"$sibling")"
lacks "nothing warned" "$(cat "$tmp/warnings")" 'warning: task-link.sh --update failed'

# A second --update with nothing new writes nothing.
log_before="$(grep -c '^edit$' "$tmp/gh-state/log" || true)"
check "the first pass did write through gh" yes "$( ((log_before > 0)) && echo yes || echo no)"
again="$(WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
  bash "$skill/task-link.sh" --task linking --workspace "$workspace" --update)"
contains "a rerun reports the blocks as unchanged" "$again" 'TASK_UNCHANGED=2'
check "a rerun sends no update" "$log_before" "$(grep -c '^edit$' "$tmp/gh-state/log" || true)"

# --dry-run prints and writes nothing.
jq '(.[] | select(.number == 12) | .body) = "Сброшено."' "$mrs" > "$mrs.tmp" && mv "$mrs.tmp" "$mrs"
dry="$(WORKSPACE_COORDINATION_ROOT="$workspace" PATH="$tmp/bin:$PATH" \
  bash "$skill/task-link.sh" --task linking --workspace "$workspace" --update --dry-run)"
contains "--dry-run says what it would link" "$dry" 'WOULD-LINK=shared https://github.com/group/shared/pull/12'
check "--dry-run writes nothing" "Сброшено." "$(jq -r '.[] | select(.number == 12) | .body' "$mrs")"

# A refused write is a warning from run.sh, not a failed run.
set +e
out="$(FAKE_GH_UPDATE=fail run_push refused-update --existing-mr 2>"$tmp/warnings")"
rc=$?
set -e
check "a refused task-link write does not fail the run" 0 "$rc"
check "the run still reports the PR" "existing" "$(sed -n 's/^MR_STATE=//p' <<<"$out")"
contains "the refusal is named with the repair command" "$(cat "$tmp/warnings")" \
  'task-link.sh --task linking --update'

# --no-task-link: no block in a refreshed description, and no --update pass.
jq '(.[] | select(.number == 12) | .body) = "Не трогать."' "$mrs" > "$mrs.tmp" && mv "$mrs.tmp" "$mrs"
run_push without-block --existing-mr --mr-description-file "$tmp/description" --no-task-link >/dev/null 2>&1
created="$(jq -r '.[] | select(.number == 2) | .body' "$mrs")"
lacks "--no-task-link sends no block" "$created" '<!-- task-link:start -->'
contains "--no-task-link still sends the authored body" "$created" '## Что и зачем'
check "--no-task-link leaves the siblings alone" "Не трогать." \
  "$(jq -r '.[] | select(.number == 12) | .body' "$mrs")"

if ((failures)); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'ok: the task block reaches the new PR, and --update links every open PR both ways\n'
