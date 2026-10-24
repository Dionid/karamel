#!/usr/bin/env bash
# Поведение self-update.sh. Ценность скрипта не в том, что он умеет обновлять —
# `git pull` умеет и без него, — а в том, что он ОТКАЗЫВАЕТСЯ, когда корневой
# чекаут не в том состоянии, и при отказе не трогает ни рабочее дерево, ни HEAD.
#
# Регрессия здесь выглядит как успех: скрипт «починил» корень и отчитался
# зелёным, а вместе с этим ушла чужая незакоммиченная работа — одна копия на
# все параллельные сессии воркспейса.
#
# Тест работает только во временном каталоге и уходит туда первым делом: пустая
# переменная пути превращает `git -C "$root"` в «текущий каталог», и однажды
# такая опечатка уже завела ветки фикстуры в настоящем репозитории.
set -uo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../self-update.sh"
LIB_SRC="$(cd -P "$SELF_DIR/../../commit-and-mr" && pwd)/lib.sh"
[ -f "$LIB_SRC" ] || { printf 'FAIL missing shared git library\n' >&2; exit 1; }

fails=0
ok()   { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; fails=$((fails + 1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cd "$tmp" || exit 1

export GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
git config --global user.email "test@example.invalid"
git config --global user.name "test"
git config --global init.defaultBranch development

# self-update.sh теперь грузит commit-and-mr/lib.sh (gl_load читает окружение
# и необязательный .env) — изолируем прогон от креда и предпочтений транспорта
# реальной машины/CI, как это делают тесты commit-and-mr.
unset AGENT_SESSION_ID GITHUB_TOKEN GH_TOKEN GH_ENTERPRISE_TOKEN


# Воркспейс-фикстура: bare origin, корневой чекаут на базовой ветке, заглушка
# ./ops, которая логирует вызовы, и скрипт на своём штатном месте.
make_ws() {
  local ws="$tmp/$1"
  local root="$ws/root"
  mkdir -p "$root/agents/common/skills/self-update" "$root/agents/common/skills/commit-and-mr"
  cp "$SCRIPT" "$root/agents/common/skills/self-update/self-update.sh"
  chmod +x "$root/agents/common/skills/self-update/self-update.sh"
  # self-update.sh ищет lib.sh по месту воркспейса (agents/common/skills/…),
  # как и wt — фикстура держит настоящую копию библиотеки на этом пути.
  cp "${LIB_SRC%/*}/"{lib.sh,env.py,redact.py} "$root/agents/common/skills/commit-and-mr/"
  printf '{"branch": "development"}\n' > "$root/workspace.json"
  printf 'original\n' > "$root/tracked.txt"
  cat > "$root/ops" <<'OPS'
#!/usr/bin/env bash
here="$(cd -P "$(dirname "$0")" && pwd)"
printf '%s\n' "$1" >> "$here/ops.log"
[ "$1" = check ] && [ -f "$here/fail-check" ] && exit 3
[ "$1" = sync ] && [ -f "$here/fail-sync" ] && exit 3
exit 0
OPS
  chmod +x "$root/ops"
  git -C "$root" init -q
  git -C "$root" add -A
  git -C "$root" commit -qm "init"
  git init -q --bare "$ws/origin.git"
  git -C "$root" remote add origin "$ws/origin.git"
  git -C "$root" push -qu origin development
  # harness.json кладётся ПОСЛЕ коммита: в настоящем воркспейсе он gitignore-нут
  # и создаётся `./ops sync`. Трекнутый маркер сделал бы фикстуру «чекаут без
  # harness.json» грязной, и она отказывала бы не тем гейтом.
  printf '{}\n' > "$root/harness.json"
  printf '%s\n' "$root"
}

# Та же фикстура, но lib.sh лежит ТОЛЬКО по $ROOT/.claude/skills/…, без копии
# в agents/common/skills/… — так выглядит корень после настоящего `./ops sync`.
# Эту ветку резолва self-update.sh проверяет первой (self-update.sh:93) и идёт
# по ней на каждом реальном запуске; вторая ветка (agents/common/…) — только
# фолбэк для фикстуры make_ws выше, где sync никто не запускал.
make_ws_claude_lib() {
  local ws="$tmp/$1"
  local root="$ws/root"
  mkdir -p "$root/agents/common/skills/self-update" "$root/.claude/skills/commit-and-mr"
  cp "$SCRIPT" "$root/agents/common/skills/self-update/self-update.sh"
  chmod +x "$root/agents/common/skills/self-update/self-update.sh"
  cp "${LIB_SRC%/*}/"{lib.sh,env.py,redact.py} "$root/.claude/skills/commit-and-mr/"
  ln -s "$root/.claude/skills/commit-and-mr" "$root/agents/common/skills/commit-and-mr"
  printf '{"branch": "development"}\n' > "$root/workspace.json"
  printf 'original\n' > "$root/tracked.txt"
  cat > "$root/ops" <<'OPS'
#!/usr/bin/env bash
here="$(cd -P "$(dirname "$0")" && pwd)"
printf '%s\n' "$1" >> "$here/ops.log"
[ "$1" = check ] && [ -f "$here/fail-check" ] && exit 3
[ "$1" = sync ] && [ -f "$here/fail-sync" ] && exit 3
exit 0
OPS
  chmod +x "$root/ops"
  git -C "$root" init -q
  git -C "$root" add -A
  git -C "$root" commit -qm "init"
  git init -q --bare "$ws/origin.git"
  git -C "$root" remote add origin "$ws/origin.git"
  git -C "$root" push -qu origin development
  printf '{}\n' > "$root/harness.json"
  printf '%s\n' "$root"
}

# Коммит в origin мимо корня — так появляется «есть что подтянуть».
advance_origin() {
  local ws="$1"
  local clone="$tmp/push-$RANDOM"
  git clone -q "$ws/origin.git" "$clone"
  printf 'newer\n' > "$clone/agents/common/skills/self-update/NEW.md"
  printf '# правило\n' >> "$clone/AGENTS.md"
  git -C "$clone" add -A
  git -C "$clone" commit -qm "новый коммит агентского слоя"
  git -C "$clone" push -q origin development
}

run() {
  [ -n "$1" ] || { fail "фикстура не отдала путь корня"; return 1; }
  "$1/agents/common/skills/self-update/self-update.sh" 2>&1
}

# ------------------------------------------------------- обновление проходит ---
root="$(make_ws happy)"
advance_origin "$tmp/happy"
out="$(run "$root")"; rc=$?
[ "$rc" -eq 0 ] && ok "обновление: код возврата 0" || fail "обновление: rc=$rc, вывод: $out"
[ -f "$root/agents/common/skills/self-update/NEW.md" ] \
  && ok "обновление: коммит из origin оказался в корне" \
  || fail "обновление: pull не принёс коммит"
[ "$(cat "$root/ops.log" 2>/dev/null)" = "$(printf 'sync\ncheck')" ] \
  && ok "обновление: ./ops вызван как sync, затем check" \
  || fail "обновление: ожидал 'sync' + 'check', получил: $(tr '\n' ',' < "$root/ops.log" 2>/dev/null)"
printf '%s' "$out" | grep -q "новый коммит агентского слоя" \
  && ok "обновление: подтянутые коммиты перечислены в отчёте" \
  || fail "обновление: в отчёте нет списка коммитов: $out"
printf '%s' "$out" | grep -q "агентский слой изменился" \
  && ok "обновление: приехавшие файлы агентского слоя названы отдельно" \
  || fail "обновление: отчёт не отметил изменение агентского слоя: $out"

# ------------------------------------------------------------ уже свежий ---
root="$(make_ws fresh)"
out="$(run "$root")"; rc=$?
[ "$rc" -eq 0 ] && ok "уже свежий: код возврата 0" || fail "уже свежий: rc=$rc, вывод: $out"
printf '%s' "$out" | grep -q "новых коммитов нет" \
  && ok "уже свежий: отчёт говорит, что подтягивать нечего" \
  || fail "уже свежий: нет отметки об отсутствии коммитов: $out"

# ------------------------------------- резолв lib.sh: путь настоящего запуска ---
root="$(make_ws_claude_lib claudepath)"
advance_origin "$tmp/claudepath"
out="$(run "$root")"; rc=$?
[ "$rc" -eq 0 ] && ok "резолв lib.sh: \$ROOT/.claude/… — путь каждого реального запуска" \
  || fail "резолв lib.sh: rc=$rc, вывод: $out"
[ -f "$root/agents/common/skills/self-update/NEW.md" ] \
  && ok "резолв lib.sh: pull по этому пути реально прошёл" \
  || fail "резолв lib.sh: pull не случился, вывод: $out"

# --------------------------------------------- грязный корень: отказ без правки ---
root="$(make_ws dirty)"
advance_origin "$tmp/dirty"
printf 'чужая несохранённая работа\n' > "$root/tracked.txt"
head_before="$(git -C "$root" rev-parse HEAD)"
out="$(run "$root")"; rc=$?
[ "$rc" -ne 0 ] && ok "грязный корень: отказ ненулевым кодом" || fail "грязный корень: rc=0, вывод: $out"
[ "$(cat "$root/tracked.txt")" = "чужая несохранённая работа" ] \
  && ok "грязный корень: незакоммиченная правка не тронута" \
  || fail "грязный корень: правка потеряна — содержимое '$(cat "$root/tracked.txt")'"
[ "$(git -C "$root" rev-parse HEAD)" = "$head_before" ] \
  && ok "грязный корень: HEAD не сдвинут" \
  || fail "грязный корень: HEAD сдвинулся при отказе"
[ ! -f "$root/ops.log" ] \
  && ok "грязный корень: ./ops не вызывался" \
  || fail "грязный корень: ./ops вызван при несработавшем гейте"

# ------------------------------------ разошедшаяся история: только fast-forward ---
# Главное обещание скилла. Без этого случая `--ff-only` можно снять, и набор
# останется зелёным: в остальных фикстурах у корня нет своих коммитов.
root="$(make_ws diverged)"
advance_origin "$tmp/diverged"
printf 'локальная правка корня\n' > "$root/local.txt"
git -C "$root" add -A
git -C "$root" commit -qm "коммит, сделанный прямо в корне"
head_before="$(git -C "$root" rev-parse HEAD)"
out="$(run "$root")"; rc=$?
[ "$rc" -ne 0 ] && ok "разошедшаяся история: отказ ненулевым кодом" \
  || fail "разошедшаяся история: rc=0 — fast-forward не единственный путь, вывод: $out"
[ "$(git -C "$root" rev-parse HEAD)" = "$head_before" ] \
  && ok "разошедшаяся история: HEAD не сдвинут, merge-коммита нет" \
  || fail "разошедшаяся история: HEAD сдвинулся — появился merge или rebase"
printf '%s' "$out" | grep -q "ни rebase, ни merge, ни force" \
  && ok "разошедшаяся история: назван именно гейт fast-forward, не логин" \
  || fail "разошедшаяся история: сообщение не про fast-forward: $out"
printf '%s' "$out" | grep -q "транспорт остановился" \
  && fail "разошедшаяся история: сообщение про логин gh перепутано с ff-only: $out" \
  || ok "разошедшаяся история: сообщение про логин gh не подмешано"
[ ! -f "$root/ops.log" ] \
  && ok "разошедшаяся история: ./ops не вызывался" \
  || fail "разошедшаяся история: ./ops вызван после непрошедшего pull"

# ------------------------------------- ветка задачи в корне со своим upstream ---
# Ветка следит за своим origin-двойником, поэтому сверка имён её пропускает:
# ловит только сверка с базовой веткой из workspace.json.
root="$(make_ws taskbranch)"
git -C "$root" checkout -q -b feature/чужая-задача
git -C "$root" push -qu origin feature/чужая-задача
head_before="$(git -C "$root" rev-parse HEAD)"
out="$(run "$root")"; rc=$?
[ "$rc" -ne 0 ] && ok "ветка задачи в корне: отказ ненулевым кодом" \
  || fail "ветка задачи в корне: rc=0 — корень обновился на непроверенную ветку, вывод: $out"
[ "$(git -C "$root" symbolic-ref --short HEAD)" = "feature/чужая-задача" ] \
  && ok "ветка задачи в корне: ветка не переключена" \
  || fail "ветка задачи в корне: скрипт сменил ветку корня"
[ "$(git -C "$root" rev-parse HEAD)" = "$head_before" ] && ok "ветка задачи в корне: HEAD не сдвинут" \
  || fail "ветка задачи в корне: HEAD сдвинулся при отказе"

# ------------------------------------------- upstream не свой двойник: отказ ---
# Имя ветки базовое, а следит она за веткой с другим именем: fast-forward
# притянул бы чужую историю прямо в development.
root="$(make_ws upstream)"
git -C "$root" push -q origin development:other
git -C "$root" fetch -q origin
git -C "$root" branch -q --set-upstream-to=origin/other development
head_before="$(git -C "$root" rev-parse HEAD)"
out="$(run "$root")"; rc=$?
[ "$rc" -ne 0 ] && ok "чужой upstream: отказ ненулевым кодом" || fail "чужой upstream: rc=0, вывод: $out"
[ "$(git -C "$root" rev-parse HEAD)" = "$head_before" ] \
  && ok "чужой upstream: HEAD не сдвинут" || fail "чужой upstream: HEAD сдвинулся при отказе"

# ------------------------------------------------- worktree вместо корня: отказ ---
root="$(make_ws wt)"
wt="$tmp/wt-task"
git -C "$root" worktree add -q -b feature/задача "$wt" >/dev/null 2>&1
cp "$root/harness.json" "$wt/harness.json"
out="$("$wt/agents/common/skills/self-update/self-update.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "worktree: отказ ненулевым кодом" || fail "worktree: rc=0, вывод: $out"
printf '%s' "$out" | grep -qi "worktree" \
  && ok "worktree: причина отказа названа" || fail "worktree: причина отказа не названа: $out"

# ------------------------------- чекаут без harness.json (как packages/): отказ ---
# Самый близкий к беде случай: `packages/<repo>` — обычный клон, где проходят
# все остальные гейты. Корнем его делает только отсутствующий harness.json.
root="$(make_ws pkg)"
rm -f "$root/harness.json"
head_before="$(git -C "$root" rev-parse HEAD)"
out="$(run "$root")"; rc=$?
[ "$rc" -ne 0 ] && ok "чекаут не из корня: отказ ненулевым кодом" \
  || fail "чекаут не из корня: rc=0 — скилл принял packages-подобный клон за корень, вывод: $out"
[ ! -f "$root/ops.log" ] && ok "чекаут не из корня: ./ops не вызывался" \
  || fail "чекаут не из корня: ./ops sync запущен вне корня"
[ "$(git -C "$root" rev-parse HEAD)" = "$head_before" ] \
  && ok "чекаут не из корня: HEAD не сдвинут" || fail "чекаут не из корня: HEAD сдвинулся"

# ---------------------------------- красный ./ops check: падение, а не зелёный отчёт ---
root="$(make_ws redcheck)"
advance_origin "$tmp/redcheck"
touch "$root/fail-check"
out="$(run "$root")"; rc=$?
[ "$rc" -ne 0 ] && ok "красный check: ненулевой код возврата" || fail "красный check: rc=0, вывод: $out"
printf '%s' "$out" | grep -q "разошлись с agents/" \
  && ok "красный check: названа именно его причина" || fail "красный check: причина не названа: $out"

# ------------------------------------------------- упавший ./ops sync: check не зовётся ---
root="$(make_ws redsync)"
touch "$root/fail-sync"
out="$(run "$root")"; rc=$?
[ "$rc" -ne 0 ] && ok "упавший sync: ненулевой код возврата" || fail "упавший sync: rc=0, вывод: $out"
[ "$(cat "$root/ops.log")" = "sync" ] \
  && ok "упавший sync: check после него не запускался" \
  || fail "упавший sync: ожидал только 'sync', получил: $(tr '\n' ',' < "$root/ops.log")"


# ------------------------------- credentialed pull: origin похож на GitHub ---
# Доказательство дыры из AGENTS.md/preflight: origin почти всегда GitHub, и
# голый `git pull` падает в контейнере без credential.helper, хотя gh
# залогинен. `git` здесь — перехватчик: он не подменяет сеть (insteadOf
# перенаправляет реальный https-URL обратно на bare-фикстуру, как и
# полагается голому git), а только записывает, нёс ли вызов credential-флаг
# commit-and-mr/lib.sh (`-c credential.helper=!gh auth git-credential`).
# Откат self-update.sh на голый `git -C "$ROOT" pull --ff-only` красит именно
# эту проверку: маркер в логе не появится ни разу.
credbin="$tmp/cred-bin"
mkdir -p "$credbin" "$tmp/cred-gh-state" "$tmp/credlogout-gh-state"
printf '#!/usr/bin/env bash\nprintf "fixture-user\\n"\n' > "$credbin/gh"
chmod +x "$credbin/gh"
real_git_bin="$(command -v git)"
credlog="$tmp/cred-git.log"
: > "$credlog"
# FAKE_HTTPS=ok (по умолчанию) отдаёт вызов настоящему git — insteadOf ниже
# превращает его в локальную передачу без сети и без credential-запроса, так
# что успешный pull остаётся успешным. FAKE_HTTPS=auth вместо этого отвечает
# ровно тем, что `fatal: could not read Username ...` отвечает реальный
# голый git в контейнере без credential.helper — это и есть сигнал, по
# которому commit-and-mr/lib.sh решает, логинлен ли gh.
cat > "$credbin/git" <<GITSTUB
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == 'credential.helper=!gh auth git-credential' ]]; then
    printf 'credentialed\n' >> "$credlog"
    case "\${FAKE_HTTPS:-ok}" in
      ok) exec "$real_git_bin" -c protocol.file.allow=always "\$@" ;;
      auth) echo "fatal: could not read Username for 'https://github.com': terminal prompts disabled" >&2; exit 128 ;;
    esac
  fi
