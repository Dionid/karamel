#!/usr/bin/env bash
# env-check.sh — какие переменные корневого .env заполнены, и ничего больше.
#
# Единственный способ агенту узнать, вписал ли человек токен: прочитать .env
# нельзя (`permissions.deny` на Read и хук на секреты), а `${VAR:-…}` печатает
# значение. Здесь используется безопасная форма `${VAR:+set}` — она отвечает
# «есть» или «нет» и не может напечатать сам кред.
#
#   env-check.sh NOTION_TOKEN ASANA_TOKEN
#   env-check.sh --from-example            # всё, что перечислено в .env.example
#   env-check.sh --missing NOTION_TOKEN    # только незаполненные, для гейта
#
# Три состояния: `set`, `missing` и `placeholder` — значение осталось таким же,
# как в шаблоне, то есть переменную объявили и не заполнили. Плейсхолдер
# считается незаполненным.
#
# Код возврата: 0 — заполнены все запрошенные, 1 — есть незаполненные. Значение
# не печатается ни при каком флаге и ни при какой ошибке.
set -uo pipefail

c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
[ -t 1 ] || { c_grn=""; c_ylw=""; c_off=""; }

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
# Корень репозитория команды: локальный маркер `harness.json` или tracked
# манифест `workspace.json` до первой сборки.
while [ "$ROOT" != "/" ] && [ ! -f "$ROOT/harness.json" ] && [ ! -f "$ROOT/workspace.json" ]; do ROOT="$(dirname "$ROOT")"; done
{ [ -f "$ROOT/harness.json" ] || [ -f "$ROOT/workspace.json" ]; } || { printf 'не нашёл корень репозитория\n' >&2; exit 1; }

only_missing=0
from_example=0
names=()

while [ $# -gt 0 ]; do
  case "$1" in
    --missing)      only_missing=1; shift ;;
    --from-example) from_example=1; shift ;;
    -h|--help)      sed -n '2,18p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) printf 'неизвестный флаг: %s\n' "$1" >&2; exit 2 ;;
    *)  names+=("$1"); shift ;;
  esac
done

# Имена переменных из шаблона — включая закомментированные: строка
# `# NOTION_TOKEN=…` в .env.example означает «опционально», а не «не бывает».
if [ "$from_example" = 1 ]; then
  example="$ROOT/.env.example"
  [ -f "$example" ] || { printf 'нет .env.example в корне репозитория\n' >&2; exit 1; }
  while IFS= read -r name; do
    [ -n "$name" ] && names+=("$name")
  done < <(sed -nE 's/^[[:space:]]*#?[[:space:]]*([A-Z][A-Z0-9_]*)=.*/\1/p' "$example" | awk '!seen[$0]++')
fi

[ ${#names[@]} -gt 0 ] || { printf 'нечего проверять: назовите переменные или --from-example\n' >&2; exit 2; }

saved_env=""
for name in "${names[@]}"; do
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { printf 'invalid variable name\n' >&2; exit 2; }
  if [[ "${!name+x}" == x ]]; then saved_env+="export $name=$(printf '%q' "${!name}")"$'\n'; fi
done
if [ -f "$ROOT/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$ROOT/.env"
  set +a
else
  printf '%sнет .env в корне репозитория%s\n' "$c_ylw" "$c_off" >&2
fi

[[ -z "$saved_env" ]] || eval "$saved_env"

# Значение, дословно равное тому, что стоит в шаблоне, — это не кред, а
# незаполненный плейсхолдер. `.env` создаётся копией шаблона, поэтому сразу
# после сборки КАЖДАЯ переменная непуста; без этой сверки скрипт доложил бы
# «всё на месте» ровно в тот момент, когда не заполнено ничего.
#
# Сверка идёт по шаблону, а не по списку слов вроде `your_`: список пришлось бы
# догонять при каждой новой интеграции, а шаблон и так лежит рядом.
example="$ROOT/.env.example"
placeholder_of() {
  [ -f "$example" ] || return 1
  sed -nE "s/^[[:space:]]*#?[[:space:]]*$1=(.*)$/\\1/p" "$example" | head -n 1
}

# `${!name:+set}` — присутствие без значения. Форма с `:-` напечатала бы кред,
# и хук на секреты отклоняет её именно поэтому.
missing=0
for name in "${names[@]}"; do
  state="${!name:+set}"
  label="missing"

  if [ -n "$state" ]; then
    template="$(placeholder_of "$name")"
    if [ -n "$template" ] && [ "${!name}" = "$template" ]; then
      # Исключение: несекретный URL по умолчанию — `SERVICE_BASE_URL=https://service.example`
      # в шаблоне — это настоящий инстанс, а не заглушка вроде your_github_token.
      is_secret=0; is_url=0
      case "$name" in *TOKEN*|*PASS*|*SECRET*|*KEY*|*CREDENTIAL*|*URI*|*DSN*|*DB_URL*) is_secret=1 ;; esac
      case "$template" in http://*|https://*) is_url=1 ;; esac
      if [ "$is_secret" = 1 ] || [ "$is_url" = 0 ]; then
        state=""
        label="placeholder"
      fi
    fi
  fi

  if [ -n "$state" ]; then
    [ "$only_missing" = 1 ] || printf '%s%-44s set%s\n' "$c_grn" "$name" "$c_off"
  else
    missing=$((missing + 1))
    printf '%s%-44s %s%s\n' "$c_ylw" "$name" "$label" "$c_off"
  fi
done

[ "$missing" = 0 ]
