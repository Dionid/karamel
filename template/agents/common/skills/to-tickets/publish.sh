#!/usr/bin/env bash
# publish.sh — публикует одобренную разбивку тикетов в трекер, выбранный
# переменной TICKETS_TRACKER (local|github, по умолчанию local).
#
# Вход — каталог с уже написанными markdown-файлами тикетов (один тикет —
# один файл, в порядке зависимостей: блокирующие раньше блокируемых). Этот
# скрипт их не сочиняет — он только раскладывает то, что пользователь уже
# одобрил, по месту назначения.
#
#   publish.sh local  --slug <feature-slug> --dir <каталог с тикетами>
#   publish.sh github  --repo <owner/repo>    --dir <каталог с тикетами> [--dry-run]
#
# Режим (local/github) можно не называть явно — тогда скрипт сам
# берёт его из TICKETS_TRACKER в .env (по умолчанию local):
#   publish.sh --slug <feature-slug> --dir <каталог с тикетами>
#
# github без --dry-run создаёт issue реально — это внешняя запись,
# и по правилам движка она делается только после явного согласия пользователя
# на разбивку и точный текст. Без --dry-run скрипт всё равно ничего не
# отправит, если переменных не хватает: сначала env-check.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Корень репозитория команды: локальный harness.json либо tracked workspace.json.
ROOT="$SCRIPT_DIR"
while [ "$ROOT" != "/" ] && [ ! -f "$ROOT/harness.json" ] && [ ! -f "$ROOT/workspace.json" ]; do
  ROOT="$(dirname "$ROOT")"
done
ENV_CHECK="$ROOT/.claude/skills/env-check/env-check.sh"
[ -x "$ENV_CHECK" ] || ENV_CHECK="$ROOT/agents/common/skills/env-check/env-check.sh"

# env-check.sh only inspects the .env file — it never loads it into this
# process, so GITHUB_TOKEN/TICKETS_TRACKER would
# be unbound here without this. Load it ourselves, the same way notion-publish
# does, before anything reads those variables.
LIB="$SCRIPT_DIR/../commit-and-mr/lib.sh"
# shellcheck source=../commit-and-mr/lib.sh
. "$LIB"
gl_load "$ROOT"
workspace_env_load "$GL_WORKSPACE_ROOT" TICKETS_TRACKER

usage() {
  sed -n '2,21p' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

[ $# -ge 1 ] || usage 2

# Mode is positional when given explicitly (local|github|-h|--help).
# Otherwise it comes from TICKETS_TRACKER in .env, defaulting to local — the
# SKILL.md tells the agent to check this with env-check.sh, never to Read
# .env directly (that Read is blocked by permissions.deny regardless of
# whether the value is a secret).
case "$1" in
  local|github|-h|--help) mode="$1"; shift ;;
  *) mode="${TICKETS_TRACKER:-local}" ;;
esac

dir=""
slug=""
repo=""
dry_run=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --slug) slug="$2"; shift 2 ;;
    --repo) repo="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage 0 ;;
    *) printf 'неизвестный аргумент: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -n "$dir" ] && [ -d "$dir" ] || { printf '--dir обязателен и должен существовать\n' >&2; exit 2; }

files=("$dir"/*.md)
[ -e "${files[0]}" ] || { printf 'в %s нет ни одного .md тикета\n' "$dir" >&2; exit 1; }

case "$mode" in
  local)
    [ -n "$slug" ] || { printf 'local требует --slug <feature-slug>\n' >&2; exit 2; }
    dest=".scratch/$slug/issues"
    mkdir -p "$dest"
    for f in "${files[@]}"; do
      cp "$f" "$dest/$(basename "$f")"
    done
    printf 'записано %d тикет(ов) в %s\n' "${#files[@]}" "$dest"
    ;;

  github)
    [ -n "$repo" ] || { printf 'github требует --repo <owner/repo>\n' >&2; exit 2; }
    if [ "$dry_run" -eq 1 ]; then
      printf '[dry-run] создал бы %d issue в GitHub-репозитории %s\n' "${#files[@]}" "$repo"
      for f in "${files[@]}"; do printf '  - %s\n' "$(basename "$f")"; done
      exit 0
    fi
    [ -x "$ENV_CHECK" ] || { printf 'не нашёл env-check.sh, честно отказываю\n' >&2; exit 1; }
    "$ENV_CHECK" GITHUB_TOKEN >/dev/null 2>&1 || {
      printf 'GITHUB_TOKEN не задан — публикация в GitHub невозможна, см. env.example\n' >&2
      exit 1
    }
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
      || { printf 'github требует owner/repo на github.com\n' >&2; exit 2; }
    gl_require_gh github.com || exit 1
    created=0
    for f in "${files[@]}"; do
      title="$(sed -n '1s/^# *//p' "$f")"
      [ -n "$title" ] || title="$(basename "$f" .md)"
      body_file="$(mktemp)"
      tail -n +2 "$f" > "$body_file"
      issue_url="$(gl_gh_env gh issue create --repo "$repo" --title "$title" --body-file "$body_file")" || {
        rm -f "$body_file"
        printf 'GitHub issue creation failed for %s\n' "$f" >&2; exit 1
      }
      rm -f "$body_file"
      [[ "$issue_url" == "https://github.com/$repo/issues/"* ]] \
        || { printf 'GitHub did not confirm the issue URL\n' >&2; exit 1; }
      printf 'создан %s ← %s\n' "$issue_url" "$(basename "$f")"
      created=$((created + 1))
    done
    printf 'опубликовано %d issue(ов) в %s\n' "$created" "$repo"
    ;;

  -h|--help) usage 0 ;;
  *) printf 'неизвестный режим: %s (ожидался local|github)\n' "$mode" >&2; exit 2 ;;
esac
