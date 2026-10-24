#!/usr/bin/env bash
# Public login/preflight interfaces: no saved credentials, no network required.
set -euo pipefail
skill="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/ws/worktrees/test/project" "$tmp/state"
checkout="$tmp/ws/worktrees/test/project"
printf '{}\n' > "$tmp/ws/harness.json"
git init -q -b feature/test "$checkout"
git -C "$checkout" config user.name Tester
git -C "$checkout" config user.email tester@example.invalid
git -C "$checkout" remote add origin https://github.com/org/project.git
real_git="$(command -v git)"
cat > "$tmp/bin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then
    printf '%s\\n' "\$@" >> "$tmp/pushes"
    exit 0
  fi
done
exec "$real_git" "\$@"
SH
chmod +x "$tmp/bin/git"
ln -s "$skill/tests/fake-gh" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" FAKE_GH_STATE="$tmp/state" GH_TOKEN=wrong
unset GITHUB_TOKEN
printf 'GITHUB_TOKEN=fixture\n' > "$tmp/ws/.env"
out="$(bash "$skill/../github-login/login.sh" check --worktree "$checkout")"
[[ "$out" == 'STATE=ok HOST=github.com USER=fake-user' ]]
out="$(bash "$skill/preflight.sh" --worktree "$checkout" --repo project)"
grep -q '^PREFLIGHT=ok TRANSPORT=https-gh$' <<<"$out"
grep -q '^GH=ok HOST=github.com USER=fake-user$' <<<"$out"
grep -q '^--dry-run$' "$tmp/pushes"
before="$(wc -l < "$tmp/pushes")"
rc=0; out="$(GITHUB_TOKEN='' bash "$skill/preflight.sh" --worktree "$checkout" 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" == *'NEXT=github-login'* ]]
[[ "$(wc -l < "$tmp/pushes")" == "$before" ]]
rc=0; out="$(GITHUB_TOKEN='' bash "$skill/../github-login/login.sh" status --worktree "$checkout" 2>&1)" || rc=$?
[[ "$rc" == 3 && "$out" == *'STATE=missing'* ]]
rc=0; out="$(FAKE_GH_AUTH=revoked bash "$skill/../github-login/login.sh" check --worktree "$checkout" 2>&1)" || rc=$?
[[ "$rc" == 4 && "$out" == *'STATE=refused'* ]]
# Invalid remote must fail before any API or push call.
git -C "$checkout" remote set-url origin https://other.example/org/project.git
calls="$(wc -l < "$tmp/state/log")"
if bash "$skill/preflight.sh" --worktree "$checkout" >/dev/null 2>&1; then exit 1; fi
[[ "$(wc -l < "$tmp/state/log")" == "$calls" ]]
echo 'login and preflight: all checks passed'
