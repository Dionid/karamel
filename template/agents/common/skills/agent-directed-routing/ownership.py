#!/usr/bin/env python3
"""Atomic write-scope reservation ledger for isolated child writers.

The ledger lives at ``worktrees/<task>/.agent-routing/ownership.json``, outside
every repo checkout. It only records who owns which paths and in which state a
writer is; checkout creation, patch transport and integration are done by
``writer.py`` in this directory. Every write-capable descendant owns a
disposable checkout, so the canonical task worktree is never a writer's cwd.

States: reserved -> active -> patch_ready -> integrated, any live state -> failed.
Live states (reserved|active|patch_ready) hold their scope exclusively. A nested
child may carve a strict subset out of its immediate parent's scope; the ledger
then marks ``delegatedTo`` on every ancestor, and those ancestors cannot write
the carved-out paths until the child is integrated or failed.
"""

from __future__ import annotations

import argparse
import fcntl
import fnmatch
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

VERSION = 2
STATES = ("reserved", "active", "patch_ready", "integrated", "failed")
LIVE = frozenset({"reserved", "active", "patch_ready"})
TRANSITIONS = {
    "reserved": {"active", "failed"},
    "active": {"patch_ready", "failed"},
    "patch_ready": {"integrated", "failed"},
    "integrated": set(),
    "failed": set(),
}
AGENT_PATH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$")
DEFAULT_LEASE_SECONDS = 6 * 3600


class Refused(Exception):
    """A reservation or ledger operation was refused; nothing was changed."""


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def git_out(cwd: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(cwd), *args], check=True, capture_output=True, text=True
    )
    return result.stdout


def repo_toplevel(path: Path) -> Path:
    return Path(git_out(path, "rev-parse", "--show-toplevel").strip()).resolve()


def task_dir(path: Path) -> Path:
    """``worktrees/<task>``: parent of the canonical checkout, or the part of a
    disposable checkout path that precedes ``.agent-routing``."""
    top = repo_toplevel(path)
    if ".agent-routing" in top.parts:
        return Path(*top.parts[: top.parts.index(".agent-routing")])
    return top.parent


def routing_dir(task: Path) -> Path:
    return task / ".agent-routing"


def ledger_path(task: Path) -> Path:
    return routing_dir(task) / "ownership.json"


# --- file lock and persistence -------------------------------------------------


