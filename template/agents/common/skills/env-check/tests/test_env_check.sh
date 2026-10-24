#!/usr/bin/env bash
# Поведение env-check.sh, у которого вся ценность в одном свойстве: он
# отвечает, задана переменная или нет, и НЕ МОЖЕТ напечатать её значение.
#
# Проверяется именно это. Регрессия здесь не выглядит регрессией: скрипт
# по-прежнему работает, отчёт по-прежнему верный, просто рядом со словом `set`
# теперь стоит токен — и он уехал в транскрипт, в лог сессии и в контекст
# следующего агента. Ни один хук этого не поймает: хук смотрит на команду,
# которую позвал агент, а не на то, что скрипт печатает.
set -uo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SELF_DIR/../env-check.sh"

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

# Значение с узнаваемой формой: если оно где-то всплывёт, это видно глазом.
SECRET='ghp_CANARY-must-never-be-printed'

# Тест обязан видеть только свою фикстуру. env-check решает по переменным
# окружения после того, как подхватит .env, поэтому настоящее окружение агента
# (где эти токены заданы) делает «незаполненную» переменную заполненной, и тест
# краснеет ровно там, где продукт прав.
unset PRIMARY_TOKEN SERVICE_BASE_URL NOTION_TOKEN ASANA_TOKEN \
      EMPTY_TOKEN STILL_TEMPLATE FILLED_TOKEN SECRET_URL_TOKEN

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
root="$tmp/workspace"
mkdir -p "$root/agents/common/skills/env-check"
cp "$CHECK" "$root/agents/common/skills/env-check/env-check.sh"
printf '{}\n' > "$root/harness.json"
run="$root/agents/common/skills/env-check/env-check.sh"

{
  printf 'PRIMARY_TOKEN=%s\n' "$SECRET"
  printf 'SERVICE_BASE_URL=https://service.example\n'
  printf 'EMPTY_TOKEN=\n'
  # Осталось ровно тем, что стоит в шаблоне: `.env` создаётся его копией,
  # поэтому это состояние «человек ещё ничего не вписал», а не «заполнено».
  printf 'STILL_TEMPLATE=your_github_token\n'
  printf 'FILLED_TOKEN=actually-filled-in\n'
  printf 'SECRET_URL_TOKEN=https://example.com/placeholder\n'
} > "$root/.env"

{
  printf 'PRIMARY_TOKEN=your_service_token\n'
  printf 'SERVICE_BASE_URL=https://service.example\n'
  printf 'SECRET_URL_TOKEN=https://example.com/placeholder\n'
  printf 'STILL_TEMPLATE=your_github_token\n'
  printf 'FILLED_TOKEN=your_github_token\n'
  printf '# NOTION_TOKEN=ntn_placeholder\n'
  printf '#   ASANA_TOKEN=placeholder\n'
} > "$root/.env.example"

# --------------------------------------------------------------------- отчёт
out="$("$run" PRIMARY_TOKEN NOTION_TOKEN 2>&1)"; rc=$?

case "$out" in
  *"$SECRET"*) fail "значение секрета попало в вывод" ;;
  *)           ok "значение секрета в вывод не попадает" ;;
esac

case "$out" in
  *PRIMARY_TOKEN*set*) ok "заданная переменная помечена set" ;;
  *)                  fail "заданная переменная не помечена set: $out" ;;
esac

case "$out" in
  *NOTION_TOKEN*missing*) ok "незаданная переменная помечена missing" ;;
  *)                      fail "незаданная переменная не помечена missing: $out" ;;
esac

[ "$rc" -eq 1 ] && ok "код возврата 1, когда чего-то не хватает" \
  || fail "ожидался код 1 при незаполненной переменной, получен $rc"

# ------------------------------------------------------- всё на месте -> 0
"$run" PRIMARY_TOKEN SERVICE_BASE_URL >/dev/null 2>&1 && ok "код возврата 0, когда всё задано" \
  || fail "ожидался код 0, когда все переменные заданы"

# Пустое значение — это не «задана». Переменная, объявленная и оставленная
# пустой, ведёт себя как отсутствующая у любого потребителя.
out="$("$run" EMPTY_TOKEN 2>&1)"
case "$out" in
  *EMPTY_TOKEN*missing*) ok "пустое значение считается missing" ;;
  *)                     fail "пустое значение не считается missing: $out" ;;
esac

# Значение, не тронутое с момента копирования шаблона, — это не кред.
# Без этой проверки скрипт докладывал бы «всё на месте» ровно в тот момент,
# когда не заполнено ничего: scaffold создаёт .env копией шаблона, и все
# переменные в нём непусты.
out="$("$run" STILL_TEMPLATE 2>&1)"; rc=$?
case "$out" in
  *STILL_TEMPLATE*placeholder*) ok "значение из шаблона помечено placeholder" ;;
  *) fail "значение из шаблона не помечено placeholder: $out" ;;
