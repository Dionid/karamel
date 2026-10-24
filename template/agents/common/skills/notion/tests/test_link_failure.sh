#!/usr/bin/env bash
# walk: an unreadable CHILD and an unreadable LINK are not the same failure.
#
# notion-snapshot refuses to commit a walk that reported SKIPPED_PAGES, and it
# is right to: the pages under an unread child were never read either, so
# committing that walk deletes them from the snapshot. A LINK target is not in
# the tree at all — pointing at a page is not containing it — and most trees
# link to pages the integration was never connected to. If those counted as
# skipped, every run of a link-following snapshot would refuse forever.
#
# So this pins the split: child failure -> SKIPPED_PAGES, link failure ->
# UNREACHABLE_LINKS, and a link failure leaves the walk committable.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WS="$(mktemp -d "${TMPDIR:-/tmp}/notion-linkfail-ws.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
printf '{"branch":"main","branchPrefix":"feature/"}\n' > "$WS/harness.json"
mkdir -p "$WS/skill"
cp -R "$SKILL/." "$WS/skill/"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../notion.sh
. "$WS/skill/notion.sh"

fail=0

ROOT=11111111111111111111111111111111
CHILD=22222222222222222222222222222222
LINKED=33333333333333333333333333333333

# No token, no network: the walk's own dependencies are stubbed, which is the
# only way to assert what it does with a failure.
UNREADABLE=""
page_markdown_soft() {  # page_markdown_soft <uuid>
  local id="${1//-/}"
  case " $UNREADABLE " in
    *" $id "*) SOFT_ERR="object_not_found"; return 1 ;;
  esac
  if [ "$id" = "${ROOT//-/}" ]; then
    cat <<MD
# Root

Points at [Linked](https://www.notion.so/$LINKED).

<page url="https://app.notion.com/p/$CHILD">Child</page>
MD
  else
    printf '# %s\n' "$id"
  fi
  MD_TRUNCATED="false"
  return 0
}
page_title_soft() { printf 'Linked'; }

run_walk() {  # run_walk <unreadable-ids...>
  UNREADABLE="$*"
  walk_init
  WALK_MAX_DEPTH=3
  walk "$ROOT" 0 "Root"
  # Links are deferred until the tree is exhausted — see test_link_precedence.sh
  # for why — so a walk is only finished once the queue has been drained.
  walk_links
}

# --- an unreadable child is a hole in the tree -------------------------------

run_walk "$CHILD"
if [ -z "$WALK_SKIPPED" ]; then
  echo "FAILED: an unreadable child must set SKIPPED_PAGES" >&2
  fail=1
fi
if [ -n "$WALK_UNREACHABLE" ]; then
  echo "FAILED: an unreadable child is not an unreachable link" >&2
  fail=1
fi
# --- an unreadable link target is not --------------------------------------

run_walk "$LINKED"
if [ -n "$WALK_SKIPPED" ]; then
  echo "FAILED: an unreadable LINK must not set SKIPPED_PAGES — it would stop
every snapshot of a tree that links outside itself" >&2
  fail=1
fi
if [ -z "$WALK_UNREACHABLE" ]; then
  echo "FAILED: an unreadable link must be reported as UNREACHABLE_LINKS" >&2
  fail=1
fi
if ! grep -q 'UNREACHABLE_LINKS=yes' <<<"$(walk_summary)"; then
  echo "FAILED: the summary must name the unreachable links" >&2
  fail=1
fi
if grep -q 'SKIPPED_PAGES=yes' <<<"$(walk_summary)"; then
  echo "FAILED: the summary must not report a skipped page" >&2
  fail=1
fi

# --- a readable link is walked and counted ----------------------------------

run_walk ""
if [ "$WALK_PAGES" != "3" ]; then
  echo "FAILED: want root + child + linked = 3 pages, got $WALK_PAGES" >&2
  fail=1
fi
if [ "$WALK_LINKED" != "1" ]; then
  echo "FAILED: want 1 link followed, got $WALK_LINKED" >&2
  fail=1
fi

# --- links off leaves the linked page alone ---------------------------------

WALK_LINKS=0
run_walk ""
if [ "$WALK_PAGES" != "2" ]; then
  echo "FAILED: with --no-links want root + child = 2 pages, got $WALK_PAGES" >&2
  fail=1
fi
WALK_LINKS=1

if [ "$fail" -ne 0 ]; then
  echo "FAIL: walk link failure handling" >&2
  exit 1
fi
echo "ok: walk link failure handling"
