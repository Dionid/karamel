#!/usr/bin/env python3
"""Проверка SessionEnd-хука review-session-on-end.py без настоящего `claude`.

Хук запускается с подменённым HOME (каталог session-reports в ~/.claude
создаётся во временном каталоге) и с PATH, где `claude` — shell-заглушка: она
записывает argv, окружение и cwd и печатает строку в stdout. Так проверяется
ровно то, что хук обещает:

  * без `WORKSPACE_SESSION_REVIEW=1` ничего не запускается;
  * с флагом команда ограничена: только Read и Skill, MCP выключен, модель и
    бюджет заданы, промпт называет скилл и транскрипт;
  * дочерний процесс получает флаг снятым и маркер против рекурсии, а его
    stdout попадает в отчёт `<дата>-<session_id>.md`;
  * маркер ребёнка, нет `claude`, нет транскрипта, опасный session_id, битый
    ввод — тихий exit 0 без запуска.

    python3 agents/common/tests/review-session-on-end.test.py
"""

from __future__ import annotations

import datetime as dt
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "review-session-on-end.py"

STUB = """#!/bin/sh
out="$STUB_OUT"
for a in "$@"; do printf '%s\\0' "$a"; done > "$out/argv"
printf '%s\\n%s\\n' "${WORKSPACE_SESSION_REVIEW-unset}" "${WORKSPACE_SESSION_REVIEW_CHILD-unset}" > "$out/env"
pwd > "$out/cwd"
echo "# stub report"
: > "$out/done"
"""

FAILURES: list[str] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + (f" — {detail}" if detail and not ok else ""))
    if not ok:
        FAILURES.append(name)


class Sandbox:
    def __init__(self, root: Path, *, with_claude: bool = True) -> None:
        self.root = root
        self.home = root / "home"
        self.home.mkdir()
        self.bin = root / "bin"
        self.bin.mkdir()
        self.out = root / "stub-out"
        self.out.mkdir()
        self.cwd = root / "project"
        self.cwd.mkdir()
        self.transcript = root / "session.jsonl"
        self.transcript.write_text('{"type":"user"}\n')
        if with_claude:
            stub = self.bin / "claude"
            stub.write_text(STUB)
            stub.chmod(0o755)

    def payload(self, **overrides: object) -> str:
        data: dict[str, object] = {
            "session_id": "abc-123_DEF",
            "transcript_path": str(self.transcript),
            "cwd": str(self.cwd),
            "hook_event_name": "SessionEnd",
            "reason": "prompt_input_exit",
        }
        data.update(overrides)
        return json.dumps(data)

    def run(self, stdin: str, **env: str) -> subprocess.CompletedProcess:
        full_env = {"HOME": str(self.home), "PATH": str(self.bin), "STUB_OUT": str(self.out)}
        full_env.update(env)
        return subprocess.run([sys.executable, str(HOOK)], input=stdin, capture_output=True,
                              text=True, timeout=30, env=full_env)

    def wait_stub(self, seconds: float = 10.0) -> bool:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if (self.out / "done").exists():
                return True
            time.sleep(0.05)
        return False

    def launched(self) -> bool:
        # Отрицательный случай: даём фоновому процессу шанс проявиться.
        time.sleep(0.5)
        return (self.out / "argv").exists()

    def reports(self) -> Path:
        return self.home / ".claude" / "session-reports"


def flag_value(argv: list[str], flag: str) -> str | None:
    return argv[argv.index(flag) + 1] if flag in argv else None


def test_without_flag() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        box = Sandbox(Path(tmp))
        proc = box.run(box.payload())
        check("без флага: exit 0, пустой stdout", proc.returncode == 0 and not proc.stdout.strip(),
              f"rc={proc.returncode} out={proc.stdout!r}")
        check("без флага: claude не запускается", not box.launched())
        check("без флага: каталог отчётов не создаётся", not box.reports().exists())
        proc = box.run(box.payload(), WORKSPACE_SESSION_REVIEW="0")
        check("флаг=0: claude не запускается", proc.returncode == 0 and not box.launched())


