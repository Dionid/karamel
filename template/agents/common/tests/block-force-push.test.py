#!/usr/bin/env python3
"""Self-test гарда force-push — запускается lint.sh как behaviour test.

Агент не делает force-push никогда, даже по просьбе пользователя; его делает
человек. Хук `block-force-push.py` держит это правило на PreToolUse/Bash, и
у него три способа сломаться, каждый молча:

  * **Пропустить написание.** `permissions.deny` матчит строку, а force-push
    пишется десятком способов: связка коротких флагов (`-fu`), `+refspec`,
    `git -C dir`, `git -c …`, обёртки (`timeout 30`, `env X=1`, `bash -c`),
    составные команды и подстановки. Каждое — строка таблицы ниже.
  * **Запретить обычную работу.** Обычный push, `--delete`, `fetch --force`,
    коммит-сообщение со строкой `git push -f`, `rg 'push --force'`, тело
    heredoc. Гард, который мешает работать, снимают целиком — после чего не
    защищено ничего. Поэтому разрешённые формы проверяются так же явно.
  * **Упасть на непонятном вводе.** Незакрытая кавычка, чужая форма payload,
    не-строка вместо команды — пропуск (exit 0 без вывода), не отказ.

Каждый случай идёт в трёх формах payload, и вердикт обязан совпасть: Claude
Code шлёт snake_case и команду строкой, Codex — camelCase, а его shell-tool
несёт argv массивом (`["bash", "-lc", cmd]`).

Спорные формы и решения по ним (обоснование — в docstring хука):
  * `--mirror` — запрещён: принудительно перезаписывает и удаляет refs;
  * `--dry-run`/`-n` с force-флагом — разрешён: ничего не отправляет;
  * `--delete`/`:branch` — разрешены: удаление ветки не перезапись истории.

    python3 agents/common/tests/block-force-push.test.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

# (что это, команда, должен ли быть отказ)
CASES = [
    # ── прямые формы force-push ──────────────────────────────────────────────
    ("--force", "git push --force", True),
    ("--force с remote и веткой", "git push --force origin main", True),
    ("-f", "git push -f", True),
    ("-f после позиционных", "git push origin main -f", True),
    ("-f в связке -fu", "git push -fu origin feature", True),
    ("-f в связке -uf", "git push -uf origin feature", True),
    ("-f в связке -vf", "git push -vf", True),
    ("--force-with-lease", "git push --force-with-lease", True),
    ("--force-with-lease=ref", "git push --force-with-lease=main origin main", True),
    ("--force-with-lease=ref:sha", "git push --force-with-lease=main:abc123 origin main", True),
    ("--force-if-includes", "git push --force-with-lease --force-if-includes origin x", True),
    ("сокращённый длинный флаг --forc", "git push --forc origin x", True),
    ("сокращённый --force-w", "git push --force-w origin x", True),
    ("--mirror перезаписывает и удаляет refs", "git push --mirror origin", True),
    ("+refspec", "git push origin +main", True),
    ("+refspec в кавычках", "git push origin '+main'", True),
    ("+HEAD:refs/heads/x", "git push origin +HEAD:refs/heads/x", True),
    ("+refspec среди обычных", "git push origin a +b:c", True),
    ("абсолютный путь к git", "/usr/bin/git push -f", True),
    ("git в кавычках", '"git" push -f', True),
    ("экранированный git", "\\git push -f", True),
    ("git-push по прямому пути", "/usr/libexec/git-core/git-push --force origin x", True),
    ("send-pack --force", "git send-pack --force origin main", True),
    ("hub — обёртка git", "hub push -f", True),
    ("URL с credentials в remote", "git push -f https://u:not-a-real-pass@example.com/r.git main", True),
    # ── глобальные опции git перед push ──────────────────────────────────────
    ("-C dir", "git -C /tmp/repo push --force", True),
    ("-c key=value", "git -c user.name=x push -f", True),
    ("несколько -c и -C", "git -c a.b=1 -C /tmp/r -c c.d=2 push -f origin x", True),
    ("--git-dir=", "git --git-dir=/tmp/r/.git push -f", True),
    ("--no-pager", "git --no-pager push --force", True),
    ("-c remote.*.push с '+'", "git -c remote.origin.push=+refs/heads/*:refs/heads/* push", True),
    ("-c remote.*.mirror", "git -c remote.origin.mirror=true push origin", True),
    ("-c alias на force-push", "git -c alias.yolo='push --force' yolo origin x", True),
    ("-c shell-alias на force-push", "git -c 'alias.y=!git push -f' y", True),
    ("submodule foreach", "git submodule foreach 'git push -f'", True),
    ("submodule foreach --recursive", "git submodule foreach --recursive git push --force", True),
    # ── обёртки ──────────────────────────────────────────────────────────────
    ("env X=1", "env X=1 git push -f", True),
    ("env -i с опцией", "env -i PATH=/usr/bin git push -f", True),
    ("env -S строкой", "env -S 'git push -f'", True),
    ("префикс-присваивание", "GIT_TRACE=1 git push -f", True),
    ("sudo", "sudo git push -f", True),
    ("sudo -u user --", "sudo -u bob -- git push --force", True),
    ("command", "command git push -f", True),
    ("builtin-цепочка command+nice", "command nice -n 5 git push -f", True),
    ("nice -n 10", "nice -n 10 git push -f", True),
    ("nohup", "nohup git push -f > /dev/null 2>&1 &", True),
    ("time", "time git push -f", True),
    ("timeout 30", "timeout 30 git push -f", True),
    ("timeout -s KILL 30s", "timeout -s KILL 30s git push -f", True),
    ("stdbuf -oL", "stdbuf -oL git push -f", True),
    ("xargs", "echo origin | xargs git push -f", True),
    ("xargs -I", "echo x | xargs -I {} git push -f origin {}", True),
    ("bash -c", 'bash -c "git push -f"', True),
    ("sh -c", "sh -c 'git push -f'", True),
    ("bash -lc", "bash -lc 'cd /tmp && git push --force'", True),
    ("zsh -c", "zsh -c 'git push -f'", True),
    ("вложенные shell", "bash -c \"sh -c 'git push -f'\"", True),
    ("bash -o pipefail -c", "bash -o pipefail -c 'git push -f'", True),
    ("bash -eu -o pipefail -c", "bash -eu -o pipefail -c 'git push -f'", True),
    ("o в связке: bash -euo pipefail -c", "bash -euo pipefail -c 'git push -f'", True),
    ("две o в связке", "bash -oo pipefail nounset -c 'git push -f'", True),
    ("bash -O shopt -c", "bash -O extglob -c 'git push -f'", True),
    ("bash +o, -c после значения", "bash -c +o pipefail 'git push -f'", True),
    ("sh -eo pipefail -c", "sh -eo pipefail -c 'git push -f'", True),
    ("zsh -euo pipefail -c", "zsh -euo pipefail -c 'git push -f'", True),
    ("zsh -opipefail: значение в связке", "zsh -opipefail -c 'git push -f'", True),
    ("eval строкой", 'eval "git push -f"', True),
    ("eval словами", "eval git push --force", True),
    ("heredoc в bash", "bash <<'EOF'\ngit push -f\nEOF", True),
    ("echo в pipe в sh", "echo 'git push -f' | sh", True),
    ("printf в pipe в bash", "printf 'git push --force\\n' | bash", True),
    ("ssh на хост", "ssh host 'cd repo && git push -f'", True),
    ("ssh -p порт", "ssh -p 2222 user@host git push --force", True),
    ("find -execdir", "find . -name .git -execdir git push -f \\;", True),
    ("переменная с флагом", "F=--force; git push $F origin x", True),
    ("export переменной", "export F=-f && git push ${F}", True),
    # ── составные команды ────────────────────────────────────────────────────
    ("&&", "git add . && git push -f", True),
    ("||", "git push || git push -f", True),
    (";", "git status; git push -f", True),
    ("pipe", "git push -f 2>&1 | tee log", True),
    ("фон &", "git push -f &", True),
    ("перевод строки", "git status\ngit push -f", True),
    ("продолжение строки", "git push \\\n  --force origin x", True),
    ("подстановка $(...)", "echo $(git push -f)", True),
    ("подстановка в двойных кавычках", 'git commit -m "x $(git push -f)"', True),
    ("обратные кавычки", "echo `git push -f`", True),
    ("подоболочка", "(cd /tmp/r && git push -f)", True),
    ("группа { }", "{ git push -f; }", True),
    ("if/then", "if true; then git push -f; fi", True),
    ("for/do", "for b in a c; do git push -f origin $b; done", True),
    ("функция", "f() { git push -f; }; f", True),
    ("подстановка процесса", "cat <(git push -f)", True),
    ("после комментария на другой строке", "# готово\ngit push -f", True),
    # ── обычная работа: должно проходить ─────────────────────────────────────
    ("обычный push", "git push", False),
    ("push с remote и веткой", "git push origin main", False),
    ("push -u", "git push -u origin feature", False),
    ("push --set-upstream", "git push --set-upstream origin feature", False),
    ("push --tags", "git push --tags", False),
    ("push --follow-tags", "git push --follow-tags origin main", False),
    ("push --delete", "git push --delete origin old", False),
    ("push -d", "git push -d origin old", False),
    ("удаление через :branch", "git push origin :old", False),
    ("push --prune", "git push --prune origin 'refs/heads/*:refs/heads/*'", False),
    ("push HEAD:ref", "git push origin HEAD:refs/heads/x", False),
    ("push -o push-option", "git push -o ci.skip origin x", False),
    ("push -of: 'f' — значение push-option", "git push -of origin x", False),
    ("push --push-option с '+'", "git push --push-option +x origin x", False),
    ("ветка с '-f' после --", "git push origin -- -f", False),
    ("--no-verify", "git push --no-verify origin x", False),
    ("dry-run с --force", "git push --dry-run --force origin x", False),
    ("dry-run -n с -f", "git push -n -f origin x", False),
    ("dry-run в связке -nf", "git push -nf origin x", False),
    ("dry-run с --mirror", "git push --dry-run --mirror origin", False),
    ("dry-run с +refspec", "git push --dry-run origin +main", False),
    ("fetch --force — не push", "git fetch --force origin", False),
    ("fetch -f", "git fetch -f origin main:main", False),
    ("pull --force", "git pull --force", False),
    ("stash push", "git stash push -m wip", False),
    ("commit message со строкой", 'git commit -m "no git push -f"', False),
    ("commit message одинарные", "git commit -m 'git push --force is forbidden'", False),
    ("подстановка в одинарных — данные", "git commit -m '$(git push -f)'", False),
    ("echo строки", 'echo "git push -f"', False),
    ("printf строки", "printf 'git push --force\\n'", False),
    ("rg по тексту", "rg 'push --force' agents/", False),
    ("grep по тексту", 'grep -rn "git push -f" .', False),
    ("git log --grep", 'git log --grep="push -f"', False),
    ("git grep", "git grep -n 'push --force'", False),
    ("heredoc в файл — данные", "cat > notes.md <<'EOF'\ngit push -f\nEOF", False),
    ("heredoc в git commit -F-", "git commit -F - <<EOF\nreverted git push --force\nEOF", False),
    ("комментарий", "git push  # не git push -f", False),
    ("command -v git", "command -v git", False),
    ("bash script.sh — файл не виден", "bash push.sh", False),
    ("bash -c без force", "bash -lc 'git push origin main'", False),
    ("bash -euo pipefail без force", "bash -euo pipefail -c 'git push origin main'", False),
    ("timeout без force", "timeout 30 git push origin x", False),
    ("ssh без force", "ssh host 'git push origin x'", False),
    ("help по push", "git push --help", False),
    ("-c alias без force", "git -c alias.p=push p origin x", False),
    ("-c remote.*.push без '+'", "git -c remote.origin.push=refs/heads/a:refs/heads/a push", False),
    ("gh pr create", "gh pr create --draft --fill", False),
    ("переменная без force", "B=main; git push origin $B", False),
    ("--no-dry-run не отменяется молча", "git push --no-dry-run origin x", False),
    # ── последний из --dry-run/--no-dry-run побеждает ───────────────────────
    ("--dry-run отменён --no-dry-run", "git push --dry-run --no-dry-run -f origin x", True),
    # ── fail-open: непонятное — пропуск ──────────────────────────────────────
    ("незакрытая двойная кавычка", 'git push -f "oops', False),
    ("незакрытая одинарная кавычка", "git push -f 'oops", False),
    ("незакрытая подстановка", "echo $(git push -f", False),
    ("незакрытая обратная кавычка", "echo `git push -f", False),
    ("глубже предела вложенности", "eval " * 20 + "git push -f", False),
    ("пустая команда", "", False),
    ("одни пробелы", "   \n  ", False),
]


def find_hook() -> Path:
    """Собранное дерево, если есть, — его и запускает рантайм; иначе исходник."""
    for candidate in (ROOT / ".claude/hooks", ROOT / "agents/common/hooks"):
        hook = candidate / "block-force-push.py"
        if hook.is_file():
            return hook
    sys.exit("block-force-push.py not found in .claude/hooks or agents/common/hooks")


def shapes(cmd: str) -> dict[str, dict]:
    """Один вызов так, как его кладёт на провод каждый агент."""
    return {
        "claude snake+str": {"tool_name": "Bash", "cwd": "/tmp", "tool_input": {"command": cmd}},
        "codex camel+str": {"toolName": "shell", "cwd": "/tmp", "toolInput": {"command": cmd}},
        "codex camel+argv": {"toolName": "shell", "cwd": "/tmp",
                             "toolInput": {"command": ["bash", "-lc", cmd]}},
    }


def run(hook: Path, stdin: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(hook)], input=stdin, capture_output=True, text=True, timeout=30)


def verdict(proc: subprocess.CompletedProcess) -> bool | str:
    """True — отказ, False — пропуск, строка — хук сломан."""
    if proc.returncode != 0:
        return f"exit={proc.returncode} stderr={proc.stderr.strip()[:200]!r}"
    if not proc.stdout.strip():
        return False
    try:
        out = json.loads(proc.stdout)
        spec = out["hookSpecificOutput"]
    except (ValueError, KeyError, TypeError) as exc:
        return f"нечитаемое решение: {exc}"
    if spec.get("hookEventName") != "PreToolUse" or spec.get("permissionDecision") != "deny":
        return f"неожиданное решение: {spec!r}"
    return True


def reason(proc: subprocess.CompletedProcess) -> str:
    return json.loads(proc.stdout)["hookSpecificOutput"]["permissionDecisionReason"]


def main() -> int:
    hook = find_hook()
    failures = 0

    if not hook.stat().st_mode & 0o111:
        print(f"  FAIL {hook}: не исполняемый — агент его не запустит")
        failures += 1

    for what, cmd, want in CASES:
        bad = []
        for shape, payload in shapes(cmd).items():
            got = verdict(run(hook, json.dumps(payload)))
            if got is not want:
                bad.append(f"{shape} → {got!r}, ожидался {'deny' if want else 'allow'}")
        if bad:
            failures += 1
            print(f"  FAIL {what}: {cmd!r}")
            for line in bad:
                print(f"       {line}")

    # Текст отказа: правило и исполнитель названы, команда целиком — нет.
    # URL remote бывает с токеном, а причина дописывается в транскрипт.
    proc = run(hook, json.dumps(shapes(
        "git push -f https://u:not-a-real-pass@example.com/r.git main")["claude snake+str"]))
    text = reason(proc) if verdict(proc) is True else ""
    for must in ("никогда", "даже по прямой просьбе пользователя", "человек", "-f"):
        if must not in text:
            failures += 1
            print(f"  FAIL причина отказа не содержит {must!r}: {text!r}")
    if "not-a-real-pass" in text or "example.com" in text:
        failures += 1
        print("  FAIL причина отказа повторяет URL remote — в нём бывает токен")

    # Признак называется конкретно: человеку видно, что именно сработало.
    for cmd, marker in (("git push origin +main", "+main"),
                        ("git push --mirror origin", "--mirror"),
                        ("git push --force-with-lease", "--force-with-lease")):
        proc = run(hook, json.dumps(shapes(cmd)["claude snake+str"]))
        if verdict(proc) is not True or marker not in reason(proc):
            failures += 1
            print(f"  FAIL причина для {cmd!r} не называет {marker!r}")

    # Субагент — тот же запрет: agent_id ничего не меняет.
    sub = dict(shapes("git push -f")["claude snake+str"], agent_id="a1", agent_type="worker")
    if verdict(run(hook, json.dumps(sub))) is not True:
        failures += 1
        print("  FAIL субагент (agent_id) прошёл с git push -f")

    # Не shell-инструмент — не его дело, даже с полем command.
    for tool in ("Read", "Edit", "WebFetch"):
        payload = {"tool_name": tool, "tool_input": {"command": "git push -f"}}
        if verdict(run(hook, json.dumps(payload))) is not False:
            failures += 1
            print(f"  FAIL инструмент {tool} получил отказ — хук только для shell")

    # Codex exec_command с полем cmd вместо command.
    payload = {"toolName": "exec_command", "toolInput": {"cmd": "git push --force"}}
    if verdict(run(hook, json.dumps(payload))) is not True:
        failures += 1
        print("  FAIL exec_command с полем cmd прошёл с git push --force")

    # Fail-open на испорченных и чужих payload: exit 0 и пустой stdout.
    garbage = (
        ("пустой stdin", ""),
        ("не json", "не json вовсе"),
        ("обрезанный json", '{"tool_input": {"command": "git push -f"'),
        ("массив", '["git", "push", "-f"]'),
        ("строка json", '"git push -f"'),
        ("пустой объект", "{}"),
        ("tool_input null", '{"tool_name": "Bash", "tool_input": null}'),
        ("tool_input строкой", '{"tool_name": "Bash", "tool_input": "git push -f"}'),
        ("command числом", '{"tool_name": "Bash", "tool_input": {"command": 42}}'),
        ("command объектом", '{"tool_name": "Bash", "tool_input": {"command": {"x": 1}}}'),
        ("tool_name числом", '{"tool_name": 7, "tool_input": {"command": "git push -f"}}'),
    )
    for name, stdin in garbage:
        proc = run(hook, stdin)
        if proc.returncode != 0 or proc.stdout.strip():
            failures += 1
            print(f"  FAIL fail-open / {name}: exit={proc.returncode} stdout={proc.stdout.strip()[:120]!r}")

    total = len(CASES) * 3
    if failures:
        print(f"\n  провалено {failures} проверок (случаев в таблице: {len(CASES)}, прогонов: {total})")
        return 1
    print(f"  block-force-push.py: {len(CASES)} случаев × 3 формы payload, "
          f"текст отказа, субагент, чужие инструменты и {len(garbage)} испорченных ввода — ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
