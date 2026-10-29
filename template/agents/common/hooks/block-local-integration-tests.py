#!/usr/bin/env python3
"""PreToolUse hook (Claude Code и Codex, root и субагенты): integration/e2e — только в CI.

ЗАЧЕМ. Integration и e2e на машине агента ходят в общие стенды и базы, долго
занимают порты и контейнеры и дают ответ, который всё равно перепроверит CI.
Агент запускает их «на всякий случай» — поэтому правило стоит на входе.

ЧТО СМОТРИТ. Только исполняемую команду, а не текст: `rg e2e`, `echo "npm run
e2e"`, сообщение коммита и тело heredoc у не-шелла не считаются запуском.
Команда режется на сегменты по `&&`, `||`, `;`, `|`, `&`, переводам строки,
`( )`, `$(…)` и обратным кавычкам; каждый сегмент разбирается shlex.
Разворачиваются `VAR=…`, `env`, `sudo`, `timeout`, `nice`, `nohup`, `time`,
`command`, `exec`, `xargs`, `eval`, `bash|sh|zsh -c '…'` (и heredoc шелла),
`docker|podman exec`, `docker compose exec|run`, `kubectl|oc exec … -- …`,
`npx`, `npm exec`, `pnpm exec|dlx`, `yarn exec|dlx`, `uv|poetry|pipenv|pdm run`,
`python -m pytest`.

ЧТО БЛОКИРУЕТ.
  * npm/yarn/pnpm скрипты, чьё имя содержит часть `integration` или `e2e`
    (`test:integration`, `test:e2e:ci`, `e2e`), кроме сборки/lint/typecheck
    (`e2e:build`, `build:e2e`, `lint:e2e`, `typecheck:e2e`); аргументы после
    имени скрипта проверяются как пути/конфиги jest;
  * pytest: `-m`, способный выбрать тест с маркером integration/e2e
    (`-m integration`, `-m "integration and not slow"`, но не `-m "not
    integration"`), путь или `-c`-конфиг с маркером; `--collect-only`/`--co` —
    пропуск;
  * jest/vitest: путь, `--config`/`-c`, `--project`/`--selectProjects`,
    `--testPathPattern`; `--listTests`, `vitest list` — пропуск;
  * `go test -tags integration[,…]`, `-run` с Integration/E2E в регэкспе, пакет
    `./integration/...`; `-c`, `-list` — пропуск; `gotestsum -- …`;
  * `playwright test` (кроме `--list`), `cypress run|open`;
  * nx: `run <proj>:e2e[:cfg]`, `e2e <proj>`, `<proj>:e2e`, `run-many|affected
    -t e2e`, `affected:e2e`.

МАРКЕР В ПУТИ — это компонент каталога (`tests/integration/`, `apps/api-e2e/`,
`integration_tests/`), имя файла (`*.e2e.ts`, `*.e2e-spec.ts`,
`*.integration.test.ts`, `*_integration_test.go`, `test_integration.py`) или
конфиг (`jest-e2e.json`, `vitest.integration.config.ts`), но не подстрока:
`integration_utils.test.ts`, `src/integrations/` — пропуск. Компонент считается
маркером, если после отбрасывания хвостовых `test|tests|spec|specs` его
последняя часть (по `.`, `_`, `-`) равна `integration` или `e2e`.

НЕ ПОКРЫВАЕТ: Gradle, Maven, Cargo, RSpec, dotnet, make/just/turbo/tox/nox,
bun, `docker run`, `ssh` (удалённый хост — не локальный запуск), скрипты-обёртки
(`bash scripts/e2e.sh`) и npm-скрипты, которые внутри зовут integration под
нейтральным именем (`npm test`).

ВЫКЛЮЧАТЕЛЬ: `WORKSPACE_ALLOW_LOCAL_INTEGRATION=1` в окружении ПРОЦЕССА хука.
Префикс `WORKSPACE_ALLOW_LOCAL_INTEGRATION=1 npm run e2e` в самой команде
ничего не выключает — ставит его человек, не агент.

FAIL-OPEN: непонятный или непарсящийся ввод, любой сбой — exit 0 без вывода.
Тест: agents/common/tests/block-local-integration-tests.test.py
"""

