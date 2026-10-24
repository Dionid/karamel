#!/usr/bin/env bash
# notion.sh — read Notion: one page, a whole subtree, or a database.
#
#   notion.sh roots                                   # what notion.json defines
#   notion.sh whoami                                  # which integration the token is
#   notion.sh page  [<ref>]                           # one page as markdown
#   notion.sh tree  [<ref>] [--depth N] [--no-dbs]    # the subtree as an indented map
#   notion.sh dump  [<ref>] [--depth N] [--out DIR]   # every page of the subtree to files
#                   [--layout ordered|nested]         # numbered by walk order, or stable paths
#   notion.sh grep  <pattern> [<ref>] [--depth N]     # search text across the subtree
#   notion.sh db    <ref> [--limit N] [--csv]         # rows of a database
#   notion.sh search <query>                          # Notion's own workspace search
#   notion.sh edited <ref>                            # last_edited_time of one page, no walk
#
# <ref> is a root name from notion.json, a Notion URL, a dashed uuid or a
# bare 32-hex id. Omitted, it is the manifest's defaultRoot — that is what makes
# "the team page" the thing you can walk without knowing its id.
#
# NOTION_TOKEN is sourced from the workspace root .env and never printed.
# Everything here is READ-ONLY; publishing is the `notion-publish` skill.

set -euo pipefail

NOTION_VERSION="2026-03-11"
API="https://api.notion.com/v1"

# Notion's published limit is ~3 requests/second averaged over time. One walk is
# one request per page, so a deep tree is throttled here rather than by 429s.
RATE_DELAY="${NOTION_RATE_DELAY:-0.34}"
MAX_RETRIES="${NOTION_MAX_RETRIES:-5}"
MD_TRUNCATED="false"

