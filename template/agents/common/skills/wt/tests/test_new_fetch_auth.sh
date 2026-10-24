#!/usr/bin/env bash
# `wt new` при упавшем fetch origin/<base>: отказ аутентификации — не «офлайн».
# Сеть ответила, packages/<repo> просто устарел, и ветвиться от локального
# origin/<base> значит молча начать задачу со старой базы. Поэтому отказ gh
# останавливает `wt new … --pull`. Настоящая сетевая ошибка по-прежнему
# откатывается на локальный ref. git-заглушка отвечает на fetch нужной ошибкой;
# сети нет.
set -euo pipefail
# The fix a missing login names depends on the runtime; these checks are the
# laptop's, so an managed runtime session running the suite must not flip them.
unset AGENT_SESSION_ID

ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/workspace"
mkdir -p "$WS/agents/common/skills/wt" "$WS/agents/common/skills/commit-and-mr" \
  "$WS/agents/common/skills/clone" "$WS/packages" "$TMP/bin"
printf '{}\n' > "$WS/harness.json"
printf '{"repos":{"demo":{"url":"git@github.com:team/demo.git","branch":"main","deps":"none"}}}\n' > "$WS/repos.json"
cp "$ROOT/agents/common/skills/wt/wt" "$WS/agents/common/skills/wt/wt"
cp "$ROOT/agents/common/skills/commit-and-mr/lib.sh" "$WS/agents/common/skills/commit-and-mr/lib.sh"
cp "$ROOT/agents/common/skills/commit-and-mr/"{env.py,redact.py} "$WS/agents/common/skills/commit-and-mr/"
# packages/demo уже на месте: клонировать нечего.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/agents/common/skills/clone/ensure-repository"
chmod +x "$WS/agents/common/skills/clone/ensure-repository"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

git init --quiet -b main "$TMP/seed"
printf 'base\n' > "$TMP/seed/base"
git -C "$TMP/seed" add base
git -C "$TMP/seed" commit --quiet -m base
git clone --quiet "$TMP/seed" "$WS/packages/demo"
# A GitHub origin, so gl_fetch goes through the gh transport.
git -C "$WS/packages/demo" remote set-url origin git@github.com:team/demo.git

real_git="$(command -v git)"
cat > "$TMP/bin/git" <<EOF
#!/usr/bin/env bash
https=0
for a in "\$@"; do
  [ "\$a" != 'credential.helper=!gh auth git-credential' ] || https=1
done
for a in "\$@"; do
  if [ "\$a" = fetch ]; then
    case "\${STUB_FETCH:-ok}" in
      auth) echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2; exit 128 ;;
      net)  echo "fatal: unable to access 'https://github.com/team/demo.git/': Could not resolve host: github.com" >&2; exit 128 ;;
      *)    exit 0 ;;
    esac
  fi
done
exec "$real_git" "\$@"
EOF
chmod +x "$TMP/bin/git"
# gh is token-backed; no keyring or alternate transport is consulted.
printf '#!/usr/bin/env bash\nprintf "fixture-user\\n"\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
export GITHUB_TOKEN=test-canonical-secret

run() { (cd "$WS" && PATH="$TMP/bin:$PATH" bash agents/common/skills/wt/wt "$@"); }
fail() { echo "FAIL: $*" >&2; exit 1; }

# Authentication refused: --pull stops, names the fix, creates nothing.
if out="$(STUB_FETCH=auth run new authtask --repo demo --pull 2>&1)"; then
  fail "wt new --pull succeeded after an auth failure: $out"
fi
grep -q 'GitHub authentication failed' <<< "$out" || fail "auth failure not named: $out"
grep -q 'GITHUB_TOKEN' <<< "$out" || fail "no gh login hint: $out"
grep -q 'offline' <<< "$out" && fail "auth failure called offline: $out"
[ ! -e "$WS/worktrees/authtask/demo" ] || fail "worktree created after an auth failure"

# Without --pull the stale base is refused too, unless --allow-stale accepts it.
if STUB_FETCH=auth run new authtask2 --repo demo >/dev/null 2>&1; then
  fail "wt new succeeded after an auth failure without --allow-stale"
fi
out="$(STUB_FETCH=auth run new staletask --repo demo --allow-stale 2>&1)" \
  || fail "--allow-stale did not proceed after an auth failure: $out"
grep -q 'freshness unknown' <<< "$out" || fail "--allow-stale did not say what it accepted: $out"
[ -d "$WS/worktrees/staletask/demo" ] || fail "--allow-stale created no worktree"

# Missing canonical token refuses before fetch even with gh available.
if out="$(GITHUB_TOKEN='' STUB_FETCH=ok run new missing --repo demo --pull 2>&1)"; then
  fail "missing GITHUB_TOKEN accepted: $out"
fi
grep -q GITHUB_TOKEN <<< "$out" || fail "missing token hint absent: $out"
[ ! -e "$WS/worktrees/missing/demo" ] || fail "missing token created a worktree"

# A real network failure keeps the offline fallback.
out="$(STUB_FETCH=net run new nettask --repo demo --pull 2>&1)" \
  || fail "wt new --pull failed on a network error: $out"
grep -q 'fetch failed (offline?)' <<< "$out" || fail "network failure not reported as offline: $out"
[ -d "$WS/worktrees/nettask/demo" ] || fail "network fallback created no worktree"

echo "ok: wt new tells a refused GitHub login from a network failure"
