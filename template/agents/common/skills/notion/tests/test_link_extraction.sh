#!/usr/bin/env bash
# extract_children: what the walk is handed as the next level of the tree.
#
# Two kinds of edge come out of one page. `page`/`database` are the tree Notion
# owns; `link` is everything the page merely points at, which is how a walk
# reaches a page nobody filed underneath the root it started from. The rules
# that matter are the ones a wrong answer makes expensive:
#
#   - structural edges come FIRST, so a page that is both a child and linked is
#     placed where the tree says and a nested dump does not move files around
#     because somebody added a sentence;
#   - a `#<32hex>` fragment is a BLOCK and `?v=<32hex>` a database VIEW, so the
#     id has to be read from the path alone — walking a block id 404s, and the
#     walk reports 404s as holes in the tree;
#   - links off is the whole old behaviour, unchanged.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Same reasoning as test_nested_layout.sh: notion.sh resolves the workspace root
# at load time, and harness.json is gitignored, so the test builds one.
WS="$(mktemp -d "${TMPDIR:-/tmp}/notion-links-ws.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
printf '{"branch":"main","branchPrefix":"feature/"}\n' > "$WS/harness.json"
mkdir -p "$WS/skill"
cp -R "$SKILL/." "$WS/skill/"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../notion.sh
. "$WS/skill/notion.sh"

fail=0
MD="$WS/page.md"

normalized="$(normalize_ref "https://www.notion.so/00000000000000000000000000000003")"
if [[ "$normalized" != "00000000-0000-0000-0000-000000000003" ]]; then
  echo "FAILED: uppercase page ids must normalize portably, got: $normalized" >&2
  fail=1
fi

cat > "$MD" <<'MDEOF'
# Concept

See [Product](https://www.notion.so/00000000000000000000000000000004) for details.
Anchored: [a note](https://www.notion.so/Some-Page-00000000000000000000000000000005#00000000000000000000000000000006)
A view: [rows](https://www.notion.so/00000000000000000000000000000007?v=00000000000000000000000000000008)
Outside: [eBay](https://www.ebay.com/itm/1234)
Bare: https://app.notion.com/p/00000000000000000000000000000009
Also linked: [Support](https://www.notion.so/0000000000000000000000000000000a)
<unknown url="https://app.notion.com/p/0000000000000000000000000000000b#0000000000000000000000000000000c" alt="breadcrumb"/>

<page url="https://app.notion.com/p/0000000000000000000000000000000a">Support</page>
<database url="https://app.notion.com/p/0000000000000000000000000000000d" inline="true" data-source-url="collection://00000000-0000-0000-0000-00000000000e">Category</database>
MDEOF

# kind<US>id<US>data-source<US>title, one per line, as the walk reads it.
got_on="$(WALK_LINKS=1 extract_children "$MD")"
got_off="$(WALK_LINKS=0 extract_children "$MD")"

check() {  # check <description> <expected-line> <haystack>
  if ! grep -qxF "$2" <<<"$3"; then
    echo "want line: $(cat -v <<<"$2")" >&2
    echo "in:
$(cat -v <<<"$3")" >&2
    echo "FAILED: $1" >&2
    fail=1
  fi
}

absent() {  # absent <description> <pattern> <haystack>
  if grep -qF "$2" <<<"$3"; then
    echo "did not want '$2' in:
$(cat -v <<<"$3")" >&2
    echo "FAILED: $1" >&2
    fail=1
  fi
}

us=$'\x1f'

# --- the tree Notion owns ---------------------------------------------------

check "child page is structural" \
  "page${us}0000000000000000000000000000000a${us}${us}Support" "$got_on"
check "inline database keeps its data source" \
  "database${us}0000000000000000000000000000000d${us}00000000-0000-0000-0000-00000000000e${us}Category" "$got_on"

# Structural edges before link edges: `head -2` is the assertion, because the
# walk places a page the first time it sees it.
if [[ "$(head -2 <<<"$got_on" | cut -d"$us" -f1 | tr '\n' ' ')" != "page database " ]]; then
  echo "FAILED: structural edges must come first, got:
$(cut -d"$us" -f1 <<<"$got_on" | tr '\n' ' ')" >&2
  fail=1
fi

# A page that is both a child and linked in prose appears once, as the child.
if [[ "$(grep -cF "0000000000000000000000000000000a" <<<"$got_on")" != "1" ]]; then
  echo "FAILED: a linked child must not be emitted twice" >&2
  fail=1
fi

# --- what the page points at ------------------------------------------------

check "a plain link is followed" \
  "link${us}00000000000000000000000000000004${us}${us}Product" "$got_on"
check "a block anchor resolves to its page, not the block" \
  "link${us}00000000000000000000000000000005${us}${us}a note" "$got_on"
absent "the block id itself is never walked" "00000000000000000000000000000006" "$got_on"
check "a database view link resolves to the page" \
  "link${us}00000000000000000000000000000007${us}${us}rows" "$got_on"
absent "the view id is not a page" "00000000000000000000000000000008" "$got_on"
# A bare URL has no link text; the walk asks Notion for the real title rather
# than filing every such page under one slug, so an empty title here is correct.
check "a bare Notion URL is followed, untitled" \
  "link${us}00000000000000000000000000000009${us}${us}" "$got_on"

# --- what it must not follow ------------------------------------------------

absent "a link off Notion is not a page" "ebay.com" "$got_on"
# The <unknown> url is a block anchor the resolver left behind, not a link.
absent "an unknown-block placeholder is not a link" \
  "0000000000000000000000000000000b" "$got_on"

# --- links off is the old behaviour -----------------------------------------

if [[ "$(cut -d"$us" -f1 <<<"$got_off" | sort -u | tr '\n' ' ')" != "database page " ]]; then
  echo "FAILED: --no-links must yield structural edges only, got:
$(cat -v <<<"$got_off")" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: extract_children" >&2
  exit 1
fi
echo "ok: extract_children"