from __future__ import annotations

import itertools
import json
import os
import re
import shlex
import sys

SWITCH = "WORKSPACE_ALLOW_LOCAL_INTEGRATION"
REASON = (
    "Локальный запуск integration/e2e запрещён: `{cmd}` ({why}). Integration и "
    "e2e гоняются только в CI. Локально — только если человек сам поставил "
    f"{SWITCH}=1 в окружении агента и прямо попросил о прогоне; агент этот "
    "выключатель не ставит и префиксом команды его не обойти. Запустите unit-"
    "проверки, а в отчёте напишите «integration не запускались локально»."
)

SHELL_TOOLS = {"Bash", "shell", "local_shell", "exec_command", "unified_exec"}
MARK = {"integration", "e2e"}
TRAIL = {"test", "tests", "spec", "specs"}
NON_RUN = set("build lint typecheck type tsc types format fmt prettier eslint compile "
              "codegen gen generate install clean report docs".split())
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
KEYWORDS = {"!", "{", "}", "time", "then", "do", "else", "elif", "if", "while", "until"}
MAX_DEPTH = 6

HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][\w-]*)\1")
ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
REDIR = re.compile(r"^(?:\d+|&)?(?:>>?|<<?<?|>\|)&?(.*)$", re.S)
PYTHON = re.compile(r"^python[\d.]*$")


# ---------------------------------------------------------------- разбор строки

def split_commands(cmd: str) -> tuple[list[str], dict[int, list[str]]]:
    """Сегменты команды и тела heredoc по индексу сегмента, к которому они относятся.

    `$(…)` и обратные кавычки — отдельные сегменты и внутри двойных кавычек;
    `#` в начале слова — комментарий до конца строки.
    """
    out: list[str] = []
    cur: list[str] = []
    bodies: dict[int, list[str]] = {}
    docs: list[tuple[str, int]] = []
    stack: list[tuple[str, str | None]] = []
    quote: str | None = None
    i, n = 0, len(cmd)

    def flush() -> None:
        out.append("".join(cur))
        cur.clear()

    while i < n:
        c, two = cmd[i], cmd[i:i + 2]
        if quote == "'":
            cur.append(c)
            quote = None if c == "'" else quote
            i += 1
            continue
        if c == "\\":
            cur.append(cmd[i:i + 2])
            i += 2
            continue
        if two == "$(":
            flush()
            stack.append(("(", quote))
            quote, i = None, i + 2
            continue
        if c == "`":
            flush()
            if stack and stack[-1][0] == "`" and quote is None:
                quote = stack.pop()[1]
            else:
                stack.append(("`", quote))
                quote = None
            i += 1
            continue
        if quote == '"':
            cur.append(c)
            quote = None if c == '"' else quote
            i += 1
            continue
        # quote is None
        if c == "#" and (not cur or cur[-1] in " \t"):
            while i < n and cmd[i] != "\n":
                i += 1
            continue
        m = HEREDOC.match(cmd, i) if two == "<<" and cmd[i:i + 3] != "<<<" else None
        if m:
            docs.append((m.group(2), len(out)))
            cur.append(m.group(0))
            i = m.end()
            continue
        if c == "\n":
            flush()
            i += 1
            for delim, seg in docs:
                lines = []
                while i < n:
                    end = cmd.find("\n", i)
                    end = n if end < 0 else end
                    line = cmd[i:end]
                    i = end + 1
                    if line.strip() == delim:
                        break
                    lines.append(line)
                bodies.setdefault(seg, []).append("\n".join(lines))
            docs = []
            continue
        if two in ("&&", "||"):
            flush()
            i += 2
            continue
        if c == ")" and stack and stack[-1][0] == "(":
            flush()
            quote = stack.pop()[1]
            i += 1
            continue
        if c in ";|()" or (c == "&" and cmd[i - 1:i] not in ("<", ">")
                            and cmd[i + 1:i + 2] != ">"):
            flush()
            i += 1
            continue
        if c in "'\"":
            quote = c
        cur.append(c)
        i += 1
    flush()
    return out, bodies


