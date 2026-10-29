# Фоновое ревью сессии при её завершении

Новый хук `review-session-on-end.py` (Claude Code, `SessionEnd`) по флагу
`WORKSPACE_SESSION_REVIEW=1` запускает отсоединённый `claude -p` со скиллом
`review-chat-session` над транскриптом завершённой сессии (sonnet, только Read
и Skill, без MCP, с лимитами ходов и бюджета). Отчёт сохраняется в каталог
session-reports в `~/.claude` как `<дата>-<session_id>.md`;
`.review-chat-session.md` в этом режиме только читается. Флаг ставит человек,
без него хук ничего не делает. Скилл получил раздел о фоновом режиме.
Обновление — `./ops upgrade` и `./ops sync`.
