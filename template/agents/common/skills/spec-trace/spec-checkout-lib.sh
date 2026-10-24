#!/usr/bin/env bash
# spec-checkout-lib.sh — какой чекаут задачи держит спеку и где она в нём лежит.
#
# Живёт здесь, а не в core: «спека» — это каталог с определённой раскладкой
# (`openspec/` у OpenSpec), и у другой команды она может называться иначе или
# лежать в нескольких репозиториях. Core про это ничего не знает — он только
# спрашивает spec-ref.sh и мирится с тем, что ответа может не быть.
#
# Кандидаты — записи repos.json, которые ЗАЯВИЛИ `specRoot`, плюс записи
# `always`: их адресовали от корня чекаута ещё до появления поля. Store не
# один — у `platform` он свой, а store спек the team его не принимает
# , — поэтому кандидатов в одном worktree может оказаться несколько, и
# find_spec_checkout требует ровно одного ДЛЯ СУБЪЕКТА, а не вообще. Маркер
# каталога переопределяется SPEC_MARKER_DIR, субъект — SPEC_SUBJECT_REPO.
#
# ПОДКАТАЛОГ, А НЕ КОРЕНЬ. У команды спека может лежать не в корне чекаута, а
# под отдельным подкаталогом — например, когда в корне занят слой конфигурации
# агента. Путь до него задаётся полем `specRoot` записи репозитория в
# `repos.json`, рядом с `url` и `branch`. Без этого поля адресация идёт от
# корня чекаута, как раньше.
#
# Полем, а не переменной окружения, и это не вкусовщина: переменную окружения
# забывают ровно в том вызове, где цена ошибки максимальна; поле читается из
# манифеста в каждом. Промах в обе стороны плохой: без `specRoot` там, где он
# нужен, поиск падает на несуществующем корневом `openspec/`; а если в чужом
# форке корневой `openspec/` тоже существует, литеральный путь находит его и
# молча отвечает про другой проект.
#
# Подключается через `. "$(dirname "$0")/spec-checkout-lib.sh"`; требует
# WORKSPACE_ROOT и функции commit-and-mr/lib.sh (repos_manifest), которые
# каждый вызывающий скрипт сам подключает раньше этого файла.

SPEC_MARKER_DIR="${SPEC_MARKER_DIR:-openspec}"

# SPEC_SUBJECT_REPO — репозиторий-store, чья спека сейчас пишется. Нужен только
# там, где в worktree лежит больше одного store; переменной, а не полем, потому
# что это свойство конкретного изменения, а не манифеста. Забытая переменная
# здесь безопасна: без неё функция отказывает, а не выбирает за человека.
SPEC_SUBJECT_REPO="${SPEC_SUBJECT_REPO:-}"

# manifest_has_repo <path-or-name> — репозиторий описан в repos.json.
#
# Чем отделяются продуктовые чекауты задачи от репозиториев, которые в
# манифест не входят: такой чекаут мог попасть в `worktrees/<task>/` не через
# обычный клон из `repos.json`, а какой-то другой процедурой, и его MR открывает
# не этот скилл — спеку он не реализует. Блок «Спека» в таком MR — ложное
# обещание следующему агенту, а не безобидная лишняя строка.
manifest_has_repo() {
  local repo manifest
  repo="$(basename "$1")"
  [[ -n "$repo" ]] || return 1
  manifest="$(repos_manifest "$WORKSPACE_ROOT")"
  [[ -f "$manifest" ]] || return 1
  [[ "$(jq -r --arg r "$repo" 'if .repos[$r] then "yes" else "no" end' \
        "$manifest" 2>/dev/null || echo no)" == "yes" ]]
}

# repo_branch <name> — базовая ветка репозитория из repos.json, "main" когда
# запись отсутствует или манифеста ещё нет.
repo_branch() {
  local repo manifest
  repo="$(basename "$1")"
  manifest="$(repos_manifest "$WORKSPACE_ROOT")"
  [[ -f "$manifest" ]] || { printf 'main\n'; return 0; }
  jq -r --arg r "$repo" '.repos[$r].branch // "main"' "$manifest" 2>/dev/null || printf 'main\n'
}

