# karamel

Генератор агентских воркспейсов по образцу
[bulka](https://github.com/Dionid/bulka): правила `AGENTS.md`, скиллы, роли,
хуки, операторский CLI `ops` и раскладка `packages/` + `worktrees/<task>/`.

## Что внутри

| Путь | Что |
| --- | --- |
| `template/` | общий агентский слой: всё, что попадает в новый воркспейс |
| `skills/new-workspace/` | скилл и скрипт `new-workspace.sh` (`create`, `upgrade`) |
| `.claude-plugin/` | манифест плагина и marketplace для Claude Code |
| `tests/new-workspace.test.sh` | сквозная проверка: create → setup → lint → wt → upgrade |

## Установка

Как плагин Claude Code:

```text
/plugin marketplace add Dionid/karamel
/plugin install karamel@karamel
```

После этого в любой сессии достаточно попросить «создай воркспейс как bulka».

Без плагина — клоном:

```bash
git clone https://github.com/Dionid/karamel ~/karamel
~/karamel/skills/new-workspace/new-workspace.sh --help
```

## Создать воркспейс

```bash
new-workspace.sh create ~/work/acme --team Acme \
  --knowledge acme-knowledge=https://github.com/acme/knowledge \
  --repo api=https://github.com/acme/api@develop \
  --repo web=https://github.com/acme/web
```

Скрипт копирует шаблон, пишет `repos.json`, `workspace.json`, `PACKAGES.md`,
делает `git init`, `./ops setup`, `./ops clone` (если задан `GITHUB_TOKEN`) и
`./ops check`. Репозиторий на GitHub для воркспейса создаёте сами.

Требования: `bash`, `git`, `python3`; для `./ops clone` и PR — `GITHUB_TOKEN`
и `gh`; для lint — `shellcheck` и `markdownlint-cli2`.

## Обновить воркспейс

```bash
new-workspace.sh upgrade ~/work/acme --dry-run
new-workspace.sh upgrade ~/work/acme
```

Общий слой перезаписывается из `template/`, удалённые из шаблона файлы в
`agents/` и `docs/` удаляются. Командные файлы (`repos.json`,
`workspace.json`, `PACKAGES.md`, `README.md`, `notion.json`, `CODEOWNERS`,
`IDENTITY.md`, `SOUL.md`, `AGENTS.md`, `.env.example`) не трогаются никогда.

## Откуда шаблон

`template/` снят с `Dionid/bulka@e215f14`, плюс фикс CI из
[bulka#7](https://github.com/Dionid/bulka/pull/7). Командные файлы bulka
(`repos.json`, `PACKAGES.md`, строка в `README.md`) сброшены к пустым.
Общий слой правится здесь, в `template/`, и раздаётся воркспейсам через
`upgrade`.
