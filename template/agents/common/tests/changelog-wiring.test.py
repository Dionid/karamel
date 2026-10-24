"""The changelog skill is wired in, and the wiring is load-bearing.

The skill itself no longer lives here: it belongs to the knowledge repository
and reaches this runtime through the `skills` field of `repos.json`. Its own
behaviour is tested next to it, in that repository. What stays testable here is
the *wiring* — the manifest entry that imports it, the rows that route to it,
the closing step that calls it, the rule in AGENTS.md it satisfies, and the MR
section that carries the link back. The MR section is the half that does not
depend on another repository at all, so it is asserted hardest: the gate must
refuse a description without `## Changelog` even in a workspace where the skill
was never imported.

This file must stay green in a checkout with an empty `packages/` — that is the
ordinary state of CI and of a fresh clone. The imported skill is therefore
asserted through the manifest always, and through the built link only when the
source repository is actually cloned.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SKILLS = ROOT / "agents/common/skills"


def table_rows(text: str) -> str:
    """Only the markdown table lines.

    Anchored to the table, not to the document: a passing mention in prose keeps
    a "somewhere in the file" assertion green after the row it exists to protect
    has been deleted.
    """
    return "\n".join(line for line in text.splitlines() if line.lstrip().startswith("|"))


# ------------------------------------------------- the skill is not local
# Deleting it here was the point; a copy that creeps back would shadow the
# imported one and build.py would then refuse the import as a name collision.
assert not (SKILLS / "changelog").exists(), (
    "agents/common/skills/changelog is back — the skill lives in the knowledge "
    "repository now, and a local copy would collide with the imported one"
)

# ------------------------------------------------- the manifest imports it
# External changelog providers are optional in an unconfigured workspace.
# The import mechanism itself is covered by runtime-build.test.py.

# --------------------------------------------------------------- routing rows
for rel in ("knowledge/SKILL.md", "knowledge/SKILL.md"):
    rows = table_rows((SKILLS / rel).read_text(encoding="utf-8"))
    row = [line for line in rows.splitlines() if "changelog/" in line]
    assert row, f"{rel} has no changelog row at all"
    assert any("`changelog`" in line for line in row), (
        f"{rel} still routes changelog to a directory instead of the skill that writes it"
    )

closing = (SKILLS / "commit-and-mr/SKILL.md").read_text(encoding="utf-8")
assert "skill **`changelog`**" in closing, (
    "commit-and-mr does not call the skill — then nothing makes it fire"
)
assert "../changelog/SKILL.md" not in closing, (
    "commit-and-mr links to a path that no longer exists in this repository"
)

policy = " ".join((ROOT / "AGENTS.md").read_text(encoding="utf-8").split())
assert "skill **`changelog`**" in policy, (
    "AGENTS.md mandates the entry without naming the skill that satisfies the rule"
)
# The two ways a cross-repo skill fails quietly. Both are documented, or an
# agent meets them as a mystery instead of as a known cost.
assert "`skills` в `repos.json`" in policy, (
    "AGENTS.md does not say how a skill from another repository reaches the runtime"
)
for fact, what in (
    ("дефолтной ветки", "that the skill is served from the default branch of its repository"),
    ("непополненным `packages/`", "that an unpopulated packages/ means no skill at all"),
):
    assert fact in policy, f"AGENTS.md does not warn {what}"

# ------------------------------------------------- the link back from the MR
template = (SKILLS / "mr-description/template.md").read_text(encoding="utf-8")
assert "## Changelog" in template, "the MR template carries no changelog link"
assert "## Changelog" in (SKILLS / "mr-description/SKILL.md").read_text(encoding="utf-8")

# ...and the gate actually enforces it. Prose is a promise; describe.sh is what
# a person meets. This half lives here and keeps working with no packages/.
describe = SKILLS / "mr-description/describe.sh"
BODY = """## Что и зачем

Проверка гейта.

## Изменения

- Гейт: добавлена секция.

## Инфраструктура, схема, зависимости

Нет.

## Как проверить

Этим тестом.

## Риски и что осталось

Нет.
"""


def check(body: str) -> subprocess.CompletedProcess[str]:
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
        handle.write(body)
        path = handle.name
    try:
        return subprocess.run(
            ["bash", str(describe), "check", "--file", path],
            capture_output=True, text=True, check=False,
        )
    finally:
        os.unlink(path)


missing = check(BODY)
assert missing.returncode != 0, "a description without ## Changelog must not pass"
assert "Changelog" in missing.stderr, (
    f"the refusal must name the missing section: {missing.stderr!r}"
)

# "Нет" is allowed on purpose: the gate asks the question, the skill answers it.
# Forcing an entry would buy invented ones.
allowed = check(BODY + "\n## Changelog\n\nНет.\n")
assert allowed.returncode == 0 and "DESCRIPTION_OK=true" in allowed.stdout, (
    f"an honest 'Нет' must pass: {allowed.stdout!r} {allowed.stderr!r}"
)

linked = check(BODY + "\n## Changelog\n\n`projects/p/knowledge/changelog/2026-10-16-x.md` — «Заголовок».\n")
assert linked.returncode == 0, f"a real entry path must pass: {linked.stderr!r}"

# Order matters: the section is last, and a description that puts it elsewhere
# is reported rather than silently accepted.
out_of_order = check("## Changelog\n\nНет.\n\n" + BODY)
assert out_of_order.returncode != 0, "## Changelog out of order must be reported"

print("changelog wiring: pass")
