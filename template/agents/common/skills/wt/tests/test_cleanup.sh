#!/usr/bin/env bash
# `wt cleanup` на настоящем git: удаляет только задачи, чья работа уже есть в
# origin/<base>, и оставляет всё, где хоть один коммит существует только здесь.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/workspace"
mkdir -p "$WS/agents/common/skills/wt" "$WS/agents/common/skills/commit-and-mr" "$WS/packages"
printf '{}\n' > "$WS/harness.json"
cp "$ROOT/agents/common/skills/wt/wt" "$WS/agents/common/skills/wt/wt"
cp "$ROOT/agents/common/skills/commit-and-mr/lib.sh" "$WS/agents/common/skills/commit-and-mr/lib.sh"
cp "$ROOT/agents/common/skills/commit-and-mr/"{env.py,redact.py} "$WS/agents/common/skills/commit-and-mr/"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
commit() { printf '%s\n' "$2" > "$1/$2"; g "$1" add "$2"; g "$1" commit -m "$2"; }

# origin.git с веткой main и её клон в packages/demo.
git init --quiet --bare -b main "$TMP/origin.git"
git init --quiet -b main "$TMP/seed"
commit "$TMP/seed" base
g "$TMP/seed" remote add origin "$TMP/origin.git"
g "$TMP/seed" push origin main
printf 'node_modules/\n.env*\nlocal-data/\n' > "$TMP/seed/.gitignore"
g "$TMP/seed" add .gitignore; g "$TMP/seed" commit -m ignore
g "$TMP/seed" push origin main
git clone --quiet "$TMP/origin.git" "$WS/packages/demo"
git clone --quiet "$TMP/origin.git" "$WS/packages/specs"
D="$WS/packages/demo"
printf 'X=1\n' > "$D/.env"

# add_task <task> [<repo>] — what `wt new` leaves: worktrees/<task>/<repo>.
add_task() {
  local repo="${2:-demo}"
  g "$WS/packages/$repo" worktree add -b "feature/$1" "$WS/worktrees/$1/$repo" origin/main
}
add_task merged;   commit "$WS/worktrees/merged/demo" merged-work
mkdir "$WS/worktrees/merged/demo/node_modules"
ln -s "$D/.env" "$WS/worktrees/merged/demo/.env"
add_task rebased;  commit "$WS/worktrees/rebased/demo" rebased-work
add_task open;     commit "$WS/worktrees/open/demo" open-work
add_task dirty;    printf 'wip\n' > "$WS/worktrees/dirty/demo/untracked"
add_task empty
# Продуктовая задача: в demo работа смёржена, specs ("always") не трогали.
add_task mixed;    commit "$WS/worktrees/mixed/demo" mixed-work; add_task mixed specs
# Ветка с неотправленным коммитом, переключённая на base: HEAD уже в main,
# а feature/det — нет. Удалить её значило бы потерять коммит.
add_task det;      commit "$WS/worktrees/det/demo" det-work
g "$WS/worktrees/det/demo" switch --detach origin/main
add_task kept-data; commit "$WS/worktrees/kept-data/demo" kept-data-work
mkdir "$WS/worktrees/kept-data/demo/local-data"
printf 'db\n' > "$WS/worktrees/kept-data/demo/local-data/pg"
# Вложенные задачи adopt.sh: каждая ветка судится отдельно.
add_task nest/a;   commit "$WS/worktrees/nest/a/demo" nest-a-work
add_task nest/b;   printf 'wip\n' > "$WS/worktrees/nest/b/demo/untracked"

# merged доезжает до main как есть, rebased — тем же патчем, но другим SHA.
g "$TMP/seed" pull --quiet origin main
for t in merged mixed kept-data nest/a; do
  g "$TMP/seed" fetch "$WS/worktrees/$t/demo" "feature/$t"
  g "$TMP/seed" merge --no-edit FETCH_HEAD
done
commit "$TMP/seed" unrelated
g "$TMP/seed" fetch "$WS/worktrees/rebased/demo" feature/rebased
g "$TMP/seed" cherry-pick FETCH_HEAD
g "$TMP/seed" push origin main

run() { (cd "$WS" && bash agents/common/skills/wt/wt "$@"); }
fail() { echo "FAIL: $*" >&2; exit 1; }

out="$(run cleanup --dry-run 2>&1)" || fail "dry-run exited non-zero: $out"
for t in merged rebased open dirty empty mixed det kept-data nest/a nest/b; do
  [ -d "$WS/worktrees/$t/demo" ] || fail "dry-run removed $t"
done
grep -q 'would remove merged' <<< "$out" || fail "dry-run missed merged: $out"
grep -q 'keep   open — demo: 1 commit(s) not in origin/main' <<< "$out" || fail "open not explained: $out"

out="$(run cleanup 2>&1)" || fail "cleanup exited non-zero: $out"
for t in merged rebased mixed nest/a; do
  [ ! -e "$WS/worktrees/$t" ] || fail "$t was kept: $out"
  ! git -C "$D" show-ref --verify --quiet "refs/heads/feature/$t" || fail "branch of $t survived"
done
! git -C "$WS/packages/specs" show-ref --verify --quiet refs/heads/feature/mixed || fail "specs branch of mixed survived"
for t in open dirty empty det kept-data nest/b; do
  [ -d "$WS/worktrees/$t/demo" ] || fail "$t was removed: $out"
  git -C "$D" show-ref --verify --quiet "refs/heads/feature/$t" || fail "branch of $t deleted"
done
expect() { grep -qF "keep   $1 — $2" <<< "$out" || fail "$1 not explained as '$2': $out"; }
expect dirty 'demo: uncommitted changes'
expect empty 'nothing committed yet'
expect det 'demo: detached HEAD'
expect kept-data 'demo: ignored files that would be lost: local-data'
expect nest/b 'demo: uncommitted changes'

# Явно названная задача трогается одна, остальные не перечисляются.
out="$(run cleanup open 2>&1)" || fail "named cleanup exited non-zero: $out"
grep -q 'dirty' <<< "$out" && fail "named cleanup looked at other tasks: $out"
if run cleanup ../escape >/dev/null 2>&1; then fail "accepted task path escape"; fi
echo ok
