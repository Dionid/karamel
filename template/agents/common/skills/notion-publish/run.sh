#!/usr/bin/env bash
# Publish markdown documentation to a Notion page.
#
#   run.sh check   <page-url-or-id>
#   run.sh publish <page-url-or-id> --file <md> [--append] [--overwrite]
#   run.sh create  <parent-url-or-id> --title <title> --file <md> [--allow-duplicate]
#   run.sh has-child <parent-url-or-id> --title <title>
#
# NOTION_TOKEN is sourced from the workspace root .env and never printed.
# `publish` refuses to touch a page that already has content unless --overwrite
# (replace everything) or --append (add to the end) is passed — that refusal is
# what forces the "Перезаписать?" question.

set -euo pipefail

NOTION_VERSION="2026-03-11"
API="https://api.notion.com/v1"

usage() {
  cat <<'EOF'
Usage:
  run.sh check   <page-url-or-id>
  run.sh publish <page-url-or-id> --file <md> [--append] [--overwrite]
  run.sh create  <parent-url-or-id> --title <title> --file <md> [--allow-duplicate]
  run.sh has-child <parent-url-or-id> --title <title>

  --append          keep the current content, add the new one at the end
  --overwrite       replace the current content entirely
  --title           title of the new child page (create, has-child)
  --allow-duplicate create even when the parent already has a child of that title
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

find_workspace_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/harness.json" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

load_token() {
  local root env_file
  root="$(find_workspace_root)" || die "workspace root (the dir holding harness.json) not found"
  env_file="$root/.env"

  [[ -f "$env_file" ]] || die "no .env at the workspace root — copy .env.example and set NOTION_TOKEN"

  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a

  [[ -n "${NOTION_TOKEN:-}" ]] || die "NOTION_TOKEN is not set in the workspace root .env"
}

# Accepts a full Notion URL, a dashed uuid or a bare 32-hex id.
normalize_page_id() {
  local raw="$1" id
  raw="${raw%%\?*}"
  raw="${raw%%#*}"
  raw="${raw##*/}"
  raw="${raw//-/}"

  [[ "$raw" =~ ([0-9a-fA-F]{32})$ ]] || die "cannot extract a Notion page id from: $1"
  id="${BASH_REMATCH[1]}"

  printf '%s-%s-%s-%s-%s\n' \
    "${id:0:8}" "${id:8:4}" "${id:12:4}" "${id:16:4}" "${id:20:12}"
}

req() {
  local method="$1" path="$2"
  shift 2
  curl -sS -X "$method" "$API$path" \
    -H "Authorization: Bearer $NOTION_TOKEN" \
    -H "Notion-Version: $NOTION_VERSION" \
    -H "Content-Type: application/json" \
    "$@"
}

check_api_error() {
  local body="$1" what="$2"
  if [[ "$(jq -r '.object // ""' <<<"$body")" == "error" ]]; then
    local code msg
    code="$(jq -r '.code // .status // "?"' <<<"$body")"
    msg="$(jq -r '.message // "no message"' <<<"$body")"
    die "$what failed [$code]: $msg"
  fi
}

# Notion renders the page title as a leading H1; drop it before deciding
# whether the page is actually empty.
body_without_title() {
  local md="$1" title="$2"
  printf '%s' "$md" | awk -v t="# $title" 'NR==1 && $0==t {next} {print}'
}

fetch_page() {
  local id="$1"

  PAGE_JSON="$(req GET "/pages/$id")"
  check_api_error "$PAGE_JSON" "retrieving page $id"

  PAGE_TITLE="$(jq -r '[.properties[]? | select(.type=="title") | .title[]?.plain_text] | add // ""' <<<"$PAGE_JSON")"
  PAGE_URL="$(jq -r '.url // ""' <<<"$PAGE_JSON")"

  local md_json
  md_json="$(req GET "/pages/$id/markdown")"
  check_api_error "$md_json" "retrieving markdown of page $id"

  PAGE_MD="$(jq -r '.markdown // ""' <<<"$md_json")"
  PAGE_TRUNCATED="$(jq -r '.truncated // false' <<<"$md_json")"
  PAGE_BODY="$(body_without_title "$PAGE_MD" "$PAGE_TITLE")"
  PAGE_BODY_TRIMMED="$(printf '%s' "$PAGE_BODY" | tr -d '[:space:]')"
}

cmd_check() {
  local id="$1"
  fetch_page "$id"

  printf 'PAGE_ID=%s\n' "$id"
  printf 'PAGE_TITLE=%s\n' "$PAGE_TITLE"
  printf 'PAGE_URL=%s\n' "$PAGE_URL"
  printf 'TRUNCATED=%s\n' "$PAGE_TRUNCATED"

  if [[ -z "$PAGE_BODY_TRIMMED" ]]; then
    printf 'EMPTY=yes\nCHARS=0\n'
    return 0
  fi

  local out
  out="${TMPDIR:-/tmp}/notion-existing-${id}.md"
  printf '%s\n' "$PAGE_BODY" > "$out"

  printf 'EMPTY=no\n'
  printf 'CHARS=%s\n' "${#PAGE_BODY}"
  printf 'EXISTING_FILE=%s\n' "$out"
  printf -- '--- existing content (first 40 lines) ---\n'
  head -n 40 "$out"
}

cmd_publish() {
  local id="$1" file="" append=0 overwrite=0
  shift

  while (($# > 0)); do
    case "$1" in
      --file)      (($# >= 2)) || die "--file needs a value"; file="$2"; shift 2 ;;
      --append)    append=1; shift ;;
      --overwrite) overwrite=1; shift ;;
      *)           usage >&2; exit 1 ;;
    esac
  done

  [[ -n "$file" ]] || die "--file is required"
  [[ -f "$file" ]] || die "file not found: $file"
  [[ -s "$file" ]] || die "file is empty: $file"
  ((append && overwrite)) && die "--append and --overwrite are mutually exclusive"

  fetch_page "$id"

  if [[ -n "$PAGE_BODY_TRIMMED" ]] && ((!append && !overwrite)); then
    die "page \"$PAGE_TITLE\" already has content (${#PAGE_BODY} chars).
Ask the user \"Перезаписать?\" and re-run with --overwrite or --append."
  fi

  if [[ "$PAGE_TRUNCATED" == "true" ]] && ((append)); then
    die "page content is truncated by the API; appending would rewrite it from a partial copy. Use --overwrite or edit in Notion."
  fi

  local new_str
  new_str="$(cat "$file")"

  if ((append)) && [[ -n "$PAGE_BODY_TRIMMED" ]]; then
    new_str="$PAGE_BODY"$'\n\n'"$new_str"
  fi

  local http
  http="$(write_markdown "$id" "$new_str" "publishing to page $id")" \
    || die "publishing to page $id failed — the page is unchanged"

  printf 'PUBLISHED=%s\n' "$id"
  printf 'MODE=%s\n' "$( ((append)) && echo append || echo overwrite )"
  printf 'PAGE_TITLE=%s\n' "$PAGE_TITLE"
  printf 'PAGE_URL=%s\n' "$PAGE_URL"
  printf 'CHARS=%s\n' "${#new_str}"
  printf 'HTTP=%s\n' "$http"
}

write_markdown() {
  local id="$1" new_str="$2" what="$3"
  local body resp http

  body="$(jq -n --arg s "$new_str" '{
    type: "replace_content",
    replace_content: { new_str: $s, allow_deleting_content: true },
    allow_async: false
  }')"

  resp="$(req PATCH "/pages/$id/markdown" --data "$body" -w '\n%{http_code}')"
  http="$(printf '%s' "$resp" | tail -n 1)"
  resp="$(printf '%s' "$resp" | sed '$d')"

  if [[ "$http" != "200" && "$http" != "202" ]]; then
    # Reported, not fatal: `create` has a page to clean up before it gives up.
    if [[ "$(jq -r '.object // ""' <<<"$resp" 2>/dev/null)" == "error" ]]; then
      echo "error: $what failed [$(jq -r '.code // "?"' <<<"$resp")]: $(jq -r '.message // "no message"' <<<"$resp")" >&2
    else
      echo "error: $what failed with HTTP $http" >&2
    fi
    return 1
  fi

  printf '%s\n' "$http"
}

