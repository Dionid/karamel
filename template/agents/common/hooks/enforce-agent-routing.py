#!/usr/bin/env python3
"""PreToolUse hook (Claude Code): root только оркестрирует, работу делает child.

Грубый гард привычки, не песочница ; субагент (`agent_id`) свободен.
1. Edit/Write/MultiEdit/NotebookEdit в `$CLAUDE_PROJECT_DIR` (realpath, без
   учёта регистра) и в любой `.claude/settings*.json` — deny; вне — можно.
2. Bash режется на сегменты; первое слово (после `VAR=…` и обёрток) из списка
   LIVE, gh, мутирующий git, `ops sync|setup`, db-query — deny всегда.
3. Сегменты-оркестрация (скрипты skill воркспейса, `ops check|status`) и
   чтение — allow; иное — deny до Agent/Task/SendMessage/Workflow или ответа
   child в ходе. Тело heredoc, `# …`, `{ }` не сегменты; `cd`/`export` учтены.
4. Read/Grep/Glob и читающий Bash без Agent — одно напоминание за ход.
Не видит редиректы, inline-код интерпретаторов и всё после Agent-вызова.
`AGENT_ROUTING_GUARD=off` выключает; любой сбой — exit 0 без вывода.
Тест: agents/common/tests/enforce-agent-routing.test.py
"""

from __future__ import annotations

import json
import os
import re
import shlex
import sys
import tempfile
from pathlib import Path

REMINDER = (
    "Напоминание: Track выбран? Работу исполняет child по skill "
    "agent-directed-routing (Q/P — explorer, E — scout, F/H/I — worker, C — "
    "spec-loop/build-loop), включая live-операции без diff. Root только классифицирует, "
    "готовит dispatch-prompt и проверяет результат; исключение — Track Q/E с одним "
    "известным источником . Если child не стартует по "
    "bounded fallback — сообщите о сбое делегирования, а не доделывайте сами."
)
WRITE_REASON = (
    "Root не пишет в {path}: правка воркспейса — работа worker, а "
    ".claude/settings*.json (выключатель гарда) меняет человек. Отправьте child "
    "по agent-directed-routing; вне воркспейса (scratchpad, /tmp) писать можно."
)
LIVE_REASON = (
    "Root не исполняет `{cmd}` сам: live-операции, мутирующий git, пакетные "
    "менеджеры и сборка — работа child по agent-directed-routing, и вызов Agent "
    "этого не меняет. Отправьте worker (F/H/I) или explorer (Q/P)."
)
UNKNOWN_REASON = (
    "В этом ходе root ещё не вызывал Agent, а `{cmd}` — не оркестрация и не "
    "чтение. Сначала отправьте child по agent-directed-routing; после "
    "Agent-вызова root может запускать проверки результата child."
)

AGENT_TOOLS = {"Agent", "Task", "SendMessage", "Workflow"}
WRITE_TOOLS = {"Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path",
               "NotebookEdit": "notebook_path"}
READ_TOOLS = {"Read", "Grep", "Glob"}
SERVICE_PREFIXES = ("<task-notification>", "<local-command-", "<command-",
                    "[Request interrupted")
COMMAND_PREFIXES = ("<command-name>/", "<command-message>")

LIVE = set("ssh scp rsync sftp mosh docker docker-compose podman kubectl helm terraform "
           "pulumi argocd vault psql mysql mongosh redis-cli pg_dump gcloud gsutil bq aws "
           "az flyctl vercel firebase ansible ansible-playbook npm npx pnpm yarn bun pip "
           "pip3 uv poetry pipx brew gem make go cargo gh".split())
GIT_MUTATING = set("commit push merge rebase reset checkout switch restore cherry-pick "
                   "revert tag rm mv apply am clean add pull".split())
GIT_READ = set("status log diff show fetch ls-remote ls-tree ls-files branch rev-parse blame "
               "grep worktree remote config stash merge-base reflog rev-list cat-file for-each-ref "
               "describe shortlog symbolic-ref name-rev check-ignore count-objects range-diff".split())
