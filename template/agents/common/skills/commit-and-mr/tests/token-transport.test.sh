#!/usr/bin/env bash
# Token precedence, inert dotenv, HTTPS-only commands and access failure gates.
set -euo pipefail
skill="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
. "$skill/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/workspace"
printf '{}\n' > "$tmp/workspace/harness.json"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GITHUB_TOKEN-}" == "${EXPECTED_TOKEN-}" && "${GH_TOKEN-}" == "${EXPECTED_TOKEN-}" ]] || exit 90
[[ "${GH_PROMPT_DISABLED-}" == 1 && "${GH_HOST-}" == github.com && -z "${GH_DEBUG-}" ]] || exit 91
printf 'called\n' >> "$AUTH_CALLS"
case "${AUTH_MODE:-ok}" in
  ok) echo fixture-user ;;
  refused) echo 'HTTP 401 Bad credentials' >&2; exit 1 ;;
  net) echo 'dial tcp: connection refused' >&2; exit 1 ;;
  leak) printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" >&2; exit 1 ;;
esac
SH
cat > "$tmp/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GH_TOKEN-}" == "$EXPECTED_TOKEN" && "${GIT_TERMINAL_PROMPT-}" == 0 ]] || exit 92
printf '%s\n' "$@" >> "$GIT_CALLS"
case "${GIT_MODE:-ok}" in fail) echo 'Authentication failed' >&2; exit 128 ;; esac
printf 'fixture-result\n'
SH
chmod +x "$tmp/bin/gh" "$tmp/bin/git"
export PATH="$tmp/bin:$PATH" AUTH_CALLS="$tmp/auth" GIT_CALLS="$tmp/git"
export GH_TOKEN=wrong GH_DEBUG=api
printf 'GITHUB_TOKEN=from-file\nNOTION_TOKEN=from-notion\nPATH=/untrusted\n' > "$tmp/workspace/.env"
unset GITHUB_TOKEN
export EXPECTED_TOKEN=from-file
gl_load "$tmp/workspace"
[[ "$GITHUB_TOKEN" == from-file && "$NOTION_TOKEN" == from-notion && "$PATH" != /untrusted ]]
gl_require_gh
[[ "$GL_GH_USER" == fixture-user ]]
export GITHUB_TOKEN=from-process EXPECTED_TOKEN=from-process
gl_load "$tmp/workspace"
gl_require_gh
# Empty is a deliberate process setting and must not import a shared token.
export GITHUB_TOKEN=''
gl_load "$tmp/workspace"
rc=0; gl_require_gh || rc=$?
[[ "$rc" == 3 && "$GL_NEXT" == github-login ]]
[[ "$(wc -l < "$AUTH_CALLS" | tr -d ' ')" == 2 ]]
# Parse literal shell syntax rather than executing it or importing arbitrary names.
printf '%s\n' "GITHUB_TOKEN='\$(touch $tmp/executed)'" 'NOTION_TOKEN=literal' > "$tmp/workspace/.env"
unset GITHUB_TOKEN NOTION_TOKEN
gl_load "$tmp/workspace"
[[ ! -e "$tmp/executed" && "$GITHUB_TOKEN" == "\$(touch $tmp/executed)" ]]
export EXPECTED_TOKEN="$GITHUB_TOKEN"
gl_require_gh
# A single token drives all remote operations, using HTTPS and an isolated helper.
export GITHUB_TOKEN=transport EXPECTED_TOKEN=transport
for url in https://github.com/org/repo.git git@github.com:org/repo.git ssh://git@github.com/org/repo.git; do
  gl_git_url "$url" ls-remote "$url" >/dev/null
  [[ "$GL_TRANSPORT" == https-gh && "$GL_GIT_AUTH_FAILED" == 0 ]]
done
grep -qFx 'credential.helper=' "$GIT_CALLS"
grep -qFx 'credential.helper=!gh auth git-credential' "$GIT_CALLS"
grep -qFx 'protocol.allow=never' "$GIT_CALLS"
grep -qFx 'protocol.https.allow=always' "$GIT_CALLS"
grep -qFx 'url.https://github.com/.insteadOf=git@github.com:' "$GIT_CALLS"
rc=0; AUTH_MODE=refused gl_git_url https://github.com/org/repo.git ls-remote https://github.com/org/repo.git || rc=$?
[[ "$rc" == 4 && "$GL_GIT_AUTH_FAILED" == 1 && "$GL_TRANSPORT" == none ]]
rc=0; AUTH_MODE=net gl_git_url https://github.com/org/repo.git ls-remote https://github.com/org/repo.git || rc=$?
[[ "$rc" == 2 && "$GL_GIT_AUTH_FAILED" == 0 && "$GL_TRANSPORT" == none ]]
rc=0; GIT_MODE=fail gl_git_url https://github.com/org/repo.git ls-remote https://github.com/org/repo.git || rc=$?
[[ "$rc" == 128 && "$GL_GIT_AUTH_FAILED" == 1 ]]
for url in https://other.example/org/repo.git https://github.com.evil/org/repo.git https://user:password@github.com/org/repo.git http://github.com/org/repo.git https://github.com/org/repo/extra https://github.com/org/repo.git?token=fixture https://github.com/org/repo.git#fixture; do
  if gl_remote_is_github "$url"; then echo 'unsupported repository accepted' >&2; exit 1; fi
done
# Failed gh output cannot expose the exact configured token.
leak="$(AUTH_MODE=leak gl_gh_env gh api user 2>&1)" && exit 1
[[ "$leak" == *'<redacted>'* && "$leak" != *"$GITHUB_TOKEN"* ]]
# Unsupported hosts are rejected before invoking either executable.
before="$(wc -l < "$AUTH_CALLS")"
if gl_git_url https://other.example/org/repo.git ls-remote https://other.example/org/repo.git; then exit 1; fi
[[ "$(wc -l < "$AUTH_CALLS")" == "$before" ]]
# Malformed selected dotenv fails, never prints the assignment value.
printf 'GITHUB_TOKEN="unterminated\n' > "$tmp/workspace/.env"
if gl_load "$tmp/workspace" 2>"$tmp/error"; then echo 'malformed env accepted' >&2; exit 1; fi
! grep -q unterminated "$tmp/error"
echo 'token transport: all checks passed'

# The token belongs to the owning workspace, even when a task checkout carries
# its own tracked marker or an accidental generated harness marker.
mkdir -p "$tmp/owner/worktrees/task/repo"
printf '{}\n' > "$tmp/owner/harness.json"
printf '{}\n' > "$tmp/owner/worktrees/task/repo/workspace.json"
printf '{}\n' > "$tmp/owner/worktrees/task/repo/harness.json"
printf 'GITHUB_TOKEN=owning-workspace-secret\n' > "$tmp/owner/.env"
printf 'GITHUB_TOKEN=wrong-nested-secret\n' > "$tmp/owner/worktrees/task/repo/.env"
unset GITHUB_TOKEN
gl_load "$tmp/owner/worktrees/task/repo"
[[ "$GITHUB_TOKEN" == owning-workspace-secret && "$GL_WORKSPACE_ROOT" == "$tmp/owner" ]]
echo 'owning workspace token resolution: passed'
