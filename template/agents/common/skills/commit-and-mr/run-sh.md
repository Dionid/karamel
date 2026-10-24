# run.sh contract

Используйте `run.sh --help` для полного списка флагов. Каталог skill и MR-флаги
сохранены для совместимости; удалённые объекты — GitHub pull requests.

- Новый PR: `--message-file`, `--mr-description-file`, пути после `--`.
- Существующий PR: `--existing-mr`, необязательное описание.
- Только body: `--existing-mr --mr-description-file --description-only`.
- Только commit/push: `--no-mr`.
- Транспорт: `--transport auto|https`, оба значения означают HTTPS.

Проверка body, origin, токена и совпадения fetch/push repository проходит до
staging. Commit hooks сохраняются. Запросы gh получают GITHUB_TOKEN через
зеркальный GH_TOKEN, prompts отключены. Создание всегда использует `--draft`.
Описание передаётся через временный файл, удаляемый после вызова.

Вывод содержит `COMMIT_SHA`, `COMMIT_SUBJECT`, `BRANCH`, `TARGET_BRANCH`,
`MR_STATE`, `MR_URL`, `TRANSPORT`, `MR_TRANSPORT`, `SPEC_STATE`,
`SPEC_CHANGE` и `SPEC_MR_URL`. Транспорт: `https-gh`, `local` или `none`.

`MR_STATE=created|existing` с подтверждённым GitHub `/pull/<number>` URL
подтверждает PR. `not-created` означает отсутствие созданного PR,
`unconfirmed` — сбой lookup, `create-failed` — неудавшееся создание.
`PREFILL_URL` — только форма сравнения веток, не PR. Пустой токен останавливает
run с exit 3 и `NEXT=github-login`; ошибки доступа/сети дают ненулевой exit.
Описание без открытого PR в режиме `--description-only` даёт exit 1.

Coordination получает handoff только для подтверждённых PR после push.
Неуспешный refresh task-link печатает предупреждение и команду повтора.
