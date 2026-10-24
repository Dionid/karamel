---
name: figma-review
description: Ревью UI против Figma — тянет референсы по Figma REST API, снимает скриншоты локального стенда на нескольких viewport'ах, сравнивает числом (SSIM/pHash/RMS) и генерирует punch-list расхождений в iter-N.md. Использовать по «/figma-review», «проверь дизайн», «сравни с фигмой», «design diff», «ревью дизайна».
---

# Figma Review

Closed-loop ревью UI: тянет Figma-референсы по REST API, снимает скриншоты
локального стенда на разных viewport'ах, сравнивает визуально и численно,
генерирует структурированный punch-list расхождений и сохраняет в
`feedback/iter-N.md`. **Этот скилл код не правит** — только отчёт; правки
делает отдельный агент/человек по следующему iter.

## Триггеры

- `/figma-review` без аргументов → ревью текущего проекта по последнему iter
- `/figma-review <Figma URL>` — указанный блок одной командой
- «проверь дизайн», «сравни с фигмой», «design diff», «ревью дизайна»

## Prerequisites — проверить и честно отказать, если не хватает

1. **`FIGMA_TOKEN`** в `.env` (scope: File content read). Проверить через
   `.claude/skills/env-check/env-check.sh FIGMA_TOKEN`. Сгенерировать:
   https://www.figma.com/settings → Personal access tokens. Значение никогда
   не печатается и не идёт в отчёт.
2. **Локальный стенд запущен.** URL — либо явно передан, либо определяется
   автоматически по конфигу проекта (`vite.config.*` / `next.config.*` /
   `nuxt.config.*` → `server.port` / `devServer.port`), иначе спросить
   пользователя. Если стенд не отвечает — сказать об этом и остановиться, а
   не гадать порт.
3. **`CHROME_PATH`** в `.env` — путь к локальному Chrome/Chromium, нужен
   `.claude/skills/figma-review/scripts/shoot-local.mjs`. Без него скрипт отказывает и называет
   переменную, не подставляет платформенный путь по умолчанию.
