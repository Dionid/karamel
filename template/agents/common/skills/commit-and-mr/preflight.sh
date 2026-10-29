#!/usr/bin/env bash
# Read-only identity, token access and HTTPS dry-run push checks.
set -uo pipefail
usage() {
  echo 'preflight.sh [--worktree <path>] [--repo <name>] [--quiet] [--transport auto|https]'
}
worktree=. repo='' quiet=0
while (($#)); do
  case "$1" in
    --worktree) worktree="${2-}"; shift 2 ;;
    --repo) repo="${2-}"; shift 2 ;;
    --quiet) quiet=1; shift ;;
    --transport) case "${2-}" in auto|https) ;; *) usage >&2; exit 2 ;; esac; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$script_dir/lib.sh"
root="$(find_workspace_root "$worktree")" || { echo 'error: no workspace root' >&2; exit 2; }
failed=0
note() { ((quiet)) || printf '%s\n' "$1"; }
fail() { printf '%s\n' "$1" >&2; failed=$((failed + 1)); }
name="${GIT_AUTHOR_NAME-}" mail="${GIT_AUTHOR_EMAIL-}" identity_source=env
if [[ -z "$name" || -z "$mail" ]]; then
  identity_source=config
  name="$(git -C "$worktree" config --get user.name 2>/dev/null || true)"
  mail="$(git -C "$worktree" config --get user.email 2>/dev/null || true)"
fi
if [[ -n "$name" && -n "$mail" ]]; then note "IDENTITY=ok ($identity_source) $name <$mail>";
else fail 'IDENTITY=missing — set GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL or user.name/user.email'; fi
if proj_of "$worktree"; then note "ORIGIN=$PROJ_HOST${repo:+ ($repo)}";
else fail 'ORIGIN=missing-or-unsupported'; fi
if ! gl_origin_projects_match "$worktree"; then fail 'ORIGIN=push-mismatch'; fi
if ((failed)); then printf 'PREFLIGHT=failed CHECKS_FAILED=%d\n' "$failed"; exit 1; fi
if ! gl_load "$root"; then fail 'ENV=invalid'; fi
rc=0
gl_require_gh "${PROJ_HOST:-github.com}" || rc=$?
case "$rc" in
  0) note "GH=ok HOST=$GL_GH_HOST USER=$GL_GH_USER" ;;
  1) fail 'GH=missing' ;;
  2) fail 'GH=unreachable' ;;
  3) fail 'GH=logged-out'; printf 'NEXT=github-login\n' ;;
  4) fail 'GH=refused' ;;
esac
branch="$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
# The PR target run.sh will use — the shared resolver, personal base included.
base=''
if [[ -n "$repo" ]]; then
  if base="$(resolve_task_base "$root" "$repo")"; then note "BASE=$base";
  else fail 'BASE=invalid-owner'; fi
fi
if [[ -z "$branch" ]]; then fail 'PUSH=detached';
elif [[ -n "$base" && "$branch" == "$base" ]]; then fail "PUSH=base-branch $branch";
elif ((failed == 0)); then
  if gl_push "$worktree" "$branch" --dry-run; then note "PUSH=ok $branch (${GL_TRANSPORT:-none})";
  else fail 'PUSH=failed'; fi
fi
if ((failed)); then printf 'PREFLIGHT=failed CHECKS_FAILED=%d\n' "$failed"; exit 1; fi
printf 'PREFLIGHT=ok TRANSPORT=%s\n' "${GL_TRANSPORT:-none}"
