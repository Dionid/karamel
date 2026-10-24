#!/usr/bin/env bash
# Every push destination must be one unambiguous GitHub repository.
set -euo pipefail
skill="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
. "$skill/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/ws/worktrees/test/repo" "$tmp/state"
printf '{}\n' > "$tmp/ws/harness.json"
printf '{"repos":{"repo":{"branch":"main"}}}\n' > "$tmp/ws/repos.json"
checkout="$tmp/ws/worktrees/test/repo"
git init -q -b main "$checkout"
git -C "$checkout" config user.name Tester
git -C "$checkout" config user.email tester@example.test
git -C "$checkout" remote add origin https://github.com/org/repo.git
printf 'base\n' > "$checkout/file"
git -C "$checkout" add file
git -C "$checkout" commit -qm base
git -C "$checkout" switch -qc feature/test
printf 'changed\n' >> "$checkout/file"
printf 'test: remote guard\n' > "$tmp/message"
real_git="$(command -v git)"
cat > "$tmp/bin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then echo pushed >> "$tmp/pushes"; exit 0; fi
done
exec "$real_git" "\$@"
SH
chmod +x "$tmp/bin/git"
ln -s "$skill/tests/fake-gh" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GITHUB_TOKEN=regression-secret FAKE_GH_STATE="$tmp/state"
refuses() {
  if gl_origin_projects_match "$checkout"; then echo "accepted $1" >&2; exit 1; fi
  if gl_push "$checkout" feature/test >/dev/null 2>&1; then echo "standalone push accepted $1" >&2; exit 1; fi
  [[ ! -e "$tmp/pushes" ]]
  before="$(git -C "$checkout" rev-parse HEAD)"
  if bash "$skill/run.sh" --worktree "$checkout" --repo repo --message-file "$tmp/message" --no-mr -- file >/dev/null 2>&1; then
    echo "run staged/committed $1" >&2; exit 1
  fi
  [[ "$(git -C "$checkout" rev-parse HEAD)" == "$before" ]]
  git -C "$checkout" diff --cached --quiet
}
gl_origin_projects_match "$checkout"
git -C "$checkout" config --add remote.origin.pushurl https://github.com/org/repo.git
git -C "$checkout" config --add remote.origin.pushurl https://other.example/org/repo.git
refuses 'two push URLs'
git -C "$checkout" config --unset-all remote.origin.pushurl
git -C "$checkout" config --add remote.origin.url https://github.com/org/other.git
refuses 'multiple fallback origin URLs'
git -C "$checkout" config --unset-all remote.origin.url
git -C "$checkout" config --add remote.origin.url https://github.com/org/repo.git
git -C "$checkout" config 'url.https://other.example/.pushInsteadOf' https://github.com/
refuses 'effective push URL rewritten to another host'
git -C "$checkout" config --unset-all 'url.https://other.example/.pushInsteadOf'
gl_origin_projects_match "$checkout"
echo 'remote validation: duplicate and rewritten destinations refused before staging/pushing'