@contextmanager
def locked(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.with_suffix(path.suffix + ".lock").open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield


def read_ledger(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": VERSION, "entries": []}
    document = json.loads(path.read_text())
    if document.get("version") != VERSION or not isinstance(document.get("entries"), list):
        raise Refused(f"unsupported ownership ledger (expected version {VERSION}): {path}")
    return document


def write_ledger(path: Path, document: dict[str, Any]) -> None:
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=".ownership.", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w") as stream:
            json.dump(document, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


# --- scopes ---------------------------------------------------------------------


def is_glob(scope: str) -> bool:
    return any(char in scope for char in "*?[")


def normalize_scope(scope: str) -> str:
    parts = Path(scope).parts
    if Path(scope).is_absolute() or ".." in parts or ".git" in parts or scope.startswith(":"):
        raise Refused(f"ownership scope must stay inside the repository: {scope}")
    normalized = Path(scope).as_posix().removeprefix("./").strip("/")
    if not normalized:
        raise Refused("repository-wide ownership is not allowed")
    return normalized


def scope_matches(path: str, scope: str) -> bool:
    scope = scope.strip("/")
    if is_glob(scope):
        return fnmatch.fnmatchcase(path, scope)
    return path == scope or path.startswith(scope + "/")


def scope_prefix(scope: str) -> str:
    """Fixed directory a glob claims for new paths; a literal scope is its own prefix."""
    if not is_glob(scope):
        return scope.rstrip("/")
    before = scope[: min(scope.find(char) for char in "*?[" if char in scope)]
    if before.endswith("/"):
        return before.rstrip("/")
    return before.rsplit("/", 1)[0] if "/" in before else ""


def expand_scopes(tracked: list[str], scopes: list[str]) -> list[str]:
    """Tracked files a scope set covers right now (globs and directories)."""
    return sorted({path for path in tracked if any(scope_matches(path, s) for s in scopes)})


def _nested(left: str, right: str) -> bool:
    return not left or not right or left == right or left.startswith(right + "/") or right.startswith(left + "/")


def scopes_overlap(left: list[str], right: list[str]) -> bool:
    for a in left:
        for b in right:
            if scope_matches(a, b) or scope_matches(b, a):
                return True
            if (is_glob(a) or is_glob(b)) and _nested(scope_prefix(a), scope_prefix(b)):
                return True
    return False


def covered_by(scopes: list[str], tracked: list[str], parent_scopes: list[str]) -> bool:
    """Every path a child scope can name lies inside the parent scopes."""
    candidates: list[str] = []
    for scope in scopes:
        if is_glob(scope):
            # a glob may also create new names under its fixed directory
            prefix = scope_prefix(scope)
            candidates.append(f"{prefix}/__new__" if prefix else "__new__")
            candidates.extend(path for path in tracked if scope_matches(path, scope))
        else:
            candidates.append(scope)
    return all(any(scope_matches(c, p) for p in parent_scopes) for c in candidates)


# --- ledger queries ---------------------------------------------------------------


def find(ledger: dict[str, Any], agent_path: str) -> dict[str, Any] | None:
    found = [e for e in ledger["entries"] if e["agentPath"] == agent_path]
    return found[0] if found else None


def need(ledger: dict[str, Any], agent_path: str) -> dict[str, Any]:
    entry = find(ledger, agent_path)
    if entry is None:
        raise Refused(f"no reservation for {agent_path}")
    return entry


def ancestors(ledger: dict[str, Any], entry: dict[str, Any]) -> list[dict[str, Any]]:
    chain: list[dict[str, Any]] = []
    parent = find(ledger, entry["parentPath"])
    while parent is not None:
        chain.append(parent)
        parent = find(ledger, parent["parentPath"])
    return chain


def live_children(ledger: dict[str, Any], agent_path: str) -> list[dict[str, Any]]:
    return [e for e in ledger["entries"] if e["parentPath"] == agent_path and e["state"] in LIVE]


def live_delegations(ledger: dict[str, Any], entry: dict[str, Any]) -> list[dict[str, Any]]:
    result = []
    for delegation in entry.get("delegatedTo", []):
        child = find(ledger, delegation["agentPath"])
        if child is not None and child["state"] in LIVE:
            result.append(delegation)
    return result


def writable(ledger: dict[str, Any], agent_path: str, path: str) -> tuple[bool, str]:
    entry = need(ledger, agent_path)
    if entry["state"] != "active":
        return False, f"{agent_path} is {entry['state']}, not active"
    if not any(scope_matches(path, s) for s in entry["scopes"]):
        return False, f"{path} is outside the scope of {agent_path}"
    for delegation in live_delegations(ledger, entry):
        if any(scope_matches(path, s) for s in delegation["scopes"]):
            return False, f"{path} is delegated to {delegation['agentPath']} until it is integrated or failed"
    return True, "ok"


# --- mutations (callers hold the ledger lock) ----------------------------------------


def reserve(
    ledger: dict[str, Any],
    *,
    agent_path: str,
    parent_path: str,
    depth: int,
    track: str,
    repo: str,
    scopes: list[str],
    parent_scopes: list[str],
    tracked: list[str],
    target: str,
    base_head: str,
    snapshot_tree: str,
    checkout: str,
    git_common_dir: str,
    lease_seconds: int = DEFAULT_LEASE_SECONDS,
) -> dict[str, Any]:
    """Add a reservation or raise Refused; the ledger is only changed on success."""
    if not AGENT_PATH.match(agent_path):
        raise Refused(f"agent path must be slash-separated [A-Za-z0-9._-] components: {agent_path}")
    if find(ledger, agent_path) is not None:
        raise Refused(f"agent path already has a reservation (use a new path to re-dispatch): {agent_path}")
    scopes = [normalize_scope(s) for s in scopes]
    if not scopes:
        raise Refused("at least one --scope is required")
    expanded = expand_scopes(tracked, scopes)

    parent = find(ledger, parent_path)
    chain: list[dict[str, Any]] = []
    if parent is not None:
        if parent["state"] != "active":
            raise Refused(f"parent {parent_path} is {parent['state']}; only an active writer can carve out a scope")
        if not covered_by(scopes, tracked, parent["scopes"]):
            raise Refused("nested child scope must be contained in its immediate parent's scope")
        if sorted(set(scopes)) == sorted(set(parent["scopes"])) or (
            expanded and expanded == parent["expandedScopes"]
        ):
            raise Refused("nested carve-out must be a strict subset of the parent's scope")
        chain = [parent, *ancestors(ledger, parent)]
    else:
        parent_scopes = [normalize_scope(s) for s in parent_scopes]
        if not parent_scopes or not covered_by(scopes, tracked, parent_scopes):
            raise Refused("child ownership must be contained by parent/group scopes (--parent-scope)")

    skip = {a["agentPath"] for a in chain}
    for other in ledger["entries"]:
        if (
            other["state"] in LIVE
            and other["agentPath"] not in skip
            and other.get("gitCommonDir") == git_common_dir  # same repository only
            and scopes_overlap(scopes, other["scopes"])
        ):
            raise Refused(f"ownership overlaps live writer {other['agentPath']} ({other['state']})")

    entry = {
        "agentPath": agent_path,
        "parentPath": parent_path,
        "depth": depth,
        "track": track,
        "repo": repo,
        "scopes": scopes,
        "expandedScopes": expanded,
        "state": "reserved",
        "target": target,
        "baseHead": base_head,
        "snapshotTree": snapshot_tree,
        "checkout": checkout,
        "gitCommonDir": git_common_dir,
        "cleanup": "pending",
        "delegatedTo": [],
        "delegationViolations": [],
        "leaseSeconds": lease_seconds,
        "leaseExpiresAt": time.time() + lease_seconds,
        "createdAt": now_iso(),
        "updatedAt": now_iso(),
    }
    for ancestor in chain:
        ancestor["delegatedTo"].append({"agentPath": agent_path, "scopes": scopes})
        ancestor["updatedAt"] = now_iso()
    ledger["entries"].append(entry)
    return entry


def transition(ledger: dict[str, Any], agent_path: str, state: str, **fields: Any) -> dict[str, Any]:
    entry = need(ledger, agent_path)
    if state not in TRANSITIONS[entry["state"]]:
        raise Refused(f"invalid state transition {entry['state']} -> {state} for {agent_path}")
    entry["state"] = state
    entry.update(fields)
    entry["updatedAt"] = now_iso()
    return entry


def clear_violations(ledger: dict[str, Any], agent_path: str) -> int:
    """Deliberate operator step: accept the paths a parent wrote into a delegated scope."""
    entry = need(ledger, agent_path)
    count = len(entry.get("delegationViolations", []))
    entry["delegationViolations"] = []
    entry["updatedAt"] = now_iso()
    return count


# --- CLI ---------------------------------------------------------------------------------


def _task(args: argparse.Namespace) -> Path:
    return args.task_dir.resolve() if args.task_dir else task_dir(args.repo_root)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", type=Path, default=Path.cwd())
    parser.add_argument("--task-dir", type=Path, help="worktrees/<task>; default derived from --repo-root")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("show", help="print the ledger")
    check = sub.add_parser("check-write", help="exit 0 only if the active writer may write PATH now")
    check.add_argument("--agent-path", required=True)
    check.add_argument("path", nargs="+")
    beat = sub.add_parser("heartbeat", help="extend the lease of a live writer")
    beat.add_argument("--agent-path", required=True)
    clear = sub.add_parser("clear-violation", help="operator: accept paths a writer wrote into a scope it had delegated")
    clear.add_argument("--agent-path", required=True)
    args = parser.parse_args()
    try:
        path = ledger_path(_task(args))
        with locked(path):
            ledger = read_ledger(path)
            if args.command == "show":
                print(json.dumps(ledger, ensure_ascii=False, indent=2))
            elif args.command == "check-write":
                refusals = []
                for candidate in args.path:
                    ok, reason = writable(ledger, args.agent_path, normalize_scope(candidate))
                    if not ok:
                        refusals.append(reason)
                if refusals:
                    raise Refused("; ".join(refusals))
                print("ok")
            elif args.command == "clear-violation":
                print(f"{args.agent_path}: cleared {clear_violations(ledger, args.agent_path)} violation(s)")
                write_ledger(path, ledger)
            else:
                entry = need(ledger, args.agent_path)
                if entry["state"] not in LIVE:
                    raise Refused(f"{args.agent_path} is {entry['state']}")
                entry["leaseExpiresAt"] = time.time() + entry["leaseSeconds"]
                write_ledger(path, ledger)
                print(f"{args.agent_path}: lease extended")
    except (OSError, Refused, subprocess.CalledProcessError, json.JSONDecodeError) as error:
        print(f"agent ownership refused: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