# spec_prefix_for <repo> — путь маркера внутри чекаута: `openspec` или
# `<specRoot>/openspec`. Принимает и `<step>/<repo>`, как их возвращает
# find_spec_checkout.
#
# Отдельной функцией, а не «побочным эффектом find_spec_checkout»: тот вызывают
# из подстановки команд, то есть в подоболочке, и любая переменная, выставленная
# внутри, до вызывающего не доедет. Вызывающий спрашивает префикс сам, для того
# же чекаута — ответ тот же, потому что оба идут в один манифест.
spec_prefix_for() {
  local repo root manifest
  repo="$(basename "$1")"
  manifest="$(repos_manifest "$WORKSPACE_ROOT")"
  root=""
  [[ -f "$manifest" ]] && root="$(jq -r --arg r "$repo" '.repos[$r].specRoot // ""' \
            "$manifest" 2>/dev/null || true)"
  root="${root#./}"
  root="${root%/}"

  if [[ -n "$root" && "$root" != "." ]]; then
    printf '%s/%s\n' "$root" "$SPEC_MARKER_DIR"
  else
    printf '%s\n' "$SPEC_MARKER_DIR"
  fi
}

# always_repos — repos.json"->"always", один репозиторий на строку. Пусто,
# когда манифеста ещё нет или поля нет — вызывающий код это не считает
# конфигом спеки и печатает нейтральный SPEC_STATE, а не падает.
always_repos() {
  local manifest
  manifest="$(repos_manifest "$WORKSPACE_ROOT")"
  [[ -f "$manifest" ]] || return 0
  jq -r '.always[]? // empty' "$manifest" 2>/dev/null || true
}

