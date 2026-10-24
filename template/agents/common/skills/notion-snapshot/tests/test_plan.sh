#!/usr/bin/env bash
# Pure guards for deciding whether a Notion walk is safe to commit.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../run.sh
. "$SKILL/run.sh"

fail=0

verdict() {
  local want="$1" got
  got="$(walk_verdict "$2" "$3" "$4")"
  if [[ "$want" != "$got" ]]; then
    echo "walk_verdict('$2', …, $4) — want '$want', got '$got'" >&2
    fail=1
  fi
}

full=$'PAGES=42\nDATABASES=1\nDEEPEST_LEVEL=4\nDEPTH_LIMIT=6\n'
skipped=$'PAGES=42\nSKIPPED_PAGES=yes\n  Legal (abc) — [object_not_found]\n'
truncated=$'PAGES=42\nTRUNCATED_PAGES=yes\n  Protocol Summary (def)\n'

verdict ok '42' "$full" 'no'
verdict 'refuse:empty' '0' $'PAGES=0\n' 'no'
verdict 'refuse:empty' '' '' 'no'
verdict 'refuse:empty' '0' $'PAGES=0\nSKIPPED_PAGES=yes\n' 'yes'
verdict 'refuse:partial' '42' "$skipped" 'no'
verdict partial '42' "$skipped" 'yes'
verdict ok '42' "$truncated" 'no'

budget=$'PAGES=2000\nBUDGET_EXHAUSTED=yes\n(the walk stopped at the 2000-page budget\n'
verdict 'refuse:budget' '2000' "$budget" 'no'
verdict 'refuse:budget' '2000' "$budget" 'yes'
verdict 'refuse:budget' '2000' "$budget$skipped" 'yes'
verdict 'refuse:empty' '0' $'PAGES=0\nBUDGET_EXHAUSTED=yes\n' 'no'
verdict ok '42' $'PAGES=42\nUNREACHABLE_LINKS=yes\n  Teams (abc) — [object_not_found]\n' 'no'

walk_out=$'PAGES=3\nTRUNCATED_PAGES=yes\nProduct Hub (00000000-0000-0000-0000-000000000014) — unreadable blocks: 1\nOdd (00000000-0000-0000-0000-000000000001) — unreadable blocks: ?\n(blocks on these pages could not be read — most often they are not shared\n with the integration; read them in Notion)\n'
want_md=$'  - [Product Hub](https://app.notion.com/p/00000000000000000000000000000014) — нечитаемых блоков: 1\n  - [Odd](https://app.notion.com/p/00000000000000000000000000000001) — нечитаемых блоков: ?'
got_md="$(truncated_pages_md "$walk_out")"
if [[ "$got_md" != "$want_md" ]]; then
  printf 'truncated_pages_md — want:\n%s\ngot:\n%s\n' "$want_md" "$got_md" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAIL: notion-snapshot guards" >&2
  exit 1
fi
echo "ok: walk_verdict, truncated_pages_md"
