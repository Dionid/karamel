#!/usr/bin/env bash
# RESOLVE_UNKNOWN_PY: what becomes of `<unknown …/>` placeholders the markdown
# endpoint leaves behind.
#
# The endpoint answers `truncated: true` for any page with one such block, and
# most of them are breadcrumbs — no text at all — or link previews and list
# items the blocks API reads fine. Before this, a 309-page tree reported 85
# pages as partial; the handful that really were could not be found among them.
#
# So the rules under test: a content-free block disappears with its line; a
# readable block is rendered in place, keeping its indentation; a Notion-hosted
# file links to the block's stable anchor, not to a signed URL that expires; and
# only what stays unreadable — an API error, or an id with no placeholder — is
# counted as missing.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Same reason as test_nested_layout.sh: notion.sh needs a harness.json above it
# at load time, and the CI checkout never has one.
WS="$(mktemp -d "${TMPDIR:-/tmp}/notion-unknown-ws.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
printf '{"branch":"development","branchPrefix":"feature/"}\n' > "$WS/harness.json"
mkdir -p "$WS/skill"
cp -R "$SKILL/." "$WS/skill/"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../notion.sh
. "$WS/skill/notion.sh"

P="https://app.notion.com/p/11111111111111111111111111111111"
B_CRUMB="aaaaaaaa000000000000000000000001"
B_LINK="aaaaaaaa000000000000000000000002"
B_ITEM="aaaaaaaa000000000000000000000003"
B_IMG="aaaaaaaa000000000000000000000004"
B_GONE="aaaaaaaa000000000000000000000005"
B_KIDS="aaaaaaaa000000000000000000000006"
B_NOPH="aaaaaaaa000000000000000000000007"
B_BTN="aaaaaaaa000000000000000000000008"

dash() { printf '%s-%s-%s-%s-%s' "${1:0:8}" "${1:8:4}" "${1:12:4}" "${1:16:4}" "${1:20:12}"; }

cat > "$WS/md" <<EOF
<unknown url="$P#$B_CRUMB" alt="breadcrumb"/>
## Section
<unknown url="$P#$B_BTN" alt="button"/>
	- first
	<unknown url="$P#$B_ITEM"/>
<unknown url="$P#$B_LINK" alt="external_object_instance"/>
<unknown url="$P#$B_IMG"/>
<unknown url="$P#$B_GONE"/>
<unknown url="$P#$B_KIDS"/>
end
EOF

for b in $B_CRUMB $B_LINK $B_ITEM $B_IMG $B_GONE $B_KIDS $B_NOPH; do dash "$b"; echo; done > "$WS/unknown"

{
  jq -cn --arg id "$(dash $B_LINK)" '{id:$id, block:{object:"block", type:"link_preview", link_preview:{url:"https://figma.com/x"}}}'
  jq -cn --arg id "$(dash $B_ITEM)" '{id:$id, block:{object:"block", type:"bulleted_list_item", has_children:false,
    bulleted_list_item:{rich_text:[{plain_text:"bold ", annotations:{bold:true}}, {plain_text:"link", href:"https://e.x"}]}}}'
  jq -cn --arg id "$(dash $B_IMG)" '{id:$id, block:{object:"block", type:"image",
    image:{type:"file", caption:[], file:{url:"https://s3.example/signed?X-Amz-Expires=3600"}}}}'
  jq -cn --arg id "$(dash $B_GONE)" '{id:$id, block:{object:"error", code:"object_not_found"}}'
  jq -cn --arg id "$(dash $B_KIDS)" '{id:$id, block:{object:"block", type:"toggle", has_children:true,
    toggle:{rich_text:[{plain_text:"details"}]}}}'
} > "$WS/blocks"

out="$(python3 -c "$RESOLVE_UNKNOWN_PY" "$WS/md" "$WS/blocks" "$WS/unknown" "$WS/left")"
left="$(cat "$WS/left")"

fail=0
expect_line() {  # expect_line <what> <exact line>
  if grep -qxF -- "$2" <<<"$out"; then
    printf 'ok    %s\n' "$1"
  else
    printf 'FAIL  %s\n      want line: %s\n' "$1" "$2"; fail=1
  fi
}
expect_absent() {  # expect_absent <what> <substring>
  if grep -qF -- "$2" <<<"$out"; then
    printf 'FAIL  %s\n      still has: %s\n' "$1" "$2"; fail=1
  else
    printf 'ok    %s\n' "$1"
  fi
}