BRANCH_LIVE = set("-d -D -f -m -M -c -C --delete --force --move --copy --set-upstream-to -u "
                  "--unset-upstream --edit-description".split())
BRANCH_LIST = set("--list -l --contains --no-contains --merged --no-merged --points-at".split())
CONFIG_LIVE = set("--global --system --add --replace-all --edit -e --rename-section "
                  "--remove-section".split())
READ_CMDS = set("ls cat head tail wc rg grep find sed awk jq yq echo printf pwd date which "
                "file stat sort uniq cut tr diff basename dirname realpath tree cd export "
                "set test true false sleep mktemp".split())
WRAPPERS = set("sudo env command exec timeout nice nohup xargs".split())
INTERPRETERS = set("python python3 bash sh zsh".split())
SKILL_ROOTS = (".claude/skills", ".agents/skills", "agents/common/skills")
HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*['\"]?(\w+)['\"]?")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
WRAPPER_ARG = re.compile(r"^(-.*|\d+(\.\d+)?[smhd]?|[A-Za-z_][A-Za-z0-9_]*=.*)$", re.S)


def split_segments(cmd: str) -> list[str]:
    """Грубо режет команду на сегменты; в '…' не режет, в "…" — только по $( и `.
    Тело heredoc пропускается до строки-разделителя."""
    out, cur, quote, i, docs = [], [], None, 0, []
    while i < len(cmd):
        c, two = cmd[i], cmd[i:i + 2]
        m = HEREDOC.match(cmd, i) if quote is None else None
        if m:
            docs.append(m.group(1)); cur.append(m.group(0)); i = m.end(); continue
        if c == "\n" and quote is None and docs:
            out.append("".join(cur)); cur = []
            rest, k = cmd[i + 1:].split("\n"), 0
            for d in docs:
                while k < len(rest) and rest[k].strip() != d:
                    k += 1
                k += 1
            i, docs = i + 1 + sum(len(x) + 1 for x in rest[:k]), []
            continue
        if quote == "'":
            quote = None if c == "'" else quote
        elif c == "\\" and quote != "'":
            cur.append(cmd[i:i + 2]); i += 2; continue
        elif two == "$(" or c == "`" or (quote is None and (
                two in ("&&", "||") or c in ";|\n(" or (
                    c == "&" and cmd[i - 1:i] not in "<>" and cmd[i + 1:i + 2] != ">"))):
            out.append("".join(cur)); cur = []
            i += 2 if two in ("$(", "&&", "||") else 1
            continue
        elif c in "'\"" and quote is None:
            quote = c
        elif c == '"' and quote == '"':
            quote = None
        cur.append(c); i += 1
    out.append("".join(cur))
    return out

def words(segment: str) -> list[str]:
    try:
        toks = shlex.split(segment)
    except ValueError:
        toks = segment.split()
    return [t.rstrip(")") for t in toks if t.strip(")")]

def expand(word: str, env: dict) -> str:
    word = re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?",
                  lambda m: env.get(m.group(1), m.group(0)), word)
    return os.path.expanduser(word)

def git_kind(sub: str, args: list[str]) -> str:
    """live — мутирующие git и мутирующие формы читающих подкоманд."""
    flags = {a.split("=")[0] for a in args if a.startswith("-")}
    pos = [a for a in args if not a.startswith("-")]
    first = pos[0] if pos else ""
    if (sub in GIT_MUTATING
            or (sub == "stash" and first not in ("list", "show"))
            or (sub == "branch" and (flags & BRANCH_LIVE or (pos and not flags & BRANCH_LIST)))
            or (sub == "worktree" and first in ("add", "remove", "move", "prune", "lock", "unlock"))
            or (sub == "config" and (flags & CONFIG_LIVE or len(pos) > 1
                                     or any(f.startswith("--unset") for f in flags)))
            or (sub == "remote" and first in ("add", "remove", "rm", "rename", "set-url",
                                              "set-head", "set-branches", "prune"))
            or (sub == "fetch" and any(":" in a for a in pos[1:]))
            or (sub == "symbolic-ref" and (flags & {"-d", "--delete"} or len(pos) > 1))):
        return "live"
    return "read" if sub in GIT_READ else "unknown"

