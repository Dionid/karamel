#!/usr/bin/env bash
# The wrapper's whole point is that it reads the token from the FILE, because
# some hosting runtimes never give the CLI process the workspace's own .env. So
# that is what is tested here, against a fake workspace: --print never starts
# the server and never prints a value, which is what makes this runnable
# without credentials.
set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$SKILL/mcp-server.sh"

# The wrapper sources lib.sh from its own directory, so a fake install has to
# carry both files - copying only the script would test a broken install.
install_skill() {
  mkdir -p "$1"
  cp "$WRAPPER" "$SKILL/lib.sh" "$1/"
}

WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT
: > "$WS/harness.json"
install_skill "$WS/.claude/skills/slack"
W="$WS/.claude/skills/slack/mcp-server.sh"

# Every --print in this file must be answered from the fake workspace, not from
# whatever cache the machine running the tests happens to have.
CACHE="$WS/cache"
export SLACK_MCP_CACHE_DIR="$CACHE"

# A cwd that is not the workspace: an MCP server is spawned by the CLI, so the
# root has to come from the script's own location or nothing works.
cd /

run() {
  set +e
  out="$(env -u SLACK_MCP_XOXP_TOKEN -u SLACK_MCP_XOXB_TOKEN "$@" "$W" --print 2>&1)"
  rc=$?
  set -e
}

# --- no .env at all ----------------------------------------------------------
run
[[ $rc -eq 0 ]] || { echo "--print must not fail without .env: $out" >&2; exit 1; }
grep -q '^\.env  *absent' <<< "$out" || { echo "missing .env must be reported: $out" >&2; exit 1; }
grep -q 'SLACK_MCP_XOXB_TOKEN  *missing' <<< "$out" || { echo "token must read missing: $out" >&2; exit 1; }

# --- the token lives in the file, and nothing else does ----------------------
cat > "$WS/.env" <<'ENV'
GITHUB_TOKEN=must-not-leak
SLACK_MCP_XOXB_TOKEN=xoxb-from-the-file
ENV

run
grep -q 'SLACK_MCP_XOXB_TOKEN  *set (\.env)' <<< "$out" || {
  echo "the file is the source the wrapper exists for: $out" >&2; exit 1; }
grep -q 'SLACK_MCP_XOXP_TOKEN  *missing' <<< "$out" || {
  echo "an absent name must stay missing, not become empty-but-present: $out" >&2; exit 1; }

# The diagnostic is run by agents, so it must be safe to print in a transcript.
grep -q 'xoxb-from-the-file' <<< "$out" && { echo "--print leaked a value: $out" >&2; exit 1; }
grep -q 'must-not-leak'      <<< "$out" && { echo "--print leaked a value: $out" >&2; exit 1; }

# --- a value quoted the way a shell would choke on it ------------------------
# Not cosmetic: the value crosses a shell boundary inside the wrapper, and a
# token mangled there would authenticate as nobody while looking present.
cat > "$WS/.env" <<'ENV'
SLACK_MCP_XOXB_TOKEN='xoxb with a space and a $dollar and a #hash'
ENV

run
[[ $rc -eq 0 ]] || { echo "an awkward value must still resolve: $out" >&2; exit 1; }
grep -q 'SLACK_MCP_XOXB_TOKEN  *set (\.env)' <<< "$out" || {
  echo "quoted value must survive: $out" >&2; exit 1; }

# --- the environment wins over the file --------------------------------------
run SLACK_MCP_XOXB_TOKEN=xoxb-from-the-environment
grep -q 'SLACK_MCP_XOXB_TOKEN  *set (environment)' <<< "$out" || {
  echo "an exported token is the value a human set most recently: $out" >&2; exit 1; }

# An empty export is not a value: it is the failure the wrapper removes.
run SLACK_MCP_XOXB_TOKEN=
grep -q 'SLACK_MCP_XOXB_TOKEN  *set (\.env)' <<< "$out" || {
  echo "an empty export must fall through to the file: $out" >&2; exit 1; }

# --- with no token anywhere, the server is not started at all ----------------
rm "$WS/.env"
set +e
out="$(env -u SLACK_MCP_XOXP_TOKEN -u SLACK_MCP_XOXB_TOKEN "$W" 2>&1)"
rc=$?
set -e
[[ $rc -eq 3 ]] || { echo "no token must exit 3, got $rc: $out" >&2; exit 1; }
grep -q 'SLACK_MCP_XOXB_TOKEN' <<< "$out" || {
  echo "the refusal must name the variable to fill: $out" >&2; exit 1; }

# --- a tree with no harness.json is a broken install, not a missing token ----
BAD="$(mktemp -d)"
trap 'rm -rf "$WS" "$BAD"' EXIT
install_skill "$BAD/skills/slack"
set +e
out="$("$BAD/skills/slack/mcp-server.sh" --print 2>&1)"
rc=$?
set -e
[[ $rc -eq 2 ]] || { echo "no workspace root must exit 2, got $rc: $out" >&2; exit 1; }

# --- the cache, which is the other half of "the server did not start" --------
# A missing channels cache is fatal for the server and invisible in the token
# lines, so --print has to report it and say what builds it. Otherwise the only
# diagnostic an agent has says "everything is set" about a server that dies.
cd /
run
grep -q "channels cache  *absent ($CACHE/channels_cache_v2.json)" <<< "$out" || {
  echo "an absent channels cache must be reported with its path: $out" >&2; exit 1; }
