#!/usr/bin/env python3
"""Build and verify the local Claude Code and Codex runtime trees."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

TIERS = ("fast", "balanced", "strong")
EFFORTS = ("low", "medium", "high")


def merge(base: Any, overlay: Any) -> Any:
    if isinstance(base, dict) and isinstance(overlay, dict):
        result = dict(base)
        for key, value in overlay.items():
            result[key] = merge(result[key], value) if key in result else value
        return result
    if isinstance(base, list) and isinstance(overlay, list):
        result = list(base)
        for value in overlay:
            if value not in result:
                result.append(value)
        return result
    return overlay


def strip_comments(value: Any) -> Any:
    """Drop `"//"` keys on the way into a generated settings file.

    A deny rule is a one-line glob whose reason does not fit in it, and JSON has
    nowhere to put that reason. `"//"` is the usual idiom, but the generated
    `.claude/settings.json` is read by Claude Code against its own schema, so the
    comment is kept in the source layer under `agents/` and removed here.
    """
    if isinstance(value, dict):
        return {k: strip_comments(v) for k, v in value.items() if k != "//"}
    if isinstance(value, list):
        return [strip_comments(v) for v in value]
    return value


class Builder:
    """Read sources from ``root``; write and verify runtime trees under ``output``.

    ``output`` defaults to ``root`` — the ordinary in-place sync. A different
    ``output`` is the scratch build of ``check`` in a checkout that must not grow
    runtime trees of its own: everything generated there is byte-identical to what
    an in-place sync of ``root`` would write, symlink targets included.
    """

    def __init__(self, root: Path, output: Path | None = None) -> None:
        self.root = root.resolve()
        self.output = (output or root).resolve()
        self.agents = self.root / "agents"
        self.catalog_path = self.agents / "common" / "routing" / "catalog.json"
        self._repo_skills: tuple[dict[str, Path], list[str], list[str]] | None = None

    def catalog(self) -> dict[str, Any]:
        catalog = json.loads(self.catalog_path.read_text())
        if catalog.get("version") != 1 or catalog.get("tiers") != list(TIERS):
            raise RuntimeError("routing catalog has an unsupported version or tier list")
        providers = catalog.get("providers", {})
        for provider in ("claude", "codex"):
            data = providers.get(provider)
            if not isinstance(data, dict):
                raise RuntimeError(f"routing catalog is missing provider {provider}")
            models = data.get("models", {})
            if set(models) != set(TIERS):
                raise RuntimeError(f"routing catalog has invalid tiers for {provider}")
            known = set(data.get("supportedModels", []))
            if not known or len(known) != len(data.get("supportedModels", [])):
                raise RuntimeError(f"routing catalog has an empty or duplicate model set for {provider}")
            for tier, chain in models.items():
                if not isinstance(chain, list) or not chain or len(chain) != len(set(chain)):
                    raise RuntimeError(f"routing catalog has an empty or duplicate {provider}/{tier} chain")
                if any(not isinstance(model, str) or model not in known for model in chain):
                    raise RuntimeError(f"routing catalog has an unknown model in {provider}/{tier}")
            fallbacks = data.get("effortFallbacks", {})
            if set(fallbacks) != set(EFFORTS):
                raise RuntimeError(f"routing catalog has invalid effort chains for {provider}")
            for effort, chain in fallbacks.items():
                if (not isinstance(chain, list) or not chain or chain[0] != effort
                        or len(chain) != len(set(chain)) or any(item not in EFFORTS for item in chain)):
                    raise RuntimeError(f"routing catalog has an empty, cyclic, or invalid effort chain for {provider}/{effort}")
        minimums = catalog.get("roleMinimums")
        if not isinstance(minimums, dict) or not minimums:
            raise RuntimeError("routing catalog has no role minimums")
        role_names = {source.stem for source in (self.agents / "common" / "roles").glob("*.md")}
        if set(minimums) != role_names:
            raise RuntimeError(
                "routing catalog roleMinimums must match agents/common/roles/*.md: "
                f"unknown {sorted(set(minimums) - role_names)}, missing {sorted(role_names - set(minimums))}")
        for role, minimum in minimums.items():
            if not isinstance(minimum, dict):
                raise RuntimeError(f"routing catalog has an invalid minimum for role {role}")
            floor = minimum.get("floor", minimum)
            for level in (minimum, floor):
                if not isinstance(level, dict) or level.get("tier") not in TIERS or level.get("effort") not in EFFORTS:
                    raise RuntimeError(f"routing catalog has an invalid tier or effort for role {role}")
            # the floor is the cheapest combination a parent may pick: it never sits above the default minimum
            if (TIERS.index(floor["tier"]) > TIERS.index(minimum["tier"])
                    or EFFORTS.index(floor["effort"]) > EFFORTS.index(minimum["effort"])):
                raise RuntimeError(f"routing catalog has a floor above the minimum for role {role}")
        for provider, default in catalog.get("rootDefaults", {}).items():
            if provider not in providers or default.get("effort") not in EFFORTS:
                raise RuntimeError(f"routing catalog has invalid root default for {provider}")
            model = default.get("model")
            if model == "strongestAvailable":
                model = catalog.get("strongestAvailable", {}).get(provider)
            provider_models = set(providers[provider]["supportedModels"])
            if model not in provider_models:
                raise RuntimeError(f"routing catalog has unknown root model for {provider}")
        return catalog

    def resolved_defaults(self, catalog: dict[str, Any], provider: str) -> dict[str, str]:
        default = dict(catalog["rootDefaults"][provider])
        if default["model"] == "strongestAvailable":
            default["model"] = catalog["strongestAvailable"][provider]
        prefix = provider.upper()
        for field, env_name in (("model", f"{prefix}_DEFAULT_MODEL"),
                                ("effort", f"{prefix}_DEFAULT_EFFORT")):
            if os.environ.get(env_name):
                default[field] = os.environ[env_name]
        return default

    def role_model(self, catalog: dict[str, Any], role: str) -> str:
        """First Claude model of the role's minimum tier: the tracked default of a profile.

        Deliberately independent of ``CLAUDE_DEFAULT_*``: those set the root's own model, and a
        profile that followed them would make generated files differ per machine. An explicit
        ``model`` on the Agent call and the runtime's own subagent-model override still win over
        this frontmatter default at invocation time.
        """
        minimum = catalog["roleMinimums"].get(role)
        if minimum is None:
            raise RuntimeError(f"routing catalog has no minimum for role {role}")
        return catalog["providers"]["claude"]["models"][minimum["tier"]][0]

    @staticmethod
    def claude_profile(source: Path, effort: str, capability: str, model: str) -> bytes:
        text = source.read_text()
        if not text.startswith("---\n"):
            raise RuntimeError(f"canonical role has no frontmatter: {source}")
        _, frontmatter, body = text.split("---\n", 2)
        metadata: dict[str, str] = {}
        for line in frontmatter.splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                metadata[key.strip()] = value.strip()
        role = metadata.get("name", source.stem)
        if not metadata.get("tools"):
            # an absent tools line means "inherit everything", which would put Agent into terminal profiles
            raise RuntimeError(f"canonical role must declare an explicit tools list: {source}")
        tools = [item.strip() for item in metadata.get("tools", "").split(",") if item.strip() and item.strip() != "Agent"]
        if capability == "delegating":
            tools.append("Agent")
        metadata["name"] = f"{role}--{effort}--{capability}"
        metadata["tools"] = ", ".join(dict.fromkeys(tools))
        metadata["effort"] = effort
        metadata["model"] = model
        profile_note = (
            f"\n\n## Routing profile\n\nThis profile is {capability} with minimum effort {effort}. "
            "Its model is the catalog default of the role's minimum tier; the immediate parent supplies the "
            "concrete catalog model and effort for each invocation and an explicit value wins. "
            "Do not substitute a different tier or skip a workflow gate.\n"
        )
        rendered = "---\n" + "\n".join(f"{key}: {value}" for key, value in metadata.items())
        return (rendered + "\n---\n" + body.rstrip() + profile_note).encode()

    @staticmethod
    def codex_profile(source: Path, effort: str, capability: str) -> bytes:
        text = source.read_text()
        marker = 'developer_instructions = """'
        start = text.find(marker)
        end = text.find('"""', start + len(marker)) if start >= 0 else -1
        if start < 0 or end < 0:
            raise RuntimeError(f"canonical Codex role has invalid instructions: {source}")
        instructions = text[start + len(marker):end].strip()
        instructions += (
            f"\n\nRouting profile: {capability}, minimum effort {effort}. "
            "The parent supplies model and reasoning_effort at spawn. Terminal profiles must not spawn "
            "or use collaboration tools; delegating profiles may do so only within the assigned Track and depth."
        )
        description_line = next((line for line in text.splitlines() if line.startswith("description = ")), None)
        description = description_line.split("=", 1)[1].strip() if description_line else '"Workspace agent role"'
        role = source.stem
        sandbox = '\nsandbox_mode = "read-only"' if source.stem in {"explorer", "scout"} else ""
        collaboration = (
            # both generations of the collaboration tools (spawn_agent & co.) are separate flags; a terminal
            # profile that leaves either on could still spawn at depth 4 or in Track Q/P/E
            '\n\n[features]\nmulti_agent = false\nmulti_agent_v2 = false'
            if capability == "terminal"
            else ""
        )
        profile = (
            f"# Generated from {source.as_posix()}; edit canonical role and run ./ops sync.\n"
            f"name = \"{role}--{effort}--{capability}\"\n"
            f"description = {description}{sandbox}\n\n"
            "developer_instructions = \"\"\"\n" + instructions + "\n\"\"\"\n"
            + collaboration + "\n"
        )
        return profile.encode()

    def manifest_repos(self) -> dict[str, Any]:
        """``repos`` of ``repos.json``; no manifest is an empty workspace, a broken one an error."""
        manifest = self.root / "repos.json"
        if not manifest.is_file():
            return {}
        try:
            repos = json.loads(manifest.read_text()).get("repos", {})
        except (ValueError, AttributeError) as error:
            raise RuntimeError(f"repos.json is not a valid manifest: {error}") from error
        if not isinstance(repos, dict):
            raise RuntimeError("repos.json is not a valid manifest: `repos` must be an object")
        return repos

    def repo_checks(self) -> list[str]:
        """Errors in the optional ``checks`` of ``repos.json`` entries.

        ``checks`` lists the standard local verification commands of a repository —
        lint, typecheck, unit tests, build — that an agent runs before reporting. It is
        a list of nonempty strings. Integration and e2e run in CI only, so a command
        that the ``block-local-integration-tests.py`` hook would refuse is an error
        here too: the manifest must not advertise as standard what the agent may not
        run. The hook is imported, not copied, so both share one detector; it is
        loaded only when some repository declares commands, and a hook that cannot be
        loaded is an error rather than a silent pass. ``check`` reports these as drift,
        ``sync`` as warnings.
        """
        errors: list[str] = []
        detect = None
        for repo, entry in self.manifest_repos().items():
            if not isinstance(entry, dict) or "checks" not in entry:
                continue
            declared = entry["checks"]
            if not isinstance(declared, list):
                errors.append(f"repos.json: {repo}.checks must be a list of command strings")
                continue
            for raw in declared:
                if not isinstance(raw, str) or not raw.strip():
                    errors.append(f"repos.json: {repo}.checks entry {raw!r} must be a nonempty command string")
                    continue
                if detect is None:
                    try:
                        detect = self.integration_detector()
                    except Exception as error:  # a check fails loudly, unlike the hook itself
                        errors.append(f"repos.json: {repo}.checks cannot be verified: the "
                                      f"block-local-integration-tests.py hook did not load ({error})")
                        return errors
                hit = detect(raw)
                if hit:
                    errors.append(f"repos.json: {repo}.checks entry {raw!r} runs integration/e2e ({hit}); "
                                  "those run in CI only — list lint, typecheck, unit and build commands")
        return errors

    def integration_detector(self) -> Any:
        """``analyze_command`` of the integration hook, executed without writing bytecode."""
        path = self.agents / "common" / "hooks" / "block-local-integration-tests.py"
        namespace: dict[str, Any] = {"__name__": "block_local_integration_tests", "__file__": str(path)}
        exec(compile(path.read_text(), str(path), "exec"), namespace)
        return namespace["analyze_command"]

    def repo_skills(self) -> tuple[dict[str, Path], list[str], list[str]]:
        """Skills that live in product repositories: ``(name -> directory, warnings, errors)``.

        ``repos.json`` lists them per repository in ``skills``: paths of skill directories
        relative to the repository root, the skill name being the basename. The source is
        ``packages/<repo>/<path>``, which only exists once the repository is cloned and the
        skill is merged there; a missing directory is a warning and a skip, not a failure, so
        a ``git pull`` hook never breaks on a skill that has not landed yet. The two absences
        read differently: no ``packages/<repo>`` at all is an optional checkout, while a cloned
        repository without the path is a typo or a stale manifest, and the warning says which.
        A name that
        collides with a workspace skill under ``agents/common/skills/`` or with another
        imported one is an error: the workspace skill wins and nothing is imported under that
        name. ``sync`` prints errors as warnings and skips; ``check`` reports them as drift.
        """
        if self._repo_skills is not None:
            return self._repo_skills
        found: dict[str, Path] = {}
        warnings: list[str] = []
        errors: list[str] = []
        repos = self.manifest_repos()
        taken = {path.name for path in (self.agents / "common" / "skills").iterdir() if path.is_dir()}
        for repo, entry in repos.items():
            declared = entry.get("skills", []) if isinstance(entry, dict) else []
            if not isinstance(declared, list):
                errors.append(f"repos.json: {repo}.skills must be a list of paths")
                continue
            for raw in declared:
                # Path() silently drops "." and doubled slashes, so segments are checked on the raw
                # string: "." or "./" would otherwise yield an empty name, i.e. the whole skills dir.
                relative = Path(raw) if isinstance(raw, str) and raw else None
                if (relative is None or relative.is_absolute() or not relative.parts
                        or any(segment in ("", ".", "..") for segment in raw.split("/"))
                        or relative.name in ("", ".", "..")):
                    errors.append(f"repos.json: {repo}.skills entry {raw!r} must be a path inside the repository")
                    continue
                name = relative.name
                if name in taken:
                    owner = "a workspace skill" if name not in found else "another repository skill"
                    errors.append(f"skill {name}: packages/{repo}/{raw} not imported, the name is already "
                                  f"taken by {owner}; rename the skill directory")
                    continue
                repo_root = self.root / "packages" / repo
                source = repo_root / relative
                if not source.is_dir():
                    # Two different absences, and conflating them hides the one worth acting on.
                    # No checkout: the workspace simply has not cloned that repository, and the
                    # skill arrives with `clone`. A checkout that lacks the path is a typo in the
                    # manifest or a skill that has not merged into the default branch yet — the
                    # warning names both the repository and the path so it can be chased.
                    if not repo_root.is_dir():
                        warnings.append(f"skill {name}: packages/{repo} is not cloned — "
                                        f"{raw} cannot be imported until it is")
                    else:
                        warnings.append(f"skill {name}: packages/{repo} is cloned but has no {raw} "
                                        f"— stale repos.json entry, a typo, or the skill has not "
                                        f"merged into the default branch of {repo} yet")
                    continue
                # the .. check above is lexical; a symlink inside the repository may still lead out
                try:
                    source.resolve().relative_to(repo_root.resolve())
                except ValueError:
                    errors.append(f"repos.json: {repo}.skills entry {raw!r} must be a path inside the repository "
                                  "(it resolves outside through a symlink)")
                    continue
                if not (source / "SKILL.md").is_file():
                    warnings.append(f"skill {name}: packages/{repo}/{raw} has no SKILL.md")
                    continue
                taken.add(name)
                found[name] = source
        self._repo_skills = (found, warnings, errors)
        return self._repo_skills

    def links(self) -> dict[Path, Path]:
        links: dict[Path, Path] = {}
        skills = self.agents / "common" / "skills"
        hooks = self.agents / "common" / "hooks"
        roles = self.agents / "common" / "roles"
        commands = self.agents / "claude" / "commands"

        for source in sorted(path for path in skills.iterdir() if path.is_dir()):
            links[self.output / ".claude" / "skills" / source.name] = source
            links[self.output / ".agents" / "skills" / source.name] = source
        for name, source in sorted(self.repo_skills()[0].items()):
            links[self.output / ".claude" / "skills" / name] = source
            links[self.output / ".agents" / "skills" / name] = source
        for source in sorted(
            path for path in hooks.iterdir() if path.is_file() and os.access(path, os.X_OK)
        ):
            links[self.output / ".claude" / "hooks" / source.name] = source
            links[self.output / ".agents" / "hooks" / source.name] = source
        for source in sorted(roles.glob("*.md")):
            links[self.output / ".claude" / "agents" / source.name] = source
        for source in sorted(roles.glob("*.toml")):
            links[self.output / ".codex" / "agents" / source.name] = source
        for source in sorted(path for path in commands.iterdir() if path.is_file()):
            links[self.output / ".claude" / "commands" / source.name] = source
        links[self.output / ".claude" / "file-suggestion.sh"] = (
            self.agents / "claude" / "file-suggestion.sh"
        )
        return links

    def settings(self) -> bytes:
        base = json.loads((self.agents / "claude" / "settings.base.json").read_text())
        team = json.loads((self.agents / "claude" / "settings.json").read_text())
        settings = strip_comments(merge(base, team))
        defaults = self.resolved_defaults(self.catalog(), "claude")
        settings.setdefault("model", defaults["model"])
        settings.setdefault("effortLevel", defaults["effort"])
        settings.setdefault("env", {})["CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH"] = "4"
        return (json.dumps(settings, ensure_ascii=False, indent=2) + "\n").encode()

    def codex_config(self) -> bytes:
        base = (self.agents / "codex" / "config.base.toml").read_text()
        append = (self.agents / "codex" / "config.append.toml").read_text()
        defaults = self.resolved_defaults(self.catalog(), "codex")
        content = (
            "# Generated from agents/codex; edit the source layer and run ./ops sync.\n"
            f"model = \"{defaults['model']}\"\n"
            f"model_reasoning_effort = \"{defaults['effort']}\"\n\n"
            + base.rstrip()
            + "\n\n# Additive fragment: agents/codex/config.append.toml\n"
            + append.rstrip()
            + "\n"
        )
        return content.replace("@ROOT@", str(self.root)).encode()

    def files(self) -> dict[Path, bytes]:
        settings = self.settings()
        manifest = json.loads((self.root / "workspace.json").read_text())
        hooks = json.dumps(
            {"hooks": json.loads(settings)["hooks"]}, ensure_ascii=False, indent=2
        )
        files = {
            self.output / ".claude" / "settings.json": settings,
            self.output / ".codex" / "config.toml": self.codex_config(),
            self.output / ".codex" / "hooks.json": (hooks + "\n").encode(),
            self.output / "harness.json": (
                json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
            ).encode(),
        }
        catalog = self.catalog()
        roles = self.agents / "common" / "roles"
        for source in sorted(roles.glob("*.md")):
            model = self.role_model(catalog, source.stem)
            for effort in EFFORTS:
                for capability in ("terminal", "delegating"):
                    destination = self.output / ".claude" / "agents" / (
                        f"{source.stem}--{effort}--{capability}.md"
                    )
                    files[destination] = self.claude_profile(source, effort, capability, model)
        for source in sorted(roles.glob("*.toml")):
            for effort in EFFORTS:
                for capability in ("terminal", "delegating"):
                    destination = self.output / ".codex" / "agents" / (
                        f"{source.stem}--{effort}--{capability}.toml"
                    )
                    files[destination] = self.codex_profile(source, effort, capability)
        return files

    def link_target(self, path: Path, source: Path) -> str:
        # Relative to where the link would sit in the source checkout, not in the
        # output: a scratch build then carries exactly the targets of an in-place sync.
        return os.path.relpath(source, self.root / path.parent.relative_to(self.output))

    def managed_dirs(self) -> list[Path]:
        return [
            self.output / ".claude" / "skills",
            self.output / ".claude" / "hooks",
            self.output / ".claude" / "agents",
            self.output / ".claude" / "commands",
            self.output / ".agents" / "skills",
            self.output / ".agents" / "hooks",
            self.output / ".codex" / "agents",
        ]

    def runtime_roots(self) -> list[Path]:
        return [self.output / name for name in (".claude", ".agents", ".codex")]

    @staticmethod
    def refuse_symlink(path: Path) -> None:
        if path.is_symlink():
            raise RuntimeError(f"refusing to follow runtime symlink: {path}")

    def validate_layout(self, expected_files: dict[Path, bytes]) -> None:
        for directory in [*self.runtime_roots(), *self.managed_dirs()]:
            self.refuse_symlink(directory)
            if directory.exists() and not directory.is_dir():
                raise RuntimeError(f"runtime directory is not a directory: {directory}")
        for path in expected_files:
            self.refuse_symlink(path)
            if path.exists() and not path.is_file():
                raise RuntimeError(f"runtime output is not a regular file: {path}")

    @staticmethod
    def atomic_write(path: Path, content: bytes) -> None:
        descriptor, temporary = tempfile.mkstemp(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
        )
        temporary_path = Path(temporary)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            temporary_path.chmod(0o644)
            os.replace(temporary_path, path)
        finally:
            temporary_path.unlink(missing_ok=True)

    def drift(self) -> list[str]:
        expected_links = self.links()
        expected_files = self.files()
        drift: list[str] = [f"skill-import:{error}" for error in self.repo_skills()[2]]
        drift += [f"manifest:{error}" for error in self.repo_checks()]

        try:
            self.validate_layout(expected_files)
        except RuntimeError as error:
            return [f"unsafe:{error}"]

        expected_by_parent: dict[Path, set[str]] = {}
        for path in expected_links:
            expected_by_parent.setdefault(path.parent, set()).add(path.name)
        for path in expected_files:
            expected_by_parent.setdefault(path.parent, set()).add(path.name)
        for directory in self.managed_dirs():
            expected = expected_by_parent.get(directory, set())
            if directory.exists():
                for entry in directory.iterdir():
                    if entry.name not in expected:
                        drift.append(f"extra:{entry.relative_to(self.output)}")

        for path, source in expected_links.items():
            expected = self.link_target(path, source)
            if not path.is_symlink():
                drift.append(f"link:{path.relative_to(self.output)}")
            elif os.readlink(path) != expected:
                drift.append(f"target:{path.relative_to(self.output)}")
        for path, content in expected_files.items():
            if path.is_symlink() or not path.is_file() or path.read_bytes() != content:
                drift.append(f"file:{path.relative_to(self.output)}")
        return sorted(drift)

    def sync(self) -> None:
        expected_links = self.links()
        expected_files = self.files()
        self.validate_layout(expected_files)
        expected_by_parent: dict[Path, set[str]] = {}
        for path in expected_links:
            expected_by_parent.setdefault(path.parent, set()).add(path.name)
        for path in expected_files:
            expected_by_parent.setdefault(path.parent, set()).add(path.name)

        for directory in self.managed_dirs():
            directory.mkdir(parents=True, exist_ok=True)
            expected = expected_by_parent.get(directory, set())
            for entry in directory.iterdir():
                if entry.name in expected:
                    continue
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry)
                else:
                    entry.unlink()

        for path, source in expected_links.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            expected = self.link_target(path, source)
            if path.is_symlink() and os.readlink(path) == expected:
                continue
            if path.exists() or path.is_symlink():
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            path.symlink_to(expected)

        for path, content in expected_files.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            self.atomic_write(path, content)


