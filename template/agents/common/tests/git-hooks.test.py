#!/usr/bin/env python3
"""Behaviour tests for agents/git-hooks and the installer in ./ops.

The hooks run `./ops wt pull all` then `./ops sync` after `git pull` in the
workspace root checkout and nowhere else. Every case uses real git repositories in temp dirs and a stub
`ops` that logs its calls. Includes end-to-end real `git pull` / `--rebase`.

    python3 agents/common/tests/git-hooks.test.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SRC = Path(__file__).resolve().parents[3]
HOOKS = ("post-merge", "post-rewrite")
FAILS: list[str] = []


def check(ok: bool, what: str, detail: str = "") -> None:
    if not ok:
        FAILS.append(what)
        print(f"FAIL: {what}")
        if detail:
            print(detail)


def base_env(extra: dict[str, str] | None = None) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k not in ("WORKSPACE_NO_AUTO_SYNC", "WORKSPACE_NO_AUTO_WT_PULL")}
    env.update(
        GIT_CONFIG_GLOBAL="/dev/null",
        GIT_CONFIG_NOSYSTEM="1",
        GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.com",
        GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.com",
    )
    env.update(extra or {})
    return env


def git(cwd: Path, *args: str, env: dict[str, str] | None = None, check_rc: bool = True) -> subprocess.CompletedProcess[str]:
    r = subprocess.run(["git", *args], cwd=cwd, env=env or base_env(), capture_output=True, text=True)
    if check_rc and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {r.stderr}")
    return r


def init_repo(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    git(path, "init", "-q", "-b", "main")


def commit(path: Path, name: str, text: str = "x") -> None:
    (path / name).write_text(text)
    git(path, "add", name)
    git(path, "commit", "-q", "-m", name)


def stub_ops(path: Path, rc: int = 0, wt_rc: int = 0) -> None:
    path.write_text(
        "#!/usr/bin/env bash\n"
        'printf "%s\\n" "$*" >> "$(dirname "$0")/ops.calls"\n'
        'if [ "$1" = wt ]; then env | grep -E "^(GIT_CONFIG_(PARAMETERS|COUNT|KEY_|VALUE_)|GIT_ASKPASS|GIT_TERMINAL_PROMPT|GIT_REFLOG_ACTION)" >> "$(dirname "$0")/wt.env"; '
        f'exit {wt_rc}; fi\n'
        f"exit {rc}\n"
    )
    path.chmod(0o755)


def calls(root: Path) -> list[str]:
    f = root / "ops.calls"
    return f.read_text().splitlines() if f.exists() else []


def install_hooks_copy(root: Path, link: bool = True) -> None:
    dest = root / "agents/git-hooks"
    dest.mkdir(parents=True, exist_ok=True)
    for name in HOOKS:
        shutil.copy2(SRC / "agents/git-hooks" / name, dest / name)
    if link:
        (root / ".git/hooks").mkdir(exist_ok=True)
        for name in HOOKS:
            (root / ".git/hooks" / name).symlink_to(f"../../agents/git-hooks/{name}")


def run_hook(root: Path, name: str, *args: str, env: dict[str, str] | None = None, cwd: Path | None = None):
    return subprocess.run(
        [str(root / "agents/git-hooks" / name), *args],
        cwd=cwd or root, env=env or base_env(), input="", capture_output=True, text=True,
    )


def make_root(base: Path, name: str = "root", marker: bool = True, ops_rc: int = 0) -> Path:
    root = base / name
    init_repo(root)
    commit(root, "seed")
    install_hooks_copy(root)
    stub_ops(root / "ops", ops_rc)
    if marker:
        (root / "harness.json").write_text("{}")
    return root


def test_hooks(base: Path) -> None:
    root = make_root(base)
    r = run_hook(root, "post-merge", "0")
    check(r.returncode == 0 and calls(root) == ["wt pull all", "sync"], "post-merge in root runs `ops wt pull all` then `ops sync`", r.stdout + r.stderr)

    root = make_root(base, "nomarker", marker=False)
    r = run_hook(root, "post-merge", "0")
    check(r.returncode == 0 and calls(root) == [], "no harness.json: ops not called", r.stderr)

    root = make_root(base, "wtmain")
    git(root, "worktree", "add", "-q", "-b", "wt", str(base / "wt"))
    wt = base / "wt"
    stub_ops(wt / "ops")
    (wt / "harness.json").write_text("{}")
    r = run_hook(root, "post-merge", "0", cwd=wt)
    check(r.returncode == 0 and calls(wt) == [] and calls(root) == [], "linked worktree: ops not called", r.stderr)

    root = make_root(base, "packages/agent-workspace")
    r = run_hook(root, "post-merge", "0")
    check(r.returncode == 0 and calls(root) == [], "clone under packages/: ops not called", r.stderr)

    root = make_root(base, "optout")
    r = run_hook(root, "post-merge", "0", env=base_env({"WORKSPACE_NO_AUTO_SYNC": "1"}))
    check(r.returncode == 0 and calls(root) == [], "WORKSPACE_NO_AUTO_SYNC=1: neither wt pull nor sync called", r.stderr)

    root = make_root(base, "wtfail")
    stub_ops(root / "ops", wt_rc=5)
    r = run_hook(root, "post-merge", "0")
    check(
        r.returncode == 0 and calls(root) == ["wt pull all", "sync"] and "wt pull all failed" in r.stderr,
        "failing wt pull: warning, sync still runs, exit 0", r.stdout + r.stderr,
    )

    root = make_root(base, "nowtpull")
    r = run_hook(root, "post-merge", "0", env=base_env({"WORKSPACE_NO_AUTO_WT_PULL": "1"}))
    check(r.returncode == 0 and calls(root) == ["sync"], "WORKSPACE_NO_AUTO_WT_PULL=1: only sync runs", r.stderr)

    root = make_root(base, "envleak")
    leak = {
        "GIT_CONFIG_PARAMETERS": "'x.y=z'", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "x.y",
        "GIT_CONFIG_VALUE_0": "z", "GIT_ASKPASS": "/bin/echo", "GIT_TERMINAL_PROMPT": "0", "GIT_REFLOG_ACTION": "pull",
    }
    r = run_hook(root, "post-merge", "0", env=base_env(leak))
    seen = (root / "wt.env").read_text() if (root / "wt.env").exists() else ""
    check(
        r.returncode == 0 and calls(root) == ["wt pull all", "sync"] and seen == "",
        "wt pull all does not see invoking git's config/askpass env", seen + r.stderr,
    )
    check("post-merge: ./ops wt pull all ..." in r.stdout, "pre-pull progress line printed", r.stdout)

    root = make_root(base, "failing", ops_rc=3)
    r = run_hook(root, "post-merge", "0")
    check(
        r.returncode == 0 and calls(root) == ["wt pull all", "sync"] and "may be stale" in r.stderr and "./ops sync" in r.stderr,
        "failing ops: exit 0 with stale-trees warning", r.stdout + r.stderr,
    )

    root = make_root(base, "notexec")
    (root / "ops").chmod(0o644)
    r = run_hook(root, "post-merge", "0")
    check(r.returncode == 0 and calls(root) == [], "non-executable ops: silent exit 0", r.stderr)

    root = make_root(base, "rewrite")
    r = run_hook(root, "post-rewrite", "rebase")
    check(r.returncode == 0 and calls(root) == ["wt pull all", "sync"], "post-rewrite rebase runs wt pull then sync", r.stderr)
    r = run_hook(root, "post-rewrite", "amend")
    check(r.returncode == 0 and calls(root) == ["wt pull all", "sync"], "post-rewrite amend does not run sync", r.stderr)
    r = run_hook(root, "post-rewrite")
    check(r.returncode == 0 and calls(root) == ["wt pull all", "sync"], "post-rewrite without args exits 0", r.stderr)


def test_pull(base: Path) -> None:
    origin = base / "origin.git"
    seed = base / "seed"
    init_repo(seed)
    commit(seed, "a")
    subprocess.run(["git", "clone", "-q", "--bare", str(seed), str(origin)], env=base_env(), check=True)
    for mode in ("merge", "rebase"):
        clone = base / f"clone-{mode}"
        subprocess.run(["git", "clone", "-q", str(origin), str(clone)], env=base_env(), check=True)
        git(clone, "config", "pull.rebase", "true" if mode == "rebase" else "false")
        if mode == "merge":
            git(clone, "config", "pull.ff", "only")
        install_hooks_copy(clone)
        stub_ops(clone / "ops")
        (clone / "harness.json").write_text("{}")
        # untracked helper files do not block pull; local commit forces a rebase
        # (post-rewrite) rather than a fast-forward (post-merge) in rebase mode.
        if mode == "rebase":
            commit(clone, "local")
        commit(seed, f"remote-{mode}")
        git(seed, "push", "-q", str(origin), "main")
        r = git(clone, "pull", "-q", check_rc=False)
        check(r.returncode == 0, f"real git pull ({mode}) succeeds", r.stderr)
        check(calls(clone) == ["wt pull all", "sync"], f"real git pull ({mode}) triggers wt pull then ops sync", repr(calls(clone)) + r.stderr)


def installer_root(base: Path, name: str) -> Path:
    root = base / name
    init_repo(root)
    shutil.copy2(SRC / "ops", root / "ops")
    (root / "agents").mkdir()
    (root / "agents/build.py").write_text("#!/usr/bin/env bash\nexit 0\n")
    (root / "agents/build.py").chmod(0o755)
    (root / "package.json").write_text("{}")
    for name_ in HOOKS:
        (root / "agents/git-hooks").mkdir(exist_ok=True)
        shutil.copy2(SRC / "agents/git-hooks" / name_, root / "agents/git-hooks" / name_)
    return root


def run_ops(root: Path, *args: str):
    return subprocess.run([str(root / "ops"), *args], cwd=root, env=base_env(), capture_output=True, text=True)


def test_installer(base: Path) -> None:
    root = installer_root(base, "inst")
    for cmd in ("sync", "update", "setup"):
        shutil.rmtree(root / ".git/hooks", ignore_errors=True)
        r = run_ops(root, cmd)
        links = [(root / ".git/hooks" / n) for n in HOOKS]
        ok = r.returncode == 0 and all(
            p.is_symlink() and os.readlink(p) == f"../../agents/git-hooks/{p.name}" and os.access(p, os.X_OK)
            for p in links
        )
        check(ok, f"ops {cmd} installs relative symlinks", r.stdout + r.stderr)
    r = run_ops(root, "sync")
    check(
        r.returncode == 0 and "installed git hook" not in r.stdout and r.stderr == "",
        "second sync is idempotent", r.stdout + r.stderr,
    )

    root = installer_root(base, "ws/packages/agent-workspace")
    r = run_ops(root, "sync")
    check(
        r.returncode == 0 and not (root / ".git/hooks/post-merge").exists() and r.stderr == "",
        "clone under packages/: installer is silent", r.stdout + r.stderr,
    )

    root = installer_root(base, "foreign")
    hooks = root / ".git/hooks"
    hooks.mkdir(exist_ok=True)
    mine = hooks / "post-merge"
    mine.write_text("#!/bin/sh\necho mine\n")
    r = run_ops(root, "sync")
    check(
        r.returncode == 0 and mine.read_text() == "#!/bin/sh\necho mine\n" and not mine.is_symlink()
        and "post-merge" in r.stderr and (hooks / "post-rewrite").is_symlink(),
        "foreign hook preserved, warning printed, sync succeeds", r.stdout + r.stderr,
    )

    root = installer_root(base, "hookspath")
    git(root, "config", "core.hooksPath", str(base / "elsewhere"))
    shutil.rmtree(root / ".git/hooks", ignore_errors=True)
    r = run_ops(root, "sync")
    check(
        r.returncode == 0 and not (root / ".git/hooks/post-merge").exists() and "core.hooksPath" in r.stderr,
        "core.hooksPath set: nothing installed, exit 0", r.stdout + r.stderr,
    )

    root = installer_root(base, "linked")
    commit(root, "seed")
    wt = base / "linked-wt"
    git(root, "worktree", "add", "-q", "-b", "w", str(wt))
    shutil.copy2(SRC / "ops", wt / "ops")
    (wt / "agents").mkdir(exist_ok=True)
    shutil.copy2(root / "agents/build.py", wt / "agents/build.py")
    r = run_ops(wt, "sync")
    check(r.returncode == 0 and r.stdout == "" and r.stderr == "", "linked worktree: installer is silent", r.stdout + r.stderr)


def main() -> int:
    if shutil.which("git") is None:
        print("FAIL: git is required")
        return 1
    for name in HOOKS:
        p = SRC / "agents/git-hooks" / name
        check(p.is_file() and os.access(p, os.X_OK), f"agents/git-hooks/{name} exists and is executable")
    with tempfile.TemporaryDirectory(prefix="workspace-git-hooks-") as raw:
        base = Path(raw).resolve()
        for fn in (test_hooks, test_pull, test_installer):
            sub = base / fn.__name__
            sub.mkdir()
            try:
                fn(sub)
            except Exception as exc:  # noqa: BLE001 - a crashed test must be red
                check(False, f"{fn.__name__} crashed", repr(exc))
    if FAILS:
        print(f"{len(FAILS)} check(s) failed")
        return 1
    print("git-hooks tests passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