usage() {
  cat <<'EOF'
Usage:
  notion.sh roots
  notion.sh whoami
  notion.sh page   [<ref>]
  notion.sh tree   [<ref>] [--depth N|max] [--no-dbs] [--no-links]
                   [--link-depth N] [--max-pages N] [--cache DIR] [--resume]
  notion.sh dump   [<ref>] [--depth N|max] [--out DIR] [--layout ordered|nested]
                   [--cache DIR] [--resume]
  notion.sh grep   <pattern> [<ref>] [--depth N|max] [--from DIR] [-i]
  notion.sh db     <ref> [--limit N] [--csv]
  notion.sh search <query> [--limit N]
  notion.sh edited <ref>

  <ref>       root name from notion.json, Notion URL, uuid or 32-hex id
              (omitted: the manifest's defaultRoot)
  --depth N   levels below the root; 0 = the root page alone (default: the
              root's maxDepth in the manifest, else 4). "max" means 20.
  --no-dbs    do NOT descend into database rows (they are walked by default)
  --no-links  do NOT follow Notion links found in page text (followed by
              default) — a link leaves the root's own subtree, which is the
              point: a page is reached through whatever points at it
  --link-depth N  how many link hops past the tree to follow (default 2;
              0 follows none, same as --no-links). Tree depth does not bound
              this: a tree ends, a link graph does not
  --cache DIR how to not pay for the same page twice. Keeps each page's
              markdown beside the `last_edited_time` it was rendered at; the
              next walk then asks only "has it changed" and re-fetches the body
              only when it has — about half the requests of a cold walk
  --resume    continue a walk that was interrupted: a cached page is taken
              as-is, costing nothing, so the part already done replays in
              seconds and the walk carries on into what it never reached.
              Needs --cache
  --max-pages N  stop after N pages and say so (default 2000; 0 = no budget).
              A walk that hit the budget is reported as incomplete, because a
              caller that commits it cannot tell the pages it never read from
              pages that were deleted
  --out DIR   where dump writes (default: a notion-<root>-<date> dir in TMPDIR)
  --from DIR  grep an existing dump instead of walking the API again
  --layout    dump file naming: "ordered" (default) numbers files by walk order,
              "nested" mirrors the page tree under stable paths — the one to use
              when the dump is committed, since ordered names shift whenever a
              page is inserted above them
EOF
}

die() { echo "error: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

# The workspace root is the directory holding harness.json. Resolve the symlink
# chain first — .claude/skills/notion/notion.sh is a symlink into the layer.
resolve_workspace_root() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/harness.json" ]; then printf '%s\n' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

ROOT_DIR="$(resolve_workspace_root)" \
  || die "cannot locate the workspace root — no harness.json above ${BASH_SOURCE[0]}"
MANIFEST="$ROOT_DIR/notion.json"

command -v jq >/dev/null 2>&1 || die "jq is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required (to parse page references)"

# The environment first, the file second — the same precedence, and the same
# reason, as the GitHub resolver (`gl_load` in commit-and-mr/lib.sh): on a
# hosted runtime the turn's own credential arrives as process environment,
# while the `.env` mirrored into a session workspace may hold nothing at all.
# Demanding the file outright made this skill unusable on exactly such a
# runtime, with the token sitting right there in the environment.
#
# Returning early rather than sourcing anyway is equivalent, not a shortcut:
# RATE_DELAY, MAX_RETRIES and DB_LIMIT are read at file scope, long before this
# runs, so the token is the only thing `.env` has ever given this script.
load_token() {
  [ -z "${NOTION_TOKEN:+x}" ] || return 0

  local env_file="$ROOT_DIR/.env"
  [ -f "$env_file" ] \
    || die "NOTION_TOKEN is not in the environment, and there is no .env at $ROOT_DIR — set it in either"
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
  [ -n "${NOTION_TOKEN:+x}" ] || die "NOTION_TOKEN is not set in $env_file"
}

# ---------------------------------------------------------------- manifest ---
# The engine is generic; the pages belong to the team, so notion.json lives
# in the team's own repository, not in the engine. A workspace with no
# notion.json still works — every command then needs an explicit <ref>.

manifest_get() {  # manifest_get <jq-filter>
  [ -f "$MANIFEST" ] || { printf '\n'; return 0; }
  jq -r "$1 // empty" "$MANIFEST" 2>/dev/null || printf '\n'
}

cmd_roots() {
  [ -f "$MANIFEST" ] || die "no manifest at $MANIFEST — pass a Notion URL or id explicitly"
  local def
  def="$(manifest_get '.defaultRoot')"
  printf 'MANIFEST=%s\n' "$MANIFEST"
  printf 'DEFAULT_ROOT=%s\n' "${def:-<none>}"
  jq -r '
    .roots // {} | to_entries[] |
    "\n\(.key)
  title:     \(.value.title // "?")
  page:      \(.value.page // "?")
  maxDepth:  \(.value.maxDepth // 4)
  dbs:       \(.value.dbs // true)
  links:     \(.value.links // true)
  maxLinkDepth: \(.value.maxLinkDepth // 2)
  maxPages:  \(.value.maxPages // 2000)
  about:     \(.value.description // "-")"
  ' "$MANIFEST"
}

# ------------------------------------------------------------------- refs ----

# Accepts a manifest root name, a full Notion URL, a dashed uuid or a bare
# 32-hex id, and returns a dashed uuid.
normalize_ref() {
  local raw="$1" id from_manifest
  from_manifest="$(manifest_get ".roots[\"$raw\"].page")"
  if [ -n "$from_manifest" ]; then raw="$from_manifest"; fi

  raw="${raw%%\?*}"
  raw="${raw%%#*}"
  raw="${raw##*/}"
  raw="${raw//-/}"

  [[ "$raw" =~ ([0-9a-fA-F]{32})$ ]] || die "cannot read a Notion page id from: $1
Pass a root name from $MANIFEST, a Notion URL, a uuid or a 32-hex id."
  # Lowercased: the id is the identity the walk dedupes on, and a hand-typed
  # or older Notion URL carries the same page in upper case.
  id="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
  printf '%s-%s-%s-%s-%s\n' \
    "${id:0:8}" "${id:8:4}" "${id:12:4}" "${id:16:4}" "${id:20:12}"
}

default_ref() {
  local def
  def="$(manifest_get '.defaultRoot')"
  [ -n "$def" ] || die "no <ref> given and no defaultRoot in $MANIFEST"
  printf '%s\n' "$def"
}

# The depth a root is meant to be read to, when --depth was not passed.
default_depth_for() {  # default_depth_for <original-ref>
  local d
  d="$(manifest_get ".roots[\"$1\"].maxDepth")"
  printf '%s\n' "${d:-4}"
}

# --------------------------------------------------------------- transport ---

api() {  # api <METHOD> <PATH> [curl args...]
  local method="$1" path="$2"; shift 2
  local attempt=0 resp http body

  while :; do
    sleep "$RATE_DELAY"
    resp="$(curl -sS -X "$method" "$API$path" \
      -H "Authorization: Bearer $NOTION_TOKEN" \
      -H "Notion-Version: $NOTION_VERSION" \
      -H "Content-Type: application/json" \
      -w $'\n%{http_code}' "$@" </dev/null)" || resp=$'\n000'

    http="${resp##*$'\n'}"
    body="${resp%$'\n'*}"

    case "$http" in
      429|500|502|503|504|000)
        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$MAX_RETRIES" ]; then
          printf '%s' "$body"
          return 0
        fi
        note "notion: HTTP $http on $path — retry $attempt/$MAX_RETRIES"
        sleep "$((attempt * 2))"
        ;;
      *)
        printf '%s' "$body"
        return 0
        ;;
    esac
  done
}

api_error() {  # api_error <body> <what>  — dies with Notion's own code/message
  local body="$1" what="$2" code msg
  if [ "$(jq -r '.object // ""' <<<"$body" 2>/dev/null)" = "error" ]; then
    code="$(jq -r '.code // .status // "?"' <<<"$body")"
    msg="$(jq -r '.message // "no message"' <<<"$body")"
    case "$code" in
      object_not_found)
        die "$what failed [$code]: $msg
The integration is probably not connected to this page: in Notion open the page
menu (⋯) → Connections → add the integration. It needs the parent too, not just
the child page." ;;
      unauthorized)
        die "$what failed [$code]: $msg
NOTION_TOKEN is wrong, revoked, or from another workspace." ;;
      *)
        die "$what failed [$code]: $msg" ;;
    esac
  fi
}

page_title() {  # page_title <uuid>
  local body
  body="$(api GET "/pages/$1")"
  api_error "$body" "retrieving page $1"
  jq -r '[.properties[]? | select(.type=="title") | .title[]?.plain_text] | add // ""' <<<"$body"
}

# The markdown endpoint carries no metadata (verified live 2026-09-22: its
# response has only id/markdown/object/request_id/truncated/unknown_block_ids),
# so a page's own last_edited_time costs a second GET per page — there is no
# way to fold it into the one the walk already makes.
page_edited_time() {  # page_edited_time <uuid>
  local body
  body="$(api GET "/pages/$1")"
  api_error "$body" "retrieving page $1"
  jq -r '.last_edited_time // ""' <<<"$body"
}

# The title of a page the walk already proved readable; empty rather than fatal,
# same reasoning as page_edited_time_soft below.
page_title_soft() {  # page_title_soft <uuid>
  local body
  body="$(api GET "/pages/$1")"
  if [ "$(jq -r '.object // ""' <<<"$body" 2>/dev/null)" = "error" ]; then
    printf ''
    return 0
  fi
  jq -r '[.properties[]? | select(.type=="title") | .title[]?.plain_text] | add // ""' <<<"$body"
}

# Like page_edited_time, but for use inside a walk that already read this page
# via page_markdown_soft: that call proved the page reachable, and a dump
# minutes into a 100+-page tree should not die on the *second* request for a
# page the first one already succeeded on. Empty output on failure, same as an
# empty last_edited_time — the frontmatter carries a blank `edited` rather than
# aborting the run.
page_edited_time_soft() {  # page_edited_time_soft <uuid>
  local body
  body="$(api GET "/pages/$1")"
  if [ "$(jq -r '.object // ""' <<<"$body" 2>/dev/null)" = "error" ]; then
    printf ''
    return 0
  fi
  jq -r '.last_edited_time // ""' <<<"$body"
}

# `<cache>/<id>.md` is the markdown, `<cache>/<id>.meta` the three facts needed
# to serve it again faithfully: what it was edited at, and whether the render
# was truncated. Plain `key=value` lines read field by field — never sourced,
# because the cache is written by one run and read by another.
cache_meta_get() {  # cache_meta_get <id> <key>
  [ -n "$WALK_CACHE" ] || return 1
  local f="$WALK_CACHE/$1.meta"
  [ -f "$f" ] || return 1
  sed -n "s/^$2=//p" "$f" | head -n 1
}

CACHE_WRITE_FAILED=""
cache_store() {  # cache_store <id> <markdown-file> <edited>
  [ -n "$WALK_CACHE" ] || return 0
  # Said once, not per page, and said at all: the whole plan is that the cache
  # accumulates across attempts the runtime keeps killing, and a cache that
  # cannot be written reports FROM_CACHE=0 — byte-identical to a healthy first
  # run. Without this, the third attempt dies in the same place as the first
  # with nothing to explain why.
  if ! cp "$2" "$WALK_CACHE/$1.md" 2>/dev/null; then
    [ -n "$CACHE_WRITE_FAILED" ] || note "notion: cannot write to the cache at $WALK_CACHE — this run will not make the next one cheaper"
    CACHE_WRITE_FAILED=yes
    return 0
  fi
  if ! printf 'edited=%s\ntruncated=%s\nunreadable=%s\n' \
    "$3" "$MD_TRUNCATED" "$MD_UNREADABLE" > "$WALK_CACHE/$1.meta" 2>/dev/null; then
    [ -n "$CACHE_WRITE_FAILED" ] || note "notion: cannot write cache metadata at $WALK_CACHE — this run will not make the next one cheaper"
    CACHE_WRITE_FAILED=yes
  fi
}

# Markdown of one page, from the cache when the cache can answer. Same contract
# as page_markdown_soft — 0 and the markdown on <out>, 1 and SOFT_ERR set — plus
# MD_TRUNCATED, MD_UNREADABLE and PAGE_EDITED as side effects.
page_markdown_cached() {  # page_markdown_cached <uuid> <out>
  local id="$1" out="$2" cached_edited live_edited="" cached_truncated
  PAGE_EDITED=""

  if [ -z "$WALK_CACHE" ]; then
    page_markdown_soft "$id" > "$out"
    return
  fi

  cached_edited="$(cache_meta_get "$id" edited || true)"

  if [ -n "$cached_edited" ] && [ -f "$WALK_CACHE/$id.md" ]; then
    if [ "$WALK_RESUME" -eq 1 ]; then
      # Resume asks nothing at all. The run it continues already decided these
      # pages were current; re-checking them is the cost it died of.
      live_edited="$cached_edited"
    else
      live_edited="$(page_edited_time_soft "$id")"
    fi
    if [ -n "$live_edited" ] && [ "$live_edited" = "$cached_edited" ]; then
      cached_truncated="$(cache_meta_get "$id" truncated)"
      # A truncated render is not always a property of the page: `api` gives up
      # after its retries, and a 429 in the middle of a three-hour walk renders
      # one block as a placeholder. Cached and re-served, that freezes the page
      # in its broken form for every later run — the page's own edited time
      # never moves, so nothing ever retries it. A refresh therefore refetches
      # a truncated entry; resume still takes it, because resume's job is to
      # replay cheaply and the closing non-resume run is what heals it.
      if [ "$WALK_RESUME" -eq 1 ] || [ "${cached_truncated:-false}" != "true" ]; then
        cat "$WALK_CACHE/$id.md" > "$out"
        cached_truncated="${cached_truncated:-false}"
        MD_TRUNCATED="$cached_truncated"
        MD_UNREADABLE="$(cache_meta_get "$id" unreadable)"
        MD_UNREADABLE="${MD_UNREADABLE:-0}"
        PAGE_EDITED="$cached_edited"
        WALK_CACHED=$((WALK_CACHED + 1))
        return 0
      fi
    fi
  fi

  # The timestamp is taken BEFORE the body, and reused when the check above
  # already fetched it. Both halves matter. Asking after the body stores the
  # new time next to the old text whenever the page is edited mid-fetch, and
  # that page is then current forever — invisible even to `notion.sh edited`,
  # which compares against exactly this value. Asking twice also made a changed
  # page cost three requests where a cold walk costs two.
  [ -n "$live_edited" ] || live_edited="$(page_edited_time_soft "$id")"
  page_markdown_soft "$id" > "$out" || return 1
  WALK_REFETCHED=$((WALK_REFETCHED + 1))
  PAGE_EDITED="$live_edited"
  cache_store "$id" "$out" "$PAGE_EDITED"
  return 0
}

# Like page_markdown, but a page the integration cannot read is reported and
# skipped rather than killing a walk that is already minutes in. Notion trees
# routinely mix pages shared with the integration and pages that are not.
page_markdown_soft() {  # page_markdown_soft <uuid>
  local body
  body="$(api GET "/pages/$1/markdown")"
  if [ "$(jq -r '.object // ""' <<<"$body" 2>/dev/null)" = "error" ]; then
    SOFT_ERR="$(jq -r '.code // .status // "?"' <<<"$body")"
    return 1
  fi
  markdown_of_body "$body"
}

# Markdown of one page. Sets MD_TRUNCATED as a side effect.
page_markdown() {  # page_markdown <uuid>
  local body
  body="$(api GET "/pages/$1/markdown")"
  api_error "$body" "retrieving markdown of page $1"
  markdown_of_body "$body"
}

# The markdown endpoint answers `truncated: true` whenever it met a block it
# could not render, and leaves `<unknown url="…#<block>" alt="<type>"/>` where
# that block stood. Measured on a 309-page tree (2026-10-06): 137 such blocks on
# 85 pages, and 76 of them were breadcrumbs — navigation with no text at all.
# The rest were link previews, embeds, images and plain list items that the
# blocks API reads fine, plus a handful the integration has no access to.
# Reporting all 85 pages as partial hid the few that really were.
#
# So each placeholder is resolved where it stands: content-free blocks are
# dropped, readable ones are rendered from GET /blocks/<id>, and only what stays
# unreadable keeps the page truncated. Sets MD_TRUNCATED and MD_UNREADABLE
# (how many blocks are still missing) as side effects; prints the markdown.
MD_UNREADABLE=0
markdown_of_body() {  # markdown_of_body <markdown-endpoint-body>
  local body="$1"
  MD_TRUNCATED="$(jq -r '.truncated // false' <<<"$body")"
  MD_UNREADABLE=0
  if [ "$MD_TRUNCATED" != "true" ]; then
    jq -r '.markdown // ""' <<<"$body"
    return 0
  fi

  local tmp bid alt blk
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/notion-unknown.XXXXXX")"
  jq -r '.markdown // ""' <<<"$body" > "$tmp/md"
  jq -r '.unknown_block_ids[]? // empty' <<<"$body" > "$tmp/unknown"
  : > "$tmp/blocks"
  while IFS=$'\t' read -r bid alt; do
    [ -n "${bid:-}" ] || continue
    if unknown_alt_is_empty "$alt"; then continue; fi
    blk="$(api GET "/blocks/$bid")"
    jq -c --arg id "$bid" '{id: $id, block: .}' <<<"$blk" >> "$tmp/blocks" 2>/dev/null || true
  done < <(python3 -c "$UNKNOWN_IDS_PY" "$tmp/md")

  # Any failure here keeps the page truncated and its markdown as the API gave
  # it: a resolver that died must not turn into an empty page reported whole.
  # The walk calls this inside an `if`, where set -e is off, so check by hand.
  MD_UNREADABLE="?"
  if python3 -c "$RESOLVE_UNKNOWN_PY" "$tmp/md" "$tmp/blocks" "$tmp/unknown" "$tmp/left" \
       > "$tmp/out" 2>/dev/null && [ -f "$tmp/left" ]; then
    MD_UNREADABLE="$(cat "$tmp/left")"
    cat "$tmp/out"
  else
    cat "$tmp/md"
  fi
  if [ "$MD_UNREADABLE" = "0" ]; then MD_TRUNCATED="false"; fi
  rm -rf "$tmp"
}

# Placeholders whose block carries no text — navigation, a generated table of
# contents, an action button: dropped without asking the API.
unknown_alt_is_empty() {  # unknown_alt_is_empty <alt>
  case "$1" in breadcrumb|table_of_contents|button) return 0 ;; *) return 1 ;; esac
}

# Prints "<dashed-block-id> TAB <alt>" for every placeholder in a markdown file.
UNKNOWN_IDS_PY=$(cat <<'PY'
import re, sys

md = open(sys.argv[1], encoding='utf-8').read()
seen = set()
for m in re.finditer(r'<unknown\b([^>]*?)/?>', md):
    attrs = m.group(1)
    url = re.search(r'\burl="([^"]*)"', attrs)
    ids = re.findall(r'[0-9a-fA-F]{32}', url.group(1)) if url else []
    if not ids or ids[-1].lower() in seen:
        continue  # one GET per block, however often it is placed
    h = ids[-1].lower()
    seen.add(h)
    alt = re.search(r'\balt="([^"]*)"', attrs)
    print('%s-%s-%s-%s-%s\t%s' % (h[:8], h[8:12], h[12:16], h[16:20], h[20:],
                                  alt.group(1) if alt else ''))
PY
)

# resolve <markdown> <blocks.jsonl> <unknown-ids> <left-file>
# Rewrites every placeholder it can, prints the markdown, and writes how many
# blocks remain unreadable to <left-file>. Pure: no API, so it is testable.
RESOLVE_UNKNOWN_PY=$(cat <<'PY'
import json, re, sys

md_path, blocks_path, unknown_path, left_path = sys.argv[1:5]
md = open(md_path, encoding='utf-8').read()

blocks = {}
for line in open(blocks_path, encoding='utf-8'):
    line = line.strip()
    if line:
        rec = json.loads(line)
        blocks[rec['id'].replace('-', '').lower()] = rec['block']

unknown = set()
for line in open(unknown_path, encoding='utf-8'):
    if line.strip():
        unknown.add(line.strip().replace('-', '').lower())

EMPTY = {'breadcrumb', 'table_of_contents', 'button'}
PREFIX = {
    'paragraph': '', 'bulleted_list_item': '- ', 'numbered_list_item': '1. ',
    'toggle': '- ', 'quote': '> ', 'callout': '> ',
    'heading_1': '# ', 'heading_2': '## ', 'heading_3': '### ', 'heading_4': '#### ',
}
LINKS = {'link_preview', 'embed', 'bookmark'}
FILES = {'image', 'video', 'file', 'pdf', 'audio'}

def rich(items):
    out = []
    for it in items or []:
        t = it.get('plain_text', '')
        if not t:
            continue
        a = it.get('annotations') or {}
        core, lead, trail = t.strip(), t[:len(t) - len(t.lstrip())], t[len(t.rstrip()):]
        if core:
            if a.get('code'):
                core = '`%s`' % core
            if a.get('bold'):
                core = '**%s**' % core
            if a.get('italic'):
                core = '*%s*' % core
            if it.get('href'):
                core = '[%s](%s)' % (core, it['href'])
        out.append(lead + core + trail)
    return ''.join(out)

def render(block, anchor):
    """Markdown for one block, or None when it cannot be rendered faithfully.
    The second value is False when the block has children left unread."""
    if block.get('object') != 'block':
        return None, False
    t = block.get('type', '')
    d = block.get(t) or {}
    if t in EMPTY:
        return '', True
    if t == 'divider':
        return '---', True
    caption = rich(d.get('caption'))
    if t in LINKS and d.get('url'):
        return '[%s](%s)' % (caption or t.replace('_', ' '), d['url']), True
    if t in FILES:
        label = caption or d.get('name') or t
        if d.get('type') == 'external' and (d.get('external') or {}).get('url'):
            url = d['external']['url']
            return ('![%s](%s)' if t == 'image' else '[%s](%s)') % (label, url), True
        # A Notion-hosted file is a signed URL that expires within the hour:
        # committing it would change every run. The block's own anchor is stable.
        return '[%s: %s](%s)' % (t, label, anchor), True
    if t == 'code':
        return '```%s\n%s\n```' % (d.get('language', ''), rich(d.get('rich_text'))), \
            not block.get('has_children')
    if t == 'to_do':
        return '- [%s] %s' % ('x' if d.get('checked') else ' ', rich(d.get('rich_text'))), \
            not block.get('has_children')
    if t in PREFIX:
        return PREFIX[t] + rich(d.get('rich_text')), not block.get('has_children')
    return None, False

left = 0
seen = set()
out_lines = []
pat = re.compile(r'<unknown\b([^>]*?)/?>')
for line in md.split('\n'):
    indent = line[:len(line) - len(line.lstrip())]

    def sub(m):
        global left
        attrs = m.group(1)
        url = re.search(r'\burl="([^"]*)"', attrs)
        anchor = url.group(1) if url else ''
        ids = re.findall(r'[0-9a-fA-F]{32}', anchor)
        alt = re.search(r'\balt="([^"]*)"', attrs)
        bid = ids[-1].lower() if ids else ''
        seen.add(bid)
        if alt and alt.group(1) in EMPTY:
            return ''
        text, complete = render(blocks.get(bid, {}), anchor)
        if text is None:
            left += 1
            return m.group(0)
        if not complete:
            left += 1
        return text.replace('\n', '\n' + indent)

    new = pat.sub(sub, line)
    if new != line and not new.strip():
        continue  # the line held only a dropped placeholder
    out_lines.append(new)

# Blocks the API named as unknown but left no placeholder for: still missing.
left += len(unknown - seen)
sys.stdout.write('\n'.join(out_lines))
# `truncated` with nothing to resolve is a cut this resolver cannot see — say
# "unknown" rather than 0, so the page is not reported whole.
open(left_path, 'w').write(str(left) if (seen or unknown) else '?')
PY
)

# ------------------------------------------------------------------ parsing --
# The markdown rendering is what makes deep reading cheap: it names every child
# page and database inline, so one request per page yields both the content and
# the next level of the tree.
#
#   <page url="https://app.notion.com/p/<32hex>">Title</page>
#   <database url="..." inline="true|false" data-source-url="collection://<uuid>">Title</database>
#
# Those two tags are the page TREE. A page also points at pages that are not
# its children — a mention, a link in a sentence — and those render as ordinary
# markdown links to a Notion URL. They are extracted too, as kind `link`, so a
# walk reaches a page through whatever points at it and not only through the
# parent that happens to own it. Structural entries are emitted FIRST: when a
# page is both a child and linked, the walk must place it where the tree says,
# or a nested dump would move files around depending on prose.
#
# Output is \x1f-separated: kind, id, data-source-id, title

EXTRACT_PY=$(cat <<'PY'
import re, sys

md = open(sys.argv[1], encoding='utf-8').read()
follow_links = len(sys.argv) > 2 and sys.argv[2] == '1'
seen = set()
structural = []
links = []

tag = re.compile(r'<(page|database)\b([^>]*?)>(.*?)</\1>', re.S)


def clean(text):
    text = re.sub(r'\\(.)', r'\1', text).strip()
    return re.sub(r'\s+', ' ', text)


for m in tag.finditer(md):
    kind, attrs, title = m.group(1), m.group(2), m.group(3)

    url = re.search(r'\burl="([^"]*)"', attrs)
    if not url:
        continue
    ids = re.findall(r'[0-9a-fA-F]{32}', url.group(1))
    if not ids:
        continue
    pid = ids[-1].lower()

    ds = re.search(r'data-source-url="collection://([0-9a-fA-F-]+)"', attrs)
    ds_id = ds.group(1) if ds else ''

    # A database can appear several times on one page (the source plus inline
    # linked views). They are the same rows, so dedupe on the data source.
    key = ('db', ds_id or pid) if kind == 'database' else ('page', pid)
    if key in seen:
        continue
    seen.add(key)
    # A database is also reachable by its own page URL, and pages routinely
    # link to a database they already carry inline. Claiming the id here keeps
    # the link scanner below from re-emitting it as a page that does not exist.
    seen.add(('page', pid))

    structural.append('\x1f'.join((kind, pid, ds_id, clean(title))))

# Links live in the prose, so the structural tags are blanked out first: their
# own href attributes are the same ids, already emitted above, and `<unknown>`
# carries a BLOCK anchor that is not a page at all.
if follow_links:
    prose = tag.sub(' ', md)
    prose = re.sub(r'<unknown\b[^>]*?/?>', ' ', prose)

    URL = (r'https?://(?:www\.)?(?:notion\.so|notion\.site|app\.notion\.com)'
           r'/[^\s)\]"\x27<>]+')

    titled = {}
    for m in re.finditer(r'\[([^\]]*)\]\((' + URL + r')\)', prose):
        titled.setdefault(m.group(2), clean(m.group(1)))

    for m in re.finditer(URL, prose):
        url = m.group(0)
        # `#<32hex>` is a block anchor and `?v=<32hex>` a database view: either
        # one read as the target would send the walk at something that is not a
        # page, and the 404 would be reported as a hole in the tree.
        path = url.split('#', 1)[0].split('?', 1)[0]
        ids = re.findall(r'[0-9a-fA-F]{32}', path)
        if not ids:
            continue
        pid = ids[-1].lower()
        if ('page', pid) in seen:
            continue
        seen.add(('page', pid))
        links.append('\x1f'.join(('link', pid, '', titled.get(url, ''))))

out = structural + links
sys.stdout.write('\n'.join(out) + ('\n' if out else ''))
PY
)

extract_children() {  # extract_children <markdown-file>
  python3 -c "$EXTRACT_PY" "$1" "$WALK_LINKS"
}

# -------------------------------------------------------------------- walk ---
# Depth-first, one request per page, cycle-safe. Children are read from a file
# rather than a pipe so the recursion stays in this shell.

WALK_TMP=""
WALK_PAGES=0
WALK_DBS=0
WALK_LINKED=0
# Defaults for a sourced notion.sh (tests, and any caller that walks without
# going through parse_walk_flags): deep in both directions, same as the CLI.
WALK_WITH_DBS=1
WALK_LINKS=1
WALK_MAX_DEPTH=4
WALK_MAX_LINK_DEPTH=2
WALK_MAX_PAGES=2000
WALK_DEEPEST=0
WALK_TRUNCATED=""
WALK_SKIPPED=""
WALK_UNREACHABLE=""
WALK_BUDGET_HIT=""
WALK_LINK_HOP=0
SOFT_ERR=""

# Where a page reached only by a link is written, and at what depth. Not the
# linking page's own directory: who mentioned it first is a property of prose,
# and the nested layout exists so that a committed path does not move when
# somebody writes a sentence. Depth 1 rather than 0 because the dump treats
# depth 0 as "the root page, whose children go to the top".
WALK_LINK_DIR="_linked"
WALK_LINK_DEPTH_BASE=1

# The page cache. Keyed by page id, it holds the rendered markdown next to the
# `last_edited_time` it was rendered at, so a later walk can tell the two
# questions apart: "has this page changed" costs one request, "what does it say"
# costs another, and only the first has to be asked every time.
#
# Two behaviours come out of that, and they are the two halves of the same
# problem. Without --resume the cache is a REFRESH: every page is asked for its
# edited time, and the markdown is re-fetched only when that moved — half the
# requests of a cold walk. With --resume a cached page is taken as-is and costs
# nothing, which is what lets a walk that was killed carry on instead of
# starting the root over. A full walk of a large root does not fit in every
# runtime's patience, and before this it had no way to make partial progress.
WALK_CACHE=""
WALK_RESUME=0
WALK_CACHED=0
WALK_REFETCHED=0
# Set by page_markdown_cached so the dump's own frontmatter does not pay for a
# second GET of the same `last_edited_time`.
PAGE_EDITED=""

walk_init() {
  WALK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/notion-walk.XXXXXX")"
  : > "$WALK_TMP/seen"
  : > "$WALK_TMP/linkq.seen"
  WALK_PAGES=0; WALK_DBS=0; WALK_LINKED=0; WALK_DEEPEST=0
  WALK_CACHED=0; WALK_REFETCHED=0
  WALK_TRUNCATED=""; WALK_SKIPPED=""; WALK_UNREACHABLE=""; WALK_BUDGET_HIT=""
  WALK_LINK_HOP=0
  trap 'rm -rf "$WALK_TMP"' EXIT
}

walk_seen() {  # walk_seen <key> — true if already visited, records it otherwise
  if grep -qxF "$1" "$WALK_TMP/seen" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$1" >> "$WALK_TMP/seen"
  return 1
}

# Overridden per command: called for every page as it is read.
# visit <depth> <id> <title> <markdown-file> <dir>
#
# <dir> is where this page's own output belongs, relative to the run's root, and
# it is empty at the top. A visit that writes files answers with the directory
# its children belong in, through VISIT_CHILD_DIR — the walk reads that back
# before descending, which is how a nested layout stays a tree without the walk
# itself knowing anything about file names. A visit that ignores it leaves it
# empty and every page stays at the root, which is what the flat layouts want.
visit() { :; }
# visit_db <depth> <id> <data-source-id> <title> <dir>
visit_db() { :; }
VISIT_CHILD_DIR=""

# <origin> is `child` for a page the tree owns and `link` for one reached
# through a mention. The difference is only about failure: an unreadable CHILD
# is a hole in the tree, and a snapshot that committed it would delete the pages
# below it, so the walk reports it loudly. An unreadable LINK is a page that was
# never part of this tree — pointing at something is not the same as containing
# it — and treating it as a hole would make every run of a linked tree refuse to
# commit.
walk() {  # walk <uuid> <depth> <title> [<dir>] [<origin>]
  local id="$1" depth="$2" title="$3" dir="${4:-}" origin="${5:-child}"
  if [ "$depth" -gt "$WALK_MAX_DEPTH" ]; then return 0; fi
  # Checked before `walk_seen` records anything: a page the budget stopped must
  # stay unvisited, so a later run — or a later edge — can still reach it.
  if [ "$WALK_MAX_PAGES" -gt 0 ] && [ "$WALK_PAGES" -ge "$WALK_MAX_PAGES" ]; then
    WALK_BUDGET_HIT="yes"
    return 0
  fi
  if walk_seen "page:$id"; then return 0; fi

  local md_file="$WALK_TMP/$id.md"
  if ! page_markdown_cached "$id" "$md_file"; then
    # Under --resume the list of children came out of a CACHED parent, so a
    # child that has since been deleted in Notion is the expected answer, not a
    # hole in the tree. Counting it as SKIPPED_PAGES would make any ordinary
    # deletion refuse the whole run, and the only documented escape
    # (--allow-partial) commits a tree with a real hole in it. The closing
    # non-resume run reads the parent live and stops naming the dead child.
    if [ "$origin" = "link" ] || { [ "$WALK_RESUME" -eq 1 ] && [ "$SOFT_ERR" = "object_not_found" ]; }; then
      WALK_UNREACHABLE="$WALK_UNREACHABLE  ${title:-(untitled)} ($id) — $SOFT_ERR
"
    else
      WALK_SKIPPED="$WALK_SKIPPED  $title ($id) — $SOFT_ERR
"
    fi
    return 0
  fi

  if [ "$origin" = "link" ]; then
    WALK_LINKED=$((WALK_LINKED + 1))
    # A bare URL carries no text to name the page with, and the nested layout
    # builds file names out of titles: ask for the real one rather than filing
    # every such page under the same slug.
    [ -n "$title" ] || title="$(page_title_soft "$id")"
    [ -n "$title" ] || title="$id"
  fi

  if [ "$MD_TRUNCATED" = "true" ]; then
    WALK_TRUNCATED="$WALK_TRUNCATED$title ($id) — unreadable blocks: $MD_UNREADABLE
"
  fi
  WALK_PAGES=$((WALK_PAGES + 1))
  if [ "$depth" -gt "$WALK_DEEPEST" ]; then WALK_DEEPEST="$depth"; fi

  VISIT_CHILD_DIR=""
  visit "$depth" "$id" "$title" "$md_file" "$dir"
  # Read back before descending: the recursion below overwrites the global.
  local kids_dir="$VISIT_CHILD_DIR"

  if [ "$depth" -eq "$WALK_MAX_DEPTH" ]; then return 0; fi

  local kids="$WALK_TMP/kids.$id"
  extract_children "$md_file" > "$kids"

  local kind cid ds ctitle rows_dir
  while IFS=$'\x1f' read -r kind cid ds ctitle; do
    [ -n "${cid:-}" ] || continue
    case "$kind" in
      page)
        walk "$(normalize_ref "$cid")" "$((depth + 1))" "$ctitle" "$kids_dir"
        ;;
      link)
        walk_enqueue_link "$(normalize_ref "$cid")" "$ctitle"
        ;;
      database)
        if walk_seen "db:${ds:-$cid}"; then continue; fi
        WALK_DBS=$((WALK_DBS + 1))
        VISIT_CHILD_DIR=""
        visit_db "$((depth + 1))" "$cid" "$ds" "$ctitle" "$kids_dir"
        rows_dir="$VISIT_CHILD_DIR"
        if [ "$WALK_WITH_DBS" -eq 1 ] && [ -n "$ds" ]; then
          walk_db_rows "$ds" "$((depth + 2))" "$rows_dir"
        fi
        ;;
    esac
  done < "$kids"
}

# Links are collected while the tree is walked and followed only once it is
# exhausted. The ordering is the whole correctness argument, not an
# optimisation: `walk_seen` claims a page the moment it is first reached, so
# whichever edge arrives first decides what that page IS — a member of this
# tree, or a stranger the tree points at. Following links as they were met made
# that a race against prose, and three separate failures fell out of it:
#
#   - an unreadable CHILD that something happened to link first was reported as
#     a merely-unreachable link, so the snapshot committed — and its guard saw
#     nothing wrong with deleting that page and everything under it;
#   - a mention moved a page, and its whole directory, away from the parent that
#     owns it, which is exactly the churn the nested layout exists to prevent;
#   - a link landing on a page at exactly the depth limit claimed it and then
#     returned before reading its children, dropping them with no refusal.
#
# Draining afterwards makes the question decidable: by then `walk_seen` knows
# the tree's full membership, so a link can only ever reach a page the tree does
# not own.
walk_enqueue_link() {  # walk_enqueue_link <uuid> <title>
  [ "$WALK_LINKS" -eq 1 ] || return 0
  [ "$WALK_LINK_HOP" -lt "$WALK_MAX_LINK_DEPTH" ] || return 0
  if grep -qxF "$1" "$WALK_TMP/linkq.seen" 2>/dev/null; then return 0; fi
  printf '%s\n' "$1" >> "$WALK_TMP/linkq.seen"
  # "$2", not "$title": bash scopes dynamically, and the caller's $title is the
  # title of the page doing the linking.
  printf '%s\x1f%s\n' "$1" "$2" >> "$WALK_TMP/linkq.$((WALK_LINK_HOP + 1))"
}

# One pass per hop: pages linked from the tree, then pages linked from those.
# Hops are bounded separately from tree depth because the two are different
# shapes — a tree ends, a link graph does not, and a root on maxDepth 9999
# would otherwise hand the walk the whole workspace.
walk_links() {
  [ "$WALK_LINKS" -eq 1 ] || return 0
  local hop=1 qfile id title
  while [ "$hop" -le "$WALK_MAX_LINK_DEPTH" ]; do
    qfile="$WALK_TMP/linkq.$hop"
    [ -f "$qfile" ] || break
    WALK_LINK_HOP="$hop"
    while IFS=$'\x1f' read -r id title; do
      [ -n "${id:-}" ] || continue
      [ -z "$WALK_BUDGET_HIT" ] || break
      walk "$id" "$WALK_LINK_DEPTH_BASE" "$title" "$WALK_LINK_DIR" link
    done < "$qfile"
    hop=$((hop + 1))
  done
  WALK_LINK_HOP=0
}

walk_db_rows() {  # walk_db_rows <data-source-id> <depth> [<dir>]
  local ds="$1" depth="$2" dir="${3:-}" cursor="" body rows
  if [ "$depth" -gt "$WALK_MAX_DEPTH" ]; then return 0; fi

  while :; do
    if [ -n "$cursor" ]; then
      body="$(api POST "/data_sources/$ds/query" --data "$(jq -n --arg c "$cursor" '{page_size:100, start_cursor:$c}')")"
    else
      body="$(api POST "/data_sources/$ds/query" --data '{"page_size":100}')"
    fi
    if [ "$(jq -r '.object // ""' <<<"$body")" = "error" ]; then
      note "notion: cannot query data source $ds — $(jq -r '.message // "?"' <<<"$body")"
      return 0
    fi

    rows="$WALK_TMP/rows.$ds"
    jq -r '.results[]? | [.id, ([.properties[]? | select(.type=="title") | .title[]?.plain_text] | add // "(untitled)")] | @tsv' <<<"$body" > "$rows"

    local rid rtitle
    while IFS=$'\t' read -r rid rtitle; do
      [ -n "${rid:-}" ] || continue
      # Normalised like every other call site: the cache key and walk_seen both
      # ride on this id, and a dashed/undashed mix would double a row's cost
      # and cache it twice without ever failing visibly.
      walk "$(normalize_ref "$rid")" "$depth" "$rtitle" "$dir"
    done < "$rows"

    if [ "$(jq -r '.has_more // false' <<<"$body")" = "true" ]; then
      cursor="$(jq -r '.next_cursor // ""' <<<"$body")"
      [ -n "$cursor" ] || break
    else
      break
    fi
  done
}

walk_summary() {
  printf '\nPAGES=%s\nDATABASES=%s\nLINKED_PAGES=%s\nDEEPEST_LEVEL=%s\nDEPTH_LIMIT=%s\nLINK_DEPTH_LIMIT=%s\nPAGE_BUDGET=%s\n' \
    "$WALK_PAGES" "$WALK_DBS" "$WALK_LINKED" "$WALK_DEEPEST" "$WALK_MAX_DEPTH" \
    "$WALK_MAX_LINK_DEPTH" "$WALK_MAX_PAGES"
  if [ -n "$WALK_CACHE" ]; then
    printf 'FROM_CACHE=%s\nFETCHED=%s\nCACHE=%s\n' \
      "$WALK_CACHED" "$WALK_REFETCHED" "$WALK_CACHE"
  fi
  if [ -n "$WALK_SKIPPED" ]; then
    printf 'SKIPPED_PAGES=yes\n%s' "$WALK_SKIPPED"
    printf '(these were not read — the tree below them is missing from this run)\n'
  fi
  if [ -n "$WALK_BUDGET_HIT" ]; then
    # Reported like a hole in the tree, and refused the same way by callers that
    # commit a walk: the pages the budget cut off are indistinguishable, from
    # the outside, from pages that were deleted in Notion.
    printf 'BUDGET_EXHAUSTED=yes\n'
    printf '(the walk stopped at the %s-page budget — it is NOT the whole tree.\n' "$WALK_MAX_PAGES"
    printf ' Raise --max-pages, or narrow the walk with --depth/--link-depth/--no-links)\n'
  fi
  if [ -n "$WALK_UNREACHABLE" ]; then
    # Deliberately not SKIPPED_PAGES: nothing is missing from the tree, these
    # are pages it merely points at. notion-snapshot keys its refusal off
    # SKIPPED_PAGES, and a link into someone else's space must not stop a
    # snapshot that is otherwise whole.
    printf 'UNREACHABLE_LINKS=yes\n%s' "$WALK_UNREACHABLE"
    printf '(linked pages the integration cannot read — they are not part of\n'
    printf ' this tree, so nothing is missing from the snapshot because of them)\n'
  fi
  if [ -n "$WALK_TRUNCATED" ]; then
    printf 'TRUNCATED_PAGES=yes\n%s' "$WALK_TRUNCATED"
    printf '(blocks on these pages could not be read — most often they are not shared\n'
    printf ' with the integration; read them in Notion)\n'
  fi
  if [ "$WALK_DEEPEST" -eq "$WALK_MAX_DEPTH" ]; then
    printf 'NOTE=the depth limit was reached; there may be more below (--depth %s)\n' \
      "$((WALK_MAX_DEPTH + 2))"
  fi
}

# ---------------------------------------------------------------- commands ---

# Reading is deep by default: database rows and links are walked unless asked
# otherwise. The flags that used to turn them ON still parse — a caller that
# passes --dbs gets what it asked for — but they now only pin the default
# against a manifest that opts out.
parse_walk_flags() {  # consumes --depth/--dbs/--links/--out/--from/--layout/-i, rest in REST
  REST=()
  DEPTH_SET=0
  WALK_WITH_DBS=1
  DBS_SET=0
  WALK_LINKS=1
  LINKS_SET=0
  WALK_MAX_LINK_DEPTH=2
  LINK_DEPTH_SET=0
  WALK_MAX_PAGES=2000
  MAX_PAGES_SET=0
  WALK_CACHE=""
  WALK_RESUME=0
  OUT_DIR=""
  FROM_DIR=""
  GREP_FLAGS=""
  DUMP_LAYOUT="ordered"
  while [ $# -gt 0 ]; do
    case "$1" in
      --depth) [ $# -ge 2 ] || die "--depth needs a value"
               if [ "$2" = "max" ]; then WALK_MAX_DEPTH=20; else WALK_MAX_DEPTH="$2"; fi
               case "$WALK_MAX_DEPTH" in ''|*[!0-9]*) die "--depth takes a number or 'max'";; esac
               DEPTH_SET=1; shift 2 ;;
      --dbs)   WALK_WITH_DBS=1; DBS_SET=1; shift ;;
      --no-dbs) WALK_WITH_DBS=0; DBS_SET=1; shift ;;
      --links) WALK_LINKS=1; LINKS_SET=1; shift ;;
      --no-links) WALK_LINKS=0; LINKS_SET=1; shift ;;
      --link-depth) [ $# -ge 2 ] || die "--link-depth needs a number"
               WALK_MAX_LINK_DEPTH="$2"
               case "$WALK_MAX_LINK_DEPTH" in ''|*[!0-9]*) die "--link-depth takes a number";; esac
               LINK_DEPTH_SET=1; shift 2 ;;
      --cache) [ $# -ge 2 ] || die "--cache needs a directory"
               WALK_CACHE="$2"; shift 2 ;;
      --resume) WALK_RESUME=1; shift ;;
      --max-pages) [ $# -ge 2 ] || die "--max-pages needs a number"
               WALK_MAX_PAGES="$2"
               case "$WALK_MAX_PAGES" in ''|*[!0-9]*) die "--max-pages takes a number (0 = no budget)";; esac
               MAX_PAGES_SET=1; shift 2 ;;
      --out)   [ $# -ge 2 ] || die "--out needs a directory"; OUT_DIR="$2"; shift 2 ;;
      --from)  [ $# -ge 2 ] || die "--from needs a directory"; FROM_DIR="$2"; shift 2 ;;
      --layout) [ $# -ge 2 ] || die "--layout needs ordered or nested"
               case "$2" in ordered|nested) DUMP_LAYOUT="$2" ;;
                 *) die "--layout takes 'ordered' or 'nested', not '$2'" ;; esac
               shift 2 ;;
      -i)      GREP_FLAGS="-i"; shift ;;
      -h|--help) usage; exit 0 ;;
      --*)     die "unknown flag: $1" ;;
      *)       REST+=("$1"); shift ;;
    esac
  done

  # --resume with nowhere to resume from would walk the whole root cold and
  # still report itself as a resumed run — the one outcome nobody could tell
  # apart from success.
  if [ "$WALK_RESUME" -eq 1 ] && [ -z "$WALK_CACHE" ]; then
    die "--resume needs --cache DIR — there is nothing to resume from otherwise"
  fi
  if [ -n "$WALK_CACHE" ]; then
    mkdir -p "$WALK_CACHE" || die "cannot create the cache directory $WALK_CACHE"
  fi
}

