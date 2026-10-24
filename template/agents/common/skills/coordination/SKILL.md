---
name: coordination
description: Координировать агентов в общем workspace: владение задачей/worktree, heartbeat, локальные PR handoff-записи, передача состояния и сбор устаревших записей.
---

# Coordination

Runtime state хранится локально в `.coordination/`, игнорируется git и не
содержит prompts, credentials или transcript.

Перед правками:

```bash
.claude/skills/coordination/coord status
.claude/skills/coordination/coord claim <task>
```

Пересечение owners — предупреждение: согласуйте области работы до параллельных
правок одного checkout. Heartbeat, `status <task>` и `doctor` помогают
отличить активную сессию от устаревшей записи.

Перед финальным ответом оставьте handoff:

```bash
.claude/skills/coordination/coord finish <task> \
  --outcome paused --checkpoint "tests pass; review not started"
```

Допустимые outcomes: `mr`, `blocked`, `paused`, `no-changes`,
`abandoned`. `commit-and-mr` вызывает скрытый `record-mr` и сохраняет URL и
target branch PR, которые вернул gh. `release <task>` снимает задачу только с текущей
сессии.

`gc` удаляет только старые terminal coordination records; dry-run является
дефолтом:

```bash
.claude/skills/coordination/coord gc
.claude/skills/coordination/coord gc --older-than 14d --apply
```

Coordination не проверяет GitHub PR state и не удаляет worktrees.
Удалять worktree можно через
`wt rm` только после отдельного человеческого подтверждения, что PR завершён,
и локальной проверки чистоты checkout. Исключение — `wt cleanup`: он удаляет
только чистые задачи без живой lease, чей HEAD уже есть в `origin/<base>`,
так что доказательство даёт сам git, а не догадка о PR; список его
`--dry-run` человек видит до запуска.
