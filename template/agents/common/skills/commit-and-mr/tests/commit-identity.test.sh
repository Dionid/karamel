#!/usr/bin/env bash
#
# Who signs the commit run.sh makes.
#
# GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL to the real requester and git uses them for
# the AUTHOR on its own — that half was never broken. The COMMITTER fell through
# to the checkout's git config, which in this runtime is one shared
# ~/.gitconfig naming the agent. A GitHub instance with a committer-email push
# rule then rejects the push, after the commit is made and after run.sh has
# nothing left to stage, so the only evidence of the regression used to be a
# remote rejection in someone's terminal.
#
# Both directions are checked against the commit run.sh actually produces, not
# against preflight.sh's advisory line: the env case must carry the requester on
# BOTH trailers, and the no-env case must stay exactly as it was, on the
# checkout's own config.
#
# No network: `origin` is a GitHub URL so the script's project parsing is the
# real one, while `remote.origin.pushurl` sends the push to a local bare repo.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
run_sh="$script_dir/../run.sh"

failures=0

check() {
  local name expected actual
  name="$1"
  expected="$2"
  actual="$3"

  if [[ "$expected" == "$actual" ]]; then
    printf '  ok   %s\n' "$name"
  else
    printf '  FAIL %s\n' "$name"
    printf '    expected: %q\n' "$expected"
    printf '    actual:   %q\n' "$actual"
    failures=$((failures + 1))
  fi
}

command -v jq > /dev/null 2>&1 || {
  printf 'commit-identity: jq is required\n' >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ws="$tmp/ws"
wt="$ws/worktrees/t/project"
mkdir -p "$wt"
printf '{}\n' > "$ws/harness.json"
cat > "$ws/repos.json" <<'JSON'
{ "repos": { "project": { "branch": "main", "url": "git@github.com:group/project.git" } } }
JSON

# The shared global config is exactly what this test is about, so it is cut out:
# whatever the committer turns out to be, it came from this checkout or from the
# environment, not from the machine running the test.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

agent_name="managed runtime agent"
agent_mail="platform-agent@users.noreply.github.com"
human_name="Real Requester"
human_mail="real.requester@example.invalid"

git init --quiet --bare "$tmp/origin.git"
git init --quiet -b main "$wt"
git -C "$wt" config user.name "$agent_name"
git -C "$wt" config user.email "$agent_mail"
git -C "$wt" remote add origin git@github.com:group/project.git
: > "$wt/seed"
git -C "$wt" add seed
git -C "$wt" commit --quiet -m seed
git -C "$wt" checkout --quiet -b feature/t

printf 'feat: change\n' > "$tmp/msg"

# Keep real GitHub origin validation and replace only the network operation.
# The fixture forwards pushes to a local bare repo after the shared guard runs.
mkdir -p "$tmp/bin" "$tmp/gh-state"
real_git="$(command -v git)"
cat > "$tmp/bin/git" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then
    branch="\$("$real_git" -C "$wt" branch --show-current)"
    exec "$real_git" -C "$wt" push -qu "$tmp/origin.git" "\$branch"
  fi
done
exec "$real_git" "\$@"
SH
chmod +x "$tmp/bin/git"
ln -s "$script_dir/fake-gh" "$tmp/bin/gh"
export GITHUB_TOKEN=identity-regression-secret FAKE_GH_STATE="$tmp/gh-state"

n=0
run() {
  n=$((n + 1))
  printf '%s\n' "$n" > "$wt/file"
  (
    cd "$ws" || exit 1
    # The fake git forwards the validated GitHub push to the local fixture.
    PATH="$tmp/bin:$PATH" env "$@" \
      bash "$run_sh" \
      --worktree "$wt" --repo project --message-file "$tmp/msg" \
      --no-mr --no-coauthor --no-spec-link -- file
  )
}

author_of() { git -C "$wt" log -1 --format='%an <%ae>'; }
committer_of() { git -C "$wt" log -1 --format='%cn <%ce>'; }

# ---------------------------------------------------------- the real requester
#
# green committer here can only have come from run.sh.
if run env -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  GIT_AUTHOR_NAME="$human_name" GIT_AUTHOR_EMAIL="$human_mail" \
  > /dev/null 2>&1; then
  check "env identity: author is the requester" "$human_name <$human_mail>" "$(author_of)"
  check "env identity: committer is the requester too" \
    "$human_name <$human_mail>" "$(committer_of)"
else
  check "run.sh succeeds with an env identity" "exit 0" "non-zero"
fi

# ------------------------------------------------------------- nothing in env
#
# Unchanged behaviour: the checkout's own git config signs both halves.
if run env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL \
  -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  > /dev/null 2>&1; then
  check "no env identity: author is the checkout config" \
    "$agent_name <$agent_mail>" "$(author_of)"
  check "no env identity: committer is the checkout config" \
    "$agent_name <$agent_mail>" "$(committer_of)"
else
  check "run.sh succeeds without an env identity" "exit 0" "non-zero"
fi

# --------------------------------------------------------------- half an env
#
# Only one of the pair is set. git's own fallback already mixes the environment
# with the config for the author; the committer must not be invented from half
# an identity, so it stays on the config — and run.sh's condition and
# preflight.sh's report agree on that.
if run env -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL \
  GIT_AUTHOR_NAME="$human_name" > /dev/null 2>&1; then
  check "half an env identity: committer stays on the config" \
    "$agent_name <$agent_mail>" "$(committer_of)"
else
  check "run.sh succeeds with half an env identity" "exit 0" "non-zero"
fi

# ------------------------------------------------- a committer set on purpose
#
# The author pair is set exactly as in the first case, but the committer is
# spoken for. run.sh fills the committer in; it does not take it over. The email
# is the half a GitHub push rule judges, so it is the half asserted here — and
# the name stays on the config, because half a deliberate identity is not an
# identity either.
preset_mail="deliberate@example.invalid"
if run env -u GIT_COMMITTER_NAME \
  GIT_AUTHOR_NAME="$human_name" GIT_AUTHOR_EMAIL="$human_mail" \
  GIT_COMMITTER_EMAIL="$preset_mail" > /dev/null 2>&1; then
  check "preset committer: the email set on purpose survives" \
    "$preset_mail" "$(git -C "$wt" log -1 --format='%ce')"
  check "preset committer: the author is still the requester" \
    "$human_name <$human_mail>" "$(author_of)"
  check "preset committer: the name is not taken over either" \
    "$agent_name" "$(git -C "$wt" log -1 --format='%cn')"
else
  check "run.sh succeeds with a preset committer email" "exit 0" "non-zero"
fi

if ((failures)); then
  printf '%d check(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'commit-identity: all checks passed\n'
