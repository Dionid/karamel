#!/usr/bin/env bash
#
# refresh-cache.sh — build the channels cache slack-mcp-server needs to boot.
#
# Run it when `mcp-server.sh --print` reports the channels cache absent, and
# after channels have been created or renamed in bulk. It is safe to re-run: the
# file is written atomically and replaced whole.
#
# It exists because the server cannot always build this cache itself. It asks
# for all four conversation types in one `conversations.list` call, so a token
# without `im:read`/`mpim:read` fails the whole fetch, and a boot with zero
# channels and no cache file on disk is fatal. This script asks per type, so the
# types the token can read still land on disk and the server starts.
#
# It is deliberately not called from `mcp-server.sh`: an MCP client gives its
# server seconds to answer `initialize`, and a large workspace takes minutes
# here.
#
# Usage:
#   refresh-cache.sh [--print] [--types public_channel,private_channel] [--force]
#
#   --print   resolved paths and whether the caches are there, then exit.
#             No network, no token needed, no values printed.
#   --types   comma-separated subset of public_channel,private_channel,mpim,im.
#             Default: all four, skipping the ones the token cannot read.
#   --force   rebuild even when the cache is present and fresh (< 24h).
#
# Exit codes: 0 ok · 2 no workspace root · 3 no token · 4 the fetch failed

set -euo pipefail

self_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$self_dir/lib.sh"

root="$(slack_find_root "$self_dir")" || exit 2

print_only=0
force=0
types=""
while [ $# -gt 0 ]; do
  case "$1" in
    --print) print_only=1 ;;
    --force) force=1 ;;
    --types) types="${2-}"; shift ;;
    --types=*) types="${1#--types=}" ;;
    -h|--help) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'slack refresh: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

channels_cache="$(slack_channels_cache)"
users_cache="$(slack_users_cache)"

if [ "$print_only" = 1 ]; then
  printf 'root                  %s\n' "$root"
  printf 'cache dir             %s\n' "$(slack_cache_dir)"
  printf 'users cache           %s (%s)\n' \
    "$([ -s "$users_cache" ] && echo present || echo absent)" "$users_cache"
  printf 'channels cache        %s (%s)\n' \
    "$([ -s "$channels_cache" ] && echo present || echo absent)" "$channels_cache"
  exit 0
fi

# Freshness, so that a re-run on a warm cache is a no-op rather than twenty
# thousand API calls. `--force` is the way past it.
if [ "$force" = 0 ] && [ -s "$channels_cache" ]; then
  if [ -z "$(find "$channels_cache" -mmin +1440 -print 2>/dev/null)" ]; then
    printf 'channels cache is present and less than 24h old, nothing to do: %s\n' "$channels_cache"
    printf 'pass --force to rebuild it anyway\n'
    exit 0
  fi
fi

slack_read_tokens "$root"

# A bot token cannot stand in here: `conversations.list` under `xoxb` returns
# only the channels the bot was invited to, which would write a cache that looks
# complete and silently hides every other channel from the tools that read it.
if [ -z "$SLACK_XOXP" ]; then
  printf 'slack refresh: SLACK_MCP_XOXP_TOKEN is not set, in the environment or in %s/.env\n' "$root" >&2
  printf 'slack refresh: a user token is required - a bot token only sees channels it was invited to\n' >&2
  exit 3
fi

printf 'building channels cache -> %s\n' "$channels_cache"
if SLACK_REFRESH_TOKEN="$SLACK_XOXP" python3 "$self_dir/refresh_cache.py" "$channels_cache" "$types"; then
  exit 0
fi
exit 4
