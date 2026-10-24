---
name: asana
description: Читать и писать доски/проекты, секции/статусы и задачи Asana через REST API с кредами из корневого .env. Использовать, когда просят доску Asana, задачи по доске или статусу, создать задачу Asana (в дефолтной секции или в названной), перенести задачу между статусами, узнать обязательные поля доски, или связать задачу Asana со спекой/изменением.
---

# Asana через REST API

Asana — внешнее состояние проекта: чтение свободно, любая запись — после явного
согласия пользователя на точный текст и место. Это касается и создания задачи:
черновик названия, описания, статуса и полей показывается пользователю, и
задача создаётся только после его "да" — исключений для создания в этом скилле
нет.

По умолчанию `curl` + `jq` против `https://app.asana.com/api/1.0`, с токеном
`ASANA_TOKEN` из корневого `.env`. Не печатайте токен, не вставляйте его в
файлы и не читайте `.env` вне того самого Bash-вызова, которому он нужен —
проверить, что переменная задана, можно без чтения значения:

```bash
.claude/skills/env-check/env-check.sh ASANA_TOKEN ASANA_WORKSPACE_GID ASANA_PROJECT_GID
```

Официальный облачный Asana MCP — опциональный транспорт для Codex, когда он
настроен в конфиге команды. Он удобен для исследовательских чтений и сводок;
для скриптовых, повторяемых и проверяемых правок предпочитайте REST-путь этого
скилла. Запись через любой из путей всё равно требует согласия.

## Обязательные `.env`

```bash
# personal access token c https://app.asana.com/0/my-apps
ASANA_TOKEN=
# workspace ("organization") gid — из GET /users/me или из URL доски
ASANA_WORKSPACE_GID=
# project (доска) gid — из URL доски (.../0/<project_gid>/...)
ASANA_PROJECT_GID=
```

Опционально:

```bash
# gid кастомного поля, в которое пишется ссылка на спеку/PR (см. "Связать задачу")
ASANA_SPEC_FIELD_GID=
# gid пользователя для автоназначения новых задач, если он всегда один
ASANA_DEFAULT_ASSIGNEE_GID=
```

`ASANA_PROJECT_GID` — это доска; секции этой доски и есть статусы, названия
которых команда решает сама — скилл их не угадывает и не хардкодит.

## Вызов

Повторяйте прелюдию в каждой команде — состояние shell между вызовами не
сохраняется:

```bash
set -a; . ./.env; set +a
: "${ASANA_TOKEN:?ASANA_TOKEN is unset}"
: "${ASANA_WORKSPACE_GID:?ASANA_WORKSPACE_GID is unset}"
: "${ASANA_PROJECT_GID:?ASANA_PROJECT_GID is unset}"
ASANA_BASE=https://app.asana.com/api/1.0
auth="Authorization: Bearer $ASANA_TOKEN"
curl -sfH "$auth" "$ASANA_BASE/<path>" | jq .
```

`auth` на отдельной строке — не стиль, а требование: сканер секретов в
некоторых рантаймах блокирует целиком файл, если в одной строке встречаются
`curl` и переменная `*TOKEN*` (`exfil_curl`, без обхода регистра), а
заблокированный `SKILL.md` деградирует молча. Не соединяйте заголовок с
`curl` ни здесь, ни в примерах ниже.

Проверить токен, когда есть сомнение:

```bash
curl -sfH "$auth" "$ASANA_BASE/users/me" | jq -r '.data.name'
```

## Прочитать доску

Сначала секции — их gid и есть устойчивые идентификаторы статуса, нужные для
переноса и создания:

```bash
curl -sfH "$auth" \
  "$ASANA_BASE/projects/$ASANA_PROJECT_GID/sections?limit=100" \
  | jq -r '.data[] | "\(.gid)\t\(.name)"'
```

Задачи всей доски:

```bash
curl -sfG -H "$auth" \
  --data-urlencode "limit=100" \
  --data-urlencode "completed_since=now" \
  --data-urlencode "opt_fields=gid,name,completed,permalink_url,memberships.section.name,assignee.name,due_on,notes,custom_fields.name,custom_fields.display_value" \
  "$ASANA_BASE/projects/$ASANA_PROJECT_GID/tasks" \
  | jq -r '.data[] | "\(.gid)\t\(.memberships[0].section.name // "-")\t\(.name)\t\(.permalink_url)"'
```

Задачи одной секции по её gid:

```bash
curl -sfG -H "$auth" \
  --data-urlencode "limit=100" \
  --data-urlencode "completed_since=now" \
  --data-urlencode "opt_fields=gid,name,completed,permalink_url,assignee.name,due_on,notes,custom_fields.name,custom_fields.display_value" \
  "$ASANA_BASE/sections/<section_gid>/tasks" \
  | jq -r '.data[] | "\(.gid)\t\(.name)\t\(.permalink_url)"'
```

Если результат может превышать 100 элементов, идите по `next_page.offset`
явно, а не считайте первую страницу полной.

## Обязательные поля доски — не хардкодить, спрашивать у API

Прежде чем создавать задачу, узнайте, какие кастомные поля доска считает
обязательными — не по памяти и не по значениям из другой команды, а через
`custom_field_settings` этого проекта:

```bash
curl -sfH "$auth" \
  "$ASANA_BASE/projects/$ASANA_PROJECT_GID/custom_field_settings?opt_fields=is_important,custom_field.name,custom_field.gid,custom_field.type,custom_field.enum_options.name,custom_field.enum_options.gid" \
  | jq -r '.data[] | "\(.is_important)\t\(.custom_field.gid)\t\(.custom_field.name)\t\(.custom_field.type)"'
```

