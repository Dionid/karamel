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

# agent-directed-routing bookkeeping: worktrees/<task>/.agent-routing/ beside
# the canonical checkouts. Every task below is merged, so only the bookkeeping
# can keep it.
# ledger <task-dir> <state>... — ownership.json with one entry per state.
ledger() {
  local dir="$WS/worktrees/$1/.agent-routing" st list="" i=0; shift
  mkdir -p "$dir/checkouts" "$dir/recovery" "$dir/journals" "$dir/locks"
  : > "$dir/ownership.json.lock"
  for st in "$@"; do
    i=$((i + 1)); list="${list:+$list,}{\"agentPath\":\"root/w$i\",\"state\":\"$st\"}"
  done
  printf '{"version":2,"entries":[%s]}\n' "$list" > "$dir/ownership.json"
}
# writer <task-dir> — a real disposable writer checkout (a git worktree).
writer() {
  g "$D" worktree add --detach "$WS/worktrees/$1/.agent-routing/checkouts/root~w1" origin/main
}
ROUTED="rt-checkout rt-reserved rt-active rt-patch rt-bad rt-recovery rt-journal rt-idle rn/a rn/b"
for t in $ROUTED; do add_task "$t"; commit "$WS/worktrees/$t/demo" "$(tr / - <<< "$t")-work"; done
ledger rt-checkout active; writer rt-checkout
ledger rt-reserved integrated reserved
ledger rt-active integrated active
ledger rt-patch failed patch_ready
mkdir -p "$WS/worktrees/rt-bad/.agent-routing"; printf '{not json' > "$WS/worktrees/rt-bad/.agent-routing/ownership.json"
ledger rt-recovery failed; mkdir -p "$WS/worktrees/rt-recovery/.agent-routing/recovery/root~w1"
printf 'diff\n' > "$WS/worktrees/rt-recovery/.agent-routing/recovery/root~w1/_patch.diff"
ledger rt-journal integrated; printf '{}\n' > "$WS/worktrees/rt-journal/.agent-routing/journals/root~w1.json"
ledger rt-idle integrated failed
ledger rn/a active      # nested: worktrees/<task>/<sub>/.agent-routing
ledger rn/b integrated

# merged доезжает до main как есть, rebased — тем же патчем, но другим SHA.
g "$TMP/seed" pull --quiet origin main
for t in merged mixed kept-data nest/a $ROUTED; do
  g "$TMP/seed" fetch "$WS/worktrees/$t/demo" "feature/$t"
  g "$TMP/seed" merge --no-edit FETCH_HEAD
done
commit "$TMP/seed" unrelated
g "$TMP/seed" fetch "$WS/worktrees/rebased/demo" feature/rebased
g "$TMP/seed" cherry-pick FETCH_HEAD
g "$TMP/seed" push origin main

run() { (cd "$WS" && bash agents/common/skills/wt/wt "$@"); }
fail() { echo "FAIL: $*" >&2; exit 1; }

# A writer checkout is not a task: neither list nor cleanup may report one.
out="$(run list 2>&1)" || fail "list exited non-zero: $out"
grep -q 'agent-routing\|root~w1' <<< "$out" && fail "list shows agent-routing as a task/repo: $out"

out="$(run cleanup --dry-run 2>&1)" || fail "dry-run exited non-zero: $out"
grep -Eq '(^keep   |would remove )[^ ]*(\.agent-routing|root~w1)' <<< "$out" \
  && fail "dry-run treats a writer checkout as a task: $out"
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

# Agent routing holds a merged task: one case per reason.
for t in rt-checkout rt-reserved rt-active rt-patch rt-bad rt-recovery rt-journal rn/a; do
  [ -d "$WS/worktrees/$t/demo" ] || fail "$t was removed despite agent-routing work: $out"
  [ -d "$WS/worktrees/$t/.agent-routing" ] || fail "bookkeeping of $t was removed: $out"