def words(segment: str) -> list[str]:
    try:
        toks = shlex.split(segment)
    except ValueError:
        toks = segment.split()
    out, skip = [], False
    for tok in toks:
        if skip:
            skip = False
            continue
        m = REDIR.match(tok)
        if m:  # редирект `> f`, `2>&1`, `<<EOF` — не аргумент команды
            skip = m.group(1) == ""
            continue
        out.append(tok)
    return out


def skip_options(args: list[str], with_value: set[str]) -> list[str]:
    """Отбрасывает ведущие опции (и значения перечисленных) до первого позиционного."""
    i = 0
    while i < len(args) and args[i].startswith("-") and args[i] != "-":
        if args[i] == "--":
            return args[i + 1:]
        i += 2 if args[i] in with_value else 1
    return args[i:]


def options(args: list[str], with_value: set[str]):
    """→ (flag, value|None) и ('', positional) по порядку; `--x=v` и `-xV` тоже."""
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            for rest in args[i + 1:]:
                yield "", rest
            return
        if a.startswith("-") and a != "-":
            if "=" in a and a.startswith("--"):
                k, v = a.split("=", 1)
                yield k, v
            elif a in with_value:
                yield a, args[i + 1] if i + 1 < len(args) else ""
                i += 1
            elif not a.startswith("--") and a[:2] in with_value and len(a) > 2:
                yield a[:2], a[2:]
            else:
                yield a, None
        else:
            yield "", a
        i += 1


# ---------------------------------------------------------------- предикаты

def parts(name: str) -> list[str]:
    return [p for p in re.split(r"[._\-]+", name.lower()) if p]


def marked(name: str) -> bool:
    """`integration`, `api-e2e`, `integration_tests`, `foo_integration_test`."""
    ps = parts(name)
    while ps and ps[-1] in TRAIL:
        ps.pop()
    return bool(ps) and ps[-1] in MARK


def run_name(name: str) -> bool:
    """Имя скрипта/таргета запускает integration/e2e, а не собирает их."""
    ps = [p for p in re.split(r"[:._\-/\s]+", name.lower()) if p]
    return bool(set(ps) & MARK) and not set(ps) & NON_RUN


def components(path: str) -> list[str]:
    path = path.split("::", 1)[0]
    return [c for c in path.split("/") if c not in ("", ".", "..")]


def is_file(comp: str) -> bool:
    return "." in comp.strip(".") and not comp.startswith(".")


def path_marked(path: str) -> bool:
    comps = components(path)
    if not comps:
        return False
    last = comps[-1]
    dirs = comps[:-1] if is_file(last) else comps
    if any(marked(c) for c in dirs):
        return True
    return is_file(last) and any(marked(seg) for seg in last.split(".")[:-1])


def config_marked(path: str) -> bool:
    comps = components(path)
    if not comps:
        return False
    stem = comps[-1].rsplit(".", 1)[0] if is_file(comps[-1]) else comps[-1]
    return any(marked(c) for c in comps[:-1]) or bool(set(parts(stem)) & MARK)


