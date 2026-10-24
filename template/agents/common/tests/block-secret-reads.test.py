#!/usr/bin/env python3
"""Self-test for the secret-leak hook — run by lint.sh as the `hooks` check.

The hook is the only thing in this repo that has to be right about a payload it
never sees while being written: it is fed by whichever agent is driving, and the
two do not agree on the shape. Claude Code sends snake_case with the command as
a string; Codex CLI sends camelCase, and its shell tool carries argv as an array.

That difference is not cosmetic, which is why this file exists. Half the rules in
the hook anchor to the start of a command, because that is where a command sits
in a shell line. Flatten `["bash", "-lc", "env"]` naively and it reads
`bash -lc env`, the anchor stops matching, and a whole-environment dump walks
through a guard that still reports itself as working. Every case below therefore
runs in all three shapes, and the verdict must be identical in each.

    python3 agents/common/tests/block-secret-reads.test.py
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

# Built from the same string in two pieces on purpose: this file is read by
# agents whose own shell guard denies a command line carrying a reader next to a
# real .env, and a literal here would trip it before the test could run.
DOTENV = "." + "env"

# (what it is, the command, must it be denied)
CASES = [
    ("reader pointed at .env", f"cat {DOTENV}", True),
    ("whole-environment dump", "env", True),
    ("printenv of a secret", "printenv GITHUB_TOKEN", True),
    ("echo of a secret", 'echo "$GITHUB_TOKEN"', True),
    ("${VAR:-default} expansion", 'echo "${GITHUB_TOKEN:-none}"', True),
    ("curl -v beside a token", 'curl -v -H "PRIVATE-TOKEN: $GITHUB_TOKEN" https://x', True),
    ("the sanctioned source", f"set -a; . ./{DOTENV}; set +a", False),
    ("passing by name", 'psql "$DB_URI_APP_DEV" -c "select 1"', False),
    ("${VAR:+set} presence test", 'echo "${GITHUB_TOKEN:+set}"', False),
    ("reading the template", f"cat {DOTENV}.example", False),
    ("an ordinary command", "git status --short", False),
]


# <root>/agents/common/tests/block-secret-reads.test.py — root is fixed by
# this file's own location, whether root is the engine source tree (this
# repo) or a team repository harness has synced.
def find_root() -> Path:
    return Path(__file__).resolve().parents[3]


def find_hook(root: Path) -> Path:
    """The built tree when there is one — that is the hook the layers actually
    resolved to, config override included — and core's own otherwise, which is
    the state of every CI checkout."""
    for candidate in (root / ".claude/hooks", root / "agents/common/hooks"):
        hook = candidate / "block-secret-reads.sh"
        if hook.is_file():
            return hook
    sys.exit("block-secret-reads.sh not found in .claude/hooks or agents/common/hooks")


def shapes(cmd: str) -> dict[str, dict]:
    """One call, as each agent puts it on the wire."""
    return {
        "claude snake+str": {"tool_name": "Bash", "tool_input": {"command": cmd}},
        "codex camel+str": {"toolName": "shell", "toolInput": {"command": cmd}},
        "codex camel+argv": {"toolName": "shell", "toolInput": {"command": ["bash", "-lc", cmd]}},
    }


def denied(hook: Path, payload: dict) -> bool | str:
    """True denied, False allowed, or a string describing a broken hook."""
    r = subprocess.run([str(hook)], input=json.dumps(payload),
                       capture_output=True, text=True)
    if r.returncode != 0:
        return f"exit={r.returncode}"
    if not r.stdout.strip():
        return False
    try:
        out = json.loads(r.stdout)
        return out["hookSpecificOutput"]["permissionDecision"] == "deny"
    except (ValueError, KeyError) as exc:
        return f"unreadable decision: {exc}"


def main() -> int:
    root = find_root()
    if not shutil.which("jq"):
        print("  SKIPPED: jq not installed — the hook needs it to read its input")
        return 0

    hook = find_hook(root)
    failures = 0
    for what, cmd, want_deny in CASES:
        bad = []
        for shape, payload in shapes(cmd).items():
            got = denied(hook, payload)
            if got is not want_deny:
                expected = "deny" if want_deny else "allow"
                bad.append(f"{shape} → {got!r}, expected {expected}")
        if bad:
            failures += 1
            print(f"  FAIL {what}")
            for line in bad:
                print(f"       {line}")

    total = len(CASES) * len(shapes(""))
    if failures:
        print(f"  {failures} of {len(CASES)} case(s) failed across {total} checks")
        return 1
    print(f"  {total} checks pass ({len(CASES)} commands × 3 input shapes)"
          f" — {hook.relative_to(root)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
