#!/usr/bin/env bash
# new-workspace.sh — создать агентский воркспейс из template/ или обновить
# агентский слой уже созданного. Шаблон лежит в корне karamel: ../../template.
#
#   new-workspace.sh create <dir> --team <name> [options]
#   new-workspace.sh upgrade <dir> [--dry-run]
#
# Командные файлы (TEAM_FILES) create генерирует, а upgrade никогда не трогает.
# Всё остальное — общий слой: upgrade перезаписывает его из шаблона, а в agents/
# и docs/ удаляет файлы, которых в шаблоне больше нет.

set -euo pipefail

SELF="$(basename "$0")"
HERE="$(cd "$(dirname "$0")" && pwd)"
KARAMEL="$(cd "$HERE/../.." && pwd)"
TEMPLATE="${KARAMEL_TEMPLATE:-$KARAMEL/template}"
DEFAULT_UPSTREAM="https://github.com/Dionid/karamel"

TEAM_FILES=(repos.json workspace.json PACKAGES.md README.md notion.json CODEOWNERS IDENTITY.md SOUL.md AGENTS.md .env.example)
# Командные файлы, которые create всегда переписывает: их расхождение с шаблоном
# ожидаемо, и upgrade о нём не сообщает.
GENERATED_FILES=(repos.json workspace.json PACKAGES.md README.md)
PRUNED_DIRS=(agents docs)

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

usage() {
  cat <<USAGE
Usage:
  $SELF create <dir> --team <name> [options]
  $SELF upgrade <dir> [--dry-run]

create options:
  --team <name>             имя команды для workspace.json и README (обязательно)
  --agent <name>            имя агента (по умолчанию "Engineering agent")
  --branch-prefix <prefix>  префикс веток задач (по умолчанию "codex/")
  --upstream <url>          откуда ./ops upgrade берёт общий слой (по умолчанию
                            origin этого karamel или $DEFAULT_UPSTREAM)
  --repo <name>=<url>[@<branch>]
                            продуктовый репозиторий; можно повторять
  --knowledge <name>=<url>[@<branch>]
                            репозиторий знаний и спек: попадает в "always",
                            knowledgeRoot=knowledge, specRoot=""
  --no-setup                не запускать ./ops setup и ./ops check
  --no-clone                не клонировать репозитории в packages/
  --no-git                  не делать git init и первый коммит

upgrade перезаписывает общий слой из шаблона и не трогает командные файлы:
  ${TEAM_FILES[*]}
До записи (и в --dry-run) upgrade печатает строки "differs <file>": общий слой,
чья локальная версия отличается от шаблона и будет перезаписана.
USAGE
}

[ -d "$TEMPLATE/agents" ] && [ -x "$TEMPLATE/ops" ] || die "шаблон не найден: $TEMPLATE"

in_list() {
  local needle="$1" f
  shift
  for f in "$@"; do [ "$needle" = "$f" ] && return 0; done
  return 1
}

# Файлы шаблона относительно его корня, по одному на строку.
template_files() { (cd "$TEMPLATE" && find . -type f ! -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort); }

# ----------------------------------------------------------------- create --
cmd_create() {
  local dir="" team="" agent="Engineering agent" prefix="codex/" upstream=""
  local setup=1 clone=1 git=1
  local -a repos=() knowledge=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --team) team="${2:?--team needs a value}"; shift ;;
      --agent) agent="${2:?--agent needs a value}"; shift ;;
      --branch-prefix) prefix="${2:?--branch-prefix needs a value}"; shift ;;
      --upstream) upstream="${2:?--upstream needs a url}"; shift ;;
      --repo) repos+=("${2:?--repo needs name=url}"); shift ;;
      --knowledge) knowledge+=("${2:?--knowledge needs name=url}"); shift ;;
      --no-setup) setup=0 ;;
      --no-clone) clone=0 ;;
      --no-git) git=0 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "неизвестный флаг: $1" ;;
      *) [ -z "$dir" ] || die "лишний аргумент: $1"; dir="$1" ;;
    esac
    shift
  done
  [ -n "$dir" ] || die "не указан каталог (см. --help)"
  [ -n "$team" ] || die "не указана команда: --team <name>"
  [ "${#knowledge[@]}" -le 1 ] || die "--knowledge можно указать только один раз"
  if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    die "каталог не пуст: $dir"
  fi

  if [ -z "$upstream" ]; then
    upstream="$(git -C "$KARAMEL" config --get remote.origin.url 2>/dev/null || true)"
    upstream="${upstream:-$DEFAULT_UPSTREAM}"
  fi

  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"
  say "копирую шаблон в $dir"
  cp -a "$TEMPLATE/." "$dir/"

  say "пишу workspace.json, repos.json, PACKAGES.md, README.md"
  python3 - "$dir" "$team" "$agent" "$prefix" "$upstream" "${knowledge[0]:-}" "${repos[@]}" <<'PY'
