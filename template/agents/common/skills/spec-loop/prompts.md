# Dispatch prompts — the spec loop

Fill the placeholders and pass the result as the `Agent` tool's `prompt`. Each
agent's own instructions live in [`../../roles/`](../../roles/) — these
templates carry only what is task-specific.

Placeholders: `{TASK}`, `{CHANGE}`, `{REPOS}`, `{REQUEST}` — the user's request in
their own words, not your paraphrase of it. `{SPEC_REPO}`/`{SPEC_ROOT}` — the
repo and directory named in [SKILL.md](SKILL.md) §0. `{CHECKOUT}`/`{AGENT_PATH}` —
the writing agent's disposable checkout of `{SPEC_REPO}` and its ledger path
(writing dispatches only).

**Never interpolate one agent's report into the other's prompt during the study.**
Afterwards you must: a cross-read is *about* the other's file, and the answers to
the user's questions are the only reason either can write anything. What stays
forbidden is passing a *summary* where the agent could read the file itself.

**Writers do not share the spec worktree.** The study below is read-only and
may read `worktrees/{TASK}/` directly. Every later dispatch that writes
(`proposal.md`, delta specs, design, tasks, coverage edits) is a write-capable
child: first `writer.py spawn` it a disposable checkout of `{SPEC_REPO}` scoped to
`{SPEC_ROOT}/openspec/changes/{CHANGE}/` (see `agent-directed-routing`) and put
that checkout into the prompt as `{CHECKOUT}` together with the agent's
`agentPath`. The templates below already use `{CHECKOUT}` literally; the agent
writes only there and refuses to write if none is named. Then you `submit` and
`integrate` the patch before the next artefact is cross-read or closed. A
resumed agent is told its new checkout.

This loop owns the spec-first change's steps through the complete bundle. Do
not create or request builder work or wave assignments from these prompts;
build-loop starts only after the complete bundle is recorded in the ledger.

---

## Study — `analyst` and `architect`, dispatched together

Two `Agent` calls in one message. Read-only; nothing is written in this step.

```text
subagent_type: analyst        # and, in the same message: architect
minimum tier/effort: strong/high for each role (see agent-directed-routing)
```

### analyst

```text
Шаг 1 спек-цикла — изучение. Ничего не пишем: ни артефактов, ни кода.
Не создавай builder cards/processes и не планируй wave assignment как действие:
до завершения пакета спеки они существуют только как будущий план в tasks.md.

Запрос пользователя, дословно:
{REQUEST}

Worktree: worktrees/{TASK}/
Repos in this task: {REPOS}
Spec repo: worktrees/{TASK}/{SPEC_REPO}, openspec в {SPEC_ROOT}/openspec
(specRoot необязателен: пустой {SPEC_ROOT} значит openspec/ лежит в корне репозитория);
это store субъекта изменения, а не единственный store воркспейса — других не трогай;
change `{CHANGE}` уже создан

Разберись, что происходит СЕГОДНЯ, и что из запроса ещё не определено:

1. код в worktrees/{TASK}/<repo>/ — как флоу работает сейчас, path:line;
2. существующие спеки (через `.claude/skills/openspec-read/`, если он есть в
   этом репозитории, иначе через `openspec show`/`openspec list` напрямую) —
   есть ли уже требование, которое этот запрос меняет (тогда это MODIFIED, а
   не новое);
3. **живые данные, если в этом воркспейсе есть скилл для read-only запросов к
   продуктовой БД** — сколько строк реально выглядят как краевой случай,
   действительно ли колонка nullable, что видно сейчас. Только чтение. Такого
   скилла нет — скажи об этом прямо, не проектируй по предполагаемым данным;
4. что уже в полёте — через GitHub UI (API skill, если он доступен, иначе
   `commit-and-mr`'ные средства чтения), открытые PR по тому же флоу.

Отдай: СЕГОДНЯ, кандидаты в требования, ВОПРОСЫ (сначала блокирующие — модель
данных, судьба существующих строк или денег в полёте; к каждому неблокирующему —
дефолт, который ты предлагаешь, и почему), ДОПУЩЕНИЯ, НЕ ВЫЯСНИЛ.

Вопросы задаёт пользователю оркестратор, и только блокирующие — ты с ним не
разговариваешь. Не выбирай ответ на блокирующий вопрос за него: он остаётся
вопросом.
```

### architect