resolve_target() {  # resolve_target [<ref>] — sets TARGET_ID and TARGET_REF
  local ref="${1:-}"
  [ -n "$ref" ] || ref="$(default_ref)"
  TARGET_REF="$ref"
  TARGET_ID="$(normalize_ref "$ref")"
  if [ "$DEPTH_SET" -eq 0 ]; then
    WALK_MAX_DEPTH="$(default_depth_for "$ref")"
  fi
  # Both are on by default, so the manifest is only consulted to turn one OFF
  # for a root that should stay shallow — an explicit flag still wins.
  if [ "$DBS_SET" -eq 0 ] && [ "$(manifest_get ".roots[\"$ref\"].dbs")" = "false" ]; then
    WALK_WITH_DBS=0
  fi
  if [ "$LINKS_SET" -eq 0 ] && [ "$(manifest_get ".roots[\"$ref\"].links")" = "false" ]; then
    WALK_LINKS=0
  fi
  # Validated like the flags are, and in this shell rather than through a
  # helper: `die` inside a command substitution kills only the subshell, so a
  # bad value would print its complaint and carry on. `maxPages` decides
  # whether a truncated walk may be committed, and when it was left comparing
  # as a string the test simply failed — budget off, guard silently inverted,
  # one `[: integer expression expected` per page the only sign.
  local v
  if [ "$LINK_DEPTH_SET" -eq 0 ]; then
    v="$(manifest_get ".roots[\"$ref\"].maxLinkDepth")"
    if [ -n "$v" ]; then
      case "$v" in ''|*[!0-9]*) die "notion.json: maxLinkDepth of root '$ref' must be a number, not '$v'" ;; esac
      WALK_MAX_LINK_DEPTH="$v"
    fi
  fi
  if [ "$MAX_PAGES_SET" -eq 0 ]; then
    v="$(manifest_get ".roots[\"$ref\"].maxPages")"
    if [ -n "$v" ]; then
      case "$v" in ''|*[!0-9]*) die "notion.json: maxPages of root '$ref' must be a number, not '$v'" ;; esac
      WALK_MAX_PAGES="$v"
    fi
  fi
}

