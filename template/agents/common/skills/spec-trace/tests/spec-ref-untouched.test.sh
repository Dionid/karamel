#!/usr/bin/env bash
# spec-ref.sh must judge a branch by its OWN diff against the spec repo's base,
# never by what merely sits in the shared spec checkout's working tree.
#
# The bug this pins down: `openspec/changes/` in the spec repo's default branch
# routinely holds several *other* tasks' unarchived active changes — that is
# the normal steady state, not an edge case. A resolver that counted every
# directory under `changes/` regardless of which branch put it there would trip
# the "several active changes, pass --change" refusal on every task that never
# touched a change directory at all (the common case: a task with no spec
# impact), turning SPEC_STATE=untouched into a hard error as soon as the spec
# repo accumulated more than one active change anywhere.
#
# spec-ref.sh finds the workspace root by walking up from its own path looking
# for harness.json, so it must run from inside a fake workspace that has one —
# not from the engine's own source tree, which is a generator, not a deployed
# workspace, and has no harness.json of its own. Each scenario below builds
# that workspace: harness.json + repos.json at its root, and this skill's own
# scripts + commit-and-mr/lib.sh copied under .claude/skills/, exactly as
# `./ops sync` would lay them out in a real generated workspace.
#
# Discovered automatically by this engine's lint skill.

set -uo pipefail

skill_dir="$(cd "$(dirname "$0")/.." && pwd)"
skills_root="$(cd "$skill_dir/.." && pwd)"
lib_sh="$skills_root/commit-and-mr/lib.sh"

if [ ! -f "$lib_sh" ]; then
  echo "FAIL: не найден $lib_sh" >&2
  exit 1
fi

if ! command -v jq > /dev/null 2>&1; then
  echo "SKIP: jq недоступен, spec-ref.sh требует его" >&2
  exit 0
fi

failures=0
checks=0

ok() {
  checks=$((checks + 1))
  printf 'ok   %s\n' "$1"
}

bad() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  printf 'FAIL %s\n' "$1" >&2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# make_workspace <dir> — a fake generated workspace: harness.json at its root
# and this skill's own scripts wired up under .claude/skills/, so a script run
# from inside it resolves WORKSPACE_ROOT to <dir>, never to some unrelated
# ancestor.
make_workspace() {
  local dir="$1"
  mkdir -p "$dir/.claude/skills/commit-and-mr" "$dir/.claude/skills/spec-trace" "$dir/worktrees/task"
  printf '{}\n' > "$dir/harness.json"
  cp "$lib_sh" "$dir/.claude/skills/commit-and-mr/lib.sh"
  cp "$skill_dir/spec-ref.sh" "$skill_dir/spec-checkout-lib.sh" "$dir/.claude/skills/spec-trace/"
  chmod +x "$dir/.claude/skills/spec-trace/spec-ref.sh"
}

spec_ref_in() {
  local ws="$1"
  shift
  "$ws/.claude/skills/spec-trace/spec-ref.sh" "$@"
}

# --- upstream: спека с ДЕСЯТЬЮ чужими активными changes на development ------
upstream="$tmp/upstream"
git init -q -b development "$upstream"
(
  cd "$upstream" || exit
  git config user.email test@example.com
  git config user.name test
  mkdir -p openspec/specs
  for i in 1 2 3 4 5 6 7 8 9 10; do
    mkdir -p "openspec/changes/other-task-$i"
    echo "proposal $i" > "openspec/changes/other-task-$i/proposal.md"
  done
  git add -A
  git commit -q -m "ten unrelated active changes, as if development always looks"
)

clone_checkout() {
  # clone_checkout <dest> — a fresh clone of upstream, on a feature branch, so
  # each scenario starts from the same ten-unrelated-changes baseline.
  local dest="$1"
  git clone -q "$upstream" "$dest"
  (
    cd "$dest" || exit
    git config user.email test@example.com
    git config user.name test
    git checkout -q -b feature/task
  )
}

