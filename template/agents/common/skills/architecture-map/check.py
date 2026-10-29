#!/usr/bin/env python3
"""Проверка архитектурного документа: каждая ссылка `path:line` существует.

    check.py --root <каталог, от которого считаются пути> <architecture/<name>/>

Ссылка — inline code вида `path:line` или `path:start-end` (в `.html` —
`<code>path:line</code>`) вне fenced-блоков. Файл должен лежать внутри
`--root`, строка — в пределах его длины. В `README.md` обязателен раздел
`## Неподтверждённое`; его пункты печатаются отдельным списком.

Exit: 0 — все ссылки целы; 1 — битая ссылка, нет README.md или раздела
«Неподтверждённое»; 2 — неверный вызов. Только stdlib.
Тест: agents/common/skills/architecture-map/tests/check.test.py
"""

from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path

REF = re.compile(r"^(?P<path>[^\s:`<>]*[./][^\s:`<>]*):(?P<start>\d+)(?:-(?P<end>\d+))?$")
SPAN = re.compile(r"(`+)(.+?)\1")
HTML_CODE = re.compile(r"<code[^>]*>(.*?)</code>", re.S | re.I)
FENCE = re.compile(r"^\s*(```|~~~)")
UNCONFIRMED = re.compile(r"^##\s+Неподтверждённое\s*$")


def markdown_spans(text: str):
    """(line number, code span) outside fenced blocks."""
    fenced = False
    for number, line in enumerate(text.splitlines(), 1):
        if FENCE.match(line):
            fenced = not fenced
            continue
        if not fenced:
            for match in SPAN.finditer(line):
                yield number, match.group(2).strip()


def html_spans(text: str):
    for match in HTML_CODE.finditer(text):
        number = text.count("\n", 0, match.start()) + 1
        yield number, html.unescape(re.sub(r"<[^>]+>", "", match.group(1))).strip()


def unconfirmed(text: str) -> list[str] | None:
    """Пункты раздела `## Неподтверждённое`; None — раздела нет."""
    items: list[str] | None = None
    fenced = False
    for line in text.splitlines():
        if FENCE.match(line):
            fenced = not fenced
        if fenced:
            continue
        if UNCONFIRMED.match(line):
            items = []
        elif items is not None and re.match(r"^#{1,2}\s", line):
            break
        elif items is not None and re.match(r"^\s*[-*]\s+\S", line):
            item = re.sub(r"^\s*[-*]\s+", "", line).strip()
            if item.rstrip(".").lower() not in ("нет", "none"):
                items.append(item)
    return items


def broken(root: Path, ref: str) -> str | None:
    """Почему ссылка битая; None — цела. ref уже совпал с REF."""
    match = REF.match(ref)
    rel = match.group("path")
    start = int(match.group("start"))
    end = int(match.group("end") or start)
    if rel.startswith("/") or ".." in Path(rel).parts:
        return "путь вне --root"
    target = (root / rel).resolve()
    if not target.is_relative_to(root):
        return "путь выходит из --root"
    if not target.is_file():
        return "файла нет"
    lines = len(target.read_text(errors="replace").splitlines())
    if start < 1 or end < start:
        return "неверный номер строки"
    if end > lines:
        return f"в файле {lines} строк"
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path.cwd(),
                        help="каталог, от которого считаются пути ссылок (обычно worktrees/<task>)")
    parser.add_argument("document", type=Path, help="каталог <knowledge-root>/architecture/<name>/")
    args = parser.parse_args()

    root = args.root.resolve()
    doc = args.document
    if not root.is_dir() or not doc.is_dir():
        print(f"architecture-map: нет каталога {root if not root.is_dir() else doc}", file=sys.stderr)
        return 2

    readme = doc / "README.md"
    failures: list[str] = []
    if not readme.is_file():
        print(f"FAIL {readme}: нет README.md", file=sys.stderr)
        return 1

    files = [readme, *sorted(doc.glob("*.html"))]
    checked = 0
    for path in files:
        text = path.read_text(errors="replace")
        spans = html_spans(text) if path.suffix == ".html" else markdown_spans(text)
        for number, span in spans:
            if not REF.match(span):
                continue
            checked += 1
            reason = broken(root, span)
            if reason:
                failures.append(f"BROKEN {path.name}:{number}: `{span}` — {reason}")

    items = unconfirmed(readme.read_text(errors="replace"))
    if items is None:
        failures.append("FAIL README.md: нет раздела `## Неподтверждённое` (пустой — пункт «нет»)")

    print(f"architecture-map: {checked} ссылок path:line, битых {sum(f.startswith('BROKEN') for f in failures)}")
    print(f"Неподтверждённое ({len(items or [])}):")
    for item in items or []:
        print(f"  - {item}")
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