done
printf 'bare\n' >> "$credlog"
exec "$real_git_bin" "\$@"
GITSTUB
chmod +x "$credbin/git"

credws="$tmp/cred"
credroot="$(make_ws cred)"
advance_origin "$credws"
git -C "$credroot" remote set-url origin https://github.com/group/project.git
git -C "$credroot" config "url.$credws/origin.git.insteadOf" https://github.com/group/project.git

out="$(PATH="$credbin:$PATH" GITHUB_TOKEN=test-canonical-secret \
  run "$credroot" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "credentialed pull: обновление прошло" \
  || fail "credentialed pull: rc=$rc, вывод: $out"
grep -qx credentialed "$credlog" \
  && ok "credentialed pull: git pull нёс credential.helper из commit-and-mr/lib.sh" \
  || fail "credentialed pull: ни один вызов git не нёс credential-маркер — откат на голый git остался бы незамеченным. Лог: $(cat "$credlog")"

# ---------------------- credentialed pull: gh не залогинен — назвать отказ ---
# Новый режим отказа: не обходить молча голым git или SSH, а остановиться и
# назвать NEXT=, как это уже делают commit-and-mr и preflight.
logws="$tmp/credlogout"
logroot="$(make_ws credlogout)"
advance_origin "$logws"
git -C "$logroot" remote set-url origin https://github.com/group/project.git
git -C "$logroot" config "url.$logws/origin.git.insteadOf" https://github.com/group/project.git
head_before="$(git -C "$logroot" rev-parse HEAD)"
: > "$credlog"
out="$(PATH="$credbin:$PATH" GITHUB_TOKEN='' \
  FAKE_HTTPS=auth run "$logroot" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "gh не залогинен: отказ ненулевым кодом" \
  || fail "gh не залогинен: rc=0 — должен был остановиться, вывод: $out"
