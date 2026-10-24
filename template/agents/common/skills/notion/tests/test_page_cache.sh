#!/usr/bin/env bash
# The page cache: what a second walk has to pay, and what it must not.
#
# A cold walk of a large root does not fit in every runtime's patience — ours
# was killed twice at about two hours — and before the cache a killed walk had
# produced nothing reusable: the next run started the root over. So the cache
# has two jobs, and they are tested separately because they trade differently:
#
#   --cache alone is a REFRESH. Every page is still asked whether it moved
#   (one request), and only a page that did costs a second one for its body.
#
#   --cache --resume is a CONTINUATION. A cached page is taken as-is and costs
#   nothing at all, which is the only way the already-walked part replays fast
#   enough to reach what was never walked.
#
# The failure this guards is quiet: a cache that silently refetches looks
# exactly like a working one, only slower, and the walk still dies.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WS="$(mktemp -d "${TMPDIR:-/tmp}/notion-cache-ws.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
printf '{"branch":"development","branchPrefix":"feature/"}\n' > "$WS/harness.json"
mkdir -p "$WS/skill"
cp -R "$SKILL/." "$WS/skill/"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../notion.sh
. "$WS/skill/notion.sh"

fail=0
ROOT=11111111111111111111111111111111
KID=22222222222222222222222222222222

# Request counters stand in for the network: what matters is how many times the
# walk reaches for each endpoint, not what comes back. They are files, not
# variables, because the walk calls page_edited_time_soft inside a command
# substitution — a subshell, where an incremented variable dies with it.
MD_COUNT="$WS/md.count"
ED_COUNT="$WS/edited.count"
EDITED_NOW="2026-10-07T10:00:00.000Z"
bump() { printf 'x' >> "$1"; }
count() { [ -f "$1" ] && wc -c < "$1" | tr -d ' ' || echo 0; }

page_markdown_soft() {
  bump "$MD_COUNT"
  local id="${1//-/}"
  if [ "$id" = "$ROOT" ]; then
    printf '# Root\n\n<page url="https://app.notion.com/p/%s">Kid</page>\n' "$KID"
  else
    printf '# Kid\n'
  fi
  MD_TRUNCATED="false"
  MD_UNREADABLE=0
  return 0
}
page_edited_time_soft() { bump "$ED_COUNT"; printf '%s' "$EDITED_NOW"; }
page_title_soft() { printf 'Kid'; }

run() {  # run <cache-dir> <resume:0|1>
  : > "$MD_COUNT"; : > "$ED_COUNT"
  WALK_CACHE="$1"; WALK_RESUME="$2"
  walk_init
  WALK_MAX_DEPTH=3
  # Normalised, exactly as every cmd_* entry point calls it: the cache is keyed
  # by the id the walk carries, and a dashed/undashed mix would key one page
  # twice without ever failing visibly.
  walk "$(normalize_ref "$ROOT")" 0 "Root"
  walk_links
  MD_CALLS="$(count "$MD_COUNT")"
  EDITED_CALLS="$(count "$ED_COUNT")"
}

CACHE="$WS/cache"
mkdir -p "$CACHE"

# --- cold walk fills the cache ----------------------------------------------

run "$CACHE" 0
if [ "$WALK_PAGES" != "2" ]; then
  echo "FAILED: cold walk should read root + kid, got $WALK_PAGES" >&2; fail=1
fi
if [ "$MD_CALLS" != "2" ]; then
  echo "FAILED: a cold walk must fetch every body, got $MD_CALLS" >&2; fail=1
fi
if [ "$WALK_CACHED" != "0" ] || [ "$WALK_REFETCHED" != "2" ]; then
  echo "FAILED: nothing was cached yet — want FROM_CACHE=0 FETCHED=2, got $WALK_CACHED/$WALK_REFETCHED" >&2
  fail=1
fi
for id in "$ROOT" "$KID"; do
  d="${id:0:8}-${id:8:4}-${id:12:4}-${id:16:4}-${id:20:12}"
  [ -f "$CACHE/$d.md" ] && [ -f "$CACHE/$d.meta" ] || {
    echo "FAILED: $d left nothing in the cache" >&2; fail=1; }
done

# --- refresh: unchanged pages cost the question, not the answer -------------

