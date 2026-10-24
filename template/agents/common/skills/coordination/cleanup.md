# Cleanup без автоматической проверки PR

Активный coordination не определяет PR state и не удаляет worktrees
автоматически. Удаление требует подтверждённого состояния PR и проверки
локального checkout.

Состояние PR подтверждает человек в UI или child одним чтением
`gh pr view <ветка> -R <origin> --json state,body` (поле `state`). После того как
merge/закрытие PR подтверждено:

1. проверьте `coord status <task>` и отсутствие другого активного owner;
2. проверьте `git status --short` каждого checkout;
3. вызовите `.claude/skills/wt/wt rm <task> --repo <repo>`;
4. оставьте terminal handoff и позже очистите старые records через `coord gc`.

`wt rm` не должен применяться на основании догадки о состоянии GitHub.

Без проверки PR можно убрать только то, что доказывает сам git:
`.claude/skills/wt/wt cleanup --dry-run`, показ списка человеку, затем
`.claude/skills/wt/wt cleanup`. Он удаляет задачу, только если каждый её
checkout чист и стоит на ветке, HEAD есть в свежем `origin/<base>` (предок или
те же патчи), задача что-то коммитила и у неё нет живой lease. Полный перечень
условий — в [`WORKTREES.md`](../../../../WORKTREES.md).
