#!/usr/bin/env bash
#
# lint.sh — the harness linter. Checks the thing this repo actually ships: the
# docs and scripts under .claude/ that agents read and run.
#
# Two halves. This file drives the checks that are about files and processes
# (syntax, shellcheck, the executable bit, manifest drift, markdownlint); lint.py
# beside it does the ones that are string work (heading slugs, fenced code,
# frontmatter). Run this one — it calls the other.
#
# Missing external tools are reported as SKIPPED, not as passes: a linter that
# quietly does less than it says is worse than no linter. --require-tools turns
# a missing one into a failure, which is what CI passes.

set -uo pipefail

# Проверки на python лежат в каталоге под git. Без этого каждый прогон линта
# оставляет рядом с ними __pycache__/, который `git add -A` подхватывает как
# исходник — gitignore чинит последствие, это чинит причину.
export PYTHONDONTWRITEBYTECODE=1

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The workspace root holds generated harness.json or tracked workspace.json.
# Walking up means this
# works whether the script was reached through .claude/ or agents/.
is_root() { [ -f "$1/harness.json" ] || [ -f "$1/workspace.json" ]; }
ROOT="$SELF_DIR"
while [ "$ROOT" != "/" ] && ! is_root "$ROOT"; do ROOT="$(dirname "$ROOT")"; done
is_root "$ROOT" || { printf 'cannot locate the workspace root\n' >&2; exit 1; }

MANIFEST_REL="repos.json"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 1 ] || { c_red=""; c_grn=""; c_ylw=""; c_dim=""; c_off=""; }

FAILED=""
SKIPPED=""
WARNED=""
REQUIRE_TOOLS=0
STRICT=0
ONLY=""
MARKDOWNLINT_VERSION="0.23.2"

git_common_dir="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
LINT_TOOL_OVERRIDE="${WORKSPACE_LINT_TOOL_ROOT-}"
if [ -n "$git_common_dir" ]; then
  LINT_TOOL_ROOT="${LINT_TOOL_OVERRIDE:-$(dirname "$git_common_dir")/.agent-tools/lint}"
else
  LINT_TOOL_ROOT="${LINT_TOOL_OVERRIDE:-$ROOT/.agent-tools/lint}"
fi

ALL_CHECKS="syntax shellcheck execbit manifest markdown harness decisions hooks"

usage() {
  cat <<EOF
Usage: .claude/skills/lint/lint.sh [--only <check>]... [--strict] [--require-tools]
                                   [--install-hook] [--install-tools] [--list]

Checks:
  syntax       bash -n on every tracked script with a shebang
  shellcheck   static analysis of those scripts (needs shellcheck)
  execbit      standalone scripts +x, sourced libs not +x
  manifest     repos.json vs what is in packages/ (skipped when packages/ is empty)
  markdown     markdownlint over the tracked .md (needs pinned local tools)
  harness      lint.py: skill contract, links, anchors, doc paths, fences,
               forbidden command forms, cross-doc coverage
  decisions    локальный DECISIONS.md/decisions/ и, если он склонирован,
               packages/<knowledge-repo>/<knowledge-root>/decisions: статусы,
               обязательные поля, взаимность замен
  hooks        lifecycle/coordination behavior plus the secret-leak decision on
               every input shape both agents send (secret checks need jq)

  --strict         warnings and skips fail too
  --require-tools  a missing linter is a failure, not a SKIPPED line (CI passes this)
  --install-hook   install .git/hooks/pre-commit, then exit
  --install-tools  install pinned external linters into the shared local cache
  --list           print the check names and exit
EOF
}

