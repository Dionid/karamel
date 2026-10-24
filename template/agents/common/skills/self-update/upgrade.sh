#!/usr/bin/env bash
# upgrade.sh — подтянуть общий агентский слой из upstream-репозитория.
#
#   ./ops upgrade [--dry-run]
#
# Upstream задаётся в workspace.json: поле `upstream` (URL) и необязательное
# `upstreamRef` (ветка, по умолчанию main). В upstream должен лежать
# skills/new-workspace/new-workspace.sh (как в karamel): обновление делает он,
# этот скрипт только доставляет свежую копию upstream в .agent-tools/upstream.
# Транспорт — общая библиотека commit-and-mr (HTTPS + GITHUB_TOKEN); file://
# и локальные пути работают без кредов.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../commit-and-mr/lib.sh"

die() { printf 'upgrade: %s\n' "$*" >&2; exit 2; }

ROOT=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="${2:?--root needs a path}"; shift ;;
    --dry-run) args+=(--dry-run) ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "неизвестный аргумент: $1" ;;
  esac
  shift
done
[ -n "$ROOT" ] || die "не указан корень воркспейса (--root); запускайте через ./ops upgrade"
[ -f "$ROOT/workspace.json" ] || die "нет $ROOT/workspace.json"

read -r url ref < <(python3 - "$ROOT/workspace.json" <<'PY'
import json, sys
ws = json.load(open(sys.argv[1]))
print(ws.get("upstream", ""), ws.get("upstreamRef", "main"))
PY
) || true
[ -n "${url:-}" ] || die "в workspace.json не задан upstream: добавьте \"upstream\": \"<url>\""

cache="$ROOT/.agent-tools/upstream"
mkdir -p "$ROOT/.agent-tools"

# shellcheck source=../commit-and-mr/lib.sh
. "$LIB"
gl_load "$ROOT"

if [ -d "$cache/.git" ]; then
  printf '==> fetch %s (%s)\n' "$url" "$ref"
  git -C "$cache" remote set-url origin "$url"
  gl_remote_run "$url" -C "$cache" fetch -q --depth 1 origin "$ref" \
    || die "не удалось получить $url ($ref)"
  git -C "$cache" checkout -q --detach FETCH_HEAD
else
  printf '==> clone %s (%s)\n' "$url" "$ref"
  rm -rf "$cache"
  gl_remote_run "$url" clone -q --depth 1 --branch "$ref" "$url" "$cache" \
    || die "не удалось склонировать $url ($ref)"
fi
printf '==> upstream %s\n' "$(git -C "$cache" log -1 --format='%h %s')"

tool="$cache/skills/new-workspace/new-workspace.sh"
[ -x "$tool" ] || die "в upstream нет skills/new-workspace/new-workspace.sh"
exec "$tool" upgrade "$ROOT" "${args[@]}"
