#!/usr/bin/env bash

set -euo pipefail

skill="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

good="$tmp/good.md"
cat > "$good" <<'EOF'
## Что и зачем
Нужно сохранить SSH-only delivery.

## Изменения
- Добавлен локальный gate.

## Инфраструктура, схема, зависимости
Нет.

## Как проверить
Запустить тест описания.

## Риски и что осталось
Нет.

## Changelog

Нет.
EOF

"$skill/describe.sh" check --file "$good" | grep -q '^DESCRIPTION_OK=true$'

bad="$tmp/bad.md"
sed '/## Как проверить/,$d' "$good" > "$bad"
if "$skill/describe.sh" check --file "$bad" >/dev/null 2>&1; then
  echo "missing sections must fail" >&2
  exit 1
fi

blocked="$tmp/blocked.md"
cp "$good" "$blocked"
printf '\n<!-- task-link:start -->\nlegacy\n<!-- task-link:end -->\n' >> "$blocked"
if "$skill/describe.sh" check --file "$blocked" >/dev/null 2>&1; then
  echo "generated blocks must fail" >&2
  exit 1
fi

# A description read back from GitHub: strip drops the managed block, and the
# rest passes check again.
"$skill/describe.sh" strip --file "$blocked" > "$tmp/stripped.md"
if grep -q 'task-link' "$tmp/stripped.md"; then
  echo "strip left the managed block in" >&2
  exit 1
fi
"$skill/describe.sh" check --file "$tmp/stripped.md" | grep -q '^DESCRIPTION_OK=true$'

if "$skill/describe.sh" set --file "$good" >/dev/null 2>&1; then
  echo "API-backed set command must be unavailable" >&2
  exit 1
fi

echo "ok: offline MR description gate"