printf '%s' "$out" | grep -q '^NEXT=' \
  && ok "gh не залогинен: отчёт называет NEXT=" \
  || fail "gh не залогинен: в выводе нет NEXT= — отказ без указания, что делать дальше: $out"
printf '%s' "$out" | grep -q "транспорт остановился" \
  && ok "gh не залогинен: названа именно причина логина, не общая ff-only" \
  || fail "gh не залогинен: сообщение не называет логин как причину: $out"
printf '%s' "$out" | grep -q "ни rebase, ни merge, ни force" \
  && fail "gh не залогинен: сообщение перепутано с gate'ом fast-forward: $out" \
  || ok "gh не залогинен: fast-forward-сообщение не подмешано"
[ "$(git -C "$logroot" rev-parse HEAD)" = "$head_before" ] \
  && ok "gh не залогинен: HEAD корня не сдвинут" \
  || fail "gh не залогинен: HEAD сдвинулся при несработавшем credential-гейте"
[ ! -f "$logroot/ops.log" ] \
  && ok "gh не залогинен: ./ops не вызывался" \
  || fail "gh не залогинен: ./ops вызван при несработавшем credential-гейте"

# Unselected dotenv variables never enter git hooks or later runtime commands.
root="$(make_ws envleak)"
printf 'LEAK_PROBE_VAR=leaked-value\n' > "$root/.env"
cat > "$root/ops" <<OPS
#!/usr/bin/env bash
here="\$(cd -P "\$(dirname "\$0")" && pwd)"
printf '%s\n' "\$1" >> "\$here/ops.log"
[ -z "\${LEAK_PROBE_VAR-}" ] || printf '%s\n' "\$1" >> "\$here/ops-leak.log"
[ "\$1" = check ] && [ -f "\$here/fail-check" ] && exit 3
[ "\$1" = sync ] && [ -f "\$here/fail-sync" ] && exit 3
exit 0
OPS
chmod +x "$root/ops"
mkdir -p "$root/.git/hooks"
cat > "$root/.git/hooks/post-merge" <<HOOK
#!/usr/bin/env bash
[ -z "\${LEAK_PROBE_VAR-}" ] || printf 'leaked\n' >> "$root/posthook-leak.log"
printf '%s\n' "\${WORKSPACE_NO_AUTO_WT_PULL-unset}" >> "$root/posthook-wtpull.log"
exit 0
HOOK
chmod +x "$root/.git/hooks/post-merge"
git -C "$root" add ops
git -C "$root" commit -qm "test: env-leak probes в ./ops и post-merge"
git -C "$root" push -q origin development
advance_origin "$tmp/envleak"

