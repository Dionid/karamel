#!/usr/bin/env bash
# The tree decides what a page is; prose only decides what else gets fetched.
#
# `walk_seen` claims a page the first time an edge reaches it, so the order the
# edges arrive in determines whether the page counts as part of this tree or as
# a stranger it points at. Following links where they were found made that a
# race against prose. Each case here is one way that race was lost, and all
# three end the same way: `notion-snapshot` commits a tree with pages missing
# from it, and its own guard sees nothing wrong, because the replaced directory
# makes "never read" and "deleted in Notion" the same diff.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

WS="$(mktemp -d "${TMPDIR:-/tmp}/notion-prec-ws.XXXXXX")"
trap 'rm -rf "$WS"' EXIT
printf '{"branch":"main","branchPrefix":"feature/"}\n' > "$WS/harness.json"
mkdir -p "$WS/skill"
cp -R "$SKILL/." "$WS/skill/"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../notion.sh
. "$WS/skill/notion.sh"

fail=0

ROOT=11111111111111111111111111111111
ALPHA=22222222222222222222222222222222   # walked first; the link path starts here
ALPHA2=77777777777777777777777777777777
ALPHA3=88888888888888888888888888888888  # depth 3, and it is what links SHARED
BRAVO=33333333333333333333333333333333   # walked second, OWNS SHARED at depth 2
SHARED=44444444444444444444444444444444
KID=55555555555555555555555555555555     # child of SHARED

UNREADABLE=""
page_markdown_soft() {
  local id="${1//-/}"
  case " $UNREADABLE " in *" $id "*) SOFT_ERR="object_not_found"; return 1 ;; esac
  case "$id" in
    "$ROOT")
      printf '# Root\n\n<page url="https://app.notion.com/p/%s">Alpha</page>\n' "$ALPHA"
      printf '<page url="https://app.notion.com/p/%s">Bravo</page>\n' "$BRAVO" ;;
    "$ALPHA")
      printf '# Alpha\n\n<page url="https://app.notion.com/p/%s">AlphaTwo</page>\n' "$ALPHA2" ;;
    "$ALPHA2")
      printf '# AlphaTwo\n\n<page url="https://app.notion.com/p/%s">AlphaThree</page>\n' "$ALPHA3" ;;
    "$ALPHA3")
      printf '# AlphaThree\n\nMentions [Shared](https://www.notion.so/%s).\n' "$SHARED" ;;
    "$BRAVO")
      printf '# Bravo\n\n<page url="https://app.notion.com/p/%s">Shared</page>\n' "$SHARED" ;;
    "$SHARED")
      printf '# Shared\n\n<page url="https://app.notion.com/p/%s">Kid</page>\n' "$KID" ;;
    *) printf '# %s\n' "$id" ;;
  esac
  MD_TRUNCATED="false"
  return 0
}
page_title_soft() { printf 'Shared'; }

run() {  # run <max-depth> [<unreadable-ids>...]
  local d="$1"; shift
  UNREADABLE="$*"
  walk_init
  WALK_MAX_DEPTH="$d"
  walk "$ROOT" 0 "Root"
  walk_links
}

# --- a page the tree owns is the tree's, however early prose mentions it -----

# Alpha is walked before Bravo and links SHARED; SHARED is unreadable. The
# failure has to be the one that stops the commit, not the one that waves it
# through, because Bravo really does own SHARED and KID underneath it.
run 6 "$SHARED"
if [ -z "$WALK_SKIPPED" ]; then
  echo "FAILED: an unreadable page the tree OWNS must set SKIPPED_PAGES even
when prose linked it first — otherwise the snapshot commits it, and its whole
subtree, as deleted" >&2
  fail=1
fi
if [ -n "$WALK_UNREACHABLE" ]; then
  echo "FAILED: a page the tree owns is never merely 'linked'" >&2
  fail=1
fi

# --- and it keeps its place in the tree -------------------------------------

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notion-prec-out.XXXXXX")"
visit() {  # depth id title md_file dir
  local rel
  rel="$(dump_nested_path "$3" "$2" "${5:-}")"
  mkdir -p "$OUT_DIR${5:+/$5}"
  : > "$OUT_DIR/$rel.md"
  if [ "$1" -eq 0 ]; then VISIT_CHILD_DIR=""; else VISIT_CHILD_DIR="$rel"; fi
}
run 6
if [ ! -f "$OUT_DIR/bravo/shared.md" ]; then
  echo "FAILED: Shared belongs under Bravo, which owns it — found instead:
