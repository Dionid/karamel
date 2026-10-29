# Force-push заблокирован хуком для агентов

Новый хук `block-force-push.py` (Claude Code и Codex, `PreToolUse` на shell)
блокирует force-push в любой форме: `--force`, `--force-with-lease`, `-f`,
`+refspec`, `--mirror`, обёртки и составные команды; `--dry-run` разрешён.
Агент не делает force-push даже по просьбе пользователя — это действие человека.
Правило записано в разделе «Git и закрытие задачи» `AGENTS.md`. Обновление —
`./ops upgrade` и `./ops sync`.