out="$(run "$root")"; rc=$?
[ "$rc" -eq 0 ] && ok "env-leak: обновление с .env в корне проходит" \
  || fail "env-leak: rc=$rc, вывод: $out"
[ ! -f "$root/ops-leak.log" ] \
  && ok "env-leak: ./ops не видит \$LEAK_PROBE_VAR из корневого .env" \
  || fail "env-leak: .env уехал в ./ops — виден в: $(cat "$root/ops-leak.log")"
[ ! -f "$root/posthook-leak.log" ] \
  && ok "env-leak: unselected dotenv variable is absent from post-merge" \
  || fail "env-leak: unselected dotenv variable reached post-merge"
# Пин на то, что явно просили перепроверить после перехода на subshell:
# префиксное присваивание WORKSPACE_NO_AUTO_WT_PULL=1 перед вызовом gl_git
# по-прежнему доезжает до git внутри gl_remote_run и до хука post-merge,
# который этот git pull запускает, даже когда sourcing+gl_load+pull теперь
# заперты в subshell'е, а не идут прямо в self-update.sh.
[ "$(cat "$root/posthook-wtpull.log" 2>/dev/null)" = "1" ] \
  && ok "env-leak: WORKSPACE_NO_AUTO_WT_PULL=1 доезжает до хука post-merge и через subshell" \
  || fail "env-leak: WORKSPACE_NO_AUTO_WT_PULL не доехал до хука — видел '$(cat "$root/posthook-wtpull.log" 2>/dev/null)'"

printf '\n'
if [ "$fails" -ne 0 ]; then
  printf 'провалов: %d\n' "$fails" >&2
  exit 1
fi
printf 'self-update.sh: все проверки прошли\n'