done
[ -d "$WS/worktrees/rt-checkout/.agent-routing/checkouts/root~w1" ] || fail "writer checkout removed"
expect rt-checkout 'agent routing: 1 writer checkout(s) in rt-checkout/.agent-routing/checkouts'
expect rt-reserved 'agent routing: 1 live ledger entr(ies) (reserved/active/patch_ready)'
expect rt-active 'agent routing: 1 live ledger entr(ies)'
expect rt-patch 'agent routing: 1 live ledger entr(ies)'
expect rt-bad 'agent routing: unreadable ledger rt-bad/.agent-routing/ownership.json'
expect rt-recovery 'agent routing: recovery bundle(s) in rt-recovery/.agent-routing/recovery'
expect rt-journal 'agent routing: apply journal(s) in rt-journal/.agent-routing/journals'
expect rn/a 'agent routing: 1 live ledger entr(ies) (reserved/active/patch_ready) in rn/a/.agent-routing'
# Terminal-only bookkeeping goes with the last checkout instead of pinning the dir.
[ ! -e "$WS/worktrees/rt-idle" ] || fail "rt-idle (or its .agent-routing) survived: $(ls -A "$WS/worktrees/rt-idle")"
[ ! -e "$WS/worktrees/rn/b" ] || fail "rn/b (nested, idle bookkeeping) survived"

# Once the writer checkout is gone, the same task is removed with its bookkeeping.
g "$D" worktree remove --force "$WS/worktrees/rt-checkout/.agent-routing/checkouts/root~w1"
ledger rt-checkout integrated
out="$(run cleanup rt-checkout 2>&1)" || fail "cleanup rt-checkout failed: $out"
[ ! -e "$WS/worktrees/rt-checkout" ] || fail "rt-checkout kept after its writer finished: $out"

# Bookkeeping is never a task path.
out="$(run cleanup rt-active/.agent-routing/checkouts/root~w1 2>&1)" && fail "cleanup accepted .agent-routing path"
grep -q 'bad task name' <<< "$out" || fail "no bad-task-name for .agent-routing path: $out"
out="$(run rm rt-active/.agent-routing 2>&1)" && fail "rm accepted .agent-routing path"
grep -q 'bad task name' <<< "$out" || fail "rm: no bad-task-name for .agent-routing path: $out"
out="$(run new x/.agent-routing --repo demo 2>&1)" && fail "new accepted .agent-routing path"
grep -q 'bad task name' <<< "$out" || fail "new: no bad-task-name for .agent-routing path: $out"

# wt rm refuses without --force while a writer checkout exists, nested ledger included.
add_task rt-force; ledger rt-force active; writer rt-force
out="$(run rm rt-force 2>&1)" && fail "rm removed a task with a writer checkout: $out"
grep -q 'agent-routing work in progress' <<< "$out" || fail "rm refusal not explained: $out"
[ -d "$WS/worktrees/rt-force/demo" ] && [ -d "$WS/worktrees/rt-force/.agent-routing/checkouts/root~w1" ] \
  || fail "refused rm still removed something"
out="$(run rm rn 2>&1)" && fail "rm of the outer task ignored the nested ledger of rn/a: $out"
[ -d "$WS/worktrees/rn/a/demo" ] || fail "refused rm rn removed rn/a"
out="$(run rm rt-force --force 2>&1)" || fail "rm --force failed: $out"
[ ! -e "$WS/worktrees/rt-force" ] || fail "rm --force left $(ls -A "$WS/worktrees/rt-force")"
git -C "$D" worktree list | grep -q 'rt-force' && fail "writer checkout registration survived rm --force"

# Bookkeeping stays while a checkout of the task remains, goes with the last one,
# and an emptied grouping dir's idle .agent-routing goes too.
add_task rt-two; add_task rt-two specs; ledger rt-two integrated
out="$(run rm rt-two --repo specs 2>&1)" || fail "rm --repo specs failed: $out"
[ -d "$WS/worktrees/rt-two/.agent-routing" ] || fail "bookkeeping dropped while demo remains"
out="$(run rm rt-two 2>&1)" || fail "rm of the last checkout failed: $out"
[ ! -e "$WS/worktrees/rt-two" ] || fail "rt-two left behind: $(ls -A "$WS/worktrees/rt-two")"
add_task rp/x; ledger rp integrated; ledger rp/x integrated
out="$(run rm rp/x 2>&1)" || fail "rm rp/x failed: $out"
[ ! -e "$WS/worktrees/rp" ] || fail "rp grouping dir left behind: $(find "$WS/worktrees/rp")"

# Явно названная задача трогается одна, остальные не перечисляются.
out="$(run cleanup open 2>&1)" || fail "named cleanup exited non-zero: $out"
grep -q 'dirty' <<< "$out" && fail "named cleanup looked at other tasks: $out"
if run cleanup ../escape >/dev/null 2>&1; then fail "accepted task path escape"; fi
echo ok
