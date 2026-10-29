#!/usr/bin/env bash
#
# adopt.sh — open a worktree on a branch that ALREADY exists on origin.
#
# `wt new` always *creates* a branch: `worktree add -b feature/<task>` off
# origin/<base>. That is right for new work and wrong for continuing somebody
# else's — it would fork a second, unrelated branch under the same name. This
# wrapper does the three things that flow needs, then hands over to `wt new`:
#
#   1. prunes dead worktree registrations, so a branch whose directory was
#      removed by hand is no longer "checked out" in a tree that is gone;
#   2. deletes the local branches whose NAME blocks the one being adopted. Git
#      keeps refs as files, so refs/heads/feature/x and refs/heads/feature/x/03
#      cannot both exist — the second one dies with "cannot lock ref
#      'refs/heads/feature/x/03': 'refs/heads/feature/x' exists". Each blocker is
#      deleted only after proving it is already contained in an origin ref, and
#      its sha is printed first, so the deletion is recoverable;
#   3. runs `wt new <task> --base <branch> --allow-stale --no-always`, which is
#      what makes the checkout start on the remote branch rather than on the base.
#
# Everything else — the worktrees/<task>/<repo> layout, the .env* symlinks, the
# deps strategy, postSetup — stays in `wt`; this file only clears its way.
#
# Why each of those `wt new` flags is not optional here:
#   --base <branch>  the start point IS the branch being adopted, and because git
#                    branches off a remote-tracking ref, the new local branch
#                    gets that ref as its upstream for free.
#   --allow-stale    packages/<repo> sits on its base branch, so it is "behind"
#                    the adopted branch by definition and `wt new` would refuse.
#                    The staleness that actually matters — the linked deps coming
#                    from an outdated main checkout — is checked separately below.
#   --no-always      --base applies to every repo of the run, and the "always"
#                    repos (spec-repo) almost never carry the same branch;
#                    they would fail with "base branch not found". They are
#                    reported at the end instead.
#
# Usage:
#   .claude/skills/wt/adopt.sh <feature/branch> --repo <name> [--repo <other>]...
#                              [--dry-run] [--drop-unmerged] [wt new flags]

set -euo pipefail

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
info() { printf '%s%s%s\n' "$c_grn" "$*" "$c_off"; }
warn() { printf '%s%s%s\n' "$c_ylw" "$*" "$c_off"; }
err()  { printf '%s%s%s\n' "$c_red" "$*" "$c_off" >&2; }

# Same rule as `wt`: the workspace is the directory holding harness.json, found by
# walking up from this file's real location, so cwd never matters.
resolve_workspace_root() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  if [ "${1-}" = --source-dir ]; then printf '%s\n' "$dir"; return 0; fi
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/harness.json" ]; then printf '%s\n' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

WS="$(resolve_workspace_root)" \
  || { err "cannot locate the workspace root — no harness.json above ${BASH_SOURCE[0]}"; exit 1; }
SOURCE_DIR="$(resolve_workspace_root --source-dir)"
SELF="$0"
ROOT="$WS/packages"
WT_ROOT="$WS/worktrees"
MANIFEST="$WS/repos.json"
WT="$SOURCE_DIR/wt"
# gl_fetch — the same credentialed fetch `wt` and ensure-repository use, so
# the adopted branch's ref-fetch below works on an ssh-flavoured origin too.
LIB="$SOURCE_DIR/../commit-and-mr/lib.sh"
# shellcheck source=../commit-and-mr/lib.sh
. "$LIB"
gl_load "$WS"
# gl_use_repo <repo> — same per-host token resolution `wt` uses,
# needed before gl_fetch below.
gl_use_repo() {
  gl_use "$(gl_host_from_url "$(git -C "$ROOT/$1" remote get-url origin 2>/dev/null || true)" 2>/dev/null || true)"
}
# Same source as `wt`: harness.json "branchPrefix", default feature/.
read_branch_prefix() {
  local root="$1" value=""
  if command -v python3 >/dev/null 2>&1 && [ -f "$root/harness.json" ]; then
    value="$(python3 -c 'import json,sys
try:    print(json.load(open(sys.argv[1])).get("branchPrefix") or "")
except Exception: print("")' "$root/harness.json" 2>/dev/null || true)"
  fi
  printf '%s' "${value:-feature/}"
}
BRANCH_PREFIX="$(read_branch_prefix "$WS")"

