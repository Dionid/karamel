#!/usr/bin/env python3
"""Проверка DECISIONS.md — реестров долговременных решений.

Что именно проверяется и почему именно это.

Реестр решений разваливается одним способом: решение отменяют, а запись
остаётся в статусе «в силе». Тогда файл не просто устаревает — он врёт, и врёт
убедительнее, чем `AGENTS.md`, потому что у записи есть дата и статус, и им
верят. Поэтому проверяются не орфография и не полнота, а ровно те инварианты,
без которых статус перестаёт что-либо значить:

  * уникальные идентификаторы формата DEC-NNN;
  * все обязательные поля на месте;
  * статус — из фиксированного набора, а не свободный текст;
  * «заменено» обязано указывать, ЧЕМ заменено;
  * «в силе» обязано иметь пустое поле «Заменено»;
  * ссылки на замену ВЗАИМНЫ: если A заменено на B, у B в «Заменяет» стоит A.

Последнее — главное. Односторонняя ссылка означает, что читатель B не узнает,
что B что-то отменяет, и оба решения будут выглядеть действующими.

Наличие «Причина» проверяется тоже: решение без причины нельзя ни оспорить, ни
признать устаревшим, потому что неизвестно, при каких условиях оно принималось.

Реестр — это либо один файл (несколько `## DEC-NNN` подряд), либо каталог с
одним `## DEC-NNN` на файл плюс необязательный `README.md`/`index.md` без
собственного решения. В обоих случаях взаимность ссылок «Заменяет»/«Заменено»
проверяется по всему реестру целиком, а не по одному файлу, — иначе разбивка
файла на каталог сама по себе стала бы ложным срабатыванием.

Usage: check-decisions.py <DECISIONS.md|DECISIONS-dir> [<...>...]
"""

import re
import sys
from pathlib import Path

STATUSES = {"в силе", "заменено", "отменено"}
REQUIRED_FIELDS = ("Статус", "Принято", "Заменяет", "Заменено", "Где применяется")
EMPTY = {"—", "-", ""}
INDEX_NAMES = {"readme.md", "index.md"}

HEADING = re.compile(r"^##\s+(DEC-\d{3})\s+—\s+(.+?)\s*$")
FIELD = re.compile(r"^-\s+\*\*(?P<name>[^:*]+):\*\*\s*(?P<value>.*?)\s*$")
REASON = re.compile(r"^\*\*Причина\.\*\*", re.MULTILINE)
DEC_REF = re.compile(r"DEC-\d{3}")


class Problem(Exception):
    pass


def parse(path: Path):
    """Разбирает один файл в {dec_id: {...}}. Порядок разделов сохраняется."""
    text = path.read_text(encoding="utf-8")
    lines = text.splitlines()

    decisions = {}
    current = None

    for lineno, line in enumerate(lines, start=1):
        heading = HEADING.match(line)
        if heading:
            dec_id, title = heading.group(1), heading.group(2)
            if dec_id in decisions:
                raise Problem(
                    f"{path}:{lineno}: {dec_id} встречается второй раз "
                    f"(первый — строка {decisions[dec_id]['line']})"
                )
            current = {
                "id": dec_id,
                "title": title,
                "line": lineno,
                "file": path,
                "fields": {},
                "body": [],
            }
            decisions[dec_id] = current
            continue

        if line.startswith("## "):
            # Раздел, который не является решением: заголовок без DEC-NNN.
            current = None
            continue

        if current is None:
            continue

        field = FIELD.match(line)
        if field:
            current["fields"][field.group("name").strip()] = field.group("value").strip()
        else:
            current["body"].append(line)

    return decisions


def collect(path: Path):
    """Собирает реестр: один файл как есть, каталог — как один реестр по всем
    его файлам (кроме README/index), с общим пространством DEC-NNN."""
    if not path.is_dir():
        return parse(path)

    members = sorted(
        p for p in path.glob("*.md") if p.name.lower() not in INDEX_NAMES
    )
    if not members:
        raise Problem(f"{path}: в каталоге нет ни одного файла решения (*.md)")

    combined = {}
    for member in members:
        member_decisions = parse(member)
        if not member_decisions:
            raise Problem(
                f"{member}: ни одного решения — заголовок `## DEC-NNN — …` не "
                "найден или не распознан"
            )
        for dec_id, dec in member_decisions.items():
            if dec_id in combined:
                raise Problem(
                    f"{member}: {dec_id} уже определён в "
                    f"{combined[dec_id]['file']}"
                )
            combined[dec_id] = dec
    return combined


