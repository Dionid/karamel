#!/bin/sh
# Обновляет и проверяет CODE_MAP.md — индекс кода этого репозитория.
#
# Карта состоит из двух зон, и это главное, что нужно про неё знать:
#
#   сгенерированная  — перечень областей кода. Набор строк выводится из дерева
#                      и переписывается этим скриптом; текст роли у каждой
#                      строки СОХРАНЯЕТСЯ между прогонами, потому что вывести
#                      его из дерева нельзя.
#   кураторская      — всё остальное: домены, флоу, ловушки. Пишется руками,
#                      скрипт только проверяет, что упомянутые пути существуют.
#
# Роль новой области скрипт не придумывает: он ставит `TODO: роль`. Заглушка,
# сгенерированная вместо роли, удовлетворила бы проверку и ничего не сообщила
# читателю — то есть выключила бы тот самый гард, который здесь и заводится.
#
#   code-map.sh --write   обновить CODE_MAP.md на месте (pre-commit, агент)
#   code-map.sh --check   ничего не менять, выйти с 1 при расхождении (CI)
#
# POSIX sh + awk, никаких зависимостей: скрипт одинаково работает в node:slim,
# node:alpine, Flutter-образе и alpine.
set -eu

# Порядок строк в сгенерированном блоке обязан быть одним и тем же везде: --write
# гоняется локально, --check — в CI, и cmp сравнивает их байт в байт. Collation
# glibc в локалях вроде en_US.UTF-8 игнорирует пунктуацию на первом проходе, из-за
# чего `app-core/` и `app/` меняются местами относительно байтового порядка
# (musl в alpine сортирует по байтам). Разошлись бы — джоба краснела бы без
# всякой правки в дереве. Фиксируем явно.
export LC_ALL=C

usage() {
  cat <<'USAGE'
Usage:
  tools/code-map/code-map.sh --write    обновить CODE_MAP.md
  tools/code-map/code-map.sh --check    проверить, ничего не меняя (exit 1 при расхождении)
USAGE
}

mode=""
case "${1:-}" in
  --write) mode="write" ;;
  --check) mode="check" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# Корень репозитория — каталог на два уровня выше скрипта.
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
cd "$repo_root"

config="tools/code-map/roots"
check_also="tools/code-map/check-also"
map="CODE_MAP.md"

[ -f "$config" ] || { echo "нет $config" >&2; exit 2; }
[ -f "$map" ]    || { echo "нет $map" >&2; exit 2; }

BEGIN_MARK='<!-- code-map:generated -->'
END_MARK='<!-- code-map:generated:end -->'

grep -qF "$BEGIN_MARK" "$map" || { echo "в $map нет маркера $BEGIN_MARK" >&2; exit 2; }
grep -qF "$END_MARK" "$map"   || { echo "в $map нет маркера $END_MARK" >&2; exit 2; }

tmp=$(mktemp)
areas=$(mktemp)
roles=$(mktemp)
prefixes=$(mktemp)
trap 'rm -f "$tmp" "$areas" "$roles" "$prefixes"' EXIT

# Префиксы, под которыми путь из кураторской зоны проверяется на существование:
# корни генерации плюс необязательный check-also — каталоги, которые НЕ нужно
# перечислять как области, но на которые карта ссылается (миграции, соседний
# npm-воркспейс). Без него такие ссылки молча устаревали бы при переезде.
{
  grep -v '^[[:space:]]*#' "$config" || true
  [ ! -f "$check_also" ] || grep -v '^[[:space:]]*#' "$check_also" || true
} | grep . >"$prefixes" || true

# ── что есть в дереве ─────────────────────────────────────────────────────────
# Каждый корень из tools/code-map/roots перечисляется на один уровень вглубь.
# Строки-комментарии и пустые в конфиге игнорируются.
: >"$areas"
while IFS= read -r root; do
  case "$root" in ''|\#*) continue ;; esac
  [ -d "$root" ] || continue
  find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
    | sed 's|^\./||' \
    | while IFS= read -r dir; do
        base=${dir##*/}
        case "$base" in
          __tests*|_shared|test|tests|node_modules|.*) continue ;;
        esac
        printf '%s/\n' "$dir"
      done >>"$areas"
done <"$config"

sort -o "$areas" "$areas"

if [ ! -s "$areas" ]; then
  echo "ни один корень из $config не дал областей — проверьте конфиг" >&2
  exit 2
fi

# ── роли, уже написанные людьми ───────────────────────────────────────────────
# Из существующего блока: `путь` | роль. Ключ — путь, значение — текст роли.
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0 == b { inside = 1; next }
  $0 == e { inside = 0; next }
  inside && /^\| `/ {
    line = $0
    sub(/^\| `/, "", line)
    idx = index(line, "`")
    if (idx == 0) next
    path = substr(line, 1, idx - 1)
    rest = substr(line, idx + 1)
    sub(/^[[:space:]]*\|[[:space:]]*/, "", rest)
    sub(/[[:space:]]*\|[[:space:]]*$/, "", rest)
    printf "%s\t%s\n", path, rest
  }
