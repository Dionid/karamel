#!/usr/bin/env python3
"""Behaviour tests for ``./ops check`` outside and inside the workspace root.

Outside the root (a linked worktree, anything under worktrees/) check must build
the runtime trees into a temporary directory and leave the checkout byte-for-byte
untouched, while still failing on sources that do not build. In the root it must
keep verifying the generated trees in place, so a tampered file is still drift.

    python3 agents/common/tests/ops-check-scratch.test.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SRC = Path(__file__).resolve().parents[3]
FAILS: list[str] = []
RUNTIME = (".claude", ".agents", ".codex", "harness.json")


def check(ok: bool, what: str, detail: str = "") -> None:
    if not ok:
        FAILS.append(what)
        print(f"FAIL: {what}")
        if detail:
            print(detail)


def seed(root: Path) -> Path:
    root.mkdir(parents=True)
    shutil.copytree(SRC / "agents", root / "agents", symlinks=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for name in ("ops", "workspace.json"):
        shutil.copy2(SRC / name, root / name)
    return root


def snapshot(root: Path) -> dict[str, tuple]:
    state: dict[str, tuple] = {}
    for directory, dirs, files in os.walk(root):
        for name in dirs + files:
            path = Path(directory) / name
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                state[rel] = ("link", os.readlink(path))
            elif path.is_dir():
                state[rel] = ("dir",)
            else:
                state[rel] = ("file", path.read_bytes(), path.stat().st_mode)
    return state


def ops(root: Path, *args: str, tmp: Path) -> subprocess.CompletedProcess[str]:
    # A private TMPDIR makes a leaked scratch directory visible: it must be empty afterwards.
    env = {k: v for k, v in os.environ.items() if not k.endswith("_DEFAULT_MODEL") and not k.endswith("_DEFAULT_EFFORT")}
    env["TMPDIR"] = str(tmp)
    return subprocess.run([str(root / "ops"), *args], cwd=root, env=env, capture_output=True, text=True)


def scratch_case(checkout: Path, tmp: Path, label: str) -> None:
    before = snapshot(checkout)
    result = ops(checkout, "check", tmp=tmp)
    output = result.stdout + result.stderr
    check(result.returncode == 0, f"{label}: ./ops check exits 0 without generated trees", output)
    check("temporary directory" in result.stdout, f"{label}: check reports the scratch mode", output)
    check(snapshot(checkout) == before, f"{label}: checkout is byte-for-byte untouched")
    check(not any((checkout / name).exists() for name in RUNTIME), f"{label}: no runtime tree created")
    check(not any(tmp.iterdir()), f"{label}: the temporary build directory is removed", repr(list(tmp.iterdir())))


def broken_case(checkout: Path, tmp: Path, label: str, path: str, transform) -> None:
    target = checkout / path
    original = target.read_text()
    target.write_text(transform(original))
    try:
        before = snapshot(checkout)
        result = ops(checkout, "check", tmp=tmp)
        output = result.stdout + result.stderr
        check(result.returncode == 2, f"{label}: ./ops check fails with exit 2", f"rc={result.returncode}\n{output}")
        check("sources do not build" in result.stderr, f"{label}: failure names the cause", output)
        check("Traceback" not in output, f"{label}: failure is a message, not a traceback", output)
        check(snapshot(checkout) == before, f"{label}: failing check leaves the checkout untouched")
        check(not any(tmp.iterdir()), f"{label}: the temporary build directory is removed on failure")
    finally:
        target.write_text(original)


def dangling_case(checkout: Path, tmp: Path, path: str) -> None:
    # A missing link source still syncs (the link is written, its target named
    # correctly) and passes drift; only the resolution check sees it.
    target = checkout / path
    held = target.with_name(target.name + ".held")
    target.rename(held)
    try:
        before = snapshot(checkout)
        result = ops(checkout, "check", tmp=tmp)
        output = result.stdout + result.stderr
        check(result.returncode == 1, "missing link source: ./ops check fails with exit 1",
              f"rc={result.returncode}\n{output}")
        check(f"dangling:.claude/{target.name}" in result.stderr,
              "missing link source: reported as a dangling link", output)
        check(snapshot(checkout) == before, "missing link source: checkout untouched")
        check(not any(tmp.iterdir()), "missing link source: the temporary build directory is removed")
    finally:
        held.rename(target)


# Runs build.py's main() in a child process with one setup step broken, the way
# an unwritable temporary area or a filesystem without symlinks breaks it. A
# bad TMPDIR alone cannot do it: Python falls back to /tmp, /var/tmp and the cwd.
SETUP_FAILURE = r"""
import errno, importlib.util, os, sys, tempfile
from pathlib import Path
build_py, root, broken = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("runtime_build", build_py)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
def refuse(*args, **kwargs):
    raise PermissionError(errno.EACCES, "refused by test", broken)