def is_orchestration(word: str, args: list[str], cwd: str, project: str) -> bool:
    path = os.path.realpath(os.path.join(cwd, word)) if "/" in word else ""
    if not path:
        return False
    if path == os.path.join(project, "ops"):
        return bool(args) and args[0] in ("check", "status")
    return any(path.startswith(os.path.join(project, r) + os.sep) for r in SKILL_ROOTS)

def classify_segment(segment: str, env: dict, project: str) -> tuple[str, str]:
    toks = words(segment)
    toks = toks[toks[:1] == ["{"]:len(toks) - (toks[-1:] == ["}"])]
    if toks and toks[0].startswith("#"):
        return "none", ""
    if toks and toks[0] == "export":
        toks = [t for t in toks[1:] if ASSIGN.match(t)]
    while toks and ASSIGN.match(toks[0]):
        name, value = ASSIGN.match(toks[0]).groups()
        env[name] = expand(value, env)
        toks = toks[1:]
    while toks and os.path.basename(toks[0]) in WRAPPERS:
        toks = toks[1:]
        while toks and WRAPPER_ARG.match(toks[0]):
            toks = toks[1:]
    if not toks:
        return "none", ""
    toks = [expand(t, env) for t in toks]
    first, args, cwd = toks[0], toks[1:], env["PWD"]
    base = os.path.basename(first)
    shown = " ".join(toks)[:80]
    if base == "cd":
        env["PWD"] = os.path.join(cwd, args[0]) if args else env["HOME"]
        return "read", shown
    if base in ("source", ".") and args and os.path.realpath(
            os.path.join(cwd, args[0])) == os.path.join(project, ".env"):
        return "read", shown
    if base in LIVE or re.search(r"skills/db-query/", first):
        return "live", shown
    if base == "ops" and args and args[0] in ("sync", "setup"):
        return "live", shown
    if base == "git":
        rest = list(args)
        while rest and rest[0].startswith("-"):
            rest = rest[2:] if rest[0] in ("-C", "-c") else rest[1:]
        return git_kind(rest[0] if rest else "", rest[1:]), shown
    if base in INTERPRETERS:
        script = next((a for a in args if not a.startswith("-")), "")
        if script and re.search(r"skills/db-query/", script):
            return "live", shown
        if script and is_orchestration(script, [], cwd, project):
            return "orch", shown
        return "unknown", shown
    if is_orchestration(first, args, cwd, project):
        return "orch", shown
    return ("read", shown) if base in READ_CMDS else ("unknown", shown)

def classify_bash(cmd: str, cwd: str, project: str) -> tuple[str, str]:
    env = {"CLAUDE_PROJECT_DIR": project, "HOME": os.path.expanduser("~"), "PWD": cwd}
    verdict, first_unknown = "none", ""
    for segment in split_segments(cmd):
        kind, shown = classify_segment(segment, env, project)
        if kind == "live":
            return kind, shown
        if kind == "unknown" and not first_unknown:
            first_unknown = shown
        if kind == "read" and verdict == "none":
            verdict = "read"
    return ("unknown", first_unknown) if first_unknown else (verdict, "")


def write_blocked(target: str, cwd: str, project: str) -> bool:
    path = os.path.normpath(os.path.join(cwd, os.path.expanduser(target)))
    for p in (path, os.path.realpath(path)):
        name = os.path.basename(p).casefold()
        if (os.path.basename(os.path.dirname(p)).casefold() == ".claude"
                and name.startswith("settings") and name.endswith(".json")):
            return True
        a, b = p.casefold(), project.casefold()
        if a == b or a.startswith(b.rstrip(os.sep) + os.sep):
            return True
    return False


