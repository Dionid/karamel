#!/usr/bin/env bash
# dump_frontmatter: the YAML header written above every dumped page.
#
# `edited` records a page's own last_edited_time from Notion, not the
# date of the dump run — so staleness of a committed snapshot can be checked
# per page (`notion.sh edited <id>` against this field) instead of trusting
# the whole tree or re-walking it. This test is the contract for that field:
# present, in the right position, carrying exactly the value it was given.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Same reason as test_nested_layout.sh: notion.sh resolves the workspace root
# at load time and dies with no harness.json above it, which the CI checkout
# never has (it's gitignored).
WS="$(mktemp -d "${TMPDIR:-/tmp}/notion-frontmatter-ws.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
printf '{"branch":"development","branchPrefix":"feature/"}\n' > "$WS/harness.json"
mkdir -p "$WS/skill"
cp -R "$SKILL/." "$WS/skill/"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../notion.sh
. "$WS/skill/notion.sh"

fail=0

got="$(dump_frontmatter 'Payment Flows' '00000000-0000-0000-0000-000000000001' '1' \
  '2026-08-12T15:37:00.000Z')"

# Command substitution strips trailing newlines, so `want` stops at the
# closing `---` too — dump_frontmatter itself still emits the blank line after
# it that separates the header from the page body.
want='---
title: Payment Flows
id: 00000000-0000-0000-0000-000000000001
url: https://app.notion.com/p/00000000000000000000000000000001
depth: 1
edited: 2026-08-12T15:37:00.000Z
---'

if [[ "$got" != "$want" ]]; then
  echo "dump_frontmatter — want:" >&2
  printf '%s' "$want" | sed 's/^/  /' >&2
  echo "got:" >&2
  printf '%s' "$got" | sed 's/^/  /' >&2
  fail=1
fi

# A page Notion never dated (the API returning no last_edited_time) still
# produces a well-formed header — an empty value, not a missing field that
# would shift every line after it.
got_empty="$(dump_frontmatter 'Untitled' '00000000-0000-0000-0000-000000000002' '0' '')"
if [[ "$got_empty" != *$'\nedited: \n'* ]]; then
  echo "dump_frontmatter with empty edited — expected a blank 'edited:' line, got:" >&2
  printf '%s' "$got_empty" | sed 's/^/  /' >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: dump_frontmatter" >&2
  exit 1
fi
echo "ok: dump_frontmatter"