```text
Шаг 1 спек-цикла — изучение. Ничего не пишем: ни артефактов, ни кода.
Не создавай builder cards/processes и не планируй wave assignment как действие:
до завершения пакета спеки они существуют только как будущий план в tasks.md.

Запрос пользователя, дословно:
{REQUEST}

Worktree: worktrees/{TASK}/
Repos in this task: {REPOS}
Spec repo: worktrees/{TASK}/{SPEC_REPO}, openspec в {SPEC_ROOT}/openspec
(specRoot необязателен: пустой {SPEC_ROOT} значит openspec/ лежит в корне репозитория);
это store субъекта изменения, а не единственный store воркспейса — других не трогай;
change `{CHANGE}` уже создан

Твоя половина — как это строится и как выкатывается:

1. границы и репозитории: кто чем владеет, что ходит между ними, задет ли
   опубликованный контракт — библиотека или SDK, которую публикует один
   репозиторий этого воркспейса и потребляют другие (проверь repos.json и их
   package-манифесты, если сомневаешься, какой репозиторий что публикует);
2. **схема как она есть, если в воркспейсе есть скилл для read-only запросов к
   БД** — колонки, nullability, индексы, количество строк, от которого
   зависит, миграция это или простой. Такого скилла нет — скажи об этом прямо;
3. что уже в полёте — через GitHub;
4. существующие спеки (через `.claude/skills/openspec-read/`, если есть, иначе
   `openspec show`/`openspec list`), чтобы дизайн дополнял, а не противоречил.

Отдай: КАРТИНА, варианты решения с ценой каждого, ВОЛНЫ (предварительно),
РЕЛИЗ (предварительно, если репозиториев больше одного), ВОПРОСЫ (сначала
блокирующие; к каждому неблокирующему — предлагаемый дефолт),
ДОПУЩЕНИЯ / НЕ ВЫЯСНИЛ.

Вопросы задаёт пользователю оркестратор. Открытый выбор дизайна — это вопрос к
нему, а не твоё решение: два защитимых варианта с разной моделью данных
описываются оба, с ценой.
```

---

## `analyst` — proposal.md

Resume the study agent with `SendMessage`; it holds what it read.

```text
Ответы пользователя на блокирующие вопросы, дословно (не было — «нет»):

1. <вопрос> → <ответ>
2. <…>

Неблокирующие вопросы закрыты допущениями — запиши каждое строкой в артефакте:

1. <вопрос> → <допущение и на чём оно основано>

Твой checkout: {CHECKOUT}, agentPath: {AGENT_PATH}. Пиши только в нём; если
checkout не назван — ничего не пиши и сообщи об этом. Перед записью спорного пути:
ownership.py check-write --agent-path {AGENT_PATH} <path>.

Теперь напиши только `proposal.md` для change `{CHANGE}` в
{CHECKOUT}/{SPEC_ROOT}/openspec/changes/{CHANGE}/. Ни delta-спек, ни design, ни tasks —
они следующими шагами этого же захода, они пишутся одним пакетом, без отдельных
остановок на согласование.

cd {CHECKOUT}/{SPEC_ROOT}
openspec instructions proposal --change {CHANGE} --json
openspec validate

Инструкции и openspec/config.yaml важнее твоих привычек, включая язык
артефактов, если он там задан.
Обязательно назови, что ВНЕ объёма — безграничный proposal превращается в волну,
которую некому отревьюить.

Допущение, которое пришлось сделать, пиши строкой в самом артефакте.
```

---

## `analyst` — the delta specs

```text
Твой checkout: {CHECKOUT}, agentPath: {AGENT_PATH}. Пиши только в нём; если
checkout не назван — ничего не пиши и сообщи об этом. Перед записью спорного пути:
ownership.py check-write --agent-path {AGENT_PATH} <path>.

`proposal.md` написан (cross-read пройден; пакет уйдёт в build-loop без показа пользователю). Теперь delta-спеки change
`{CHANGE}` — и только они.

cd {CHECKOUT}/{SPEC_ROOT}
openspec instructions specs --change {CHANGE} --json
openspec validate

Формат `### Requirement:` / `#### Scenario:`. Три правила:
- требование описывает поведение, а не реализацию;
- у каждого требования есть сценарий, который может покраснеть. Не можешь
  написать отказной случай — требование ещё не определено, скажи это;
- MODIFIED дополняет specs/<capability>/spec.md, а не заменяет требование
  целиком: прочитай текущий текст (через `openspec-read`, если он есть в этом
  репозитории, иначе `openspec show <capability> --type spec`) и меняй только
  то, что этот запрос действительно двигает.
```

---

## `architect` — the feasibility pass

Read-only. Findings, not edits.

```text
Delta-спеки change `{CHANGE}` написаны аналитиком:
worktrees/{TASK}/{SPEC_REPO}/{SPEC_ROOT}/openspec/changes/{CHANGE}/specs/