if broken == "tempdir":
    build.tempfile.TemporaryDirectory = refuse
else:
    build.Path.symlink_to = refuse
sys.argv = ["build.py", "check", "--root", root]
sys.exit(build.main())
"""


def setup_failure_case(checkout: Path, tmp: Path, broken: str) -> None:
    label = f"scratch setup fails ({broken})"
    before = snapshot(checkout)
    env = dict(os.environ, TMPDIR=str(tmp))
    result = subprocess.run([sys.executable, "-c", SETUP_FAILURE, str(checkout / "agents/build.py"),
                             str(checkout), broken], env=env, capture_output=True, text=True)
    output = result.stdout + result.stderr
    check(result.returncode == 3, f"{label}: exits 3", f"rc={result.returncode}\n{output}")
    check("could not prepare a temporary directory" in result.stderr, f"{label}: names the cause", output)
    check("sources do not build" not in output, f"{label}: not blamed on the sources", output)
    check("Traceback" not in output, f"{label}: a message, not a traceback", output)
    check(snapshot(checkout) == before, f"{label}: checkout untouched")
    check(not any(tmp.iterdir()), f"{label}: no temporary directory left", repr(list(tmp.iterdir())))


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ops-check-scratch-test-") as raw:
        base = Path(raw).resolve()
        tmp = base / "tmpdir"
        tmp.mkdir()

        # (a) a checkout under worktrees/<task>/ and a linked git worktree (.git is a file)
        worktree = seed(base / "ws/worktrees/task/agent-workspace")
        scratch_case(worktree, tmp, "under worktrees/")
        linked = seed(base / "linked")
        (linked / ".git").write_text("gitdir: /nonexistent/.git/worktrees/linked\n")
        scratch_case(linked, tmp, "linked worktree")
        # a clean clone in packages/ is a main checkout (.git is a directory) and still not the root
        package = seed(base / "ws/packages/agent-workspace")
        (package / ".git").mkdir()
        scratch_case(package, tmp, "clone in packages/")

        # a link whose source is missing builds, but must not pass the check
        dangling_case(worktree, tmp, "agents/claude/file-suggestion.sh")

        # the post-sync drift is load-bearing: a role named like a generated profile
        # makes a link and a file share one path, the later write wins, drift sees it
        twin = worktree / "agents/common/roles/explorer--high--terminal.md"
        shutil.copy2(worktree / "agents/common/roles/explorer.md", twin)
        catalog_path = worktree / "agents/common/routing/catalog.json"
        catalog_before = catalog_path.read_text()
        catalog = json.loads(catalog_before)  # every role needs a minimum, the twin included
        catalog["roleMinimums"][twin.stem] = catalog["roleMinimums"]["explorer"]
        catalog_path.write_text(json.dumps(catalog))
        try:
            collided = ops(worktree, "check", tmp=tmp)
            check(collided.returncode == 1
                  and "link:.claude/agents/explorer--high--terminal.md" in collided.stderr,
                  "link/file collision: scratch check reports drift", collided.stdout + collided.stderr)
        finally:
            twin.unlink()
            catalog_path.write_text(catalog_before)

        # the environment, not the sources: setup failures get their own exit code
        setup_failure_case(worktree, tmp, "tempdir")
        setup_failure_case(worktree, tmp, "symlink")

        # (b) sources that do not build still fail the scratch check
        broken_case(worktree, tmp, "role without tools", "agents/common/roles/explorer.md",
                    lambda text: "\n".join(line for line in text.splitlines() if not line.startswith("tools:")) + "\n")
        broken_case(worktree, tmp, "malformed settings", "agents/claude/settings.json",
                    lambda text: text + "{")
        broken_case(worktree, tmp, "malformed routing catalog", "agents/common/routing/catalog.json",
                    lambda text: json.dumps({**json.loads(text), "tiers": ["fast"]}))

        # (c) the workspace root keeps checking its real trees in place
        root = seed(base / "root")
        missing = ops(root, "check", tmp=tmp)
        check(missing.returncode == 1 and "link:.claude/skills/" in missing.stderr,
              "root without trees: in-place check reports drift", missing.stdout + missing.stderr)
        check(not any((root / name).exists() for name in RUNTIME), "root: check alone creates nothing")
        synced = ops(root, "sync", tmp=tmp)
        check(synced.returncode == 0, "root: ./ops sync succeeds", synced.stdout + synced.stderr)
        clean = ops(root, "check", tmp=tmp)
        check(clean.returncode == 0 and "runtime trees match" in clean.stdout,
              "root after sync: in-place check is clean", clean.stdout + clean.stderr)

        settings = root / ".claude/settings.json"
        settings.write_text(settings.read_text() + " ")
        tampered = ops(root, "check", tmp=tmp)
        check(tampered.returncode == 1 and "file:.claude/settings.json" in tampered.stderr,
              "root: tampered generated file is drift", tampered.stdout + tampered.stderr)
        forced = ops(root, "check", "--scratch", tmp=tmp)
        check(forced.returncode == 0 and "temporary directory" in forced.stdout
              and "not checked" in forced.stderr,
              "root: --scratch ignores the tree in place and says so", forced.stdout + forced.stderr)
        ops(root, "sync", tmp=tmp)

        skill = next(path for path in sorted((root / ".claude/skills").iterdir()))
        skill.unlink()
        skill.symlink_to("../../agents/common/skills/lint")
        retargeted = ops(root, "check", tmp=tmp)
        check(retargeted.returncode == 1 and f"target:.claude/skills/{skill.name}" in retargeted.stderr,
              "root: retargeted generated link is drift", retargeted.stdout + retargeted.stderr)
        ops(root, "sync", tmp=tmp)

        forced_in_place = ops(worktree, "check", "--in-place", tmp=tmp)
        check(forced_in_place.returncode == 1, "worktree: --in-place still checks the (absent) trees there",
              forced_in_place.stdout + forced_in_place.stderr)

        # A scratch build writes the same bytes and link targets an in-place sync writes.
        spec = importlib.util.spec_from_file_location("runtime_build", root / "agents/build.py")
        build = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(build)
        output = base / "scratch-output"
        output.mkdir()
        scratch = build.Builder(root, output)
        scratch.sync()
        in_place = build.Builder(root)
        for path in in_place.links():
            twin = output / path.relative_to(root)
            check(os.readlink(twin) == os.readlink(path), f"scratch link target equals in-place: {twin.name}",
                  f"{os.readlink(twin)} != {os.readlink(path)}")
        for path in in_place.files():
            twin = output / path.relative_to(root)
            check(twin.read_bytes() == path.read_bytes(), f"scratch file equals in-place: {path.relative_to(root)}")
        check(not any(tmp.iterdir()), "no scratch directory leaked across the whole run")

    if FAILS:
        print(f"{len(FAILS)} failure(s)")
        return 1
    print("ops check scratch/in-place: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
