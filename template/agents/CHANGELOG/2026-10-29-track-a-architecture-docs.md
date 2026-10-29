# Треки переименованы, Track A — архитектурные материалы

Прежний Track A (вопрос о коде, диагностика, live-состояние) теперь Track Q,
прежний Track B (изменение продукта) — Track F; `writer.py spawn --track`
принимает `A P Q F C H I`. Новый Track A — работа только с архитектурными
материалами: карта или документ об архитектуре в
`<knowledge-root>/architecture/<name>/` (`README.md`, необязательный html) либо
OpenSpec-спека без реализации. Документ и карту пишет `architect`, спеку —
`analyst` + `architect` через `spec-loop`, каждый в одноразовом checkout. Новый
skill `architecture-map` задаёт формат (каждое утверждение — `path:line`,
команда или URL, непроверенное — в «Неподтверждённое») и проверку `check.py`:
битая ссылка `path:line` даёт exit 1. Спека на Track A требует явного approval
после closing review, ledger получает строку «Ревью спеки до кода: да — Track A,
без build-loop», и `build-loop` по ней отказывает. Обновление — `./ops upgrade`
и `./ops sync`; локальные правила и скиллы, называющие треки старыми буквами,
переименуйте вручную.
