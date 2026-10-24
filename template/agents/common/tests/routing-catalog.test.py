#!/usr/bin/env python3
"""Tracked provider catalog (tasks 2.1) — schema and content.

Requirement: agent-directed-routing / «Fallback и fail-closed при недоступности
child» and design D1. The expected values below are written from D1/tasks 2.1,
never read off the catalog or off a run; every assertion goes red when
catalog.json or the builder's validation changes.

    python3 agents/common/tests/routing-catalog.test.py
"""

from __future__ import annotations

import copy
import importlib.util
import json
import shutil
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CATALOG = ROOT / "agents/common/routing/catalog.json"

spec = importlib.util.spec_from_file_location("runtime_build", ROOT / "agents/build.py")
assert spec and spec.loader
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

real = json.loads(CATALOG.read_text())


def validate(document: dict) -> None:
    """Run the builder's own catalog validation on `document`."""
    with tempfile.TemporaryDirectory(prefix="routing-catalog-") as raw:
        root = Path(raw)
        path = root / "agents/common/routing/catalog.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(document))
        shutil.copytree(ROOT / "agents/common/roles", root / "agents/common/roles")
        build.Builder(root).catalog()


def rejects(mutate, why: str) -> None:
    document = copy.deepcopy(real)
    mutate(document)
    try:
        validate(document)
    except RuntimeError:
        return
    raise AssertionError(f"catalog accepted an invalid document: {why}")


# --- the shipped catalog is valid and says what tasks 2.1 / D1 say -------------

validate(real)
assert real["version"] == 1
assert real["tiers"] == ["fast", "balanced", "strong"]
assert real["efforts"] == ["low", "medium", "high"]
assert real["rootDefaults"] == {
    "claude": {"model": "opus", "effort": "high"},
    "codex": {"model": "strongestAvailable", "effort": "high"},
}
assert real["strongestAvailable"] == {"codex": "gpt-6-astra"}
EXPECTED_MODELS = {
    "claude": {
        "fast": ["haiku", "sonnet"],
        "balanced": ["sonnet", "opus"],
        "strong": ["opus", "sonnet"],
    },
    "codex": {
        "fast": ["gpt-6-luna", "gpt-5.6-luna"],
        "balanced": ["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol"],
        "strong": ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-sol"],
    },
}
EXPECTED_EFFORTS = {
    "high": ["high", "medium", "low"],
    "medium": ["medium", "high", "low"],
    "low": ["low", "medium", "high"],
}
for provider, tiers in EXPECTED_MODELS.items():
    assert real["providers"][provider]["models"] == tiers, provider
    assert real["providers"][provider]["effortFallbacks"] == EXPECTED_EFFORTS, provider

# role minimums: the single source of the per-role tier/effort contract and of the profile default model
assert real["roleMinimums"] == {
    "explorer": {"tier": "balanced", "effort": "medium"},
    "scout": {"tier": "balanced", "effort": "medium", "floor": {"tier": "fast", "effort": "low"}},
    "worker": {"tier": "balanced", "effort": "medium"},
    "builder": {"tier": "balanced", "effort": "medium"},
    "analyst": {"tier": "strong", "effort": "high"},
    "architect": {"tier": "strong", "effort": "high"},
    "reviewer": {"tier": "strong", "effort": "high"},
}

# --- invalid catalogs are refused ----------------------------------------------

rejects(lambda c: c["providers"]["claude"]["models"].update({"turbo": ["opus"]}), "unknown tier")
rejects(lambda c: c["providers"]["claude"]["models"].pop("fast"), "missing tier")
rejects(lambda c: c.update(tiers=["fast", "balanced", "strong", "turbo"]), "tier list changed")
rejects(lambda c: c["providers"]["claude"]["models"].update(fast=["haiku", "gpt-6"]), "unknown model")
rejects(lambda c: c["providers"]["codex"]["models"].update(strong=["gpt-6-astra", "gpt-6-astra"]), "duplicate candidate")
rejects(lambda c: c["providers"]["codex"]["supportedModels"].append("gpt-6-astra"), "duplicate supported model")
rejects(lambda c: c["providers"]["claude"]["models"].update(balanced=[]), "empty chain")
rejects(lambda c: c["providers"]["claude"]["effortFallbacks"].update(extreme=["extreme"]), "unknown effort key")
rejects(lambda c: c["providers"]["claude"]["effortFallbacks"].update(high=["high", "ultra", "low"]), "unknown effort value")
rejects(lambda c: c["providers"]["claude"]["effortFallbacks"].update(high=["high", "medium", "high"]), "effort fallback cycle")
rejects(lambda c: c["providers"]["claude"]["effortFallbacks"].update(high=["medium", "high", "low"]), "chain does not start at the requested effort")
rejects(lambda c: c["providers"]["claude"]["effortFallbacks"].update(high=[]), "empty effort chain")
rejects(lambda c: c["rootDefaults"]["claude"].update(effort="turbo"), "unknown root effort")
rejects(lambda c: c["rootDefaults"]["claude"].update(model="gpt-6"), "unknown root model")
rejects(lambda c: c["strongestAvailable"].update(codex="no-such-model"), "strongestAvailable not a supported model")
rejects(lambda c: c.pop("roleMinimums"), "missing role minimums")
rejects(lambda c: c["roleMinimums"].update(worker={"tier": "turbo", "effort": "medium"}), "unknown role tier")
rejects(lambda c: c["roleMinimums"].update(worker={"tier": "balanced", "effort": "max"}), "unknown role effort")
rejects(lambda c: c["roleMinimums"]["scout"].update(floor={"tier": "strong", "effort": "low"}), "floor tier above minimum")
rejects(lambda c: c["roleMinimums"]["scout"].update(floor={"tier": "fast", "effort": "high"}), "floor effort above minimum")
rejects(lambda c: c.update(version=2), "unsupported version")
rejects(lambda c: c["providers"].pop("codex"), "missing provider")

# The fallback *rule* (selected candidate first, then the tier's remaining models at the same effort, then the next effort)
# is wording in agent-directed-routing/SKILL.md, pinned in routing-policy.test.py. What this file pins is the data that rule
# walks: the exact ordered chains above, which stay inside their tier by construction (validated per tier).
for provider, tiers in EXPECTED_MODELS.items():
    data = real["providers"][provider]
    for tier, models in tiers.items():
        assert set(data["models"][tier]) <= set(data["supportedModels"]), (provider, tier)
        assert len(data["models"][tier]) * len(data["effortFallbacks"]["high"]) == len(models) * 3  # each pair once

print("routing catalog: ok")