usage() {
  sed "s|@SELF@|$SELF|g" <<'EOF'

Open a worktree on a branch that already exists on origin.

  @SELF@ <feature/branch> --repo <name> [--repo <other>]... [flags]

  --dry-run         print what would happen; touch nothing
  --drop-unmerged   delete a name-blocking local branch even when its commits
                    are on no origin ref (its sha is printed — recover with
                    `git branch <name> <sha>`)
  anything else     passed through to `wt new` (--install, --clone-modules, …)

The branch must start with feature/ — `wt` names branches feature/<task>, and
the task name is what is left after that prefix:

  @SELF@ feature/withdraw-flow/03-wallets --repo api
  # -> worktrees/withdraw-flow/03-wallets/api

For a branch that does NOT exist yet, this script is the wrong tool:
  .claude/skills/wt/wt new <task> --repo <name> --pull

EOF
}

# ------------------------------------------------------------------- args ------

BRANCH=""; REPOS=""; DRY=0; DROP_UNMERGED=0; PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo) [ -n "${2:-}" ] || { err "--repo needs a value"; exit 1; }
            REPOS="${REPOS}${2}"$'\n'; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --drop-unmerged) DROP_UNMERGED=1; shift ;;
    --base) err "--base is set by this script to the branch being adopted — drop it"; exit 1 ;;
    --no-always|--allow-stale) shift ;;   # already passed; accepting them is harmless
    -*) PASS+=("$1"); shift ;;
    *)  if [ -z "$BRANCH" ]; then BRANCH="$1"; shift
        else err "unexpected argument: $1 (one branch at a time)"; exit 1; fi ;;
  esac
done

[ -n "$BRANCH" ] || { err "branch required"; usage; exit 1; }
BRANCH="${BRANCH#origin/}"                       # tolerate a pasted origin/… name
BRANCH="${BRANCH#refs/heads/}"
case "$BRANCH" in
  "$BRANCH_PREFIX"*) ;;
  *) err "branch must start with ${BRANCH_PREFIX} — '$BRANCH' cannot map to a ${BRANCH_PREFIX}<task> worktree"
     err "  a branch outside that scheme has to be checked out by hand: git -C packages/<repo> worktree add …"
     exit 1 ;;
esac
TASK="${BRANCH#"$BRANCH_PREFIX"}"
[ -n "$TASK" ] || { err "branch '$BRANCH' has no task part after ${BRANCH_PREFIX}"; exit 1; }

if [ -z "$REPOS" ]; then
  err "--repo <name> required (see: $WT repos)"
  err "  this script does not guess from cwd — it deletes refs, so it names its targets"
  exit 1
fi

# ------------------------------------------------------------------ helpers ----

ref_exists()  { git -C "$ROOT/$1" show-ref --verify --quiet "$2"; }
say_dry()     { [ "$DRY" = 1 ] && printf '  %s(dry-run)%s %s\n' "$c_ylw" "$c_off" "$*" || true; }

