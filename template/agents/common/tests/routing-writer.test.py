#!/usr/bin/env python3
"""Isolated writers: reservation ledger, disposable checkouts, patch integration (task 2.6, D5).

Requirements: agent-directed-routing / «Непересекающийся ownership вложенных
правок» and design D5 — every write-capable descendant owns a disposable
checkout, the immediate parent verifies the returned patch against the reserved
scope and integrates it all-or-nothing, hop by hop up to the canonical worktree.
Real git repositories in a temp dir, the CLIs as a subprocess; expected values
come from D5/tasks 2.6.

    python3 agents/common/tests/routing-writer.test.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SKILL = ROOT / "agents/common/skills/agent-directed-routing"
WRITER, OWNERSHIP = SKILL / "writer.py", SKILL / "ownership.py"
ENV = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
BIN = bytes(range(256)) * 4


def run(*cmd: str, cwd: Path | None = None, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=ENV, **kw)


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, env=ENV)
    assert result.returncode == 0, f"git {args}: {result.stderr}"
    return result.stdout


def tree_state(root: Path) -> dict[str, tuple]:
    """Everything below `root` except .git: path -> (kind, mode, content) — for byte-for-byte comparison."""
    state: dict[str, tuple] = {}
    for current, dirs, names in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d != ".git")
        for name in sorted(names + [d for d in dirs if os.path.islink(os.path.join(current, d))]):
            path = Path(current, name)
            rel = path.relative_to(root).as_posix()
            if path.is_symlink():
                state[rel] = ("link", 0, os.readlink(path))
            elif name != ".git":
                state[rel] = ("file", path.stat().st_mode & 0o111, path.read_bytes())
    return state


class World:
    """worktrees/<task>/ with one or more repos, each a git repo with a few tracked files."""

    def __init__(self, repos: tuple[str, ...] = ("repo",)) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="routing-writer-")).resolve()
        self.task = self.tmp / "T"
        for name in repos:
            repo = self.task / name
            repo.mkdir(parents=True)
            git(repo, "init", "-q")
            git(repo, "config", "user.email", "t@example.test")
            git(repo, "config", "user.name", "t")
            for rel, data in {
                "src/a/x.ts": b"x\n", "src/a/y.ts": b"y\n", "src/b/y.ts": b"b-y\n", "src/bin.dat": BIN,
                "src/run.sh": b"#!/bin/sh\n", "docs/d.md": b"d\n", "README.md": b"r\n",
            }.items():
                (repo / rel).parent.mkdir(parents=True, exist_ok=True)
                (repo / rel).write_bytes(data)
            git(repo, "add", "-A")
            git(repo, "commit", "-qm", "init")

    def repo(self, name: str = "repo") -> Path:
        return self.task / name

    def checkout(self, agent: str) -> Path:
        return self.task / ".agent-routing/checkouts" / agent.replace("/", "~")

    def recovery(self, agent: str) -> Path:
        return self.task / ".agent-routing/recovery" / agent

    def ledger(self) -> dict:
        return json.loads((self.task / ".agent-routing/ownership.json").read_text())

    def entry(self, agent: str) -> dict:
        return next(e for e in self.ledger()["entries"] if e["agentPath"] == agent)

    def save_ledger(self, document: dict) -> None:
        (self.task / ".agent-routing/ownership.json").write_text(json.dumps(document))

    def w(self, *args: str, tree: Path | None = None) -> subprocess.CompletedProcess:
        return run(sys.executable, str(WRITER), "--repo-root", str(tree or self.repo()), *args)

    def spawn(self, agent: str, *scopes: str, parent: str = "root", depth: int = 1, tree: Path | None = None,
              parent_scopes: tuple[str, ...] = ("src", "docs"), lease: int | None = None) -> subprocess.CompletedProcess:
        args = ["spawn", "--agent-path", agent, "--parent-path", parent, "--depth", str(depth), "--track", "F"]
        for scope in scopes:
            args += ["--scope", scope]
        if parent == "root":
            for scope in parent_scopes:
                args += ["--parent-scope", scope]
        if lease is not None:
            args += ["--lease-seconds", str(lease)]
        return self.w(*args, tree=tree)

    def start(self, agent: str) -> None:
        ok(self.w("start", "--agent-path", agent), f"start {agent}")

    def finish(self, agent: str, tree: Path | None = None) -> subprocess.CompletedProcess:
        ok(self.w("submit", "--agent-path", agent, tree=tree), f"submit {agent}")
        return self.w("integrate", "--agent-path", agent, tree=tree)

    def ownership(self, *args: str) -> subprocess.CompletedProcess:
        return run(sys.executable, str(OWNERSHIP), "--task-dir", str(self.task), *args)

    def worktrees(self, repo: str = "repo") -> list[str]:
        return [l.split()[0] for l in git(self.repo(repo), "worktree", "list").splitlines()]

    def close(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)


def ok(proc: subprocess.CompletedProcess, what: str) -> subprocess.CompletedProcess:
    assert proc.returncode == 0, f"{what} failed ({proc.returncode}):\n{proc.stdout}\n{proc.stderr}"
    return proc


def refused(proc: subprocess.CompletedProcess, what: str) -> None:
    assert proc.returncode == 2, f"{what} must be refused with exit 2, got {proc.returncode}:\n{proc.stdout}\n{proc.stderr}"


def assert_failed_hop(world: World, agent: str, parent: str, target: Path, phase: str | None = None,
                      bundle: bool = True) -> dict:
    """failed state + failedHop naming the hop + recovery bundle, and nothing else half-done."""
    entry = world.entry(agent)
    assert entry["state"] == "failed", entry["state"]
    hop = entry["failedHop"]
    assert hop["from"] == agent and hop["to"] == parent, hop
    assert Path(hop["target"]).resolve() == target.resolve(), hop
    assert hop["reason"] and (phase is None or hop["phase"] == phase), hop
    assert hop["rollback"] == "ok" and hop["dirtyPaths"] == [], hop
    if bundle:
        for name in ("_patch.diff", "_manifest.json", "_failure.json"):
            assert (world.recovery(agent) / name).is_file(), f"recovery bundle lacks {name}"
        failure = json.loads((world.recovery(agent) / "_failure.json").read_text())
        assert failure["agentPath"] == agent and failure["rollback"] == "ok"
    assert not world.checkout(agent).exists(), "a handled failure removes the disposable checkout"
    return entry


# ============================================================================================
# Reservation: atomic ledger, overlap refusal, cross-repo identity
# ============================================================================================

def test_reservation_and_overlap() -> None:
    world = World(("repo", "other"))
    try:
        ok(world.spawn("root/w1", "src/a"), "first reservation")
        entry = world.entry("root/w1")
        assert entry["state"] == "reserved" and entry["scopes"] == ["src/a"]
        assert Path(entry["checkout"]).is_dir() and Path(entry["checkout"]) != world.repo()
        before = json.dumps(world.ledger())

        refused(world.spawn("root/w2", "src/a"), "same scope")  # sibling overlap
        refused(world.spawn("root/w3", "src/a/x.ts"), "file inside a reserved directory")
        refused(world.spawn("root/w4", "src"), "parent directory of a reserved scope")
        refused(world.spawn("root/w5", "src/a/new-dir"), "new directory under a reserved scope")  # new-path collision
        refused(world.spawn("root/w6", "src/a/**"), "tracked glob over a reserved scope")
        refused(world.spawn("root/w7", "README.md"), "scope outside the group paths")  # --parent-scope containment
        refused(world.spawn("root/w1", "docs"), "an agent path is never reused")
        assert json.dumps(world.ledger()) == before, "a refused reservation must not touch the ledger"
        assert not (world.task / ".agent-routing/checkouts/root~w2").exists(), "refused before any checkout exists"

        ok(world.spawn("root/w8", "src/b"), "disjoint scope is fine")
        ok(world.spawn("root/w9", "docs/**"), "disjoint glob is fine")
        refused(world.spawn("root/w10", "docs/d.md"), "file under a reserved glob")
        refused(world.spawn("root/w11", "docs/brand-new/file.md"), "new directory matched by a reserved glob")

        # the same glob in another repository is another resource
        ok(world.spawn("root/o1", "src/**", tree=world.repo("other")), "same glob, other repo")
        refused(world.spawn("root/o2", "src/b", tree=world.repo("other")), "overlap inside the other repo")
    finally:
        world.close()


def test_track_choices_include_writing_track_a_and_drop_old_letters() -> None:
    """A writes architecture material through a disposable checkout; old B and read-only E are not writer tracks."""
    world = World()
    try:
        base = ["spawn", "--parent-path", "root", "--depth", "1", "--parent-scope", "src", "--parent-scope", "docs"]
        ok(world.w(*base, "--agent-path", "root/arch", "--track", "A", "--scope", "docs"), "Track A writer")
        entry = world.entry("root/arch")
        assert entry["track"] == "A" and entry["state"] == "reserved"
        assert Path(entry["checkout"]).is_dir() and ".agent-routing/checkouts" in entry["checkout"]
        for n, track in enumerate(("P", "Q", "F", "C", "H", "I")):
            ok(world.w(*base, "--agent-path", f"root/t{n}", "--track", track, "--scope", f"src/new-{n}"), f"track {track}")
        before = json.dumps(world.ledger())
        for track in ("B", "E", "a"):
            refused(world.w(*base, "--agent-path", f"root/x{track}", "--track", track, "--scope", "src/b"), f"track {track}")
        assert json.dumps(world.ledger()) == before, "an unknown track must not touch the ledger"
    finally:
        world.close()


def test_reservation_is_atomic_under_races() -> None:
    world = World()
    try:
        procs = [subprocess.Popen(
            [sys.executable, str(WRITER), "--repo-root", str(world.repo()), "spawn", "--agent-path", f"root/r{i}",
             "--parent-path", "root", "--depth", "1", "--track", "F", "--scope", "src/a", "--parent-scope", "src"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=ENV) for i in range(6)]
        codes = sorted(p.wait() for p in procs)
        assert codes == [0, 2, 2, 2, 2, 2], f"exactly one racer may win the scope: {codes}"
        live = [e for e in world.ledger()["entries"] if e["state"] in ("reserved", "active", "patch_ready")]
        assert len(live) == 1
    finally:
        world.close()


def test_snapshot_includes_untracked_and_uncommitted_parent_state() -> None:
    world = World()
    try:
        (world.repo() / "src/a/x.ts").write_text("uncommitted\n")
        (world.repo() / "src/a/untracked.ts").write_text("new\n")
        ok(world.spawn("root/w1", "src/a"), "spawn")
        checkout = world.checkout("root/w1")
        assert (checkout / "src/a/x.ts").read_text() == "uncommitted\n"
        assert (checkout / "src/a/untracked.ts").read_text() == "new\n"
        assert (world.repo() / "src/a/x.ts").read_text() == "uncommitted\n"
        assert git(checkout, "status", "--porcelain").strip() == "", "the writer starts from a clean snapshot"
        assert world.entry("root/w1")["snapshotTree"], "exact snapshot digest recorded"
    finally:
        world.close()


# ============================================================================================
# Parallel disjoint writers, all change kinds
# ============================================================================================

def test_two_disjoint_writers_run_concurrently_and_both_integrate() -> None:
    world = World()
    try:
        ok(world.spawn("root/w1", "src/a"), "w1")
        ok(world.spawn("root/w2", "docs/**"), "w2")  # reserved while w1 is live: no serialisation
        world.start("root/w1")
        world.start("root/w2")
        assert {world.entry(a)["state"] for a in ("root/w1", "root/w2")} == {"active"}  # both running at once
        (world.checkout("root/w1") / "src/a/x.ts").write_text("from w1\n")
        (world.checkout("root/w2") / "docs/new.md").write_text("from w2\n")
        (world.checkout("root/w2") / "docs/d.md").unlink()
        for agent in ("root/w1", "root/w2"):
            ok(world.w("submit", "--agent-path", agent), "submit")
        procs = [subprocess.Popen([sys.executable, str(WRITER), "--repo-root", str(world.repo()), "integrate",
                                   "--agent-path", a], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
                 for a in ("root/w1", "root/w2")]
        results = [(p.wait(), p.stdout.read(), p.stderr.read()) for p in procs]
        assert all(code == 0 for code, _, _ in results), results
        assert (world.repo() / "src/a/x.ts").read_text() == "from w1\n"
        assert (world.repo() / "docs/new.md").read_text() == "from w2\n" and not (world.repo() / "docs/d.md").exists()
        assert {world.entry(a)["state"] for a in ("root/w1", "root/w2")} == {"integrated"}
        assert not any(world.checkout(a).exists() for a in ("root/w1", "root/w2"))
        assert world.worktrees() == [str(world.repo())], "no disposable checkout stays registered with git"
    finally:
        world.close()


def test_change_kinds_rename_new_delete_binary_mode_symlink() -> None:
    world = World()
    try:
        ok(world.spawn("root/w1", "src"), "w1")
        world.start("root/w1")
        co = world.checkout("root/w1")
        (co / "src/bin.dat").rename(co / "src/bin-renamed.dat")  # binary rename
        (co / "src/b/y.ts").unlink()  # delete
        (co / "src/new").mkdir()
        (co / "src/new/f.ts").write_text("new\n")  # new file in a new directory
        (co / "src/run.sh").chmod(0o755)  # mode change
        os.symlink("run.sh", co / "src/lnk")  # symlink inside the repository
        (co / "src/a/x.ts").write_bytes(BIN[::-1])  # binary content change
        result = world.finish("root/w1")
        ok(result, "integrate")
        repo = world.repo()
        assert (repo / "src/bin-renamed.dat").read_bytes() == BIN and not (repo / "src/bin.dat").exists()
        assert not (repo / "src/b/y.ts").exists()
        assert (repo / "src/new/f.ts").read_text() == "new\n"
        assert os.access(repo / "src/run.sh", os.X_OK)
        assert (repo / "src/lnk").is_symlink() and os.readlink(repo / "src/lnk") == "run.sh"
        assert (repo / "src/a/x.ts").read_bytes() == BIN[::-1]
        assert world.entry("root/w1")["state"] == "integrated"
    finally:
        world.close()


# ============================================================================================
# Refusals: out-of-scope, traversal, submodule, symlink escape, digest — target stays byte-identical
# ============================================================================================

def tamper(world: World, agent: str, edit) -> None:
    manifest_path = world.task / ".agent-routing/patches" / agent / "_manifest.json"
    manifest = json.loads(manifest_path.read_text())
    edit(manifest)
    manifest_path.write_text(json.dumps(manifest))


def test_unsafe_results_are_refused_and_leave_the_target_untouched() -> None:
    world = World()
    try:
        canonical_before = tree_state(world.repo())

        def attempt(agent: str, prepare, phase: str, tamper_manifest=None):
            ok(world.spawn(agent, "src"), agent)
            world.start(agent)
            prepare(world.checkout(agent))
            ok(world.w("submit", "--agent-path", agent), "submit")
            if tamper_manifest:
                tamper(world, agent, tamper_manifest)
            result = world.w("integrate", "--agent-path", agent)
            assert result.returncode == 3, result.stdout + result.stderr
            assert tree_state(world.repo()) == canonical_before, f"{agent}: canonical changed by a refused patch"
            assert_failed_hop(world, agent, "root", world.repo(), phase)

        attempt("root/out", lambda co: ((co / "docs/d.md").write_text("outside\n"), (co / "src/ok.ts").write_text("in\n")), "scope")
        attempt("root/rename-out", lambda co: (co / "src/a/y.ts").rename(co / "docs/stolen.ts"), "scope")  # both rename sides
        attempt("root/escape", lambda co: os.symlink("../../etc/passwd", co / "src/esc"), "scope")  # symlink out of the repo
        attempt("root/abs", lambda co: os.symlink("/etc", co / "src/abs"), "scope")

        def embedded_repo(co: Path) -> None:  # a nested git repo becomes a gitlink: a submodule boundary
            sub = co / "src/vendor"
            sub.mkdir()
            git(sub, "init", "-q")
            git(sub, "-c", "user.name=t", "-c", "user.email=t@e", "commit", "-q", "--allow-empty", "-m", "s")

        attempt("root/submodule", embedded_repo, "scope")

        def traversal(manifest: dict) -> None:
            manifest["entries"][0]["path"] = "../escape.txt"

        attempt("root/traversal", lambda co: (co / "src/t.txt").write_text("t\n"), "scope", traversal)

        def into_git(manifest: dict) -> None:
            manifest["entries"][0]["path"] = ".git/hooks/post-checkout"

        attempt("root/dotgit", lambda co: (co / "src/g.txt").write_text("g\n"), "scope", into_git)
        assert not (world.task / "escape.txt").exists()

        # digest: a patch altered after submit is refused before anything is written
        ok(world.spawn("root/digest", "src"), "digest")
        world.start("root/digest")
        (world.checkout("root/digest") / "src/d.txt").write_text("d\n")
        ok(world.w("submit", "--agent-path", "root/digest"), "submit")
        patch = world.task / ".agent-routing/patches/root/digest/_patch.diff"
        patch.write_bytes(patch.read_bytes() + b"\n")
        assert world.w("integrate", "--agent-path", "root/digest").returncode == 3
        assert tree_state(world.repo()) == canonical_before
        assert_failed_hop(world, "root/digest", "root", world.repo(), "digest")
    finally:
        world.close()


# ============================================================================================
# Conflicts at each hop: child -> parent, parent -> canonical, grandchild -> child
# ============================================================================================

def test_conflict_at_the_canonical_hop() -> None:
    world = World()
    try:
        ok(world.spawn("root/w1", "src/a"), "w1")
        world.start("root/w1")
        (world.checkout("root/w1") / "src/a/x.ts").write_text("child\n")
        (world.repo() / "src/a/x.ts").write_text("someone else\n")  # the target moved after the snapshot
        before = tree_state(world.repo())
        result = world.finish("root/w1")
        assert result.returncode == 3, result.stdout
        assert tree_state(world.repo()) == before
        entry = assert_failed_hop(world, "root/w1", "root", world.repo(), "cas")
        assert "src/a/x.ts" in entry["failedHop"]["reason"]
        # the scope went back to its owner with the bundle registered: it can be reserved again
        ok(world.spawn("root/w1-retry", "src/a"), "re-dispatch from a fresh snapshot, new agent path")
    finally:
        world.close()


def nested_world() -> tuple[World, Path, Path]:
    """root/p owns src, root/p/c owns src/a, root/p/c/g owns src/a/deep — three levels of isolated checkouts."""
    world = World()
    (world.repo() / "src/a/deep").mkdir()
    (world.repo() / "src/a/deep/z.ts").write_text("z\n")
    git(world.repo(), "add", "-A")
    git(world.repo(), "commit", "-qm", "deep")
    ok(world.spawn("root/p", "src"), "p")
    world.start("root/p")
    p_tree = world.checkout("root/p")
    ok(world.spawn("root/p/c", "src/a", parent="root/p", depth=2, tree=p_tree), "c")
    world.start("root/p/c")
    c_tree = world.checkout("root/p/c")
    ok(world.spawn("root/p/c/g", "src/a/deep", parent="root/p/c", depth=3, tree=c_tree), "g")
    world.start("root/p/c/g")
    return world, p_tree, c_tree


def test_nested_carve_out_ledger_and_propagation() -> None:
    world, p_tree, c_tree = nested_world()
    try:
        ledger = world.ledger()
        for ancestor in ("root/p", "root/p/c"):  # delegatedTo on every ancestor of the grandchild
            assert "root/p/c/g" in json.dumps(world.entry(ancestor)["delegatedTo"]), ancestor
        assert "root/p/c" in json.dumps(world.entry("root/p")["delegatedTo"])
        assert world.entry("root/p/c/g")["target"] == str(c_tree) and world.entry("root/p/c")["target"] == str(p_tree)

        # strict subset only; siblings/cousins/unrelated overlap refused before spawn
        refused(world.spawn("root/p/c/x", "src/a", parent="root/p/c", depth=3, tree=c_tree), "equal scope is not a strict subset")
        refused(world.spawn("root/p/c/y", "src/b", parent="root/p/c", depth=3, tree=c_tree), "outside the parent's scope")
        refused(world.spawn("root/p/c/z", "src/a/deep/z.ts", parent="root/p/c", depth=3, tree=c_tree), "overlaps a live child")
        refused(world.spawn("root/p/s", "src/a/y.ts", parent="root/p", depth=2, tree=p_tree), "overlaps a delegated sub-scope")
        refused(world.spawn("root/unrelated", "src/a/deep"), "unrelated branch overlapping")
        ok(world.spawn("root/p/sib", "src/b", parent="root/p", depth=2, tree=p_tree), "disjoint sibling inside the parent")
        assert world.ledger()["entries"][:len(ledger["entries"])]  # earlier records intact

        # ancestors: writing inside the carve-out is rejected, outside it is allowed
        assert world.ownership("check-write", "--agent-path", "root/p", "src/a/deep/z.ts").returncode == 2
        assert world.ownership("check-write", "--agent-path", "root/p/c", "src/a/deep/new.ts").returncode == 2
        assert world.ownership("check-write", "--agent-path", "root/p/c", "src/a/y.ts").returncode == 0
        assert world.ownership("check-write", "--agent-path", "root/p", "src/run.sh").returncode == 0
        assert world.ownership("check-write", "--agent-path", "root/p/c/g", "src/a/deep/z.ts").returncode == 0
        assert world.ownership("check-write", "--agent-path", "root/p/c/g", "src/a/y.ts").returncode == 2  # outside its own scope

        # successful nested propagation, hop by hop, canonical gets everything at the end
        (world.checkout("root/p/c/g") / "src/a/deep/z.ts").write_text("grandchild\n")
        (c_tree / "src/a/y.ts").write_text("child\n")
        (p_tree / "src/run.sh").write_text("#!/bin/sh\nparent\n")
        refused(world.w("submit", "--agent-path", "root/p/c", tree=c_tree), "a writer with a live descendant cannot submit")
        ok(world.finish("root/p/c/g", tree=c_tree), "grandchild -> child")
        assert (c_tree / "src/a/deep/z.ts").read_text() == "grandchild\n"
        assert (world.repo() / "src/a/deep/z.ts").read_text() == "z\n", "nothing reaches the canonical tree before its hop"
        assert world.entry("root/p/c/g")["state"] == "integrated"
        # the carved-out sub-scope returns to the child once the grandchild is integrated
        assert world.ownership("check-write", "--agent-path", "root/p/c", "src/a/deep/z.ts").returncode == 0
        ok(world.finish("root/p/c", tree=p_tree), "child -> parent")
        assert (p_tree / "src/a/deep/z.ts").read_text() == "grandchild\n" and (p_tree / "src/a/y.ts").read_text() == "child\n"
        assert (world.repo() / "src/a/y.ts").read_text() == "y\n"
        ok(world.w("cancel", "--agent-path", "root/p/sib", tree=p_tree), "cancel the idle sibling")
        ok(world.finish("root/p"), "parent -> canonical")
        repo = world.repo()
        assert (repo / "src/a/deep/z.ts").read_text() == "grandchild\n" and (repo / "src/a/y.ts").read_text() == "child\n"
        assert "parent" in (repo / "src/run.sh").read_text()
        assert [world.entry(a)["state"] for a in ("root/p/c/g", "root/p/c", "root/p")] == ["integrated"] * 3
        assert world.worktrees() == [str(repo)]
    finally:
        world.close()


def test_carve_out_must_be_a_strict_subset() -> None:
    world = World()
    try:
        ok(world.spawn("root/q", "src/b", "src/a/x.ts"), "q")
        world.start("root/q")
        q_tree = world.checkout("root/q")
        refused(world.spawn("root/q/same", "src/b", "src/a/x.ts", parent="root/q", depth=2, tree=q_tree), "the whole scope")
        refused(world.spawn("root/q/same2", "src/a/x.ts", "src/b", parent="root/q", depth=2, tree=q_tree), "the whole scope, reordered")
        refused(world.spawn("root/q/out", "src/a/y.ts", parent="root/q", depth=2, tree=q_tree), "outside the parent's scope")
        ok(world.spawn("root/q/part", "src/b/y.ts", parent="root/q", depth=2, tree=q_tree), "a strict subset is a valid carve-out")
        ok(world.spawn("root/q/part2", "src/a/x.ts", parent="root/q", depth=2, tree=q_tree), "a second disjoint carve-out")
    finally:
        world.close()


def test_failures_at_the_inner_hops_leave_every_ancestor_untouched() -> None:
    for kind in ("conflict", "out-of-scope"):
        world, p_tree, c_tree = nested_world()
        try:
            g_tree = world.checkout("root/p/c/g")
            (g_tree / "src/a/deep/z.ts").write_text("grandchild\n")
            if kind == "conflict":
                # c's checkout changed the same path after g's snapshot: grandchild -> child must fail whole
                (c_tree / "src/a/deep/z.ts").write_text("child got there first\n")
            else:
                (g_tree / "src/a/y.ts").write_text("outside g's scope\n")
            canonical, parent, child = tree_state(world.repo()), tree_state(p_tree), tree_state(c_tree)
            result = world.finish("root/p/c/g", tree=c_tree)
            assert result.returncode == 3, result.stdout
            assert tree_state(world.repo()) == canonical and tree_state(p_tree) == parent and tree_state(c_tree) == child, \
                "the immediate target and every ancestor stay byte-for-byte unchanged"
            assert_failed_hop(world, "root/p/c/g", "root/p/c", c_tree, "cas" if kind == "conflict" else "scope")
            assert world.entry("root/p/c")["state"] == "active" and world.entry("root/p")["state"] == "active"

            if kind == "conflict":  # the child wrote into g's delegated scope: recorded, and submit stays blocked until restored
                assert world.entry("root/p/c")["delegationViolations"]
                (c_tree / "src/a/deep/z.ts").write_text("z\n")
            # child -> parent hop failing: parent's checkout and canonical unchanged, grandchild's work not propagated
            (c_tree / "src/a/y.ts").write_text("child work\n")
            (p_tree / "src/a/y.ts").write_text("parent moved\n")  # the delegated sub-scope changed under the child
            parent, canonical = tree_state(p_tree), tree_state(world.repo())
            result = world.finish("root/p/c", tree=p_tree)
            assert result.returncode == 3, result.stdout
            assert tree_state(p_tree) == parent and tree_state(world.repo()) == canonical
            assert_failed_hop(world, "root/p/c", "root/p", p_tree, "cas")
        finally:
            world.close()


def test_parent_to_canonical_failures_after_a_successful_inner_hop() -> None:
    for kind in ("conflict", "out-of-scope"):
        world, p_tree, c_tree = nested_world()
        try:
            (world.checkout("root/p/c/g") / "src/a/deep/z.ts").write_text("grandchild\n")
            ok(world.finish("root/p/c/g", tree=c_tree), "g -> c")
            ok(world.finish("root/p/c", tree=p_tree), "c -> p")
            if kind == "conflict":
                (world.repo() / "src/a/deep/z.ts").write_text("canonical moved\n")
            else:
                (p_tree / "docs/d.md").write_text("p wrote outside its scope\n")
            before = tree_state(world.repo())
            result = world.finish("root/p")
            assert result.returncode == 3, result.stdout
            assert tree_state(world.repo()) == before, "no partial propagation into the canonical worktree"
            assert_failed_hop(world, "root/p", "root", world.repo(), "cas" if kind == "conflict" else "scope")
            assert world.entry("root/p/c/g")["state"] == "integrated"  # inner hops stay what they were
        finally:
            world.close()


# ============================================================================================
# delegationViolations (S7)
# ============================================================================================

def test_delegated_scope_written_by_an_ancestor() -> None:
    world, p_tree, c_tree = nested_world()
    try:
        (world.checkout("root/p/c/g") / "src/a/deep/z.ts").write_text("grandchild\n")
        (c_tree / "src/a/deep/stray.ts").write_text("the child wrote into the delegated scope\n")
        result = world.finish("root/p/c/g", tree=c_tree)
        assert result.returncode == 3
        hop = world.entry("root/p/c/g")["failedHop"]
        assert "ancestor wrote delegated path" in hop["reason"] and "src/a/deep/stray.ts" in hop["reason"]
        violations = world.entry("root/p/c")["delegationViolations"]
        assert violations and "src/a/deep/stray.ts" in violations[0]["paths"] and violations[0]["agentPath"] == "root/p/c/g"
        refused(world.w("submit", "--agent-path", "root/p/c", tree=c_tree), "submit with an open violation")
        assert world.entry("root/p/c")["state"] == "active"
        (c_tree / "src/a/deep/stray.ts").unlink()  # restored to the child's snapshot content: the block lifts
        ok(world.w("submit", "--agent-path", "root/p/c", tree=c_tree), "submit after restoring")
    finally:
        world.close()

    world, p_tree, c_tree = nested_world()  # cancel path: the violation must be recorded without any hop
    try:
        (c_tree / "src/a/deep/z.ts").write_text("changed by the ancestor\n")
        ok(world.w("cancel", "--agent-path", "root/p/c/g", tree=c_tree), "cancel")
        assert world.entry("root/p/c")["delegationViolations"][0]["paths"] == ["src/a/deep/z.ts"]
        refused(world.w("submit", "--agent-path", "root/p/c", tree=c_tree), "submit after cancel with a violation")
        assert world.ownership("clear-violation", "--agent-path", "root/p/c").returncode == 0  # a deliberate operator step
        assert world.entry("root/p/c")["delegationViolations"] == []
        ok(world.w("submit", "--agent-path", "root/p/c", tree=c_tree), "submit after clear-violation")
    finally:
        world.close()


# ============================================================================================
# Crash safety: journal rollback (S4)
# ============================================================================================

def run_patched(world: World, agent: str, patch: str) -> subprocess.CompletedProcess:
    code = (f"import sys, os\nsys.path.insert(0, {str(SKILL)!r})\nimport writer\n{patch}\n"
            f"sys.argv = ['writer.py', '--repo-root', {str(world.repo())!r}, 'integrate', '--agent-path', {agent!r}]\n"
            "sys.exit(writer.main())\n")
    return run(sys.executable, "-c", code)


def prepare_patch_ready(world: World, agent: str = "root/w1") -> None:
    ok(world.spawn(agent, "src/a"), agent)
    world.start(agent)
    (world.checkout(agent) / "src/a/x.ts").write_text("child\n")
    (world.checkout(agent) / "src/a/new.ts").write_text("new\n")
    ok(world.w("submit", "--agent-path", agent), "submit")


def test_crash_during_apply_is_rolled_back_by_recover_and_integrate_can_be_rerun() -> None:
    world = World()
    try:
        prepare_patch_ready(world)
        pristine = tree_state(world.repo())
        crashed = run_patched(world, "root/w1", "real = writer.materialize\n"
                                                "def m(*a, **k):\n    real(*a, **k)\n    os._exit(9)\nwriter.materialize = m")
        assert crashed.returncode == 9
        assert tree_state(world.repo()) != pristine, "precondition: the crash left the target half-applied"
        assert (world.task / ".agent-routing/journals").is_dir() and any((world.task / ".agent-routing/journals").iterdir())
        report = json.loads(ok(world.w("recover"), "recover").stdout)
        assert report["journals"] and report["journals"][0]["rollback"] == "ok" and report["journals"][0]["dirtyPaths"] == []
        assert tree_state(world.repo()) == pristine, "recover restores the pre-apply state byte for byte"
        assert not any((world.task / ".agent-routing/journals").iterdir())
        ok(world.w("integrate", "--agent-path", "root/w1"), "a re-run integrate completes")
        assert (world.repo() / "src/a/x.ts").read_text() == "child\n" and (world.repo() / "src/a/new.ts").exists()
        assert world.entry("root/w1")["state"] == "integrated"
    finally:
        world.close()

    world = World()  # a re-run integrate alone also consults the journal
    try:
        prepare_patch_ready(world)
        pristine = tree_state(world.repo())
        run_patched(world, "root/w1", "real = writer.materialize\n"
                                      "def m(*a, **k):\n    real(*a, **k)\n    os._exit(9)\nwriter.materialize = m")
        ok(world.w("integrate", "--agent-path", "root/w1"), "integrate after a crash")
        assert (world.repo() / "src/a/x.ts").read_text() == "child\n"
        assert not any((world.task / ".agent-routing/journals").iterdir())
    finally:
        world.close()


def test_apply_failure_reports_rollback_ok_or_failed_with_dirty_paths() -> None:
    world = World()
    try:
        prepare_patch_ready(world)
        pristine = tree_state(world.repo())
        result = run_patched(world, "root/w1", "real = writer.materialize\ncalls = {'n': 0}\n"
                                               "def m(*a, **k):\n    calls['n'] += 1\n    real(*a, **k)\n"
                                               "    if calls['n'] == 1:\n        raise OSError('simulated failure after writing')\n"
                                               "writer.materialize = m")
        assert result.returncode == 3, result.stdout + result.stderr
        assert tree_state(world.repo()) == pristine, "a failed apply is rolled back, the target is unchanged"
        assert_failed_hop(world, "root/w1", "root", world.repo(), "apply")
    finally:
        world.close()

    world = World()
    try:
        prepare_patch_ready(world)
        result = run_patched(world, "root/w1", "real = writer.materialize\ncalls = {'n': 0}\n"
                                               "def m(*a, **k):\n    calls['n'] += 1\n"
                                               "    if calls['n'] == 1:\n        real(*a, **k)\n"
                                               "    raise OSError('simulated disk failure')\n"
                                               "writer.materialize = m")
        assert result.returncode == 3, result.stdout + result.stderr
        entry = world.entry("root/w1")
        assert entry["state"] == "failed" and entry["failedHop"]["rollback"] == "failed"
        assert entry["failedHop"]["dirtyPaths"], "the failure record must say which paths are dirty"
        failure = json.loads((world.recovery("root/w1") / "_failure.json").read_text())
        assert failure["rollback"] == "failed" and failure["dirtyPaths"] == entry["failedHop"]["dirtyPaths"]
        assert (world.task / ".agent-routing/journals").is_dir() and any((world.task / ".agent-routing/journals").iterdir()), \
            "a failed rollback keeps its journal so recover can retry"
    finally:
        world.close()


FAIL_TWICE = ("real = writer.materialize\ncalls = {'n': 0}\n"
              "def m(*a, **k):\n    calls['n'] += 1\n"
              "    if calls['n'] == 1:\n        real(*a, **k)\n"
              "    raise OSError('simulated disk failure')\n"
              "writer.materialize = m")


def journals(world: World) -> list[Path]:
    directory = world.task / ".agent-routing/journals"
    return sorted(directory.iterdir()) if directory.is_dir() else []


def test_a_stale_journal_never_clobbers_a_newer_integration() -> None:
    world = World()
    try:
        prepare_patch_ready(world)  # w1 rewrites src/a/x.ts and adds src/a/new.ts
        result = run_patched(world, "root/w1", FAIL_TWICE)
        assert result.returncode == 3 and world.entry("root/w1")["failedHop"]["rollback"] == "failed"
        assert len(journals(world)) == 1, "the failed rollback keeps its journal"

        ok(world.spawn("root/w2", "src/a"), "the scope is re-dispatched under a new agent path")
        world.start("root/w2")
        (world.checkout("root/w2") / "src/a/x.ts").write_text("newer\n")
        ok(world.finish("root/w2"), "the new writer integrates")
        assert (world.repo() / "src/a/x.ts").read_text() == "newer\n"

        report = json.loads(ok(world.w("recover"), "recover").stdout)
        old = next(j for j in report["journals"] if j["agentPath"] == "root/w1")
        assert "src/a/x.ts" in old["skippedPaths"], "content that is neither the snapshot nor the old apply is not ours"
        assert (world.repo() / "src/a/x.ts").read_text() == "newer\n", "the newer integration must survive recover"
        assert world.entry("root/w2")["state"] == "integrated" and not journals(world)
    finally:
        world.close()


def test_recover_cannot_undo_an_apply_that_is_about_to_be_recorded() -> None:
    world = World()
    try:
        prepare_patch_ready(world)
        pristine = tree_state(world.repo())
        ready, gate = world.tmp / "ready", world.tmp / "gate"
        seam = (f"import sys, os, time\nsys.path.insert(0, {str(SKILL)!r})\nimport writer\nreal = writer.apply_hop\n"
                "def apply(task, entry, on_applied=None):\n"
                "    def hook(result):  # inside the scope locks: tree applied, ledger not yet written\n"
                f"        open({str(ready)!r}, 'w').close()\n"
                f"        deadline = time.time() + 30\n"
                f"        while not os.path.exists({str(gate)!r}) and time.time() < deadline:\n            time.sleep(0.05)\n"
                "        return on_applied(result)\n"
                "    return real(task, entry, hook)\n"
                "writer.apply_hop = apply\n"
                f"sys.argv = ['writer.py', '--repo-root', {str(world.repo())!r}, 'integrate', '--agent-path', 'root/w1']\n"
                "sys.exit(writer.main())\n")
        integrate = subprocess.Popen([sys.executable, "-c", seam], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
        deadline = time.time() + 30
        while not ready.exists() and time.time() < deadline:
            time.sleep(0.05)
        assert ready.exists(), "integrate never reached the seam"
        applied = tree_state(world.repo())
        assert applied != pristine, "precondition: the patch is on disk, the ledger still says patch_ready"
        assert world.entry("root/w1")["state"] == "patch_ready"

        recover = subprocess.Popen([sys.executable, str(WRITER), "--repo-root", str(world.repo()), "recover"],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=ENV)
        time.sleep(1.5)  # unguarded, recover would be done and the snapshot restored well before this
        assert recover.poll() is None, "recover must wait for the scope locks held by the applying integrate"
        assert tree_state(world.repo()) == applied
        gate.write_text("go")
        assert integrate.wait() == 0 and recover.wait() == 0
        assert tree_state(world.repo()) == applied, "the applied patch must still be there"
        assert world.entry("root/w1")["state"] == "integrated", "ledger and tree agree"
        assert not journals(world) and json.loads(recover.stdout.read())["journals"] == []
    finally:
        world.close()


def test_a_journal_whose_target_directory_is_gone_is_cleared_with_a_note() -> None:
    world = World()
    try:
        directory = world.task / ".agent-routing/journals"
        directory.mkdir(parents=True)
        (directory / "root~ghost.json").write_text(json.dumps({
            "agentPath": "root/ghost", "target": str(world.tmp / "gone"), "snapshotTree": "0" * 40, "candidate": "0" * 40,
            "affected": ["src/a/x.ts"], "scopes": ["src/a"], "startedAt": "now"}))
        report = json.loads(ok(world.w("recover"), "recover").stdout)
        assert report["journals"][0]["rollback"] == "ok" and "gone" in report["journals"][0]["note"]
        assert not journals(world), "not reported as `rollback failed` forever"
    finally:
        world.close()


# ============================================================================================
# cancel, stale-lease recovery, cleanup
# ============================================================================================

def test_cancel() -> None:
    world, p_tree, c_tree = nested_world()
    try:
        refused(world.w("cancel", "--agent-path", "root/p/c", tree=p_tree), "cancel with a live descendant")
        ok(world.w("cancel", "--agent-path", "root/p/c/g", tree=c_tree), "cancel the grandchild")
        entry = world.entry("root/p/c/g")
        assert entry["state"] == "failed" and entry["failedHop"]["phase"] == "cancel"
        assert not world.checkout("root/p/c/g").exists() and not world.recovery("root/p/c/g").exists(), \
            "cancel removes the checkout and keeps no recovery bundle"
        assert world.ownership("check-write", "--agent-path", "root/p/c", "src/a/deep/z.ts").returncode == 0, \
            "a cancelled child hands its scope back"
        refused(world.w("cancel", "--agent-path", "root/p/c/g", tree=c_tree), "cancelling twice")
    finally:
        world.close()


def test_stale_lease_recovery_and_cleanup() -> None:
    world = World()
    try:
        ok(world.spawn("root/stale", "src/a", lease=1), "stale")
        ok(world.spawn("root/fresh", "docs"), "fresh")
        world.start("root/stale")
        world.start("root/fresh")
        stale_co = world.checkout("root/stale")
        (stale_co / "src/a/x.ts").write_text("unsubmitted work\n")
        time.sleep(1.3)
        refused(world.spawn("root/taker", "src/a"), "a stale reservation holds its scope until it is recovered")
        orphan = world.task / ".agent-routing/checkouts/unregistered"
        orphan.mkdir()
        (orphan / "keep.txt").write_text("not ours")

        report = json.loads(ok(world.w("recover"), "recover").stdout)
        assert [r["agentPath"] for r in report["recovered"]] == ["root/stale"]
        assert world.entry("root/fresh")["state"] == "active", "a live lease is left alone"
        entry = world.entry("root/stale")
        assert entry["state"] == "failed" and entry["failedHop"]["phase"] == "recover"
        assert "unsubmitted work" in (world.recovery("root/stale") / "_patch.diff").read_text(), "salvaged before cleanup"
        assert not stale_co.exists() and str(stale_co) not in git(world.repo(), "worktree", "list")
        assert report["orphans"] == [str(orphan)] and (orphan / "keep.txt").exists(), "unregistered paths are reported, never deleted"
        ok(world.spawn("root/taker", "src/a"), "the scope is free after recovery")

        # forced recovery of a known crash; a writer with a live child is skipped, not torn down
        ok(world.w("recover", "--agent-path", "root/fresh"), "forced recover")
        assert world.entry("root/fresh")["state"] == "failed"
    finally:
        world.close()

    world, p_tree, c_tree = nested_world()
    try:
        report = json.loads(ok(world.w("recover", "--agent-path", "root/p"), "recover parent").stdout)
        assert report["skipped"] == ["root/p"] and world.entry("root/p")["state"] == "active"
    finally:
        world.close()


def test_cleanup_refuses_paths_outside_the_registry() -> None:
    world = World()
    try:
        ok(world.spawn("root/w1", "src/a"), "w1")
        world.start("root/w1")
        victim = world.tmp / "not-a-checkout"
        victim.mkdir()
        (victim / "precious.txt").write_text("keep")
        document = world.ledger()
        document["entries"][0]["checkout"] = str(victim)
        world.save_ledger(document)
        ok(world.w("cancel", "--agent-path", "root/w1"), "cancel")
        entry = world.entry("root/w1")
        assert entry["cleanup"] == "failed" and "outside" in entry["cleanupError"]
        assert (victim / "precious.txt").read_text() == "keep"
    finally:
        world.close()


# ============================================================================================
# No shared-tree writer path remains
# ============================================================================================

def test_no_shared_tree_writer_mode() -> None:
    assert sorted(p.name for p in SKILL.iterdir() if p.name != "__pycache__") == ["SKILL.md", "ownership.py", "writer.py"]
    skill = (SKILL / "SKILL.md").read_text()
    assert "siblings-quiesced" not in skill and "shared worktree" not in skill.lower().replace("never works in the canonical", "")
    for command in ("verify", "state", "reserve"):  # the old ledger CLI that scanned a shared tree
        assert run(sys.executable, str(OWNERSHIP), "--task-dir", "/nonexistent", command).returncode == 2
    help_text = run(sys.executable, str(OWNERSHIP), "--help").stdout
    assert "verify" not in help_text and "siblings" not in help_text
    sys.path.insert(0, str(SKILL))
    import ownership  # noqa: E402
    assert "completed" not in ownership.STATES and ownership.STATES == ("reserved", "active", "patch_ready", "integrated", "failed")

    world = World()
    try:
        ok(world.spawn("root/w1", "src/a"), "w1")
        entry = world.entry("root/w1")
        assert Path(entry["checkout"]) != world.repo() and ".agent-routing/checkouts" in entry["checkout"]
        # a non-writer parent cannot hand out the canonical tree from inside someone's checkout either
        refused(world.spawn("root/w2", "docs", tree=world.checkout("root/w1")), "spawn from a foreign checkout")
        assert not (world.task / ".agent-routing/checkouts/root~w2").exists()
    finally:
        world.close()


TESTS = [value for name, value in sorted(globals().items()) if name.startswith("test_") and callable(value)]

if __name__ == "__main__":
    for test in TESTS:
        started = time.time()
        test()
        print(f"ok  {test.__name__} ({time.time() - started:.1f}s)")
    print(f"routing writer: {len(TESTS)} scenarios ok")