def marker_expr_selects(expr: str) -> bool:
    """Может ли pytest `-m EXPR` выбрать тест с маркером integration/e2e."""
    toks = re.findall(r"\(|\)|[A-Za-z_][\w.\-]*|\S", expr)
    idents = [t for t in toks if re.match(r"[A-Za-z_]", t) and t not in ("and", "or", "not")]
    hits = sorted({t for t in idents if set(parts(t)) & MARK})
    if not hits:
        return False
    names = sorted(set(idents))
    if len(names) > 12 or any(t not in ("(", ")") and not re.match(r"[A-Za-z_]", t)
                              for t in toks):
        return True  # непонятное выражение с маркером — считаем выбором
    alias = {name: f"v{k}" for k, name in enumerate(names)}
    code = " ".join(alias.get(t, t) for t in toks)
    try:
        compiled = compile(code, "<marker>", "eval")
    except SyntaxError:
        return True
    for hit in hits:
        others = [x for x in names if x != hit]
        for values in itertools.product((False, True), repeat=len(others)):
            env = {alias[x]: v for x, v in zip(others, values)}
            env[alias[hit]] = True
            try:
                if eval(compiled, {"__builtins__": {}}, env):  # noqa: S307 — имена и and/or/not
                    return True
            except Exception:  # `marker(arg)` и прочее непонятное с маркером — выбор
                return True
    return False


# ---------------------------------------------------------------- инструменты

PYTEST_VALUE = set("-m -k -c -p -o -n -W -r --rootdir --confcutdir --junitxml --junit-xml "
                   "--basetemp --maxfail --tb --log-level --ignore --ignore-glob --deselect "
                   "--dist --import-mode --config-file --durations --cov-report --cov-config "
                   "--log-file --override-ini --capture --color --timeout --reruns --html "
                   "--alluredir".split())


def pytest(args: list[str]) -> str | None:
    if set(args) & {"--collect-only", "--co", "--fixtures", "--markers", "--version",
                    "-h", "--help"}:
        return None
    for flag, value in options(args, PYTEST_VALUE):
        if flag == "-m" and value and marker_expr_selects(value):
            return f"pytest -m {value}"
        if flag in ("-c", "--config-file") and value and config_marked(value):
            return f"pytest-конфиг {value}"
        if flag == "" and path_marked(value):
            return f"pytest {value}"
    return None


JEST_VALUE = set("-c --config --project --selectProjects --testPathPattern --testPathPatterns "
                 "--dir --rootDir --workspace -t --testNamePattern --reporter --reporters "
                 "--environment --env --pool --root -r --shard --outputFile --maxWorkers -w "
                 "--mode --testTimeout".split())


def jest_like(args: list[str], tool: str) -> str | None:
    if set(args) & {"--listTests", "--showConfig", "--help", "-h", "--version"}:
        return None
    if tool == "vitest":
        pos = skip_options(args, JEST_VALUE)
        if pos and pos[0] in ("list", "init"):
            return None
        if pos and pos[0] in ("run", "watch", "dev", "related", "bench"):
            idx = args.index(pos[0])
            args = args[:idx] + args[idx + 1:]
    for flag, value in options(args, JEST_VALUE):
        if not value:
            continue
        if flag in ("-c", "--config", "--workspace") and config_marked(value):
            return f"{tool} --config {value}"
        if flag in ("--project", "--selectProjects") and run_name(value):
            return f"{tool} --project {value}"
        if flag in ("--testPathPattern", "--testPathPatterns", "--dir", "--rootDir", "") \
                and path_marked(value):
            return f"{tool} {value}"
    return None


GO_VALUE = set("run skip tags count timeout p parallel bench benchtime cpu coverprofile "
               "coverpkg covermode o list exec ldflags gcflags asmflags mod modfile shuffle "
               "blockprofile cpuprofile memprofile mutexprofile outputdir trace fuzz fuzztime "
               "C vet".split())


def go_test(args: list[str]) -> str | None:
    norm = []
    for a in args:
        if a == "-args":
            break
        a = "-" + a[2:] if a.startswith("--") and len(a) > 2 else a
        if a.startswith("-") and "=" in a:  # у go `-tags=x` с одним дефисом
            norm.extend(a.split("=", 1))
        else:
            norm.append(a)
    found = None
    for flag, value in options(norm, {"-" + f for f in GO_VALUE}):
        name = flag.lstrip("-")
        if name in ("c", "list") and value != "false":
            return None
        if found:
            continue
        if name == "tags" and value and any(marked(t) for t in re.split(r"[,\s]+", value)):
            found = f"go test -tags {value}"
        elif name == "run" and value and re.search(r"(?i)integration|e2e", value):
            found = f"go test -run {value}"
        elif flag == "" and path_marked(value):
            found = f"go test {value}"
    return found


