#!/usr/bin/env bash
#
# mcp-server.sh — start slack-mcp-server with the workspace's Slack tokens and
# with its caches on a path that outlives one session.
#
# Two gaps are closed here, and neither announces itself when it is open.
#
# **The token gap.** An MCP server declared as
# `"SLACK_MCP_XOXB_TOKEN": "${SLACK_MCP_XOXB_TOKEN}"` reads only the process
# environment, and some hosting runtimes give the CLI process a restricted
# environment for the MCP servers it launches, carrying nothing from the
# workspace's own `.env`. Such a server starts with an empty token however well
# the file is filled, and fails as if the credential were missing.
# `slack_read_tokens` reads the file instead.
#
# **The cache gap.** slack-mcp-server refuses to boot with zero channels and no
# channels cache on disk, and it cannot build that cache with a token missing
# `im:read`/`mpim:read` — it requests all four conversation types in one call.
# On a hosting runtime where `$HOME` is scoped to one session, the server's
# default cache path is exactly the one place a cache built once cannot help the
# next session. `slack_cache_dir` moves both caches onto a persistent path; the
# file itself is built by `refresh-cache.sh`, never by this wrapper — see the
# note below.
#
# Only the Slack names are exported. The `.env` is sourced in a subshell and
# nothing else survives it: slack-mcp-server is a third-party npm package, and
# there is no reason for it to inherit GitHub, Notion or database credentials.
#
# Usage:
#   mcp-server.sh [--print] [extra args passed to slack-mcp-server]
#
#   --print   report which token names resolved and from where, and where the
#             caches are expected, then exit without starting anything. Names,
#             paths and `set`/`missing` only, never a value — this is the
#             diagnostic an agent may run.
#
# Exit codes: 0 ok · 2 no workspace root · 3 no token in either door

set -euo pipefail

self_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$self_dir/lib.sh"

root="$(slack_find_root "$self_dir")" || exit 2

print_only=0
if [ "${1-}" = "--print" ]; then print_only=1; shift; fi

slack_read_tokens "$root"

users_cache="$(slack_users_cache)"
channels_cache="$(slack_channels_cache)"

if [ "$print_only" = 1 ]; then
  printf 'root                  %s\n' "$root"
  printf '.env                  %s\n' "$([ -f "$root/.env" ] && echo present || echo absent)"
  printf 'SLACK_MCP_XOXP_TOKEN  %s\n' "$(slack_state "$SLACK_XOXP" "$SLACK_XOXP_FROM")"
  printf 'SLACK_MCP_XOXB_TOKEN  %s\n' "$(slack_state "$SLACK_XOXB" "$SLACK_XOXB_FROM")"
  printf 'users cache           %s (%s)\n' \
    "$([ -s "$users_cache" ] && echo present || echo absent)" "$users_cache"
  printf 'channels cache        %s (%s)\n' \
    "$([ -s "$channels_cache" ] && echo present || echo absent)" "$channels_cache"
  if [ ! -s "$channels_cache" ]; then
    printf 'hint                  no channels cache: the server will refuse to boot if the\n'
    printf '                      token lacks im:read/mpim:read. Build it with\n'
    printf '                      .claude/skills/slack/refresh-cache.sh\n'
  fi
  exit 0
fi

if [ -z "$SLACK_XOXP" ] && [ -z "$SLACK_XOXB" ]; then
  printf 'slack mcp: neither SLACK_MCP_XOXP_TOKEN nor SLACK_MCP_XOXB_TOKEN is set, in the environment or in %s/.env - slack-mcp-server cannot authenticate, so it is not started\n' "$root" >&2
  exit 3
fi

# Only the ones that actually resolved: slack-mcp-server picks its auth mode by
# which variable is present, and an empty one declared present is how a bot-only
# deployment ends up trying to authenticate as a user.
# An empty one is unset rather than left alone: an empty string we inherited is
# still "present" to the child, which is the whole failure this script exists to
# remove, one layer down.
if [ -n "$SLACK_XOXP" ]; then export SLACK_MCP_XOXP_TOKEN="$SLACK_XOXP"; else unset SLACK_MCP_XOXP_TOKEN; fi
if [ -n "$SLACK_XOXB" ]; then export SLACK_MCP_XOXB_TOKEN="$SLACK_XOXB"; else unset SLACK_MCP_XOXB_TOKEN; fi

# reactions_add/reactions_remove and conversations_add_message (post/reply) are
# disabled upstream by default, and stay disabled here by default too: turning
# on a write tool is the team's own decision, made in its own .env or process
# environment (see SKILL.md's Writes section), never something this wrapper
# switches on for everyone by exporting `true` unconditionally. Every call
# through either tool is still gated by the user's explicit approval before
# this skill uses it, whatever the setting — the setting only controls whether
# the tool exists at all. The bot/user token still needs the matching scope
# (`reactions:write`, `chat:write`) before a call actually succeeds.
reaction_tool="$(slack_env_flag "$root" SLACK_MCP_REACTION_TOOL false)"
add_message_tool="$(slack_env_flag "$root" SLACK_MCP_ADD_MESSAGE_TOOL false)"
export SLACK_MCP_REACTION_TOOL="$reaction_tool"
export SLACK_MCP_ADD_MESSAGE_TOOL="$add_message_tool"

# The directory is created here so the server can write the users cache it *can*
# build; a missing channels cache is not repaired on this path on purpose. An
# MCP client gives its server seconds to answer `initialize`, and building this
# cache takes minutes on a large workspace — a wrapper that fetched tens of
# thousands of channels before exec would turn a server that fails loudly into
# one that times out.
mkdir -p "$(dirname "$users_cache")" "$(dirname "$channels_cache")" 2>/dev/null || true
export SLACK_MCP_USERS_CACHE="$users_cache"
export SLACK_MCP_CHANNELS_CACHE="$channels_cache"

# Pinned, not @latest: the cache file format both scripts read and write here
# (lib.sh, refresh_cache.py) was verified against v1.3.0's struct tags, and
# @latest would silently start running whatever the next release changed —
# including that format — with nothing here to notice. Override only after
# checking the new version's cache shape against refresh_cache.py's `convert`.
SLACK_MCP_SERVER_VERSION="${SLACK_MCP_SERVER_VERSION:-1.3.0}"
exec npx -y "slack-mcp-server@${SLACK_MCP_SERVER_VERSION}" --transport stdio "$@"
