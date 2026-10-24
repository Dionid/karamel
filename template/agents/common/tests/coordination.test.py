"""Behavior tests for the cross-client coordination hook and CLI."""

from __future__ import annotations

import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


# <root>/agents/common/tests/coordination.test.py — root is fixed by this
# file's own location, whether root is the engine source tree (this repo) or
# a team repository harness has synced.
SOURCE_ROOT = Path(__file__).resolve().parents[3]
COORD = SOURCE_ROOT / "agents/common/skills/coordination/coord"


class CoordinationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "harness.json").write_text(
            json.dumps({"branchPrefix": "feature/"}), encoding="utf-8"
        )
        self.env = os.environ.copy()
        self.env["WORKSPACE_COORDINATION_ROOT"] = str(self.root)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_coord(
        self,
        *args: str,
        payload: dict | None = None,
        check: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(COORD), *args],
            input=json.dumps(payload) if payload is not None else None,
            capture_output=True,
            text=True,
            env=self.env,
        )
        if check and result.returncode:
            self.fail(
                f"coord {' '.join(args)} exited {result.returncode}: "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
        return result

    def checkout(self, task: str = "alpha", repo: str = "api") -> Path:
        path = self.root / "worktrees" / task / repo
        path.mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        subprocess.run(
            ["git", "-C", str(path), "branch", "-M", f"feature/{task}"],
            check=True,
        )
        return path

    def pushed_checkout(self, task: str = "alpha", repo: str = "api") -> tuple[Path, str]:
        path = self.checkout(task, repo)
        remote = self.root / "remotes" / f"{repo}.git"
        remote.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        subprocess.run(
            ["git", "-C", str(path), "config", "user.email", "coord@example.invalid"],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(path), "config", "user.name", "Coord Test"],
            check=True,
        )
        tracked = path / "tracked.txt"
        tracked.write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(path), "add", "tracked.txt"], check=True)
        subprocess.run(["git", "-C", str(path), "commit", "-qm", "base"], check=True)
        subprocess.run(["git", "-C", str(path), "branch", "-M", "main"], check=True)
        subprocess.run(["git", "-C", str(path), "remote", "add", "origin", str(remote)], check=True)
        subprocess.run(["git", "-C", str(path), "push", "-q", "-u", "origin", "main"], check=True)
        subprocess.run(
            ["git", "-C", str(path), "switch", "-qc", f"feature/{task}"],
            check=True,
        )
        tracked.write_text("feature\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(path), "commit", "-qam", "feature"], check=True)
        subprocess.run(
            ["git", "-C", str(path), "push", "-q", "-u", "origin", f"feature/{task}"],
            check=True,
        )
        head = subprocess.run(
            ["git", "-C", str(path), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        return path, head

    @staticmethod
    def payload(
        session: str,
        event: str,
        cwd: Path,
        command: str = "git status --short",
        camel: bool = False,
    ) -> dict:
        if camel:
            return {
                "sessionId": session,
                "hookEventName": event,
                "cwd": str(cwd),
                "agentId": "root",
                "toolInput": {"command": ["bash", "-lc", command]},
            }
        return {
            "session_id": session,
            "hook_event_name": event,
            "cwd": str(cwd),
            "agent_id": "root",
            "tool_input": {"command": command},
        }

    def records(self, kind: str) -> list[dict]:
        directory = self.root / ".coordination" / kind
        return [
            json.loads(path.read_text(encoding="utf-8"))
            for path in sorted(directory.glob("*.json"))
        ]

    def record_paths(self, kind: str) -> list[Path]:
        return sorted((self.root / ".coordination" / kind).glob("*.json"))

    def age_records(self, kind: str, field: str, days: int) -> None:
        stamp = (
            dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=days)
        ).isoformat(timespec="seconds").replace("+00:00", "Z")
        for path in self.record_paths(kind):
            record = json.loads(path.read_text(encoding="utf-8"))
            record[field] = stamp
            path.write_text(json.dumps(record), encoding="utf-8")

    def test_snake_and_camel_payloads_create_independent_leases(self) -> None:
        command = ".claude/skills/coordination/coord claim alpha"
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("claude-session", "PreToolUse", self.root, command),
        )
        self.run_coord(
            "hook", "--client", "codex",
            payload=self.payload("codex-session", "PreToolUse", self.root, command, camel=True),
        )

        leases = self.records("sessions")
        self.assertEqual({item["client"] for item in leases}, {"claude", "codex"})
        self.assertTrue(all(item["phase"] == "busy" for item in leases))
        self.assertTrue(all(item["tasks"] == ["alpha"] for item in leases))

    def test_overlap_warns_but_does_not_block(self) -> None:
        checkout = self.checkout()
        first = self.payload("one", "PreToolUse", checkout)
        second = self.payload("two", "PreToolUse", checkout, camel=True)
        self.run_coord("hook", "--client", "claude", payload=first)
        result = self.run_coord("hook", "--client", "codex", payload=second)

        output = json.loads(result.stdout)
        self.assertIn("advisory", output["systemMessage"])
        self.assertEqual(len(self.records("sessions")), 2)

    def test_finish_releases_task_and_preserves_handoff(self) -> None:
        claim = ".claude/skills/coordination/coord claim alpha"
        finish = (
            ".claude/skills/coordination/coord finish alpha "
            "--outcome paused --checkpoint 'tests pass; review pending'"
        )
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("one", "PreToolUse", self.root, claim),
        )
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("one", "PostToolUse", self.root, finish),
        )
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("one", "Stop", self.root),
        )

        lease = self.records("sessions")[0]
        task = self.records("tasks")[0]
        self.assertEqual(lease["tasks"], [])
        self.assertEqual(lease["phase"], "ended")
        self.assertEqual(task["status"], "paused")
        self.assertEqual(task["checkpoint"], "tests pass; review pending")
        self.assertEqual(self.run_coord("guard-remove", "alpha").returncode, 0)

    def test_record_mr_preserves_known_target_branch(self) -> None:
        self.run_coord("claim", "alpha")
        self.run_coord(
            "record-mr",
            "--task", "alpha",
            "--repo", "api",
            "--checkout", "worktrees/alpha/step/api",
            "--branch", "feature/alpha-step",
            "--sha", "abc123",
            "--url", "https://github.com/group/api/pull/7",
            "--state", "created",
            "--target", "feature/alpha-base",
        )

        task = self.records("tasks")[0]
        repo = task["repos"]["worktrees/alpha/step/api"]
        self.assertEqual(repo["targetBranch"], "feature/alpha-base")
        self.assertEqual(repo["mrState"], "opened")

    def test_active_lease_guards_remove_then_session_end_releases_it(self) -> None:
        checkout = self.checkout()
        active = self.payload("one", "PreToolUse", checkout)
        self.run_coord("hook", "--client", "claude", payload=active)
        blocked = self.run_coord("guard-remove", "alpha", check=False)
        self.assertEqual(blocked.returncode, 1)
        self.assertIn("active leases", blocked.stderr)

        ended = self.payload("one", "SessionEnd", checkout)
        self.run_coord("hook", "--client", "claude", payload=ended)
        self.assertEqual(self.run_coord("guard-remove", "alpha").returncode, 0)

    def test_parent_lease_guards_nested_task_removal(self) -> None:
        command = ".claude/skills/coordination/coord claim alpha"
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("one", "PreToolUse", self.root, command),
        )
        blocked = self.run_coord("guard-remove", "alpha/child", check=False)
        self.assertEqual(blocked.returncode, 1)
        self.assertIn("active leases", blocked.stderr)

    def test_cleaning_task_denies_new_tool_use(self) -> None:
        self.run_coord("finish", "alpha", "--outcome", "paused")
        task_file = next((self.root / ".coordination/tasks").glob("*.json"))
        task = json.loads(task_file.read_text(encoding="utf-8"))
        task["status"] = "cleaning"
        task_file.write_text(json.dumps(task), encoding="utf-8")

        command = ".claude/skills/coordination/coord claim alpha"
        result = self.run_coord(
            "hook", "--client", "codex",
            payload=self.payload("new", "PreToolUse", self.root, command, camel=True),
        )
        output = json.loads(result.stdout)
        decision = output["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertEqual(self.records("sessions"), [])

    def test_parent_cleaning_task_denies_nested_tool_use(self) -> None:
        checkout = self.checkout("alpha/child", "config")
        self.run_coord("finish", "alpha", "--outcome", "paused")
        task_file = next((self.root / ".coordination/tasks").glob("*.json"))
        task = json.loads(task_file.read_text(encoding="utf-8"))
        task["status"] = "cleaning"
        task_file.write_text(json.dumps(task), encoding="utf-8")

        result = self.run_coord(
            "hook",
            "--client",
            "codex",
            payload=self.payload("nested", "PreToolUse", checkout, camel=True),
        )

        decision = json.loads(result.stdout)["hookSpecificOutput"]
        self.assertEqual(decision["permissionDecision"], "deny")
        self.assertIn("Task alpha", decision["permissionDecisionReason"])
        self.assertEqual(self.records("sessions"), [])

    def test_raw_tool_input_is_not_persisted(self) -> None:
        checkout = self.checkout()
        sentinel = "SENSITIVE_COMMAND_TEXT_4219"
        payload = self.payload("one", "PreToolUse", checkout, f"echo {sentinel}")
        self.run_coord("hook", "--client", "claude", payload=payload)
        stored = "".join(
            path.read_text(encoding="utf-8")
            for path in (self.root / ".coordination").rglob("*.json")
        )
        self.assertNotIn(sentinel, stored)

    def test_parallel_writers_leave_valid_records(self) -> None:
        command = ".claude/skills/coordination/coord claim alpha"
        processes = []
        for index in range(12):
            payload = self.payload(f"session-{index}", "PreToolUse", self.root, command)
            processes.append(subprocess.Popen(
                [str(COORD), "hook", "--client", "claude"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=self.env,
            ))
            processes[-1].stdin.write(json.dumps(payload))
            processes[-1].stdin.close()
        for process in processes:
            stdout = process.stdout.read()
            stderr = process.stderr.read()
            code = process.wait()
            self.assertEqual(code, 0, f"stdout={stdout!r} stderr={stderr!r}")

        self.assertEqual(len(self.records("sessions")), 12)
        tasks = self.records("tasks")
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]["task"], "alpha")

    def test_stale_is_suspected_not_active(self) -> None:
        command = ".claude/skills/coordination/coord claim alpha"
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("old", "PreToolUse", self.root, command),
        )
        lease_file = next((self.root / ".coordination/sessions").glob("*.json"))
        lease = json.loads(lease_file.read_text(encoding="utf-8"))
        lease["heartbeatAt"] = (
            dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=2)
        ).isoformat().replace("+00:00", "Z")
        lease_file.write_text(json.dumps(lease), encoding="utf-8")

        status = self.run_coord("status", "alpha")
        self.assertIn("stale", status.stdout)
        self.assertEqual(self.run_coord("guard-remove", "alpha").returncode, 0)

    def test_release_hands_the_task_back_and_keeps_the_handoff(self) -> None:
        checkout = self.checkout()
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("one", "PreToolUse", checkout),
        )
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload(
                "one", "PostToolUse", self.root,
                ".claude/skills/coordination/coord finish alpha --outcome mr",
            ),
        )
        released = self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload(
                "one", "PreToolUse", checkout,
                ".claude/skills/coordination/coord release alpha",
            ),
        )
        self.assertEqual(released.returncode, 0)

        lease = self.records("sessions")[0]
        task = self.records("tasks")[0]
        self.assertEqual(lease["tasks"], [])
        self.assertEqual(lease["checkouts"], [])
        # The session is still alive and still working; only the task went back.
        self.assertNotEqual(lease["phase"], "ended")
        # A release must not resurrect the handoff as `working`.
        self.assertEqual(task["status"], "mr")
        self.assertEqual(self.run_coord("release", "alpha").returncode, 0)

    def test_release_reports_when_no_hook_lease_exists(self) -> None:
        self.run_coord("claim", "alpha", check=False)
        result = self.run_coord("release", "alpha", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("hooks may need sync", result.stderr)

    def test_gc_removes_terminal_records_older_than_retention(self) -> None:
        self.run_coord("claim", "alpha", check=False)
        self.run_coord("finish", "alpha", "--outcome", "no-changes")
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("one", "SessionEnd", self.root),
        )
        self.age_records("tasks", "updatedAt", 30)
        self.age_records("sessions", "heartbeatAt", 30)

        dry = self.run_coord("gc")
        self.assertIn("dry-run", dry.stdout)
        self.assertEqual(len(self.record_paths("tasks")), 1)
        self.assertEqual(len(self.record_paths("sessions")), 1)

        applied = self.run_coord("gc", "--apply")
        self.assertIn("removed 2 record(s)", applied.stdout)
        self.assertEqual(self.record_paths("tasks"), [])
        self.assertEqual(self.record_paths("sessions"), [])

    def test_gc_keeps_recent_and_unfinished_records(self) -> None:
        self.run_coord("claim", "alpha", check=False)
        self.run_coord("finish", "alpha", "--outcome", "no-changes")
        self.run_coord("claim", "beta", check=False)
        self.run_coord("finish", "beta", "--outcome", "mr", "--mr-url", "https://example.invalid/1")
        self.age_records("tasks", "updatedAt", 30)

        # alpha is terminal and old; beta still has an open MR.
        self.run_coord("gc", "--apply")
        remaining = [item["task"] for item in self.records("tasks")]
        self.assertEqual(remaining, ["beta"])

        self.run_coord("claim", "gamma", check=False)
        self.run_coord("finish", "gamma", "--outcome", "no-changes")
        self.run_coord("gc", "--apply")
        self.assertIn("gamma", [item["task"] for item in self.records("tasks")])

    def test_gc_keeps_a_terminal_task_whose_worktree_still_exists(self) -> None:
        self.checkout("alpha")
        self.run_coord("claim", "alpha", "--checkout", "worktrees/alpha/api", check=False)
        self.run_coord("finish", "alpha", "--outcome", "no-changes")
        self.age_records("tasks", "updatedAt", 30)

        result = self.run_coord("gc", "--apply")
        self.assertIn("no terminal record is older than", result.stdout)
        self.assertEqual([item["task"] for item in self.records("tasks")], ["alpha"])

    def test_gc_keeps_a_terminal_task_an_agent_is_still_holding(self) -> None:
        self.run_coord("claim", "alpha", check=False)
        self.run_coord("finish", "alpha", "--outcome", "no-changes")
        self.age_records("tasks", "updatedAt", 30)
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload(
                "one", "PreToolUse", self.root,
                ".claude/skills/coordination/coord claim alpha",
            ),
        )

        self.run_coord("gc", "--apply")
        self.assertEqual([item["task"] for item in self.records("tasks")], ["alpha"])

    def test_gc_keeps_a_stale_lease_that_still_owns_a_task(self) -> None:
        checkout = self.checkout()
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("one", "PreToolUse", checkout),
        )
        self.age_records("sessions", "heartbeatAt", 30)

        self.run_coord("gc", "--apply")
        lease = self.records("sessions")[0]
        self.assertEqual(lease["tasks"], ["alpha"])

        # Ending the session hands the task back, and only then is it collectable.
        self.run_coord(
            "hook", "--client", "claude",
            payload=self.payload("one", "SessionEnd", checkout),
        )
        self.age_records("sessions", "heartbeatAt", 30)
        self.run_coord("gc", "--apply")
        self.assertEqual(self.record_paths("sessions"), [])

    def test_gc_leaves_the_archive_alone(self) -> None:
        archive = self.root / ".coordination" / "archive"
        archive.mkdir(parents=True, exist_ok=True)
        snapshot = archive / "old.json"
        snapshot.write_text(json.dumps({"task": "alpha"}), encoding="utf-8")
        self.run_coord("claim", "alpha", check=False)
        self.run_coord("finish", "alpha", "--outcome", "no-changes")
        self.age_records("tasks", "updatedAt", 30)

        self.run_coord("gc", "--apply")
        self.assertTrue(snapshot.is_file())

    def test_gc_window_is_configurable(self) -> None:
        self.run_coord("claim", "alpha", check=False)
        self.run_coord("finish", "alpha", "--outcome", "no-changes")
        self.age_records("tasks", "updatedAt", 3)

        self.run_coord("gc", "--apply")
        self.assertEqual(len(self.record_paths("tasks")), 1)

        self.run_coord("gc", "--older-than", "2d", "--apply")
        self.assertEqual(self.record_paths("tasks"), [])

    def test_gc_rejects_an_unparsable_window(self) -> None:
        result = self.run_coord("gc", "--older-than", "soon", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("14d", result.stderr)

    def test_doctor_fails_on_corrupt_record(self) -> None:
        sessions = self.root / ".coordination/sessions"
        sessions.mkdir(parents=True)
        (sessions / "broken.json").write_text("{", encoding="utf-8")
        result = self.run_coord("doctor", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("error:", result.stdout)

if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(CoordinationTest)
    outcome = unittest.TextTestRunner(verbosity=2).run(suite)
    if outcome.wasSuccessful():
        print(f"  {outcome.testsRun} coordination behavior tests pass")
    sys.exit(0 if outcome.wasSuccessful() else 1)
