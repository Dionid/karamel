---
name: github-login
description: Проверить GitHub token при подключении GitHub, NEXT=github-login, GH=logged-out или отказе авторизации gh.
---

# GitHub token access

GITHUB_TOKEN из окружения или корневого `.env` — единственный источник GitHub credentials.

Человек задаёт `GITHUB_TOKEN` вне чата: в окружении процесса либо корневом
`.env`. Не просите прислать токен в сообщении и не печатайте его значение.
Процесс имеет приоритет, включая явно пустое значение. `GH_TOKEN` при каждом
вызове перезаписывается значением `GITHUB_TOKEN`; сохранённые логины не используются.

Проверьте наличие через корневой skill **env-check**, затем запустите:

```bash
.claude/skills/github-login/login.sh check --worktree worktrees/<task>/<repo>
```

Это read-only запрос `gh api user`: `STATE=ok HOST=github.com USER=<login>`
подтверждает токен, но не разрешение на push или создание PR в каждом репозитории.
Для проверки конкретного checkout используйте
[`commit-and-mr/preflight.sh`](../commit-and-mr/preflight.sh).

`STATE=missing` требует задать GITHUB_TOKEN; `STATE=refused` — проверить срок
действия, доступ к репозиторию и разрешения токена. `STATE=error` указывает на
отсутствующий gh, неправильный root .env или сетевую ошибку. После исправления
повторите исходную команду. Скрипт ничего не сохраняет и не запускает интерактивную
авторизацию.
