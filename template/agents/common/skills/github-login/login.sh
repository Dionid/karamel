#!/usr/bin/env bash
# Validate the configured token; never launch login or save credentials.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../commit-and-mr/lib.sh
. "$script_dir/../commit-and-mr/lib.sh"
worktree=. hostname=github.com
case "${1-}" in check|status) shift ;; '') ;; -*) ;; *) echo 'usage: login.sh [check|status] [--worktree <path>] [--hostname github.com]' >&2; exit 2 ;; esac
while (($#)); do
  case "$1" in
    --worktree) worktree="${2-}"; shift 2 ;;
    --hostname) hostname="${2-}"; shift 2 ;;
    *) echo 'error: unsupported argument' >&2; exit 2 ;;
  esac
done
root="$(find_workspace_root "$worktree")" || { echo 'STATE=error REASON=no-workspace-root'; exit 1; }
gl_load "$root" || { echo 'STATE=error REASON=invalid-env'; exit 1; }
rc=0
gl_require_gh "$hostname" || rc=$?
case "$rc" in
  0) printf 'STATE=ok HOST=%s USER=%s\n' "$GL_GH_HOST" "$GL_GH_USER" ;;
  1) echo 'STATE=error REASON=gh-missing'; exit 1 ;;
  2) echo 'STATE=error REASON=network-or-response'; exit 1 ;;
  3) echo 'STATE=missing REASON=set-GITHUB_TOKEN-in-environment-or-root-env'; exit 3 ;;
  4) echo 'STATE=refused REASON=invalid-or-insufficient-GITHUB_TOKEN'; exit 4 ;;
esac
