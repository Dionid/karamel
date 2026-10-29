# Integration и e2e — только в CI, локальный запуск заблокирован хуком

Новый хук `block-local-integration-tests.py` (Claude Code и Codex, `PreToolUse`
на shell, root и субагенты) отказывает локальному запуску integration/e2e по
исполняемой команде: npm/yarn/pnpm-скрипты `test:integration`/`test:e2e`,
`pytest -m integration`, jest/vitest с integration/e2e-путём или конфигом,
`go test -tags integration` и `-run Integration`, `playwright test`, `cypress`,
`nx run <proj>:e2e`, в том числе внутри `docker`/`podman`/`kubectl exec`.
Сборку, lint, typecheck, unit и сбор без запуска (`e2e:build`,
`pytest --collect-only`) пропускает; Gradle, Maven, Cargo, RSpec и dotnet не
видит, но правило в разделе «Integration-тесты только в CI» `AGENTS.md`
действует и на них. В отчётах агенты пишут «integration не запускались
локально», а не «прошли»; роли builder, reviewer, worker и skills build-loop и
verification-before-completion приведены к этому правилу. Выключатель
`WORKSPACE_ALLOW_LOCAL_INTEGRATION=1` ставит только человек. В `repos.json`
появилось необязательное поле `checks` — стандартные локальные команды проверки
репозитория; `./ops check` отвергает не-массив, пустые строки и команды,
которые заблокировал бы хук. Обновление — `./ops upgrade` и `./ops sync`.
