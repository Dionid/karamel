#!/usr/bin/env bash
# Честные отказы скриптов figma-review без сети/браузера/токена/либ:
# каждый должен назвать причину, а не гадать значение по умолчанию.
set -uo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FETCH="$SELF_DIR/../scripts/figma-fetch.py"
DIFF="$SELF_DIR/../scripts/pixel-diff.py"
SHOOT="$SELF_DIR/../scripts/shoot-local.mjs"

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

# ------------------------------------------------------------- figma-fetch.py
if command -v python3 >/dev/null 2>&1; then
  out="$(env -u FIGMA_TOKEN python3 "$FETCH" --url 'https://figma.com/design/K/f?node-id=1-2' --out /tmp/figma-review-test 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "figma-fetch.py без FIGMA_TOKEN: код возврата не 0" \
    || fail "figma-fetch.py без FIGMA_TOKEN должен был отказать"
  case "$out" in
    *FIGMA_TOKEN*) ok "figma-fetch.py называет переменную в сообщении" ;;
    *) fail "figma-fetch.py не называет причину: $out" ;;
  esac
else
  printf 'нет python3 в PATH, часть теста пропущена\n' >&2
fi

# -------------------------------------------------------------- pixel-diff.py
if command -v python3 >/dev/null 2>&1; then
  out="$(python3 "$DIFF" 2>&1)"; rc=$?
  # Либо честный отказ по недостающей зависимости (opencv и т.п.), либо -
  # если зависимости есть в этом окружении - обычная ошибка argparse
  # (не хватает позиционных аргументов). Оба варианта валидны, лишь бы
  # не падал необъяснимым traceback без причины.
  if [ "$rc" -ne 0 ]; then
    ok "pixel-diff.py без аргументов/зависимостей: код возврата не 0"
  else
    fail "pixel-diff.py без аргументов должен был завершиться с ошибкой"
  fi
  case "$out" in
    *"зависимость не установлена"*|*"usage"*|*"required"*) ok "pixel-diff.py объясняет причину отказа" ;;
    *) fail "pixel-diff.py не объяснил причину: $out" ;;
  esac
fi

# ------------------------------------------------------------ shoot-local.mjs
if command -v node >/dev/null 2>&1; then
  out="$(node "$SHOOT" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "shoot-local.mjs без --url/--out: код возврата не 0" \
    || fail "shoot-local.mjs без аргументов должен был отказать"
  case "$out" in
    *Usage*) ok "shoot-local.mjs без аргументов печатает usage" ;;
    *) fail "shoot-local.mjs без аргументов не печатает usage: $out" ;;
  esac

  out="$(env -u CHROME_PATH node "$SHOOT" --url http://localhost:1/ --out /tmp/figma-review-shots 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "shoot-local.mjs без CHROME_PATH: код возврата не 0" \
    || fail "shoot-local.mjs без CHROME_PATH должен был отказать"
  case "$out" in
    *CHROME_PATH*) ok "shoot-local.mjs без CHROME_PATH называет переменную" ;;
    *) fail "shoot-local.mjs без CHROME_PATH не называет причину: $out" ;;
  esac

  out="$(CHROME_PATH=/no/such/chrome node "$SHOOT" --url http://localhost:1/ --out /tmp/figma-review-shots 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && ok "shoot-local.mjs с несуществующим CHROME_PATH: код возврата не 0" \
    || fail "shoot-local.mjs с несуществующим CHROME_PATH должен был отказать"
  case "$out" in
    *"/no/such/chrome"*) ok "shoot-local.mjs называет несуществующий путь" ;;
    *) fail "shoot-local.mjs не назвал несуществующий путь: $out" ;;
  esac
else
  printf 'нет node в PATH, часть теста пропущена\n' >&2
fi

# ============================================================
#  Позитивный путь: значение только в .env (не экспортировано) —
#  изолированный workspace root (свой harness.json, свой .env).
# ============================================================
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
ROOT="$tmp/workspace"
mkdir -p "$ROOT/.claude/skills/figma-review/scripts"
printf '{}\n' > "$ROOT/harness.json"

if command -v python3 >/dev/null 2>&1; then
  cp "$FETCH" "$ROOT/.claude/skills/figma-review/scripts/figma-fetch.py"
  printf 'FIGMA_TOKEN=fake-token-for-tests\n' > "$ROOT/.env"
  # URL без node-id: падает уже ПОСЛЕ проверки токена, без сети — доказывает,
  # что токен реально был прочитан из .env, а не "FIGMA_TOKEN не задан".
  out="$(cd "$ROOT" && env -u FIGMA_TOKEN python3 "$ROOT/.claude/skills/figma-review/scripts/figma-fetch.py" --url 'https://figma.com/design/K/f' --out "$tmp/out" 2>&1)"; rc=$?
  case "$out" in
    *"FIGMA_TOKEN не задан"*) fail "FIGMA_TOKEN только в .env: не был загружен: $out" ;;
    *"node-id"*) ok "FIGMA_TOKEN только в .env: реально загружен (дошли до разбора URL)" ;;
    *) fail "FIGMA_TOKEN только в .env: неожиданный вывод rc=$rc: $out" ;;
  esac
fi

if command -v node >/dev/null 2>&1; then
  mkdir -p "$ROOT/.claude/skills/figma-review/scripts"
  cp "$SHOOT" "$ROOT/.claude/skills/figma-review/scripts/shoot-local.mjs"
  FAKE_CHROME="$ROOT/fake-chrome"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_CHROME"
  chmod +x "$FAKE_CHROME"
  printf 'CHROME_PATH=%s\n' "$FAKE_CHROME" > "$ROOT/.env"
  out="$(cd "$ROOT" && env -u CHROME_PATH node "$ROOT/.claude/skills/figma-review/scripts/shoot-local.mjs" --url http://localhost:1/ --out "$tmp/shots" 2>&1)"; rc=$?
  case "$out" in
    *"CHROME_PATH не задан"*) fail "CHROME_PATH только в .env: не был загружен: $out" ;;
    *"путь к Chrome не существует"*) fail "CHROME_PATH только в .env: не нашёл наш фейковый путь: $out" ;;
    *"puppeteer-core не установлен"*) ok "CHROME_PATH только в .env: реально загружен (дошли до проверки puppeteer-core)" ;;
    *) fail "CHROME_PATH только в .env: неожиданный вывод rc=$rc: $out" ;;
  esac
fi

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'figma-review scripts: все проверки пройдены\n'
  exit 0
fi
printf 'figma-review scripts: провалено проверок: %s\n' "$fails" >&2
exit 1
