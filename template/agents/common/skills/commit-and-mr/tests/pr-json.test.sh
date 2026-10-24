#!/usr/bin/env bash
# Malformed non-empty responses are uncertain, never proof that no PR exists.
set -euo pipefail
skill="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib.sh
. "$skill/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo"
git init -q "$tmp/repo"
git -C "$tmp/repo" remote add origin https://github.com/org/repo.git
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
cat "$LIST_FIXTURE"
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GITHUB_TOKEN=regression-secret LIST_FIXTURE="$tmp/list.json"
valid='{"number":1,"url":"https://github.com/org/repo/pull/1","state":"OPEN","baseRefName":"main","title":"PR","body":""}'
for invalid in '[null]' '[false]' '[1]' '[{}]' "[$valid,null]" "[$valid,false]" \
  '[{"number":1,"url":"https://other.example/org/repo/pull/1","state":"OPEN","baseRefName":"main","title":"PR","body":""}]' \
  '[{"number":1,"url":"https://github.com/org/repo/pull/1","state":"UNKNOWN","baseRefName":"main","title":"PR","body":""}]'; do
  printf '%s\n' "$invalid" > "$LIST_FIXTURE"
  rc=0; gl_mr_find "$tmp/repo" feature/test >/dev/null 2>&1 || rc=$?
  [[ "$rc" == 2 ]] || { echo "malformed PR list was treated as absent: $invalid (rc=$rc)" >&2; exit 1; }
done
printf '[]\n' > "$LIST_FIXTURE"
rc=0; gl_mr_find "$tmp/repo" feature/test >/dev/null 2>&1 || rc=$?
[[ "$rc" == 1 ]]
printf '[%s]\n' "$valid" > "$LIST_FIXTURE"
gl_mr_find "$tmp/repo" feature/test
[[ "$MR_IID" == 1 && "$MR_STATE" == opened ]]
echo 'PR JSON schema: malformed entries fail closed; only empty array is absent'