# --- сценарий 1: ветка не трогала спеку вообще → untouched, не отказ --------
ws1="$tmp/ws1"
make_workspace "$ws1"
cat > "$ws1/repos.json" <<'JSON'
{
  "always": ["spec-repo"],
  "exclude": [],
  "repos": {
    "spec-repo": { "url": "git@example.com:org/specs.git", "branch": "development" }
  }
}
JSON
checkout1="$ws1/worktrees/task/spec-repo"
clone_checkout "$checkout1"

out="$(spec_ref_in "$ws1" --worktree "$checkout1" 2>"$tmp/err1")"
rc=$?

if [ "$rc" -eq 0 ]; then
  ok "untouched: exit 0"
else
  bad "untouched: ожидался exit 0, получен $rc (stderr: $(cat "$tmp/err1"))"
fi

if printf '%s\n' "$out" | grep -qx 'SPEC_STATE=untouched'; then
  ok "untouched: SPEC_STATE=untouched несмотря на 10 чужих active changes"
else
  bad "untouched: SPEC_STATE не untouched — вывод: $out"
fi

# --- сценарий 2: ветка сама трогает ДВЕ change-директории → это ambiguous ---
ws2="$tmp/ws2"
make_workspace "$ws2"
cat > "$ws2/repos.json" <<'JSON'
{
  "always": ["spec-repo"],
  "exclude": [],
  "repos": {
    "spec-repo": { "url": "git@example.com:org/specs.git", "branch": "development" }
  }
}
JSON
checkout2="$ws2/worktrees/task/spec-repo"
clone_checkout "$checkout2"
(
  cd "$checkout2" || exit
  mkdir -p openspec/changes/my-change-a openspec/changes/my-change-b
  echo "a" > openspec/changes/my-change-a/proposal.md
  echo "b" > openspec/changes/my-change-b/proposal.md
  git add -A
  git commit -q -m "this branch's own two changes"
)

err2="$tmp/err2"
spec_ref_in "$ws2" --worktree "$checkout2" > /dev/null 2>"$err2"
rc=$?

if [ "$rc" -ne 0 ]; then
  ok "ambiguous-own: exit non-zero when this branch's own diff is genuinely ambiguous"
else
  bad "ambiguous-own: ожидался отказ, получен exit 0"
fi

if grep -q 'pass --change to pick one' "$err2"; then
  ok "ambiguous-own: сообщение просит --change"
else
  bad "ambiguous-own: нет ожидаемого сообщения об ошибке — stderr: $(cat "$err2")"
fi

if grep -q 'my-change-a' "$err2" && grep -q 'my-change-b' "$err2"; then
  ok "ambiguous-own: перечислены СВОИ change (my-change-a, my-change-b)"
else
  bad "ambiguous-own: свои change не перечислены — stderr: $(cat "$err2")"
fi

if grep -q 'other-task-' "$err2"; then
  bad "ambiguous-own: в список утекли чужие active changes из development — stderr: $(cat "$err2")"
else
  ok "ambiguous-own: чужие active changes из development в список не попали"
fi

# --- сценарий 3: ветка трогает РОВНО ОДНУ свою change-директорию → пикается сама
ws3="$tmp/ws3"
make_workspace "$ws3"
cat > "$ws3/repos.json" <<'JSON'
{
  "always": ["spec-repo"],
  "exclude": [],
  "repos": {
    "spec-repo": { "url": "git@example.com:org/specs.git", "branch": "development" }
  }
}
JSON
checkout3="$ws3/worktrees/task/spec-repo"
clone_checkout "$checkout3"
(
  cd "$checkout3" || exit
  mkdir -p openspec/changes/my-only-change
  echo "only" > openspec/changes/my-only-change/proposal.md
  git add -A
  git commit -q -m "this branch's one change"
)

out3="$(spec_ref_in "$ws3" --worktree "$checkout3" 2>"$tmp/err3")"
rc=$?

if [ "$rc" -eq 0 ] && printf '%s\n' "$out3" | grep -qx 'SPEC_CHANGE=my-only-change'; then
  ok "single-own-change: picked up automatically despite ten unrelated siblings"
else
  bad "single-own-change: ожидался SPEC_CHANGE=my-only-change, получено: $out3 (stderr: $(cat "$tmp/err3"))"