# spec_store_repos — кандидаты на spec-store, один на строку, без повторов.
#
# Кандидат — это репозиторий, ЗАЯВИВШИЙ `specRoot` (поле присутствует; пустая
# строка тоже заявление — она значит «openspec/ в корне чекаута»), плюс записи
# `always`. Вторая половина — совместимость: до появления поля store искали
# только среди `always` и адресовали от корня чекаута, и воркспейс, который
# `specRoot` нигде не объявил, обязан продолжать работать.
#
# Первая половина — то, ради чего функция появилась. Репозиторий со своим
# store не обязан лежать в каждом worktree: `platform` в `always` не входит,
# его подтягивают `wt new <task> --repo platform`. Пока кандидатов искали
# только в `always`, адрес не зависел от того, спеку какого продукта пишут, и
# всегда указывал на store the team — для `platform` это неверный ответ
# .
spec_store_repos() {
  local manifest
  manifest="$(repos_manifest "$WORKSPACE_ROOT")"
  [[ -f "$manifest" ]] || return 0
  jq -r '
    [ (.repos // {} | to_entries[] | select(.value | has("specRoot")) | .key) ]
      + [ (.always[]? // empty) ]
    | reduce .[] as $r ([]; if index($r) then . else . + [$r] end)
    | .[]
  ' "$manifest" 2>/dev/null || true
}

# find_spec_checkout <task_dir> [near_dir] — путь относительно <task_dir>.
# Префикс внутри него спрашивают отдельно, через spec_prefix_for.
#
# `near_dir` — это чекаут, ДЛЯ которого мы ищем спеку: задача, разбитая на шаги,
# держит по чекауту спек на шаг, и ветке принадлежит тот, что лежит рядом с ней,
# а не тот, который первым отсортировался.
#
# Берутся ВСЕ совпадения, а не первое: store несколько, и первое совпадение —
# это порядок манифеста, а не ответ на вопрос «чья это спека». Несколько
# кандидатов в одном worktree — не поломка манифеста, а неназванный субъект:
# задача с `--repo platform` несёт и свой store, и общий store the team из
# `always`. Тогда субъекта называет SPEC_SUBJECT_REPO, а без него — отказ с
# кодом 2 и перечислением кандидатов, чтобы вызывающий остановился и спросил
# пользователя. Молчаливый выбор одного из двух store хуже отказа: запись
# уезжает в чужой store, где её никто не ищет.
#
# Названный субъект отбирает кандидатов ДО того, как их пересчитают, и это не
# оптимизация порядка. Единственный найденный store не значит «тот самый»:
# store the team лежит в каждом worktree по `always`, и задача про `platform`,
# чей чекаут не подтянут или подтянут позже, иначе получила бы его молча.
#
# Коды возврата: 0 — ответ на stdout; 1 — store нет вовсе (нейтральное
# состояние, не ошибка); 2 — отказ: либо кандидатов несколько и субъект не
# назван, либо названный субъект среди них не найден.
find_spec_checkout() {
  local task_dir near_dir candidate dir rel prefix
  local -a near_hits=() hits=() subject_hits=()
  task_dir="$1"
  near_dir="${2-}"

  while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    prefix="$(spec_prefix_for "$candidate")"

    if [[ -n "$near_dir" && -d "$near_dir/$candidate/$prefix" ]]; then
      rel="$(cd "$near_dir/$candidate" && pwd)"
      near_hits+=("${rel#"$task_dir"/}")
      continue
    fi

    if [[ -d "$task_dir/$candidate/$prefix" ]]; then
      hits+=("$candidate")
      continue
    fi

    for dir in "$task_dir"/*/"$candidate"/"$prefix"; do
      if [[ -d "$dir" ]]; then
        rel="${dir%/"$prefix"}"
        hits+=("${rel#"$task_dir"/}")
        break
      fi
    done
  done < <(spec_store_repos)

  # Store рядом с запрошенным чекаутом бьёт дальние: у разбитой на шаги задачи
  # ветке принадлежит именно он.
  if [[ ${#near_hits[@]} -gt 0 ]]; then
    hits=("${near_hits[@]}")
  fi

  if [[ ${#hits[@]} -eq 0 ]]; then
    return 1
  fi

  # Субъект отбирает кандидатов ДО того, как единственный станет ответом. Один
  # кандидат — ещё не «тот самый»: store the team входит в `always` и лежит
  # в каждом worktree, а чекаут `platform` может быть ещё не подтянут. Без
  # этого фильтра задача про `platform` молча получила бы чужой store и
  # увезла бы туда implementation.md — ровно та запись, которую запрещает
  # Названный, но не найденный субъект — отказ, а не повод взять,
  # что есть.
  if [[ -n "$SPEC_SUBJECT_REPO" ]]; then
    for rel in "${hits[@]}"; do
      if [[ "$(basename "$rel")" == "$SPEC_SUBJECT_REPO" ]]; then
        subject_hits+=("$rel")
      fi
    done

    if [[ ${#subject_hits[@]} -eq 0 ]]; then
      echo "error: SPEC_SUBJECT_REPO=$SPEC_SUBJECT_REPO is not a spec store in this worktree: ${hits[*]}" >&2
      echo "hint: the subject names the store to write into, so another store is not a substitute for it — check that repo out (wt new <task> --repo $SPEC_SUBJECT_REPO) or correct the subject " >&2
      return 2
    fi

    hits=("${subject_hits[@]}")
  fi

  if [[ ${#hits[@]} -eq 1 ]]; then
    printf '%s\n' "${hits[0]}"
    return 0
  fi

  if [[ -n "$SPEC_SUBJECT_REPO" ]]; then
    echo "error: SPEC_SUBJECT_REPO=$SPEC_SUBJECT_REPO matches more than one checkout here: ${hits[*]}" >&2
    echo "hint: a stepped task holds the same store twice — pass the step as part of the task (--task <task>/<step>) or ask the user which checkout this change belongs to" >&2
    return 2
  fi

  echo "error: several spec stores in this worktree: ${hits[*]}" >&2
  echo "hint: the store is chosen by the subject of the change, not by the manifest order — set SPEC_SUBJECT_REPO=<repo> or ask the user which one; writing into either of them silently is not allowed " >&2
  return 2
}