install_hook() {
  local dst="$ROOT/.git/hooks/pre-commit"
  if [ -e "$dst" ] && ! grep -q 'lint/lint.sh' "$dst" 2>/dev/null; then
    printf '%srefusing to overwrite an existing unrelated hook: .git/hooks/pre-commit%s\n' "$c_red" "$c_off" >&2
    return 1
  fi
  cat > "$dst" <<'HOOK'
#!/usr/bin/env sh
# Installed by .claude/skills/lint/lint.sh --install-hook
#
# Lints the harness before every commit in THIS repo. Warnings do not block —
# only errors do, so a skill a few lines over its budget is reported and lets
# the commit through.
exec .claude/skills/lint/lint.sh
HOOK
  chmod +x "$dst"
  printf '%sinstalled .git/hooks/pre-commit%s\n' "$c_grn" "$c_off"
}

install_tools() {
  command -v npm >/dev/null 2>&1 || {
    printf '%snpm is required to install markdownlint-cli2%s\n' "$c_red" "$c_off" >&2
    return 1
  }
  mkdir -p "$LINT_TOOL_ROOT"
  printf 'installing markdownlint-cli2@%s into %s\n' "$MARKDOWNLINT_VERSION" "$LINT_TOOL_ROOT"
  npm install --prefix "$LINT_TOOL_ROOT" --no-save --no-package-lock \
    "markdownlint-cli2@$MARKDOWNLINT_VERSION"
}

while (($# > 0)); do
  case "$1" in
    --only) ONLY="$ONLY ${2:-}"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --require-tools) REQUIRE_TOOLS=1; shift ;;
    --install-hook) install_hook; exit $? ;;
    --install-tools) install_tools; exit $? ;;
    --list) printf '%s\n' $ALL_CHECKS; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done

CHECKS="${ONLY:-$ALL_CHECKS}"

wants() {
  case " $CHECKS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

head_of() { printf '\n%s== %s ==%s\n' "$c_grn" "$1" "$c_off"; }
fail()    { FAILED="$FAILED $1"; }

# no_tool <check> <name> <how to get it>
no_tool() {
  if ((REQUIRE_TOOLS)); then
    printf '%s  missing: %s — %s%s\n' "$c_red" "$2" "$3" "$c_off"
    fail "$1"
  else
    printf '%s  SKIPPED: %s not installed — %s%s\n' "$c_ylw" "$2" "$3" "$c_off"
    SKIPPED="$SKIPPED $1"
  fi
}

cd "$ROOT" || exit 1

# Tracked SHELL scripts: the shebang has to name sh or bash. Matching on `#!`
# alone would hand lint.py to `bash -n`, which fails on perfectly good Python —
# and `wt` has no extension, so the shebang is the only thing to go by.
scripts() {
  git ls-files | while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$(head -1 "$f" 2>/dev/null)" in
      '#!'*[/\ ]sh|'#!'*[/\ ]bash|'#!'*env\ sh|'#!'*env\ bash) printf '%s\n' "$f" ;;
    esac
  done
}

# --------------------------------------------------------------------- syntax --
if wants syntax; then
  head_of "syntax (bash -n)"
  n=0
  while IFS= read -r f; do
    n=$((n + 1))
    out="$(bash -n "$f" 2>&1)" || { printf '%s  %s: %s%s\n' "$c_red" "$f" "$out" "$c_off"; fail syntax; }
  done < <(scripts)
  [ -n "$FAILED" ] || printf '  %s%d scripts parse%s\n' "$c_dim" "$n" "$c_off"
fi

# ----------------------------------------------------------------- shellcheck --
if wants shellcheck; then
  head_of "shellcheck"
  if command -v shellcheck > /dev/null 2>&1; then
    # -x follows `source`d files (lib.sh), which is the whole point here.
    # SC1091: a sourced path that only exists at runtime (.env) is not a defect.
    sh_files=()
    while IFS= read -r script; do sh_files+=("$script"); done < <(scripts)
    if ! shellcheck -x -e SC1091 -S warning "${sh_files[@]}"; then
      fail shellcheck
    else
      printf '  %sno warnings%s\n' "$c_dim" "$c_off"
    fi
  else
    no_tool shellcheck shellcheck "brew install shellcheck"
  fi
fi