cmd_whoami() {
  local body
  body="$(api GET "/users/me")"
  api_error "$body" "identifying the integration"
  jq -r '"INTEGRATION=\(.name // "?")\nTYPE=\(.type // "?")\nWORKSPACE=\(.bot.workspace_name // "?")\nID=\(.id // "?")"' <<<"$body"
}

cmd_page() {
  resolve_target "${REST[0]:-}"
  local title tmp
  title="$(page_title "$TARGET_ID")"
  # Not a command substitution: page_markdown sets MD_TRUNCATED, and a subshell
  # would swallow it.
  tmp="$(mktemp "${TMPDIR:-/tmp}/notion-page.XXXXXX")"
  page_markdown "$TARGET_ID" > "$tmp"
  printf 'PAGE_TITLE=%s\nPAGE_ID=%s\nPAGE_URL=https://app.notion.com/p/%s\nTRUNCATED=%s\n---\n' \
    "$title" "$TARGET_ID" "${TARGET_ID//-/}" "$MD_TRUNCATED"
  cat "$tmp"
  rm -f "$tmp"
}

cmd_tree() {
  resolve_target "${REST[0]:-}"
  walk_init

  visit() {  # depth id title md_file
    printf '%*s- %s  (%s)\n' "$(( $1 * 2 ))" '' "$3" "${2//-/}"
  }
  visit_db() {  # depth id ds title
    printf '%*s- [db] %s  (%s)\n' "$(( $1 * 2 ))" '' "${4:-(untitled)}" "${2//-/}"
  }

  local root_title
  root_title="$(page_title "$TARGET_ID")"
  printf 'ROOT=%s\nDEPTH=%s\n\n' "$root_title" "$WALK_MAX_DEPTH"
  walk "$TARGET_ID" 0 "$root_title"
  walk_links
  walk_summary
}

