#!/usr/bin/env bash
# dump_nested_path: where one page lands in a `dump --layout nested` run.
#
# This is the whole reason the nested layout exists. The ordered layout numbers
# files by walk order, so inserting one page in Notion renames every file after
# it — in a committed snapshot that is a diff touching a hundred files, none of
# which changed. Nothing fails; the history just stops being readable.
#
# So the rules under test are: the path comes from the title and the tree, never
# from the order; children sit under a directory named after their parent's
# file; and two siblings that slugify to the same name do not collide.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# notion.sh resolves the workspace root AT LOAD TIME and `die`s when there is no
# harness.json above it — right behaviour for a CLI, fatal for a unit test of one
# pure function. And `harness.json` is gitignored, so the CI checkout never has
# one: sourcing the skill in place passes on any developer machine and fails in
# every pipeline, which is exactly how this test came to be red on `development`
# while green for everyone who ran it by hand.
#
# So the test builds the root it needs. 48K of copy buys a run that does not
# depend on where the checkout sits or on a file git refuses to carry.
WS="$(mktemp -d "${TMPDIR:-/tmp}/notion-layout-ws.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
printf '{"branch":"development","branchPrefix":"feature/"}\n' > "$WS/harness.json"
mkdir -p "$WS/skill"
cp -R "$SKILL/." "$WS/skill/"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../notion.sh
. "$WS/skill/notion.sh"

fail=0
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notion-layout-test.XXXXXX")"
trap 'rm -rf "$OUT_DIR" "$WS"' EXIT

check() {  # check <want> <title> <id> <dir>
  local want="$1" got
  got="$(dump_nested_path "$2" "$3" "$4")"
  if [[ "$want" != "$got" ]]; then
    echo "dump_nested_path('$2', '$3', '$4') — want '$want', got '$got'" >&2
    fail=1
  fi
}

# --- the path is the title, at every level ----------------------------------

check 'product' 'Product' '1111aaaa-2222-3333-4444-555566667777' ''
check 'product/payment-flows' 'Payment Flows' '2222bbbb-2222-3333-4444-555566667777' 'product'
# A Russian title transliterates instead of turning into mojibake or into
# "untitled" — half this workspace's Notion pages are named in Russian, and
# ASCII paths also keep the snapshot readable in git on a case-folding or
# NFD-normalising filesystem.
check 'product/platezhnye-scenarii' 'Платёжные сценарии' \
  '3333cccc-2222-3333-4444-555566667777' 'product'
# A title with nothing sluggable still has to land somewhere nameable.
check 'untitled' '///' '4444dddd-2222-3333-4444-555566667777' ''

# --- the same title twice under one parent ----------------------------------

# First writer takes the clean name. Nothing exists yet, so this is what the
# walk would have written.
check 'tech/services' 'Services' 'aaaa1111-2222-3333-4444-555566667777' 'tech'
mkdir -p "$OUT_DIR/tech"
: > "$OUT_DIR/tech/services.md"
# Second one must not overwrite it — and must not take the first one's name
# away either, or every snapshot would reshuffle depending on walk order.
check 'tech/services-bbbb1111' 'Services' 'bbbb1111-2222-3333-4444-555566667777' 'tech'

# A database claims a directory without writing a file of its own, so a page of
# the same name later must still step aside.
mkdir -p "$OUT_DIR/bd/partners"
check 'bd/partners-cccc1111' 'Partners' 'cccc1111-2222-3333-4444-555566667777' 'bd'

# --- the clean name is stable across runs -----------------------------------

# Re-asking for a page whose own file is the only thing in the way would answer
# with a suffix, which is why the snapshot writes into an empty directory: the
# caller clears the tree first. Assert the mechanism rather than the wish.
rm -f "$OUT_DIR/tech/services.md"
check 'tech/services' 'Services' 'aaaa1111-2222-3333-4444-555566667777' 'tech'

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: dump_nested_path" >&2
  exit 1
fi
echo "ok: dump_nested_path"