def check_registry(path: Path) -> list:
    problems = []
    decisions = collect(path)

    if not decisions:
        return [f"{path}: ни одного решения — реестр пуст или формат разъехался"]

    for dec_id, dec in decisions.items():
        where = f"{dec['file']}:{dec['line']}: {dec_id}"
        fields = dec["fields"]

        for name in REQUIRED_FIELDS:
            if name not in fields:
                problems.append(f"{where}: нет обязательного поля «{name}»")

        status = fields.get("Статус", "")
        if status and status not in STATUSES:
            problems.append(
                f"{where}: статус «{status}» не из набора "
                f"({', '.join(sorted(STATUSES))})"
            )

        if not fields.get("Принято", "").strip():
            problems.append(f"{where}: поле «Принято» пустое — нужна дата или «неизвестно»")

        superseded_by = fields.get("Заменено", "")
        if status == "заменено" and superseded_by in EMPTY:
            problems.append(
                f"{where}: статус «заменено», но поле «Заменено» пустое — "
                "неизвестно, чем заменено"
            )
        if status == "в силе" and superseded_by not in EMPTY:
            problems.append(
                f"{where}: статус «в силе», но поле «Заменено» заполнено "
                f"(«{superseded_by}») — противоречие"
            )

        if not REASON.search("\n".join(dec["body"])):
            problems.append(
                f"{where}: нет блока «**Причина.**» — решение без причины нельзя "
                "ни оспорить, ни признать устаревшим"
            )

        # Взаимность ссылок.
        for field_name, mirror in (("Заменено", "Заменяет"), ("Заменяет", "Заменено")):
            value = fields.get(field_name, "")
            if value in EMPTY:
                continue
            for ref in DEC_REF.findall(value):
                target = decisions.get(ref)
                if target is None:
                    problems.append(
                        f"{where}: поле «{field_name}» ссылается на {ref}, "
                        "которого в этом реестре нет"
                    )
                    continue
                back = target["fields"].get(mirror, "")
                if dec_id not in DEC_REF.findall(back):
                    problems.append(
                        f"{where}: ссылка не взаимна — у {ref} в поле «{mirror}» "
                        f"нет {dec_id} (там «{back or 'пусто'}»)"
                    )

    problems.extend(check_index(path, decisions))
    return problems


def check_index(path: Path, decisions: dict) -> list:
    """Каждое решение каталога должно числиться в его README/index.

    Реестр — это то, что читают, когда ищут решение; файл, которого в нём нет,
    для читателя не существует, а проверки выше его видят и молчат, потому что
    собирают реестр по файлам и индекс из сбора исключают. Так из реестра
    `agent-workspace` выпали три решения подряд, и линт всё это время был зелёным.

    Индекс необязателен: каталог без него — не ошибка. Но индекс, который уже
    перечисляет хоть одно решение, обязан перечислять все: наполовину
    заполненный список хуже отсутствующего, потому что выглядит полным.
    """
    if not path.is_dir():
        return []

    indexes = sorted(c for c in path.glob("*.md") if c.name.lower() in INDEX_NAMES)
    if not indexes:
        return []
    index = indexes[0]

    text = index.read_text(encoding="utf-8")
    listed = set(DEC_REF.findall(text))
    if not listed:
        return []

    missing = sorted(set(decisions) - listed)
    return [
        f"{index}: {dec_id} есть файлом, но не числится в реестре — "
        "найти его через индекс нельзя"
        for dec_id in missing
    ]


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2

    problems = []
    checked = 0

    for arg in argv[1:]:
        path = Path(arg)
        if not path.exists():
            problems.append(f"{path}: файла нет")
            continue
        checked += 1
        try:
            problems.extend(check_registry(path))
        except Problem as exc:
            problems.append(str(exc))

    for problem in problems:
        print(f"  {problem}", file=sys.stderr)

    if problems:
        return 1

    print(f"  {checked} реестр(ов) решений в порядке")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