# Cyrillic to ASCII, before anything tries to lowercase or class-match it.
#
# The shell here runs under LC_CTYPE=POSIX, where `tr '[:upper:]' '[:lower:]'`
# walks bytes and mangles every multi-byte character, while a UTF-8 locale makes
# `sed` reject the `а-я` range outright ("Invalid collation character"). Either
# way a Russian page title used to slugify to mojibake. Byte-exact replacement
# of whole UTF-8 sequences is the one form that is correct in both.
translit_cyrillic() {
  sed -E '
    s/Ё/e/g; s/ё/e/g; s/Й/y/g; s/й/y/g; s/Ъ//g; s/ъ//g; s/Ь//g; s/ь//g
    s/Ж/zh/g; s/ж/zh/g; s/Ц/c/g; s/ц/c/g; s/Ч/ch/g; s/ч/ch/g
    s/Ш/sh/g; s/ш/sh/g; s/Щ/sch/g; s/щ/sch/g; s/Ю/yu/g; s/ю/yu/g
    s/Я/ya/g; s/я/ya/g; s/Э/e/g; s/э/e/g; s/Ы/y/g; s/ы/y/g
    s/А/a/g; s/а/a/g; s/Б/b/g; s/б/b/g; s/В/v/g; s/в/v/g; s/Г/g/g; s/г/g/g
    s/Д/d/g; s/д/d/g; s/Е/e/g; s/е/e/g; s/З/z/g; s/з/z/g; s/И/i/g; s/и/i/g
    s/К/k/g; s/к/k/g; s/Л/l/g; s/л/l/g; s/М/m/g; s/м/m/g; s/Н/n/g; s/н/n/g
    s/О/o/g; s/о/o/g; s/П/p/g; s/п/p/g; s/Р/r/g; s/р/r/g; s/С/s/g; s/с/s/g
    s/Т/t/g; s/т/t/g; s/У/u/g; s/у/u/g; s/Ф/f/g; s/ф/f/g; s/Х/h/g; s/х/h/g
  '
}

