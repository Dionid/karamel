# Preflight

`preflight.sh --worktree <path> --repo <name> [--quiet] [--transport https|auto]`
проверяет identity, GitHub.com origin, совпадение fetch/push repository,
`gh api user` с GITHUB_TOKEN и dry-run push по HTTPS.

Вывод: `IDENTITY=ok (env|config)`, `ORIGIN=github.com`,
`GH=ok HOST=github.com USER=<login>`, `PUSH=ok` и
`PREFLIGHT=ok TRANSPORT=https-gh`. При ошибке: `PREFLIGHT=failed`, exit 1.
Пустой токен: `GH=logged-out` и `NEXT=github-login`. Отказ API: `GH=refused`.
Сетевая ошибка: `GH=unreachable`. Отсутствующий executable: `GH=missing`.
Неподдерживаемые аргументы дают exit 2.

Проверка read-only: не сохраняет credentials, не меняет ветки и не делает commit.
Dry-run не доказывает отсутствие всех серверных ограничений настоящего push.
