#!/usr/bin/env bash
# `create` must write the markdown into the page it just created — never into
# the parent.
#
# That is the failure worth a test: the parent here is a section page with
# other people's pages under it, and a PATCH aimed at the parent replaces its
# content whole. It would look like a success — a page id comes back either
# way. The duplicate guard is the second check: the same document captured
# twice is two pages nobody reconciles.

set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0

check() {
  local what="$1" want="$2" got="$3"
  [[ "$want" == "$got" ]] || { echo "$what — want '$want', got '$got'" >&2; fail=1; }
}

PARENT="11111111-1111-1111-1111-111111111111"
CHILD="22222222-2222-2222-2222-222222222222"

mkdir -p "$tmp/.claude/skills/notion-publish" "$tmp/bin"
echo '{}' > "$tmp/harness.json"
dotenv="$tmp/.env"
echo "NOTION_TOKEN=stub-token" > "$dotenv"
cp "$SKILL/run.sh" "$tmp/.claude/skills/notion-publish/run.sh"
RUN="$tmp/.claude/skills/notion-publish/run.sh"

cat > "$tmp/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=""; url=""; data=""; want_code=0
while (($# > 0)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -w) want_code=1; shift 2 ;;
    -H) shift 2 ;;
    -sS|-s) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
echo "$method ${url#*/v1}" >> "$CALL_LOG"
body='{"object":"error","code":"unstubbed","message":"'"$method $url"'"}'
case "$method ${url#*/v1}" in
  "GET /pages/$PARENT")          body='{"object":"page","url":"https://notion/parent","properties":{"title":{"type":"title","title":[{"plain_text":"R&D"}]}}}' ;;
  "GET /pages/$PARENT/markdown") body="$(jq -n --arg m "$PARENT_MD" --argjson t "${TRUNCATED:-false}" '{markdown:$m,truncated:$t}')" ;;
  "POST /pages")                 printf '%s\n' "$data" > "$CREATE_BODY"; body='{"object":"page","id":"'"$CHILD"'","url":"https://notion/child"}' ;;
  "PATCH /pages/"*"/markdown")
    printf '%s\n' "$data" > "$PATCH_BODY"
    if [[ -n "${PATCH_FAILS:-}" ]]; then
      body='{"object":"error","code":"validation_error","message":"nope"}'
      printf '%s' "$body"; ((want_code)) && printf '\n400'; exit 0
    fi
    body='{"object":"page"}' ;;
  "PATCH /pages/$CHILD")         body='{"object":"page","archived":true}' ;;
esac
printf '%s' "$body"
((want_code)) && printf '\n200'
exit 0
STUB
chmod +x "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH" PARENT CHILD
export CALL_LOG="$tmp/calls" CREATE_BODY="$tmp/create.json" PATCH_BODY="$tmp/patch.json"
printf '# document\n\nbody text\n' > "$tmp/h.md"

# --- a parent holding somebody else's page -----------------------------------

export PARENT_MD='# R&D
<page url="https://notion/other">Другой документ</page>'
: > "$CALL_LOG"

out="$("$RUN" create "$PARENT" --title "Подписка для мерчантов" --file "$tmp/h.md")"

check "reports the new page id" "$CHILD" "$(sed -n 's/^CREATED=//p' <<<"$out")"
check "reports the new page url" "https://notion/child" "$(sed -n 's/^PAGE_URL=//p' <<<"$out")"
check "reports the parent it went under" "R&D" "$(sed -n 's/^PARENT_TITLE=//p' <<<"$out")"
check "created under the given parent" "$PARENT" "$(jq -r '.parent.page_id' "$CREATE_BODY")"
check "title set on the new page" "Подписка для мерчантов" "$(jq -r '.properties.title.title[0].text.content' "$CREATE_BODY")"
check "content written into the child, not the parent" "1" \
  "$(grep -c "^PATCH /pages/$CHILD/markdown\$" "$CALL_LOG" || true)"
