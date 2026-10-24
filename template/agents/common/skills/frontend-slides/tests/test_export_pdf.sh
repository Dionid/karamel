#!/usr/bin/env bash
# export-pdf.sh: без Playwright, установленного заранее, скрипт не должен
# молча ставить его через npm — только с явным --install-deps (согласие).
set -uo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../scripts/export-pdf.sh"

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

command -v node >/dev/null 2>&1 || { printf 'нет node в PATH, тест пропущен\n' >&2; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '<html><body><div class="slide">hi</div></body></html>' > "$tmp/deck.html"

# playwright заведомо не резолвится из этого временного каталога
out="$(cd "$tmp" && bash "$SCRIPT" "$tmp/deck.html" "$tmp/deck.pdf" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "без --install-deps: код возврата не 0" \
  || fail "без --install-deps должен был отказать"
case "$out" in
  *install-deps*) ok "сообщение называет --install-deps как путь согласия" ;;
  *) fail "сообщение не упоминает --install-deps: $out" ;;
esac
case "$out" in
  *"npm install playwright"*) ok "сообщение даёт ручную команду тоже" ;;
  *) fail "сообщение не даёт ручную команду: $out" ;;
esac
[ ! -f "$tmp/deck.pdf" ] && ok "PDF не создан без согласия" \
  || fail "PDF создан без согласия — не должно быть"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'export-pdf.sh: все проверки пройдены\n'
  exit 0
fi
printf 'export-pdf.sh: провалено проверок: %s\n' "$fails" >&2
exit 1