fi

# --- сценарий 4: репозитория спек в always нет вообще → no-spec-repo -------
ws4="$tmp/ws4"
make_workspace "$ws4"
cat > "$ws4/repos.json" <<'JSON'
{
  "always": [],
  "exclude": [],
  "repos": {}
}
JSON
mkdir -p "$ws4/worktrees/task/some-code-repo"
git init -q -b main "$ws4/worktrees/task/some-code-repo" > /dev/null

out4="$(spec_ref_in "$ws4" --task task --worktree "$ws4/worktrees/task/some-code-repo" 2>"$tmp/err4")"
rc=$?

if [ "$rc" -eq 0 ] && printf '%s\n' "$out4" | grep -qx 'SPEC_STATE=no-spec-repo'; then
  ok "no-spec-repo: manifest без always-спеки отвечает нейтральным состоянием"
else
  bad "no-spec-repo: ожидался SPEC_STATE=no-spec-repo, получено: $out4 (stderr: $(cat "$tmp/err4"))"
fi

# --- сценарий 5: два spec-store в одной задаче → отказ, а не тихий выбор ----
# Store больше не один: репозиторий объявляет свой полем specRoot, и продукт со
# своим store не обязан лежать в `always`. Тогда «первый найденный» — это
# порядок манифеста, а не ответ на вопрос, чья это спека, и spec-ref.sh обязан
# отказать кодом 2. Нейтральный no-spec-repo здесь был бы хуже отказа: он
# утверждает, что спеки нет, ровно там, где их две.
ws5="$tmp/ws5"
make_workspace "$ws5"
cat > "$ws5/repos.json" <<'JSON'
{
  "always": ["spec-repo"],
  "exclude": [],
  "repos": {
    "spec-repo": { "url": "git@example.com:org/specs.git", "branch": "development", "specRoot": "project" },
    "own-store": { "url": "git@example.com:org/own.git", "branch": "development", "specRoot": "" }
  }
}
JSON
mkdir -p "$ws5/worktrees/task/spec-repo/project/openspec/changes" \
         "$ws5/worktrees/task/own-store/openspec/changes" \
         "$ws5/worktrees/task/some-code-repo"
git init -q -b main "$ws5/worktrees/task/some-code-repo" > /dev/null

err5="$tmp/err5"
out5="$(spec_ref_in "$ws5" --task task --worktree "$ws5/worktrees/task/some-code-repo" 2>"$err5")"
rc=$?

if [ "$rc" -eq 2 ]; then
  ok "two-stores: exit 2, адрес выбирает субъект изменения, а не манифест"
else
  bad "two-stores: ожидался exit 2, получен $rc (вывод: $out5, stderr: $(cat "$err5"))"
fi

if printf '%s\n' "$out5" | grep -q 'SPEC_STATE=no-spec-repo'; then
  bad "two-stores: отказ свёлся к нейтральному no-spec-repo — ссылка на спеку потеряна молча"
else
  ok "two-stores: отказ не выдаётся за «спеки нет»"
fi

if grep -q 'spec-repo' "$err5" && grep -q 'own-store' "$err5"; then
  ok "two-stores: перечислены оба кандидата"
else
  bad "two-stores: кандидаты не перечислены — stderr: $(cat "$err5")"
fi

# Названный субъект снимает неоднозначность — и выбирает именно свой store.
out6="$(SPEC_SUBJECT_REPO=own-store spec_ref_in "$ws5" --task task \
  --worktree "$ws5/worktrees/task/some-code-repo" 2>"$tmp/err6")"
rc=$?

if [ "$rc" -ne 2 ] && printf '%s\n' "$out6" | grep -qx 'SPEC_REPO=own-store'; then
  ok "two-stores: SPEC_SUBJECT_REPO выбирает store субъекта"
else
  bad "two-stores: SPEC_SUBJECT_REPO не выбрал own-store — rc=$rc, вывод: $out6 (stderr: $(cat "$tmp/err6"))"
fi

# --- итог -------------------------------------------------------------------
printf '\n%d проверок, %d неудач\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