expect_absent "breadcrumb is dropped" "$B_CRUMB"
expect_line   "breadcrumb leaves no blank line" "## Section"
expect_absent "button is dropped" "$B_BTN"
if [ "$(head -1 <<<"$out")" = "## Section" ]; then
  printf 'ok    first line is the heading\n'
else
  printf 'FAIL  first line is the heading, got: %s\n' "$(head -1 <<<"$out")"; fail=1
fi
expect_line   "list item keeps indentation and rich text" $'\t- **bold** [link](https://e.x)'
expect_line   "link preview becomes a link" "[link preview](https://figma.com/x)"
expect_line   "hosted image links to the stable anchor" "[image: image]($P#$B_IMG)"
expect_absent "signed file URL is not committed" "X-Amz-Expires"
expect_line   "unreadable block keeps its placeholder" "<unknown url=\"$P#$B_GONE\"/>"
expect_line   "block with children renders its own text" "- details"
expect_line   "text after placeholders survives" "end"

# Missing: B_GONE (error), B_KIDS (children unread), B_NOPH (no placeholder).
if [ "$left" = "3" ]; then
  printf 'ok    three blocks counted as unreadable\n'
else
  printf 'FAIL  unreadable count: want 3, got %s\n' "$left"; fail=1
fi

# --- markdown_of_body: the bash around the resolver --------------------------
# api() is stubbed: each call is logged, and every block reads as a paragraph.
CALLS="$WS/calls"
: > "$CALLS"
api() {
  printf '%s\n' "$2" >> "$CALLS"
  printf '{"object":"block","type":"paragraph","paragraph":{"rich_text":[{"plain_text":"text"}]}}'
}

body_of() {  # body_of <markdown> <unknown-id>...
  local md="$1"; shift
  jq -n --arg md "$md" --args '{markdown: $md, truncated: true, unknown_block_ids: $ARGS.positional}' "$@"
}

state() {  # state <want-truncated> <want-unreadable> <what>
  if [ "$MD_TRUNCATED" = "$1" ] && [ "$MD_UNREADABLE" = "$2" ]; then
    printf 'ok    %s\n' "$3"
  else
    printf 'FAIL  %s: want T=%s U=%s, got T=%s U=%s\n' "$3" "$1" "$2" "$MD_TRUNCATED" "$MD_UNREADABLE"; fail=1
  fi
}

# Called the way walk calls it — a redirect inside an `if` — the globals must
# land in this shell; a breadcrumb costs no request; a block placed twice, one.
body="$(body_of "<unknown url=\"$P#$B_CRUMB\" alt=\"breadcrumb\"/>
<unknown url=\"$P#$B_ITEM\"/>
<unknown url=\"$P#$B_ITEM\"/>" "$(dash $B_CRUMB)" "$(dash $B_ITEM)")"
if markdown_of_body "$body" > "$WS/page"; then :; fi
state false 0 "resolved page is reported whole"
if [ "$(wc -l < "$CALLS" | tr -d ' ')" = "1" ]; then
  printf 'ok    one request: none for the breadcrumb, one for a block placed twice\n'
else
  printf 'FAIL  requests: want 1, got:\n%s\n' "$(cat "$CALLS")"; fail=1
fi

# `truncated` with nothing to resolve: a cut this code cannot see stays a cut.
body="$(body_of $'line1\nline2')"
if markdown_of_body "$body" > "$WS/page"; then :; fi
state true '?' "truncated with no placeholders stays truncated"

# A resolver that dies leaves the API's markdown and the truncated flag, never
# an empty page reported whole.
real_py="$RESOLVE_UNKNOWN_PY"
RESOLVE_UNKNOWN_PY='raise SystemExit(3)'
body="$(body_of "keep me
<unknown url=\"$P#$B_ITEM\"/>" "$(dash $B_ITEM)")"
if markdown_of_body "$body" > "$WS/page"; then :; fi
RESOLVE_UNKNOWN_PY="$real_py"
state true '?' "resolver failure keeps the page truncated"
if grep -qxF "keep me" "$WS/page"; then
  printf 'ok    resolver failure keeps the original markdown\n'
else
  printf 'FAIL  resolver failure lost the markdown: %s\n' "$(cat "$WS/page")"; fail=1
fi

exit "$fail"