NX_VALUE = set("-t --target --targets -p --projects -c --configuration --exclude --base "
               "--head --output-style --files".split())


def nx(args: list[str]) -> str | None:
    pos = [v for f, v in options(args, NX_VALUE) if f == ""]
    targets = [t for f, v in options(args, NX_VALUE)
               if f in ("-t", "--target", "--targets") and v for t in v.split(",")]
    if not pos:
        return None
    head = pos[0]
    if head == "run" and len(pos) > 1:
        bits = pos[1].split(":")
        targets.append(bits[1] if len(bits) > 1 else "")
    elif head in ("run-many", "affected"):
        pass
    elif head.startswith("affected:"):
        targets.append(head.split(":", 1)[1])
    elif ":" in head:
        targets.append(head.split(":")[1])
    else:
        targets.append(head)
    hit = next((t for t in targets if run_name(t)), None)
    return f"nx таргет {hit}" if hit else None


# ------------------------------------------------- пакетные менеджеры и обёртки

NPM_VALUE = set("--prefix -w --workspace --cache --userconfig --loglevel -C".split())
PNPM_VALUE = set("--filter -F -C --dir --workspace-concurrency --reporter --loglevel".split())
YARN_VALUE = set("--cwd".split())
NPX_VALUE = set("-p --package --call -w --workspace".split())


PM_BUILTINS = set("install i add remove rm uninstall update up upgrade ci link unlink publish "
                  "pack outdated list ls why audit init create config store prune import "
                  "rebuild dedupe fetch patch info view version cache set plugin bin root "
                  "help login logout whoami".split())


def script_run(name: str, extra: list[str], who: str) -> str | None:
    """Имя скрипта; аргументы после него — пути/конфиги, только если это test-скрипт."""
    if run_name(name):
        return f"{who} {name}"
    if "test" in re.split(r"[:._\-/]+", name.lower()):
        return jest_like(extra, f"{who} {name}")
    return None


def exec_like(args: list[str], value: set[str], depth: int) -> str | None:
    """npx / npm exec / pnpm exec: `-c 'cmd'` или argv после опций."""
    for flag, val in options(args, value | {"-c"}):
        if flag in ("-c", "--call") and val:
            return analyze_command(val, depth + 1)
    return analyze_argv(skip_options(args, value), depth + 1)


def package_manager(base: str, args: list[str], depth: int) -> str | None:
    if base == "npm":
        pos = skip_options(args, NPM_VALUE)
        if not pos:
            return None
        sub = pos[0]
        if sub in ("run", "run-script", "rum", "urn") and len(pos) > 1:
            rest = skip_options(pos[1:], NPM_VALUE)
            return script_run(rest[0], rest[1:], "npm run") if rest else None
        if sub in ("exec", "x"):
            return exec_like(pos[1:], NPX_VALUE, depth)
        if sub in ("test", "t", "tst"):
            return jest_like(pos[1:], "npm test")
        return None
    if base in ("npx", "pnpx"):
        return exec_like(args, NPX_VALUE, depth)
    if base == "pnpm":
        pos = skip_options(args, PNPM_VALUE)
        if not pos:
            return None
        if pos[0] in ("exec", "dlx"):
            return exec_like(pos[1:], PNPM_VALUE, depth)
        if pos[0] == "run":
            rest = skip_options(pos[1:], PNPM_VALUE)
            return script_run(rest[0], rest[1:], "pnpm run") if rest else None
        if pos[0] in PM_BUILTINS:
            return None
        return script_run(pos[0], pos[1:], "pnpm") or analyze_argv(pos, depth + 1)
    if base == "yarn":
        pos = skip_options(args, YARN_VALUE)
        if not pos:
            return None
        if pos[0] in ("exec", "dlx"):
            return exec_like(pos[1:], {"-p", "--package"}, depth)
        if pos[0] == "workspace" and len(pos) > 2:
            pos = pos[2:]
        elif pos[0] == "workspaces":
            if "run" not in pos:
                return None
            pos = skip_options(pos[pos.index("run") + 1:], set())
        if pos and pos[0] == "run":
            pos = pos[1:]
        if not pos or pos[0] in PM_BUILTINS:
            return None
        return script_run(pos[0], pos[1:], "yarn") or analyze_argv(pos, depth + 1)
    return None


