#!/usr/bin/env bash
# Сквозная проверка: create → ./ops check → lint → clone + wt new → upgrade.
# LINT_ARGS задаёт аргументы lint.sh созданного воркспейса (в CI: --require-tools).

set -euo pipefail

KARAMEL="$(cd "$(dirname "$0")/.." && pwd)"
NW="$KARAMEL/skills/new-workspace/new-workspace.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok    %s\n' "$*"; }

# Локальный «продуктовый» репозиторий, чтобы clone и wt работали без сети.
git init -q -b main "$TMP/src"
git -C "$TMP/src" commit -q --allow-empty -m init
git clone -q --bare "$TMP/src" "$TMP/demo.git"

WS="$TMP/ws"
env -u GITHUB_TOKEN "$NW" create "$WS" --team Acme \
  --knowledge acme-knowledge=https://github.com/acme/knowledge \
  --repo api=https://github.com/acme/api@develop > "$TMP/create.log" 2>&1 \
  || { cat "$TMP/create.log"; fail "create"; }
ok "create"

python3 - "$WS" <<'PY' || fail "сгенерированные файлы"
import json, sys
root = sys.argv[1]
m = json.load(open(f"{root}/repos.json"))
assert m["always"] == ["acme-knowledge"], m
assert m["repos"]["acme-knowledge"]["knowledgeRoot"] == "knowledge", m
assert m["repos"]["api"] == {"url": "https://github.com/acme/api", "branch": "develop"}, m
assert json.load(open(f"{root}/workspace.json"))["team"] == "Acme"
assert "[api](https://github.com/acme/api)" in open(f"{root}/PACKAGES.md").read()
PY
ok "repos.json, workspace.json, PACKAGES.md"

for f in harness.json .claude/skills/wt/wt .env; do
  [ -e "$WS/$f" ] || fail "нет $f после ./ops setup"
done
git -C "$WS" log --oneline -1 > /dev/null || fail "нет первого коммита"
(cd "$WS" && ./ops check > /dev/null) || fail "./ops check"
ok "./ops setup и ./ops check"

"$NW" create "$WS" --team Again > /dev/null 2>&1 && fail "create поверх непустого каталога"
ok "create отказывается писать в непустой каталог"

# shellcheck disable=SC2086 # LINT_ARGS намеренно делится на слова
(cd "$WS" && bash agents/common/skills/lint/lint.sh --only syntax --only shellcheck \
  --only execbit --only markdown --only harness ${LINT_ARGS:-}) > "$TMP/lint.log" 2>&1 \
  || { cat "$TMP/lint.log"; fail "lint созданного воркспейса"; }
ok "lint созданного воркспейса"

python3 - "$WS" "$TMP/demo.git" <<'PY'
import json, sys
root, bare = sys.argv[1:]
m = json.load(open(f"{root}/repos.json"))
m["repos"]["demo"] = {"url": f"file://{bare}", "branch": "main", "deps": "none"}
json.dump(m, open(f"{root}/repos.json", "w"), indent=2)
PY
(cd "$WS" && ./ops clone demo > /dev/null 2>&1) || fail "./ops clone demo"
(cd "$WS" && .claude/skills/wt/wt new try-it --repo demo --no-always > /dev/null 2>&1) || fail "wt new"
[ "$(git -C "$WS/worktrees/try-it/demo" branch --show-current)" = "codex/try-it" ] || fail "ветка worktree"
git -C "$WS" checkout -q repos.json
ok "clone и wt new создают worktrees/<task>/<repo> на ветке codex/<task>"

out="$("$NW" upgrade "$WS" --dry-run)"
grep -q 'добавлено 0, обновлено 0, удалено 0' <<<"$out" || { echo "$out"; fail "upgrade сразу после create должен быть пустым"; }
ok "upgrade без изменений шаблона ничего не меняет"

mkdir -p "$WS/agents/common/skills/gone"
echo x > "$WS/agents/common/skills/gone/SKILL.md"
echo "# local" >> "$WS/GIT.md"
echo "# team rule" >> "$WS/AGENTS.md"
git -C "$WS" add -A && git -C "$WS" commit -qm wip
"$NW" upgrade "$WS" > /dev/null
[ ! -e "$WS/agents/common/skills/gone" ] || fail "upgrade не удалил скилл, которого нет в шаблоне"
cmp -s "$KARAMEL/template/GIT.md" "$WS/GIT.md" || fail "upgrade не вернул общий GIT.md"
grep -q '# team rule' "$WS/AGENTS.md" || fail "upgrade перезаписал командный AGENTS.md"
ok "upgrade обновляет общий слой и не трогает командные файлы"

echo x >> "$WS/GIT.md"
"$NW" upgrade "$WS" > /dev/null 2>&1 && fail "upgrade при грязном дереве"
ok "upgrade отказывается работать при незакоммиченных правках"

echo "all passed"
