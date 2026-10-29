#!/usr/bin/env bash
#
# Personal base: a repo with "personalBase": true in repos.json, in a workspace
# whose owner is set (`git config workspace.owner <prefix>`, WORKSPACE_OWNER
# overriding it, an empty WORKSPACE_OWNER= switching it off), forks its tasks
# from <owner>-<base> and targets its PRs there.
#
# Checked here, offline, against a bare repository on disk as origin:
#   - resolve_task_base (lib.sh) — the one resolver wt, adopt.sh, run.sh,
#     preflight.sh, task-link.sh and spec-trace share;
#   - `wt new` creating <owner>-<base> on origin once, from origin/<base>, and
#     never moving it afterwards;
#   - the empty WORKSPACE_OWNER= switch;
#   - `wt cleanup` accepting a task merged into <base> OR into <owner>-<base>.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$script_dir/../../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset WORKSPACE_OWNER AGENT_SESSION_ID

failures=0
check() { # check <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n    expected: %q\n    actual:   %q\n' "$1" "$2" "$3"
    failures=$((failures + 1))
  fi
}
g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
commit() { printf '%s\n' "$2" > "$1/$2"; g "$1" add "$2"; g "$1" commit -m "$2"; }
has() { if grep -q -- "$1" <<< "$2"; then echo yes; else echo no; fi; }
remote_sha() { git -C "$TMP/origin.git" rev-parse --verify --quiet "refs/heads/$1" || echo none; }

# ------------------------------------------------------------- resolver ------

# shellcheck source=../lib.sh
. "$script_dir/../lib.sh"

R="$TMP/resolver"
mkdir -p "$R"
git init --quiet "$R"
cat > "$R/repos.json" <<'JSON'
{"repos": {
  "app":   {"branch": "main", "personalBase": true},
  "plain": {"branch": "development"},
  "off":   {"branch": "main", "personalBase": false},
  "nobranch": {"personalBase": true}
}}
JSON

check "no owner: personalBase repo keeps its base" main "$(resolve_task_base "$R" app)"
git -C "$R" config workspace.owner ds
check "owner from git config" ds-main "$(resolve_task_base "$R" app)"
check "repo without personalBase keeps its base" development "$(resolve_task_base "$R" plain)"
check "personalBase false keeps its base" main "$(resolve_task_base "$R" off)"
check "no branch field: main, then the personal base" ds-main "$(resolve_task_base "$R" nobranch)"
check "repo absent from the manifest" main "$(resolve_task_base "$R" ghost)"
check "caller-supplied base" ds-develop "$(resolve_task_base "$R" app develop)"
check "empty caller base stays empty" "" "$(resolve_task_base "$R" app "")"
check "WORKSPACE_OWNER overrides git config" xy-main "$(WORKSPACE_OWNER=xy resolve_task_base "$R" app)"
check "empty WORKSPACE_OWNER switches the personal base off" main "$(WORKSPACE_OWNER='' resolve_task_base "$R" app)"
rc=0; out="$(WORKSPACE_OWNER='a b' resolve_task_base "$R" app 2>/dev/null)" || rc=$?
check "an owner that is no branch prefix is an error" "1:" "$rc:$out"
rc=0; WORKSPACE_OWNER='a b' resolve_task_base "$R" plain >/dev/null 2>&1 || rc=$?
check "an invalid owner does not matter to a repo without personalBase" 0 "$rc"
mv "$R/repos.json" "$R/repos.off"
check "no manifest at all" main "$(resolve_task_base "$R" app)"
mv "$R/repos.off" "$R/repos.json"

# spec-trace reads the same answer through spec-checkout-lib.sh's repo_branch.
check "spec-trace repo_branch uses the resolver" ds-main "$(
  export WORKSPACE_ROOT="$R"
  # shellcheck source=../../spec-trace/spec-checkout-lib.sh
  . "$script_dir/../../spec-trace/spec-checkout-lib.sh"
  repo_branch "worktrees/t/app")"

# ------------------------------------------------- wt new and wt cleanup -----

WS="$TMP/workspace"
mkdir -p "$WS/agents/common/skills/"{wt,commit-and-mr,clone} "$WS/packages"
cp "$ROOT/agents/common/skills/wt/wt" "$WS/agents/common/skills/wt/wt"
cp "$ROOT/agents/common/skills/commit-and-mr/"{lib.sh,env.py,redact.py} "$WS/agents/common/skills/commit-and-mr/"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/agents/common/skills/clone/ensure-repository"
chmod +x "$WS/agents/common/skills/clone/ensure-repository"
printf '{"branchPrefix":"feature/"}\n' > "$WS/harness.json"
cat > "$WS/repos.json" <<'JSON'
{"repos": {"app": {"branch": "main", "personalBase": true, "deps": "none"},
           "lib": {"branch": "main", "deps": "none"}}}
JSON
git init --quiet "$WS"
git -C "$WS" config workspace.owner ds