import json, re, sys
from pathlib import Path

root, team, agent, prefix, upstream, knowledge, *repos = sys.argv[1:]
root = Path(root)

def parse(spec):
    m = re.fullmatch(r"([A-Za-z0-9._-]+)=(\S+?)(?:@([^@/\s]+))?", spec)
    if not m:
        sys.exit(f"new-workspace.sh: ожидалось name=url[@branch], получено: {spec}")
    return m.group(1), m.group(2), m.group(3) or "main"

manifest = {"always": [], "repos": {}}
rows = []
if knowledge:
    name, url, branch = parse(knowledge)
    manifest["always"].append(name)
    manifest["repos"][name] = {"url": url, "branch": branch, "deps": "none",
                               "knowledgeRoot": "knowledge", "specRoot": ""}
    rows.append((name, url, "Team knowledge and product specifications", "Yes"))
for spec in repos:
    name, url, branch = parse(spec)
    if name in manifest["repos"]:
        sys.exit(f"new-workspace.sh: репозиторий указан дважды: {name}")
    manifest["repos"][name] = {"url": url, "branch": branch}
    rows.append((name, url, "Product repository", "No"))

(root / "repos.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

ws = json.loads((root / "workspace.json").read_text())
ws.update({"team": team, "agent": agent, "branchPrefix": prefix,
           "upstream": upstream, "upstreamRef": "main"})
(root / "workspace.json").write_text(json.dumps(ws, indent=2, ensure_ascii=False) + "\n")

if rows:
    table = ["| Repository | Role | Required in every task |", "| --- | --- | --- |"]
    table += [f"| [{n}]({u}) | {r} | {a} |" for n, u, r, a in rows]
    packages = (
        "# Repositories\n\n"
        "`repos.json` is the repository catalog.\n\n"
        + "\n".join(table) + "\n\n"
        "Use the `clone` skill to populate `packages/` and the `wt` skill to open task\n"
        "checkouts. `packages/` is read-only; changes belong in\n"
        "`worktrees/<task>/<repo>/`.\n\n"
        "Optional repository fields include `knowledgeRoot`, `specRoot`, `skills`, `deps`\n"
        "and `postSetup`; see `WORKTREES.md` and the relevant skills for their contracts.\n"
        "`always` lists repositories required in every task.\n"
    )
    (root / "PACKAGES.md").write_text(packages)

readme = root / "README.md"
text = readme.read_text()
text = text.replace("# Engineering workspace", f"# {team} — engineering workspace", 1)
readme.write_text(text)
PY

  if [ "$git" = 1 ]; then
    say "git init"
    git -C "$dir" init -q -b main
    git -C "$dir" add -A
    if git -C "$dir" commit -q -m "Initial workspace from karamel" 2>/dev/null; then
      say "первый коммит создан"
    else
      say "git identity не настроен: файлы добавлены в индекс, коммит сделайте сами"
    fi
  fi

  if [ "$setup" = 1 ]; then
    say "./ops setup"
    (cd "$dir" && ./ops setup)
    if [ "$clone" = 1 ] && [ "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["repos"]))' "$dir/repos.json")" != 0 ]; then
      if [ -n "${GITHUB_TOKEN:-}" ] || grep -qE '^GITHUB_TOKEN=.+' "$dir/.env" 2>/dev/null; then
        say "./ops clone"
        (cd "$dir" && ./ops clone) || say "clone не прошёл: проверьте GITHUB_TOKEN и доступ, затем ./ops clone"
      else
        say "GITHUB_TOKEN не задан: пропускаю clone. Заполните .env и выполните ./ops clone"
      fi
    fi
    say "./ops check"
    (cd "$dir" && ./ops check)
  fi

  cat <<DONE

Готово: $dir
Дальше:
  1. Заполните .env (как минимум GITHUB_TOKEN), если ещё не заполнен.
  2. Создайте пустой репозиторий на GitHub и запушьте: git remote add origin <url> && git push -u origin main
  3. Откройте Claude Code в $dir: правила — в AGENTS.md, команды — ./ops help.
DONE
}

