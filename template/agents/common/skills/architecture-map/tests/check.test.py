#!/usr/bin/env python3
"""Поведение check.py: целые ссылки path:line проходят, битые (нет файла,
строка за концом, выход из --root) дают exit 1 с адресом, раздел
«Неподтверждённое» обязателен и печатается отдельным списком, fenced-блоки и
не-ссылки не проверяются, ссылки в .html тоже проверяются."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "check.py"
fails = 0


def check(name: str, ok: bool, detail: str = "") -> None:
    global fails
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + ("" if ok else f"\n        {detail}"))
    fails += not ok


def world() -> tuple[Path, Path]:
    base = Path(tempfile.mkdtemp(prefix="arch-map-")).resolve()
    root = base / "task"
    (root / "api/src").mkdir(parents=True)
    (root / "api/src/server.ts").write_text("".join(f"line {i}\n" for i in range(1, 11)))
    (root / "api/README.md").write_text("one\ntwo")  # no trailing newline: still 2 lines
    (base / "outside.txt").write_text("x\n" * 50)
    doc = root / "kb/architecture/payments"
    doc.mkdir(parents=True)
    return root, doc


def run(root: Path, doc: Path, readme: str | None, html: str | None = None):
    if readme is not None:
        (doc / "README.md").write_text(readme)
    if html is not None:
        (doc / "index.html").write_text(html)
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
    proc = subprocess.run([sys.executable, str(SCRIPT), "--root", str(root), str(doc)],
                          capture_output=True, text=True, env=env)
    return proc.returncode, proc.stdout, proc.stderr


GOOD = """# Платежи

Срез: 2026-10-29, api@abc1234.

- Вход HTTP поднимается в `api/src/server.ts:3` (диапазон `api/src/server.ts:1-10`).
- Описание сервиса — `api/README.md:2`.
- Хост `localhost:8080` и команда `rg -n listen api` — не ссылки на файл.

```text
`api/src/missing.ts:1` внутри fenced-блока — пример, не проверяется
```

## Неподтверждённое

- Очередь ретраев живёт в отдельном воркере (?) — не нашёл код.
- Таймаут 30 с задан в Helm values — нет доступа к чарту.
"""


def main() -> int:
    if not SCRIPT.is_file() or not os.access(SCRIPT, os.X_OK):
        print(f"  FAIL  {SCRIPT} отсутствует или не исполняемый")
        return 1

    root, doc = world()
    try:
        code, out, err = run(root, doc, GOOD)
        check("целые ссылки, fenced-блок и не-ссылки — exit 0", code == 0, err)
        check("считает только реальные ссылки (3)", "3 ссылок path:line, битых 0" in out, out)
        check("неподтверждённое — отдельным списком из 2 пунктов",
              "Неподтверждённое (2):" in out and "  - Очередь ретраев" in out and "  - Таймаут 30 с" in out, out)

        for name, ref, reason in (("нет файла", "api/src/gone.ts:1", "файла нет"),
                                  ("строка за концом", "api/src/server.ts:11", "в файле 10 строк"),
                                  ("конец диапазона за концом", "api/src/server.ts:9-12", "в файле 10 строк"),
                                  ("строка 0", "api/src/server.ts:0", "неверный номер строки"),
                                  ("выход через ..", "../outside.txt:1", "путь вне --root"),
                                  ("абсолютный путь", f"{root.parent}/outside.txt:1", "путь вне --root")):
            code, out, err = run(root, doc, GOOD.replace("`api/README.md:2`", f"`{ref}`"))
            check(f"{name} — exit 1 с адресом и причиной",
                  code == 1 and f"README.md:6: `{ref}`" in err and reason in err, f"{code} {err}")

        link = root / "api/link.txt"
        link.symlink_to(root.parent / "outside.txt")
        code, _, err = run(root, doc, GOOD.replace("`api/README.md:2`", "`api/link.txt:1`"))
        check("симлинк наружу — exit 1", code == 1 and "выходит из --root" in err, err)

        code, out, err = run(root, doc, GOOD.split("## Неподтверждённое")[0])
        check("нет раздела «Неподтверждённое» — exit 1", code == 1 and "Неподтверждённое" in err, err)

        code, out, err = run(root, doc, GOOD.split("## Неподтверждённое")[0] + "## Неподтверждённое\n\n- нет\n")
        check("раздел с пунктом «нет» — exit 0 и пустой список", code == 0 and "Неподтверждённое (0):" in out, err)

        code, out, err = run(root, doc, GOOD + "\n## Дальше\n\n- `api/src/server.ts:2` вне раздела\n")
        check("следующий раздел закрывает список неподтверждённого",
              code == 0 and "Неподтверждённое (2):" in out and "вне раздела" not in out, out)

        code, out, err = run(root, doc, GOOD, html="<p><code>api/src/server.ts:99</code></p>\n")
        check("битая ссылка в .html — exit 1", code == 1 and "index.html:1: `api/src/server.ts:99`" in err, err)
        (doc / "index.html").unlink()

        (doc / "README.md").unlink()
        code, _, err = run(root, doc, None)
        check("нет README.md — exit 1", code == 1 and "README.md" in err, err)

        code, _, _ = run(root / "nope", doc, GOOD)
        check("нет --root — exit 2", code == 2)
    finally:
        shutil.rmtree(root.parent, ignore_errors=True)

    print(f"\n  {'провалено ' + str(fails) if fails else 'все проверки прошли'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