# --------------------------------------------------------------------- execbit --
if wants execbit; then
  head_of "executable bit"
  bad=0
  while IFS= read -r line; do
    mode="${line%% *}"; rest="${line#* }"; f="${rest#*$'\t'}"
    has_shebang=0
    case "$(head -1 "$f" 2>/dev/null)" in '#!'*) has_shebang=1 ;; esac
    # A library is sourced, never executed — +x on it invites the wrong call.
    is_lib=0
    case "$f" in
      *lib.sh|*/lib-*.sh) is_lib=1 ;;
    esac

    if [ "$has_shebang" = 1 ] && [ "$is_lib" = 0 ] && [ "$mode" != "100755" ]; then
      printf '%s  %s: mode %s — has a shebang but is not executable%s\n' "$c_red" "$f" "$mode" "$c_off"
      bad=1
    fi
    if [ "$is_lib" = 1 ] && [ "$mode" = "100755" ]; then
      printf '%s  %s: mode %s — a sourced library must not be executable%s\n' "$c_red" "$f" "$mode" "$c_off"
      bad=1
    fi
  done < <(git ls-files -s)
  [ "$bad" = 0 ] && printf '  %sall modes correct%s\n' "$c_dim" "$c_off" || fail execbit
fi

# -------------------------------------------------------------------- manifest --
if wants manifest; then
  head_of "repos.json vs packages/"
  # A glob rather than `ls | grep`: .gitkeep is the only thing a fresh clone has.
  pkg_count=0
  for d in packages/*; do
    [ -e "$d" ] || continue
    case "$d" in packages/.gitkeep) continue ;; esac
    pkg_count=$((pkg_count + 1))
  done

  if [ ! -f "$MANIFEST_REL" ]; then
    printf '  %sSKIPPED: no %s (the manifest is not there yet)%s\n' "$c_ylw" "$MANIFEST_REL" "$c_off"
    SKIPPED="$SKIPPED manifest"
  elif [ "$pkg_count" = 0 ]; then
    printf '  %sSKIPPED: packages/ is empty (a fresh clone or CI) — nothing to compare%s\n' "$c_ylw" "$c_off"
    SKIPPED="$SKIPPED manifest"
  else
    out="$(
      MANIFEST_REL="$MANIFEST_REL" python3 - <<'PY'
import json, os
m = json.load(open(os.environ['MANIFEST_REL']))
listed = set(m['repos']) | set(m.get('exclude', []))
disk = {d for d in os.listdir('packages') if os.path.exists(f'packages/{d}/.git')}
for r in sorted(disk - listed):
    print(f"  on disk but not in the manifest: packages/{r} — run: .claude/skills/wt/wt manifest")
for r in sorted(set(m['repos']) - disk):
    print(f"  in the manifest but not on disk: {r} — run: .claude/skills/clone/clone.sh {r}")
PY
    )"
    # Drift is a warning: a repo cloned by hand is a legitimate state until
    # someone runs `wt manifest`, and it must not block an unrelated commit.
    if [ -n "$out" ]; then printf '%s%s%s\n' "$c_ylw" "$out" "$c_off"; WARNED="$WARNED manifest"
    else printf '  %sin step%s\n' "$c_dim" "$c_off"; fi
  fi
fi

# -------------------------------------------------------------------- markdown --
if wants markdown; then
  head_of "markdownlint"
  md_cmd=()
  markdownlint_problem=""
  local_markdownlint="$LINT_TOOL_ROOT/node_modules/.bin/markdownlint-cli2"
  if [ -x "$local_markdownlint" ]; then
    local_markdownlint_version="$("$local_markdownlint" --version 2>&1 | head -1)"
    case "$local_markdownlint_version" in
      "markdownlint-cli2 v$MARKDOWNLINT_VERSION "*) md_cmd=("$local_markdownlint") ;;
      *) markdownlint_problem="cached tool reports $local_markdownlint_version; need markdownlint-cli2 v$MARKDOWNLINT_VERSION — rerun: make lint-tools" ;;
    esac
  elif command -v markdownlint-cli2 > /dev/null 2>&1; then
    global_markdownlint_version="$(markdownlint-cli2 --version 2>&1 | head -1)"
    case "$global_markdownlint_version" in
      "markdownlint-cli2 v$MARKDOWNLINT_VERSION "*) md_cmd=(markdownlint-cli2) ;;
      *) markdownlint_problem="found $global_markdownlint_version; need markdownlint-cli2 v$MARKDOWNLINT_VERSION" ;;
    esac
  fi

  if [ "${#md_cmd[@]}" -gt 0 ]; then
    # git ls-files, so an untracked scratch .md never fails the run. One run, its
    # status read directly — piping into grep would hand back grep's status and
    # the check would pass on every finding.
    # Vendored docs are excluded, and the count is printed rather than swallowed:
    # a check that quietly covers less than it claims is the failure mode this
    # whole linter exists to prevent. VENDORED lists paths taken from upstream
    # unchanged — skills imported verbatim from public collections. Reformatting
    # them would fork them from their source, and every later update would then
    # arrive as a conflict, for no gain.
    VENDORED='^agents/common/skills/(finding-duplicate-functions|memory|using-tmux-for-interactive-commands)/'
    mdfiles=()
    while IFS= read -r markdown; do mdfiles+=("$markdown"); done \
      < <(git ls-files '*.md' | grep -vE "$VENDORED")
    skipped_md=$(git ls-files '*.md' | grep -cE "$VENDORED" || true)
    [ "$skipped_md" = 0 ] || printf '  %s%s vendored file(s) not linted (%s)%s\n' \
      "$c_dim" "$skipped_md" "$VENDORED" "$c_off"
    md_out="$("${md_cmd[@]}" "${mdfiles[@]}" 2>&1)"
    md_rc=$?
    # Individual Finding lines are noise; keep Linting so a zero-issue summary
    # cannot be mistaken for a run that received zero input files.
    printf '%s\n' "$md_out" | grep -vE '^(markdownlint-cli2 v|Finding:)' | sed 's/^/  /'
    [ "$md_rc" = 0 ] || fail markdown
  else
    if [ -n "$markdownlint_problem" ]; then
      printf '%s  %s%s\n' "$c_red" "$markdownlint_problem" "$c_off"
      fail markdown
    else
      no_tool markdown markdownlint-cli2 "run: make lint-tools (one networked setup, shared by worktrees)"
    fi
  fi
fi

# --------------------------------------------------------------------- harness --
if wants harness; then
  head_of "harness (skills, links, fences, cross-doc)"
  args=""
  ((STRICT)) && args="--strict"
  python3 "$SELF_DIR/lint.py" $args || fail harness
fi

# ------------------------------------------------------------------- decisions --
# Реестры долговременных решений. Разваливаются одним способом: решение
# отменяют, а запись остаётся «в силе» — и тогда файл врёт убедительнее
# AGENTS.md, потому что у записи есть дата и статус, и им верят.
#
# Проверяется корневой реестр движка — каталог decisions/ (один файл на
# решение) или старый единый DECISIONS.md — и, отдельно, реестр команды.
# Командный реестр больше не лежит в этом репозитории: каталог knowledge/ уехал
# в отдельный knowledge-репозиторий, и его регистр проверяет собственный CI
# того репозитория. Здесь он проверяется только если его checkout уже есть
# локально — то есть у человека, а не в CI, где packages/ всегда пуст.
#
# Имя knowledge-репозитория берётся из repos.json тем же правилом, что и у
# skill `knowledge`: единственная запись из always с настроенным knowledgeRoot
# (включая корень checkout через ".") или legacy knowledge/. Константы здесь нет
# намеренно: переезд каталога не должен требовать правки линтера.
#
# Пустой список — не голый SKIPPED. «Пропущено» без причины читается как
# «проверять нечего», и ровно так 76 решений могут месяцами не проверяться
# ничем, пока строка выглядит безобидно.
if wants decisions; then
  head_of "decisions"

  decision_files=""
  if [ -d "$ROOT/decisions" ]; then
    decision_files="$ROOT/decisions"
  elif [ -f "$ROOT/DECISIONS.md" ]; then
    decision_files="$ROOT/DECISIONS.md"
  fi

  knowledge_repo=""
  knowledge_root=""
  knowledge_route=""
  if [ -f "$MANIFEST_REL" ]; then
    TMP_RESOLVE="$(mktemp)"
    if knowledge_route="$(python3 "$ROOT/agents/common/skills/knowledge/resolve.py" "$ROOT" --allow-missing 2>"$TMP_RESOLVE")"; then
      knowledge_repo="$(jq -r '.repo' <<<"$knowledge_route")"
      knowledge_root="$(jq -r '.root' <<<"$knowledge_route")"
    elif grep -q 'found: none$' "$TMP_RESOLVE"; then
      # Ни одного knowledge-репозитория — штатное состояние нового воркспейса:
      # о нём предупреждает ветка ниже, а не падение линта.
      :
    else
      cat "$TMP_RESOLVE" >&2
      fail decisions
    fi
    rm -f "$TMP_RESOLVE"
  fi

  team_registry=""
  if [ -n "$knowledge_repo" ] && [ -d "$ROOT/packages/$knowledge_repo/$knowledge_root/decisions" ]; then
    team_registry="$ROOT/packages/$knowledge_repo/$knowledge_root/decisions"
    decision_files="$decision_files $team_registry"
  fi

  if [ -z "$knowledge_repo" ]; then
    printf '%s  реестр решений команды НЕ проверен: %s не разрешает однозначный knowledgeRoot%s\n' \
      "$c_ylw" "$MANIFEST_REL" "$c_off"
    WARNED="$WARNED decisions"
  elif [ -z "$team_registry" ]; then
    printf '  %sреестр решений команды живёт в %s (%s/decisions/) и проверяется CI того репозитория; здесь не проверен — packages/%s/ не склонирован%s\n' \
      "$c_dim" "$knowledge_repo" "$knowledge_root" "$knowledge_repo" "$c_off"
  fi

  if [ -z "$decision_files" ]; then
    # Reported, not SKIPPED. Who owns the registry is already said above: either
    # the knowledge repository (whose own CI checks it) or nobody, and that
    # second case is the warning two branches up. A skip on top of that would
    # make --strict permanently red in every clone without packages/, which is
    # every fresh clone and every CI job.
    printf '  %sв этом репозитории своего decisions/ или DECISIONS.md нет — проверять здесь нечего%s\n' \
      "$c_dim" "$c_off"
  else
    # shellcheck disable=SC2086
    python3 "$ROOT/agents/common/skills/lint/check-decisions.py" $decision_files \
      || fail decisions
  fi
fi

# ----------------------------------------------------------------------- hooks --
# The one check here that RUNS something instead of reading it. The harness fails
# silently by nature: a hook whose rule stops matching leaves no lease and lets a
# secret into a transcript while its configuration still looks valid; a helper
# whose path resolution breaks answers plausibly and wrongly.
#
# Tests are DISCOVERED, not listed. A listed test is a test somebody has to
# remember to add here, and the failure mode of forgetting is invisible: the file
# sits in the repository looking like coverage while nothing runs it. That is not
# hypothetical — `agents/common/skills/clone/tests/test_origin_url.sh` lived
# here unreferenced until this discovery loop picked it up.
#
# Discovered locations:
#   agents/common/tests/*.test.py      behavior tests of hooks and libraries
#   agents/common/tests/*.test.sh
#   agents/common/skills/*/tests/*.sh  tests that live next to their skill
#   agents/common/skills/*/tests/*.py
#
# `.test.py`/`.test.sh` under tests/ and anything under skills/*/tests/ — the two
# conventions already present in the tree, kept both rather than renaming files
# and breaking whatever calls them by name.
if wants hooks; then
  head_of "behavior tests"

  if ! command -v jq > /dev/null 2>&1; then
    # jq is used by several of the tests and by the manifest helpers they call.
    no_tool hooks jq "brew install jq"
  fi

  behavior_tests() {
    local layer="$ROOT/agents/common"
    [ -d "$layer" ] || return 0
    find "$layer/tests" -maxdepth 1 -type f \( -name '*.test.py' -o -name '*.test.sh' \) 2>/dev/null
    find "$layer/skills" -mindepth 3 -maxdepth 3 -path '*/tests/*' -type f \
      \( -name '*.py' -o -name '*.sh' \) 2>/dev/null
  }

  found=0
  while IFS= read -r test_file; do
    [ -n "$test_file" ] || continue
    found=$((found + 1))
    rel="${test_file#"$ROOT"/}"

    case "$test_file" in
      *.py) runner=python3 ;;
      *.sh) runner=bash ;;
      *) continue ;;
    esac

    if [ ! -r "$test_file" ]; then
      printf '  %s: unreadable\n' "$rel" >&2
      fail hooks
      continue
    fi

    if "$runner" "$test_file" > /dev/null 2>&1; then
      printf '  %s: pass\n' "$rel"
    else
      printf '  %s: FAIL — rerun it directly to see why:\n    %s %s\n' \
        "$rel" "$runner" "$rel" >&2
      fail hooks
    fi
  done < <(behavior_tests | sort -u)

  if [ "$found" -eq 0 ]; then
    # Zero discovered tests means the discovery itself broke — the tree always
    # has some. Silence here would read as "everything passes".
    printf '  no behavior tests discovered — discovery is broken\n' >&2
    fail hooks
  else
    printf '  %d behavior test file(s) discovered and run\n' "$found"
  fi

  # A hook nobody tests. Warn, not fail: a hook can be trivial enough that a
  # test says nothing. What this catches is the other case — a hook whose
  # comment claims coverage that was never written, which is what happened to
  # a made-up hook name, and which no reader can tell from the real thing.
  # Matching is by file name inside the discovered tests, so a test that names
  # the hook it drives counts however it is written.
  untested=""
  layer="$ROOT/agents/common"
  if [ -d "$layer/hooks" ]; then
    for hook in "$layer/hooks"/*.sh; do
      [ -e "$hook" ] || continue
      base="$(basename "$hook")"
      if ! behavior_tests | sort -u | xargs -r grep -l -F -- "$base" > /dev/null 2>&1; then
        untested="$untested ${hook#"$ROOT"/}"
      fi
    done
  fi

  if [ -n "$untested" ]; then
    for hook in $untested; do
      printf '  %swarn   %s: no behavior test names this hook%s\n' "$c_ylw" "$hook" "$c_off"
    done
    WARNED="$WARNED hooks"
  fi
fi

# ---------------------------------------------------------------------- report --
printf '\n'
[ -n "$SKIPPED" ] && printf '%sskipped:%s%s\n' "$c_ylw" "$SKIPPED" "$c_off"
[ -n "$WARNED" ] && printf '%swarnings:%s%s\n' "$c_ylw" "$WARNED" "$c_off"

if [ -n "$FAILED" ]; then
  printf '%sFAILED:%s%s\n' "$c_red" "$FAILED" "$c_off"
  exit 1
fi
if ((STRICT)) && [ -n "$WARNED$SKIPPED" ]; then
  printf '%s--strict: warnings and skips count as failures%s\n' "$c_red" "$c_off"
  exit 1
fi
if [ -n "$WARNED$SKIPPED" ]; then
  printf '%slint completed with the warnings/skips reported above%s\n' "$c_ylw" "$c_off"
else
  printf '%slint clean%s\n' "$c_grn" "$c_off"
fi