run "$CACHE" 0
if [ "$MD_CALLS" != "0" ]; then
  echo "FAILED: nothing changed, so no body should have been re-fetched — got $MD_CALLS" >&2
  fail=1
fi
if [ "$EDITED_CALLS" != "2" ]; then
  echo "FAILED: refresh must still ASK each page whether it moved — got $EDITED_CALLS" >&2
  fail=1
fi
if [ "$WALK_CACHED" != "2" ]; then
  echo "FAILED: want both pages served from cache, got $WALK_CACHED" >&2; fail=1
fi

# --- a page that moved is re-read, and the cache is updated -----------------

EDITED_NOW="2026-10-07T12:00:00.000Z"
run "$CACHE" 0
if [ "$MD_CALLS" != "2" ]; then
  echo "FAILED: both pages moved, both bodies must be re-fetched — got $MD_CALLS" >&2
  fail=1
fi
run "$CACHE" 0
if [ "$MD_CALLS" != "0" ]; then
  echo "FAILED: the cache was not updated with the new edited time — got $MD_CALLS" >&2
  fail=1
fi

# --- resume: a cached page costs nothing at all -----------------------------

run "$CACHE" 1
if [ "$MD_CALLS" != "0" ] || [ "$EDITED_CALLS" != "0" ]; then
  echo "FAILED: --resume must ask nothing for a cached page — got md=$MD_CALLS edited=$EDITED_CALLS.
This is the whole point: re-checking is the cost the killed run died of." >&2
  fail=1
fi
if [ "$WALK_PAGES" != "2" ]; then
  echo "FAILED: a resumed walk still produces the whole tree, got $WALK_PAGES" >&2; fail=1
fi

# --- resume reaches what the cache does not hold ----------------------------

# The second page is dropped from the cache the way a killed run would leave it:
# everything before the kill cached, everything after it absent.
kid_d="${KID:0:8}-${KID:8:4}-${KID:12:4}-${KID:16:4}-${KID:20:12}"
rm -f "$CACHE/$kid_d.md" "$CACHE/$kid_d.meta"
run "$CACHE" 1
if [ "$WALK_PAGES" != "2" ]; then
  echo "FAILED: resume must carry on into the part that was never walked, got $WALK_PAGES" >&2
  fail=1
fi
if [ "$MD_CALLS" != "1" ]; then
  echo "FAILED: exactly the uncached page should have been fetched, got $MD_CALLS" >&2
  fail=1
fi
if [ "$WALK_CACHED" != "1" ] || [ "$WALK_REFETCHED" != "1" ]; then
  echo "FAILED: want one replayed and one fetched, got $WALK_CACHED/$WALK_REFETCHED" >&2
  fail=1
fi

# --- a truncated render is not frozen into the cache ------------------------

