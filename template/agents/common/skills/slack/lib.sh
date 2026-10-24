#!/usr/bin/env bash
#
# lib.sh — the three things both Slack scripts need: the workspace root, the
# tokens, and where the caches live.
#
# It exists because `mcp-server.sh` and `refresh-cache.sh` have to agree on all
# three exactly. They resolve the same cache path from different processes —
# the wrapper exports it to the server, the refresher writes the file the server
# will read — and a mismatch produces no error at all: the refresher reports a
# freshly built cache, the server reports no cache, and both are telling the
# truth about different files.
#
# Sourced, never executed. Every function prints only names and states, never a
# token value.

# The root is found from the caller's own location, not from `$PWD` the way the
# other skill scripts do it: an MCP server is spawned by the CLI, so its cwd is
# whatever the CLI happened to start in and is not a fact about this workspace.
slack_find_root() {
  local start="$1" root parent
  root="$start"
  while [ ! -f "$root/harness.json" ]; do
    parent="$(dirname "$root")"
    if [ "$parent" = "$root" ]; then
      printf 'slack: workspace root not found above %s (no harness.json)\n' "$start" >&2
      return 2
    fi
    root="$parent"
  done
  printf '%s\n' "$root"
}

# A credential reaches an agent through two separate doors, and only one of them
# is the `.env` file every skill talks about:
#
#   - **the file** `<workspace root>/.env`, which skills source in their own
#     Bash call;
#   - **the environment of the CLI process**, from which `${VAR}` in
#     `settings.json` / `config.toml` is expanded. Some hosting runtimes give the
#     CLI a restricted process environment for the MCP servers it launches —
#     unrelated to the workspace's own `.env` — so a server declared with
#     `${SLACK_MCP_XOXB_TOKEN}` there starts with an empty token however well
#     the file is filled, and fails as if the credential were missing.
#
# Reading the file here is what closes the gap. Sets SLACK_XOXP / SLACK_XOXB and
# SLACK_XOXP_FROM / SLACK_XOXB_FROM in the caller's shell.
slack_read_tokens() {
  local root="$1" file_xoxp file_xoxb

  # An operator who exported the token in their own shell keeps winning: this
  # is the value a human set most recently.
  SLACK_XOXP="${SLACK_MCP_XOXP_TOKEN-}"
  SLACK_XOXB="${SLACK_MCP_XOXB_TOKEN-}"
  SLACK_XOXP_FROM="environment"
  SLACK_XOXB_FROM="environment"

  [ -f "$root/.env" ] || return 0

  # `printf %q` because the values cross a shell boundary here and a token is
  # opaque: quoting it wrongly would corrupt it silently, or worse, execute
  # part of it.
  file_xoxp=""; file_xoxb=""
  eval "$(
    set -a
    # shellcheck disable=SC1090,SC1091
    . "$root/.env"
    set +a
    printf 'file_xoxp=%q\nfile_xoxb=%q\n' "${SLACK_MCP_XOXP_TOKEN-}" "${SLACK_MCP_XOXB_TOKEN-}"
  )"
  # SLACK_*_FROM are read by the sourcing script (mcp-server.sh --print).
  # shellcheck disable=SC2034
  if [ -z "$SLACK_XOXP" ] && [ -n "$file_xoxp" ]; then SLACK_XOXP="$file_xoxp"; SLACK_XOXP_FROM=".env"; fi
  # shellcheck disable=SC2034
  if [ -z "$SLACK_XOXB" ] && [ -n "$file_xoxb" ]; then SLACK_XOXB="$file_xoxb"; SLACK_XOXB_FROM=".env"; fi
}

# slack_env_flag <root> <name> <default> — a boolean-ish setting from the same
# two doors as a token: the caller's own environment first, then <root>/.env,
# then <default>. Used for the write-capability switches below, which must
# stay opt-in — a team turns write on for itself, in its own .env, rather than
# this wrapper deciding it for everyone by exporting `true` unconditionally.
slack_env_flag() {
  local root="$1" name="$2" default="$3" value file_value
  value="$(eval "printf '%s' \"\${$name-}\"")"
  if [ -z "$value" ] && [ -f "$root/.env" ]; then
    file_value=""
    eval "$(
      set -a
      # shellcheck disable=SC1090,SC1091
      . "$root/.env"
      set +a
      eval "printf 'file_value=%q\\n' \"\${$name-}\""
    )"
    value="$file_value"
  fi
  printf '%s\n' "${value:-$default}"
}

# Where the caches live, and the whole reason this file exists.
#
# slack-mcp-server cannot build the channels cache with a token that lacks
# `im:read`/`mpim:read`: it asks for all four conversation types in one call,
# so one missing scope fails the whole fetch, and a boot with zero channels and
# no cache file on disk is fatal. The cache therefore has to outlive the process
# that could not build it — and on some hosting runtimes `$HOME` is scoped to one
# session or thread, so the default path is the one place it cannot outlive
# anything.
#
# Order, first hit wins:
#   1. SLACK_MCP_CACHE_DIR      — explicit, any deployment
#   2. WORKSPACE_CACHE_DIR          — a runtime that offers a persistent cache dir
#   3. $HOME/.cache/...         — what the server would have used anyway
#
# Guarded by existence rather than by runtime detection: neither branch is
# assumed, and nothing here fails when the persistent directory does not exist.
slack_cache_dir() {
  if [ -n "${SLACK_MCP_CACHE_DIR-}" ]; then
    printf '%s\n' "$SLACK_MCP_CACHE_DIR"
  elif [ -n "${WORKSPACE_CACHE_DIR-}" ]; then
    printf '%s/slack-mcp-server\n' "$WORKSPACE_CACHE_DIR"
  else
    printf '%s/.cache/slack-mcp-server\n' "${HOME:-/tmp}"
  fi
}

# The two files, with the per-file overrides the server itself understands
# taking precedence over the directory above.
#
# The names carry no team id. The server prefixes one only onto its *own*
# default path — an explicitly configured path is written verbatim (verified
# against v1.3.0) — so one cache directory means one Slack workspace.
slack_users_cache() {
  if [ -n "${SLACK_MCP_USERS_CACHE-}" ]; then printf '%s\n' "$SLACK_MCP_USERS_CACHE"
  else printf '%s/users_cache.json\n' "$(slack_cache_dir)"; fi
}

slack_channels_cache() {
  if [ -n "${SLACK_MCP_CHANNELS_CACHE-}" ]; then printf '%s\n' "$SLACK_MCP_CHANNELS_CACHE"
  else printf '%s/channels_cache_v2.json\n' "$(slack_cache_dir)"; fi
}

# `set (...)` / `missing`, never a value — this is what an agent may print.
slack_state() {
  if [ -n "$1" ]; then printf 'set (%s)' "$2"; else printf 'missing'; fi
}