check "the parent was never patched" "0" \
  "$(grep -c "^PATCH /pages/$PARENT/markdown\$" "$CALL_LOG" || true)"
check "the file is what got published" "# document" \
  "$(jq -r '.replace_content.new_str' "$PATCH_BODY" | head -1)"

# --- the same title twice -----------------------------------------------------

export PARENT_MD='# R&D
<page url="https://notion/dup">Подписка для мерчантов</page>'
: > "$CALL_LOG"

if "$RUN" create "$PARENT" --title "Подписка для мерчантов" --file "$tmp/h.md" >/dev/null 2>"$tmp/err"; then
  echo "a child with the same title should refuse" >&2
  fail=1
fi
grep -q 'allow-duplicate' "$tmp/err" || { echo "the refusal should name the override" >&2; fail=1; }
check "nothing created on refusal" "0" "$(grep -c '^POST /pages' "$CALL_LOG" || true)"

: > "$CALL_LOG"
"$RUN" create "$PARENT" --title "Подписка для мерчантов" --file "$tmp/h.md" --allow-duplicate >/dev/null
check "--allow-duplicate goes through" "1" "$(grep -c '^POST /pages' "$CALL_LOG" || true)"


# --- a title Notion escaped in the parent's markdown --------------------------

export PARENT_MD='# R&D
<page url="https://notion/dup">Подписка \_для\_ мерчантов</page>'
: > "$CALL_LOG"

if "$RUN" create "$PARENT" --title "Подписка _для_ мерчантов" --file "$tmp/h.md" >/dev/null 2>"$tmp/err"; then
  echo "an escaped title in the parent should still count as a duplicate" >&2
  fail=1
fi
check "nothing created for an escaped duplicate" "0" "$(grep -c '^POST /pages' "$CALL_LOG" || true)"

# --- a parent whose child list the API truncated ------------------------------

export PARENT_MD='# R&D'
export TRUNCATED=true
: > "$CALL_LOG"

if "$RUN" create "$PARENT" --title "Подписка для мерчантов" --file "$tmp/h.md" >/dev/null 2>"$tmp/err"; then
  echo "a truncated parent hides children, so the guard must refuse" >&2
  fail=1
fi
grep -q 'truncated' "$tmp/err" || { echo "the refusal should say the list is truncated" >&2; fail=1; }
check "nothing created on a truncated parent" "0" "$(grep -c '^POST /pages' "$CALL_LOG" || true)"
unset TRUNCATED

# --- the content write fails after the page exists ----------------------------

export PARENT_MD='# R&D'
export PATCH_FAILS=1
: > "$CALL_LOG"

if "$RUN" create "$PARENT" --title "Подписка для мерчантов" --file "$tmp/h.md" >/dev/null 2>"$tmp/err"; then
  echo "a failed content write should fail the run" >&2
  fail=1
fi
check "the empty page is trashed, not left under the parent" "1" \
  "$(grep -c "^PATCH /pages/$CHILD\$" "$CALL_LOG" || true)"
grep -q 'retried' "$tmp/err" || { echo "the error should say the capture can be retried" >&2; fail=1; }
unset PATCH_FAILS


# --- has-child answers the same question without writing ----------------------

export PARENT_MD='# R&D
<page url="https://notion/dup">Подписка для мерчантов</page>'
: > "$CALL_LOG"

"$RUN" has-child "$PARENT" --title "Подписка для мерчантов" >"$tmp/out" 2>&1
check "has-child finds the child" "yes" "$(sed -n 's/^HAS_CHILD=//p' "$tmp/out")"

set +e
"$RUN" has-child "$PARENT" --title "Другой документ" >"$tmp/out" 2>&1
rc=$?
set -e
check "has-child exits 3 when it is absent" "3" "$rc"
check "has-child says no" "no" "$(sed -n 's/^HAS_CHILD=//p' "$tmp/out")"
check "has-child writes nothing" "0" "$(grep -cE '^(POST|PATCH)' "$CALL_LOG" || true)"

((fail == 0)) && echo "PASS" || echo "FAIL"
exit "$fail"
