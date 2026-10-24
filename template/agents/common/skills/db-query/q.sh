#!/usr/bin/env bash
#
# q.sh — один запрос к одной базе, с защитами, которые иначе держатся на памяти
# агента.
#
# Прелюдия (найти корень, загрузить .env, собрать psql с нужными флагами) —
# ровно то место, где защита прода теряется: забытый PGOPTIONS не падает, он
# просто выполняет то, что ему дали. Поэтому read-only на проде здесь не совет,
# а два независимых механизма: сервер получает default_transaction_read_only, а
# сам скрипт отказывается отправить не-SELECT.
#
# Базы этой команды не хардкодятся в скрипте: имя базы — любое, что заведено в
# .env по конвенции DB_URI_<БАЗА>_<ОКРУЖЕНИЕ>. Какие базы реально существуют и
# что каждая хранит, документирует env.example и SKILL.md команды, не этот
# файл.
#
# Usage:
#   q.sh --db <name> --env <dev|prod> --sql "SELECT ..."
#   q.sh --db <name> --env <dev|prod> --file <path.sql>
#   q.sh --db <name> --env <dev|prod> --tables | --schema <table> | --migrations | --whoami
#
# Options:
#   --db <name>      имя базы — часть переменной DB_URI_<ИМЯ>_<ОКРУЖЕНИЕ>
#   --env <dev|prod> окружение — вторая часть той же переменной
#   --sql <text>     запрос
#   --file <path>    запрос из файла (для длинного SQL и кавычек)
#   --tables         \dt
#   --schema <t>     \d+ <t>
#   --migrations     последние 5 строк таблицы migrations
#   --whoami         current_database(), current_user, version()
#   --csv | --tsv    машинный вывод; --raw — голое значение без заголовков
#   --explain        выполнить EXPLAIN вместо запроса
#   --timeout <s>    statement_timeout (дефолт: 15 на проде, 60 на dev)
#   --no-limit       разрешить на проде SELECT без LIMIT и без агрегата
#   --confirm        разрешить запись на dev (на проде не действует)
#   --print          показать, что было бы отправлено, и не подключаться
#
# Exit codes: 0 ok · 1 запрос упал · 2 ошибка вызова · 3 нет URI · 4 запрещено

set -euo pipefail

die() { printf 'q.sh: %s\n' "$1" >&2; exit "${2:-2}"; }

root=$PWD
while [ ! -f "$root/harness.json" ]; do
  parent=$(dirname "$root")
  [ "$parent" != "$root" ] || die 'корень воркспейса не найден (нет harness.json)'
  root=$parent
done

db=""; env_name=""
sql=""; sql_file=""; fmt="aligned"; explain=0; timeout=""
no_limit=0; confirm=0; print_only=0; meta=""

while [ $# -gt 0 ]; do
  case "$1" in
    --db)         db=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
    --env)        env_name=$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
    --sql)        sql="${2:-}"; shift 2 ;;
    --file)       sql_file="${2:-}"; shift 2 ;;
    --tables)     meta='\dt'; shift ;;
    --schema)     meta="\\d+ ${2:-}"; shift 2 ;;
    --migrations) sql='SELECT * FROM migrations ORDER BY id DESC LIMIT 5'; shift ;;
    --whoami)     sql='SELECT current_database(), current_user, version()'; shift ;;
    --csv)        fmt=csv; shift ;;
    --tsv)        fmt=tsv; shift ;;
    --raw)        fmt=raw; shift ;;
    --explain)    explain=1; shift ;;
    --timeout)    timeout="${2:-}"; shift 2 ;;
    --no-limit)   no_limit=1; shift ;;
    --confirm)    confirm=1; shift ;;
    --print)      print_only=1; shift ;;
    -h|--help)    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "неизвестный флаг '$1'" ;;
  esac
done

case "$env_name" in
  dev|prod) ;;
  development) env_name=dev ;;
  production) env_name=prod ;;
  "") die 'нужен --env <dev|prod>' ;;
  *) die "неизвестное окружение '$env_name' — dev или prod" ;;
esac

[ -n "$db" ] || die 'нужен --db <name>'
# Часть имени переменной окружения: буквы, цифры и подчёркивание, ничего
# больше — иначе имя базы, взятое из аргумента, могло бы адресовать
# произвольную переменную окружения вместо DB_URI_<ИМЯ>_<ОКРУЖЕНИЕ>.
case "$db" in
  *[!a-z0-9_]*|"") die "имя базы '$db' может содержать только строчные буквы, цифры и подчёркивание" ;;
esac

if [ -n "$sql_file" ]; then
  [ -f "$sql_file" ] || die "файла нет: $sql_file"
  sql=$(cat "$sql_file")
fi

[ -n "$sql$meta" ] || die 'нечего выполнять — нужен --sql, --file или один из --tables/--schema/--migrations/--whoami'
[ -z "$sql" ] || [ -z "$meta" ] || die 'мета-команда и --sql в одном вызове — это два разных запроса'

