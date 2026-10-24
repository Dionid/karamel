#!/usr/bin/env python3
"""Поведение check-decisions.py.

Проверка реестра решений сама должна быть проверена, и причина та же, по
которой она вообще существует: её отказ невидим. Чекер, который перестал что-то
ловить, выглядит точно как чекер, у которого всё в порядке, — оба печатают
«в порядке» и возвращают 0.

Поэтому каждый инвариант проверяется дважды: на корректном реестре (обязан
пройти) и на реестре, сломанном ровно в этом месте (обязан упасть). Один
негативный кейс на инвариант — иначе «падает всегда» тоже сошло бы за
исправность.

Запускается автообнаружением в lint.sh.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

CHECKER = (
    Path(__file__).resolve().parent.parent
    / "skills"
    / "lint"
    / "check-decisions.py"
)

VALID = """# Решения

Преамбула.

---

## DEC-001 — Первое решение

- **Статус:** в силе
- **Принято:** 2026-09-03 (`abc1234`)
- **Заменяет:** —
- **Заменено:** —
- **Где применяется:** `что-то`

**Причина.** Потому что.

## DEC-002 — Второе решение, отменяющее первое

- **Статус:** в силе
- **Принято:** неизвестно
- **Заменяет:** DEC-003
- **Заменено:** —
- **Где применяется:** `что-то ещё`

**Причина.** Потому что.

## DEC-003 — Устаревшее решение

- **Статус:** заменено
- **Принято:** неизвестно
- **Заменяет:** —
- **Заменено:** DEC-002
- **Где применяется:** `третье`

**Причина.** Потому что было иначе.
"""


def run(content: str) -> int:
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "DECISIONS.md"
        path.write_text(content, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(CHECKER), str(path)],
            capture_output=True,
            text=True,
        )
        return result.returncode


def run_dir(files: dict) -> int:
    """Same checker, but against a DECISIONS/ directory: one .md per key."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "DECISIONS"
        root.mkdir()
        for name, content in files.items():
            (root / name).write_text(content, encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(CHECKER), str(root)],
            capture_output=True,
            text=True,
        )
        return result.returncode


def split_valid() -> dict:
    """VALID split into one file per DEC-NNN, plus a README.md that must be
    ignored — same shape as config/DECISIONS/ after the folder conversion."""
    preamble, rest = VALID.split("---", 1)
    blocks = ["## DEC-" + b for b in rest.split("## DEC-")[1:]]
    files = {f"{block.split(chr(10), 1)[0].split(' ')[1]}.md": block for block in blocks}
    files["README.md"] = preamble
    return files


CASES = [
    ("корректный реестр проходит", VALID, 0),
    (
        "дублирующийся DEC-NNN ловится",
        VALID + VALID.split("---", 1)[1],
        1,
    ),
    (
        "пропущенное обязательное поле ловится",
        VALID.replace("- **Где применяется:** `что-то`\n", "", 1),
        1,
    ),
    (
        "статус вне набора ловится",
        VALID.replace("- **Статус:** в силе", "- **Статус:** наверное да", 1),
        1,
    ),
    (
        "«в силе» с заполненным «Заменено» — противоречие",
        VALID.replace(
            "- **Статус:** в силе\n- **Принято:** 2026-09-03 (`abc1234`)\n"
            "- **Заменяет:** —\n- **Заменено:** —",
            "- **Статус:** в силе\n- **Принято:** 2026-09-03 (`abc1234`)\n"
            "- **Заменяет:** —\n- **Заменено:** DEC-002",
            1,
        ),
        1,
    ),
    (
        "«заменено» без указания чем — ловится",
        VALID.replace(
            "- **Статус:** заменено\n- **Принято:** неизвестно\n"
            "- **Заменяет:** —\n- **Заменено:** DEC-002",
            "- **Статус:** заменено\n- **Принято:** неизвестно\n"
            "- **Заменяет:** —\n- **Заменено:** —",
            1,
        ),
        1,
    ),
    (
        "односторонняя ссылка на замену ловится",
        VALID.replace("- **Заменяет:** DEC-003", "- **Заменяет:** —", 1),
        1,
    ),
    (
        "ссылка на несуществующее решение ловится",
        VALID.replace("- **Заменяет:** DEC-003", "- **Заменяет:** DEC-777", 1),
        1,
    ),
    (
        "решение без блока «Причина» ловится",
        VALID.replace("**Причина.** Потому что.\n", "", 1),
        1,
    ),
    (
        "пустое поле «Принято» ловится",
        VALID.replace("- **Принято:** 2026-09-03 (`abc1234`)", "- **Принято:**", 1),
        1,
    ),
    ("файл без решений ловится", "# Решения\n\nНичего.\n", 1),
]

