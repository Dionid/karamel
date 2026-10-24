#!/usr/bin/env python3
"""Every user-reviewed hook has a human-readable name and explanation."""

from __future__ import annotations

import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[3]
SOURCES = (
    ROOT / "agents/codex/config.base.toml",
    ROOT / "agents/codex/config.append.toml",
    ROOT / "agents/claude/settings.base.json",
)


def toml_handlers(path: Path) -> list[tuple[str, dict[str, str]]]:
    """Read the small repeated hook-handler tables without a TOML dependency."""
    handlers: list[tuple[str, dict[str, str]]] = []
    event = ""
    fields: dict[str, str] | None = None
    for line in path.read_text().splitlines():
        header = re.fullmatch(r"\[\[hooks\.([^.]+)\.hooks\]\]", line.strip())
        if header:
            if fields is not None:
                handlers.append((event, fields))
            event, fields = header.group(1), {}
            continue
        if line.startswith("[[") and fields is not None:
            handlers.append((event, fields))
            fields = None
            continue
        if fields is not None:
            field = re.fullmatch(r'([A-Za-z]+)\s*=\s*"(.*)"', line.strip())
            if field:
                fields[field.group(1)] = field.group(2)
    if fields is not None:
        handlers.append((event, fields))
    return handlers


def handlers(path: Path) -> list[tuple[str, dict[str, object]]]:
    if path.suffix == ".toml":
        return toml_handlers(path)
    parsed = json.loads(path.read_text())
    return [
        (event, hook)
        for event, groups in parsed.get("hooks", {}).items()
        for group in groups
        for hook in group.get("hooks", [])
    ]


def main() -> None:
    missing: list[str] = []
    for source in SOURCES:
        configured = handlers(source)
        if not configured:
            missing.append(f"{source.relative_to(ROOT)}: no hook handlers discovered")
        for hook_index, (event, hook) in enumerate(configured):
            if hook.get("type") != "command":
                continue
            message = str(hook.get("statusMessage", "")).strip()
            name, separator, description = message.partition(" — ")
            if not separator or not name.strip() or not description.strip():
                missing.append(
                    f"{source.relative_to(ROOT)}:{event}.hooks[{hook_index}]"
                )

    if missing:
        raise SystemExit(
            "hook statusMessage must be '<name> — <description>':\n- "
            + "\n- ".join(missing)
        )

    print(f"hook metadata: {len(SOURCES)} sources pass")


if __name__ == "__main__":
    main()
