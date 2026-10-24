#!/usr/bin/env python3
"""Политика гардов, проверяемая исполнением, а не абзацем в документации.

Два правила, и у них РАЗНАЯ полярность — спутать их легко, а цена спутывания
обратная в каждую сторону:

  * **Гард в рабочем потоке fail-open.** Хук, который не понял, что ему дали,
    обязан пропустить. Гард, падающий на неожиданном вводе, останавливает не
    опасное действие, а работу вообще, и его снимают целиком — после чего не
    защищено уже ничего. Поэтому «не понял» значит «пропусти», а не «запрети».
  * **Тест наоборот fail-closed.** Сломанная проверка — это провал, а не
    пропуск; иначе набор зеленеет ровно в тот момент, когда перестаёт работать.
    Это правило держит сам факт существования этого файла.

Проверяется ОБНАРУЖЕНИЕМ, а не списком: перечисленный хук — это хук, который
кто-то должен не забыть дописать сюда, а забывают всегда. Ноль найденных хуков
считается провалом, потому что сломаться может и само обнаружение.

Третья проверка — у каждого хука есть тест, который его называет. Гард без
теста, который краснеет при снятии гарда, защитой не является: он выглядит как
защита в диффе и ничего не делает в бою.

    python3 agents/common/tests/guards-fail-open.test.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HOOKS = ROOT / "agents" / "common" / "hooks"
TESTS = ROOT / "agents" / "common" / "tests"

# Вводы, которых хук не ждёт. Ни один не должен привести к отказу: это не
# «опасная команда», это испорченный или чужой payload.
GARBAGE = (
    ("пустой stdin", ""),
    ("не json", "не json вовсе"),
    ("пустой объект", "{}"),
    ("null в ожидаемом поле", '{"tool_input": null}'),
    ("чужая форма события", '{"hook_event_name": "Unknown", "whatever": 1}'),
    ("обрезанный json", '{"tool_input": {"command": "ls"'),
    ("массив вместо объекта", "[1, 2, 3]"),
)


def refuses(stdout: str) -> bool:
    """Отказ в любой из двух форм, которые понимают агенты."""
    out = stdout.strip()
    if not out:
        return False
    try:
        data = json.loads(out)
    except ValueError:
        return False
    if data.get("decision") == "block":
        return True
    spec = data.get("hookSpecificOutput")
    return isinstance(spec, dict) and spec.get("permissionDecision") == "deny"


def main() -> int:
    hooks = sorted(p for p in HOOKS.iterdir() if p.is_file() and not p.name.startswith("."))
    if not hooks:
        print(f"  FAIL  в {HOOKS.relative_to(ROOT)} не найдено ни одного хука — "
              "сломано обнаружение, а не политика")
        return 1

    test_text = "\n".join(p.read_text(errors="replace") for p in TESTS.glob("*.test.*"))
    failures = 0

    for hook in hooks:
        rel = hook.relative_to(ROOT).as_posix()

        if not hook.stat().st_mode & 0o111:
            print(f"  FAIL  {rel}: не исполняемый — агент его просто не запустит")
            failures += 1
            continue

        for name, payload in GARBAGE:
            try:
                proc = subprocess.run([str(hook)], input=payload, capture_output=True,
                                      text=True, timeout=30, cwd=ROOT)
            except subprocess.TimeoutExpired:
                print(f"  FAIL  {rel} / {name}: завис — гард обязан отвечать быстро")
                failures += 1
                continue
            if proc.returncode != 0:
                print(f"  FAIL  {rel} / {name}: exit={proc.returncode}, ожидался 0 "
                      "(гард в рабочем потоке fail-open)")
                failures += 1
            elif refuses(proc.stdout):
                print(f"  FAIL  {rel} / {name}: отказ на вводе, который хук не понял")
                failures += 1

        if hook.name not in test_text:
            print(f"  FAIL  {rel}: ни один тест его не называет — "
                  "гард без теста защитой не является")
            failures += 1

    total = len(hooks) * (len(GARBAGE) + 2)
    if failures:
        print(f"\n  провалено {failures} из {total}")
        return 1
    print(f"  {len(hooks)} хук(ов) × {len(GARBAGE)} испорченных ввода: все fail-open, "
          "исполняемы и покрыты тестом")
    return 0


if __name__ == "__main__":
    sys.exit(main())