def compose(args: list[str], depth: int) -> str | None:
    rest = skip_options(args, set("-f --file -p --project-name --profile --env-file "
                                  "--project-directory --ansi --progress --parallel".split()))
    if not rest:
        return None
    if rest[0] == "exec":
        rest = skip_options(rest[1:], set("-e --env -u --user -w --workdir --index".split()))
    elif rest[0] == "run":
        rest = skip_options(rest[1:], set("-e --env -u --user -w --workdir -v --volume -p "
                                          "--publish --name --entrypoint -l --label --cap-add "
                                          "--cap-drop --pull --env-from-file".split()))
    else:
        return None
    return analyze_argv(rest[1:], depth + 1) if len(rest) > 1 else None


def container(base: str, args: list[str], depth: int) -> str | None:
    if base in ("kubectl", "oc"):
        if "exec" in args and "--" in args[args.index("exec"):]:
            return analyze_argv(args[args.index("--", args.index("exec")) + 1:], depth + 1)
        return None
    if base in ("docker-compose", "podman-compose"):
        return compose(args, depth)
    rest = skip_options(args, set("--context -c -H --host --config -l --log-level".split()))
    if rest[:1] == ["container"]:
        rest = rest[1:]
    if rest[:1] == ["compose"]:
        return compose(rest[1:], depth)
    if rest[:1] == ["exec"]:
        rest = skip_options(rest[1:], set("-e --env --env-file -u --user -w --workdir "
                                          "--detach-keys".split()))
        return analyze_argv(rest[1:], depth + 1) if len(rest) > 1 else None
    return None


WRAPPER_VALUE = {
    "env": set("-u --unset -C --chdir".split()),
    "sudo": set("-u -g -C -D -h -p -r -t -T -U --user --group --chdir --host "
                "--prompt --role --type".split()),
    "doas": {"-u", "-C"},
    "timeout": set("-s --signal -k --kill-after".split()),
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "-n", "-p", "--class", "--classdata"},
    "nohup": set(),
    "time": set(),
    "stdbuf": {"-i", "-o", "-e"},
    "exec": {"-a"},
    "command": set(),
    "xargs": set("-I -n -P -L -d -E -s -a --max-args --max-procs --delimiter "
                 "--arg-file".split()),
}
RUNNERS_VALUE = set("--with -p --python --project --directory --package --extra --group "
                    "--env-file --with-requirements --index --from".split())


SHELL_LONG_ARG_OPTS = {"--rcfile", "--init-file"}


