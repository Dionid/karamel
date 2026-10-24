"""Resolve authored knowledge while excluding a dedicated snapshot mirror."""

import importlib.util
import json
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[3]
module_spec = importlib.util.spec_from_file_location(
    "knowledge_resolve_manifest", ROOT / "agents/common/skills/knowledge/resolve.py")
resolver = importlib.util.module_from_spec(module_spec)
module_spec.loader.exec_module(resolver)

manifest = {'always': ['agent-workspace', 'team-knowledge', 'reference-store'], 'notionSnapshotRepo': 'reference-store', 'repos': {'product-docker-infra': {'branch': 'main', 'url': 'git@github.com:team/product-docker-infra.git'}, 'agent-workspace': {'branch': 'main'}, 'team-knowledge': {'branch': 'main', 'knowledgeRoot': 'projects/product/knowledge', 'specRoot': 'projects/product'}, 'reference-store': {'branch': 'main'}, 'platform': {'branch': 'main', 'specRoot': ''}}}

mirror = manifest.get("notionSnapshotRepo")

with tempfile.TemporaryDirectory() as scratch:
    task = Path(scratch)
    (task / "repos.json").write_text(json.dumps(manifest))
    for name in manifest["always"]:
        entry = manifest["repos"][name]
        checkout = task / name
        checkout.mkdir(parents=True)
        # Only materialize a knowledge-shaped directory for checkouts that
        # really carry one: the repo with an explicit knowledgeRoot (the
        # authored knowledge repository) and the Notion mirror (whose content
        # sits at the implicit default root "knowledge"). Every other always
        # checkout (e.g. agent-workspace) is simulated as present but bare, which
        # is what a real `wt new --pull` worktree looks like.
        if "knowledgeRoot" in entry or name == mirror:
            root = entry.get("knowledgeRoot", "knowledge")
            (checkout / root).mkdir(parents=True)

    route = resolver.resolve(task, task_dir=task)
    assert route["repo"] == "team-knowledge", (
        "expected the resolver to pick the authored knowledge repository "
        f"team-knowledge, got {route['repo']!r} — the Notion mirror in `always` "
        "is not being excluded from the authored-knowledge scan"
    )

print("knowledge resolve manifest: pass")
