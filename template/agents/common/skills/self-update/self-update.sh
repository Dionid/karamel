#!/usr/bin/env bash
# self-update.sh — корневой чекаут воркспейса подтягивает свежий агентский слой
# и пересобирает из него рантайм-деревья.
#
#   self-update.sh
#
# Три шага, остановка на первом неуспешном: fast-forward `git pull`,
# `./ops sync`, `./ops check`.
#
# Скрипт сознательно отказывается работать вместо того, чтобы расчищать дорогу:
# грязный корень, не та ветка, разошедшаяся история — это отчёт человеку, а не
# повод для reset/stash/checkout. Корневой чекаут — единственная копия
# агентского слоя, которой пользуются все параллельные сессии.
#
# Гейт на грязное дерево смотрит только на tracked-файлы. Gitignore-нутый файл
# (`.env`, `CLAUDE.local.md`) он не видит, и fast-forward молча перезапишет его,
# если тот же путь приедет из origin уже как tracked. Случай требует коммита
# пути, который `.gitignore` явно исключает, поэтому гейта на него нет.
#
# Код возврата: 0 — обновление прошло; 1 — отказ или падение шага.
set -uo pipefail

c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_red=$'\033[31m'; c_off=$'\033[0m'
[ -t 1 ] || { c_grn=""; c_ylw=""; c_red=""; c_off=""; }

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$c_grn" "$c_off" "$*"; }
die()  { printf '%sself-update:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
  "") ;;
  *) die "неизвестный аргумент: $1 (скрипт вызывается без аргументов)" ;;
esac

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
# Маркер корня — только `harness.json`: он не трекается и появляется от
# `./ops setup` в одном месте. `workspace.json` маркером быть не может — он
# трекается, то есть лежит в КАЖДОМ чекауте репозитория, включая
# `packages/agent-workspace`, где проходят и все остальные гейты.
while [ "$ROOT" != "/" ] && [ ! -f "$ROOT/harness.json" ]; do
  ROOT="$(dirname "$ROOT")"
done
[ -f "$ROOT/harness.json" ] || die "не нашёл корень воркспейса (harness.json). Самообновление идёт только из корня; в packages/ и worktrees/ его делать нельзя"

# В git worktree `.git` — файл, в основном чекауте — каталог. Worktree, в
# котором кто-то запускал `./ops sync`, получает собственный `harness.json` и
# иначе прошёл бы обход вверх как корень.
[ -d "$ROOT/.git" ] || die "$ROOT — git worktree, а не корневой чекаут воркспейса; самообновление идёт только в корне"
[ -x "$ROOT/ops" ] || die "в корне нет исполняемого ./ops — сначала './ops setup'"

say "корень: $ROOT"

# ------------------------------------------------------------------- гейты ---
dirty="$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" \
  || die "git не отвечает в $ROOT"
if [ -n "$dirty" ]; then
  printf '%s\n' "$dirty" >&2
  die "в корневом чекауте есть незакоммиченные правки. Они принадлежат worktree задачи — разберитесь с ними руками; stash, reset и checkout здесь делать нельзя"
fi

branch="$(git -C "$ROOT" symbolic-ref --quiet --short HEAD)" \
  || die "корень в detached HEAD — верните его на базовую ветку руками"
upstream="$(git -C "$ROOT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" \
  || die "у ветки '$branch' нет upstream — обновлять нечего и неоткуда"

# Базовая ветка объявлена в tracked-конфигурации воркспейса, а не угадывается по
# upstream: ветка задачи, случайно оставленная в корне, тоже следит за своим
# origin-двойником и прошла бы сверку имён.
base="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("branch",""))' \
  "$ROOT/workspace.json" 2>/dev/null)"
[ -n "$base" ] || die "в $ROOT/workspace.json не читается базовая ветка (поле branch)"
[ "$branch" = "$base" ] \
  || die "корень на ветке '$branch', а базовая ветка воркспейса — '$base'. Это след незакрытой работы в корне; ветку здесь не переключаем, разберитесь руками"

# origin/feature/x -> feature/x: имя удалённого всегда один сегмент, имя ветки
# может содержать слэши.
[ "${upstream#*/}" = "$branch" ] \
  || die "ветка '$branch' следит за '$upstream' — не за своим origin-двойником. Fast-forward притянул бы чужую историю"

say "ветка: $branch -> $upstream"

# ---------------------------------------------------------- credentialed pull ---
# Use the shared GitHub HTTPS transport so pull uses the same canonical token
# as clone, fetch, push and PR operations.
LIB="$SCRIPT_DIR/../commit-and-mr/lib.sh"
[ -f "$LIB" ] \
  || die "не нашёл общую библиотеку commit-and-mr/lib.sh — credentialed pull сделать нечем"