# Notion renders a child page as `<page url="…">Title</page>`, with markdown
# escapes in the title. Comparing the raw title against that misses a title
# holding `_`, `*` or a line break, so both sides get the same normalisation
# the harness's own reader applies (agents/common/skills/notion/notion.sh).
normalize_title() {
  printf '%s' "$1" \
    | sed -E 's/\\(.)/\1/g' \
    | tr '\n' ' ' \
    | tr -s '[:space:]' ' ' \
    | sed -E 's/^ +| +$//g'
}

parent_has_child() {
  local md="$1" want title
  want="$(normalize_title "$2")"

  while IFS= read -r title; do
    [[ "$(normalize_title "$title")" == "$want" ]] && return 0
  done < <(printf '%s\n' "$md" \
    | grep -oE '<page url="[^"]*">[^<]*</page>' \
    | sed -E 's|^<page url="[^"]*">||; s|</page>$||')

  return 1
}

# A new page *under* an existing one, content and all. The parent keeps its own
# content: a document that belongs under a section page becomes a child page
# instead of overwriting the section page it belongs to.
cmd_create() {
  local parent="$1" title="" file="" allow_dup=0
  shift

  while (($# > 0)); do
    case "$1" in
      --title)           (($# >= 2)) || die "--title needs a value"; title="$2"; shift 2 ;;
      --file)            (($# >= 2)) || die "--file needs a value"; file="$2"; shift 2 ;;
      --allow-duplicate) allow_dup=1; shift ;;
      *)                 usage >&2; exit 1 ;;
    esac
  done

  [[ -n "$title" ]] || die "--title is required"
  [[ -n "$file" ]] || die "--file is required"
  [[ -f "$file" ]] || die "file not found: $file"
  [[ -s "$file" ]] || die "file is empty: $file"

  # Reading the parent does two things: it proves the integration can see it
  # (the usual 404 is a missing connection, not a wrong id), and its markdown
  # lists the existing child pages, which is how the duplicate guard works.
  fetch_page "$parent"
  local parent_title="$PAGE_TITLE" parent_url="$PAGE_URL" parent_md="$PAGE_MD"

  if ((!allow_dup)); then
    # A truncated parent is a partial list of children: the guard would pass by
    # not seeing the duplicate rather than by there not being one.
    [[ "$PAGE_TRUNCATED" != "true" ]] || die \
      "the markdown of \"$parent_title\" is truncated, so its child pages cannot all be seen.
Check in Notion whether \"$title\" is already there, then pass --allow-duplicate."

    if parent_has_child "$parent_md" "$title"; then
      die "page \"$parent_title\" already has a child titled \"$title\".
Pass --allow-duplicate if a second one is really wanted, or publish into the existing child."
    fi
  fi

  local body resp new_id new_url
  body="$(jq -n --arg p "$parent" --arg t "$title" '{
    parent: { page_id: $p },
    properties: { title: { title: [ { text: { content: $t } } ] } }
  }')"

  resp="$(req POST "/pages" --data "$body")"
  check_api_error "$resp" "creating a child page of $parent"
  new_id="$(jq -r '.id // ""' <<<"$resp")"
  new_url="$(jq -r '.url // ""' <<<"$resp")"
  [[ -n "$new_id" ]] || die "Notion returned no page id for the new child page"

  local new_str http
  new_str="$(cat "$file")"

  # The page exists from here on. A failed write would leave a titled, empty
  # husk under the parent — which then blocks the retry through the duplicate
  # guard — so it is sent to the trash before giving up.
  if ! http="$(write_markdown "$new_id" "$new_str" "publishing to the new page $new_id")"; then
    local trash
    trash="$(req PATCH "/pages/$new_id" --data '{"archived": true}')"
    if [[ "$(jq -r '.object // ""' <<<"$trash")" == "error" ]]; then
      die "the page was created but neither written nor trashed: $new_url — delete it in Notion before retrying"
    fi
    die "writing the content failed; the empty page was moved to trash, so the capture can be retried"
  fi

  printf 'CREATED=%s\n' "$new_id"
  printf 'PAGE_TITLE=%s\n' "$title"
  printf 'PAGE_URL=%s\n' "$new_url"
  printf 'PARENT_TITLE=%s\n' "$parent_title"
  printf 'PARENT_URL=%s\n' "$parent_url"
  printf 'CHARS=%s\n' "${#new_str}"
  printf 'HTTP=%s\n' "$http"
}

# The duplicate question on its own, for a caller that writes somewhere else
# first and wants to know before it does. Exit 0 — the child is there; 3 — it
# is not; anything else — the question could not be answered.
cmd_has_child() {
  local parent="$1" title=""
  shift

  while (($# > 0)); do
    case "$1" in
      --title) (($# >= 2)) || die "--title needs a value"; title="$2"; shift 2 ;;
      *)       usage >&2; exit 1 ;;
    esac
  done

  [[ -n "$title" ]] || die "--title is required"

  fetch_page "$parent"

  printf 'PARENT_TITLE=%s\n' "$PAGE_TITLE"
  printf 'TRUNCATED=%s\n' "$PAGE_TRUNCATED"

  [[ "$PAGE_TRUNCATED" != "true" ]] || die \
    "the markdown of \"$PAGE_TITLE\" is truncated — its child pages cannot all be seen"

  if parent_has_child "$PAGE_MD" "$title"; then
    printf 'HAS_CHILD=yes\n'
    return 0
  fi

  printf 'HAS_CHILD=no\n'
  return 3
}

(($# >= 2)) || { usage >&2; exit 1; }

command -v jq >/dev/null || die "jq is required"

subcommand="$1"
page_ref="$2"
shift 2

load_token
page_id="$(normalize_page_id "$page_ref")"

case "$subcommand" in
  check)   cmd_check "$page_id" ;;
  publish) cmd_publish "$page_id" "$@" ;;
  create)  cmd_create "$page_id" "$@" ;;
  has-child) cmd_has_child "$page_id" "$@" ;;
  *)       usage >&2; exit 1 ;;
esac
