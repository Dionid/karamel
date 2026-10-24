#!/usr/bin/env python3
"""Self-test хука enforce-agent-routing.py — грубый гард: root только оркестрирует.

Хук обязан: не ограничивать субагента; запрещать root запись в воркспейс и в
`.claude/settings*.json`, пропуская запись вне воркспейса; запрещать live-команды
даже после Agent; пропускать оркестрацию и чтение, а прочее — только после
Agent; напоминать раз за ход; не открывать ход служебными записями; слушаться
выключателя и пропускать мусор. Тест краснеет, если хук удалён, потерял
исполняемый бит, перестал запрещать или начал запрещать оркестрацию.

    python3 agents/common/tests/enforce-agent-routing.test.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HOOK = ROOT / "agents" / "common" / "hooks" / "enforce-agent-routing.py"
_ids = iter(range(1, 10**6))


def human(uuid: str, text: str = "обнови стенд") -> dict:
    return {"type": "user", "uuid": uuid, "origin": {"kind": "human"},
            "message": {"role": "user", "content": text}}


def task_notification(uuid: str) -> dict:
    return {"type": "user", "uuid": uuid, "origin": {"kind": "task-notification"},
            "message": {"role": "user", "content": "<task-notification>done</task-notification>"}}


def tool_result(uuid: str) -> dict:
    return {"type": "user", "uuid": uuid, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "t1", "content": "ok"}]}}


def handback(uuid: str) -> dict:
    return {"type": "user", "uuid": uuid, "isMeta": True, "origin": {"kind": "peer", "from": "w"},
            "message": {"role": "user", "content": "<peer-message>готово</peer-message>"}}


def assistant(tool: str, tool_input: dict | None = None) -> dict:
    return {"type": "assistant", "uuid": f"a{next(_ids)}", "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": f"tu{next(_ids)}", "name": tool, "input": tool_input or {}}]}}


class Env:
    def __init__(self) -> None:
        base = Path(tempfile.mkdtemp()).resolve()
        self.project, self.scratch, self.state = base / "workspace", base / "scratch", base / "state"
        for d in (self.project / "worktrees", self.scratch, self.state):
            d.mkdir(parents=True)

    def run(self, tool: str, tool_input: dict, entries=(), extra=None, env=None,
            raw: str | None = None, session: str = "s1", cwd=None) -> tuple[int, str]:
        path = self.state / "t.jsonl"
        path.write_text("".join(json.dumps(e) + "\n" for e in entries))
        payload = {"session_id": session, "cwd": str(cwd or self.project), "transcript_path": str(path),
                   "tool_name": tool, "tool_input": tool_input, **(extra or {})}
        environ = {k: v for k, v in os.environ.items() if k != "AGENT_ROUTING_GUARD"}
        environ.update({"TMPDIR": str(self.state), "CLAUDE_PROJECT_DIR": str(self.project), **(env or {})})
        proc = subprocess.run([str(HOOK)], input=raw if raw is not None else json.dumps(payload),
                              capture_output=True, text=True, timeout=30, env=environ)
        return proc.returncode, proc.stdout.strip()


def spec(out: str) -> dict:
    return json.loads(out)["hookSpecificOutput"] if out else {}


def denied(out: str) -> bool:
    return spec(out).get("permissionDecision") == "deny"


def reminded(out: str) -> bool:
    data = spec(out)
    return "permissionDecision" not in data and "agent-directed-routing" in data.get("additionalContext", "")


def main() -> int:
    failures = 0

    def check(name: str, ok: bool) -> None:
        nonlocal failures
        print(f"  {'ok  ' if ok else 'FAIL'}  {name}")
        failures += not ok

    if not HOOK.is_file() or not HOOK.stat().st_mode & 0o111:
        print(f"  FAIL  {HOOK.relative_to(ROOT)} отсутствует или не исполняемый")
        return 1

    turn = [human("u1")]
    after_agent = [human("u1"), assistant("Agent", {"prompt": "x"}), tool_result("r1")]
    after_send = [human("u1"), assistant("SendMessage", {"to": "w"}), tool_result("r1")]

    e = Env()
    bash = lambda cmd, entries=turn, **kw: e.run("Bash", {"command": cmd}, entries, **kw)  # noqa: E731

    # --- субагент ---
    for tool, tin in (("Edit", {"file_path": str(e.project / "AGENTS.md")}),
                      ("Bash", {"command": "ssh host uptime"}), ("Bash", {"command": "python3 x.py"})):
        code, out = e.run(tool, tin, turn, extra={"agent_id": "sub-1"})
        check(f"субагент: {tool} {list(tin.values())[0][-20:]} без ограничений", code == 0 and not out)

    # --- запись ---
    case_variant = e.project.parent / e.project.name.upper() / "AGENTS.md"
    for name, target in (("в воркспейс", e.project / "AGENTS.md"),
                         ("через ..", e.project / "worktrees" / ".." / "AGENTS.md"),
                         ("из scratch через ..", e.scratch / ".." / "workspace" / "x.md"),
                         ("в другом регистре", case_variant),
                         ("относительный путь", Path("agents/x.md"))):
        for tool in ("Edit", "Write", "MultiEdit"):
            check(f"{tool} {name} — deny", denied(e.run(tool, {"file_path": str(target)}, after_agent)[1]))
    check("NotebookEdit в воркспейс — deny",
          denied(e.run("NotebookEdit", {"notebook_path": str(e.project / "n.ipynb")}, after_agent)[1]))
    check("Write в scratch — allow", not e.run("Write", {"file_path": str(e.scratch / "mr.md")}, turn)[1])
    for target in (e.scratch / ".claude" / "settings.json", Path.home() / ".claude" / "settings.local.json"):
        check(f"Write {target.parent.name}/{target.name} — deny",
              denied(e.run("Write", {"file_path": str(target)}, after_agent)[1]))
    code, out = e.run("Edit", {"file_path": str(e.project / "a")}, (), extra={"transcript_path": ""})
    check("запись в воркспейс без transcript — всё равно deny", denied(out))
    (e.scratch / "link").symlink_to(e.project / "worktrees")
    check("Write через симлинк вне воркспейса внутрь — deny",
          denied(e.run("Write", {"file_path": str(e.scratch / "link" / "x.md")}, after_agent)[1]))

    # --- live: deny всегда ---
    for cmd in ("ssh h uptime", "cd /tmp && ssh h", "scp a h:b", "docker ps", "kubectl get pods",
                "helm list", "terraform apply", "psql -c 'select 1'", "aws s3 ls", "gcloud run deploy",
                "npm install", "npx x", "pip install x", "brew install x", "make build", "go test ./...",
                "cargo build", "gh pr list", "gh api user", "git push", "git -C repo commit -m x",
                "git -c a=b reset --hard", "./ops sync", f"{e.project}/ops setup",
                ".claude/skills/db-query/query.sh x", "FOO=1 sudo -n timeout 5 kubectl get x",
                "echo $(docker ps)", "ls | xargs rsync", "true\nssh h", "echo `docker ps`",
                f"python3 {e.project}/.claude/skills/db-query/x.py",
                "git stash", "git stash -u", "git stash pop", "git stash drop", "git stash clear",
                "git branch -D x", "git branch --set-upstream-to=o/x", "git branch new-x",
                "git worktree add ../x", "git worktree remove x", "git worktree prune",
                "git config user.name x", "git config --global --get x", "git config --unset x",
                "git remote add o u", "git remote set-url o u", "git remote rm o",
                "git fetch origin main:main", "git symbolic-ref -d HEAD",
                "cat <<EOF\nx\nEOF\nssh h"):
        check(f"live {cmd[:40]!r} — deny даже после Agent", denied(bash(cmd, after_agent)[1]))
    code, out = e.run("Bash", {"command": "ssh h"}, (), extra={"transcript_path": ""})
    check("live без transcript — всё равно deny", denied(out))

    # --- оркестрация и чтение до Agent ---
    for cmd in (".claude/skills/coordination/coord status", f"{e.project}/.claude/skills/wt/wt new t --pull",
                f"W={e.project}/agents/common/skills/agent-directed-routing/writer.py; python3 $W spawn",
                f"bash {e.project}/.claude/skills/commit-and-mr/run.sh --dry-run",
                f"{e.project}/ops check", "./ops status", "git -C d status", "git log --oneline | head",
                "ls -la 2>&1 | head", "rg 'a|b' agents", "cat x; echo done",
                "cat > /tmp/x/mr.md <<'EOF'\n## How to test\nmake test\ndon't\nEOF",
                "cat <<-EOF > /tmp/a\n\tpython3 x.py\n\tEOF\nls",
                "# проверка lease\n.claude/skills/coordination/coord status",
                "export W=.claude/skills/agent-directed-routing/writer.py; python3 $W start",
                "source .env && .claude/skills/env-check/env-check.sh X",
                ". $CLAUDE_PROJECT_DIR/.env; ls", "{ git status; git log -1; }",
                "git stash list", "git stash show -p", "git branch --show-current", "git branch -a",
                "git branch --contains abc", "git worktree list", "git config --get x",
                "git config user.name", "git remote -v", "git fetch origin", "git rev-list --count HEAD",
                "git cat-file -p HEAD", "git for-each-ref refs/heads", "git symbolic-ref HEAD",
                "git describe --tags", "git check-ignore x"):
        code, out = bash(cmd)
        check(f"`{cmd[-45:]!r}` до Agent — allow", code == 0 and not denied(out))

    # --- прочее: только после Agent ---
    for cmd in ("/tmp/skills/wt/x.sh", "python3 x.py", "ls && python3 -m pytest", "./script.sh",
                "source x.sh", "cat <<EOF\nx\nEOF\npython3 x.py", "cd /tmp && .claude/skills/wt/wt list"):
        check(f"`{cmd!r}` до Agent — deny", denied(bash(cmd)[1]))
    code, out = e.run("Bash", {"command": f"cd {e.project} && .claude/skills/wt/wt list"}, turn, cwd=e.scratch)
    check("`cd <проект> && .claude/skills/…` из чужого cwd — allow", code == 0 and not out)
    handback_turn = after_agent + [human("u2", "как дела?"), handback("h1")]
    for name, entries in (("Agent", after_agent), ("SendMessage", after_send),
                          ("handback в ходе", handback_turn),
                          ("task-notification в ходе", turn + [task_notification("n0")])):
        code, out = bash("python3 x.py", entries)
        check(f"`python3 x.py` после {name} — allow", code == 0 and not out)

    # --- ход и напоминание ---
    e = Env()
    code, out1 = e.run("Read", {"file_path": "/x"}, turn)
    _, out2 = e.run("Grep", {"pattern": "x"}, turn + [assistant("Read")])
    _, out3 = e.run("Bash", {"command": "ls"}, turn + [assistant("Read")] * 40)
    check("напоминание — один раз за ход, без лимита чтений",
          reminded(out1) and not out2 and not out3 and code == 0)
    _, out = e.run("Read", {"file_path": "/x"}, turn + [human("u2")])
    check("новый ход — новое напоминание", reminded(out))
    _, out = e.run("Read", {"file_path": "/x"}, after_agent + [human("u3")])
    check("после Agent в прошлом ходе — напоминание снова", reminded(out))
    _, out = e.run("Read", {"file_path": "/x"}, after_agent)
    check("после Agent в этом ходе — без напоминания", not out)

    slash = human("u9", "<command-message>fix</command-message>\n<command-name>/fix</command-name>")
    slash_name = human("u10", "<command-name>/review</command-name>")
    for name, entry in (("<command-message>", slash), ("<command-name>/", slash_name)):
        check(f"slash-команда ({name}) открывает новый ход",
              denied(e.run("Bash", {"command": "python3 x.py"}, after_agent + [entry])[1]))
    text_notification = {"type": "user", "uuid": "n2", "message": {"role": "user", "content": [
        {"type": "text", "text": "<task-notification>x</task-notification>"}]}}
    for name, entry in (("task-notification", task_notification("n1")), ("tool_result", tool_result("r2")),
                        ("peer handback", handback("h2")), ("isSidechain", {**human("u5"), "isSidechain": True}),
                        ("isCompactSummary", {**human("u6"), "isCompactSummary": True}),
                        ("текстовый <task-notification>", text_notification)):
        _, out = e.run("Bash", {"command": "python3 x.py"}, after_agent + [entry])
        check(f"{name} не открывает ход", not out)
    sidechain_agent = {**assistant("Agent"), "isSidechain": True}
    check("Agent в sidechain не открывает root",
          denied(e.run("Bash", {"command": "python3 x.py"}, turn + [sidechain_agent])[1]))

    # --- выключатель и fail-open ---
    for tool, tin in (("Bash", {"command": "ssh h"}), ("Edit", {"file_path": str(e.project / "a")})):
        code, out = e.run(tool, tin, turn, env={"AGENT_ROUTING_GUARD": "off"})
        check(f"AGENT_ROUTING_GUARD=off — {tool} без вывода", code == 0 and not out)
    for name, raw in (("пусто", ""), ("не json", "{oops"), ("массив", "[1]"),
                      ("нет tool_input", '{"tool_name":"Bash"}')):
        code, out = e.run("Bash", {}, raw=raw)
        check(f"мусор ({name}) — 0 без вывода", code == 0 and not out)
    code, out = e.run("Bash", {"command": "python3 x.py"}, extra={"transcript_path": "/nonexistent"})
    check("нет transcript — 0 без вывода", code == 0 and not out)
    (e.state / "agent-routing-reminder-sym").symlink_to(e.state / "target")
    code, out = e.run("Read", {"file_path": "/x"}, turn, session="sym")
    check("state-симлинк не пишется", code == 0 and not (e.state / "target").exists())

    # --- регистрация ---
    settings = json.loads((ROOT / "agents/claude/settings.base.json").read_text())
    mine = [g for g in settings.get("hooks", {}).get("PreToolUse", [])
            if any("enforce-agent-routing.py" in h.get("command", "") for h in g.get("hooks", []))]
    need = {"Bash", "Edit", "Write", "MultiEdit", "NotebookEdit", "Read", "Grep", "Glob"}
    check("хук зарегистрирован под PreToolUse с matcher, включающим MultiEdit",
          len(mine) == 1 and need <= set((mine[0].get("matcher") or "").split("|")))

    print(f"\n  {'провалено ' + str(failures) if failures else 'все проверки прошли'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
