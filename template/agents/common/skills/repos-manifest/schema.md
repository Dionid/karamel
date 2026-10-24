# Справочник repos.json

Это рабочий формат существующих потребителей, а не обещание строгой общей
JSON Schema. JSON не допускает комментариев. Неизвестные ключи обычно
сохраняются, но это не делает их поддерживаемыми. Используйте типы ниже;
не рассчитывайте на одинаковую обработку `null` разными shell/Python readers.

## Верхний уровень

| Поле | Тип и отсутствие | Поведение / потребитель |
| --- | --- | --- |
| `repos` | объект `имя → запись`; задавайте явно | Состав управляемых repos. Ключ определяет `packages/<имя>` и `worktrees/<task>/<имя>`, независимо от URL. |
| `always` | массив имён из `repos`; без поля `[]` | `wt new` добавляет их к каждому набору, `--no-always` отключает; `clone.sh --always` клонирует только их. Также кандидаты для discovery знаний/спек. Неизвестное имя — ошибка. |
| `exclude` | массив имён; без поля `[]` | `clone` без явных имён и `wt manifest` пропускают эти каталоги. Явно названный repo всё ещё клонируется; `always` не отключается этим списком. Можно обозначить внешний каталог, отсутствующий в `repos`. |
| `notionSnapshotRepo` | имя из `repos`, `null` либо отсутствие | Имя выбирает machine-generated зеркало Notion, даже вне `always`; запись должна иметь URL. `null` отключает публикацию даже при env overrides. Отсутствие включает legacy discovery единственного `always` repo с `knowledge/` либо `specRoot` внутри него. Пустая строка и другое неверное явное значение — отказ, без fallback. |

Имена repos — одиночные безопасные имена каталогов, без разделителей, `.` и
`..`; используйте буквы, цифры и дефисы. Наличие записи не означает наличие
checkout. Для авторских знаний требуется ровно один подходящий repo из
`always`; `notionSnapshotRepo` исключён из такого поиска.

## Запись repos.<имя>

| Поле | Тип и отсутствие | Поведение / потребитель |
| --- | --- | --- |
| `url` | непустая строка, обязательна | `clone/ensure-repository`: Git URL без credentials. SCP-style `git@host:path.git` допустим; URL вида `https://user:token@host/...` отвергается. Секреты передаются через штатную авторизацию, не манифест. |
| `branch` | строка; clone/wt при отсутствии/пустой строке — remote default | Clone target и base для `wt new`; разовый `--base` приоритетнее. `wt manifest` сохраняет существующее непустое значение. Для PR `commit-and-mr` при отсутствии/null использует `main`, а пустую строку не заменяет. Поэтому задавайте непустую согласованную ветку явно; не подменяйте её remote default автоматически. |
| `deps` | строка; default `clone-modules` | `wt new`: `clone-modules` (принимается alias `clone`), `install`, `link-modules`, `none`. Разовые флаги имеют приоритет. Неизвестное значение сейчас молча даёт `clone-modules`: считайте его ошибкой конфигурации. `clone --install` — отдельная операция, не чтение этой стратегии. |
| `postClone` | массив Bash-строк; без поля пуст | После приобретения нового основного checkout. Уже существующий checkout пропускает hook. Не применяется как worktree hook. |
| `postSetup` | массив Bash-строк; без поля пуст | `wt new`: после настройки зависимостей в свежем worktree. Ошибка останавливает setup и оставляет worktree для диагностики. |
| `skills` | массив относительных путей каталогов; без поля `[]` | `agents/build.py`: sync линкует их из `packages/<repo>/` в оба runtime skill trees. Имя — basename пути. Абсолютный путь, пустой сегмент, `.`/`..`, пустой путь, symlink наружу или коллизия имён — ошибка check. Нет каталога/`SKILL.md` — warning; sync продолжает. |
| `knowledgeRoot` | непустая относительная POSIX-строка; default `knowledge` | Каталог авторских знаний относительно checkout. `knowledge/resolve.py` проверяет repos из `always`, кроме snapshot repo. Абсолютный путь, `..`, `.`/пустой путь, backslash и realpath наружу запрещены. Явно заданный отсутствующий каталог — ошибка; требуется один кандидат. `--allow-missing` предназначен для lint, не записи. |
| `specRoot` | относительная строка; default `""` | **Родитель** `openspec/`, а не сам `openspec`. `""` означает `<repo>/openspec`. Наличие поля делает repo кандидатом в spec-store даже вне `always`; без поля кандидатом остаётся repo из `always`. Несколько stores выбираются по субъекту изменения. Абсолютные пути, `..` и realpath наружу отвергаются при routing. |

Каждый hook запускается отдельным `bash -c` с cwd целевого checkout: shell
состояние между строками не сохраняется. Оба entrypoint передают
`ROOT_WORKTREE_PATH` (основной checkout) и `REPO_NAME`. Только `wt` дополнительно
передаёт `WT_DIR` (целевой каталог); `clone.sh` его не задаёт. Для переносимого
`postClone` используйте текущий cwd. Не записывайте
секреты в команды: hooks выводятся в лог. Реальные credentials не читать.

Repo-skills читаются с ветки checkout в `packages/`; правка в task-worktree
не обновляет работающий skill до доставки туда. Необязательные поля опускайте,
если нет назначения; `null` документирован как переключатель только для
`notionSnapshotRepo`.

## Пример нового workspace

Имена и URL иллюстративные; branch и пути нужно согласовать с репозиториями.

```json
{
  "always": ["team-knowledge"],
  "exclude": [],
  "notionSnapshotRepo": null,
  "repos": {
    "api": {
      "url": "https://github.com/team/api.git",
      "branch": "development",
      "deps": "clone-modules",
      "postSetup": ["cd libs/common && npm run build"]
    },
    "team-knowledge": {
      "url": "https://github.com/team/knowledge.git",
      "branch": "main",
      "deps": "none",
      "knowledgeRoot": "projects/pay/knowledge",
      "specRoot": "projects/pay"
    }
  }
}
```

## Где проверить реализацию

- [wt](../wt/wt): `manifest_get`, `base_for`, `resolve_deps`, `run_hooks`,
  `cmd_manifest` — defaults, hooks и слияние из checkout'ов.
- [clone.sh](../clone/clone.sh) и [ensure-repository](../clone/ensure-repository):
  выбор repos, URL и приобретение checkout.
- [build.py](../../../build.py): `repo_skills` — пути, коллизии и предупреждения.
- [knowledge resolver](../knowledge/resolve.py) — знания и проверка путей.
- [spec routing](../spec/SKILL.md) и
  [spec-checkout-lib.sh](../spec-trace/spec-checkout-lib.sh) — stores и пути.
- [notion-snapshot](../notion-snapshot/SKILL.md) — явное назначение зеркала,
  legacy discovery и запрет публикации.
