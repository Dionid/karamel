#!/usr/bin/env bash
# The refresher writes the file the server refuses to boot without, so what is
# tested here is everything that can be checked without Slack: it must agree
# with the wrapper about the path, refuse rather than guess when the user token
# is absent, leave a warm cache alone, and map a conversation object into the
# shape the server actually reads.
set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT
: > "$WS/harness.json"
mkdir -p "$WS/.claude/skills/slack"
cp "$SKILL/refresh-cache.sh" "$SKILL/refresh_cache.py" "$SKILL/mcp-server.sh" \
   "$SKILL/lib.sh" "$WS/.claude/skills/slack/"
R="$WS/.claude/skills/slack/refresh-cache.sh"
W="$WS/.claude/skills/slack/mcp-server.sh"

CACHE="$WS/cache"
export SLACK_MCP_CACHE_DIR="$CACHE"

# An MCP server is spawned by the CLI, so cwd says nothing about the workspace.
cd /

run() {
  set +e
  out="$(env -u SLACK_MCP_XOXP_TOKEN -u SLACK_MCP_XOXB_TOKEN "$@" 2>&1)"
  rc=$?
  set -e
}

# --- the two scripts must resolve the same file ------------------------------
# They run in different processes - the wrapper exports the path to the server,
# the refresher writes it - and a disagreement is silent: both would report the
# truth about different files.
from_wrapper="$("$W" --print 2>&1 | sed -n 's/^channels cache .*(\(.*\))$/\1/p')"
from_refresh="$("$R" --print 2>&1 | sed -n 's/^channels cache .*(\(.*\))$/\1/p')"
[[ -n "$from_wrapper" && "$from_wrapper" == "$from_refresh" ]] || {
  echo "wrapper and refresher disagree: '$from_wrapper' vs '$from_refresh'" >&2; exit 1; }

# --print is the diagnostic an agent may run: no network, no token, no values.
run "$R" --print
[[ $rc -eq 0 ]] || { echo "--print must not need a token: $out" >&2; exit 1; }
grep -q "cache dir  *$CACHE" <<< "$out" || { echo "--print must show the dir: $out" >&2; exit 1; }
grep -q 'channels cache  *absent' <<< "$out" || { echo "--print must show presence: $out" >&2; exit 1; }

# --- a typo must not be read as "refresh everything" ------------------------
run "$R" --tpyes public_channel
[[ $rc -eq 2 ]] || { echo "an unknown argument must exit 2, got $rc: $out" >&2; exit 1; }

# --- no user token: refuse, and name the variable ---------------------------
# A bot token is deliberately not accepted as a substitute: conversations.list
# under xoxb returns only the channels the bot was invited to, which writes a
# cache that looks complete and hides every other channel.
cat > "$WS/.env" <<'ENV'
SLACK_MCP_XOXB_TOKEN=xoxb-a-bot-is-not-enough
ENV
run "$R"
[[ $rc -eq 3 ]] || { echo "a bot-only workspace must exit 3, got $rc: $out" >&2; exit 1; }
grep -q 'SLACK_MCP_XOXP_TOKEN' <<< "$out" || {
  echo "the refusal must name the variable to fill: $out" >&2; exit 1; }
grep -q 'xoxb-a-bot-is-not-enough' <<< "$out" && { echo "leaked a value: $out" >&2; exit 1; }

# --- a warm cache is left alone, without a token and without a request ------
# Twenty thousand API calls to rebuild what is already there is the failure
# mode of a refresher that is safe to re-run.
mkdir -p "$CACHE"
echo '[{"id":"C1","name":"general"}]' > "$CACHE/channels_cache_v2.json"
run "$R"
[[ $rc -eq 0 ]] || { echo "a warm cache must be a no-op, got $rc: $out" >&2; exit 1; }
grep -q 'nothing to do' <<< "$out" || { echo "and it must say so: $out" >&2; exit 1; }

# --force is the way past it, and with no user token it still refuses rather
# than pretending the rebuild happened.
run "$R" --force
[[ $rc -eq 3 ]] || { echo "--force must reach the token check, got $rc: $out" >&2; exit 1; }

# --- the shape written to disk ----------------------------------------------
# Read from the struct tags of the v1.3.0 binary; a wrong field name would
# produce a cache the server parses into empty channels, which boots and then
# resolves nothing.
python3 - "$WS/.claude/skills/slack" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rc", sys.argv[1] + "/refresh_cache.py")
rc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rc)

got = rc.convert({
    "id": "C04U4HM7QJZ", "name": "general", "is_private": False,
    "num_members": 307, "topic": {"value": ""},
    "purpose": {"value": "alerts"},
})
assert set(got) == {"id", "name", "topic", "purpose", "memberCount", "im", "mpim", "private"}, got
assert got["memberCount"] == 307 and got["purpose"] == "alerts", got
assert got["private"] is False and got["im"] is False, got

# num_members is absent on a DM, and a None there would serialise as null into a
# field the server reads as a number.
dm = rc.convert({"id": "D123", "is_im": True, "user": "U1", "num_members": None})
assert dm["memberCount"] == 0 and dm["im"] is True and dm["name"] == "U1", dm

# A missing topic/purpose object is normal, not an error.
bare = rc.convert({"id": "C1", "name": "x"})
assert bare["topic"] == "" and bare["purpose"] == "", bare

# The token comes through the environment so that it is never in a command line.
import os, subprocess
env = dict(os.environ, SLACK_REFRESH_TOKEN="")
proc = subprocess.run([sys.executable, sys.argv[1] + "/refresh_cache.py", "/tmp/never-written.json"],
                      env=env, capture_output=True, text=True)
assert proc.returncode != 0, "an empty token must not start a fetch"
assert "SLACK_REFRESH_TOKEN" in proc.stderr, proc.stderr
assert not os.path.exists("/tmp/never-written.json"), "nothing may be written on refusal"
print("python ok")
PY

echo ok
