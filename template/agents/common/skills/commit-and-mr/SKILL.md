---
name: commit-and-mr
description: Закрыть готовую работу, закоммитить, запушить или создать либо обновить Draft GitHub PR.
---

# Commit and Draft GitHub PR

Закрывайте готовую работу из `worktrees/<task>/<repo>/` через HTTPS и gh.

Единственный credential — `GITHUB_TOKEN` из окружения или корневого `.env`.
Значение процесса, включая пустое, имеет приоритет. Общая библиотека читает
выбранные `.env` assignments как данные, без исполнения команд; `GH_TOKEN`
каждого вызова зеркалит `GITHUB_TOKEN`. Токен не выводится и не сохраняется.
Поддерживается `github.com`. Установите gh и проверьте токен через
[`github-login`](../github-login/SKILL.md), если вывод содержит `NEXT=github-login`.

## Перед запуском

1. Прочитайте `git status --short`, `git diff --stat` и diff.
2. Запустите проверки репозитория и независимое closing review.
3. Если подключён skill **`work-items`**, обновите запись задачи
   (`tasks/<task>.md`); URL PR добавьте после создания так, как велит этот
   skill (например, `work_items.py set <task> prs+=<url>`).
4. Проверьте необходимость changelog через подключённый skill **`changelog`**.
   Если он не настроен, укажите это в секции `## Changelog` описания.
5. Подготовьте commit message и полное описание по
   [`mr-description/template.md`](../mr-description/template.md).
6. Запустите preflight и проверку описания:

```bash
.claude/skills/commit-and-mr/preflight.sh --worktree worktrees/<task>/<repo> --repo <repo>
.claude/skills/mr-description/describe.sh check --file /tmp/pr-description.md
```

Провал preflight требует исправить identity, origin, токен или сеть до коммита.
Preflight проверяет dry-run push; окончательное разрешение решает настоящий push.
Не коммитьте `.env`, чужие изменения и build artefacts. Не обходите hooks.
Merge, approve, снятие Draft и force-push требуют отдельной просьбы.

## Запуск

```bash
.claude/skills/commit-and-mr/run.sh \
  --worktree worktrees/<task>/<repo> --repo <repo> \
  --message-file /tmp/commit-message.txt \
  --mr-description-file /tmp/pr-description.md -- path/to/file
```

Создание всегда передаёт `gh pr create --draft`: Draft является состоянием PR,
даже когда заголовок уже начинается с `Draft:`. Проверка доступа идёт до staging;
credentials из `.env` загружаются в основной процесс только после commit,
чтобы не передавать их commit hooks.

`--existing-mr` пушит в существующий PR той же ветки. С описанием заменяет body;
без описания сохраняет его. `--existing-mr --mr-description-file <file>
--description-only` меняет только описание без staging, commit и push.
`--no-mr` делает commit и push и печатает `PREFILL_URL` формы сравнения веток.
Имена MR-флагов и полей отчёта сохранены для совместимости локальных скриптов.

При ошибке или некорректном JSON списка PR создание останавливается с
`MR_STATE=unconfirmed`: существование PR нельзя угадать. Новый PR без полного
проверенного описания не создаётся. Успех подтверждают `COMMIT_SHA` и
подтверждённый `MR_URL=https://github.com/<owner>/<repo>/pull/<number>`.
Полный контракт: [run-sh.md](run-sh.md), [preflight.md](preflight.md).

## Связи задачи

Управляемые блоки spec-link и task-link добавляются к проверенному body.
`task-link.sh --update` обновляет связи во всех открытых PR задачи. Ошибка
обновления связей — предупреждение с командой повтора; передайте его в отчёт.
Из прочитанного body управляемые блоки удаляются перед повторной проверкой.
Подробнее: [task-link.md](task-link.md).

Если активен **spec-trace**, commit получает `Spec:` trailer и блок спеки.
После code repos запускайте trace, затем коммитьте spec repo. Coordination
записывает SHA, ветку и подтверждённый PR. В отчёте называйте commit SHA,
ветку, URL PR, проверки и оставшиеся предупреждения.
