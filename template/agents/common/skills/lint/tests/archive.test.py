#!/usr/bin/env python3
"""Archived harness docs are frozen snapshots, not active runtime contracts."""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[5]
LINTER = SOURCE_ROOT / "agents/common/skills/lint/lint.py"
spec = importlib.util.spec_from_file_location("workspace_lint_archive_test", LINTER)
assert spec and spec.loader
lint = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lint)

original_root = lint.ROOT
original_findings = lint.findings

try:
    with tempfile.TemporaryDirectory(prefix="lint-archive-") as raw:
        root = Path(raw)
        archived = root / "agents/archive/legacy/skills/old/SKILL.md"
        archived.parent.mkdir(parents=True)
        archived.write_text(
            "[old sibling](../missing.md)\n"
            "Run `.claude/skills/removed/run.sh`.\n",
            encoding="utf-8",
        )

        lint.ROOT = root
        lint.findings = []
        lint.check_links([archived])
        lint.check_paths([archived])
        assert lint.findings == [], lint.findings

        active = root / "docs/active.md"
        active.parent.mkdir(parents=True)
        active.write_text("[broken](missing.md)\n", encoding="utf-8")
        lint.check_links([active])
        assert any("link target does not exist" in item[2] for item in lint.findings)
finally:
    lint.ROOT = original_root
    lint.findings = original_findings

print("harness archive link scope: pass")
