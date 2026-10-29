#!/usr/bin/env python3
"""PreToolUse/Bash hook: агент не делает force-push. Никогда.

ПРАВИЛО. Перезапись удалённой истории — действие человека. Агент не выполняет
его ни сам, ни по прямой просьбе пользователя: «пользователь попросил» —
ровно та фраза, с которой обычно и теряют чужие коммиты. Хук стоит и на root,
и на субагентах (проверки `agent_id` здесь нет намеренно), и под Claude Code,
и под Codex.

ПОЧЕМУ ХУК, А НЕ ЕЩЁ СТРОКИ В `permissions.deny`. Глоб матчит написание, а не
действие. `Bash(git push -f *)` пропускает `git push -fu origin x`,
`git -C dir push --force`, `git push origin +main`, `timeout 30 git push -f`,
`bash -c "git push -f"` и `a && git push -f`; у Codex `permissions.deny` нет
вовсе. Здесь команда разбирается так, как её прочтёт shell: сегменты, кавычки,
подстановки, обёртки — и решение принимается по аргументам `git push`.

ЧТО СЧИТАЕТСЯ FORCE-PUSH (deny):
  * `-f`, в т.ч. в связке коротких флагов (`-fu`, `-uf`, `-vf`);
  * `--force`, `--force-with-lease[=…]`, `--force-if-includes` и их
    сокращения (git принимает однозначный префикс длинного флага: `--forc`);
  * `--mirror` — сильнее `--force`: принудительно обновляет все refs и удаляет
    на удалённой стороне те, которых нет локально;
  * refspec с `+` (`origin +main`, `+HEAD:refs/heads/x`);
  * `git -c remote.<r>.push=+…` и `git -c remote.<r>.mirror=true` перед push;
  * `git -c alias.<x>=…` и обращение к этому alias, если он разворачивается в
    force-push (включая shell-alias `!…`);
  * то же через `send-pack`/`http-push` и `git-push` по прямому пути.

ЧТО ПРОПУСКАЕТСЯ НАМЕРЕННО:
  * `--dry-run`/`-n` (последний из `--dry-run`/`--no-dry-run` побеждает):
    ничего не отправляется, а предпросмотр «что перезапишется» — ровно то, что
    агент должен показать человеку вместе с командой. Блокировать надо эффект,
    а не написание;
  * `--delete`, `:branch`, `--prune` — удаление ветки не перезапись истории,
    и это обычная уборка после merge;
  * `git fetch --force`, `git stash push`, `git commit -m "git push -f"`,
    `echo`/`rg`/`grep` с этой строкой, тело heredoc, которое не исполняется.

ОБЁРТКИ И СОСТАВНЫЕ КОМАНДЫ. `&&`, `||`, `;`, `|`, `&`, перевод строки,
`( … )`, `{ …; }`, `if/for/while`, `$( … )`, обратные кавычки, `<( … )`;
`env`, `sudo`, `doas`, `command`, `builtin`, `exec`, `nice`, `nohup`, `time`,
`timeout`, `stdbuf`, `ionice`, `xargs`; `sh|bash|zsh|… -c`, heredoc и
`echo … |` в shell; `eval`; `ssh host '…'`; `find -exec`;
`git submodule foreach`; простые `F=--force; git push $F`.

НЕ ВИДИТ (это грубый гард привычки, а не песочница): alias из чужого
`.gitconfig`, `git config remote.x.push +…` отдельной командой, вывод
подстановки в аргументе (`git push $(echo -f)`), скрипт в файле
(`bash push.sh`), интерпретаторы (`python -c …`). Выключателя нет: force-push
делает человек в своём терминале, а не агент с выключенным гардом.

FAIL-OPEN. Непонятный ввод — пропуск (exit 0 без вывода): битый JSON, чужая
форма, незакрытая кавычка, превышенная глубина вложенности, любое исключение.
Гард, падающий на неожиданном вводе, останавливает не опасное действие, а
работу, и его снимают целиком.

Вход: Claude Code — snake_case, команда строкой (`tool_input.command`);
Codex — camelCase (`toolInput.command`), shell-инструменты несут argv
массивом. Отказ — общий для обоих `hookSpecificOutput.permissionDecision =
"deny"`, exit 0. Причина называет найденный признак (флаг, refspec), но не
команду целиком: в URL удалённого репозитория бывает токен.

Тест: agents/common/tests/block-force-push.test.py
"""

