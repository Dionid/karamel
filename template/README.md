# Engineering workspace

Здесь хранятся правила, скиллы и настройки, которые задают повседневную работу
агента.

## Возможности harness

Harness задаёт рабочий процесс от запроса до проверенного изменения: где агент
читает источники, как выбирает исполнителя, в каком checkout пишет и какие
проверки нужны перед результатом. Семь возможностей помогают применять один
подход к разным задачам — от вопроса о коде до реализации по готовой спеке.
Конкретные команды и ограничения описаны в связанных скиллах.

### Paralleling — параллельная работа в изолированных worktree

Каждая задача получает собственные ветки и checkout репозиториев через
[`wt`](agents/common/skills/wt/SKILL.md). Это позволяет одновременно вести
несколько задач, не смешивая изменения и состояние рабочих каталогов.
Исполнители с правом записи дополнительно получают одноразовые checkout
с выделенными областями файлов; parent проверяет и интегрирует их patch.
Параллелизм учитывает зависимости: независимую работу можно выполнять вместе,
а связанные шаги проходят в заданном порядке.

### Coordination — владение и передача состояния

[`coordination`](agents/common/skills/coordination/SKILL.md) хранит локальные
записи о владельце задачи, heartbeat и checkpoint для продолжения работы.
Перед правками агент проверяет состояние и заявляет владение; пересечения
требуют согласования областей. При завершении остаётся handoff с исходом
и следующим шагом. Устаревший heartbeat сам по себе не доказывает, что другой
агент прекратил работу.

### Tracks X — выбор процесса по запросу

[Правила треков](AGENTS.md#классификация) различают вопросы о коде, продуктовых
обещаниях и внешних системах, изменения продукта, агентского слоя
и инфраструктуры. Классификация выбирает подходящий процесс, роль исполнителя
и необходимость спеки. Изменение с открытым дизайном или новым продуктовым
потоком проходит согласование scope с пользователем, затем пишется спека,
и реализация начинается без отдельного одобрения пакета.

### Subagents — роль, модель и effort под подзадачу

[`agent-directed-routing`](agents/common/skills/agent-directed-routing/SKILL.md)
задаёт выбор роли, модели и уровня reasoning effort по характеру работы
и каталогу маршрутизации. Parent передаёт ограниченную задачу, источники
и область записи, затем проверяет результат. Разделение помогает поручать
исследование, реализацию и независимое ревью подходящим исполнителям,
сохраняя ответственность за итог у root.

### Build loop — реализация change по готовой спеке

[`build-loop`](agents/common/skills/build-loop/SKILL.md) начинается автоматически
после готового пакета спеки OpenSpec change. Работа идёт волнами: реализация и ревью,
затем тесты и их ревью. Раунды исправлений ограничены; нерешённые вопросы
выносятся пользователю. Ledger сохраняет этапы и решения, чтобы продолжать
задачу после перерыва.

### Shared knowledge

[`knowledge`](agents/common/skills/knowledge/SKILL.md) and
[`spec`](agents/common/skills/spec/SKILL.md) resolve storage from `repos.json`.
Configure the repositories before saving team knowledge or product specifications.
No repository is selected by default.

### self-update — обновление агентского слоя

[`self-update`](agents/common/skills/self-update/SKILL.md) подтягивает свежий
агентский слой, пересобирает `.claude/`, `.agents/` и `.codex/`, затем проверяет
результат. Обновление останавливается при ошибке на любом шаге: актуальные
правила и сгенерированные настройки должны оставаться согласованными.

## Что здесь лежит

- **`AGENTS.md`** — доменные правила агента: треки A/P/E/B/H/I/C, права на чтение и PR
  по репозиториям, работа со спеками, доступы к внешним системам (GitHub, БД,
  Kubernetes, Notion и т.д.).
- **`agents/`** — сам агентский слой. `agents/common/skills/` — скиллы команды
  (build-loop, spec-trace, commit-and-mr, db-query и другие), которые собираются
  и в `.claude/`, и в `.agents/`; `agents/common/roles/` — роли трека C
  (analyst, architect, builder, reviewer) для Claude Code и Codex;
  `agents/claude/` и `agents/codex/` — рантайм-специфичные настройки поверх
  core.

Knowledge storage is configured through `repos.json`; see [PACKAGES.md](PACKAGES.md).

## Остальные файлы

| Путь | Что |
| --- | --- |
| `repos.json` | каталог репозиториев; по умолчанию пуст |
| `PACKAGES.md` | за что отвечает каждый репозиторий |
| `.github/workflows/lint.yml` | единственный гейт: `lint.sh --require-tools` над агентским слоем |
| `.env.example` | `GITHUB_TOKEN`, опционально `NOTION_TOKEN` и строки подключения к БД |
| `agents/claude/settings.json` | добавка к core: deny `Edit(/knowledge/**)` и Stop-хук защиты секретов |
| `agents/claude/file-suggestion.sh` | `@`-подсказки по `packages/` и `worktrees/` вопреки `.gitignore` |
| `agents/codex/config.base.toml` | Codex-конфиг слоя: subagents + secret-read hook |

## Как изменяются знания

Настройте `knowledgeRoot`, `specRoot` и `always` в `repos.json`.
Авторские записи создаются в task-worktree; `packages/` остаётся для чтения.
Для Notion-зеркала отдельно задайте `notionSnapshotRepo`.

## Операторский CLI

Все операции настройки workspace, работы с репозиториями и проверки harness
собраны в одном исполняемом entrypoint:

```bash
npm run ops -- help
npm run ops -- help wt
npm run ops -- status --json
npm run ops -- wt new <task> --repo <repo> --pull
npm run ops -- lint strict
```

`npm run ops -- …` и прямой `./ops …` вызывают один и тот же CLI.

Полный каталог и таблица перехода со старых Make-команд находятся в
[`docs/operator-cli.md`](docs/operator-cli.md).

## Ключевые скиллы

| Скилл | О чём |
| --- | --- |
| `build-loop` | трек C: волны билдеров, барьер ревью, ограниченные раунды исправлений |
| `knowledge` | кто, когда и в какую категорию `<knowledge-root>/` пишет через task-worktree |
| `spec` | точная маршрутизация OpenSpec-артефактов в spec-root задачи |
| `openspec-read` | чтение текущих OpenSpec specs/changes без grep по markdown |
| `spec-trace` | связь спеки и кода из git + coordination: `trace.sh`, `spec-ref.sh` |
| `commit-and-mr` | commit, HTTPS push через gh и Draft PR |
| `db-query` | read-only SQL по настроенным базам данных, dev и prod |
| `standalone-setup` | пересобрать `.claude/`/`.agents/`/`.codex/` из одного слоя — для голого клона этого репозитория |
| `ci` | CI-скрипты проверки спек для `.github/workflows/lint.yml` этого репозитория |