# --- что это за запрос -------------------------------------------------------
# Классифицируем по первому ключевому слову каждого стейтмента, вырезав
# комментарии и строковые литералы: '-- DELETE' в комментарии не делает запрос
# пишущим, а вот 'WITH x AS (...) DELETE' делает.
classify() {
  python3 - "$1" <<'PY'
import re, sys
sql = sys.argv[1]
sql = re.sub(r"--[^\n]*", " ", sql)
sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
sql = re.sub(r"'(?:[^']|'')*'", "''", sql)
sql = re.sub(r'"(?:[^"]|"")*"', '""', sql)
readonly = {"select", "with", "explain", "show", "table", "values", "analyze"}
writing = []
for stmt in sql.split(";"):
    words = re.findall(r"[a-zA-Z_]+", stmt)
    if not words:
        continue
    head = words[0].lower()
    if head not in readonly:
        writing.append(head.upper())
        continue
    # WITH ... DELETE/UPDATE/INSERT — пишущий, несмотря на читающее начало.
    if head == "with" and re.search(r"\b(insert|update|delete|merge)\b", stmt, re.I):
        writing.append("WITH+DML")
        continue
    # Голый EXPLAIN плана не исполняет — а EXPLAIN ANALYZE исполняет стейтмент
    # по-настоящему, со всеми его побочными эффектами. Поэтому классифицируем
    # не по слову EXPLAIN, а по тому, что стоит после EXPLAIN [(опции)] ANALYZE.
    if head == "explain" and re.search(r"\banalyze\b", stmt, re.I):
        rest = re.sub(r"^\s*explain\b", "", stmt, flags=re.I)
        rest = re.sub(r"^\s*\([^)]*\)", "", rest, flags=re.S)
        opt = r"(analyze|verbose|costs|settings|buffers|wal|timing|summary|format\s+\w+)\b\s*"
        rest = re.sub(rf"^\s*{opt}", "", rest, flags=re.I)
        rest = re.sub(rf"^\s*{opt}", "", rest, flags=re.I)
        rest_words = re.findall(r"[a-zA-Z_]+", rest)
        if rest_words:
            rest_head = rest_words[0].lower()
            if rest_head not in readonly:
                writing.append(rest_head.upper())
            elif rest_head == "with" and re.search(r"\b(insert|update|delete|merge)\b", rest, re.I):
                writing.append("WITH+DML")
print(" ".join(dict.fromkeys(writing)))
PY
}

bounded() {
  python3 - "$1" <<'PY'
import re, sys
# Каждый стейтмент проверяется отдельно: агрегат во втором запросе не делает
# ограниченным первый.
sql = re.sub(r"--[^\n]*", " ", sys.argv[1])
sql = re.sub(r"/\*.*?\*/", " ", sql, flags=re.S)
for stmt in sql.split(";"):
    if not stmt.strip():
        continue
    aggregate = re.search(r"\b(count|sum|avg|min|max)\s*\(", stmt, re.I)
    # SELECT без FROM возвращает одну строку — ограничивать нечего.
    from_clause = re.search(r"\bfrom\b", stmt, re.I)
    if not (re.search(r"\blimit\b", stmt, re.I) or aggregate or not from_clause):
        print("no")
        break
else:
    print("yes")
PY
}

writing_ops=""
[ -z "$sql" ] || writing_ops=$(classify "$sql")

if [ "$env_name" = prod ] && [ -n "$writing_ops" ]; then
  die "прод только на чтение, а это $writing_ops. Предложите изменение — выполнит человек" 4
fi
if [ "$env_name" = dev ] && [ -n "$writing_ops" ] && [ "$confirm" = 0 ]; then
  die "запись на dev ($writing_ops) требует --confirm: против этой базы может работать кто-то ещё" 4
fi
if [ "$env_name" = prod ] && [ -n "$sql" ] && [ "$no_limit" = 0 ] && [ "$(bounded "$sql")" = no ]; then
  die 'на проде SELECT без LIMIT и без агрегата: добавьте LIMIT, посчитайте count(*) или передайте --no-limit' 4
fi

[ "$explain" = 0 ] || sql="EXPLAIN $sql"

# --- креды -------------------------------------------------------------------
# Имя переменной собирается здесь, но значение из скрипта не выходит: оно
# уходит в psql через окружение и ни разу не печатается.
var="DB_URI_$(printf '%s' "$db" | tr '[:lower:]' '[:upper:]')_$(printf '%s' "$env_name" | tr '[:lower:]' '[:upper:]')"

if [ "$print_only" = 0 ]; then
  [ -f "$root/.env" ] || die "нет $root/.env" 3
  set -a; . "$root/.env"; set +a
  uri="${!var-}"
  [ -n "$uri" ] || die "$var не задан в .env — не подставляю другую базу и не угадываю строку подключения" 3
fi

if [ -z "$timeout" ]; then
  case "$env_name" in prod) timeout=15 ;; dev) timeout=60 ;; esac
fi

args=(-X -w -v ON_ERROR_STOP=1)
case "$fmt" in
  csv) args+=(--csv) ;;
  tsv) args+=(-At -F $'\t') ;;
  raw) args+=(-At) ;;
esac
if [ -n "$meta" ]; then args+=(-c "$meta"); else args+=(-c "$sql"); fi

opts="-c statement_timeout=${timeout}s"
[ "$env_name" != prod ] || opts="-c default_transaction_read_only=on $opts"

if [ "$print_only" = 1 ]; then
  printf 'база:        %s %s (URI из $%s)\n' "$db" "$env_name" "$var"
  printf 'PGOPTIONS:   %s\n' "$opts"
  printf 'psql:        %s\n' "${args[*]}"
  printf 'запрос:      %s\n' "${meta:-$sql}"
  exit 0
fi

printf 'q.sh: %s %s, statement_timeout=%ss%s\n' \
  "$db" "$env_name" "$timeout" \
  "$([ "$env_name" = prod ] && printf ', read-only' || printf '')" >&2

PGOPTIONS="$opts" psql "$uri" "${args[@]}"