git init --quiet --bare -b main "$TMP/origin.git"
git init --quiet --bare -b main "$TMP/lib.git"
git init --quiet -b main "$TMP/seed"
commit "$TMP/seed" base
g "$TMP/seed" remote add origin "$TMP/origin.git"
g "$TMP/seed" push origin main
g "$TMP/seed" push "$TMP/lib.git" main
git clone --quiet "$TMP/origin.git" "$WS/packages/app"
git clone --quiet "$TMP/lib.git" "$WS/packages/lib"

wt() { (cd "$WS" && bash agents/common/skills/wt/wt "$@"); }
main_sha="$(remote_sha main)"

check "before: no personal base on origin" none "$(remote_sha ds-main)"
out="$(wt new t1 --repo app 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
check "wt new creates ds-main on origin from origin/main" "$main_sha" "$(remote_sha ds-main)"
check "the task forks from the personal base" "$main_sha" "$(git -C "$WS/worktrees/t1/app" rev-parse HEAD)"
r="$(has 'off origin/ds-main' "$out")"
check "wt new reports origin/ds-main as the start point" yes "$r"

# ds-main moves ahead of main (a task merged into it): the next task forks from
# it, and wt new does not recreate or move it.
commit "$WS/worktrees/t1/app" t1-work
g "$WS/worktrees/t1/app" push origin feature/t1:ds-main
ds_sha="$(remote_sha ds-main)"
out="$(wt new t2 --repo app 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
check "an existing personal base is not moved" "$ds_sha" "$(remote_sha ds-main)"
check "the next task forks from the advanced personal base" "$ds_sha" "$(git -C "$WS/worktrees/t2/app" rev-parse HEAD)"
r="$(has 'creating it' "$out")"
check "an existing personal base is not created again" no "$r"

# Empty WORKSPACE_OWNER= switches it off: the task forks from origin/main and
# no other personal base appears on origin.
out="$(WORKSPACE_OWNER='' wt new t3 --repo app 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
check "WORKSPACE_OWNER= forks from origin/main" "$main_sha" "$(git -C "$WS/worktrees/t3/app" rev-parse HEAD)"
check "WORKSPACE_OWNER= creates no branch on origin" "ds-main main" \
  "$(git -C "$TMP/origin.git" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' ' | sed 's/ $//')"
out="$(WORKSPACE_OWNER=zz wt new t3b --repo app 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
check "WORKSPACE_OWNER overrides git config for wt new" "$main_sha" "$(remote_sha zz-main)"

# A repo without personalBase is untouched by the owner.
out="$(wt new t4 --repo lib 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
check "a repo without personalBase gets no personal base" none \
  "$(git -C "$TMP/lib.git" rev-parse --verify --quiet refs/heads/ds-main || echo none)"

# An explicit --base is the start point as is (adopt.sh passes the branch).
out="$(wt new t5 --repo app --base main 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
check "--base is used as is" "$main_sha" "$(git -C "$WS/worktrees/t5/app" rev-parse HEAD)"

# Cleanup: t1 is merged into ds-main only, t6 into main only, t7 nowhere. t6
# forks from main (owner off), so merging it does not carry t1's commit along.
out="$(WORKSPACE_OWNER='' wt new t6 --repo app 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
commit "$WS/worktrees/t6/app" t6-work
g "$TMP/seed" fetch "$WS/worktrees/t6/app" feature/t6
g "$TMP/seed" merge --no-edit FETCH_HEAD
g "$TMP/seed" push origin main
out="$(wt new t7 --repo app --allow-stale 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
commit "$WS/worktrees/t7/app" t7-work

out="$(WORKSPACE_OWNER='' wt cleanup --dry-run t1 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
r="$(has '^keep   t1 — app: 1 commit(s) not in origin/main$' "$out")"
check "WORKSPACE_OWNER= cleanup compares with origin/main only" yes "$r"

out="$(wt cleanup --dry-run t1 t6 t7 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
r="$(has 'would remove t1' "$out")"
check "cleanup: merged into ds-main counts" yes "$r"
r="$(has 'would remove t6' "$out")"
check "cleanup: merged into main counts" yes "$r"
# t7 forked from ds-main, so it carries t1's commit too: two not in main.
r="$(has '^keep   t7 — app: 2 commit(s) not in origin/main; 1 commit(s) not in origin/ds-main$' "$out")"
check "cleanup: work in neither base is kept, naming both" yes "$r"

out="$(wt cleanup t1 t6 t7 2>&1)" || { printf '%s\n' "$out" >&2; exit 1; }
check "cleanup removed t1 and t6, kept t7" "gone gone kept" \
  "$([ -e "$WS/worktrees/t1" ] && echo kept || echo gone) $([ -e "$WS/worktrees/t6" ] && echo kept || echo gone) $([ -e "$WS/worktrees/t7/app" ] && echo kept || echo gone)"
check "cleanup never touches the personal base" "$ds_sha" "$(remote_sha ds-main)"

if ((failures)); then
  printf 'personal-base: %d failure(s)\n' "$failures"
  exit 1
fi
echo 'personal-base: OK'