from __future__ import annotations

import codecs
import json
import os
import re
import shlex
import sys

SHELL_TOOLS = {"", "Bash", "bash", "shell", "local_shell", "exec_command",
               "unified_exec"}
MAX_DEPTH = 12

REASON = (
    "Force-push заблокирован ({what}). Агент не выполняет force-push никогда, "
    "даже по прямой просьбе пользователя: перезаписанную историю удалённой "
    "ветки не вернуть, а чужие коммиты в ней теряются молча. Его выполняет "
    "человек: передайте ему точную команду и причину, пусть запустит её сам. "
    "Без перезаписи — обычный push, новая ветка или revert-коммит; предпросмотр "
    "`git push --dry-run …` разрешён. Под запретом -f/--force, "
    "--force-with-lease, --force-if-includes, --mirror и refspec с '+'."
)

ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\+?=(.*)$", re.S)
VAR = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")
RESERVED = {"!", "{", "}", "if", "then", "elif", "else", "fi", "while", "until",
            "do", "done", "coproc"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "fish"}
GIT_BINARIES = {"git", "hub"}
PUSH_BINARIES = {"git-push": "push", "git-send-pack": "send-pack",
                 "git-http-push": "http-push"}
PUSH_SUBCOMMANDS = {"push", "send-pack", "http-push"}

