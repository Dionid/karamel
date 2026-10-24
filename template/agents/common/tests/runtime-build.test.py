#!/usr/bin/env python3
"""Contract test for the repository-local runtime builder."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[3]


def comment_keys(node, path="settings"):
    """Paths of every "//" key in a built document, at any depth."""
    found = []
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "//":
                found.append(path)
            found.extend(comment_keys(value, f"{path}.{key}"))
    elif isinstance(node, list):
        for i, value in enumerate(node):
            found.extend(comment_keys(value, f"{path}[{i}]"))
    return found


def copy(source: str, root: Path) -> None:
    src = SOURCE / source
    dst = root / source
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def seed(root: Path) -> Path:
    for source in (
        "agents/build.py",
        "agents/claude/file-suggestion.sh",
        "agents/claude/commands/pull-packages.md",
        "agents/claude/settings.base.json",
        "agents/claude/settings.json",
        "agents/codex/config.base.toml",
        "agents/codex/config.append.toml",
        "agents/common/hooks/block-secret-reads.sh",
        "agents/common/hooks/scan-outgoing-secrets.py",
        "agents/common/routing/catalog.json",  # the builder reads root defaults and profiles from it
        "agents/common/skills/env-check/SKILL.md",
        "workspace.json",
    ):
        copy(source, root)
    for role in sorted((SOURCE / "agents/common/roles").iterdir()):  # roleMinimums must match the role files
        copy(f"agents/common/roles/{role.name}", root)
    archive = root / "agents/archive/legacy/skills/legacy-api/SKILL.md"
    archive.parent.mkdir(parents=True)
    archive.write_text("---\nname: legacy-api\ndescription: Archived fixture.\n---\n")
    return root / "agents/build.py"


with tempfile.TemporaryDirectory(prefix="runtime-build-test-") as raw:
    root = Path(raw)
    build = seed(root)
    subprocess.run([str(build), "sync"], cwd=root, check=True, capture_output=True)
    subprocess.run([str(build), "check"], cwd=root, check=True, capture_output=True)

    assert (root / ".claude/skills/env-check").is_symlink()
    assert (root / ".agents/skills/env-check").is_symlink()
    assert not (root / ".claude/skills/legacy-api").exists()
    assert not (root / ".agents/skills/legacy-api").exists()
    assert (root / ".claude/agents/analyst.md").is_symlink()
    assert (root / ".codex/agents/analyst.toml").is_symlink()
    assert (root / ".claude/agents/analyst--high--terminal.md").is_file()
    assert (root / ".codex/agents/analyst--low--delegating.toml").is_file()
    assert (root / ".claude/commands/pull-packages.md").is_symlink()
    assert (root / ".claude/hooks/scan-outgoing-secrets.py").is_symlink()
    assert (root / ".agents/hooks/scan-outgoing-secrets.py").is_symlink()

    settings = json.loads((root / ".claude/settings.json").read_text())
    assert "Edit(/knowledge/**)" in settings["permissions"]["deny"]
    # The team layer explains that rule with a "//" key, because JSON has no
    # comments. The generated file is validated by Claude Code against its own
    # schema, so the comment must not survive the build — anywhere in it, not
    # just under the one key that happens to carry a comment today. Keys only:
    # "//" is legitimate inside a value ("https://…") and in a slash-command key.
    leaked = comment_keys(settings)
    assert not leaked, f"// comment keys leaked into the built settings: {leaked}"
    codex = (root / ".codex/config.toml").read_text()
    assert str(root) in codex
    # Claude lists skills under one character budget; the generated settings must pin it.
    assert settings["env"]["SLASH_COMMAND_TOOL_CHAR_BUDGET"].isdigit()
    assert int(settings["env"]["SLASH_COMMAND_TOOL_CHAR_BUDGET"]) > 8000
    # Codex truncates the AGENTS.md chain at project_doc_max_bytes; the key must survive the
    # build as a TOP-LEVEL key — after the first table header it would belong to that table.
    doc_limit = re.search(r"^project_doc_max_bytes = (\d+)$", codex, re.M)
    assert doc_limit and int(doc_limit.group(1)) > 32 * 1024
    assert doc_limit.start() < codex.index("\n[")
    assert json.loads((root / "harness.json").read_text())["team"] == "Team"

    (root / ".codex/config.toml").write_text("drift\n")
    check = subprocess.run([str(build), "check"], cwd=root, capture_output=True)
    assert check.returncode == 1
    status = subprocess.run(
        [str(build), "status", "--json"], cwd=root, check=True, capture_output=True, text=True
    )
    assert json.loads(status.stdout)["clean"] is False

    directory_case = root / "directory-case"
    directory_build = seed(directory_case)
    outside_directory = root / "outside-directory"
    outside_directory.mkdir()
    sentinel = outside_directory / "sentinel"
    sentinel.write_text("keep\n")
    (directory_case / ".agents").mkdir()
    (directory_case / ".agents/skills").symlink_to(outside_directory)
    refused = subprocess.run(
        [str(directory_build), "sync"], cwd=directory_case, capture_output=True, text=True
    )
    assert refused.returncode == 2
    assert "refusing to follow runtime symlink" in refused.stderr
    assert sentinel.read_text() == "keep\n"

    output_case = root / "output-case"
    output_build = seed(output_case)
    outside_file = root / "outside-file"
    outside_file.write_text("keep\n")
    (output_case / ".codex").mkdir()
    (output_case / ".codex/config.toml").symlink_to(outside_file)
    refused = subprocess.run(
        [str(output_build), "sync"], cwd=output_case, capture_output=True, text=True
    )
    assert refused.returncode == 2
    assert "refusing to follow runtime symlink" in refused.stderr
    assert outside_file.read_text() == "keep\n"

print("runtime builder: pass")