def shell_options(shell: str, args: list[str]) -> tuple[bool, int]:
    """Опции шелла → (есть ли `-c`, индекс первого неопционного аргумента).

    `-o`/`-O`/`+o`/`+O` забирают значение, в том числе внутри связки:
    `bash -euo pipefail -c '…'`. В bash/sh/dash/ksh каждая `o`/`O` связки
    берёт по следующему слову; в zsh — остаток связки, если он непуст
    (`-opipefail`), иначе следующее слово. Та же функция — в
    block-force-push.py: хуки самодостаточны и не импортируют друг друга.
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


def unwrap(argv: list[str]) -> list[str] | None:
    """Снимает присваивания, ключевые слова и обёртки; None — команда не исполняет argv."""
    while argv:
        while argv and (ASSIGN.match(argv[0]) or argv[0] in KEYWORDS):
            argv = argv[1:]
        if not argv:
            return argv
        base = os.path.basename(argv[0])
        if base not in WRAPPER_VALUE:
            return argv
        args = argv[1:]
        if base == "command" and set(args) & {"-v", "-V"}:
            return None
        if base == "env":
            for k, a in enumerate(args):
                if a in ("-S", "--split-string") or a.startswith("--split-string="):
                    script = a.split("=", 1)[1] if "=" in a else (args[k + 1] if k + 1 < len(args) else "")
                    tail = args[k + 1:] if "=" in a else args[k + 2:]
                    return unwrap(words(script) + tail)
                if not a.startswith("-"):
                    break
        args = skip_options(args, WRAPPER_VALUE[base])
        if base == "timeout" and args:
            args = args[1:]
        argv = args
    return argv


def analyze_argv(argv: list[str], depth: int, stdin: list[str] | None = None) -> str | None:
    if depth > MAX_DEPTH:
        return None
    argv = unwrap(list(argv))
    if not argv:
        return None
    base, args = os.path.basename(argv[0]), argv[1:]

    if base in SHELLS:
        has_c, i = shell_options(base, args)
        if has_c:
            return analyze_command(args[i], depth + 1) if i < len(args) else None
        for body in stdin or []:
            hit = analyze_command(body, depth + 1)
            if hit:
                return hit
        return None
    if base == "eval":
        return analyze_command(" ".join(args), depth + 1)
    if base in ("docker", "podman", "docker-compose", "podman-compose", "kubectl", "oc"):
        return container(base, args, depth)
    if base in ("npm", "npx", "pnpm", "pnpx", "yarn"):
        return package_manager(base, args, depth)
    if base in ("uv", "poetry", "pipenv", "pdm", "rye"):
        if args[:1] == ["run"]:
            return analyze_argv(skip_options(args[1:], RUNNERS_VALUE), depth + 1)
        return None
    if base == "uvx":
        return analyze_argv(skip_options(args, RUNNERS_VALUE), depth + 1)
    if PYTHON.match(base):
        if len(args) > 1 and args[0] == "-m" and args[1] in ("pytest", "py.test"):
            return pytest(args[2:])
        return None
    if base in ("pytest", "py.test"):
        return pytest(args)
    if base in ("jest", "vitest"):
        return jest_like(args, base)
    if base == "go":
        return go_test(args[1:]) if args[:1] == ["test"] else None
    if base == "gotestsum":
        return go_test(args[args.index("--") + 1:]) if "--" in args else None
    if base == "playwright":
        pos = skip_options(args, set())
        if pos[:1] == ["test"] and "--list" not in args:
            return "playwright test"
        return None
    if base == "cypress":
        pos = skip_options(args, set())
        return f"cypress {pos[0]}" if pos[:1] in (["run"], ["open"]) else None
    if base == "nx":
        return nx(args)
    return None


def analyze_command(cmd: str, depth: int = 0) -> str | None:
    if depth > MAX_DEPTH:
        return None
    segments, bodies = split_commands(cmd)
    for idx, segment in enumerate(segments):
        hit = analyze_argv(words(segment), depth, bodies.get(idx))
        if hit:
            return hit
    return None


# ---------------------------------------------------------------- вход хука

def main() -> None:
    if os.environ.get(SWITCH, "").strip() == "1":
        return
    payload = json.loads(sys.stdin.read())
    if not isinstance(payload, dict):
        return
    tool = payload.get("tool_name", payload.get("toolName"))
    tool_input = payload.get("tool_input", payload.get("toolInput"))
    if not isinstance(tool, str) or tool not in SHELL_TOOLS or not isinstance(tool_input, dict):
        return
    command = tool_input.get("command", tool_input.get("cmd"))
    if isinstance(command, list) and all(isinstance(x, str) for x in command):
        command = shlex.join(command)
    if not isinstance(command, str) or not command.strip():
        return
    hit = analyze_command(command)
    if not hit:
        return
    shown = " ".join(command.split())[:120]
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": REASON.format(cmd=shown, why=hit),
    }}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except BaseException:  # fail-open: любой сбой — молча пропустить
        pass
    sys.exit(0)
