#!/usr/bin/env bash

set -euo pipefail

self_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
real_publish="$self_dir/../publish.sh"
real_env_check="$self_dir/../../env-check/env-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

root="$tmp/workspace"
mkdir -p "$root/.claude/skills/to-tickets" "$root/.claude/skills/env-check" "$root/.claude/skills/commit-and-mr" "$root/tickets"
printf '{}\n' > "$root/harness.json"
cp "$real_publish" "$root/.claude/skills/to-tickets/publish.sh"
cp "$self_dir/../../commit-and-mr/"{lib.sh,env.py,redact.py} "$root/.claude/skills/commit-and-mr/"
cp "$real_env_check" "$root/.claude/skills/env-check/env-check.sh"
chmod +x "$root/.claude/skills/to-tickets/publish.sh" "$root/.claude/skills/env-check/env-check.sh"
printf '# 01 — First ticket\n\n**Заблокирован:** Ничем\n' > "$root/tickets/01-first.md"
printf '# 02 — Second ticket\n\n**Заблокирован:** 01\n' > "$root/tickets/02-second.md"

publish="$root/.claude/skills/to-tickets/publish.sh"
cd "$root"

"$publish" local --slug demo --dir "$root/tickets" >/dev/null
test -f "$root/.scratch/demo/issues/01-first.md"
test -f "$root/.scratch/demo/issues/02-second.md"

rm -rf "$root/.scratch"
"$publish" --slug default-local --dir "$root/tickets" >/dev/null
test -d "$root/.scratch/default-local/issues"

out="$("$publish" github --repo owner/repo --dir "$root/tickets" --dry-run)"
grep -q '\[dry-run\]' <<<"$out"

if "$publish" github --project group/repo --dir "$root/tickets" --dry-run >/dev/null 2>&1; then
  echo "unknown --project option must be rejected" >&2
  exit 1
fi

printf 'TICKETS_TRACKER=github\n' > "$root/.env"
out="$("$publish" --repo owner/repo --dir "$root/tickets" --dry-run)"
grep -q 'GitHub' <<<"$out"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$GITHUB_TOKEN" == canonical-secret && "$GH_TOKEN" == canonical-secret ]]
case "$1" in
  api) echo test-user ;;
  issue)
    [[ "$2" == create && "$3" == --repo && "$4" == owner/repo ]]
    printf 'called\n' >> "$ISSUE_CALLS"
    echo https://github.com/owner/repo/issues/1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/bin/gh"
out="$(PATH="$tmp/bin:$PATH" GITHUB_TOKEN=canonical-secret GH_TOKEN=wrong ISSUE_CALLS="$tmp/issues" \
  "$publish" github --repo owner/repo --dir "$root/tickets")"
[[ "$(wc -l < "$tmp/issues" | tr -d ' ')" = 2 ]]
[[ "$out" != *canonical-secret* && "$out" != *wrong* ]]
if PATH="$tmp/bin:$PATH" GITHUB_TOKEN=canonical-secret "$publish" github --repo evil.test/owner/repo --dir "$root/tickets" >/dev/null 2>&1; then
  echo 'foreign host accepted' >&2; exit 1
fi
echo "ok: local publishing and GitHub issues use the canonical token"
