---
name: spec-trace
description: Связать OpenSpec change с локальными ветками, коммитами и уже записанными PR через trace.sh и spec-ref.sh. Использовать после code-коммитов и перед коммитом spec repo.
---

# Spec trace из локального состояния

Skill строит воспроизводимую связь между OpenSpec change и реализацией из
локального git плюс `.coordination/`. Он не запрашивает GitHub.

После коммитов code repos и до коммита spec repo:

```bash
.claude/skills/spec-trace/trace.sh --task <task>
```

При нескольких change укажите `--change <name>`. Файл
`implementation.md` регенерируется целиком; не редактируйте его вручную.
`--print` выводит результат без записи.

`spec-ref.sh --worktree <checkout>` разрешает spec repo, ветку и change.
`--block` печатает блок для нового PR, `--markdown` — человекочитаемый
указатель.

Store спек в задаче может быть не один. Назовите субъект изменения
`SPEC_SUBJECT_REPO=<repo>`: без него скрипты отказывают кодом 2 и печатают
кандидатов в stderr. Это защищает от записи в случайный `always`-checkout.
Код 1 означает, что store в задаче нет вовсе.

PR URL берётся только из coordination record, который пишет
`commit-and-mr`. Если URL там отсутствует, trace честно оставляет поле пустым.
Описания PR связывает `commit-and-mr/task-link.sh`; отдельного двустороннего
API-инструмента `spec-link.sh` нет.
