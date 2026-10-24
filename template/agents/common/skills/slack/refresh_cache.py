#!/usr/bin/env python3
"""Build slack-mcp-server's channels cache from conversations.list.

The server builds this cache itself when it can. It cannot when the token is
missing `im:read` or `mpim:read`, because it asks for all four conversation
types in a single call and one missing scope fails the whole fetch — after
which a boot with zero channels and no cache file is fatal. This script asks
for one type at a time, so the types the token *can* read still land on disk.

The file format is the server's own: a flat JSON array of

    {"id", "name", "topic", "purpose", "memberCount", "im", "mpim", "private"}

taken from the struct tags in the v1.3.0 binary and verified by starting the
server against a file written here.

Called by refresh-cache.sh, which resolves the token and the path. The token
arrives in SLACK_REFRESH_TOKEN so that it never appears in a command line.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://slack.com/api/"
ALL_TYPES = ("public_channel", "private_channel", "mpim", "im")


def call(method, token, params=None, retries=6):
    """One Slack API GET, retrying only on rate limits."""
    url = API + method
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    for _ in range(retries):
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            if exc.code != 429:
                raise
            # Slack's own Retry-After, capped: a wait longer than this means
            # something is wrong with the plan, not with this page.
            wait = min(int(exc.headers.get("Retry-After", "30")), 60)
            print(f"    rate limited, waiting {wait}s", flush=True)
            time.sleep(wait)
    raise SystemExit("slack refresh: too many rate limits in a row")


def fetch_type(token, chan_type):
    """Every channel of one type, or None when the scope is missing."""
    out, cursor, pages = [], "", 0
    while True:
        pages += 1
        data = call(
            "conversations.list",
            token,
            {
                "limit": 999,
                "exclude_archived": "false",
                "types": chan_type,
                "cursor": cursor,
            },
        )
        if not data.get("ok"):
            error = data.get("error", "unknown")
            if error == "missing_scope":
                print(f"  {chan_type:16} skipped - needs {data.get('needed', '?')}")
                return None
            raise SystemExit(f"slack refresh: conversations.list({chan_type}): {error}")
        out.extend(data.get("channels", []))
        cursor = (data.get("response_metadata") or {}).get("next_cursor", "")
        if not cursor:
            break
        if pages > 500:
            raise SystemExit(f"slack refresh: {chan_type} exceeded 500 pages")
    print(f"  {chan_type:16} {len(out)} in {pages} page(s)")
    return out


def convert(raw):
    """A Slack conversation object as slack-mcp-server stores it."""
    return {
        "id": raw.get("id", ""),
        "name": raw.get("name", "") or raw.get("user", ""),
        "topic": (raw.get("topic") or {}).get("value", ""),
        "purpose": (raw.get("purpose") or {}).get("value", ""),
        "memberCount": raw.get("num_members") or 0,
        "im": bool(raw.get("is_im")),
        "mpim": bool(raw.get("is_mpim")),
        "private": bool(raw.get("is_private")),
    }


def main(argv):
    if len(argv) < 2:
        raise SystemExit("usage: refresh_cache.py <target-path> [types]")
    target = argv[1]
    types = tuple(argv[2].split(",")) if len(argv) > 2 and argv[2] else ALL_TYPES

    token = os.environ.get("SLACK_REFRESH_TOKEN", "")
    if not token:
        raise SystemExit("slack refresh: SLACK_REFRESH_TOKEN is empty")

    who = call("auth.test", token)
    if not who.get("ok"):
        raise SystemExit("slack refresh: auth.test failed: " + str(who.get("error")))
    print(f"authenticated: team {who.get('team')} ({who.get('team_id')}), user {who.get('user')}")

    channels, refused = [], []
    for chan_type in types:
        got = fetch_type(token, chan_type)
        if got is None:
            refused.append(chan_type)
        else:
            channels.extend(got)

    if not channels:
        raise SystemExit(
            "slack refresh: no channels readable at all - writing an empty cache "
            "would only move the failure, so nothing was written"
        )

    # Atomic: the server may be starting while this runs, and half a JSON array
    # is a cache that exists and cannot be parsed.
    payload = [convert(c) for c in channels]
    os.makedirs(os.path.dirname(target) or ".", exist_ok=True)
    tmp = target + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle)
    os.replace(tmp, target)

    print(f"wrote {len(payload)} channels to {target}")
    if refused:
        print(
            "not in the cache: " + ", ".join(refused) + " - add the matching "
            "*:read scopes to the token and re-run to include them"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
