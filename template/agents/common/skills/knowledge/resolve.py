#!/usr/bin/env python3
"""Resolve the manifest-owned authored knowledge directory, never a mirror."""

import argparse
import json
from pathlib import Path
import sys


def relative_root(value):
    if not isinstance(value, str) or not value or "\\" in value:
        raise ValueError("knowledgeRoot must be a nonempty relative POSIX path")
    path = Path(value)
    if path.is_absolute() or ".." in path.parts or path == Path("."):
        raise ValueError(f"unsafe knowledgeRoot: {value!r}")
    return path.as_posix()


def resolve(workspace, task_dir=None, allow_missing=False):
    workspace = Path(workspace)
    manifest = json.loads((workspace / "repos.json").read_text())
    mirror = manifest.get("notionSnapshotRepo")
    hits, missing = [], []
    for name in manifest.get("always", []):
        if not isinstance(name, str) or Path(name).name != name or name in (".", ".."):
            raise ValueError(f"unsafe repository name: {name!r}")
        if name == mirror:
            # The machine-generated Notion mirror is never authored knowledge,
            # even when it sits in `always` with its own knowledge/ directory.
            continue
        entry = manifest["repos"][name]
        root = relative_root(entry.get("knowledgeRoot", "knowledge"))
        checkout = Path(task_dir) / name if task_dir else workspace / "packages" / name
        marker = checkout / root
        if checkout.exists():
            if marker.resolve() == checkout.resolve() or not marker.resolve().is_relative_to(checkout.resolve()):
                raise ValueError(f"knowledgeRoot escapes checkout: {name}/{root}")
            if marker.is_dir():
                hits.append({"repo": name, "root": root, "url": entry.get("url", ""),
                             "checkout": str(checkout)})
            elif "knowledgeRoot" in entry:
                raise ValueError(f"configured knowledge directory is missing: {marker}")
        elif allow_missing:
            spec_root = entry.get("specRoot", "")
            if "knowledgeRoot" in entry or spec_root == "knowledge" or spec_root.startswith("knowledge/"):
                hits.append({"repo": name, "root": root, "url": entry.get("url", ""),
                             "checkout": str(checkout)})
        else:
            missing.append(name)
    if missing:
        raise ValueError("always checkouts not inspected: " + ", ".join(missing))
    if len(hits) != 1:
        raise ValueError("expected exactly one knowledge repository; found: " +
                         (", ".join(h["repo"] for h in hits) or "none"))
    return hits[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("--task-dir", type=Path)
    parser.add_argument("--allow-missing", action="store_true",
                        help="manifest-only inspection for lint, never authoring")
    args = parser.parse_args()
    try:
        print(json.dumps(resolve(args.workspace, args.task_dir, args.allow_missing)))
    except (ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