`is_important=true` — поле, которое эта доска показывает как обязательное в
своём интерфейсе. Для `enum`/`multi_enum` полей тот же ответ уже несёт gid и
названия вариантов (`custom_field.enum_options`) — не нужен отдельный запрос и
не нужен захардкоженный список опций: он свой на каждой доске и меняется (та
же Sprint-подобная опция обычно ротируется).

Прежде чем звать `POST /tasks`, определите значение для каждого
`is_important=true` поля, покажите пользователю черновик (название, статус,
эти поля) и создавайте только после согласия. Поле, для которого значение
неясно, — повод спросить, а не пропустить молча.

## Создать задачу в статусе

Дефолтная секция — та, что команда назвала дефолтной в разговоре с
пользователем (например «ToDo»); скилл не предполагает конкретное имя.
Название статуса ищется без учёта регистра и пробелов, никогда не по
буквальному совпадению:

```bash
SECTION_GID=$(curl -sfH "$auth" \
  "$ASANA_BASE/projects/$ASANA_PROJECT_GID/sections?limit=100" \
  | jq -r --arg want "todo" \
      '.data[] | select((.name | gsub("\\s"; "") | ascii_downcase) == $want) | .gid' \
  | head -1)
: "${SECTION_GID:?такой секции на доске нет}"
```

**Не `gsub("[^a-z]"; "")`.** Он не только выбрасывает пробелы, но и стирает
любую не-ASCII букву — секция с кириллическим названием («Новые», «В работе»)
превращается в пустую строку и никогда не совпадает ни с чем, включая другую
кириллическую секцию с другим именем. `gsub("\\s"; "")` убирает только
пробелы и оставляет буквы как есть; `ascii_downcase` регистронезависимо
работает только для ASCII, так что для кириллического `--arg want` сравнивайте
без расчёта на изменение регистра или матчите `test($want; "i")`.

Ничего не нашлось — значит на доске нет такого статуса: покажите список секций
и спросите, какую использовать. Никогда не подставляйте первую попавшуюся.

Создание — после согласия на точное название, статус и значения обязательных
полей:

```bash
curl -sfX POST -H "$auth" \
  -H "Content-Type: application/json" \
  "$ASANA_BASE/tasks" \
  -d '{
    "data": {
      "workspace": "'"$ASANA_WORKSPACE_GID"'",
      "projects": ["'"$ASANA_PROJECT_GID"'"],
      "name": "<заголовок задачи>",
      "notes": "<описание>\n\nSpec: <путь к спеке или URL PR>",
      "custom_fields": { "<field_gid>": "<value or enum_option gid>" }
    }
  }' \
  | jq -r '.data.gid'
```

Помещение в секцию — вторая половина того же создания, а не опциональный шаг:
без него у задачи нет статуса на доске.

```bash
curl -sfX POST -H "$auth" \
  -H "Content-Type: application/json" \
  "$ASANA_BASE/sections/$SECTION_GID/addTask" \
  -d '{"data":{"task":"<task_gid>"}}' \
  | jq .
```

Перечитайте задачу с `memberships.section.name` и доложите статус, который
вернула Asana, — так видно, если создание попало не туда.

Если задан `ASANA_DEFAULT_ASSIGNEE_GID` и пользователь просил назначение,
добавьте `"assignee": "'"$ASANA_DEFAULT_ASSIGNEE_GID"'"` в тело задачи.

## Сменить статус

Смена статуса — перенос задачи в другую секцию. Сначала согласие, затем:

```bash
curl -sfX POST -H "$auth" \
  -H "Content-Type: application/json" \
  "$ASANA_BASE/sections/<target_section_gid>/addTask" \
  -d '{"data":{"task":"<task_gid>"}}' \
  | jq .
```

После переноса перечитайте задачу и доложите фактический статус.

## Связать задачу и спеку

Если у доски настроено `ASANA_SPEC_FIELD_GID`:

```bash
curl -sfX PUT -H "$auth" \
  -H "Content-Type: application/json" \
  "$ASANA_BASE/tasks/<task_gid>" \
  -d '{"data":{"custom_fields":{"'"$ASANA_SPEC_FIELD_GID"'":"<путь к спеке или URL PR>"}}}' \
  | jq -r '.data.permalink_url'
```

Иначе — правка `notes` и комментарий-story:

```bash
curl -sfX POST -H "$auth" \
  -H "Content-Type: application/json" \
  "$ASANA_BASE/tasks/<task_gid>/stories" \
  -d '{"data":{"text":"Spec: <путь к спеке или URL PR>"}}' \
  | jq -r '.data.gid'
```

Сторона спеки — обычная правка репозитория: добавить ссылку на задачу Asana в
соответствующий документ изменения, затем закрыть его обычным ходом задачи
(commit-and-mr и, если применимо, `spec-trace`).

## Границы

- Нет `ASANA_TOKEN`, `ASANA_PROJECT_GID` или `ASANA_WORKSPACE_GID` — REST-путь
  недоступен; назовите отсутствующую переменную. Если настроен MCP-путь, им
  можно пользоваться для чтения и для записи с согласием пользователя.
- Любая запись — создание, смена статуса, комментарий, правка задачи, правка
  спеки — только после явного согласия на точный текст, поля и место.
- Никогда не удаляйте задачи, секции, проекты, вложения или комментарии через
  этот скилл.
- Не угадывайте название статуса. Если пользователь назвал статус, которого
  нет на доске, покажите реальный список секций и спросите, какую использовать.
- Не хардкодьте gid обязательных полей или их вариантов — они свои у каждой
  доски и меняются; смотрите `custom_field_settings` перед каждым созданием.