# Errors that mean "the sources cannot be built": a refused role, unreadable or
# malformed JSON, a missing source file. check reports them, never a traceback.
# OSError stays here for source reads; preparing the scratch directory is the
# environment, not the sources, and raises ScratchSetupError instead.
BUILD_ERRORS = (RuntimeError, OSError, ValueError)

# check exit codes. 3 is the environment: no usable temporary directory (Python
# falls back from an unusable TMPDIR to /tmp, /var/tmp and the cwd first) or no
# symlink inside it.
EXIT_DRIFT, EXIT_BUILD, EXIT_SCRATCH_SETUP = 1, 2, 3


class ScratchSetupError(Exception):
    """The scratch check could not create its temporary directory or the link in it."""


def keeps_runtime_trees(root: Path) -> bool:
    """Whether check verifies the runtime trees of ``root`` in place (True) or in scratch.

    False for a linked git worktree (``.git`` is a file), for a checkout with a
    ``worktrees`` directory among its ancestors and for a direct child of a
    ``packages`` directory; True otherwise. Those checkouts must not grow
    ``.claude/``, ``.agents/``, ``.codex/`` or ``harness.json``: with them each
    becomes a workspace root of its own.

    This is build.py's own rule, not a shared one. ``find_real_workspace_root`` in
    commit-and-mr/lib.sh skips a ``harness.json`` that is a symlink or sits under
    ``*/worktrees/*``; ``install_git_hooks`` in ``ops`` wants a ``.git`` directory
    and a parent not named ``packages``. They agree on the ordinary layout (the
    root, ``worktrees/<task>/<repo>``, ``packages/<repo>``) and may disagree
    elsewhere. A caller that needs the in-place check in a checkout this rule
    calls non-root — e.g. an isolated acceptance checkout created with
    ``git worktree add`` — must pass ``--in-place``.
    """
    root = root.resolve()
    if (root / ".git").is_file():
        return False
    return "worktrees" not in root.parts[:-1] and root.parent.name != "packages"


