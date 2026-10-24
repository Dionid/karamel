"""Exercise project roots, legacy discovery, and unsafe/ambiguous authoring."""

import importlib.util
import json
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[3]
module_spec = importlib.util.spec_from_file_location(
    "knowledge_checkout", ROOT / "agents/common/skills/knowledge/resolve.py")
resolver = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(resolver)


def rejects(action, reason):
    try:
        action()
    except ValueError as error:
        assert reason in str(error), str(error)
    else:
        raise AssertionError(f"expected refusal: {reason}")


with tempfile.TemporaryDirectory() as scratch:
    ws = Path(scratch)
    manifest = {"always": ["harness", "store", "mirror"], "repos": {
        "harness": {}, "store": {"knowledgeRoot": "projects/pay/knowledge"},
        "mirror": {}},
        "notionSnapshotRepo": "mirror"}

    def save():
        (ws / "repos.json").write_text(json.dumps(manifest))

    save()
    (ws / "packages/harness").mkdir(parents=True)
    store = ws / "packages/store"
    (store / "projects/pay/knowledge/facts").mkdir(parents=True)
    # The Notion mirror is an `always` checkout too (matching production,
    # where notionSnapshotRepo names a repository in `always`) and has its own
    # default-rooted knowledge/ directory; an unrelated root-level knowledge
    # tree also sits inside `store`. Neither overrides the configured project
    # root: the mirror is excluded by name via notionSnapshotRepo, and
    # `store`'s own extraneous knowledge/ is simply not the configured
    # knowledgeRoot path.
    (ws / "packages/mirror/knowledge").mkdir(parents=True)
    (store / "knowledge").mkdir()
    route = resolver.resolve(ws)
    assert route["repo"] == "store" and route["root"] == "projects/pay/knowledge"
    task = ws / "worktrees/task"
    (task / "harness").mkdir(parents=True)
    (task / "store/projects/pay/knowledge").mkdir(parents=True)
    assert resolver.resolve(ws, task)["checkout"] == str(task / "store")
    (task / "store/projects/pay/knowledge").rmdir()
    rejects(lambda: resolver.resolve(ws, task), "configured knowledge directory is missing")

    for unsafe in ("/tmp/knowledge", "../knowledge", "projects/../knowledge", "", "./", None, 7, "a\\b"):
        manifest["repos"]["store"]["knowledgeRoot"] = unsafe
        save()
        rejects(lambda: resolver.resolve(ws), "knowledgeRoot")
    manifest["repos"]["store"]["knowledgeRoot"] = "projects/pay/knowledge"
    save()
    outside = ws / "outside"
    outside.mkdir()
    link = store / "escape"
    link.symlink_to(outside)
    manifest["repos"]["store"]["knowledgeRoot"] = "escape"
    save()
    rejects(lambda: resolver.resolve(ws), "escapes checkout")

    # An explicit dot selects the checkout itself, never a new knowledge/ child.
    manifest["repos"]["store"]["knowledgeRoot"] = "."
    save()
    assert resolver.resolve(ws)["root"] == "."
    assert resolver.resolve(ws, task)["checkout"] == str(task / "store")
    # Only explicit '.' permits equality; a symlink alias cannot disguise it.
    (store / "self").symlink_to(store, target_is_directory=True)
    manifest["repos"]["store"]["knowledgeRoot"] = "self"
    save()
    rejects(lambda: resolver.resolve(ws), "escapes checkout")

    # The old convention remains valid without knowledgeRoot.
    manifest["repos"]["store"].pop("knowledgeRoot")
    save()
    assert resolver.resolve(ws)["root"] == "knowledge"
    (ws / "packages/harness/knowledge").mkdir()
    rejects(lambda: resolver.resolve(ws), "exactly one")
    (ws / "packages/harness/knowledge").rmdir()
    (store / "knowledge").rmdir()
    rejects(lambda: resolver.resolve(ws), "found: none")
    manifest["always"].append("uncloned")
    manifest["repos"]["uncloned"] = {}
    save()
    rejects(lambda: resolver.resolve(ws), "not inspected")
    # Inspection-only lint can find a configured project before clone; authoring
    # must still fail until every always checkout has actually been inspected.
    manifest = {"always": ["new"], "repos": {
        "new": {"knowledgeRoot": "projects/pay/knowledge"}}}
    save()
    assert resolver.resolve(ws, allow_missing=True)["repo"] == "new"
    rejects(lambda: resolver.resolve(ws), "not inspected")
    manifest["repos"]["new"]["knowledgeRoot"] = "."
    save()
    assert resolver.resolve(ws, allow_missing=True)["root"] == "."
    rejects(lambda: resolver.resolve(ws), "not inspected")

print("knowledge checkout: pass")