slugify() {
  printf '%s' "$1" | translit_cyrillic | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-60
}

dump_frontmatter() {  # <title> <id> <depth> <edited>
  printf -- '---\ntitle: %s\nid: %s\nurl: https://app.notion.com/p/%s\ndepth: %s\nedited: %s\n---\n\n' \
    "$1" "$2" "${2//-/}" "$3" "$4"
}

# The path of one page in a nested dump, relative to OUT_DIR and without the
# extension — the children of that page go in a directory of the same name.
#
# Derived from the title rather than the walk order, because a nested dump is
# what gets committed: an inserted page must not rename its siblings. Two
# siblings that slugify the same would land on one path, so the second one takes
# its id as a suffix. Which of the two is "second" is the order Notion lists
# them in, so reordering a same-titled pair does swap their file names — rare,
# and the alternative (suffixing both) costs a pre-pass over every child.
dump_nested_path() {  # <title> <id> <dir>
  local title="$1" id="$2" dir="$3" slug rel id8
  slug="$(slugify "$title")"
  [ -n "$slug" ] || slug="untitled"
  id8="${id//-/}"
  # Everything under _linked/ is suffixed, not just a collision. That directory
  # is one flat namespace for every link-reached page in the run, ordered by
  # tree-walk order — so a prose edit anywhere could otherwise decide which of
  # two "Notes" keeps the clean name and which gets the suffix, swapping both
  # files and moving a subdirectory. These pages have no stable position in the
  # tree by construction, so the id is the only stable thing to name them by.
  if [ "$dir" = "$WALK_LINK_DIR" ] || [ "${dir%%/*}" = "$WALK_LINK_DIR" ]; then
    printf '%s/%s-%s\n' "$dir" "$slug" "${id8:0:8}"
    return 0
  fi
  rel="${dir:+$dir/}$slug"
  if [ -e "$OUT_DIR/$rel.md" ] || [ -d "$OUT_DIR/$rel" ]; then
    rel="${dir:+$dir/}$slug-${id8:0:8}"
  fi
  printf '%s\n' "$rel"
}

