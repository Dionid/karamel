# Прочие изменения шаблона: upgrade, Track C, wt

`new-workspace.sh upgrade` печатает `differs <file>` для локально изменённых
файлов общего слоя до перезаписи, в том числе в `--dry-run`. Условные правила
перенесены в шаблон: work-items в `commit-and-mr`, `openspec-propose` и
`spec-loop`, one-shot CLI callers в `agent-directed-routing`. Track C: число
репозиториев больше не триггер; ветки `<branchPrefix><task>/<sub>` открывает
`adopt.sh`; «оркестратор» — это root, `spawn`/`integrate` выполняются по разу на
репозиторий; Track C идёт без ожидания approval и останавливается только по явной
просьбе. `wt` учитывает `.agent-routing`: `cleanup` и `rm` удерживают задачу с
живыми writer'ами, ledger, recovery и journals. В `AGENTS.md` добавлен раздел
«Гард пропускает, тест падает». Обновление — `./ops upgrade` и `./ops sync`.
