#!/usr/bin/env python3
"""Generated runtime defaults and role profiles (tasks 2.2 and 2.3).

Requirements: agent-directed-routing / «Сильный default основной модели и
явные переопределения», «Parent выбирает роль, модель и effort каждого child»,
«Нативный предел конкурентности»; design D1 (override layers) and D2 (profiles).
Expected values are taken from tasks.md 2.2/2.3 and design D1/D2. Every assertion
reads a real artefact (catalog, generated settings/config, role files, SKILL.md).

    python3 agents/common/tests/routing-build.test.py
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import shutil
import subprocess
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

spec = importlib.util.spec_from_file_location("runtime_build", ROOT / "agents/build.py")
assert spec and spec.loader
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

ENV_NAMES = ("CLAUDE_DEFAULT_MODEL", "CLAUDE_DEFAULT_EFFORT", "CODEX_DEFAULT_MODEL", "CODEX_DEFAULT_EFFORT")
for name in ENV_NAMES:
    os.environ.pop(name, None)  # the host's own overrides must not leak into the baseline

CATALOG = json.loads((ROOT / "agents/common/routing/catalog.json").read_text())
EFFORTS = ("low", "medium", "high")
CAPABILITIES = ("terminal", "delegating")
# Written from the role contract (agent-directed-routing): the default model of a Claude profile is the first model
# of the role's minimum tier. Not read off the catalog, so a drifting roleMinimums or build goes red.
EXPECTED_PROFILE_MODEL = {
    "explorer": "sonnet", "scout": "sonnet", "worker": "sonnet", "builder": "sonnet",
    "analyst": "opus", "architect": "opus", "reviewer": "opus",
}


# --- a minimal source tree the Builder can read, with tweakable local layers ------------------


def sandbox(team_settings: dict | None = None) -> Path:
    root = Path(tempfile.mkdtemp(prefix="routing-build-")).resolve()
    for rel in (
        "agents/common/routing/catalog.json",
        "agents/claude/settings.base.json",
        "agents/claude/settings.json",
        "agents/codex/config.base.toml",
        "agents/codex/config.append.toml",
        "workspace.json",
    ):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, root / rel)
    shutil.copytree(ROOT / "agents/common/roles", root / "agents/common/roles")
    if team_settings is not None:
        path = root / "agents/claude/settings.json"
        merged = json.loads(path.read_text())
        merged.update(team_settings)
        path.write_text(json.dumps(merged))
    return root


def generated(root: Path, env: dict[str, str] | None = None) -> tuple[dict, dict]:
    for key, value in (env or {}).items():
        os.environ[key] = value
    try:
        files = build.Builder(root).files()
    finally:
        for key in (env or {}):
            os.environ.pop(key, None)
    claude = json.loads(files[root / ".claude/settings.json"])
    codex = tomllib.loads(files[root / ".codex/config.toml"].decode())
    return claude, codex


# --- 2.2: root defaults come from the catalog, field by field -----------------------------

work = sandbox()
claude, codex = generated(work)
assert claude["model"] == "opus" and claude["effortLevel"] == "high"
assert codex["model"] == "gpt-6-astra"  # strongestAvailable of the tracked catalog
assert codex["model_reasoning_effort"] == "high"
assert claude["env"]["CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH"] == "4"

# no workspace concurrency cap anywhere, generated or tracked (native limit applies)
sources = [work / "agents/codex/config.base.toml", work / "agents/codex/config.append.toml",
           ROOT / "agents/claude/settings.base.json", ROOT / "agents/claude/settings.json"]
rendered = json.dumps(claude) + json.dumps(codex) + "".join(p.read_text() for p in sources)
assert "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS" not in rendered
assert "max_concurrent_threads_per_session" not in rendered

# managed runtime *_DEFAULT_* layer: each half independently, the unset half from the catalog
for provider, (cm, ce), read in (
    ("claude", ("opus", "high"), lambda c, x: (c["model"], c["effortLevel"])),
    ("codex", ("gpt-6-astra", "high"), lambda c, x: (x["model"], x["model_reasoning_effort"])),
):
    p = provider.upper()
    both = generated(work, {f"{p}_DEFAULT_MODEL": "sonnet" if provider == "claude" else "gpt-6-sol",
                            f"{p}_DEFAULT_EFFORT": "low"})
    model_only = generated(work, {f"{p}_DEFAULT_MODEL": "haiku" if provider == "claude" else "gpt-6-luna"})
    effort_only = generated(work, {f"{p}_DEFAULT_EFFORT": "medium"})
    assert read(*both) == (("sonnet" if provider == "claude" else "gpt-6-sol"), "low"), provider
    assert read(*model_only) == (("haiku" if provider == "claude" else "gpt-6-luna"), ce), provider
    assert read(*effort_only) == (cm, "medium"), provider
    assert read(*generated(work)) == (cm, ce), provider

# local layer in the tracked team settings (Claude): same field-wise rule, beats catalog
for local, want in (
    ({"model": "sonnet", "effortLevel": "low"}, ("sonnet", "low")),
    ({"model": "sonnet"}, ("sonnet", "high")),
    ({"effortLevel": "medium"}, ("opus", "medium")),
):
    local_root = sandbox(local)
    c, _ = generated(local_root)
    shutil.rmtree(local_root, ignore_errors=True)
    assert (c["model"], c["effortLevel"]) == want, local

# Explicit /model and /effort (the top layer of design D1) belong to the runtimes: the workspace only generates the lower
# layers tested above, and states the precedence in the routing skill. Pin that wording so it cannot drift silently.
routing_skill = " ".join((ROOT / "agents/common/skills/agent-directed-routing/SKILL.md").read_text().split())
for phrase in ("override tracked root defaults field by field",
               "frontmatter `model` of a generated profile is the tracked default",
               "an explicit `model` on the Agent call overrides it",
               "Explicit values take precedence over local values, which take precedence over catalog defaults"):
    assert phrase in routing_skill, phrase

# --- 2.3: profiles per role x effort x capability ------------------------------------------

roles = ROOT / "agents/common/roles"
stems = sorted(p.stem for p in roles.glob("*.md"))
assert stems == sorted(p.stem for p in roles.glob("*.toml")), "every role needs both a Claude and a Codex body"
assert {"explorer", "scout", "worker", "analyst", "architect", "builder", "reviewer"} <= set(stems)


def frontmatter(path: Path) -> dict[str, str]:
    block = path.read_text().split("---\n", 2)[1]
    return {k.strip(): v.strip() for k, v in (line.split(":", 1) for line in block.splitlines() if ":" in line)}


for stem in stems:
    meta = frontmatter(roles / f"{stem}.md")
    assert meta["name"] == stem, f"{stem}: profile names derive from the role name"
    assert "model" not in meta, f"{stem}: a canonical role must not hardcode a model"
    toml_text = (roles / f"{stem}.toml").read_text()
    assert not re.search(r"(?m)^\s*(model|model_reasoning_effort|reasoning_effort)\s*=", toml_text), stem
    assert "Agent" not in meta["tools"].replace(" ", "").split(","), f"{stem}: canonical tools never include Agent"

files = build.Builder(work).files()
claude_profiles = {p: c for p, c in files.items() if p.parent == work / ".claude/agents"}
codex_profiles = {p: c for p, c in files.items() if p.parent == work / ".codex/agents"}
expected_names = sorted(f"{s}--{e}--{c}" for s in stems for e in EFFORTS for c in CAPABILITIES)
assert len(expected_names) == len(stems) * 6
assert sorted(p.stem for p in claude_profiles) == expected_names  # no missing, no extra, no duplicate
assert sorted(p.stem for p in codex_profiles) == expected_names

for stem in stems:
    base_tools = [t.strip() for t in frontmatter(roles / f"{stem}.md")["tools"].split(",") if t.strip()]
    for effort in EFFORTS:
        for capability in CAPABILITIES:
            name = f"{stem}--{effort}--{capability}"
            text = claude_profiles[work / f".claude/agents/{name}.md"].decode()
            head = dict(
                (k.strip(), v.strip()) for k, v in (l.split(":", 1) for l in text.split("---\n", 2)[1].splitlines() if ":" in l)
            )
            tools = [t.strip() for t in head["tools"].split(",")]
            assert head["name"] == name and head["effort"] == effort, name
            assert head["model"] == EXPECTED_PROFILE_MODEL[stem], f"{name}: default model of the role's minimum tier"
            assert ("Agent" in tools) == (capability == "delegating"), name
            assert set(tools) - {"Agent"} == set(base_tools), f"{name}: other tools unchanged"

            cx = tomllib.loads(codex_profiles[work / f".codex/agents/{name}.toml"].decode())
            assert cx["name"] == name
            assert "model" not in cx and "model_reasoning_effort" not in cx and "reasoning_effort" not in cx, name
            features = cx.get("features", {})
            if capability == "terminal":  # both tool generations are separate flags; either one left on can still spawn
                assert features == {"multi_agent": False, "multi_agent_v2": False}, f"{name}: collaboration tools must be off: {features}"
            else:
                assert "multi_agent" not in features and "multi_agent_v2" not in features, f"{name}: a delegating role keeps collaboration tools"
            assert (cx.get("sandbox_mode") == "read-only") == (stem in {"explorer", "scout"}), name

# the profile default is tracked data: managed runtime/local root overrides do not move it, a role without a minimum is refused
env = {"CLAUDE_DEFAULT_MODEL": "haiku", "CLAUDE_DEFAULT_EFFORT": "low"}
os.environ.update(env)
try:
    overridden = build.Builder(work).files()
finally:
    for key in env:
        os.environ.pop(key, None)
assert {p: c for p, c in overridden.items() if p.parent == work / ".claude/agents"} == claude_profiles, env
unlisted = sandbox()
cat_path = unlisted / "agents/common/routing/catalog.json"
doc = json.loads(cat_path.read_text())
doc["roleMinimums"].pop("scout")
cat_path.write_text(json.dumps(doc))
try:
    build.Builder(unlisted).files()
except RuntimeError as error:
    assert "scout" in str(error)
else:
    raise AssertionError("a role missing from roleMinimums must be refused")
shutil.rmtree(unlisted, ignore_errors=True)

# the keys of roleMinimums are exactly the role files: a stale or mistyped key is refused too
extra = sandbox()
cat_path = extra / "agents/common/routing/catalog.json"
doc = json.loads(cat_path.read_text())
doc["roleMinimums"]["scoot"] = dict(doc["roleMinimums"]["scout"])
cat_path.write_text(json.dumps(doc))
try:
    build.Builder(extra).files()
except RuntimeError as error:
    assert "scoot" in str(error)
else:
    raise AssertionError("a roleMinimums key without a role file must be refused")
shutil.rmtree(extra, ignore_errors=True)

# a canonical role without an explicit tools list would inherit every tool (Agent included),
# so a "terminal" profile could still delegate: the build refuses it instead of generating that
broken = sandbox()
(broken / "agents/common/roles/explorer.md").write_text(
    (broken / "agents/common/roles/explorer.md").read_text().replace("tools: Bash, Read, Grep, Glob\n", ""))
try:
    build.Builder(broken).files()
except RuntimeError as error:
    assert "tools" in str(error)
else:
    raise AssertionError("a role with no tools list must be refused")
shutil.rmtree(broken, ignore_errors=True)

# --- the real thing: sync + check on a full copy, then count what landed -----------------------

full = Path(tempfile.mkdtemp(prefix="routing-build-full-")).resolve()
shutil.copytree(ROOT / "agents", full / "agents", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
shutil.copy2(ROOT / "workspace.json", full / "workspace.json")
runner = full / "agents/build.py"
subprocess.run([str(runner), "sync"], cwd=full, check=True, capture_output=True)
subprocess.run([str(runner), "check"], cwd=full, check=True, capture_output=True)
assert len(list((full / ".claude/agents").glob("*--*--*.md"))) == len(stems) * 6
assert len(list((full / ".codex/agents").glob("*--*--*.toml"))) == len(stems) * 6
live = json.loads((full / ".claude/settings.json").read_text())
assert live["model"] == "opus" and live["effortLevel"] == "high"

for leftover in (work, full):
    shutil.rmtree(leftover, ignore_errors=True)
print("routing build: ok")