' "$map" >"$roles"

# ── собрать блок заново ───────────────────────────────────────────────────────
{
  printf '%s\n' "$BEGIN_MARK"
  printf '\n'
  printf '<!-- Набор строк генерируется из дерева: tools/code-map/code-map.sh --write.\n'
  printf '     Текст роли пишется руками и сохраняется между прогонами.\n'
  printf '     `TODO: роль` — новая область, роль ещё не описана. -->\n'
  printf '\n'
  printf '| Каталог | Роль |\n'
  printf '| --- | --- |\n'
  awk -F'\t' -v rolesfile="$roles" '
    FILENAME == rolesfile { role[$1] = $2; next }
    {
      path = $0
      printf "| `%s` | %s |\n", path, (path in role && role[path] != "" ? role[path] : "TODO: роль")
    }
  ' "$roles" "$areas"
  printf '\n'
  printf '%s\n' "$END_MARK"
} >"$tmp.block"

# ── подставить блок в файл ────────────────────────────────────────────────────
awk -v b="$BEGIN_MARK" -v e="$END_MARK" -v blockfile="$tmp.block" '
  $0 == b {
    while ((getline line < blockfile) > 0) print line
    close(blockfile)
    skipping = 1
    next
  }
  $0 == e { skipping = 0; next }
  !skipping { print }
' "$map" >"$tmp"

# ── проверка кураторской зоны: упомянутые пути существуют ─────────────────────
# Берутся только пути ВНЕ сгенерированного блока и только те, что начинаются с
# корня из конфига: остальные бэктики — это имена функций, команды и прочее.
#
# Вынесено в функцию сознательно: `case` внутри `$( )` ломает разбор в bash,
# запущенном как sh, — его парсер принимает `)` из паттерна за конец подстановки.
curated_missing() {
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0 == b { inside = 1; next }
    $0 == e { inside = 0; next }
    !inside { print }
  ' "$map" \
  | grep -o '`[^`]*`' 2>/dev/null \
  | tr -d '`' \
  | grep -v '[<>]' \
  | grep '/' \
  | sort -u \
  | while IFS= read -r cand; do
      hit=0
      while IFS= read -r root; do
        case "$root" in
          ''|\#*) continue ;;
        esac
        case "$cand" in
          "$root"*) hit=1; break ;;
        esac
      done <"$prefixes"
      [ "$hit" = 1 ] || continue
      [ -e "$cand" ] || printf '  %s\n' "$cand"
    done
}

missing=$(curated_missing)

status=0

if [ -n "$missing" ]; then
  status=1
  printf 'путь упомянут в CODE_MAP.md, но в дереве его нет:\n%s\n' "$missing" >&2
  printf 'Найдите, куда переехал код, и поправьте строку. Не удаляйте её молча:\n' >&2
  printf 'исчезнувший домен — это тоже запись.\n\n' >&2
fi

todo_count=$(grep -c '^| `[^`]*` | TODO: роль |$' "$tmp" 2>/dev/null || true)
: "${todo_count:=0}"

if [ "$mode" = check ]; then
  if ! cmp -s "$tmp" "$map"; then
    status=1
    printf 'CODE_MAP.md устарел: набор областей в дереве не совпадает с картой.\n' >&2
    printf 'Разница:\n' >&2
    diff -u "$map" "$tmp" | sed -n '3,40p' >&2 || true
    printf '\nПочините так: tools/code-map/code-map.sh --write, затем опишите роль\n' >&2
    printf 'у появившихся строк вместо TODO и закоммитьте карту вместе с кодом.\n' >&2
  fi
  if [ "$todo_count" -gt 0 ]; then
    status=1
    printf '\nв CODE_MAP.md осталось %s строк(и) с "TODO: роль".\n' "$todo_count" >&2
    printf 'Роль новой области пишется руками: заглушка удовлетворила бы проверку\n' >&2
    printf 'и ничего не сказала бы читателю.\n' >&2
  fi
  [ "$status" = 0 ] && printf 'CODE_MAP.md согласован с деревом.\n'
  exit "$status"
fi

if cmp -s "$tmp" "$map"; then
  printf 'CODE_MAP.md уже актуален.\n'
else
  cat "$tmp" >"$map"
  printf 'CODE_MAP.md обновлён.\n'
fi

# TODO обязан ронять и локальный прогон, а не только CI: иначе про незаполненную
# роль узнают после пуша, когда карта уже поехала в MR.
if [ "$todo_count" -gt 0 ]; then
  status=1
  printf '\n%s строк(и) в CODE_MAP.md с "TODO: роль" — опишите роль и повторите.\n' "$todo_count" >&2
  printf 'Роль новой области пишется руками: заглушка удовлетворила бы проверку\n' >&2
  printf 'и ничего не сказала бы читателю.\n' >&2
fi

exit "$status"
