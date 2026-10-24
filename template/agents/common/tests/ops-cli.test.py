#!/usr/bin/env python3
"""Contract tests for the human-facing ``./ops`` entrypoint."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def find_root() -> Path:
    return Path(__file__).resolve().parents[3]


def stub(path: Path, name: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "#!/usr/bin/env bash\n"
        "printf '%s' '" + name + "' >> \"$OPS_TEST_LOG\"\n"
        "printf '|%s' \"$@\" >> \"$OPS_TEST_LOG\"\n"
        "printf '\\n' >> \"$OPS_TEST_LOG\"\n"
    )
    path.chmod(0o755)


def run(ops: Path, *args: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(ops), *args],
        cwd=ops.parent,
        env=env,
        capture_output=True,
        text=True,
    )


def main() -> int:
    source_root = find_root()
    source = source_root / "ops"
    package = json.loads((source_root / "package.json").read_text())
    if package.get("private") is not True or package.get("scripts", {}).get("ops") != "./ops":
        print("FAIL: package.json must expose the private 'ops' script")
        return 1

    with tempfile.TemporaryDirectory(prefix="workspace-ops-test-") as raw:
        root = Path(raw)
        ops = root / "ops"
        shutil.copy2(source, ops)
        (root / ".env.example").write_text("EXAMPLE=value\n")
        shutil.copy2(source_root / "package.json", root / "package.json")

        stub(root / "agents/build.py", "build")
        stub(root / "agents/common/skills/clone/clone.sh", "clone")
        stub(root / "agents/common/skills/wt/wt", "wt")
        stub(root / "agents/common/skills/wt/adopt.sh", "adopt")
        stub(root / "agents/common/skills/lint/lint.sh", "lint")

        log = root / "calls.log"
        env = {**os.environ, "OPS_TEST_LOG": str(log)}

        help_run = run(ops, "help", env=env)
        if help_run.returncode != 0 or "Agent workspace operator CLI" not in help_run.stdout:
            print("FAIL: ./ops help")
            print(help_run.stdout, help_run.stderr)
            return 1

        npm = shutil.which("npm")
        if npm is not None:
            npm_run = subprocess.run(
                [npm, "run", "--silent", "ops", "--", "help"],
                cwd=root,
                env=env,
                capture_output=True,
                text=True,
            )
            if npm_run.returncode != 0 or "Agent workspace operator CLI" not in npm_run.stdout:
                print("FAIL: npm run ops -- help")
                print(npm_run.stdout, npm_run.stderr)
                return 1

        wt_help = run(ops, "help", "wt", env=env)
        required = (
            "./ops wt new <task> --repo <repo> --pull",
            "./ops wt list",
            "./ops doctor --repo <repo>",
            "./ops pull --repo <repo>",
            "./ops adopt feature/<task> --repo <repo>",
            "./ops wt rm <task> --delete-branch",
        )
        missing = [line for line in required if line not in wt_help.stdout]
        if wt_help.returncode != 0 or missing:
            print(f"FAIL: ./ops help wt misses: {missing}")
            return 1

        calls = (
            (("setup",), "build|sync"),
            (("sync",), "build|sync"),
            (("update",), "build|sync"),
            (("status", "--json"), "build|status|--json"),
            (("clone", "api"), "clone|api"),
            (("doctor", "--repo", "api"), "wt|doctor|--repo|api"),
            (("wt", "list"), "wt|list"),
            (("pull",), "wt|pull|all"),
            (("pull", "--repo", "api"), "wt|pull|--repo|api"),
            (("adopt", "feature/x", "--repo", "api"), "adopt|feature/x|--repo|api"),
            (("lint", "strict", "--only", "syntax"), "lint|--strict|--only|syntax"),
        )
        for args, expected in calls:
            result = run(ops, *args, env=env)
            actual = log.read_text().splitlines()[-1] if log.exists() else ""
            if result.returncode != 0 or actual != expected:
                print(f"FAIL: ./ops {' '.join(args)} -> {actual!r}, expected {expected!r}")
                print(result.stdout, result.stderr)
                return 1

        if (root / ".env").read_text() != "EXAMPLE=value\n":
            print("FAIL: ./ops setup did not create .env from the template")
            return 1
        if (root / ".env").stat().st_mode & 0o777 != 0o600:
            print("FAIL: ./ops setup did not protect .env with mode 0600")
            return 1

        (root / ".env").write_text("PRESERVE=value\n")
        repeated_setup = run(ops, "setup", env=env)
        if repeated_setup.returncode != 0 or (root / ".env").read_text() != "PRESERVE=value\n":
            print("FAIL: ./ops setup replaced an existing .env")
            return 1

        completion = run(ops, "completion", "zsh", env=env)
        if (
            completion.returncode != 0
            or "_agent_workspace_ops()" not in completion.stdout
            or "compdef _agent_workspace_ops ops ./ops" not in completion.stdout
        ):
            print("FAIL: zsh completion")
            return 1

        unknown = run(ops, "not-a-command", env=env)
        if unknown.returncode != 2 or "unknown command" not in unknown.stderr:
            print("FAIL: unknown command must exit 2")
            return 1

        archived_cleanup = run(ops, "cleanup", "worktrees", env=env)
        if archived_cleanup.returncode != 2 or "unknown command" not in archived_cleanup.stderr:
            print("FAIL: archived cleanup command must not be dispatched")
            return 1

        (root / ".env").unlink()
        outside = root / "outside-env"
        (root / ".env").symlink_to(outside)
        symlink_setup = run(ops, "setup", env=env)
        if (
            symlink_setup.returncode != 2
            or "refusing to create .env through a symlink" not in symlink_setup.stderr
            or outside.exists()
        ):
            print("FAIL: ./ops setup followed a destination symlink")
            return 1

    print("ops command catalog and dispatch: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