def test_with_flag() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        box = Sandbox(Path(tmp))
        proc = box.run(box.payload(), WORKSPACE_SESSION_REVIEW="1")
        check("с флагом: exit 0, пустой stdout", proc.returncode == 0 and not proc.stdout.strip(),
              f"rc={proc.returncode} out={proc.stdout!r} err={proc.stderr!r}")
        if not box.wait_stub():
            check("с флагом: claude запущен", False, "заглушка не отработала за 10 с")
            return
        argv = (box.out / "argv").read_bytes().decode().split("\0")[:-1]

        check("argv: print mode, промпт сразу после -p",
              len(argv) > 1 and argv[0] == "-p" and not argv[1].startswith("-"), repr(argv[:2]))
        prompt = argv[1] if len(argv) > 1 else ""
        check("промпт называет скилл review-chat-session", "review-chat-session" in prompt)
        check("промпт называет транскрипт", str(box.transcript) in prompt)
        check("промпт запрещает запись файлов", "НЕ создавай" in prompt)
        check("--tools только Read,Skill", flag_value(argv, "--tools") == "Read,Skill",
              repr(flag_value(argv, "--tools")))
        check("--allowedTools только Read,Skill",
              flag_value(argv, "--allowedTools") == "Read,Skill",
              repr(flag_value(argv, "--allowedTools")))
        check("MCP выключен: --strict-mcp-config без --mcp-config",
              "--strict-mcp-config" in argv and "--mcp-config" not in argv)
        check("модель ограничена", flag_value(argv, "--model") == "sonnet")
        turns = flag_value(argv, "--max-turns")
        check("--max-turns задан", bool(turns) and turns.isdigit() and int(turns) > 0, repr(turns))
        budget = flag_value(argv, "--max-budget-usd")
        try:
            budget_ok = 0 < float(budget or "x") <= 5
        except ValueError:
            budget_ok = False
        check("--max-budget-usd задан и мал", budget_ok, repr(budget))
        check("сессия ревьюера не сохраняется", "--no-session-persistence" in argv)
        for forbidden in ("Write", "Edit", "Bash", "--dangerously-skip-permissions"):
            check(f"нет {forbidden} в argv",
                  not any(forbidden in a for a in argv[2:]), repr(argv[2:]))

        env_lines = (box.out / "env").read_text().splitlines()
        check("ребёнку флаг снят", env_lines[:1] == ["0"], repr(env_lines))
        check("ребёнку выставлен маркер против рекурсии", env_lines[1:2] == ["1"], repr(env_lines))
        check("ребёнок стартует в cwd сессии",
              Path((box.out / "cwd").read_text().strip()).resolve() == box.cwd.resolve())

        report = box.reports() / f"{dt.date.today().isoformat()}-abc-123_DEF.md"
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and "# stub report" not in (
                report.read_text() if report.exists() else ""):
            time.sleep(0.05)
        check("stdout ребёнка лёг в отчёт <дата>-<session_id>.md",
              report.exists() and "# stub report" in report.read_text(),
              f"{sorted(p.name for p in box.reports().glob('*'))}")
        check("лог stderr рядом с отчётом", report.with_suffix(".log").exists())


def test_skips() -> None:
    cases = [
        ("маркер ребёнка выключает хук", {}, {"WORKSPACE_SESSION_REVIEW_CHILD": "1"}),
        ("нет транскрипта", {"transcript_path": "/nonexistent/x.jsonl"}, {}),
        ("transcript_path не строка", {"transcript_path": None}, {}),
        ("session_id с путём", {"session_id": "../../etc/x"}, {}),
        ("session_id отсутствует", {"session_id": None}, {}),
    ]
    for name, overrides, env in cases:
        with tempfile.TemporaryDirectory() as tmp:
            box = Sandbox(Path(tmp))
            proc = box.run(box.payload(**overrides), WORKSPACE_SESSION_REVIEW="1", **env)
            check(f"{name}: exit 0 без запуска",
                  proc.returncode == 0 and not proc.stdout.strip() and not box.launched(),
                  f"rc={proc.returncode} err={proc.stderr!r}")

    with tempfile.TemporaryDirectory() as tmp:
        box = Sandbox(Path(tmp), with_claude=False)
        proc = box.run(box.payload(), WORKSPACE_SESSION_REVIEW="1")
        check("нет claude в PATH: тихий пропуск",
              proc.returncode == 0 and not proc.stdout.strip() and not proc.stderr.strip()
              and not box.reports().exists(), f"rc={proc.returncode} err={proc.stderr!r}")

    for name, stdin in (("пустой stdin", ""), ("не json", "не json"),
                        ("массив", "[1,2]"), ("обрезанный json", '{"session_id": "a"')):
        with tempfile.TemporaryDirectory() as tmp:
            box = Sandbox(Path(tmp))
            proc = box.run(stdin, WORKSPACE_SESSION_REVIEW="1")
            check(f"битый ввод ({name}): exit 0 без запуска",
                  proc.returncode == 0 and not proc.stdout.strip() and not box.launched(),
                  f"rc={proc.returncode} err={proc.stderr!r}")


def main() -> int:
    if not HOOK.is_file():
        print(f"  FAIL  нет хука {HOOK}")
        return 1
    test_without_flag()
    test_with_flag()
    test_skips()
    if FAILURES:
        print(f"\n  провалено: {len(FAILURES)}")
        return 1
    print("\n  review-session-on-end: все проверки пройдены")
    return 0


if __name__ == "__main__":
    sys.exit(main())