def entry_kind(entry: dict) -> str:
    """human — начало хода (человек или его slash-команда); child — делегирование
    в ходе (Agent-вызов, peer handback, task-notification); иначе пусто."""
    msg = entry.get("message") or {}
    content = msg.get("content") if isinstance(msg, dict) else None
    blocks = [b for b in content if isinstance(b, dict)] if isinstance(content, list) else []
    if entry.get("isSidechain") or entry.get("type") not in ("user", "assistant"):
        return ""
    if entry.get("type") == "assistant":  # Agent/Task/SendMessage/Workflow
        return "child" if any(b.get("type") == "tool_use" and b.get("name") in AGENT_TOOLS
                              for b in blocks) else ""
    origin = entry.get("origin") if isinstance(entry.get("origin"), dict) else {}
    if blocks:
        kinds = [b.get("type") for b in blocks]
        if "tool_result" in kinds or not any(k in ("text", "image") for k in kinds):
            return ""
        content = next((b.get("text") for b in blocks if b.get("type") == "text"), "[image]")
    text = content.strip() if isinstance(content, str) else ""
    if origin.get("kind") in ("peer", "task-notification") or text.startswith("<task-notification>"):
        return "child"
    if (entry.get("isMeta") or entry.get("isCompactSummary") or not text
            or origin.get("kind", "human") != "human"):
        return ""
    return "human" if text.startswith(COMMAND_PREFIXES) or not text.startswith(SERVICE_PREFIXES) else ""

def last_turn(transcript: Path) -> tuple[str, bool] | None:
    """(uuid последнего хода человека, было ли в нём делегирование) или None."""
    uuid, called = None, False
    for line in transcript.read_text(errors="replace").splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        kind = entry_kind(entry)
        if kind == "human":
            uuid, called = str(entry.get("uuid") or ""), False
        elif kind == "child" and uuid is not None:
            called = True
    return (uuid, called) if uuid else None


def emit(**fields: str) -> None:
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", **fields}},
                     ensure_ascii=False))

def remind_once(session: str, uuid: str) -> None:
    safe = "".join(c for c in session if c.isalnum() or c in "-_")[:80]
    state = Path(os.environ.get("TMPDIR") or tempfile.gettempdir()) / f"agent-routing-reminder-{safe}"
    try:
        if state.read_text().strip() == uuid:
            return
    except OSError:
        pass
    try:
        fd = os.open(state, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(uuid)
    except OSError:
        return
    emit(additionalContext=REMINDER)

def main() -> None:
    if os.environ.get("AGENT_ROUTING_GUARD", "").strip().lower() == "off":
        return
    payload = json.loads(sys.stdin.read())
    if not isinstance(payload, dict) or payload.get("agent_id"):
        return
    tool, tool_input = payload.get("tool_name"), payload.get("tool_input")
    if not isinstance(tool, str) or not isinstance(tool_input, dict):
        return
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else ""
    project_raw = os.environ.get("CLAUDE_PROJECT_DIR") or cwd
    if not project_raw or not os.path.isabs(project_raw):
        return
    project = os.path.realpath(project_raw)
    cwd = cwd if cwd and os.path.isabs(cwd) else project

    if tool in WRITE_TOOLS:
        target = tool_input.get(WRITE_TOOLS[tool])
        if isinstance(target, str) and target and write_blocked(target, cwd, project):
            emit(permissionDecision="deny", permissionDecisionReason=WRITE_REASON.format(path=target))
        return
    if tool == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str):
            return
        kind, shown = classify_bash(command, cwd, project)
        if kind == "live":
            emit(permissionDecision="deny", permissionDecisionReason=LIVE_REASON.format(cmd=shown))
            return
    elif tool in READ_TOOLS:
        kind = "read"
    else:
        return

    transcript, session = payload.get("transcript_path"), str(payload.get("session_id") or "")
    if not isinstance(transcript, str) or not transcript or not session:
        return
    turn = last_turn(Path(transcript))
    if turn is None or turn[1]:
        return
    if kind == "unknown":
        emit(permissionDecision="deny", permissionDecisionReason=UNKNOWN_REASON.format(cmd=shown))
    elif kind == "read":
        remind_once(session, turn[0])

if __name__ == "__main__":
    try:
        main()
    except BaseException:  # fail-open: любой сбой — молча пропустить
        pass
    sys.exit(0)