def scratch_check(root: Path) -> list[str]:
    """Sync ``root`` into a temporary directory and verify the result there.

    Proves the sources build (sync refuses nothing), the written trees match what
    drift expects, and every relative link resolves. ``root`` is only read; the
    temporary directory is removed even when the build raises. Failing to create
    that directory or the ``agents`` link in it raises ScratchSetupError.
    """
    agents = Builder(root).agents
    try:
        scratch = tempfile.TemporaryDirectory(prefix="ops-check-")
    except OSError as error:
        raise ScratchSetupError(error) from error
    with scratch as raw:
        output = Path(raw).resolve()
        # One link, so the relative targets (../../agents/...) resolve exactly as
        # they would in root. rmtree unlinks it without descending into the sources.
        try:
            (output / "agents").symlink_to(agents, target_is_directory=True)
            # Skills imported from packages/ resolve through the same kind of link.
            if (root / "packages").is_dir():
                (output / "packages").symlink_to((root / "packages").resolve(), target_is_directory=True)
        except OSError as error:
            raise ScratchSetupError(error) from error
        builder = Builder(root, output)
        builder.sync()
        # Self-consistency, not a tautology: sync and drift derive from the same
        # links()/files(), so this is empty for a correct builder and turns red when
        # the two disagree — e.g. a generated file landing on the path of a
        # generated link: the later write wins (ops-check-scratch.test.py covers it).
        problems = builder.drift()
        problems += [
            f"dangling:{path.relative_to(output)}"
            for path in builder.links()
            if not path.exists()
        ]
        return sorted(problems)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        epilog=f"check exits 0 clean, {EXIT_DRIFT} drift, {EXIT_BUILD} sources do not build, "
               f"{EXIT_SCRATCH_SETUP} scratch check could not prepare a temporary directory.",
    )
    parser.add_argument("command", choices=("sync", "status", "check"))
    parser.add_argument("--root", type=Path)
    parser.add_argument("--json", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--scratch", action="store_true",
                      help="check: build into a temporary directory, leave the checkout untouched")
    mode.add_argument("--in-place", action="store_true",
                      help="check: verify the runtime trees present in the checkout")
    args = parser.parse_args()
    root = args.root or Path(__file__).resolve().parents[1]
    builder = Builder(root)
    if (args.scratch or args.in_place) and args.command != "check":
        parser.error("--scratch and --in-place apply to check only")

    if args.command == "sync":
        try:
            builder.sync()
            _, warnings, errors = builder.repo_skills()
            errors = [*errors, *builder.repo_checks()]
        except RuntimeError as error:
            print(f"runtime sync refused: {error}", file=sys.stderr)
            return 2
        # A skill that cannot be imported never stops sync: the workspace skill wins,
        # a missing directory is a repository not cloned or not merged yet. A bad
        # `checks` entry is advice for agents, not a runtime file: also a warning.
        for message in (*warnings, *errors):
            print(f"warning: {message}", file=sys.stderr)
        print("runtime trees synchronized")
        return 0

    scratch = args.command == "check" and (
        args.scratch or (not args.in_place and not keeps_runtime_trees(root))
    )
    try:
        drift = scratch_check(root) if scratch else builder.drift()
        # skill-import errors are already drift items; a missing source is only worth a warning
        for message in builder.repo_skills()[1]:
            print(f"warning: {message}", file=sys.stderr)
    except ScratchSetupError as error:
        print(f"runtime check failed: scratch check could not prepare a temporary directory: {error}",
              file=sys.stderr)
        return EXIT_SCRATCH_SETUP
    except BUILD_ERRORS as error:
        print(f"runtime {args.command} failed: sources do not build: {error}", file=sys.stderr)
        return EXIT_BUILD
    where = "runtime trees built in a temporary directory" if scratch else "runtime trees"
    if args.json:
        print(json.dumps({"clean": not drift, "drift": drift,
                          "mode": "scratch" if scratch else "in-place"}, indent=2))
    elif drift:
        print(f"{where} differ from agents/:", file=sys.stderr)
        for item in drift:
            print(f"  {item}", file=sys.stderr)
    else:
        print(f"{where} match agents/")
    if scratch:
        leftovers = [path.name for path in (*builder.runtime_roots(), builder.output / "harness.json")
                     if path.exists() or path.is_symlink()]
        if leftovers:
            print(f"note: this checkout holds generated {', '.join(leftovers)}; they were not checked, "
                  "and with them it resolves as a workspace root of its own", file=sys.stderr)
    return EXIT_DRIFT if args.command == "check" and drift else 0


if __name__ == "__main__":
    raise SystemExit(main())
