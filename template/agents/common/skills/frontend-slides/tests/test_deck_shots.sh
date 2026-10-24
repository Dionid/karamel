#!/usr/bin/env bash
# Поведение deck-shots.cjs: честный отказ без puppeteer-core, без CHROME_PATH
# и на несуществующем CHROME_PATH — вместо гадания пути к браузеру.
set -uo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../scripts/deck-shots.cjs"

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

command -v node >/dev/null 2>&1 || { printf 'нет node в PATH, тест пропущен\n' >&2; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf '<html><body><div class="slide">hi</div></body></html>' > "$tmp/deck.html"

# ------------------------------------------------------------ без CHROME_PATH
out="$(cd "$tmp" && CHROME_PATH="" node "$SCRIPT" deck.html "$tmp/out" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "без CHROME_PATH код возврата не 0" || fail "без CHROME_PATH должен был отказать"
case "$out" in
  *CHROME_PATH*) ok "без CHROME_PATH сообщение называет переменную" ;;
  *) fail "без CHROME_PATH сообщение не называет причину: $out" ;;
esac

# ------------------------------------------------------- несуществующий путь
out="$(cd "$tmp" && CHROME_PATH=/no/such/chrome node "$SCRIPT" deck.html "$tmp/out" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "несуществующий CHROME_PATH код возврата не 0" \
  || fail "несуществующий CHROME_PATH должен был отказать"
case "$out" in
  *"/no/such/chrome"*) ok "несуществующий путь называется в сообщении" ;;
  *) fail "несуществующий путь не назван: $out" ;;
esac

# ------------------------------------------------------------- без аргументов
out="$(node "$SCRIPT" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "без аргументов код возврата не 0" || fail "без аргументов должен был отказать"
case "$out" in
  *usage*) ok "без аргументов печатает usage" ;;
  *) fail "без аргументов не печатает usage: $out" ;;
esac

# ============================================================
#  Позитивный путь: CHROME_PATH только в .env (не экспортирован) —
#  изолированный workspace root (свой harness.json, свой .env).
# ============================================================
ROOT="$tmp/workspace"
mkdir -p "$ROOT/.claude/skills/frontend-slides/scripts"
printf '{}\n' > "$ROOT/harness.json"
cp "$SCRIPT" "$ROOT/.claude/skills/frontend-slides/scripts/deck-shots.cjs"
FAKE_CHROME="$ROOT/fake-chrome"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_CHROME"
chmod +x "$FAKE_CHROME"
printf 'CHROME_PATH=%s\n' "$FAKE_CHROME" > "$ROOT/.env"

out="$(cd "$ROOT" && env -u CHROME_PATH node "$ROOT/.claude/skills/frontend-slides/scripts/deck-shots.cjs" "$tmp/deck.html" "$tmp/out2" 2>&1)"; rc=$?
case "$out" in
  *"CHROME_PATH не задан"*) fail "CHROME_PATH только в .env: не был загружен (решил, что не задан): $out" ;;
  *"указывает на несуществующий файл"*) fail "CHROME_PATH только в .env: не нашёл наш фейковый путь: $out" ;;
  *"puppeteer-core не установлен"*) ok "CHROME_PATH только в .env: реально загружен (дошли до проверки puppeteer-core)" ;;
  *) fail "CHROME_PATH только в .env: неожиданный вывод rc=$rc: $out" ;;
esac

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'deck-shots.cjs: все проверки пройдены\n'
  exit 0
fi
printf 'deck-shots.cjs: провалено проверок: %s\n' "$fails" >&2
exit 1
