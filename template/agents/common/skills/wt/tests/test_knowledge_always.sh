#!/usr/bin/env bash
# Run the real wt with a generic fixture manifest and offline repositories. New tasks
# must import the authored project from main and the dedicated Notion-mirror
# repository from `always`, without importing the removed legacy knowledge
# checkout.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/workspace"
mkdir -p "$WS/agents/common/skills/"{wt,commit-and-mr,clone} "$TMP/bin"
cp "$ROOT/agents/common/skills/wt/wt" "$WS/agents/common/skills/wt/wt"
cp "$ROOT/agents/common/skills/commit-and-mr/lib.sh" "$WS/agents/common/skills/commit-and-mr/lib.sh"
cp "$ROOT/agents/common/skills/commit-and-mr/"{env.py,redact.py} "$WS/agents/common/skills/commit-and-mr/"
cat > "$WS/repos.json" <<'JSON'
{"always": ["agent-workspace", "team-knowledge", "reference-store"], "notionSnapshotRepo": "reference-store", "repos": {"product-docker-infra": {"branch": "main", "url": "git@github.com:team/product-docker-infra.git"}, "agent-workspace": {"branch": "main"}, "team-knowledge": {"branch": "main", "knowledgeRoot": "projects/product/knowledge", "specRoot": "projects/product"}, "reference-store": {"branch": "main"}, "platform": {"branch": "main", "specRoot": ""}}}
JSON
printf '{"branchPrefix":"feature/"}\n' > "$WS/harness.json"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WS/agents/common/skills/clone/ensure-repository"
chmod +x "$WS/agents/common/skills/clone/ensure-repository"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset AGENT_SESSION_ID
export GITHUB_TOKEN=test-canonical-secret
for repo in product-docker-infra agent-workspace team-knowledge reference-store; do
  base="$(jq -r --arg r "$repo" '.repos[$r].branch' "$WS/repos.json")"
  seed="$TMP/$repo"
  git init --quiet -b "$base" "$seed"
  if [ "$repo" = team-knowledge ]; then
    mkdir -p "$seed/projects/product/knowledge/facts" "$seed/projects/product/openspec/specs"
    printf 'authored import on main\n' > "$seed/projects/product/knowledge/facts/main.md"
    printf 'spec\n' > "$seed/projects/product/openspec/specs/main.md"
  elif [ "$repo" = reference-store ]; then
    mkdir -p "$seed/knowledge/references"
    printf 'mirror snapshot\n' > "$seed/knowledge/references/snapshot.md"
  else
    printf 'base\n' > "$seed/base"
  fi
  git -C "$seed" add .
  git -C "$seed" commit --quiet -m fixture
  git clone --quiet "$seed" "$WS/packages/$repo"
  git -C "$WS/packages/$repo" remote set-url origin "git@github.com:team/$repo.git"
done
real_git="$(command -v git)"
cat > "$TMP/bin/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = fetch ]; then exit 0; fi
done
exec "$real_git" "\$@"
EOF
printf '#!/usr/bin/env bash\nprintf "success\\tfake-user\\t\\n"\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/git" "$TMP/bin/gh"
out="$(cd "$WS" && PATH="$TMP/bin:$PATH" bash agents/common/skills/wt/wt new cutover --repo product-docker-infra --pull 2>&1)" || {
  printf '%s\n' "$out" >&2
  exit 1
}
[ -f "$WS/worktrees/cutover/team-knowledge/projects/product/knowledge/facts/main.md" ]
[ -d "$WS/worktrees/cutover/team-knowledge/projects/product/openspec" ]
[ -d "$WS/worktrees/cutover/agent-workspace" ]
[ -d "$WS/worktrees/cutover/reference-store" ]
[ -f "$WS/worktrees/cutover/reference-store/knowledge/references/snapshot.md" ]
[ ! -e "$WS/worktrees/cutover/knowledge" ]
# platform carries its own spec store but is NOT in `always`: a product
# task must not drag the platform checkout in. Putting it in `always` to
# "make specs reachable" is the mistake this line catches.
[ ! -e "$WS/worktrees/cutover/platform" ]
[ "$(git -C "$WS/worktrees/cutover/team-knowledge" branch --show-current)" = feature/cutover ]
[ "$(git -C "$WS/worktrees/cutover/reference-store" branch --show-current)" = feature/cutover ]
echo 'ok: task worktrees import team-knowledge main and the Notion-mirror repository, excluding the removed legacy repository'