# Обёртки, которые просто предваряют другую команду: опции, которым нужен
# отдельный аргумент. Остальные `-…` пропускаются по одному слову.
WRAPPERS = {
    "sudo": {"-u", "-g", "-p", "-C", "-D", "-r", "-t", "-U", "-T", "-R",
             "--user", "--group", "--prompt", "--chdir", "--close-from",
             "--role", "--type", "--other-user", "--command-timeout", "--host"},
    "doas": {"-u", "-C"},
    "env": {"-u", "--unset", "-C", "--chdir", "-P"},
    "command": set(),
    "builtin": set(),
    "exec": {"-a"},
    "nice": {"-n", "--adjustment"},
    "nohup": set(),
    "time": {"-f", "--format", "-o", "--output"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "stdbuf": {"-i", "-o", "-e", "--input", "--output", "--error"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p", "--pid", "-P",
               "--pgid", "-u", "--uid"},
    "xargs": {"-I", "-L", "-n", "-P", "-s", "-d", "-E", "-a", "--arg-file",
              "--delimiter", "--max-args", "--max-lines", "--max-procs",
              "--max-chars", "--replace", "--eof", "--process-slot-var"},
    "noglob": set(),
    "nocorrect": set(),
}
SHELL_LONG_ARG_OPTS = {"--rcfile", "--init-file"}
SSH_ARG_FLAGS = set("BbcDEeFIiJLlmOoPpQRSWw")
GIT_ARG_OPTS = {"-C", "-c", "--git-dir", "--work-tree", "--namespace",
                "--super-prefix", "--config-env"}

FORCE_LONG = ("force", "force-with-lease", "force-if-includes", "mirror")
PUSH_ARG_LONG = ("repo", "receive-pack", "exec", "push-option",
                 "recurse-submodules")


class ParseError(Exception):
    """Ввод, который хук не берётся читать, — повод пропустить, не запретить."""


# ── разбор shell-строки ──────────────────────────────────────────────────────

def _backtick_end(s: str, i: int) -> int:
    while i < len(s):
        if s[i] == "\\":
            i += 2
            continue
        if s[i] == "`":
            return i
        i += 1
    raise ParseError("unterminated `")


def _paren_end(s: str, i: int) -> int:
    """s[i] == '(' → индекс за парной ')'. Кавычки внутри уважаются."""
    depth = 0
    while i < len(s):
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                raise ParseError("unterminated '")
            i = j + 1
            continue
        if c == '"':
            i = _dquote(s, i + 1, [])[1]
            continue
        if c == "`":
            i = _backtick_end(s, i + 1) + 1
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ParseError("unbalanced (")


def _dquote(s: str, i: int, subs: list[str]) -> tuple[str, int]:
    """Тело "…" с i (за открывающей кавычкой) → (текст, индекс за закрывающей).
    Подстановки внутри — код, они уходят в subs."""
    buf: list[str] = []
    while i < len(s):
        c = s[i]
        if c == '"':
            return "".join(buf), i + 1
        if c == "\\" and i + 1 < len(s):
            nx = s[i + 1]
            if nx in '$`"\\':
                buf.append(nx)
            elif nx != "\n":
                buf.append(c + nx)
            i += 2
            continue
        if c == "$" and s[i + 1:i + 2] == "(":
            j = _paren_end(s, i + 1)
            subs.append(s[i + 2:j - 1])
            buf.append(s[i:j])
            i = j
            continue
        if c == "`":
            j = _backtick_end(s, i + 1)
            subs.append(s[i + 1:j].replace("\\`", "`"))
            buf.append(s[i:j + 1])
            i = j + 1
            continue
        buf.append(c)
        i += 1
    raise ParseError('unterminated "')


def parse(s: str) -> tuple[list[dict], list[str]]:
    """Shell-строка → (простые команды, тексты подстановок).

    Команда — {"words", "heredocs", "stdin"}: слова без кавычек, тела heredoc,
    слова команды, чей вывод пришёл по `|`. Редиректы и их цели в слова не
    попадают. Это не полный shell, а ровно столько, сколько нужно, чтобы не
    принять данные за код и код за данные.
    """
    cmds: list[dict] = []
    subs: list[str] = []
    n = len(s)
    state = {"cur": {"words": [], "heredocs": [], "stdin": None},
             "word": None, "target": None, "pending": []}

    def add(text: str) -> None:
        state["word"] = (state["word"] or "") + text

    def flush() -> None:
        word, target = state["word"], state["target"]
        if word is None:
            return
        if target is None:
            state["cur"]["words"].append(word)
        elif target != "redirect":
            state["pending"].append((word, target == "heredoc-", state["cur"]["heredocs"]))
        state["word"], state["target"] = None, None

    def end(piped: bool = False) -> None:
        flush()
        state["target"] = None
        cur = state["cur"]
        cmds.append(cur)
        state["cur"] = {"words": [], "heredocs": [],
                        "stdin": cur["words"] if piped else None}

    def heredocs(i: int) -> int:
        for delim, strip, sink in state["pending"]:
            lines = []
            while i < n:
                j = s.find("\n", i)
                stop = n if j < 0 else j
                line = s[i:stop]
                i = n if j < 0 else j + 1
                if (line.lstrip("\t") if strip else line) == delim:
                    break
                lines.append(line)
            sink.append("\n".join(lines))
        state["pending"] = []
        return i

    i = 0
    while i < n:
        c, two = s[i], s[i:i + 2]
        if c == "\\":
            if two == "\\\n":
                i += 2
                continue
            add(s[i + 1:i + 2])
            i += 2
        elif c == "'":
            j = s.find("'", i + 1)
            if j < 0:
                raise ParseError("unterminated '")
            add(s[i + 1:j])
            i = j + 1
        elif two == "$'":
            j = i + 2
            while j < n and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            if j >= n:
                raise ParseError("unterminated $'")
            raw = s[i + 2:j]
            try:
                add(codecs.decode(raw, "unicode_escape"))
            except Exception:
                add(raw)
            i = j + 1
        elif c == '"':
            text, i = _dquote(s, i + 1, subs)
            add(text)
        elif two == "$(":
            j = _paren_end(s, i + 1)
            subs.append(s[i + 2:j - 1])
            add(s[i:j])
            i = j
        elif c == "`":
            j = _backtick_end(s, i + 1)
            subs.append(s[i + 1:j].replace("\\`", "`"))
            add(s[i:j + 1])
            i = j + 1
        elif two in ("<(", ">("):
            j = _paren_end(s, i + 1)
            subs.append(s[i + 2:j - 1])
            add(s[i:j])
            i = j
        elif c in "<>":
            if state["word"] is not None and state["word"].isdigit():
                state["word"] = None  # номер дескриптора: `2>&1`
            else:
                flush()
            if s.startswith("<<<", i):
                i, state["target"] = i + 3, "redirect"
            elif s.startswith("<<-", i):
                i, state["target"] = i + 3, "heredoc-"
            elif two == "<<":
                i, state["target"] = i + 2, "heredoc"
            else:
                i += 1
                while i < n and s[i] in "<>&|":
                    i += 1
                state["target"] = "redirect"
        elif two == "&>":
            flush()
            i += 3 if s.startswith("&>>", i) else 2
            state["target"] = "redirect"
        elif c in " \t":
            flush()
            i += 1
        elif c == "#" and state["word"] is None:
            j = s.find("\n", i)
            i = n if j < 0 else j
        elif c == "\n":
            end()
            i = heredocs(i + 1) if state["pending"] else i + 1
        elif c in ";&|()":
            double = two in ("&&", "||", ";;", "|&")
            end(piped=(c == "|"))
            i += 2 if double else 1
        else:
            add(c)
            i += 1
    end()
    return cmds, subs


# ── анализ ───────────────────────────────────────────────────────────────────

def expand(words: list[str], env: dict[str, str]) -> list[str]:
    if not env:
        return list(words)
    out: list[str] = []
    for w in words:
        nw = VAR.sub(lambda m: env.get(m.group(1) or m.group(2), m.group(0)), w)
        out.extend(nw.split() if nw != w else [w])
    return out


def remember(word: str, env: dict[str, str]) -> bool:
    m = ASSIGN.match(word)
    if m:
        env[m.group(1)] = m.group(2)
    return bool(m)


def script_trigger(script: str, env: dict[str, str], depth: int) -> str | None:
    """Признак force-push в shell-строке или None."""
    if depth > MAX_DEPTH or not script.strip():
        return None
    try:
        cmds, subs = parse(script)
    except ParseError:
        return None
    for sub in subs:
        found = script_trigger(sub, env, depth + 1)
        if found:
            return found
    for cmd in cmds:
        words = expand(cmd["words"], env)
        if words[:1] == ["function"]:
            words = words[2:]
        while words and words[0] in RESERVED:
            words = words[1:]
        while words and remember(words[0], env):
            words = words[1:]
        found = argv_trigger(words, cmd["heredocs"], cmd["stdin"], env, depth)
        if found:
            return found
    return None


def strip_wrapper(base: str, rest: list[str], env: dict[str, str]) -> list[str] | None:
    """Аргументы обёртки → обёрнутая команда; None — обёртка ничего не запускает."""
    takes_arg = WRAPPERS[base]
    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--":
            i += 1
            break
        if not a.startswith("-") or a == "-":
            break
        if base == "command" and a in ("-v", "-V"):
            return None
        if base == "env" and (a == "-S" or a.startswith(("-S", "--split-string"))):
            value = a.partition("=")[2] if a.startswith("--") else a[2:]
            if not value and i + 1 < len(rest):
                i, value = i + 1, rest[i + 1]
            try:
                split = shlex.split(value)
            except ValueError:
                split = value.split()
            return split + rest[i + 1:]
        i += 2 if a in takes_arg else 1
    rest = rest[i:]
    if base == "env":
        while rest and remember(rest[0], env):
            rest = rest[1:]
    if base == "timeout" and rest:
        rest = rest[1:]  # длительность — позиционный аргумент самой обёртки
    return rest


def shell_options(shell: str, args: list[str]) -> tuple[bool, int]:
    """Опции шелла → (есть ли `-c`, индекс первого неопционного аргумента).

    `-o`/`-O`/`+o`/`+O` забирают значение, в том числе внутри связки:
    `bash -euo pipefail -c '…'`. В bash/sh/dash/ksh каждая `o`/`O` связки
    берёт по следующему слову; в zsh — остаток связки, если он непуст
    (`-opipefail`), иначе следующее слово. Та же функция — в
    block-local-integration-tests.py: хуки самодостаточны и не импортируют
    друг друга.
    """
    i, has_c = 0, False
    while i < len(args):
        a = args[i]
        if a in ("--", "-"):
            return has_c, i + 1
        if a == "--command":
            has_c, i = True, i + 1
            continue
        if a in SHELL_LONG_ARG_OPTS:
            i += 2
            continue
        if a.startswith("--"):
            i += 1
            continue
        if len(a) < 2 or a[0] not in "-+":
            break
        i += 1
        flags = a[1:]
        for k, ch in enumerate(flags):
            if ch == "c" and a[0] == "-":
                has_c = True
            elif ch in "oO":
                if shell == "zsh" and k < len(flags) - 1:
                    break  # `-opipefail`: остаток связки — имя опции
                i += 1
    return has_c, i


def shell_trigger(shell: str, rest: list[str], heredocs: list[str],
                  stdin: list[str] | None, env: dict[str, str],
                  depth: int) -> str | None:
    has_c, i = shell_options(shell, rest)
    if has_c:
        return script_trigger(rest[i], env, depth + 1) if i < len(rest) else None
    if i < len(rest):
        return None  # `bash script.sh` — скрипт в файле этому гарду не виден
    scripts = list(heredocs)
    if stdin and os.path.basename(stdin[0]) in ("echo", "printf"):
        args = stdin[1:]
        while args and args[0] in ("-e", "-n", "-E", "-ne", "-en"):
            args = args[1:]
        scripts.append(" ".join(args).replace("\\n", "\n").replace("\\t", "\t"))
    for script in scripts:
        found = script_trigger(script, env, depth + 1)
        if found:
            return found
    return None


def ssh_trigger(rest: list[str], env: dict[str, str], depth: int) -> str | None:
    i = 0
    while i < len(rest) and rest[i].startswith("-") and rest[i] != "--":
        flags = rest[i][1:]
        i += 1
        for k, ch in enumerate(flags):
            if ch in SSH_ARG_FLAGS:
                if k == len(flags) - 1:
                    i += 1
                break
    if i < len(rest) and rest[i] == "--":
        i += 1
    remote = rest[i + 1:]
    return script_trigger(" ".join(remote), env, depth + 1) if remote else None


def find_trigger(rest: list[str], env: dict[str, str], depth: int) -> str | None:
    i = 0
    while i < len(rest):
        if rest[i] in ("-exec", "-execdir", "-ok", "-okdir"):
            j = i + 1
            while j < len(rest) and rest[j] not in (";", "+"):
                j += 1
            found = argv_trigger(rest[i + 1:j], [], None, env, depth + 1)
            if found:
                return found
            i = j
        i += 1
    return None


def argv_trigger(argv: list[str], heredocs: list[str], stdin: list[str] | None,
                 env: dict[str, str], depth: int) -> str | None:
    """Признак force-push в одной простой команде (argv) или None."""
    if depth > MAX_DEPTH:
        return None
    while argv:
        base = os.path.basename(argv[0])
        rest = argv[1:]
        if base in ("export", "local", "declare", "typeset", "readonly"):
            for word in rest:
                remember(word, env)
            return None
        if base in WRAPPERS:
            unwrapped = strip_wrapper(base, rest, env)
            if unwrapped is None:
                return None
            argv = unwrapped
            continue
        if base in SHELLS:
            return shell_trigger(base, rest, heredocs, stdin, env, depth)
        if base == "eval":
            return script_trigger(" ".join(rest), env, depth + 1)
        if base == "ssh":
            return ssh_trigger(rest, env, depth)
        if base == "find":
            return find_trigger(rest, env, depth)
        if base in GIT_BINARIES:
            return git_trigger(rest, env, depth)
        if base in PUSH_BINARIES:
            return push_trigger(rest, False)
        return None
    return None


def git_trigger(args: list[str], env: dict[str, str], depth: int,
                aliases: dict[str, str] | None = None) -> str | None:
    aliases = dict(aliases or {})
    config_force = None
    i = 0
    while i < len(args):
        a = args[i]
        if a in GIT_ARG_OPTS:
            if a == "-c" and i + 1 < len(args):
                key, eq, value = args[i + 1].partition("=")
                key = key.lower()
                if key.startswith("alias."):
                    aliases[key[len("alias."):]] = value
                elif re.fullmatch(r"remote\..+\.push", key) and value.strip().startswith("+"):
                    config_force = "конфиг -c remote.*.push с '+'"
                elif re.fullmatch(r"remote\..+\.mirror", key) and (
                        not eq or value.strip().lower() in ("true", "yes", "on", "1")):
                    config_force = "конфиг -c remote.*.mirror"
            i += 2
            continue
        if a.startswith("-"):
            i += 1
            continue
        break
    if i >= len(args):
        return None
    sub, rest = args[i], args[i + 1:]
    alias = aliases.pop(sub.lower(), None)
    if alias is not None:
        if alias.startswith("!"):
            return script_trigger(" ".join([alias[1:]] + rest), env, depth + 1)
        try:
            expanded = shlex.split(alias)
        except ValueError:
            return None
        return git_trigger(expanded + rest, env, depth + 1, aliases)
    if sub in PUSH_SUBCOMMANDS:
        return push_trigger(rest, bool(config_force), config_force)
    if sub == "submodule" and "foreach" in rest:
        cmd = rest[rest.index("foreach") + 1:]
        while cmd and cmd[0] in ("--recursive", "-q", "--quiet"):
            cmd = cmd[1:]
        return script_trigger(" ".join(cmd), env, depth + 1) if cmd else None
    return None


def push_trigger(args: list[str], forced: bool, what: str | None = None) -> str | None:
    """Аргументы после `push` → признак force-push или None (в т.ч. dry-run)."""
    dry = False
    found = what if forced else None
    i, options_done = 0, False
    while i < len(args):
        a = args[i]
        i += 1
        if options_done or not a.startswith("-") or a == "-":
            if a.startswith("+") and not found:
                found = f"refspec {a[:60]!r} с '+'"
            continue
        if a == "--":
            options_done = True
            continue
        if a.startswith("--"):
            name, eq, _ = a[2:].partition("=")
            # git принимает однозначный префикс длинного флага (`--forc`), а
            # неоднозначный отвергает сам — блокировать его безвредно.
            if name and any(f.startswith(name) for f in FORCE_LONG):
                found = found or f"флаг --{name}"
            elif len(name) >= 2 and "dry-run".startswith(name):
                dry = True
            elif len(name) >= 5 and "no-dry-run".startswith(name):
                dry = False
            elif not eq and len(name) >= 3 and any(o.startswith(name) for o in PUSH_ARG_LONG):
                i += 1  # значение флага — не refspec
            continue
        cluster = a[1:]
        for k, ch in enumerate(cluster):
            if ch == "f":
                found = found or (f"флаг -f в {a[:20]}" if len(a) > 2 else "флаг -f")
            elif ch == "n":
                dry = True
            elif ch == "o":  # -o <push-option>: остаток связки или следующее слово
                if k == len(cluster) - 1:
                    i += 1
                break
    return None if dry else found


# ── вход и выход ─────────────────────────────────────────────────────────────

def main() -> int:
    payload = json.loads(sys.stdin.read())
    if not isinstance(payload, dict):
        return 0
    tool = next((payload[k] for k in ("tool_name", "toolName") if payload.get(k) is not None), "")
    if not isinstance(tool, str) or tool not in SHELL_TOOLS:
        return 0
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        tool_input = payload.get("toolInput")
    if not isinstance(tool_input, dict):
        return 0
    command = tool_input.get("command")
    if command is None:
        command = tool_input.get("cmd")
    if isinstance(command, str):
        found = script_trigger(command, {}, 0)
    elif isinstance(command, list):
        found = argv_trigger([str(x) for x in command], [], None, {}, 0)
    else:
        return 0
    if found:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": REASON.format(what=found),
        }}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    try:
        main()
    except BaseException:  # fail-open: любой сбой — молча пропустить
        pass
    sys.exit(0)