cmd_dump() {
  resolve_target "${REST[0]:-}"
  walk_init

  if [ -z "$OUT_DIR" ]; then
    OUT_DIR="${TMPDIR:-/tmp}/notion-$(slugify "$TARGET_REF")-$(date +%Y%m%d)"
  fi
  mkdir -p "$OUT_DIR"
  : > "$OUT_DIR/INDEX.md"

  DUMP_N=0
  if [ "$DUMP_LAYOUT" = "nested" ]; then
    visit() {  # depth id title md_file dir
      DUMP_N=$((DUMP_N + 1))
      local rel edited
      # page_markdown_cached already holds it whenever the cache is on; asking
      # again would undo the request this whole mechanism exists to save.
      edited="${PAGE_EDITED:-$(page_edited_time_soft "$2")}"
      rel="$(dump_nested_path "$3" "$2" "${5:-}")"
      mkdir -p "$OUT_DIR${5:+/$5}"
      {
        dump_frontmatter "$3" "$2" "$1" "$edited"
        cat "$4"
      } > "$OUT_DIR/$rel.md"
      printf '%*s- [%s](%s.md)\n' "$(( $1 * 2 ))" '' "$3" "$rel" >> "$OUT_DIR/INDEX.md"
      # The root page does not open a level of its own: its children sit at the
      # top of the dump, so a section is notion/<root>/product.md and not
      # notion/<root>/<root-page-title>/product.md.
      if [ "$1" -eq 0 ]; then VISIT_CHILD_DIR=""; else VISIT_CHILD_DIR="$rel"; fi
    }
    visit_db() {  # depth id data-source-id title dir
      local rel
      rel="$(dump_nested_path "${4:-database}" "$2" "${5:-}")"
      printf '%*s- [db] %s — https://app.notion.com/p/%s\n' "$(( $1 * 2 ))" '' "$4" "${2//-/}" \
        >> "$OUT_DIR/INDEX.md"
      VISIT_CHILD_DIR="$rel"
    }
  else
    visit() {  # depth id title md_file dir
      DUMP_N=$((DUMP_N + 1))
      local n file edited
      edited="${PAGE_EDITED:-$(page_edited_time_soft "$2")}"
      n="$(printf '%03d' "$DUMP_N")"
      file="$n-$(slugify "$3").md"
      if [ -z "$(slugify "$3")" ]; then file="$n-untitled.md"; fi
      {
        dump_frontmatter "$3" "$2" "$1" "$edited"
        cat "$4"
      } > "$OUT_DIR/$file"
      printf '%*s- [%s](%s)\n' "$(( $1 * 2 ))" '' "$3" "$file" >> "$OUT_DIR/INDEX.md"
    }
    visit_db() {
      printf '%*s- [db] %s — https://app.notion.com/p/%s\n' "$(( $1 * 2 ))" '' "$4" "${2//-/}" \
        >> "$OUT_DIR/INDEX.md"
    }
  fi

  local root_title
  root_title="$(page_title "$TARGET_ID")"
  walk "$TARGET_ID" 0 "$root_title"
  walk_links

  printf 'OUT_DIR=%s\nINDEX=%s/INDEX.md\nLAYOUT=%s\n' "$OUT_DIR" "$OUT_DIR" "$DUMP_LAYOUT"
  walk_summary
}