# ---------------------------------------------------------------- upgrade --
cmd_upgrade() {
  local dir="" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "неизвестный флаг: $1" ;;
      *) [ -z "$dir" ] || die "лишний аргумент: $1"; dir="$1" ;;
    esac
    shift
  done
  [ -n "$dir" ] || die "не указан каталог (см. --help)"
  [ -f "$dir/workspace.json" ] && [ -d "$dir/agents" ] || die "не похоже на воркспейс: $dir"
  dir="$(cd "$dir" && pwd)"
  if git -C "$dir" rev-parse --git-dir > /dev/null 2>&1 && [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
    die "в $dir есть незакоммиченные правки: закоммитьте или отложите их, чтобы diff обновления был чистым"
  fi

  # Сначала план, потом запись: список перезаписываемых локальных версий
  # печатается до того, как upgrade тронет хоть один файл.
  local f d
  local -a adds=() updates=() removals=() keeps=()
  local skipped=0
  while IFS= read -r f; do
    if in_list "$f" "${TEAM_FILES[@]}"; then
      skipped=$((skipped + 1))
      if ! in_list "$f" "${GENERATED_FILES[@]}" && [ -f "$dir/$f" ] && ! cmp -s "$TEMPLATE/$f" "$dir/$f"; then
        keeps+=("$f")
      fi
    elif [ ! -e "$dir/$f" ]; then
      adds+=("$f")
    elif ! cmp -s "$TEMPLATE/$f" "$dir/$f"; then
      updates+=("$f")
    fi
  done < <(template_files)
  for d in "${PRUNED_DIRS[@]}"; do
    [ -d "$dir/$d" ] || continue
    while IFS= read -r f; do
      f="${f#./}"
      [ -e "$TEMPLATE/$f" ] || removals+=("$f")
    done < <(cd "$dir" && find "./$d" -type f | LC_ALL=C sort)
  done

  # Общий слой, чья локальная версия расходится с шаблоном: upgrade заменит её
  # шаблонной, и локальные правки в ней пропадут. Командные файлы сюда не
  # попадают — их upgrade не трогает.
  if [ $((${#updates[@]} + ${#removals[@]})) -gt 0 ]; then
    printf 'Локальная версия общего слоя отличается от шаблона — upgrade её перезапишет%s.\n' \
      "$([ "$dry" = 1 ] && printf ' (в dry run — перезаписал бы)')"
    printf 'Перенесите нужные локальные правки в upstream-шаблон или в командные файлы:\n'
    for f in ${updates[@]+"${updates[@]}"}; do printf '  differs %s\n' "$f"; done
    for f in ${removals[@]+"${removals[@]}"}; do printf '  differs %s (нет в шаблоне, будет удалён)\n' "$f"; done
    printf '\n'
  fi

  for f in ${keeps[@]+"${keeps[@]}"}; do
    printf '  keep   %s (командный файл, в шаблоне есть изменения — сверьте вручную)\n' "$f"
  done
  for f in ${adds[@]+"${adds[@]}"}; do printf '  add    %s\n' "$f"; done
  for f in ${updates[@]+"${updates[@]}"}; do printf '  update %s\n' "$f"; done
  for f in ${removals[@]+"${removals[@]}"}; do printf '  remove %s\n' "$f"; done
  if [ "$dry" = 0 ]; then
    for f in ${adds[@]+"${adds[@]}"} ${updates[@]+"${updates[@]}"}; do
      mkdir -p "$(dirname "$dir/$f")"
      cp -p "$TEMPLATE/$f" "$dir/$f"
    done
    for f in ${removals[@]+"${removals[@]}"}; do rm -f "$dir/$f"; done
    for d in "${PRUNED_DIRS[@]}"; do
      if [ -d "$dir/$d" ]; then find "$dir/$d" -type d -empty -delete; fi
    done
  fi

  local added=${#adds[@]} changed=${#updates[@]} removed=${#removals[@]}
  printf '\nдобавлено %s, обновлено %s, удалено %s, командных файлов не тронуто %s%s\n' \
    "$added" "$changed" "$removed" "$skipped" "$([ "$dry" = 1 ] && printf ' (dry run)')"
  if [ "$dry" = 0 ] && [ $((added + changed + removed)) -gt 0 ]; then
    cat <<NEXT
Дальше: git -C "$dir" diff --stat, затем ./ops sync и ./ops check в корне воркспейса,
и обычный PR с обновлением агентского слоя.
NEXT
  fi
}

case "${1:-}" in
  create) shift; cmd_create "$@" ;;
  upgrade) shift; cmd_upgrade "$@" ;;
  -h|--help|help|"") usage ;;
  *) die "неизвестная команда: $1 (create | upgrade)" ;;
esac
