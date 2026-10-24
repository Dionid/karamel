#!/usr/bin/env python3
"""Self-test for the deny-list hook — run by lint.sh as a behaviour test.

The hook exists because Codex has no `permissions.deny` of its own. So the
rules had to move next to block-secret-reads.sh.

What this file is really guarding is the same trap that file documents: the two
agents disagree about the payload shape. Claude Code sends snake_case with the
command as a string; Codex sends camelCase and its shell tools carry argv as an
array. A hook that reads only the Claude Code snake_case shape sees an empty
command under Codex, denies nothing, and reports itself as installed and
working — which is worse than not being installed at all. Every case therefore
runs in all three shapes and must reach the same verdict.

    python3 agents/common/tests/enforce-deny-rules.test.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Same split-literal trick as the secret hook's test: this file is read by
# agents whose own guard denies a line carrying a reader next to a real .env.
DOTENV = "." + "env"

SETTINGS = {
    "permissions": {
        "deny": [
            "Bash(kubectl apply*)",
            "Bash(git push --force*)",
            "Read(**/" + DOTENV + ")",
            "Edit(/packages/**)",
        ]
    }
}

# (what it is, tool kind, command-or-path, must it be denied)
SHELL_CASES = [
    ("denied by a Bash rule", "kubectl apply -f x.yaml", True),
    ("denied mid-chain, not just at the start", "ls && kubectl apply -f x.yaml", True),
    ("force-push", "git push --force origin main", True),
    ("writing into .claude/", "sed -i s/a/b/ .claude/settings.json", True),
    ("an ordinary read", "git status --short", False),
    ("a near-miss that must pass", "kubectl get pods -n prod", False),
    ("reading .claude is fine", "cat .claude/settings.json", False),
]

PATH_CASES = [
    ("Edit under packages/", "write", "packages/api/src/x.ts", True),
    ("writing into .claude/", "write", ".claude/settings.json", True),
    ("Edit outside packages/", "write", "worktrees/t/api/src/x.ts", False),
    ("reading .env", "read", DOTENV, True),
    ("reading the template", "read", DOTENV + ".example", False),
]


# <root>/agents/common/tests/enforce-deny-rules.test.py — root is fixed by
# this file's own location, whether root is the engine source tree (this
# repo) or a team repository harness has synced.
def find_root() -> Path:
    return Path(__file__).resolve().parents[3]


def find_hook(root: Path) -> Path:
    for candidate in (root / ".claude/hooks", root / "agents/common/hooks"):
        hook = candidate / "enforce-deny-rules.sh"
        if hook.is_file():
            return hook
    sys.exit("enforce-deny-rules.sh not found in .claude/hooks or agents/common/hooks")


def shell_shapes(cmd: str, cwd: str) -> dict[str, dict]:
    return {
        "claude snake+str": {"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd},
        "codex camel+str": {"toolName": "shell", "toolInput": {"command": cmd}, "cwd": cwd},
        "codex camel+argv": {"toolName": "shell",
                             "toolInput": {"command": ["bash", "-lc", cmd]}, "cwd": cwd},
    }


def path_shapes(kind: str, path: str, cwd: str) -> dict[str, dict]:
    claude_tool = "Read" if kind == "read" else "Edit"
    codex_tool = "read_file" if kind == "read" else "apply_patch"
    return {
        "claude snake": {"tool_name": claude_tool, "tool_input": {"path": path}, "cwd": cwd},
        "codex camel": {"toolName": codex_tool, "toolInput": {"path": path}, "cwd": cwd},
        "claude file_path": {"tool_name": claude_tool,
                             "tool_input": {"file_path": path}, "cwd": cwd},
    }


def denied(hook: Path, payload: dict, workspace: str) -> bool | str:
    env = dict(os.environ, WORKSPACE=workspace,
               WORKSPACE_DENY_SETTINGS=str(Path(workspace) / ".claude/settings.json"))
    r = subprocess.run([str(hook)], input=json.dumps(payload),
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        return f"exit={r.returncode}"
    if not r.stdout.strip():
        return False
    try:
        return json.loads(r.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
    except (ValueError, KeyError) as exc:
        return f"unreadable decision: {exc}"


def main() -> int:
    root = find_root()
    if not shutil.which("jq"):
        print("  SKIPPED: jq not installed — the hook needs it to read its input")
        return 0
    hook = find_hook(root)

    failures = 0
    checks = 0
    with tempfile.TemporaryDirectory() as tmp:
        ws = Path(tmp) / "workspace"
        (ws / ".claude").mkdir(parents=True)
        (ws / "harness.json").write_text("{}")
        (ws / ".claude/settings.json").write_text(json.dumps(SETTINGS))
        wss = str(ws)

        for what, cmd, want in SHELL_CASES:
            bad = []
            for shape, payload in shell_shapes(cmd, wss).items():
                checks += 1
                got = denied(hook, payload, wss)
                if got is not want:
                    bad.append(f"{shape} → {got!r}, expected {'deny' if want else 'allow'}")
            if bad:
                failures += 1
                print(f"  FAIL {what}")
                for line in bad:
                    print(f"       {line}")

        for what, kind, path, want in PATH_CASES:
            bad = []
            for shape, payload in path_shapes(kind, path, wss).items():
                checks += 1
                got = denied(hook, payload, wss)
                if got is not want:
                    bad.append(f"{shape} → {got!r}, expected {'deny' if want else 'allow'}")
            if bad:
                failures += 1
                print(f"  FAIL {what}")
                for line in bad:
                    print(f"       {line}")

    if failures:
        print(f"  {failures} case(s) failed across {checks} checks")
        return 1
    print(f"  {checks} checks pass — {hook.relative_to(root)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
