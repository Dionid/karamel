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
ws = json.load(open(f"{root}/workspace.json"))
assert ws["team"] == "Acme", ws
assert ws["upstream"] and ws["upstreamRef"] == "main", ws
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
  --only execbit --only markdown --only harness --only decisions ${LINT_ARGS:-}) > "$TMP/lint.log" 2>&1 \
  || { cat "$TMP/lint.log"; fail "lint созданного воркспейса"; }
ok "lint созданного воркспейса"

# Полный lint с behavior-тестами шаблона долгий и тянет Chromium: только по
# FULL_LINT=1 (в CI).
if [ "${FULL_LINT:-0}" = 1 ]; then
  # shellcheck disable=SC2086 # LINT_ARGS намеренно делится на слова
  (cd "$WS" && bash agents/common/skills/lint/lint.sh ${LINT_ARGS:-}) > "$TMP/lint-full.log" 2>&1 \
    || { cat "$TMP/lint-full.log"; fail "полный lint созданного воркспейса"; }
  ok "полный lint созданного воркспейса, включая behavior-тесты"
fi

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
if grep -q 'differs' <<<"$out"; then echo "$out"; fail "differs без локальных правок"; fi
ok "upgrade без изменений шаблона ничего не меняет"

mkdir -p "$WS/agents/common/skills/gone"
echo x > "$WS/agents/common/skills/gone/SKILL.md"
echo "# local" >> "$WS/GIT.md"
echo "# local rule" >> "$WS/agents/common/skills/wt/SKILL.md"
echo "# team rule" >> "$WS/AGENTS.md"
git -C "$WS" add -A && git -C "$WS" commit -qm wip

# Список перезаписываемых локальных версий: в dry run и в upgrade, до записи.
check_differs() { # <label> <output>
  local label="$1" out="$2" f
  for f in GIT.md agents/common/skills/wt/SKILL.md 'agents/common/skills/gone/SKILL.md (нет в шаблоне'; do
    grep -qF "  differs $f" <<<"$out" || { echo "$out"; fail "$label: нет differs $f"; }
  done
  for f in AGENTS.md WORKTREES.md ops agents/common/skills/lint/lint.sh; do
    if grep -qxF "  differs $f" <<<"$out"; then echo "$out"; fail "$label: лишний differs $f"; fi
  done
  [ "$(grep -n '  differs GIT.md' <<<"$out" | cut -d: -f1)" -lt "$(grep -n '  update GIT.md' <<<"$out" | cut -d: -f1)" ] \
    || { echo "$out"; fail "$label: список differs не перед записью"; }
}
out="$("$NW" upgrade "$WS" --dry-run)"
check_differs "dry run" "$out"
grep -q '# local' "$WS/GIT.md" || fail "dry run перезаписал GIT.md"
out="$("$NW" upgrade "$WS")"
check_differs "upgrade" "$out"
ok "upgrade печатает локальные отличия общего слоя (dry run и запись), без командных и нетронутых файлов"
[ ! -e "$WS/agents/common/skills/gone" ] || fail "upgrade не удалил скилл, которого нет в шаблоне"
cmp -s "$KARAMEL/template/GIT.md" "$WS/GIT.md" || fail "upgrade не вернул общий GIT.md"
grep -q '# team rule' "$WS/AGENTS.md" || fail "upgrade перезаписал командный AGENTS.md"
ok "upgrade обновляет общий слой и не трогает командные файлы"

echo x >> "$WS/GIT.md"
"$NW" upgrade "$WS" > /dev/null 2>&1 && fail "upgrade при грязном дереве"
ok "upgrade отказывается работать при незакоммиченных правках"

# ./ops upgrade: upstream — локальный git-репозиторий с копией karamel.
UP="$TMP/upstream"
mkdir -p "$UP"
cp -a "$KARAMEL/skills" "$KARAMEL/template" "$UP/"
git -C "$WS" checkout -q GIT.md
git -C "$UP" init -q -b main && git -C "$UP" add -A && git -C "$UP" commit -qm upstream
python3 - "$WS" "$UP" <<'PY'
import json, sys
root, up = sys.argv[1:]
ws = json.load(open(f"{root}/workspace.json"))
ws["upstream"] = f"file://{up}"
json.dump(ws, open(f"{root}/workspace.json", "w"), indent=2)
PY
git -C "$WS" commit -qam "point upstream to local copy"
echo "# from upstream" >> "$UP/template/WORKTREES.md"
git -C "$UP" commit -qam "upstream change"
(cd "$WS" && ./ops upgrade > "$TMP/ops-upgrade.log" 2>&1) || { cat "$TMP/ops-upgrade.log"; fail "./ops upgrade"; }
grep -q '# from upstream' "$WS/WORKTREES.md" || { cat "$TMP/ops-upgrade.log"; fail "./ops upgrade не привёз изменение из upstream"; }
[ -d "$WS/.agent-tools/upstream/.git" ] || fail "нет кэша .agent-tools/upstream"
if git -C "$WS" status --porcelain | grep -q '.agent-tools'; then fail ".agent-tools попал в git status"; fi
git -C "$WS" commit -qam "upgrade"
echo "# second" >> "$UP/template/WORKTREES.md"
git -C "$UP" commit -qam "upstream change 2"
(cd "$WS" && ./ops upgrade > "$TMP/ops-upgrade2.log" 2>&1) || { cat "$TMP/ops-upgrade2.log"; fail "повторный ./ops upgrade"; }
grep -q '# second' "$WS/WORKTREES.md" || fail "повторный ./ops upgrade не обновил кэш upstream"
ok "./ops upgrade тянет общий слой из upstream (clone, затем fetch)"

echo "all passed"