4. **Python-зависимости `pixel-diff.py`**: `pip install pillow
   opencv-python-headless imagehash numpy scikit-image` (SSIM деградирует
   до «недоступно» без `scikit-image», остальное обязательно). Скрипт сам
   проверяет импорт и честно называет недостающий пакет — не гадать.
5. **`puppeteer-core`** для `shoot-local.mjs`: `npm install puppeteer-core`.

Если чего-то из этого нет — не запускать ревью, сказать пользователю, чего
не хватает, и не пытаться работать по памяти о макете.

## Шаги

### 0. Определить контекст проекта

Артефакты пишем в рабочий каталог проекта:
- `figma-refs/` — экспорты Figma (PNG + при необходимости SVG/JSON)
- `live-shots/iter-N/` — скриншоты локального стенда
- `feedback/iter-N.md` — punch-list этой итерации
- `feedback/iter-LATEST.md` — симлинк на самый свежий iter

### 1. Определить N (номер итерации)

```bash
N=$(ls feedback/iter-*.md 2>/dev/null | wc -l | tr -d ' ')
N=$((N+1))
```

### 2. Забрать референсы из Figma

**Важно**: визуальный просмотр PNG пропускает детали (градиентные обводки,
тени, точные отступы, иконки-инстансы). Перед/параллельно с PNG-фетчем —
вытащить design tokens из JSON для целевых узлов.

**2a — JSON tokens** (полная глубина для целевых узлов):

```bash
python3 .claude/skills/figma-review/scripts/figma-fetch.py --url '<figma-url>' --out figma-refs/ --format png --scale 2
```

Из `/v1/files/<fileKey>/nodes?ids=...` (тот же токен) выписать вручную в
`figma-refs/<block-N>-tokens.md`: fills (solid/gradient), strokes (особенно
градиентные — визуально их легко пропустить), effects (drop-shadow,
layer-blur — radius/color/offset), cornerRadius, layoutMode + padding/gap,
типографику (fontFamily/size/weight/lineHeight/letterSpacing), дочерние
инстансы-иконки (экспортировать отдельно как SVG).

**2b — PNG references** (для визуальной сверки) и **2c — SVG icons**:

```bash
python3 .claude/skills/figma-review/scripts/figma-fetch.py --url '<figma-url>' --out figma-refs/ --label <блок-имя> --scale 2
python3 .claude/skills/figma-review/scripts/figma-fetch.py --file-key <key> --node-ids '<icon1>,<icon2>' --format svg --out figma-refs/svg/
```

Кэширование: если файлы уже есть в `figma-refs/` младше 24ч — можно
пропустить повторный фетч.

### 3. Снять скриншоты локального стенда

```bash
node .claude/skills/figma-review/scripts/shoot-local.mjs \
  --url <локальный-url> \
  --out live-shots/iter-N/ \
  --bp 360,768,1440 \
  --label hero
```

Если доступен MCP для управления реальным браузером с DevTools (сеть,
консоль, Lighthouse) — предпочесть его: реальный Chrome, консоль и
performance-аудит в одном проходе. `shoot-local.mjs` — рабочий fallback,
когда такого MCP нет.

Перед скриншотом проверить, что страница загрузилась без ошибок в консоли
(особенно после горячей перезагрузки / добавления нового ассета).

### 4. Численная оценка (не «на глаз»)

Для каждой пары `figma-refs/X.png` vs `live-shots/iter-N/X.png`:

```bash
python3 .claude/skills/figma-review/scripts/pixel-diff.py \
  figma-refs/hero-desktop.png \
  live-shots/iter-N/hero-1440.png \
  --diff-out live-shots/iter-N/hero-1440-diff.png
```

Вывод: SSIM (0-1, цель >0.85), RMS-ошибка (0-255, <30 хорошо), pHash-дистанция
(<10 хорошо), худшие 3×3 регионы, heatmap разницы. Записать числа в
`iter-N.md` рядом с визуальными находками.

### 5. Визуальное сравнение (multimodal Read)

Для каждой пары Figma vs live (по breakpoint'у): прочитать оба PNG
инструментом чтения изображений, сравнить по категориям — layout, typography,
colors, spacing, visual effects, copy (точный текст), missing/extra elements,
responsive-поведение (что ломается на одном breakpoint, но не на другом).

### 6. Собрать punch-list

Формат `feedback/iter-N.md`:

```markdown
# Design Review — iter N — YYYY-MM-DD HH:MM TZ

**Scope:** <блоки которые проверяли>
**Breakpoints:** 360 / 768 / 1440
**Figma file:** <link>

## Status

| Severity | Count |
|---|---|
| High | X |
| Medium | Y |
| Low | Z |
| **Total** | **N** |

`Пустой punch-list = дизайн соответствует Figma. Готово.`

## High priority

- **[Блок / breakpoint / элемент]** — что не так.
  - **Figma**: точное значение (цвет/размер/отступ)
  - **Live**: фактическое значение
  - **Fix**: `файл:строка` — что поменять

## Medium priority
...

## Low priority
...

## Suggested next iteration

1. <упорядоченный список фиксов, самые влияющие первыми>

## Open questions

- <если что-то неоднозначно>
```

Сохранить (через Write, не bash-heredoc) и обновить симлинк:

```bash
ln -sfn iter-${N}.md feedback/iter-LATEST.md
```

### 7. Отчитаться

Кратко: сколько issues по severity, топ-3 high-priority, путь к полному
файлу. Не применять фиксы самостоятельно — это работа отдельного прохода.

## Numeric stop criteria цикла

- `Total: 0` активных issues
- SSIM >= 0.90 на всех breakpoint'ах
- pHash-дистанция <= 8 на всех breakpoint'ах

Anti-loop guard: если итераций больше 10, или SSIM не растёт два iter подряд
— остановиться и спросить пользователя, а не продолжать молча.

## Что этот скилл НЕ делает

- **Не правит код сам** — punch-list передаётся дальше, фикс делает другой
  проход/агент/человек.
- **Не запускает локальный стенд** — это prerequisite; если он не отвечает,
  сказать об этом и выйти.
- **Не хранит личные пути/токены** — `FIGMA_TOKEN` и `CHROME_PATH` только в
  `.env`, никогда в отчёте или в транскрипте.

## Edge cases

- **Figma-нода не экспортируется** (пустой URL в ответе): часто
  компонент-инстанс без override — попробовать родительский фрейм.
- **PNG-экспорт с прозрачным/белым фоном**: белый текст становится
  невидимым в экспорте — ложное срабатывание в визуальном diff. Опираться на
  JSON tokens, а не на рендер, если фон подозрительно пуст.
- **Разные breakpoint'ы с принципиально разной раскладкой** (не просто
  адаптив, а другой layout, например tab-switcher вместо двух карточек) —
  забирать hi-res референсы отдельно для mobile/tablet/desktop и сравнивать
  визуально все три, не предполагать «mobile = тот же desktop в одну
  колонку».
- **`/v1/files/.../variables` возвращает 403**: требует платный план Figma —
  тогда брать токены прямо из JSON узлов (`fills`, `effects`, `style`).
- **Локальный стенд не отвечает**: проверить, что порт слушает, и лог
  дев-сервера; остановиться и попросить запустить.

## Verification

Скилл сам является проверкой — значит, должен доказывать свою правоту
числом, а не впечатлением:

1. **Численное сравнение, не «выглядит похоже».** `pixel-diff.py` даёт SSIM;
   цель >0.85. Ниже — расхождения есть, даже если глаз их не заметил.
2. **Все breakpoint'ы сняты**, а не только desktop; скриншоты — после полной
   загрузки шрифтов и картинок.
3. **Punch-list проверяемый**: каждый пункт называет элемент, ожидаемое и
   фактическое значение. «Поправить отступы» — не пункт.
4. **Цикл закрыт**: после применения фиксов (в отдельном проходе) —
   повторный прогон и новый iter-файл; закрывать можно только при пустом
   punch-list или явном «хватит» от пользователя.
5. **Figma-референс тот самый**: node-id соответствует проверяемому блоку,
   версия макета актуальна.

**Adversarial:** макет обновился после экспорта референса; на стенде другие
данные, чем в макете (пустое состояние против заполненного); шрифт не
загрузился в headless-браузере (ложные диффы по всему экрану); анимация
поймана в середине; тёмная/светлая тема перепутаны.
