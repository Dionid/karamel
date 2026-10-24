#!/usr/bin/env python3
"""Self-test for the workspace-deletion guard — run by lint.sh as part of `hooks`.

Two things have to hold at once, and a guard that gets either one wrong is worse
than no guard at all:

  * the workspace root and the shared root above it survive every spelling of
    "delete this" — the flag orders `permissions.deny` misses (`rm -r -f`), the
    forms that never name the path (`rm -rf ..`, `rm -rf /shared/*`), and the
    deletions that are not `rm` (`mv`, `find -delete`, `rsync --delete`);
  * everything INSIDE the workspace stays deletable. Cleaning a worktree, a
    node_modules or a scratch file is ordinary work, and a guard that blocks it
    gets switched off within a week — which protects nothing.

Every case runs in all three payload shapes both agents send, and the verdict has
to be identical in each: Claude Code sends snake_case with the command as a
string, Codex CLI sends camelCase and its shell tool carries argv as an array.
The argv shape is not cosmetic here — it reaches the hook both joined
(`bash -lc rm -rf /x`) and unwrapped, so a rule that reads the joined line as a
command of its own turns `bash -lc grep -r "rm -rf" <root>` into a denied
deletion. That case is in the table below for exactly that reason.

    python3 agents/common/tests/block-workspace-deletion.test.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# {root}   the workspace itself   — <shared>/team-repo
# {shared} the shared root above it — a tree several sessions can share
# {cwd}    where the command is run from, default {root}
#
# (what it is, command, cwd, must it be denied)
CASES = [
    # ── the root itself, in the spellings a glob list cannot enumerate ──────
    ("rm -rf on the workspace", "rm -rf {root}", "{root}", True),
    ("split flags, which permissions.deny misses", "rm -r -f {root}", "{root}", True),
    ("uppercase -R", "rm -fR {root}", "{root}", True),
    ("long flags", "rm --recursive --force {root}", "{root}", True),
    ("the shared root above it", "rm -rf {shared}", "{root}", True),
    ("an ancestor of both, reached relatively", "rm -rf {shared}/..", "{root}", True),
    ("the filesystem root", "rm -rf /", "{root}", True),
    ("quoted", 'rm -rf "{root}"', "{root}", True),
    ("trailing slash", "rm -rf {root}/", "{root}", True),
    ("relative dot-dot", "rm -rf ..", "{root}", True),
    ("relative dot", "rm -rf .", "{root}", True),
    ("a bare glob in the root", "rm -rf *", "{root}", True),
    ("a glob over the shared root", "rm -rf {shared}/*", "{root}", True),
    ("cd first, then a relative rm", "cd {shared} && rm -rf team-repo", "{root}", True),
    ("sudo in front", "sudo rm -rf {root}", "{root}", True),
    ("a shell wrapper", "bash -c rm -rf {root}", "{root}", True),
    # ── deletions that are not rm ────────────────────────────────────────────
    ("moving the root away", "mv {root} /tmp/parked", "{root}", True),
    ("a deleting find", "find {root} -delete", "{root}", True),
    ("find -exec rm whose filter matches the root", "find {shared} -name team-repo -exec rm -rf {{}} +", "{root}", True),
    ("find -regex, which this guard will not evaluate", "find {root} -regex '.*' -delete", "{root}", True),
    ("rsync --delete into the root", "rsync -a --delete /tmp/empty/ {root}/", "{root}", True),
    ("a subshell, which keeps the session's cwd", "(cd {shared} && rm -rf team-repo)", "{root}", True),
    ("a brace group", "{{ rm -rf {root}; }}", "{root}", True),
    ("env with flags of its own", "env -i rm -rf {root}", "{root}", True),
    ("piped into a deleting xargs", "ls -d {shared} | xargs rm -rf", "{root}", True),
    ("xargs -0 off a find", "find {shared} -maxdepth 0 -print0 | xargs -0 rm -rf", "{root}", True),
    ("a docker bind mount of the shared root", "docker run --rm -v {shared}:/w alpine rm -rf /w", "{root}", True),
    ("ssh back into the box", "ssh host 'rm -rf {root}'", "{root}", True),
    ("gio trash", "gio trash {root}", "{root}", True),
    ("a partial pattern that matches the root", "rm -rf {shared}/team-r*", "{root}", True),
    # ── everything inside stays deletable ────────────────────────────────────
    ("a task worktree", "rm -rf {root}/worktrees/some-task", "{root}", False),
    ("a package checkout", "rm -rf {root}/packages/backend", "{root}", False),
    ("node_modules, relative", "rm -rf node_modules", "{root}", False),
    ("a scratch path outside", "rm -rf /tmp/scratch-xyz", "{root}", False),
    ("a glob one level down", "rm -rf {root}/worktrees/*", "{root}", False),
    ("a bare glob deeper in", "rm -rf *", "{root}/packages/backend", False),
    ("cd deeper, then rm", "cd {root}/packages && rm -rf backend", "{root}", False),
    ("a scoped deleting find", "find {root}/worktrees -name '*.log' -delete", "{root}", False),
    ("a read-only find at the root", "find {root} -name harness.json", "{root}", False),
    ("a filtered deleting find at the root", "find {root} -name '*.orig' -delete", "{root}", False),
    ("a filtered -exec rm at the root", "find {root} -name __pycache__ -exec rm -rf {{}} +", "{root}", False),
    ("a partial pattern that cannot match the root", "rm -f *.log", "{root}", False),
    ("a prefix pattern one level down", "rm -rf {root}/worktrees*", "{root}", False),
    ("gio trash on a worktree", "gio trash {root}/worktrees/some-task", "{root}", False),
    ("an xargs that deletes nothing", 'rg -l "rm -rf" {root} | xargs wc -l', "{root}", False),
    ("a docker mount of a subtree", "docker run --rm -v {root}/packages:/w alpine rm -rf /w/x", "{root}", False),
    ("a subshell deleting inside", "(cd {root}/packages && rm -rf backend)", "{root}", False),
    ("rsync without --delete", "rsync -a /tmp/x/ {root}/sub/", "{root}", False),
    ("moving a file into the root", "mv /tmp/x {root}/", "{root}", False),
    ("moving inside the root", "mv {root}/a {root}/b", "{root}", False),
    ("grepping for the string", 'grep -r "rm -rf" {root}', "{root}", False),
    ("an ordinary command", "git status --short", "{root}", False),
    ("listing the shared root", "ls -la {shared}", "{root}", False),
]


# <root>/agents/common/tests/block-workspace-deletion.test.py — root is fixed
# by this file's own location, whether root is the engine source tree (this
# repo) or a team repository harness has synced.
def find_root() -> Path:
    return Path(__file__).resolve().parents[3]


def find_hook(root: Path) -> Path:
    """The built tree when there is one — that is the hook the layers actually
    resolved to, config override included — and core's own otherwise, which is
    the state of every CI checkout."""
    for candidate in (root / ".claude/hooks", root / "agents/common/hooks"):
        hook = candidate / "block-workspace-deletion.sh"
        if hook.is_file():
            return hook
    sys.exit("block-workspace-deletion.sh not found in .claude/hooks or agents/common/hooks")


def shapes(cmd: str, cwd: str) -> dict[str, dict]:
    """One call, as each agent puts it on the wire."""
    return {
        "claude snake+str": {"tool_name": "Bash", "cwd": cwd, "tool_input": {"command": cmd}},
        "codex camel+str": {"toolName": "shell", "cwd": cwd, "toolInput": {"command": cmd}},
        "codex camel+argv": {
            "toolName": "shell",
            "cwd": cwd,
            "toolInput": {"command": ["bash", "-lc", cmd]},
        },
    }


def clean_env() -> dict:
    """The hook reads WORKSPACE/CLAUDE_PROJECT_DIR when they are set. The
    fixture decides what is protected, so they are dropped — otherwise the
    verdicts would depend on whose machine the test runs on."""
    env = dict(os.environ)
    for k in ("WORKSPACE", "CLAUDE_PROJECT_DIR"):
        env.pop(k, None)
    return env


def denied(hook: Path, payload: dict) -> bool | str:
    """True denied, False allowed, or a string describing a broken hook."""
    r = subprocess.run([str(hook)], input=json.dumps(payload),
                       capture_output=True, text=True, env=clean_env())
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
    find_root()
    if not shutil.which("jq"):
        print("  SKIPPED: jq not installed — the hook needs it to read its input")
        return 0

    hook = find_hook(find_root())
    failures = 0

    # A throwaway workspace rather than the real one: the hook decides what to
    # protect by walking up to harness.json, so the fixture has to be a real
    # directory layout — and no case may resolve to a path anybody works in.
    with tempfile.TemporaryDirectory() as tmp:
        shared = Path(tmp) / "shared"
        root = shared / "team-repo"
        (root / "worktrees").mkdir(parents=True)
        (root / "packages/backend").mkdir(parents=True)
        (root / "harness.json").write_text("{}\n")

        def fill(s: str) -> str:
            return s.format(root=root, shared=shared).replace("{{}}", "{}")

        for what, cmd, cwd, want_deny in CASES:
            cmd, cwd = fill(cmd), fill(cwd)
            bad = []
            for shape, payload in shapes(cmd, cwd).items():
                got = denied(hook, payload)
                if got is not want_deny:
                    expected = "deny" if want_deny else "allow"
                    bad.append(f"{shape} → {got!r}, expected {expected}")
            if bad:
                failures += 1
                print(f"  FAIL {what}: {cmd}")
                for line in bad:
                    print(f"       {line}")

        # No harness.json anywhere above: the guard cannot know what to protect,
        # and says so on stderr instead of denying or pretending to work.
        outside = subprocess.run(
            [str(hook)], cwd=tmp,
            input=json.dumps({"tool_name": "Bash", "cwd": tmp,
                              "tool_input": {"command": "rm -rf /tmp/whatever"}}),
            capture_output=True, text=True, env=clean_env(),
        )
        if outside.returncode != 0 or outside.stdout.strip() or "NOT guarded" not in outside.stderr:
            failures += 1
            print("  FAIL no workspace above cwd: must fail open and say so on stderr")
            print(f"       exit={outside.returncode} stdout={outside.stdout!r} stderr={outside.stderr!r}")

    total = len(CASES) + 1
    if failures:
        print(f"  {failures} of {total} case(s) failed")
        return 1
    print(f"  {total} deletion case(s) checked in 3 payload shapes each")
    return 0


if __name__ == "__main__":
    sys.exit(main())