esac
[ "$rc" -eq 1 ] && ok "плейсхолдер считается незаполненным (код 1)" \
  || fail "ожидался код 1 на плейсхолдере, получен $rc"

# Несекретный URL по умолчанию — `SERVICE_BASE_URL=https://service.example` — это
# настоящее значение, а не заглушка: у команды на github.com он остаётся
# шаблонным навсегда, и без исключения гейт не проходил бы никогда. Секретное
# имя с URL-плейсхолдером исключением не пользуется.
out="$("$run" SERVICE_BASE_URL 2>&1)"
case "$out" in
  *SERVICE_BASE_URL*set*) ok "шаблонный URL по умолчанию считается set" ;;
  *) fail "шаблонный URL по умолчанию не считается set: $out" ;;
esac
out="$("$run" SECRET_URL_TOKEN 2>&1)"
case "$out" in
  *SECRET_URL_TOKEN*placeholder*) ok "URL-плейсхолдер у секрета остаётся placeholder" ;;
  *) fail "URL-плейсхолдер у секрета не помечен placeholder: $out" ;;
esac

# Переменная, у которой в шаблоне тот же плейсхолдер, но в .env вписано своё,
# остаётся `set`: сверяется значение, а не факт присутствия имени в шаблоне.
out="$("$run" FILLED_TOKEN 2>&1)"
case "$out" in
  *FILLED_TOKEN*set*) ok "заполненная переменная плейсхолдером не считается" ;;
  *) fail "заполненная переменная ошибочно принята за плейсхолдер: $out" ;;
esac

# ------------------------------------------------------------------ --missing
out="$("$run" --missing PRIMARY_TOKEN NOTION_TOKEN 2>&1)"
case "$out" in
  *PRIMARY_TOKEN*) fail "--missing напечатал заданную переменную" ;;
  *NOTION_TOKEN*) ok "--missing печатает только незаполненные" ;;
  *)              fail "--missing не напечатал незаполненную: $out" ;;
esac

# ---------------------------------------------- корень по workspace.json
# Свежий клон без собранного harness.json остаётся валидным корнем.
root2="$tmp/not-built-yet"
mkdir -p "$root2/agents/common/skills/env-check"
cp "$CHECK" "$root2/agents/common/skills/env-check/env-check.sh"
printf '{}\n' > "$root2/workspace.json"
printf 'PRIMARY_TOKEN=your_service_token\nSERVICE_BASE_URL=https://service.example\n' > "$root2/.env"
printf 'PRIMARY_TOKEN=your_service_token\nSERVICE_BASE_URL=https://service.example\n' > "$root2/.env.example"
out="$("$root2/agents/common/skills/env-check/env-check.sh" PRIMARY_TOKEN SERVICE_BASE_URL 2>&1)"; rc=$?
case "$out" in
  *PRIMARY_TOKEN*placeholder*) ok "корень по workspace.json найден, плейсхолдер опознан" ;;
  *) fail "корень по workspace.json не сработал: $out" ;;
esac
case "$out" in
  *SERVICE_BASE_URL*set*) ok "корень по workspace.json: URL по умолчанию считается set" ;;
  *) fail "корень по workspace.json: URL по умолчанию не считается set: $out" ;;
esac
[ "$rc" -eq 1 ] && ok "корень по workspace.json: код возврата 1 на плейсхолдере" \
  || fail "корень по workspace.json: ожидался код 1, получен $rc"

# ------------------------------------------------------------- --from-example
# Закомментированные имена берутся тоже: строка `# NOTION_TOKEN=…` в шаблоне
# означает «опционально», а не «такой переменной не бывает».
out="$("$run" --from-example 2>&1)"
for name in PRIMARY_TOKEN NOTION_TOKEN ASANA_TOKEN; do
  case "$out" in
    *"$name"*) ok "--from-example видит $name" ;;
    *)         fail "--from-example не увидел $name: $out" ;;
  esac
done
case "$out" in
  *"$SECRET"*) fail "--from-example напечатал значение" ;;
  *)           ok "--from-example значение не печатает" ;;
esac

# Explicit process values, including empty, win over the root file.
out="$(PRIMARY_TOKEN=process-value "$run" PRIMARY_TOKEN 2>&1)"
case "$out" in *set*) ok "process env wins" ;; *) fail "process env lost: $out" ;; esac
out="$(PRIMARY_TOKEN='' "$run" PRIMARY_TOKEN 2>&1)"
case "$out" in *missing*) ok "explicit empty process env blocks fallback" ;; *) fail "empty process env lost: $out" ;; esac

# ------------------------------------------------------------------- отказы
"$run" >/dev/null 2>&1 && fail "вызов без аргументов должен отказывать" \
  || ok "вызов без аргументов отказывает"

printf '\n'
if [ "$fails" -eq 0 ]; then
  printf 'env-check.sh: все проверки пройдены\n'
  exit 0
fi
printf 'env-check.sh: провалено проверок: %s\n' "$fails" >&2
exit 1
