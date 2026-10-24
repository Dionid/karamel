"""Keep generic knowledge and OpenSpec writes in manifest-owned worktrees."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SKILLS = ROOT / "agents/common/skills"


def normalized(path: Path) -> str:
    return " ".join(path.read_text().split())


knowledge = normalized(SKILLS / "knowledge/SKILL.md")
spec = normalized(SKILLS / "spec/SKILL.md")
policy = normalized(ROOT / "AGENTS.md")

for required in (
    "repos.json",
    "always",
    "knowledgeRoot",
    "resolve.py",
    "notionSnapshotRepo",
    "worktrees/<task>/<knowledge-repo>/<knowledge-root>/",
    "packages/<knowledge-repo>/<knowledge-root>/",
    "machine-generated snapshot",
    "knowledge/references/",
):
    assert required in knowledge, f"knowledge skill lost routing rule: {required}"

for required in (
    "repos.json",
    "always",
    "specRoot",
    "worktrees/<task>/<spec-repo>/<spec-root>/openspec/",
    "planningHome.root",
    "realpath",
):
    assert required in spec, f"spec skill lost routing rule: {required}"

# Generic routing must use manifest fields rather than fixture repository names.
for forbidden in ("example-hardcoded-company",):
    assert forbidden not in knowledge.lower()
    assert forbidden not in spec.lower()

assert "skill **`knowledge`**" in policy
assert "skill **`spec`**" in policy

for role in ("analyst.md", "architect.md"):
    role_text = normalized(ROOT / "agents/common/roles" / role)
    assert "**`spec`** skill" in role_text, f"{role} does not verify spec routing"

print("knowledge routing: pass")
