#!/usr/bin/env python3
"""Skills of product repositories imported by the runtime builder.

`repos.json` lists skill directories per repository in `skills`; `./ops sync`
links each one that exists as `packages/<repo>/<path>` into `.claude/skills/` and
`.agents/skills/`. A missing source is a warning, a name taken by a workspace skill
is an error for `check` and a warning for `sync`.

    python3 agents/common/tests/repo-skills-import.test.py
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SRC = Path(__file__).resolve().parents[3]
FAILS: list[str] = []
SKILL_PATH = ".claude/skills/foo"


def check(ok: bool, what: str, detail: str = "") -> None:
    if not ok:
        FAILS.append(what)
        print(f"FAIL: {what}")
        if detail:
            print(detail)


def seed(root: Path, skills: list[str]) -> Path:
    root.mkdir(parents=True)
    shutil.copytree(SRC / "agents", root / "agents", symlinks=True,
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    shutil.copy2(SRC / "workspace.json", root / "workspace.json")
    manifest = {"repos": {"app": {"url": "git@example.invalid:team/app.git", "branch": "main",
                                  "deps": "none", "skills": skills}}}
    (root / "repos.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return root


def add_skill(root: Path, relative: str = SKILL_PATH) -> None:
    skill = root / "packages" / "app" / relative
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text(f"---\nname: {skill.name}\ndescription: Test skill.\n---\n\n# {skill.name}\n")


def build(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = {k: v for k, v in os.environ.items() if not k.endswith("_DEFAULT_MODEL") and not k.endswith("_DEFAULT_EFFORT")}
    return subprocess.run([sys.executable, str(root / "agents/build.py"), *args],
                          cwd=root, env=env, capture_output=True, text=True)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="repo-skills-import-") as raw:
        base = Path(raw).resolve()

        # (a) present source: both trees get a link that resolves to packages/<repo>/<path>
        root = seed(base / "present", [SKILL_PATH])
        add_skill(root)
        synced = build(root, "sync")
        check(synced.returncode == 0 and "warning" not in synced.stderr, "present: sync is clean",
              synced.stdout + synced.stderr)
        for tree in (".claude", ".agents"):
            link = root / tree / "skills" / "foo"
            check(link.is_symlink() and link.resolve() == (root / "packages/app" / SKILL_PATH).resolve(),
                  f"present: {tree}/skills/foo links to the repository skill",
                  f"{os.readlink(link) if link.is_symlink() else 'not a link'}")
            check((link / "SKILL.md").is_file(), f"present: {tree}/skills/foo resolves")
        in_place = build(root, "check", "--in-place")
        check(in_place.returncode == 0, "present: in-place check sees the link as expected, not drift",
              in_place.stdout + in_place.stderr)
        scratch = build(root, "check", "--scratch")
        check(scratch.returncode == 0, "present: scratch check does not report a dangling link",
              scratch.stdout + scratch.stderr)
        check(build(root, "status", "--json").returncode == 0, "present: status is clean")

        # (b) a path removed from repos.json takes the link with it on the next sync
        manifest = json.loads((root / "repos.json").read_text())
        manifest["repos"]["app"]["skills"] = []
        (root / "repos.json").write_text(json.dumps(manifest))
        stale = build(root, "check", "--in-place")
        check(stale.returncode == 1 and "extra:.claude/skills/foo" in stale.stderr,
              "removed path: the leftover link is drift", stale.stdout + stale.stderr)
        build(root, "sync")
        check(not (root / ".claude/skills/foo").is_symlink() and not (root / ".agents/skills/foo").is_symlink(),
              "removed path: sync removes the links")

        # (c) the repository is not cloned at all: a warning, no link, exit 0 everywhere.
        # An optional checkout nobody has pulled must never take the whole sync down with it.
        root = seed(base / "absent", [SKILL_PATH])
        check(not (root / "packages").exists(), "absent: the fixture really has no packages/")
        synced = build(root, "sync")
        expected = f"skill foo: packages/app is not cloned — {SKILL_PATH} cannot be imported"
        check(synced.returncode == 0 and expected in synced.stderr, "absent: sync warns and exits 0",
              synced.stdout + synced.stderr)
        check(not (root / ".claude/skills/foo").is_symlink() and not (root / ".agents/skills/foo").is_symlink(),
              "absent: no link is created")
        checked = build(root, "check", "--in-place")
        check(checked.returncode == 0 and expected in checked.stderr, "absent: check warns and exits 0",
              checked.stdout + checked.stderr)
        scratched = build(root, "check", "--scratch")
        check(scratched.returncode == 0, "absent: scratch check stays clean too",
              scratched.stdout + scratched.stderr)

        # (c2) the clone is there and the path is not: a typo or a stale manifest, and the
        # warning says so by name instead of repeating "not cloned".
        root = seed(base / "typo", [SKILL_PATH])
        (root / "packages/app").mkdir(parents=True)
        synced = build(root, "sync")
        expected = f"skill foo: packages/app is cloned but has no {SKILL_PATH}"
        check(synced.returncode == 0 and expected in synced.stderr,
              "typo: sync names the repository and the path it lacks",
              synced.stdout + synced.stderr)
        check("is not cloned" not in synced.stderr,
              "typo: the two absences are not conflated", synced.stdout + synced.stderr)
        check(not (root / ".claude/skills/foo").is_symlink(), "typo: no link is created")

        # (d) collision with a workspace skill: check fails, sync warns and keeps the workspace skill
        workspace_skill = sorted(p.name for p in (SRC / "agents/common/skills").iterdir() if p.is_dir())[0]
        relative = f".claude/skills/{workspace_skill}"
        root = seed(base / "collision", [relative])
        add_skill(root, relative)
        synced = build(root, "sync")
        check(synced.returncode == 0 and "already taken by a workspace skill" in synced.stderr,
              "collision: sync warns and exits 0", synced.stdout + synced.stderr)
        link = root / ".claude/skills" / workspace_skill
        check(link.is_symlink() and link.resolve() == (root / "agents/common/skills" / workspace_skill).resolve(),
              "collision: the workspace skill wins")
        failed = build(root, "check", "--in-place")
        check(failed.returncode != 0 and f"skill {workspace_skill}" in failed.stderr
              and "already taken by a workspace skill" in failed.stderr,
              "collision: check fails with a readable message", failed.stdout + failed.stderr)
        failed = build(root, "check", "--scratch")
        check(failed.returncode != 0 and "already taken" in failed.stderr and "Traceback" not in failed.stderr,
              "collision: scratch check fails too", failed.stdout + failed.stderr)

        # (e) a path that is not inside the repository is refused under check and skipped under sync
        for label, entry in (("..", "../outside/foo"), (".", "."), ("./", "./"), ("absolute", "/etc"),
                             ("trailing dot segment", ".claude/skills/./foo"), ("empty segment", "a//foo")):
            root = seed(base / f"bad-path-{label.replace('/', 'slash').replace(' ', '-')}", [entry])
            if entry != "../outside/foo":
                add_skill(root, ".")
            refused = build(root, "check", "--in-place")
            check(refused.returncode != 0 and "skill-import:" in refused.stdout + refused.stderr
                  and "must be a path inside the repository" in refused.stderr and "Traceback" not in refused.stderr,
                  f"bad path {label}: check fails with a readable message", refused.stdout + refused.stderr)
            synced = build(root, "sync")
            check(synced.returncode == 0 and "must be a path inside the repository" in synced.stderr,
                  f"bad path {label}: sync warns and exits 0", synced.stdout + synced.stderr)
            skills = root / ".claude/skills"
            check(skills.is_dir() and not skills.is_symlink() and not (root / ".agents/skills").is_symlink(),
                  f"bad path {label}: skills trees stay directories")
            check(not (skills / "foo").is_symlink() and not (root / ".agents/skills/foo").is_symlink(),
                  f"bad path {label}: no link is created")
            check(build(root, "check", "--in-place").returncode != 0, f"bad path {label}: check still fails after sync")

        # (f) the directory exists but has no SKILL.md: its own warning, no link, exit 0
        root = seed(base / "no-skill-md", [SKILL_PATH])
        (root / "packages/app" / SKILL_PATH).mkdir(parents=True)
        synced = build(root, "sync")
        check(synced.returncode == 0 and f"skill foo: packages/app/{SKILL_PATH} has no SKILL.md" in synced.stderr
              and "not found" not in synced.stderr, "no SKILL.md: sync warns about the missing file and exits 0",
              synced.stdout + synced.stderr)
        check(not (root / ".claude/skills/foo").is_symlink() and not (root / ".agents/skills/foo").is_symlink(),
              "no SKILL.md: no link is created")
        checked = build(root, "check", "--in-place")
        check(checked.returncode == 0 and "has no SKILL.md" in checked.stderr, "no SKILL.md: check warns and exits 0",
              checked.stdout + checked.stderr)

        # (g) two repositories declare the same skill name: the first wins, the second is an error
        root = seed(base / "name-clash", [SKILL_PATH])
        manifest = json.loads((root / "repos.json").read_text())
        manifest["repos"]["other"] = {"url": "git@example.invalid:team/other.git", "branch": "main",
                                      "deps": "none", "skills": ["skills/foo"]}
        (root / "repos.json").write_text(json.dumps(manifest))
        add_skill(root)
        other = root / "packages/other/skills/foo"
        other.mkdir(parents=True)
        (other / "SKILL.md").write_text("---\nname: foo\ndescription: Other.\n---\n")
        synced = build(root, "sync")
        check(synced.returncode == 0 and "already taken by another repository skill" in synced.stderr,
              "name clash: sync warns and exits 0", synced.stdout + synced.stderr)
        link = root / ".claude/skills/foo"
        check(link.is_symlink() and link.resolve() == (root / "packages/app" / SKILL_PATH).resolve(),
              "name clash: the first repository wins")
        failed = build(root, "check", "--in-place")
        check(failed.returncode != 0 and "another repository skill" in failed.stderr,
              "name clash: check fails", failed.stdout + failed.stderr)

        # (h) a symlink inside the repository that leads out of it is refused
        root = seed(base / "symlink-escape", [SKILL_PATH])
        outside = base / "outside-skill"
        outside.mkdir()
        (outside / "SKILL.md").write_text("---\nname: foo\ndescription: Outside.\n---\n")
        target = root / "packages/app" / SKILL_PATH
        target.parent.mkdir(parents=True)
        target.symlink_to(outside)
        synced = build(root, "sync")
        check(synced.returncode == 0 and "resolves outside" in synced.stderr and "Traceback" not in synced.stderr,
              "symlink escape: sync warns and exits 0", synced.stdout + synced.stderr)
        check(not (root / ".claude/skills/foo").is_symlink() and not (root / ".agents/skills/foo").is_symlink(),
              "symlink escape: no link is created")
        failed = build(root, "check", "--in-place")
        check(failed.returncode != 0 and "skill-import:" in failed.stdout + failed.stderr,
              "symlink escape: check fails", failed.stdout + failed.stderr)

        # a manifest whose `repos` is not an object is a readable error, not a traceback
        root = seed(base / "repos-list", [])
        (root / "repos.json").write_text('{"repos": []}\n')
        broken = build(root, "check", "--in-place")
        check(broken.returncode != 0 and "Traceback" not in broken.stderr and "repos" in broken.stderr,
              "repos not an object: readable failure", broken.stdout + broken.stderr)

        # no repos.json at all: nothing to import, nothing to fail
        root = seed(base / "no-manifest", [])
        (root / "repos.json").unlink()
        check(build(root, "sync").returncode == 0, "no manifest: sync succeeds")

    if FAILS:
        print(f"{len(FAILS)} failure(s)")
        return 1
    print("repo skills import: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