Прочитай их против кода и схемы и ответь на один вопрос: это можно построить
как написано, и чего это стоит? Ищи —
- требование, которое нельзя выполнить из данных, доступных в этой точке флоу;
- требование, противоречащее опубликованному контракту или ломающее его;
- требование, для которого нужна разрушительная миграция или backfill
  существующих строк, — это проблема порядка релиза, и она должна быть видна
  сейчас, а не на пятой волне;
- требование, реализуемое только переносом границы, которую никто не просил
  двигать;
- два требования, которые не могут выполняться одновременно.

Находки, а не правки: файл, требование, что именно мешает, и самая дешёвая
альтернатива, которую ты видишь. Требования не твои — не переписывай их под свой
дизайн. Решает пользователь.
```

---

## `architect` — design.md and tasks.md

Resume the study agent with `SendMessage`.

```text
Твой checkout: {CHECKOUT}, agentPath: {AGENT_PATH}. Пиши только в нём; если
checkout не назван — ничего не пиши и сообщи об этом. Перед записью спорного пути:
ownership.py check-write --agent-path {AGENT_PATH} <path>.

Delta-спеки написаны и прошли feasibility pass (cross-read пройден; пакет уйдёт в build-loop без показа пользователю).
Теперь `design.md` и `tasks.md` change `{CHANGE}` — и только они.

Требования, по которым строишь design:
{CHECKOUT}/{SPEC_ROOT}/openspec/changes/{CHANGE}/specs/

cd {CHECKOUT}/{SPEC_ROOT}
openspec instructions design --change {CHANGE} --json
openspec instructions tasks --change {CHANGE} --json
openspec validate

`design.md`: по каждому решению — отклонённая альтернатива и почему. Дизайн,
в котором только выбор, нельзя отревьюить.

`tasks.md` открывается таблицей `## Параллелизм`: группа, репозиторий, пути,
зависимости, волна. По ней build loop диспатчит по одному билдеру на группу, и
группы волны работают одновременно — поэтому один репозиторий не встречается в
волне дважды, а пути групп волны не пересекаются. Глобы разреши командой
(`git -C worktrees/{TASK}/<repo> ls-files '<glob>'`), а не на глаз: общий
package.json, лок, каталог миграций, DI-реестр, экспортный index, конфиг тестов
или другой общий файл сборки — это пересечение. Сомневаешься в независимости —
в следующую волну, но напиши в таблице, ЧТО именно является зависимостью: build
loop перепроверяет эту таблицу по готовому коду в обе стороны и поднимает
группу, чью зависимость не находит.

Пункты пиши для билдера, который идёт на слабой модели: пункт самодостаточен —
поля, статусы, значения и имена прямо в нём, без ссылок «§D6 design.md», «как в
предыдущей группе», «см. дизайн». Секция каждой группы открывается строкой
`**Образец:**` с одним-двумя путями существующих файлов того же репозитория, по
которым выравниваются конвенции; нечему подражать — `**Образец:** нет, новый
слой`. Build loop проверяет обе вещи перед диспатчем и группу без них на слабой
модели не запускает.

Если у двух групп есть общий, разделяемый интеграционными тестами ресурс
(например, один и тот же docker-compose стек с фиксированными портами) — их
интеграционные тесты всё равно встанут в очередь друг за другом в фазе тестов,
даже если пути групп не пересекаются; учти это при распределении по волнам, но
не обязывай их в одну волну ради параллелизма кода.

Репозиториев больше одного → сразу за ней таблица `## Порядок релиза`: порядок
выхода в прод, чего ждёт каждый шаг и почему он безопасен до следующих.
Направление по умолчанию: контракты и библиотеки (опубликованы и подняты у
потребителей) → миграции → бэкенды → клиенты, зависящие от бэкенда → любой
магазин-приложений/стор-релиз последним. Каждый шаг безопасен сам по себе; если
между N и N+1 прод сломан, это несовместимый контракт — разбей на аддитивное
изменение сейчас и удаление позже. Отметь необратимые шаги: опубликованная
версия пакета, применённая миграция, релиз в стор.
```

---

## `analyst` — the coverage pass

Read-only. Findings, not edits.

```text
`design.md` и `tasks.md` change `{CHANGE}` написаны архитектором:
worktrees/{TASK}/{SPEC_REPO}/{SPEC_ROOT}/openspec/changes/{CHANGE}/

Прочитай их против своих требований: доставляет ли этот дизайн каждое
требование и не противоречит ли какому-нибудь? Ищи —
- требование, под которое нет задачи, которая бы его произвела;
- задачу, меняющую поведение, которого не требует ни одно требование;
- решение, делающее сценарий невозможным или незаметно меняющее то, что видит
  пользователь при отказе;
- требование, чей сценарий ничто в tasks.md не смогло бы выполнить.

Находки, а не правки: файл, требование, конфликт — по строке. Файлы
архитектора не трогай.
```
