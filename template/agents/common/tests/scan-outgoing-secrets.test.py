#!/usr/bin/env python3
"""Сквозная проверка Stop-хука, стерегущего секрет на выходе.

Хук получает на stdin полезную нагрузку события и читает транскрипт сессии,
поэтому проверять его отдельно от этой формы бессмысленно: селфтест внутри
хука отвечает только за шаблоны, а здесь проверяется то, из-за чего гард
обычно и не срабатывает — разбор транскрипта, петля и fail-open.

Четыре инварианта, и каждый ломается по-своему:

  * секрет в ПОСЛЕДНЕМ сообщении ассистента останавливает ответ;
  * `reason` никогда не содержит сам фрагмент: он дописывается в транскрипт,
    и секрет в нём означал бы ровно ту утечку, которую хук предотвращает;
  * `stop_hook_active` снимает проверку — иначе отказ зациклится и агент
    перестанет отвечать вообще;
  * любая неожиданность (нет файла, битый JSON, транскрипт без текста) —
    молчаливый пропуск, а не отказ. Гард не имеет права сделать агента немым.

    python3 agents/common/tests/scan-outgoing-secrets.test.py
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

HOOK = Path(__file__).resolve().parents[1] / "hooks" / "scan-outgoing-secrets.py"

# Собирается из кусков: литерал в файле репозитория сам стал бы тем, что хук ловит.
LIVE = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2"


def rec_assistant(*blocks: dict) -> str:
    return json.dumps({"type": "assistant",
                       "message": {"role": "assistant", "content": list(blocks)}})


def rec_user(text: str) -> str:
    return json.dumps({"type": "user",
                       "message": {"role": "user",
                                   "content": [{"type": "text", "text": text}]}})


def text_block(t: str) -> dict:
    return {"type": "text", "text": t}


def tool_block(t: str) -> dict:
    return {"type": "tool_use", "name": "Bash", "input": {"command": t}}


def run(transcript_lines: list[str] | None, *, active: bool = False,
        raw_stdin: str | None = None) -> subprocess.CompletedProcess:
    with tempfile.TemporaryDirectory() as tmp:
        payload: dict = {"hook_event_name": "Stop", "stop_hook_active": active}
        if transcript_lines is not None:
            path = Path(tmp) / "transcript.jsonl"
            path.write_text("\n".join(transcript_lines) + "\n")
            payload["transcript_path"] = str(path)
        stdin = raw_stdin if raw_stdin is not None else json.dumps(payload)
        return subprocess.run([sys.executable, str(HOOK)], input=stdin,
                              capture_output=True, text=True)


def blocked(proc: subprocess.CompletedProcess) -> bool:
    out = proc.stdout.strip()
    if not out:
        return False
    try:
        return json.loads(out).get("decision") == "block"
    except ValueError:
        return False


def main() -> int:
    failures = 0
    checked = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal failures, checked
        checked += 1
        if ok:
            print(f"  ok    {name}")
        else:
            failures += 1
            print(f"  FAIL  {name}{(' — ' + detail) if detail else ''}")

    # 1. Секрет в последнем сообщении — ответ придержан.
    p = run([rec_assistant(text_block(f"готово, токен {LIVE}"))])
    check("секрет в последнем сообщении блокирует ответ", blocked(p), p.stdout[:120])

    # 2. Сам фрагмент не возвращается обратно в транскрипт.
    check("reason не содержит фрагмент", LIVE not in p.stdout, "фрагмент утёк в reason")
    check("reason называет тип ключа", "GitHub token" in p.stdout)

    # 3. Чистый ответ проходит молча.
    p = run([rec_assistant(text_block("MR !36 открыт, пайплайн зелёный"))])
    check("чистый ответ не трогается", not blocked(p) and p.stdout.strip() == "")

    # 4. Петля: хук уже держит этот ход.
    p = run([rec_assistant(text_block(f"всё ещё {LIVE}"))], active=True)
    check("stop_hook_active снимает проверку", not blocked(p))

    # 5. Секрет в аргументе инструмента наружу не уходит — проверять нечего.
    p = run([rec_assistant(text_block("смотрю конфиг")),
             rec_assistant(tool_block(f"git remote set-url o https://x:{LIVE}@h/r.git"))])
    check("секрет только в tool_use не блокирует", not blocked(p))

    # 6. Проверяется последнее сообщение, а не вся история.
    p = run([rec_assistant(text_block(f"старое сообщение с {LIVE}")),
             rec_user("продолжай"),
             rec_assistant(text_block("теперь всё чисто"))])
    check("старое сообщение не держит новый ответ", not blocked(p))

    # 7. Fail-open: нет файла, битый stdin, транскрипт без текста, пустой stdin.
    p = run(None)
    check("нет transcript_path — пропуск", p.returncode == 0 and not p.stdout.strip())

    p = run([], raw_stdin="не json")
    check("битый stdin — пропуск", p.returncode == 0 and not p.stdout.strip())

    p = run([rec_assistant(tool_block("ls")), "{битая строка", ""])
    check("битые строки транскрипта — пропуск",
          p.returncode == 0 and not p.stdout.strip())

    p = run([], raw_stdin="")
    check("пустой stdin — пропуск", p.returncode == 0 and not p.stdout.strip())

    # 8. Шаблоны самого детектора.
    st = subprocess.run([sys.executable, str(HOOK), "--selftest"],
                        capture_output=True, text=True)
    check("селфтест шаблонов зелёный", st.returncode == 0, st.stdout[-200:])

    if failures:
        print(f"\n  {failures} проверок провалено")
        return 1
    print(f"\n  {checked} проверок пройдено")
    return 0


if __name__ == "__main__":
    sys.exit(main())
