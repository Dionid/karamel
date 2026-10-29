# Личная база владельца для задач и PR

Репозиторий в `repos.json` может получить необязательный флаг
`"personalBase": true`. Если владелец воркспейса задан
(`git config workspace.owner <prefix>` в корне; `WORKSPACE_OWNER` в окружении
переопределяет, пустая `WORKSPACE_OWNER=` отключает), задачи такого
репозитория ветвятся от `<owner>-<base>` (например, `ds-main`), а
`commit-and-mr` открывает PR туда же. `wt new` один раз создаёт личную базу на
origin из `origin/<base>` обычным push, `wt cleanup` считает задачу влитой в
`<base>` или в личную базу. Ответ даёт один resolver `resolve_task_base` в
`commit-and-mr/lib.sh` для `wt`, `adopt.sh`, `run.sh`, `preflight.sh`,
`task-link.sh` и `spec-trace`; `./ops check` отвергает не-boolean
`personalBase`. Вливание личной базы в `<base>` — PR человека. Без флага или
без владельца поведение прежнее. Обновление — `./ops upgrade` и `./ops sync`.
