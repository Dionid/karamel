#!/usr/bin/env python3
"""Self-test for the Claude-scheduler hook — run by lint.sh as a behaviour test.

The hook refuses the seven entry points that schedule work inside the CLI
instead of in the runtime: the three Cron* tools, `ScheduleWakeup`, the writing
actions of `RemoteTrigger`, and the `schedule` and `loop` skills.

Two traps are guarded here. The first is the one every hook in this directory
documents: the agents disagree about the payload shape, and a hook that reads
only Claude Code's snake_case denies nothing under camelCase while still
reporting itself as installed. The second is specific to this hook — `schedule`,
`loop` and `RemoteTrigger`'s action are a tool *argument*, not a tool name, so a
case that passes for `CronCreate` proves nothing about them. Both run in both
shapes.

`RemoteTrigger` is the one entry point where the tool is allowed and only some
of its actions are not, so its read actions are asserted to pass as explicitly
as its writes are asserted to fail: a guard that quietly widened to the whole
tool would take away the only way to answer a question about an existing
routine, and nothing else here would notice.

The last check is not about behaviour at all: it reads the tool names out of
the hook's own outer `case` and out of the `PreToolUse` matcher that registers
it, and asserts the two sets are equal. Feeding the hook directly — which every
other check here does — cannot see a hook the matcher never selects.

    python3 agents/common/tests/block-claude-crons.test.py
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# (what it is, tool name, tool_input dict or None, must it be denied)
CASES = [
    ("CronCreate — заводит сессионную задачу", "CronCreate", None, True),
    ("CronList — читает сессионные задачи", "CronList", None, True),
    ("CronDelete — снимает сессионную задачу", "CronDelete", None, True),
    ("ScheduleWakeup — повтор внутри сессии под своим именем", "ScheduleWakeup", None, True),
    ("RemoteTrigger create — заводит routine на claude.ai", "RemoteTrigger", {"action": "create"}, True),
    ("RemoteTrigger update — меняет её расписание", "RemoteTrigger", {"action": "update"}, True),
    ("RemoteTrigger run — тратит бюджет вне этого рантайма", "RemoteTrigger", {"action": "run"}, True),
    ("RemoteTrigger create_webhook_trigger — вешает источник событий", "RemoteTrigger", {"action": "create_webhook_trigger"}, True),
    ("RemoteTrigger list — чтение существующих routine", "RemoteTrigger", {"action": "list"}, False),
    ("RemoteTrigger get — чтение одной routine", "RemoteTrigger", {"action": "get"}, False),
    ("RemoteTrigger list_runs — чтение её запусков", "RemoteTrigger", {"action": "list_runs"}, False),
    ("RemoteTrigger get_run_log — чтение лога запуска", "RemoteTrigger", {"action": "get_run_log"}, False),
    ("RemoteTrigger без действия", "RemoteTrigger", None, False),
    ("Skill(schedule) — внешний планировщик claude.ai", "Skill", {"skill": "schedule"}, True),
    ("Skill(loop) — повтор промпта внутри сессии", "Skill", {"skill": "loop"}, True),
    ("Skill(wt) — обычный скилл воркспейса", "Skill", {"skill": "wt"}, False),
    ("Skill без аргумента", "Skill", None, False),
    ("Bash — не планировщик", "Bash", None, False),
    ("Read — не планировщик", "Read", None, False),
]


# <root>/agents/common/tests/block-claude-crons.test.py — root is fixed by this
# file's own location, whether root is the source tree or a built runtime tree.
def find_root() -> Path:
    return Path(__file__).resolve().parents[3]


def find_settings(root: Path) -> Path:
    """Where the `PreToolUse` registration lives — same two layouts as the hook."""
    for candidate in (root / "agents/claude/settings.base.json", root / ".claude/settings.json"):
        if candidate.is_file():
            return candidate
    sys.exit("settings not found in agents/claude or .claude")


def hook_tools(hook: Path) -> set[str]:
    """Tool names the hook's outer `case` answers for.

    Read out of the script rather than hard-coded here: a list repeated in the
    test is one more copy to forget, which is the shape of the bug this pair of
    assertions exists to catch. Nested `case` blocks are skipped by depth —
    their labels are argument values (`schedule`, `run`), not tool names.
    """
    arm = hook.read_text().split('case "$tool" in', 1)[1]
    names: set[str] = set()
    depth = 1
    for line in arm.splitlines():
        stripped = line.strip()
        if stripped == "esac":
            depth -= 1
            if depth == 0:
                break
            continue
        if re.match(r"^case .* in$", stripped):
            depth += 1
            continue
        if depth != 1 or stripped.startswith("#") or not stripped.endswith(")"):
            continue
        parts = [part.strip() for part in stripped[:-1].split("|")]
        if parts and all(part.isidentifier() for part in parts):
            names.update(parts)
    return names


def matcher_tools(settings: Path) -> set[str]:
    """Tool names the hook is actually registered for."""
    data = json.loads(settings.read_text())
    for entry in data.get("hooks", {}).get("PreToolUse", []):
        commands = json.dumps(entry.get("hooks", []))
        if "block-claude-crons.sh" in commands:
            return set(entry.get("matcher", "").split("|"))
    sys.exit("block-claude-crons.sh is not registered on PreToolUse")


def find_hook(root: Path) -> Path:
    for candidate in (root / ".claude/hooks", root / "agents/common/hooks"):
        hook = candidate / "block-claude-crons.sh"
        if hook.is_file():
            return hook
    sys.exit("block-claude-crons.sh not found in .claude/hooks or agents/common/hooks")


def shapes(tool: str, tool_input: dict | None) -> dict[str, dict]:
    claude: dict[str, object] = {"tool_name": tool}
    codex: dict[str, object] = {"toolName": tool}
    if tool_input is not None:
        claude["tool_input"] = dict(tool_input)
        codex["toolInput"] = dict(tool_input)
    return {"claude snake": claude, "codex camel": codex}


def denied(hook: Path, payload: dict) -> bool | str:
    r = subprocess.run(
        [str(hook)], input=json.dumps(payload), capture_output=True, text=True, env=dict(os.environ)
    )
    if r.returncode != 0:
        return f"exit={r.returncode}"
    if not r.stdout.strip():
        return False
    try:
        return json.loads(r.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
    except (ValueError, KeyError) as exc:
        return f"unreadable decision: {exc}"


def main() -> int:
    if not shutil.which("jq"):
        print("  SKIPPED: jq not installed — the hook needs it to read its input")
        return 0
    hook = find_hook(find_root())

    failures = 0
    checks = 0
    for what, tool, tool_input, want in CASES:
        bad = []
        for shape, payload in shapes(tool, tool_input).items():
            checks += 1
            got = denied(hook, payload)
            if got is not want:
                bad.append(f"{shape}: want denied={want}, got {got!r}")
        if bad:
            failures += 1
            print(f"  FAIL {what}")
            for line in bad:
                print(f"       {line}")

    # A denial that does not say what to use instead teaches nothing, and the
    # next session repeats the attempt.
    checks += 1
    r = subprocess.run(
        [str(hook)],
        input=json.dumps({"tool_name": "CronCreate"}),
        capture_output=True,
        text=True,
        env=dict(os.environ),
    )
    reason = json.loads(r.stdout)["hookSpecificOutput"]["permissionDecisionReason"]
    if "Cron Job" not in reason or "AGENTS.md" not in reason:
        failures += 1
        print("  FAIL отказ не называет замену и источник правила")
        print(f"       {reason}")

    # THE CHECK THAT WOULD HAVE CAUGHT THIS HOOK'S OWN BUG. Every case above
    # feeds the hook directly, so all of them stay green while the hook is
    # registered for fewer tools than it answers for — and a hook the matcher
    # never selects denies nothing while reporting itself as installed. There
    # is no denial to miss, which is why the drift survived a complete-looking
    # test, a complete-looking decision record and a complete-looking hook.
    checks += 1
    in_hook = hook_tools(hook)
    in_matcher = matcher_tools(find_settings(find_root()))
    if in_hook != in_matcher:
        failures += 1
        print("  FAIL матчер и ветки хука разошлись")
        for name in sorted(in_hook - in_matcher):
            print(f"       {name}: ветка есть, в matcher нет — хук для него не запустится")
        for name in sorted(in_matcher - in_hook):
            print(f"       {name}: в matcher есть, ветки нет — хук запустится и пропустит")

    if failures:
        print(f"block-claude-crons: {failures} failed of {checks} checks")
        return 1
    print(f"block-claude-crons: {checks} checks pass")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
