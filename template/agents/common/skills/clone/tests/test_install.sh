#!/usr/bin/env bash
#
# `clone.sh --install` in a workspace that is already cloned.
#
# Two regressions, both silent: the flag used to return at the "already present"
# check before it ever reached the install block, so it installed nothing on any
# workspace past its first day; and the package manager was chosen from a
# lockfile alone, so a root `package-lock.json` with no `package.json` beside it
# ran `npm ci` in a directory that has nothing to install.
set -euo pipefail

# Same reason as test_origin_url.sh: the fixture must not inherit the caller's
# git configuration.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SRC="$ROOT/agents/common/skills/clone/clone.sh"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# A workspace of the shape clone.sh expects: it walks up from its own location
# to harness.json, so the script has to be copied, not symlinked.
CLONE="$TEST_ROOT/agents/common/skills/clone/clone.sh"
mkdir -p "$(dirname "$CLONE")" "$TEST_ROOT/bin"
cp "$SRC" "$CLONE"
chmod +x "$CLONE"
printf '{}\n' > "$TEST_ROOT/harness.json"

cat > "$TEST_ROOT/repos.json" <<'JSON'
{
  "repos": {
    "with-manifest": { "url": "git@example.com:acme/with-manifest.git", "branch": "main" },
    "lockfile-only": { "url": "git@example.com:acme/lockfile-only.git", "branch": "main" }
  }
}
JSON

# Both checkouts already exist, which is the case that used to skip the install.
mkdir -p "$TEST_ROOT/packages/with-manifest" "$TEST_ROOT/packages/lockfile-only"
printf '{"name":"with-manifest"}\n' > "$TEST_ROOT/packages/with-manifest/package.json"
printf '{}\n' > "$TEST_ROOT/packages/with-manifest/package-lock.json"
# The merchant-cabinet shape: a lockfile at the root, the project in app/.
printf '{}\n' > "$TEST_ROOT/packages/lockfile-only/package-lock.json"
mkdir -p "$TEST_ROOT/packages/lockfile-only/app"
printf '{"name":"app"}\n' > "$TEST_ROOT/packages/lockfile-only/app/package.json"

# A recording npm: the assertion is which directories it was invoked in.
cat > "$TEST_ROOT/bin/npm" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$PWD" "\$*" >> "$TEST_ROOT/npm-calls"
EOF
chmod +x "$TEST_ROOT/bin/npm"
: > "$TEST_ROOT/npm-calls"

out="$(PATH="$TEST_ROOT/bin:$PATH" "$CLONE" --install 2>&1)" || {
  echo "clone.sh --install failed:" >&2
  printf '%s\n' "$out" >&2
  exit 1
}

# 1. An existing checkout with a manifest is installed, not skipped.
grep -Fq "$TEST_ROOT/packages/with-manifest ci" "$TEST_ROOT/npm-calls" || {
  echo 'expected `npm ci` in the existing with-manifest checkout; --install did nothing' >&2
  printf 'npm calls:\n%s\n' "$(cat "$TEST_ROOT/npm-calls")" >&2
  printf 'output:\n%s\n' "$out" >&2
  exit 1
}

# 2. A lockfile with no package.json beside it installs nothing, and says so.
if grep -Fq "$TEST_ROOT/packages/lockfile-only " "$TEST_ROOT/npm-calls"; then
  echo 'expected no install in a root that has a lockfile but no package.json' >&2
  printf 'npm calls:\n%s\n' "$(cat "$TEST_ROOT/npm-calls")" >&2
  exit 1
fi
printf '%s\n' "$out" | grep -Fq '[lockfile-only] nothing to install (no package.json)' || {
  echo 'expected clone.sh to report that lockfile-only had nothing to install' >&2
  printf 'output:\n%s\n' "$out" >&2
  exit 1
}

# 3. Without --install nothing is installed at all.
: > "$TEST_ROOT/npm-calls"
PATH="$TEST_ROOT/bin:$PATH" "$CLONE" >/dev/null 2>&1
[ ! -s "$TEST_ROOT/npm-calls" ] || {
  echo 'clone.sh without --install must not install anything' >&2
  printf 'npm calls:\n%s\n' "$(cat "$TEST_ROOT/npm-calls")" >&2
  exit 1
}
