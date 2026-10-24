#!/usr/bin/env bash
# Поведение deploy.sh: без --yes/VERCEL_TOKEN честный отказ; с токеном
# только в .env (не экспортированным) скрипт должен реально загрузить .env
# сам; токен не должен попадать в argv команды vercel; коллизия с
# существующим путём деплоя не должна сноситься вслепую; npx-фетч CLI
# требует отдельного согласия --allow-npx.
#
# Настоящий `vercel` не вызываем — подменяем его фейковым бинарём в PATH,
# который проверяет ровно то, что нас интересует (нет --token в argv,
# VERCEL_TOKEN реально виден в окружении), и не трогает сеть.
set -uo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_DEPLOY="$SELF_DIR/../scripts/deploy.sh"
REAL_ENV_CHECK="$SELF_DIR/../../env-check/env-check.sh"

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

command -v npx >/dev/null 2>&1 || { printf 'нет npx в PATH, тест пропущен\n' >&2; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ROOT="$tmp/workspace"
mkdir -p "$ROOT/.claude/skills/frontend-slides/scripts" "$ROOT/.claude/skills/env-check" "$ROOT/bin"
printf '{}\n' > "$ROOT/harness.json"
cp "$REAL_DEPLOY" "$ROOT/.claude/skills/frontend-slides/scripts/deploy.sh"
cp "$REAL_ENV_CHECK" "$ROOT/.claude/skills/env-check/env-check.sh"
chmod +x "$ROOT/.claude/skills/frontend-slides/scripts/deploy.sh" "$ROOT/.claude/skills/env-check/env-check.sh"
DEPLOY="$ROOT/.claude/skills/frontend-slides/scripts/deploy.sh"

# фейковый vercel: проверяет, что --token нет в argv и что VERCEL_TOKEN
# реально виден в окружении процесса, а не пуст.
cat > "$ROOT/bin/vercel" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --version) echo "Vercel CLI 32.0.0 (fake)"; exit 0 ;;
  ls)
    exit 0
    ;;
  deploy)
    shift
    for a in "$@"; do
      if [ "$a" = "--token" ]; then echo "FAKE_VERCEL: --token found in argv" >&2; exit 3; fi
    done
    if [ -z "${VERCEL_TOKEN:-}" ]; then echo "FAKE_VERCEL: VERCEL_TOKEN not in env" >&2; exit 4; fi
    echo "https://fake-deploy-url.vercel.app"
    exit 0
    ;;
  *) echo "FAKE_VERCEL: unknown command $1" >&2; exit 2 ;;
esac
FAKE
chmod +x "$ROOT/bin/vercel"

mkdir -p "$ROOT/deck"
printf '<html><body>hi</body></html>\n' > "$ROOT/deck/index.html"

write_env() { : > "$ROOT/.env"; for line in "$@"; do printf '%s\n' "$line" >> "$ROOT/.env"; done; }
rm_env() { rm -f "$ROOT/.env"; }

cd "$ROOT" || exit 1

# ------------------------------------------------------------- без --yes
rm_env
out="$("$DEPLOY" "$ROOT/deck" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "без --yes: код возврата не 0" || fail "без --yes должен был отказать"
case "$out" in
  *согласи*) ok "без --yes: сообщение про согласие" ;;
  *) fail "без --yes: сообщение не про согласие: $out" ;;
esac

# ------------------------------------------------------- --yes без токена
rm_env
out="$("$DEPLOY" "$ROOT/deck" --yes 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "--yes без VERCEL_TOKEN в .env: код возврата не 0" \
  || fail "--yes без VERCEL_TOKEN должен был отказать"
case "$out" in
  *"не задан"*) ok "--yes без токена: сообщение называет причину" ;;
  *) fail "--yes без токена: причина не названа: $out" ;;
esac

# ============================================================
#  Позитивный путь: VERCEL_TOKEN только в .env (не экспортирован)
# ============================================================
write_env "VERCEL_TOKEN=fake-token-for-tests"
out="$(PATH="$ROOT/bin:$PATH" "$DEPLOY" "$ROOT/deck" --yes 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "VERCEL_TOKEN только в .env: деплой прошёл (фейковый vercel подтвердил токен в env)" \
  || fail "VERCEL_TOKEN только в .env: код возврата $rc, вывод: $out"
case "$out" in
  *"--token found in argv"*) fail "токен передан через --token в argv (виден в ps): $out" ;;
  *) ok "токен не передан через --token в argv" ;;
esac
case "$out" in
  *"VERCEL_TOKEN not in env"*) fail "VERCEL_TOKEN не был загружен из .env в окружение процесса: $out" ;;
  *) ok "VERCEL_TOKEN реально загружен из .env в окружение" ;;
esac
case "$out" in
  *"fake-deploy-url.vercel.app"*) ok "URL деплоя показан" ;;
  *) fail "URL деплоя не показан: $out" ;;
esac

# ============================================================
#  Коллизия временного каталога — не сносить чужое
# ============================================================
write_env "VERCEL_TOKEN=fake-token-for-tests"
COLLIDE_NAME="deck"
COLLIDE_DIR="${TMPDIR:-/tmp}/$COLLIDE_NAME"
rm -rf "$COLLIDE_DIR"
mkdir -p "$COLLIDE_DIR"
printf 'not ours\n' > "$COLLIDE_DIR/keep-me.txt"
printf '<html><body>hi</body></html>\n' > "$ROOT/deck.html"
out="$(PATH="$ROOT/bin:$PATH" "$DEPLOY" "$ROOT/deck.html" --yes 2>&1)"; rc=$?
if [ -f "$COLLIDE_DIR/keep-me.txt" ]; then
  ok "коллизия по имени: чужой каталог не удалён"
else
  fail "коллизия по имени: чужой каталог был снесён — потеря данных"
fi
[ "$rc" -ne 0 ] && ok "коллизия по имени: скрипт отказал, а не продолжил вслепую" \
  || fail "коллизия по имени: скрипт должен был отказать, а не задеплоить поверх"
rm -rf "$COLLIDE_DIR"

# ============================================================
#  npx-фетч CLI требует отдельного согласия --allow-npx
# ============================================================
write_env "VERCEL_TOKEN=fake-token-for-tests"
out="$(PATH="/usr/bin:/bin:$(dirname "$(command -v node)")" "$DEPLOY" "$ROOT/deck" --yes 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "без vercel в PATH и без --allow-npx: код возврата не 0" \
  || fail "без vercel и без --allow-npx должен был отказать"
case "$out" in
  *allow-npx*) ok "сообщение называет --allow-npx как путь согласия" ;;
  *) fail "сообщение не упоминает --allow-npx: $out" ;;
esac

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'deploy.sh: все проверки пройдены\n'
  exit 0
fi
printf 'deploy.sh: провалено проверок: %s\n' "$fails" >&2
exit 1