cmd_grep() {
  [ "${#REST[@]}" -ge 1 ] || die "grep needs a pattern"
  local pattern="${REST[0]}"

  if [ -n "$FROM_DIR" ]; then
    [ -d "$FROM_DIR" ] || die "no such dump directory: $FROM_DIR"
    grep -rn $GREP_FLAGS -- "$pattern" "$FROM_DIR" --include='*.md' || {
      echo "no matches in $FROM_DIR"; return 0; }
    return 0
  fi

  resolve_target "${REST[1]:-}"
  walk_init
  MATCHED=0

  visit() {  # depth id title md_file
    local hits
    hits="$(grep -n $GREP_FLAGS -- "$pattern" "$4" || true)"
    [ -n "$hits" ] || return 0
    MATCHED=$((MATCHED + 1))
    printf '\n== %s\n   https://app.notion.com/p/%s\n' "$3" "${2//-/}"
    printf '%s\n' "$hits" | sed 's/^/   /'
  }

  local root_title
  root_title="$(page_title "$TARGET_ID")"
  walk "$TARGET_ID" 0 "$root_title"
  walk_links
  printf '\nMATCHED_PAGES=%s\n' "$MATCHED"
  walk_summary
}

cmd_db() {
  [ "${#REST[@]}" -ge 1 ] || die "db needs a database ref"
  local ref="${REST[0]}" id ds body limit="${DB_LIMIT:-25}"
  id="$(normalize_ref "$ref")"

  body="$(api GET "/databases/$id")"
  if [ "$(jq -r '.object // ""' <<<"$body")" = "error" ]; then
    # A data source id was passed directly rather than the database page id.
    ds="$id"
  else
    ds="$(jq -r '.data_sources[0].id // ""' <<<"$body")"
    printf 'DATABASE=%s\n' "$(jq -r '[.title[]?.plain_text] | add // "?"' <<<"$body")"
    jq -r '.data_sources[]? | "DATA_SOURCE=\(.id)  \(.name)"' <<<"$body"
  fi
  [ -n "$ds" ] || die "no data source for $ref"

  body="$(api POST "/data_sources/$ds/query" --data "$(jq -n --argjson n "$limit" '{page_size:$n}')")"
  api_error "$body" "querying data source $ds"

  printf 'ROWS=%s  HAS_MORE=%s\n\n' \
    "$(jq -r '.results | length' <<<"$body")" "$(jq -r '.has_more // false' <<<"$body")"

  jq -r '
    .results[]? |
    "— " + ([.properties[]? | select(.type=="title") | .title[]?.plain_text] | add // "(untitled)")
    + "\n  url: " + (.url // "")
    + "\n" + ([
        .properties | to_entries[] |
        select(.value.type != "title") |
        . as $p |
        ($p.value | (
            if .type == "select"           then (.select.name // "")
          elif .type == "status"           then (.status.name // "")
          elif .type == "multi_select"     then ([.multi_select[]?.name] | join(", "))
          elif .type == "rich_text"        then ([.rich_text[]?.plain_text] | add // "")
          elif .type == "number"           then (.number // "" | tostring)
          elif .type == "checkbox"         then (.checkbox | tostring)
          elif .type == "date"             then (.date.start // "")
          elif .type == "url"              then (.url // "")
          elif .type == "email"            then (.email // "")
          elif .type == "people"           then ([.people[]?.name] | join(", "))
          elif .type == "relation"         then (([.relation[]?.id] | length | tostring) + " linked")
          elif .type == "formula"          then ((.formula.string // .formula.number // .formula.boolean // "") | tostring)
          else "" end)) as $v |
        select($v != "" and $v != "null") |
        "  " + $p.key + ": " + $v
      ] | join("\n"))
  ' <<<"$body"
}

cmd_edited() {
  resolve_target "${REST[0]:-}"
  local t
  t="$(page_edited_time "$TARGET_ID")"
  printf 'PAGE_ID=%s\nEDITED=%s\n' "$TARGET_ID" "$t"
}

cmd_search() {
  [ "${#REST[@]}" -ge 1 ] || die "search needs a query"
  local q="${REST[0]}" body limit="${DB_LIMIT:-20}"
  body="$(api POST "/search" --data "$(jq -n --arg q "$q" --argjson n "$limit" \
    '{query:$q, page_size:$n, sort:{direction:"descending", timestamp:"last_edited_time"}}')")"
  api_error "$body" "searching for \"$q\""

  printf 'RESULTS=%s\n\n' "$(jq -r '.results | length' <<<"$body")"
  jq -r '
    .results[]? |
    "\(.object | ascii_upcase)  " +
    ((if .object == "database"
      then ([.title[]?.plain_text] | add)
      else ([.properties[]? | select(.type=="title") | .title[]?.plain_text] | add)
      end) // "(untitled)") +
    "\n  " + (.url // "") +
    "\n  edited " + (.last_edited_time // "?")
  ' <<<"$body"
}

# ------------------------------------------------------------------- main ----

# Sourced rather than run: hand back the functions and touch nothing. That is
# what lets tests/ exercise the naming rules without a token or a single request.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

[ $# -ge 1 ] || { usage >&2; exit 1; }

subcommand="$1"; shift
DB_LIMIT="${NOTION_LIMIT:-25}"

case "$subcommand" in
  -h|--help|help) usage; exit 0 ;;
  roots)  cmd_roots; exit 0 ;;
esac

# --limit is only meaningful for db/search; strip it before the walk parser.
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) [ $# -ge 2 ] || die "--limit needs a value"; DB_LIMIT="$2"; shift 2 ;;
    --csv)   shift ;;  # accepted and ignored: the default rendering is already flat
    *)       ARGS+=("$1"); shift ;;
  esac
done

parse_walk_flags ${ARGS[@]+"${ARGS[@]}"}
load_token

case "$subcommand" in
  whoami) cmd_whoami ;;
  page)   cmd_page ;;
  tree)   cmd_tree ;;
  dump)   cmd_dump ;;
  grep)   cmd_grep ;;
  db)     cmd_db ;;
  search) cmd_search ;;
  edited) cmd_edited ;;
  *)      usage >&2; exit 1 ;;
esac