$(cd "$OUT_DIR" && find . -name '*.md' | sort)" >&2
  fail=1
fi
if [ ! -f "$OUT_DIR/bravo/shared/kid.md" ]; then
  echo "FAILED: a mention must not relocate a page's whole subtree" >&2
  fail=1
fi
rm -rf "$OUT_DIR"
unset -f visit
visit() { :; }

# --- the depth limit is spent on the tree, not on a link --------------------

run 4
if ! grep -qxF "page:${SHARED:0:8}-${SHARED:8:4}-${SHARED:12:4}-${SHARED:16:4}-${SHARED:20:12}" "$WALK_TMP/seen"; then
  echo "FAILED: Shared was never walked at all" >&2
  fail=1
fi
if [ -n "$WALK_UNREACHABLE" ]; then
  echo "FAILED: Shared is owned by the tree; the longer link path must not
turn it into a stranger" >&2
  fail=1
fi
# Alpha's chain reaches SHARED only at depth 4, while Bravo owns it at depth 2.
# With maxDepth 4 the tree can still read SHARED and KID; a link that got there
# first used to claim SHARED at the limit and return before KID was ever read.
if [ "$WALK_PAGES" != "7" ]; then
  echo "FAILED: want root+alpha+alpha2+alpha3+bravo+shared+kid = 7 pages at
maxDepth 4, got $WALK_PAGES — a link reaching a page at the depth limit must
not claim it and strand its children" >&2
  fail=1
fi

# --- a page the tree does NOT own is still reached, and filed as extra -------

OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/notion-prec-out.XXXXXX")"
STRANGER=66666666666666666666666666666666
page_markdown_soft() {
  local id="${1//-/}"
  case " $UNREADABLE " in *" $id "*) SOFT_ERR="object_not_found"; return 1 ;; esac
  case "$id" in
    "$ROOT") printf '# Root\n\nSee [Stranger](https://www.notion.so/%s).\n' "$STRANGER" ;;
    *) printf '# %s\n' "$id" ;;
  esac
  MD_TRUNCATED="false"
  return 0
}
page_title_soft() { printf 'Stranger'; }
visit() {
  local rel
  rel="$(dump_nested_path "$3" "$2" "${5:-}")"
  mkdir -p "$OUT_DIR${5:+/$5}"
  : > "$OUT_DIR/$rel.md"
  if [ "$1" -eq 0 ]; then VISIT_CHILD_DIR=""; else VISIT_CHILD_DIR="$rel"; fi
}
run 6
# Named by id, not just slug: _linked/ is one flat namespace for the whole run,
# ordered by walk order, so two link-reached pages sharing a title would
# otherwise swap file names whenever anything upstream of them moved.
if [ ! -f "$OUT_DIR/_linked/stranger-${STRANGER:0:8}.md" ]; then
  echo "FAILED: a page reached only by a link belongs under _linked/ under a
path derived from its id — found:
$(cd "$OUT_DIR" && find . -name '*.md' | sort)" >&2
  fail=1
fi
if [ "$WALK_LINKED" != "1" ]; then
  echo "FAILED: want 1 followed link, got $WALK_LINKED" >&2
  fail=1
fi
rm -rf "$OUT_DIR"
unset -f visit
visit() { :; }

# --- the budget refuses rather than truncating quietly ----------------------

WALK_MAX_PAGES=1
run 6
if [ -z "$WALK_BUDGET_HIT" ]; then
  echo "FAILED: a walk stopped by the page budget must say so" >&2
  fail=1
fi
if ! grep -q 'BUDGET_EXHAUSTED=yes' <<<"$(walk_summary)"; then
  echo "FAILED: the summary must carry BUDGET_EXHAUSTED for the caller to refuse on" >&2
  fail=1
fi
WALK_MAX_PAGES=2000

if [ "$fail" -ne 0 ]; then
  echo "FAIL: link precedence" >&2
  exit 1
fi
echo "ok: link precedence"