# `api` gives up after its retries, so one 429 mid-walk renders a block as a
# placeholder and the page comes back truncated. Cached and re-served, that
# would freeze the page in its broken form for good: its edited time never
# moves again, so nothing would ever retry it.
: > "$CACHE/.wipe"; rm -f "$CACHE"/*.md "$CACHE"/*.meta
TRUNCATE_NEXT=1
page_markdown_soft() {
  bump "$MD_COUNT"
  local id="${1//-/}"
  if [ "$id" = "$ROOT" ]; then
    printf '# Root\n\n<page url="https://app.notion.com/p/%s">Kid</page>\n' "$KID"
  else
    printf '# Kid\n'
  fi
  MD_TRUNCATED="$([ "$TRUNCATE_NEXT" -eq 1 ] && echo true || echo false)"
  MD_UNREADABLE="$([ "$TRUNCATE_NEXT" -eq 1 ] && echo 3 || echo 0)"
  return 0
}

run "$CACHE" 0
if [ -z "$WALK_TRUNCATED" ]; then
  echo "FAILED: the fixture should have produced a truncated page" >&2; fail=1
fi
# Nothing changed in Notion, but a refresh must still retry the broken render.
TRUNCATE_NEXT=0
run "$CACHE" 0
if [ "$MD_CALLS" = "0" ]; then
  echo "FAILED: a truncated page must be re-fetched on refresh — otherwise one
429 freezes it in the snapshot forever, because its edited time never moves" >&2
  fail=1
fi
if [ -n "$WALK_TRUNCATED" ]; then
  echo "FAILED: the retry succeeded, so the page must stop being reported truncated" >&2
  fail=1
fi
# And once healed, it is served from cache again like any other page.
run "$CACHE" 0
if [ "$MD_CALLS" != "0" ]; then
  echo "FAILED: a healed page should be cached normally, got $MD_CALLS" >&2; fail=1
fi

# --- the edited time is taken before the body, not after --------------------

# A page edited between the two requests would otherwise be stored with the NEW
# timestamp next to the OLD text, and every later refresh compares equal — the
# one staleness `notion.sh edited` cannot detect, because it compares against
# exactly this value.
: > "$CACHE/.wipe"; rm -f "$CACHE"/*.md "$CACHE"/*.meta
EDITED_NOW="T-before"
page_markdown_soft() {
  bump "$MD_COUNT"
  # The page moves while its body is being read.
  EDITED_NOW="T-after"
  local id="${1//-/}"
  if [ "$id" = "$ROOT" ]; then
    printf '# Root\n\n<page url="https://app.notion.com/p/%s">Kid</page>\n' "$KID"
  else
    printf '# Kid\n'
  fi
  MD_TRUNCATED="false"; MD_UNREADABLE=0
  return 0
}
run "$CACHE" 0
root_d="$(normalize_ref "$ROOT")"
stored="$(sed -n 's/^edited=//p' "$CACHE/$root_d.meta")"
if [ "$stored" = "T-after" ]; then
  echo "FAILED: the body was read at T-before but cached as T-after — that page
is now permanently stale and nothing can tell" >&2
  fail=1
fi
# Which means the next refresh sees a difference and re-reads it.
run "$CACHE" 0
if [ "$MD_CALLS" = "0" ]; then
  echo "FAILED: a page that moved mid-fetch must be re-read next time" >&2; fail=1
fi

# --- under resume, a deleted child is expected, not a hole in the tree ------

: > "$CACHE/.wipe"; rm -f "$CACHE"/*.md "$CACHE"/*.meta
EDITED_NOW="2026-10-07T10:00:00.000Z"
GONE=""
page_markdown_soft() {
  bump "$MD_COUNT"
  local id="${1//-/}"
  if [ -n "$GONE" ] && [ "$id" = "$GONE" ]; then
    SOFT_ERR="object_not_found"; return 1
  fi
  if [ "$id" = "$ROOT" ]; then
    printf '# Root\n\n<page url="https://app.notion.com/p/%s">Kid</page>\n' "$KID"
  else
    printf '# Kid\n'
  fi
  MD_TRUNCATED="false"; MD_UNREADABLE=0
  return 0
}
run "$CACHE" 0                      # fill the cache with both pages
kid_d2="$(normalize_ref "$KID")"
rm -f "$CACHE/$kid_d2.md" "$CACHE/$kid_d2.meta"   # as a killed run would leave it
GONE="$KID"                         # and meanwhile the child is deleted in Notion
run "$CACHE" 1
if [ -n "$WALK_SKIPPED" ]; then
  echo "FAILED: under --resume the child list came from a CACHED parent, so a
deleted child is the expected answer — counting it as SKIPPED_PAGES makes any
ordinary deletion refuse the whole run" >&2
  fail=1
fi
if [ -z "$WALK_UNREACHABLE" ]; then
  echo "FAILED: it still has to be reported, as an unreachable one" >&2; fail=1
fi
# Without --resume the parent is read live, and a child it still names but that
# cannot be read is a real hole.
run "$CACHE" 0
if [ -z "$WALK_SKIPPED" ]; then
  echo "FAILED: outside --resume an unreadable child is still SKIPPED_PAGES" >&2
  fail=1
fi

# --- no cache at all is the old behaviour, unchanged ------------------------

run "" 0
if [ "$MD_CALLS" != "2" ]; then
  echo "FAILED: without --cache every page is fetched, got $MD_CALLS" >&2; fail=1
fi

# --- --resume without --cache is refused ------------------------------------

if ( WALK_RESUME=0 WALK_CACHE=""; parse_walk_flags --resume ) 2>/dev/null; then
  echo "FAILED: --resume without --cache must be refused, not walked cold" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "FAIL: page cache" >&2
  exit 1
fi
echo "ok: page cache"
