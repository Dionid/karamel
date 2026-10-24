#!/usr/bin/env python3
"""Pin the always-loaded policy kernel while allowing procedural rewrites."""

import importlib.util
import tempfile
from pathlib import Path


# <root>/agents/common/tests/agents-policy.test.py — root is fixed by this
# file's own location in either the source or generated runtime tree.
ROOT = Path(__file__).resolve().parents[3]
LINTER = ROOT / "agents/common/skills/lint/lint.py"

spec = importlib.util.spec_from_file_location("workspace_lint", LINTER)
assert spec and spec.loader
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)


# Ядро политики — единственный tracked-файл AGENTS.md этого репозитория.
AGENTS = ROOT / "AGENTS.md"
root_agents = " ".join(AGENTS.read_text().split())
assert not (ROOT / "AGENTS.base.md").exists(), "AGENTS.base.md must stay consolidated into AGENTS.md"
required_policy = {
    "workspace boundary": "Корень этого репозитория — **воркспейс**",
    "generated trees": "`.claude/`, `.agents/` и `.codex/` — результат сборки",
    "worktree boundary": "Никогда не редактируйте `packages/<repo>/`",
    "worktree implementation": "Никогда не используйте встроенный `EnterWorktree`",
    "coordination handoff": "Перед финальным ответом всегда оставляйте `coord finish <task>`",
    "compose ownership": "чужие контейнеры не трогайте",
    "destructive compose": "`down -v`, `docker rm`",
    "secret boundary": "Никогда не читайте `.env`",
    "draft PR": "Коммит, push и Draft PR — штатный закрывающий шаг",
    "no force push": "Никаких merge, approve, снятия Draft, tag или force-push",
    "runtime verification": "`./ops sync` раскладывает и пересобирает",
}
missing = [
    name
    for name, text in required_policy.items()
    if " ".join(text.split()) not in root_agents
]

assert not missing, f"policy kernel lost required policy: {', '.join(missing)}"


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "AGENTS.md").write_text("ok\n" * 400)
    assert lint.agent_budget_violations(root) == []

    (root / "AGENTS.md").write_text("too long\n" * 401)
    assert [item[0] for item in lint.agent_budget_violations(root)] == ["AGENTS.md"]

    # Codex cuts the AGENTS.md chain at project_doc_max_bytes: the limit is read from
    # the tracked config, Codex's default (32 KiB) applies when the key is absent.
    assert lint.codex_project_doc_limit(root) == 32 * 1024
    codex = root / lint.CODEX_CONFIG
    codex.parent.mkdir(parents=True)
    codex.write_text("# comment\nproject_doc_max_bytes = 4000\n\n[features]\nmulti_agent_v2 = true\n")
    assert lint.codex_project_doc_limit(root) == 4000
    # The same line under a table header belongs to that table and Codex ignores it.
    codex.write_text("[features]\nmulti_agent_v2 = true\nproject_doc_max_bytes = 4000\n")
    assert lint.codex_project_doc_limit(root) == 32 * 1024
    codex.write_text("project_doc_max_bytes = 4000\n\n[features]\nmulti_agent_v2 = true\n")
    (root / "AGENTS.md").write_text("x" * 3999)
    assert lint.agents_bytes(root) == (3999, 4000)

    # Claude lists skills under one character budget: pinned in the settings env,
    # 8000 chars when unset; the listing spends every skill's name plus description.
    assert lint.skill_listing_budget(root) == lint.SKILL_LISTING_FALLBACK_CHARS
    settings = root / lint.CLAUDE_SETTINGS
    settings.parent.mkdir(parents=True)
    settings.write_text('{"env": {"SLASH_COMMAND_TOOL_CHAR_BUDGET": "12345"}}\n')
    assert lint.skill_listing_budget(root) == 12345
    skill = root / "agents/common/skills/demo/SKILL.md"
    skill.parent.mkdir(parents=True)
    skill.write_text("---\nname: demo\ndescription: ten chars.\n---\n\n# demo\n")
    assert lint.skill_listing_chars(root) == len("demo") + len("ten chars.")
    command = root / lint.CLAUDE_COMMANDS / "go.md"
    command.parent.mkdir(parents=True)
    command.write_text("---\ndescription: run it\n---\n\nRun.\n")
    assert lint.skill_listing_chars(root) == len("demo") + len("ten chars.") + len("go") + len("run it")

# The live repository must sit inside both limits — the same gates lint.sh runs.
size, limit = lint.agents_bytes(ROOT)
assert size < limit, f"AGENTS.md is {size} bytes, Codex would cut it at {limit}"
assert lint.skill_listing_chars(ROOT) <= lint.skill_listing_budget(ROOT), "skill listing over its Claude Code budget"

print("agents policy: pass")