grep -q 'refresh-cache.sh' <<< "$out" || {
  echo "an absent cache must name what builds it: $out" >&2; exit 1; }

mkdir -p "$CACHE"
echo '[{"id":"C1","name":"general"}]' > "$CACHE/channels_cache_v2.json"
run
grep -q "channels cache  *present" <<< "$out" || {
  echo "a present cache must read present: $out" >&2; exit 1; }
grep -q 'refresh-cache.sh' <<< "$out" && {
  echo "the hint must not be shown for a cache that is there: $out" >&2; exit 1; }

# An empty file is not a cache: the server would fail to parse it, and reporting
# it as present is how that failure gets misread as an auth problem.
: > "$CACHE/channels_cache_v2.json"
run
grep -q "channels cache  *absent" <<< "$out" || {
  echo "an empty cache file must not read present: $out" >&2; exit 1; }

# --- where the cache is allowed to live --------------------------------------
# The order is the point: an operator's override, then a runtime that offers a
# persistent directory, then the server's own default. On a hosting runtime
# where $HOME is scoped to one session, the default is the one path that cannot
# help.
dir_for() {
  env -u SLACK_MCP_CACHE_DIR -u WORKSPACE_CACHE_DIR -u SLACK_MCP_CHANNELS_CACHE "$@" \
    "$W" --print 2>&1 | sed -n 's/^channels cache .*(\(.*\))$/\1/p'
}

[[ "$(dir_for SLACK_MCP_CACHE_DIR=/tmp/explicit)" == "/tmp/explicit/channels_cache_v2.json" ]] || {
  echo "SLACK_MCP_CACHE_DIR must win" >&2; exit 1; }
[[ "$(dir_for WORKSPACE_CACHE_DIR=/tmp/runtime)" == "/tmp/runtime/slack-mcp-server/channels_cache_v2.json" ]] || {
  echo "WORKSPACE_CACHE_DIR must be used when there is no explicit override" >&2; exit 1; }

[[ "$(dir_for HOME=/tmp/home)" == "/tmp/home/.cache/slack-mcp-server/channels_cache_v2.json" ]] || {
  echo "unexpected fallback cache path: $(dir_for HOME=/tmp/home)" >&2; exit 1; }

# A path set for the server itself outranks the directory, because that is the
# variable the server would have read on its own.
[[ "$(env SLACK_MCP_CHANNELS_CACHE=/tmp/exact.json "$W" --print 2>&1 |
      sed -n 's/^channels cache .*(\(.*\))$/\1/p')" == "/tmp/exact.json" ]] || {
  echo "SLACK_MCP_CHANNELS_CACHE must be honoured verbatim" >&2; exit 1; }

# --- the write-capability switches default OFF, and the package version is pinned ---
# A stub `npx` stands in for the real server and just dumps what it was handed,
# so this exercises the real (non --print) path: token resolution, the two
# write-tool switches, and the exec line itself.
mkdir -p "$WS/npxbin"
cat > "$WS/npxbin/npx" <<'NPX'
#!/usr/bin/env bash
printf 'ARGS=%s\n' "$*"
printf 'SLACK_MCP_REACTION_TOOL=%s\n' "${SLACK_MCP_REACTION_TOOL-unset}"
printf 'SLACK_MCP_ADD_MESSAGE_TOOL=%s\n' "${SLACK_MCP_ADD_MESSAGE_TOOL-unset}"
NPX
chmod +x "$WS/npxbin/npx"

run_server() { set +e; out="$(env -u SLACK_MCP_XOXP_TOKEN "$@" PATH="$WS/npxbin:$PATH" "$W" 2>&1)"; rc=$?; set -e; }

cat > "$WS/.env" <<'ENV'
SLACK_MCP_XOXP_TOKEN=xoxp-a-token
ENV

run_server
[[ $rc -eq 0 ]] || { echo "the wrapper must reach exec with a token present: $out" >&2; exit 1; }
grep -q 'SLACK_MCP_REACTION_TOOL=false' <<< "$out" || {
  echo "the reaction tool must default OFF, not be forced on: $out" >&2; exit 1; }
grep -q 'SLACK_MCP_ADD_MESSAGE_TOOL=false' <<< "$out" || {
  echo "the write-message tool must default OFF, not be forced on: $out" >&2; exit 1; }
grep -q 'ARGS=.*slack-mcp-server@1\.3\.0' <<< "$out" || {
  echo "the package version must be pinned to 1.3.0 by default, not @latest: $out" >&2; exit 1; }

# A team turns a write tool on for itself, in its own .env — never forced, but
# honoured when it says so.
cat > "$WS/.env" <<'ENV'
SLACK_MCP_XOXP_TOKEN=xoxp-a-token
SLACK_MCP_ADD_MESSAGE_TOOL=true
ENV
run_server
grep -q 'SLACK_MCP_ADD_MESSAGE_TOOL=true' <<< "$out" || {
  echo "an explicit .env true must be honoured: $out" >&2; exit 1; }
grep -q 'SLACK_MCP_REACTION_TOOL=false' <<< "$out" || {
  echo "one flag turned on must not turn the other on too: $out" >&2; exit 1; }

# The version is overridable, for the day a newer release is checked and wanted.
run_server SLACK_MCP_SERVER_VERSION=9.9.9
grep -q 'ARGS=.*slack-mcp-server@9\.9\.9' <<< "$out" || {
  echo "SLACK_MCP_SERVER_VERSION must override the pinned default: $out" >&2; exit 1; }

echo ok
