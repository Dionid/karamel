#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
WT="$ROOT/agents/common/skills/wt/wt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/workspace/agents/common/skills/wt" \
  "$TMP/workspace/agents/common/skills/commit-and-mr"
printf '{}\n' > "$TMP/workspace/harness.json"
cp "$WT" "$TMP/workspace/agents/common/skills/wt/wt"
cp "$ROOT/agents/common/skills/commit-and-mr/lib.sh" \
  "$TMP/workspace/agents/common/skills/commit-and-mr/lib.sh"
cp "$ROOT/agents/common/skills/commit-and-mr/"{env.py,redact.py} "$TMP/workspace/agents/common/skills/commit-and-mr/"
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
# Подкоманда ищется по всему argv, а не в $1: перед ней wt подставляет
# `-c url.<https>.insteadOf=<ssh>` и `-c credential.helper=…gh…`, чтобы
# клонировать по HTTPS с токеном gh. Заглушка, читающая только $1, молча
# ничего не создаёт — и тест падает так, будто сломан wt.
prev=""
for arg in "$@"; do
  if [ "$arg" = clone ]; then prev=clone; continue; fi
  if [ "$prev" = clone ]; then prev=url; continue; fi
  if [ "$prev" = url ]; then mkdir -p "$arg/.git"; exit 0; fi
done
exit 0
EOF
chmod +x "$TMP/bin/git"
# gh только должен быть на PATH: заглушка git до credential helper не доходит.
printf '#!/usr/bin/env bash\necho test-user\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

export GITHUB_TOKEN=test-canonical-secret
run() { (cd "$TMP/workspace" && PATH="$TMP/bin:$PATH" bash agents/common/skills/wt/wt "$@"); }
run clone-url task-a git@github.com:team/demo.git >/dev/null
test -d "$TMP/workspace/worktrees/task-a/demo/.git"
run clone-url task-b https://github.com/team/source.git --name copied >/dev/null
test -d "$TMP/workspace/worktrees/task-b/copied/.git"
if run clone-url ../escape https://github.com/team/nope.git >/dev/null 2>&1; then
  echo 'accepted task path escape' >&2; exit 1
fi
test ! -e "$TMP/workspace/repos.json"