# Один файл на решение — форма config/DECISIONS/ после разбивки. Мутирует не
# сами блоки, а имена файлов и то, какой файл что содержит, поэтому эти кейсы
# проверяют ровно то, что не могло сработать на одном файле: реестр собирается
# из каталога, а не читается как один текст.
def lone(dec_id: str) -> str:
    """Минимальное валидное решение: случай проверяет индекс, а не формат."""
    return (
        f"## {dec_id} — Отдельное решение\n\n"
        "- **Статус:** в силе\n"
        "- **Принято:** 2026-01-01\n"
        "- **Заменяет:** —\n"
        "- **Заменено:** —\n"
        "- **Где применяется:** `что-то`\n\n"
        "**Причина.** Нужна, иначе сработает другая проверка.\n"
    )


def split_valid_indexed() -> dict:
    """`split_valid()`, но README перечисляет каждое решение — то есть ведёт
    себя как настоящий реестр, а не как преамбула."""
    files = split_valid()
    listed = sorted(name[:-3] for name in files if name != "README.md")
    files["README.md"] = files["README.md"] + "\n" + "".join(
        f"- [{dec_id}]({dec_id}.md)\n" for dec_id in listed
    )
    return files


DIR_CASES = [
    ("каталог: корректный реестр (взаимность через файлы) проходит", split_valid(), 0),
    (
        "каталог: README.md/index.md не считается решением",
        {**split_valid(), "index.md": "# тоже не решение\n"},
        0,
    ),
    (
        "каталог: одно и то же DEC-NNN в двух файлах ловится",
        {**split_valid(), "DEC-001-dup.md": split_valid()["DEC-001.md"]},
        1,
    ),
    (
        "каталог: односторонняя ссылка на замену между файлами ловится",
        {
            **split_valid(),
            "DEC-002.md": split_valid()["DEC-002.md"].replace(
                "- **Заменяет:** DEC-003", "- **Заменяет:** —"
            ),
        },
        1,
    ),
    (
        "каталог: ссылка на DEC-NNN, которого нет ни в одном файле, ловится",
        {
            **split_valid(),
            "DEC-002.md": split_valid()["DEC-002.md"].replace(
                "- **Заменяет:** DEC-003", "- **Заменяет:** DEC-777"
            ),
        },
        1,
    ),
    ("каталог: только README.md, ни одного решения — ловится", {"README.md": "# Решения\n"}, 1),
    (
        "каталог: файл решения без валидного заголовка DEC-NNN не пропадает молча",
        {**split_valid(), "DEC-004.md": "## DEC-4 - Сломанный заголовок\n\nтекст\n"},
        1,
    ),
    # Реестр, перечисляющий часть решений, выглядит полным — и потому опаснее
    # отсутствующего: читатель не узнает, что чего-то не увидел.
    (
        "каталог: решение есть файлом, но не числится в README — ловится",
        {**split_valid_indexed(), "DEC-009.md": lone("DEC-009")},
        1,
    ),
    (
        "каталог: README перечисляет все решения — проходит",
        split_valid_indexed(),
        0,
    ),
    # Индекс без единой ссылки — преамбула, а не реестр; требовать от неё
    # полноты значило бы ломать каталоги, которые индекс вообще не ведут.
    (
        "каталог: README без ссылок на решения полноты не требует",
        {**split_valid(), "DEC-009.md": lone("DEC-009")},
        0,
    ),
]


def main() -> int:
    if not CHECKER.is_file():
        print(f"FAIL: не найден чекер {CHECKER}", file=sys.stderr)
        return 1

    failures = 0

    for label, content, expected in CASES:
        actual = run(content)
        if actual == expected:
            print(f"ok   {label}")
        else:
            failures += 1
            print(
                f"FAIL {label}: ожидался код {expected}, получен {actual}",
                file=sys.stderr,
            )

    for label, files, expected in DIR_CASES:
        actual = run_dir(files)
        if actual == expected:
            print(f"ok   {label}")
        else:
            failures += 1
            print(
                f"FAIL {label}: ожидался код {expected}, получен {actual}",
                file=sys.stderr,
            )

    total = len(CASES) + len(DIR_CASES)
    print(f"\n{total} проверок, {failures} неудач")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