# -------------------------------------------------------------------- pull ---
before="$(git -C "$ROOT" rev-parse HEAD)" || die "не читается HEAD"

# Sourcing lib.sh и gl_load идут внутри этого `$( … )`, а не в самом скрипте:
# gl_load читает корневой `.env` под `set -a` (commit-and-mr/lib.sh: gl_load) и
# иначе вынес бы его переменные в окружение остальной части запуска — в
# `./ops sync`, `./ops check` и в хук `post-merge`, который срабатывает на этот
# же `git pull`. Кред нужен ровно на время самого pull'а; `$( … )` — обычный
# subshell, так что переменные, которые ставит lib.sh (включая GL_*), наружу
# не протекают, а наружу уходит только то, что скрипт печатает явно, и код
# возврата. `WORKSPACE_NO_AUTO_WT_PULL=1` перед вызовом функции остаётся
# префиксным присваиванием bash: оно доезжает до `git` внутри gl_remote_run и
# до хука `post-merge`, который этот `git pull` запускает, ровно так же, как и
# без subshell — это пинует тест на "gh отсутствует в PATH".
#
# Код возврата 3 — не свой: это EXIT_LOGGED_OUT из commit-and-mr/run.sh
# (agents/common/skills/github-login/SKILL.md, раздел про run.sh), та же
# причина отказа получает то же число, а не новую нумерацию.
step "git pull --ff-only"
pull_out="$(
  {
    # shellcheck source=../commit-and-mr/lib.sh
    . "$LIB" || exit 90
    gl_load "$ROOT"
    WORKSPACE_NO_AUTO_WT_PULL=1 gl_git "$ROOT" pull --ff-only
    rc=$?
    if ((rc != 0)) && [[ "${GL_GIT_LOGGED_OUT:-0}" == 1 ]]; then
      printf 'NEXT=%s\n' "$GL_NEXT"
      exit 3
    fi
    exit "$rc"
  } 2>&1
)"
pull_rc=$?
[ -z "$pull_out" ] || printf '%s\n' "$pull_out"

case "$pull_rc" in
  0) ;;
  3) die "git pull --ff-only не прошёл: GITHUB_TOKEN не задан — транспорт остановился до pull'а, причина не в истории корня. Смотрите NEXT= выше: логин — отдельный шаг (человек или skill github-login), потом повторите self-update" ;;
  *) die "git pull --ff-only не прошёл: это либо непройденный fast-forward, либо ошибка GitHub-транспорта (смотрите причину выше, если она есть) — в обоих случаях историю корня не переписываем: ни rebase, ни merge, ни force" ;;
esac

after="$(git -C "$ROOT" rev-parse HEAD)" || die "не читается HEAD после pull"

# -------------------------------------------------------------------- sync ---
step "./ops sync"
"$ROOT/ops" sync || die "'./ops sync' упал — рантайм-деревья собраны не полностью"

step "./ops check"
"$ROOT/ops" check || die "'./ops check' красный после sync: собранные деревья разошлись с agents/"

# ------------------------------------------------------------------- отчёт ---
printf '\n'
# shellcheck disable=SC2031 # ложное срабатывание на двух именах: commit-and-mr/lib.sh
# где-то в дереве вызовов определяет свои ЛОКАЛЬНЫЕ `before` (splice_marked_block —
# текст до маркера в шаблоне описания MR, не имеет отношения к git) и `branch`
# (параметр git-функций вроде gl_push/gl_mr_find/gl_mr_create) под теми же
# именами — shellcheck -x путает их с этой `before` (HEAD до pull на строке 99)
# и этим `branch` (текущая ветка со строки 63), которые pull_out="$( … )" выше
# не трогает вовсе.
if [ "$before" = "$after" ]; then
  printf '%sкод уже свежий%s: %s на %s, новых коммитов нет; деревья пересобраны и ./ops check зелёный\n' \
    "$c_ylw" "$c_off" "$branch" "${before:0:8}"
else
  n="$(git -C "$ROOT" rev-list --count "$before..$after")"
  printf '%sобновлено%s: %s %s -> %s, %s коммит(ов); ./ops check зелёный\n' \
    "$c_grn" "$c_off" "$branch" "${before:0:8}" "${after:0:8}" "$n"
  git -C "$ROOT" log --oneline --no-decorate "$before..$after"
  touched="$(git -C "$ROOT" diff --name-only "$before..$after" -- AGENTS.md agents/)"
  if [ -n "$touched" ]; then
    printf '\n%sагентский слой изменился%s — правила этой сессии прочитаны до обновления:\n' \
      "$c_ylw" "$c_off"
    printf '%s\n' "$touched"
  fi
fi
