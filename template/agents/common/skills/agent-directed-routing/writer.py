#!/usr/bin/env python3
"""Disposable writer checkouts, patch transport and per-hop atomic integration.

Every write-capable descendant gets its own checkout under
``worktrees/<task>/.agent-routing/checkouts/`` cut from an exact snapshot of its
immediate parent's tree. When it finishes, its result travels as a binary-safe
git patch plus a manifest, and the *immediate parent* integrates it into its own
tree with a compare-and-swap. A nested result climbs one hop at a time:
grandchild -> child checkout, child -> parent checkout, ... -> canonical task
worktree. A hop either applies completely or leaves its target (and therefore
every ancestor) byte-for-byte unchanged; a failed hop becomes ``failed`` with a
recovery bundle in ``.agent-routing/recovery/<agentPath>/``.

Reservation rules live in ``ownership.py``. Exit codes: 0 ok, 2 refused (nothing
changed), 3 hop failed (state=failed, bundle saved).
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import posixpath
import shutil
import subprocess
import sys
import tempfile
import time
from contextlib import ExitStack, contextmanager
from pathlib import Path, PurePosixPath
from typing import Any, Iterator

import ownership as ledger

ALLOWED_MODES = {"100644", "100755", "120000", "000000"}
PATCH, MANIFEST, FAILURE = "_patch.diff", "_manifest.json", "_failure.json"
IDENT = {
    "GIT_AUTHOR_NAME": "agent-routing", "GIT_AUTHOR_EMAIL": "agent-routing@localhost",
    "GIT_COMMITTER_NAME": "agent-routing", "GIT_COMMITTER_EMAIL": "agent-routing@localhost",
}
Entries = dict[str, "tuple[str, str] | None"]


class GitError(RuntimeError):
    pass


class HopFailure(Exception):
    """The hop cannot apply; ``phase`` is digest|scope|cas|apply|postcheck."""

    def __init__(self, phase: str, reason: str, rollback: str = "ok", dirty: list[str] | None = None) -> None:
        super().__init__(reason)
        self.phase = phase
        self.rollback = rollback  # "ok": target verified unchanged; "failed": see dirty
        self.dirty = dirty or []


# --- git primitives -------------------------------------------------------------------


def git(cwd: Path | str, *args: str, env: dict[str, str] | None = None, data: bytes | None = None) -> bytes:
    result = subprocess.run(["git", "-C", str(cwd), *args], input=data, capture_output=True, env=env)
    if result.returncode:
        raise GitError(f"git {' '.join(args[:3])} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


@contextmanager
def temp_index() -> Iterator[dict[str, str]]:
    with tempfile.TemporaryDirectory(prefix="agent-index.") as directory:
        yield {**os.environ, "GIT_INDEX_FILE": os.path.join(directory, "index")}


def worktree_tree(root: Path) -> str:
    """Tree object of the working tree (tracked + untracked, minus ignored), index untouched."""
    for attempt in range(3):
        try:
            with temp_index() as env:
                git(root, "read-tree", "HEAD", env=env)
                git(root, "add", "-A", env=env)
                return git(root, "write-tree", env=env).decode().strip()
        except GitError:
            if attempt == 2:
                raise
            time.sleep(0.2)
    raise AssertionError("unreachable")


def common_dir(root: Path) -> str:
    out = Path(git(root, "rev-parse", "--git-common-dir").decode().strip())
    return str(out if out.is_absolute() else (root / out).resolve())


def ls_tree(root: Path, tree: str) -> dict[str, tuple[str, str]]:
    result: dict[str, tuple[str, str]] = {}
    for record in git(root, "ls-tree", "-r", "-z", "--full-tree", tree).split(b"\0"):
        if record:
            meta, path = record.split(b"\t", 1)
            mode, _kind, sha = meta.decode().split()
            result[path.decode()] = (mode, sha)
    return result


def raw_diff(root: Path, old: str, new: str, renames: bool = True) -> list[dict[str, Any]]:
    out = git(root, "diff-tree", "-r", "-z", "--raw", "--no-abbrev", "-M" if renames else "--no-renames", old, new)
    parts = out.split(b"\0")
    entries, index = [], 0
    while index < len(parts) and parts[index]:
        old_mode, new_mode, old_sha, new_sha, status = parts[index].decode().lstrip(":").split()
        entry = {"status": status[0], "oldMode": old_mode, "newMode": new_mode, "oldSha": old_sha, "newSha": new_sha}
        if status[0] in "RC":
            entry["oldPath"], entry["path"] = parts[index + 1].decode(), parts[index + 2].decode()
            index += 3
        else:
            entry["path"] = parts[index + 1].decode()
            index += 2
        entries.append(entry)
    return entries


def tree_delta(root: Path, old: str, new: str) -> Entries:
    """path -> (mode, sha) after, or None when the path is gone, for every changed path."""
    return {
        e["path"]: None if e["status"] == "D" else (e["newMode"], e["newSha"])
        for e in raw_diff(root, old, new, renames=False)
    }


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".tmp.")
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


# --- paths ---------------------------------------------------------------------------------


def checkouts_dir(task: Path) -> Path:
    return ledger.routing_dir(task) / "checkouts"


def patches_dir(task: Path, agent_path: str) -> Path:
    return ledger.routing_dir(task) / "patches" / agent_path


def recovery_dir(task: Path, agent_path: str) -> Path:
    return ledger.routing_dir(task) / "recovery" / agent_path


def safe_path(path: Any) -> bool:
    if not isinstance(path, str) or not path or "\0" in path:
        return False
    parts = path.split("/")
    return all(p not in ("", ".", "..") and p.lower() != ".git" for p in parts)


# --- patch + manifest -------------------------------------------------------------------------


def build_patch(checkout: Path, snapshot_tree: str, out: Path, agent_path: str) -> dict[str, Any]:
    result_tree = worktree_tree(checkout)
    patch = git(
        checkout, "diff-tree", "-r", "-p", "--binary", "--full-index", "-M", "--no-ext-diff",
        "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", snapshot_tree, result_tree,
    )
    manifest = {
        "version": 1,
        "agentPath": agent_path,
        "baseTree": snapshot_tree,
        "resultTree": result_tree,
        "patchSha256": hashlib.sha256(patch).hexdigest(),
        "entries": raw_diff(checkout, snapshot_tree, result_tree),
    }
    atomic_write(out / PATCH, patch)
    atomic_write(out / MANIFEST, (json.dumps(manifest, indent=2) + "\n").encode())
    return manifest


def check_manifest(target: Path, entry: dict[str, Any], entries: list[dict[str, Any]], base: dict[str, tuple[str, str]]) -> None:
    outside = []
    for item in entries:
        paths = [item.get("path")] + ([item["oldPath"]] if "oldPath" in item else [])
        for path in paths:
            if not safe_path(path):
                raise HopFailure("scope", f"unsafe path (traversal or .git): {path!r}")
            if path == ".gitmodules" or any(base.get(prefix, ("",))[0] == "160000" for prefix in _prefixes(path)):
                raise HopFailure("scope", f"submodule boundary: {path}")
            if not any(ledger.scope_matches(path, s) for s in entry["scopes"]):
                outside.append(path)
        for mode in (item["oldMode"], item["newMode"]):
            if mode not in ALLOWED_MODES:
                raise HopFailure("scope", f"unsupported mode {mode} (submodule/tree entries are refused): {item['path']}")
        if item["newMode"] == "120000":
            link = git(target, "cat-file", "blob", item["newSha"]).decode(errors="replace")
            if link.startswith("/") or posixpath.normpath(posixpath.join(posixpath.dirname(item["path"]), link)).startswith(".."):
                raise HopFailure("scope", f"symlink escapes the repository: {item['path']} -> {link}")
    if outside:
        raise HopFailure("scope", "out-of-scope paths: " + ", ".join(sorted(set(outside))))


def _prefixes(path: str) -> list[str]:
    return [str(p) for p in PurePosixPath(path).parents if str(p) != "."]


def expectations(entries: list[dict[str, Any]]) -> tuple[Entries, Entries]:
    """(before, after) per affected path as the manifest claims; None means absent."""
    before: Entries = {}
    after: Entries = {}
    for item in entries:
        old = (item["oldMode"], item["oldSha"]) if item["status"] != "A" else None
        new = (item["newMode"], item["newSha"]) if item["status"] != "D" else None
        if item["status"] == "R":
            before[item["oldPath"]], after[item["oldPath"]] = old, None
            before[item["path"]], after[item["path"]] = None, new
        else:
            before[item["path"]], after[item["path"]] = old, new
    return before, after


def actual_entries(target: Path, base_tree: str, paths: list[str]) -> Entries:
    """What the target working tree holds at ``paths`` right now (hashed, index untouched)."""
    base = ls_tree(target, base_tree)
    present = [p for p in paths if os.path.lexists(target / p) or p in base]
    found: Entries = {p: None for p in paths}
    if not present:
        return found
    with temp_index() as env:
        git(target, "read-tree", base_tree, env=env)
        git(target, "--literal-pathspecs", "add", "-A", "--", *present, env=env)
        listing = git(target, "--literal-pathspecs", "ls-files", "-s", "-z", "--", *paths, env=env)
    for record in listing.split(b"\0"):
        if record:
            meta, path = record.split(b"\t", 1)
            mode, sha, _stage = meta.decode().split()
            found[path.decode()] = (mode, sha)
    return found


def scope_delta(target: Path, snapshot_tree: str, scopes: list[str]) -> Entries:
    """Paths under ``scopes`` whose working-tree state in ``target`` differs from the snapshot."""
    with temp_index() as env:
        git(target, "read-tree", snapshot_tree, env=env)
        for scope in scopes:
            try:
                git(target, "add", "-A", "--", scope, env=env)
            except GitError as error:
                if "did not match any files" not in str(error):
                    raise  # a scope with no files anywhere is simply unchanged
        tree = git(target, "write-tree", env=env).decode().strip()
    return tree_delta(target, snapshot_tree, tree)


def materialize(target: Path, tree: str, paths: list[str], ents: dict[str, tuple[str, str]]) -> None:
    """Make ``paths`` in the target working tree equal to ``tree`` (delete absent, check out present)."""
    for path in sorted((p for p in paths if p not in ents), key=len, reverse=True):
        full = target / path
        if os.path.lexists(full) and (full.is_symlink() or not full.is_dir()):
            full.unlink()
        parent = full.parent
        while parent != target:
            try:
                parent.rmdir()
            except OSError:
                break
            parent = parent.parent
    present = [p for p in paths if p in ents]
    if present:
        with temp_index() as env:
            git(target, "read-tree", tree, env=env)
            git(target, "checkout-index", "-f", "-z", "--stdin", env=env, data=b"\0".join(p.encode() for p in present) + b"\0")


@contextmanager
def scope_locks(task: Path, target: Path, scopes: list[str]) -> Iterator[None]:
    directory = ledger.routing_dir(task) / "locks"
    directory.mkdir(parents=True, exist_ok=True)
    with ExitStack() as stack:
        for scope in sorted(set(scopes)):
            name = hashlib.sha1(f"{target}\0{scope}".encode()).hexdigest()
            handle = stack.enter_context((directory / f"{name}.lock").open("a+"))
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def journal_path(task: Path, agent_path: str) -> Path:
    return ledger.routing_dir(task) / "journals" / (agent_path.replace("/", "~") + ".json")


def restore(target: Path, snapshot_tree: str, affected: list[str]) -> list[str]:
    """Put ``affected`` back to the snapshot content; returns paths still different (empty = clean). Never raises."""
    try:
        base = ls_tree(target, snapshot_tree)
    except Exception:
        return sorted(affected)
    try:
        materialize(target, snapshot_tree, affected, base)
    except Exception:
        pass
    try:
        now = actual_entries(target, snapshot_tree, affected)
        return sorted(p for p in affected if now[p] != base.get(p))
    except Exception:
        return sorted(affected)


class PostApplyError(ledger.Refused):
    """The tree was applied but the ledger write failed: the journal stays, so integrate/recover can still undo it."""


def rollback_locked(journal: dict[str, Any]) -> dict[str, Any]:
    """Undo an unconfirmed apply, touching only what that apply wrote (caller holds the scope locks).

    A path is rolled back only if its content is exactly what the apply wrote (the journal's candidate). Content that
    equals neither the snapshot nor the candidate belongs to someone else (a newer integration, an owner's edit) and is
    reported in ``skipped``, never overwritten. ``dirty`` lists paths that should have been restored and were not."""
    target = Path(journal["target"])
    if not target.is_dir():
        return {"dirty": [], "skipped": [], "note": f"target directory {target} is gone; journal cleared, nothing to restore"}
    affected = journal["affected"]
    try:
        base, candidate = ls_tree(target, journal["snapshotTree"]), ls_tree(target, journal["candidate"])
        current = actual_entries(target, journal["snapshotTree"], affected)
    except Exception as error:
        return {"dirty": sorted(affected), "skipped": [], "note": f"could not inspect the target: {error}"}
    ours = [p for p in affected if current[p] != base.get(p) and current[p] == candidate.get(p)]
    skipped = [p for p in affected if current[p] != base.get(p) and current[p] != candidate.get(p)]
    dirty = restore(target, journal["snapshotTree"], ours) if ours else []
    note = ("content changed since this apply, left untouched: " + ", ".join(skipped)) if skipped else None
    return {"dirty": dirty, "skipped": skipped, "note": note}


def rollback_journal(task: Path, agent_path: str, locked: bool = False) -> dict[str, Any] | None:
    """Undo an apply that was started and not confirmed. None: no journal. Else the rollback_locked report; the journal is
    removed unless paths are still dirty. ``locked``: the caller already holds the journal's scope locks."""
    path = journal_path(task, agent_path)
    try:
        journal = json.loads(path.read_text())
    except OSError:
        return None
    except json.JSONDecodeError:
        return {"dirty": ["<unreadable journal " + str(path) + ">"], "skipped": [], "note": None}
    if locked:
        report = rollback_locked(journal)
    else:
        with scope_locks(task, Path(journal["target"]), journal.get("scopes", [])):
            report = rollback_locked(journal)
    if not report["dirty"]:
        path.unlink(missing_ok=True)
    return report


def apply_hop(task: Path, entry: dict[str, Any], on_applied=lambda result: None) -> dict[str, Any]:
    """Verify and atomically integrate one agent's patch into its immediate parent's tree.

    ``on_applied(result)`` runs while the scope locks are still held, so a concurrent recover can never see an applied
    tree whose ledger entry is not yet written."""
    target = Path(entry["target"])
    patch_file = Path(entry["patchPath"])
    try:
        patch = patch_file.read_bytes()
        manifest = json.loads((patch_file.parent / MANIFEST).read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise HopFailure("digest", f"patch or manifest unreadable: {error}")
    digest = hashlib.sha256(patch).hexdigest()
    if not (
        digest == entry["patchSha256"] == manifest.get("patchSha256")
        and manifest.get("baseTree") == entry["snapshotTree"]
        and manifest.get("agentPath") == entry["agentPath"]
    ):
        raise HopFailure("digest", "patch digest, base snapshot or agent path does not match the ledger")
    entries = manifest.get("entries", [])
    if not entries:
        result = {"changedPaths": []}
        on_applied(result)
        return result
    base = ls_tree(target, entry["snapshotTree"])
    check_manifest(target, entry, entries, base)
    before, after = expectations(entries)
    affected = sorted(before)
    for path in affected:
        if base.get(path) != (tuple(before[path]) if before[path] else None):
            raise HopFailure("digest", f"manifest disagrees with the recorded snapshot at {path}")
    for path in affected:
        for prefix in _prefixes(path):
            if (target / prefix).is_symlink():
                raise HopFailure("scope", f"symlinked directory in target: {prefix}")

    with scope_locks(task, target, entry["scopes"]):
        stale = rollback_journal(task, entry["agentPath"], locked=True)  # an earlier apply died or failed to roll back
        if stale and stale["dirty"]:
            raise HopFailure("apply", "an earlier apply left the target dirty and could not be rolled back: " + ", ".join(stale["dirty"]), "failed", stale["dirty"])
        current = actual_entries(target, entry["snapshotTree"], affected)
        if all(current[p] == (tuple(after[p]) if after[p] else None) for p in affected):
            result = {"changedPaths": affected, "alreadyApplied": True}
            on_applied(result)
            return result
        # The whole reserved scope of the target must still equal the snapshot (tracked and
        # untracked): the child's own paths, and anything an ancestor wrote into a scope it had delegated.
        changed = scope_delta(target, entry["snapshotTree"], entry["scopes"])
        if changed:
            own = sorted(p for p in changed if p in before)
            foreign = sorted(p for p in changed if p not in before)
            parts = []
            if own:
                parts.append("target changed since the snapshot: " + ", ".join(own))
            if foreign:
                parts.append("ancestor wrote delegated path: " + ", ".join(foreign))
            raise HopFailure("cas", "; ".join(parts))
        with temp_index() as env:  # candidate = snapshot + patch, built without touching the target
            git(target, "read-tree", entry["snapshotTree"], env=env)
            applied = subprocess.run(
                ["git", "-C", str(target), "apply", "--cached", "--whitespace=nowarn", "-"],
                input=patch, env=env, capture_output=True,
            )
            if applied.returncode:
                raise HopFailure("cas", "patch does not apply: " + applied.stderr.decode(errors="replace").strip())
            candidate = git(target, "write-tree", env=env).decode().strip()
        want = {p: (tuple(after[p]) if after[p] else None) for p in affected}
        if tree_delta(target, entry["snapshotTree"], candidate) != want:
            raise HopFailure("postcheck", "candidate tree differs from the manifest")
        journal = journal_path(task, entry["agentPath"])  # written and fsynced before the first byte moves
        atomic_write(journal, json.dumps({
            "agentPath": entry["agentPath"], "target": str(target), "snapshotTree": entry["snapshotTree"],
            "candidate": candidate, "affected": affected, "scopes": entry["scopes"], "startedAt": ledger.now_iso(),
        }, indent=2).encode())
        try:
            materialize(target, candidate, affected, ls_tree(target, candidate))
            if actual_entries(target, entry["snapshotTree"], affected) != want:
                raise HopFailure("postcheck", "applied tree differs from the manifest")
        except BaseException as error:
            dirty = restore(target, entry["snapshotTree"], affected)  # back to the verified baseline
            if not dirty:
                journal.unlink(missing_ok=True)
            if isinstance(error, HopFailure):
                error.rollback, error.dirty = ("failed" if dirty else "ok"), dirty
                raise
            if isinstance(error, Exception):
                reason = f"{type(error).__name__}: {error}"
                raise HopFailure("apply", reason + (f"; rollback failed, dirty paths: {', '.join(dirty)}" if dirty else ""),
                                 "failed" if dirty else "ok", dirty) from error
            raise
        result = {"changedPaths": affected}
        on_applied(result)
    return result


# --- ledger-side helpers ---------------------------------------------------------------------


def cleanup_checkout(task: Path, entry: dict[str, Any]) -> None:
    """Remove only the registered checkout path; record whether it worked."""
    checkout = Path(entry["checkout"])
    try:
        checkout.resolve().relative_to(checkouts_dir(task).resolve())
    except ValueError:
        entry["cleanup"], entry["cleanupError"] = "failed", "checkout path is outside the checkouts directory"
        return
    common = entry["gitCommonDir"]
    if checkout.exists():
        removed = subprocess.run(["git", "--git-dir", common, "worktree", "remove", "--force", str(checkout)], capture_output=True)
        if removed.returncode:
            shutil.rmtree(checkout, ignore_errors=True)
    subprocess.run(["git", "--git-dir", common, "worktree", "prune"], capture_output=True)
    if checkout.exists():
        entry["cleanup"], entry["cleanupError"] = "failed", f"could not remove {checkout}"
    else:
        entry["cleanup"] = "done"
        entry.pop("cleanupError", None)


def record_violation(led: dict[str, Any], entry: dict[str, Any]) -> list[str]:
    """After a nested child ended without integrating, did its parent write into the delegated scope?"""
    parent = ledger.find(led, entry["parentPath"])
    if parent is None or parent["state"] not in ledger.LIVE:
        return []
    try:
        paths = sorted(scope_delta(Path(entry["target"]), entry["snapshotTree"], entry["scopes"]))
    except (GitError, OSError) as error:
        paths = [f"<delegated scope could not be verified: {error}>"]
    if paths:
        parent.setdefault("delegationViolations", []).append({
            "agentPath": entry["agentPath"], "snapshotTree": entry["snapshotTree"], "scopes": entry["scopes"],
            "paths": paths, "at": ledger.now_iso(),
        })
        parent["updatedAt"] = ledger.now_iso()
    return paths


def fail_locked(
    task: Path, led: dict[str, Any], agent_path: str, phase: str, reason: str, *, bundle: bool, salvage: bool = False,
    rollback: str = "ok", dirty: list[str] | None = None,
) -> dict[str, Any]:
    """Mark a live entry failed (caller holds the ledger lock and writes the ledger)."""
    entry = ledger.need(led, agent_path)
    violated = record_violation(led, entry)  # cancel, crash and every failure path, not only the scope-lock check
    if violated:
        reason += "; parent wrote delegated paths: " + ", ".join(violated)
    recovery = None
    if bundle:
        recovery = recovery_dir(task, agent_path)
        recovery.mkdir(parents=True, exist_ok=True)
        source = patches_dir(task, agent_path)
        if (source / PATCH).exists() and (source / MANIFEST).exists():
            shutil.copy2(source / PATCH, recovery / PATCH)
            shutil.copy2(source / MANIFEST, recovery / MANIFEST)
        elif salvage and Path(entry["checkout"]).exists():
            try:
                build_patch(Path(entry["checkout"]), entry["snapshotTree"], recovery, agent_path)
            except (GitError, OSError) as error:
                reason += f" (could not salvage the checkout: {error})"
        atomic_write(
            recovery / FAILURE,
            (json.dumps({"agentPath": agent_path, "parentPath": entry["parentPath"], "phase": phase, "reason": reason,
                         "target": entry["target"], "snapshotTree": entry["snapshotTree"], "rollback": rollback,
                         "dirtyPaths": dirty or [], "at": ledger.now_iso()}, indent=2) + "\n").encode(),
        )
    hop = {"from": agent_path, "to": entry["parentPath"], "target": entry["target"], "phase": phase, "reason": reason,
           "rollback": rollback, "dirtyPaths": dirty or []}
    ledger.transition(led, agent_path, "failed", failedHop=hop, recovery=str(recovery) if recovery else None)
    shutil.rmtree(patches_dir(task, agent_path), ignore_errors=True)
    cleanup_checkout(task, entry)
    return entry


@contextmanager
def open_ledger(task: Path, write: bool = True) -> Iterator[dict[str, Any]]:
    path = ledger.ledger_path(task)
    with ledger.locked(path):
        led = ledger.read_ledger(path)
        yield led
        if write:
            ledger.write_ledger(path, led)


def emit(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2))


# --- commands ---------------------------------------------------------------------------------


def cmd_spawn(args: argparse.Namespace, task: Path) -> int:
    target = ledger.repo_toplevel(args.repo_root)
    with open_ledger(task) as led:
        parent = ledger.find(led, args.parent_path)
        if parent is not None:
            if Path(parent["checkout"]).resolve() != target:
                raise ledger.Refused("a nested writer must be spawned from its parent's own checkout")
        elif ".agent-routing" in target.parts:
            raise ledger.Refused("spawn from the canonical checkout, or from the parent writer's own checkout")
        tracked = [p for p in git(target, "ls-files", "-z").decode().split("\0") if p]
        tree, head = worktree_tree(target), git(target, "rev-parse", "HEAD").decode().strip()
        checkout = checkouts_dir(task) / args.agent_path.replace("/", "~")
        entry = ledger.reserve(
            led, agent_path=args.agent_path, parent_path=args.parent_path, depth=args.depth, track=args.track,
            repo=parent["repo"] if parent else target.name, scopes=args.scope, parent_scopes=args.parent_scope,
            tracked=tracked, target=str(target), base_head=head, snapshot_tree=tree, checkout=str(checkout),
            git_common_dir=common_dir(target), lease_seconds=args.lease_seconds,
        )
        ledger.write_ledger(ledger.ledger_path(task), led)  # registered before anything is created
        try:
            commit = git(
                target, "-c", "commit.gpgsign=false", "commit-tree", tree, "-p", head, "-m", "agent-routing snapshot",
                env={**os.environ, **IDENT},
            ).decode().strip()
            checkout.parent.mkdir(parents=True, exist_ok=True)
            git(target, "worktree", "add", "--detach", "--quiet", str(checkout), commit)
            if worktree_tree(checkout) != tree:
                raise GitError("snapshot checkout differs from the parent tree (filters or attributes?)")
        except (GitError, OSError) as error:
            fail_locked(task, led, args.agent_path, "spawn", f"checkout creation failed: {error}", bundle=False)
            ledger.write_ledger(ledger.ledger_path(task), led)
            raise ledger.Refused(f"checkout creation failed: {error}")
    emit({k: entry[k] for k in ("agentPath", "state", "scopes", "target", "checkout", "snapshotTree", "baseHead")})
    return 0


def cmd_start(args: argparse.Namespace, task: Path) -> int:
    with open_ledger(task) as led:
        entry = ledger.need(led, args.agent_path)
        if not Path(entry["checkout"]).exists():
            raise ledger.Refused(f"checkout of {args.agent_path} is missing")
        ledger.transition(led, args.agent_path, "active", leaseExpiresAt=time.time() + entry["leaseSeconds"])
    print(f"{args.agent_path}: active")
    return 0


def cmd_submit(args: argparse.Namespace, task: Path) -> int:
    with open_ledger(task) as led:
        entry = ledger.need(led, args.agent_path)
        if entry["state"] != "active":
            raise ledger.Refused(f"cannot submit {args.agent_path} in state {entry['state']}")
        kids = ledger.live_children(led, args.agent_path)
        if kids:
            raise ledger.Refused("live descendants must be integrated or failed first: " + ", ".join(k["agentPath"] for k in kids))
        open_violations = []
        for violation in entry.get("delegationViolations", []):
            still = scope_delta(Path(entry["checkout"]), violation["snapshotTree"], violation["scopes"])
            if still:
                open_violations.append(f"{violation['agentPath']}: " + ", ".join(sorted(still)))
        if open_violations:
            raise ledger.Refused(
                "delegated scope was written during delegation; restore these paths to the child's snapshot "
                "content, or clear deliberately with `ownership.py clear-violation`: " + "; ".join(open_violations)
            )
        entry["delegationViolations"] = []  # all restored
        out = patches_dir(task, args.agent_path)
        manifest = build_patch(Path(entry["checkout"]), entry["snapshotTree"], out, args.agent_path)
        ledger.transition(
            led, args.agent_path, "patch_ready", patchPath=str(out / PATCH), patchSha256=manifest["patchSha256"],
            resultTree=manifest["resultTree"],
        )
    emit({"agentPath": args.agent_path, "state": "patch_ready", "patchSha256": manifest["patchSha256"],
          "changedPaths": [e["path"] for e in manifest["entries"]]})
    return 0


def cmd_integrate(args: argparse.Namespace, task: Path) -> int:
    with open_ledger(task, write=False) as led:
        entry = json.loads(json.dumps(ledger.need(led, args.agent_path)))
        if entry["state"] != "patch_ready":
            raise ledger.Refused(f"cannot integrate {args.agent_path} in state {entry['state']}")
    rollback, dirty = "ok", []

    def record(result: dict[str, Any]) -> None:  # runs under the scope locks, right after the tree was applied
        try:
            with open_ledger(task) as led:
                done = ledger.transition(led, args.agent_path, "integrated", appliedPaths=result["changedPaths"])
                shutil.rmtree(patches_dir(task, args.agent_path), ignore_errors=True)
                cleanup_checkout(task, done)
            journal_path(task, args.agent_path).unlink(missing_ok=True)  # only after the ledger says integrated
        except (OSError, ledger.Refused) as error:
            raise PostApplyError(f"applied, but the ledger could not record it ({error}); re-run integrate or recover") from error

    try:
        result = apply_hop(task, entry, record)
    except HopFailure as failure:
        phase, reason, rollback, dirty = failure.phase, str(failure), failure.rollback, failure.dirty
    except (GitError, OSError, KeyError, ValueError) as error:  # raised before anything was written
        phase, reason = "apply", f"{type(error).__name__}: {error}"
    else:
        emit({"agentPath": args.agent_path, "state": "integrated", **result})
        return 0
    with open_ledger(task) as led:
        failed = fail_locked(task, led, args.agent_path, phase, reason, bundle=True, rollback=rollback, dirty=dirty)
    emit({"agentPath": args.agent_path, "state": "failed", "failedHop": failed["failedHop"], "recovery": failed["recovery"]})
    return 3


def cmd_cancel(args: argparse.Namespace, task: Path) -> int:
    with open_ledger(task) as led:
        entry = ledger.need(led, args.agent_path)
        if entry["state"] not in ledger.LIVE:
            raise ledger.Refused(f"{args.agent_path} is already {entry['state']}")
        kids = ledger.live_children(led, args.agent_path)
        if kids:
            raise ledger.Refused("cancel live descendants first: " + ", ".join(k["agentPath"] for k in kids))
        fail_locked(task, led, args.agent_path, "cancel", "cancelled", bundle=False)
    print(f"{args.agent_path}: failed (cancelled)")
    return 0


def cmd_recover(args: argparse.Namespace, task: Path) -> int:
    report: dict[str, list[Any]] = {"recovered": [], "skipped": [], "cleaned": [], "orphans": []}
    forced = set(args.agent_path or [])
    report["journals"] = []
    journals = ledger.routing_dir(task) / "journals"
    for file in sorted(journals.glob("*.json")) if journals.exists() else []:
        try:
            journal = json.loads(file.read_text())
            agent = journal["agentPath"]
            target, scopes = Path(journal["target"]), journal.get("scopes", [])
        except (OSError, ValueError, KeyError):
            report["journals"].append({"journal": str(file), "rollback": "failed", "dirtyPaths": ["<unreadable journal>"]})
            continue
        with scope_locks(task, target, scopes):  # scope locks first, the ledger second: the order integrate uses
            with open_ledger(task, write=False) as led:
                owner = ledger.find(led, agent)
            if owner is not None and owner["state"] == "integrated":
                file.unlink(missing_ok=True)  # confirmed apply, only the cleanup was missed
                continue
            result = rollback_journal(task, agent, locked=True)
        if result is None:
            continue  # a concurrent integrate finished and removed it
        report["journals"].append({"agentPath": agent, "rollback": "failed" if result["dirty"] else "ok",
                                   "dirtyPaths": result["dirty"], "skippedPaths": result["skipped"], "note": result["note"]})
    with open_ledger(task) as led:
        stale = [
            e for e in led["entries"]
            if e["state"] in ledger.LIVE and (e["agentPath"] in forced or e["leaseExpiresAt"] < time.time())
        ]
        for entry in sorted(stale, key=lambda e: e["depth"], reverse=True):  # descendants first
            if ledger.live_children(led, entry["agentPath"]):
                report["skipped"].append(entry["agentPath"])
                continue
            reason = "forced recovery" if entry["agentPath"] in forced else "stale lease"
            done = fail_locked(task, led, entry["agentPath"], "recover", reason, bundle=True, salvage=True)
            report["recovered"].append({"agentPath": entry["agentPath"], "recovery": done["recovery"]})
        for entry in led["entries"]:
            if entry["state"] not in ledger.LIVE and entry.get("cleanup") != "done":
                cleanup_checkout(task, entry)
                if entry["cleanup"] == "done":
                    report["cleaned"].append(entry["agentPath"])
        registered = {Path(e["checkout"]).resolve() for e in led["entries"]}
        if checkouts_dir(task).exists():
            report["orphans"] = sorted(
                str(p) for p in checkouts_dir(task).iterdir() if p.resolve() not in registered
            )  # reported, never deleted: only registered paths are cleaned
    emit(report)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--task-dir", type=Path, help="worktrees/<task>; default derived from --repo-root")
    sub = parser.add_subparsers(dest="command", required=True)
    spawn = sub.add_parser("spawn", help="reserve a scope and cut the writer's checkout from this tree")
    spawn.add_argument("--agent-path", required=True)
    spawn.add_argument("--parent-path", required=True)
    spawn.add_argument("--depth", type=int, required=True)
    spawn.add_argument("--track", choices=("A", "P", "Q", "F", "C", "H", "I"), required=True)
    spawn.add_argument("--scope", action="append", default=[])
    spawn.add_argument("--parent-scope", action="append", default=[], help="group/parent scopes; required unless the parent is itself a ledger writer")
    spawn.add_argument("--lease-seconds", type=int, default=ledger.DEFAULT_LEASE_SECONDS)
    for name, text in (("start", "mark launched (reserved -> active)"), ("submit", "build patch+manifest (active -> patch_ready)"),
                       ("integrate", "apply the patch into the immediate parent's tree"), ("cancel", "drop a live writer without a bundle")):
        sub.add_parser(name, help=text).add_argument("--agent-path", required=True)
    recover = sub.add_parser("recover", help="salvage stale/forced writers, retry cleanups, list orphan checkouts")
    recover.add_argument("--agent-path", action="append", help="force recovery of this live writer (known crash)")
    args = parser.parse_args()
    handler = {"spawn": cmd_spawn, "start": cmd_start, "submit": cmd_submit, "integrate": cmd_integrate,
               "cancel": cmd_cancel, "recover": cmd_recover}[args.command]
    try:
        return handler(args, args.task_dir.resolve() if args.task_dir else ledger.task_dir(args.repo_root))
    except (OSError, ledger.Refused, GitError, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"agent writer refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