# The repo's own base branch: repos.json wins over origin/HEAD, like `wt`.
base_of() {
  local repo="$1" b=""
  if [ -f "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
    b="$(jq -r --arg r "$repo" '.repos[$r].branch // empty' "$MANIFEST" 2>/dev/null || true)"
  fi
  if [ -z "$b" ]; then
    b="$(git -C "$ROOT/$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    b="${b#origin/}"
  fi
  printf '%s\n' "$b"
}

# Is <sha> already contained in some origin ref? Checked against the adopted
# branch, the blocker's own remote namesake, the repo's base and its personal
# base <owner>-<base> (resolve_task_base, commit-and-mr/lib.sh) — being an
# ancestor of any of them means deleting the local branch loses no commit.
contained_in_origin() {
  local repo="$1" sha="$2" name="$3" cand base tbase=""
  base="$(base_of "$repo")"
  [ -z "$base" ] || tbase="$(resolve_task_base "$WS" "$repo" "$base")" || tbase=""
  [ "$tbase" != "$base" ] || tbase=""
  for cand in "origin/$BRANCH" "origin/$name" ${base:+"origin/$base"} ${tbase:+"origin/$tbase"}; do
    git -C "$ROOT/$repo" rev-parse --verify --quiet "$cand" >/dev/null 2>&1 || continue
    if git -C "$ROOT/$repo" merge-base --is-ancestor "$sha" "$cand" 2>/dev/null; then
      printf '%s\n' "$cand"; return 0
    fi
  done
  return 1
}

# The checkout a local branch is registered to, empty when it has none.
worktree_of_branch() {
  local repo="$1" branch="$2"
  git -C "$ROOT/$repo" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
    /^worktree /  { dir = substr($0, 10) }
    /^branch /    { if (substr($0, 8) == b) { print dir; exit } }'
}

# Every strict ancestor of the branch path, longest first: a/b/c -> a/b, a.
name_prefixes() {
  local p="$1"
  while case "$p" in */*) true ;; *) false ;; esac; do
    p="${p%/*}"
    printf '%s\n' "$p"
  done
}

# Delete a local branch that blocks the name, after proving it is recoverable.
# Returns 1 when it refuses — the caller then skips the repo.
drop_blocker() {
  local repo="$1" name="$2" sha where
  sha="$(git -C "$ROOT/$repo" rev-parse --short "refs/heads/$name")"
  if where="$(contained_in_origin "$repo" "$sha" "$name")"; then
    info "  blocking branch '$name' ($sha) is contained in $where — deleting"
  elif [ "$DROP_UNMERGED" = 1 ]; then
    warn "  blocking branch '$name' ($sha) is on NO origin ref — deleting anyway (--drop-unmerged)"
    warn "    recover with: git -C packages/$repo branch $name $sha"
  else
    err "  blocking branch '$name' ($sha) has commits on no origin ref — refusing to delete it"
    err "    it occupies the name '$name', so refs/heads/$BRANCH cannot be created"
    err "    push it, or re-run with --drop-unmerged (sha above is the way back)"
    return 1
  fi
  if [ "$DRY" = 1 ]; then say_dry "git -C packages/$repo branch -d $name"; return 0; fi
  # -d first: git's own merged-check is a second opinion on ours. When it says no
  # (no upstream, not merged into the current HEAD) our containment proof stands,
  # so -D is the honest follow-up — with the sha already printed above.
  git -C "$ROOT/$repo" branch -d "$name" 2>/dev/null \
    || git -C "$ROOT/$repo" branch -D "$name" >/dev/null
  return 0
}

# -------------------------------------------------------------------- main -----

adopt_one() {
  local repo="$1"
  local dir="$WT_ROOT/$TASK/$repo"

  printf '%s== %s ==%s\n' "$c_grn" "$repo" "$c_off"
  [ -d "$ROOT/$repo" ] || { err "  no such directory under packages/: $repo (run: $WT clone $repo)"; return 1; }
  git -C "$ROOT/$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || { err "  packages/$repo is not a git repo"; return 1; }

  # 1. The remote branch has to be there — that is the whole premise.
  gl_use_repo "$repo"
  if ! gl_fetch "$ROOT/$repo" "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" --quiet >/dev/null 2>&1; then
    if [ "${GL_GIT_LOGGED_OUT:-0}" = 1 ]; then
      warn "  fetch of origin/$BRANCH refused: GITHUB_TOKEN is missing — $(gl_gh_login_hint "${GL_TRANSPORT_HOST:-}")"
      warn "  NEXT=${GL_NEXT:-}"
    fi
    warn "  fetch of origin/$BRANCH failed (offline, or no such branch) — falling back to the local ref"
    # The same name conflict, one namespace over: a leftover refs/remotes/origin/<prefix>
    # (the flat branch was deleted on origin) blocks writing the nested ref too.
    local rp
    while IFS= read -r rp; do
      [ -n "$rp" ] || continue
      ref_exists "$repo" "refs/remotes/origin/$rp" || continue
      warn "    refs/remotes/origin/$rp occupies the name — if that branch is gone from origin:"
      warn "      git -C packages/$repo remote prune origin"
      break
    done < <(name_prefixes "$BRANCH")
  fi
  if ! ref_exists "$repo" "refs/remotes/origin/$BRANCH"; then
    err "  origin/$BRANCH does not exist for this repo"
    err "    for a NEW branch: $WT new $TASK --repo $repo --pull"
    return 1
  fi

  # The target path being taken by a checkout of this very branch is the goal
  # state, not a collision — re-running has to be a no-op, not an error.
  if [ -e "$dir" ]; then
    if [ "$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" = "$BRANCH" ]; then
      info "  already checked out at $dir — nothing to do"
      return 0
    fi
    err "  path already exists and is not a $BRANCH checkout: $dir"
    return 1
  fi

  # 2. Dead registrations first, or a branch whose directory somebody deleted by
  #    hand still counts as checked out and nothing below can touch it.
  if [ "$DRY" = 1 ]; then
    # `worktree prune -v` reports on stderr, dry-run included.
    local pruneable; pruneable="$(git -C "$ROOT/$repo" worktree prune -n -v 2>&1 || true)"
    [ -n "$pruneable" ] && say_dry "worktree prune would drop: $(echo "$pruneable" | tr '\n' ' ')" || true
  else
    git -C "$ROOT/$repo" worktree prune
  fi

  # 3a. The branch may already be local. Reuse it when there is a checkout,
  #     recreate it when it is a leftover, refuse when it holds unpushed work.
  if ref_exists "$repo" "refs/heads/$BRANCH"; then
    # A registration whose directory is gone is not a checkout — and in --dry-run
    # the prune above did not run, so `worktree list` still reports it.
    local existing; existing="$(worktree_of_branch "$repo" "$BRANCH")"
    if [ -n "$existing" ] && [ -d "$existing" ]; then
      info "  already checked out at $existing — nothing to do"
      return 0
    fi
    [ -n "$existing" ] && say_dry "worktree prune would drop the dead registration at $existing" || true
    local sha where; sha="$(git -C "$ROOT/$repo" rev-parse --short "refs/heads/$BRANCH")"
    if where="$(contained_in_origin "$repo" "$sha" "$BRANCH")"; then
      info "  local '$BRANCH' ($sha) has no worktree and is contained in $where — recreating it from origin"
      if [ "$DRY" = 1 ]; then say_dry "git -C packages/$repo branch -D $BRANCH"
      else git -C "$ROOT/$repo" branch -D "$BRANCH" >/dev/null; fi
    else
      err "  local '$BRANCH' ($sha) has commits on no origin ref and no worktree — not touching it"
      err "    check it out by hand: git -C packages/$repo worktree add $dir $BRANCH"
      return 1
    fi
  fi

  # 3b. The reverse name clash: refs/heads/<branch>/… below the name we want.
  #     Deleting a whole subtree of branches is not something to automate.
  local below; below="$(git -C "$ROOT/$repo" for-each-ref --format='%(refname:short)' "refs/heads/$BRANCH/**" | tr '\n' ' ')"
  if [ -n "${below// /}" ]; then
    err "  '$BRANCH' cannot be a branch here: these local branches live under that name: ${below% }"
    err "    delete or rename them first (they are the directory that blocks the file)"
    return 1
  fi

  # 3c. The blockers from the recipe: a flat local branch on a prefix of the name.
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ref_exists "$repo" "refs/heads/$p" || continue
    drop_blocker "$repo" "$p" || return 1
  done < <(name_prefixes "$BRANCH")

  # 4. The .env*/node_modules of the worktree come from packages/<repo>, and --allow-stale
  #    turns off the check that would have said so. Say it here instead.
  local base behind
  base="$(base_of "$repo")"
  if [ -n "$base" ] && ref_exists "$repo" "refs/remotes/origin/$base"; then
    behind="$(git -C "$ROOT/$repo" rev-list --count "HEAD..origin/$base" 2>/dev/null || echo 0)"
    if [ "$behind" -gt 0 ]; then
      warn "  packages/$repo is $behind commit(s) behind origin/$base — the .env*/node_modules of"
      warn "    the worktree come from that tree: git -C packages/$repo pull"
    fi
  fi

  # 5. Over to wt, which owns everything about how a worktree is built.
  local -a cmd
  cmd=("$WT" new "$TASK" --repo "$repo" --base "$BRANCH" --allow-stale --no-always ${PASS[@]+"${PASS[@]}"})
  if [ "$DRY" = 1 ]; then say_dry "${cmd[*]}"; return 0; fi
  "${cmd[@]}" || return 1
  return 0
}

ok=""; bad=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  if adopt_one "$r"; then ok="$ok $r"; else bad="$bad $r"; fi
done <<< "$REPOS"

# The "always" repos are excluded by --no-always; whether that cost anything
# depends on whether they carry this branch at all, so look instead of guessing.
if [ -f "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    case " $ok $bad " in *" $a "*) continue ;; esac
    [ -d "$ROOT/$a" ] || continue
    if git -C "$ROOT/$a" rev-parse --verify --quiet "origin/$BRANCH" >/dev/null 2>&1; then
      info "'$a' also has origin/$BRANCH — add it with: $SELF $BRANCH --repo $a"
    else
      warn "'$a' skipped (--no-always): it has no $BRANCH. If the task needs it: $WT new $TASK --repo $a"
    fi
  done < <(jq -r '.always[]? // empty' "$MANIFEST" 2>/dev/null || true)
fi

echo
if [ -n "$ok" ]; then
  [ "$DRY" = 1 ] && warn "(dry-run) would adopt:$ok  ->  $WT_ROOT/$TASK" \
                 || info "adopted:$ok  ->  $WT_ROOT/$TASK"
fi

# Adopting is by definition picking up somebody else's branch, so answer the
# first question that branch raises: which spec was its code written against.
SPEC_REF="$ROOT/.claude/skills/spec-trace/spec-ref.sh"
if [ "$DRY" != 1 ] && [ -n "$ok" ] && [ -x "$SPEC_REF" ]; then
  # Код 2 ловится отдельно: это «в задаче несколько spec store, и чей этот —
  # неизвестно», а не «спеки нет». Свёрнутый в пустой вывод, он печатал бы
  # «локально не нашлась» ровно там, где спека есть, — и адоптивший ветку
  # пошёл бы искать её в MR вместо того, чтобы назвать субъект.
  spec_err_file="$(mktemp)"
  spec_rc=0
  spec_out="$("$SPEC_REF" --task "$TASK" --markdown 2>"$spec_err_file")" || spec_rc=$?
  spec_err="$(cat "$spec_err_file")"
  rm -f "$spec_err_file"

  if [ "$spec_rc" = 2 ]; then
    echo
    warn "спека: в задаче несколько spec store — выбрать за тебя скрипт не вправе:"
    printf '%s\n' "$spec_err" >&2
  elif [ -n "$spec_out" ]; then
    echo
    info "спека этой ветки:"
    printf '%s\n' "$spec_out"
  else
    info "спека: локально не нашлась — смотри блок «Спека» в описании MR или"
    info "  git -C $WT_ROOT/$TASK/<repo> log -1 --pretty='%(trailers:key=Spec)'"
  fi
fi
[ -n "$bad" ] && { err "failed:$bad"; exit 1; }
exit 0
