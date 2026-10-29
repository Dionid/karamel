#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  trace.sh --task <task> [--change <name>] [--print]

Writes the implementation trace of a task — per repo: the branch, the merge
request and every commit on that branch — into the task's OpenSpec change:

  worktrees/<task>/<spec-repo>/<specRoot>/openspec/changes/<change>/implementation.md

Everything is derived from git and the local coordination handoff, so the file
is fully regenerated on every run without GitHub API access.

  --task     the worktree task under worktrees/
  --change   change name; inferred when the change directory holds exactly one
  --print    write to stdout instead of the file (nothing is modified)
EOF
}

task=""
change=""
print_only=0

while (($# > 0)); do
  case "$1" in
    --task)
      task="${2:-}"
      shift 2
      ;;
    --change)
      change="${2:-}"
      shift 2
      ;;
    --print)
      print_only=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$task" ]]; then
  usage >&2
  exit 1
fi

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

find_workspace_root_bootstrap() {
  local dir
  dir="$(cd "$1" && pwd)"

  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/harness.json" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

# Резолвинг repos.json и общих git helpers — из core, через .claude/.
_bootstrap_root="$(find_workspace_root_bootstrap "$script_dir")"
_lib="$script_dir/../commit-and-mr/lib.sh"
if [[ ! -f "$_lib" ]]; then
  echo "error: not found: $_lib (run: ./ops sync)" >&2
  exit 1
fi
# shellcheck source=/dev/null
. "$_lib"

# find_real_workspace_root, а не find_workspace_root: чекаут внутри
# worktrees/<task>/<repo>/ может нести свой собственный symlink harness.json
# (кладёт его тулинг самого этого репозитория, чтобы резолвить свой корень), и
# резолвер, который останавливается на первом найденном, принял бы этот
# вложенный чекаут за корень воркспейса.
workspace_root="$(find_real_workspace_root "$script_dir")"

# Поиск чекаута спек и путь внутри него — в общей библиотеке, потому что тот же
# ответ нужен spec-ref.sh. Читается изнутри spec-checkout-lib.sh,
# поэтому для shellcheck, который видит только этот файл, выглядит неиспользуемой.
# shellcheck disable=SC2034
WORKSPACE_ROOT="$workspace_root"
# shellcheck source=spec-checkout-lib.sh
. "$script_dir/spec-checkout-lib.sh"

task_dir="$workspace_root/worktrees/$task"

if [[ ! -d "$task_dir" ]]; then
  echo "error: no such task worktree: worktrees/$task" >&2
  exit 1
fi

# The spec repo is whichever candidate repo carries the spec marker directory in
# this worktree — see spec-checkout-lib.sh, which also searches the two layouts a
# task can have (`worktrees/<task>/<repo>` and the stepped
# `worktrees/<task>/<step>/<repo>`) and resolves the project level inside the
# checkout. A stepped task searched one level deep finds nothing and dies with
# "no OpenSpec changes directory" while the checkouts it would have traced sit
# right there; passing `--task <task>/<step>` is not the fix, since it narrows
# the checkout scan below to that one step and the trace then names a subset of
# the repos while reading as complete.
# Код 2 — не «нет спеки», а «их несколько и неизвестно, чья эта»: ответ на
# него разный, поэтому сообщения тоже разные. Подсказку про субъект уже
# напечатала сама функция.
find_rc=0
spec_repo="$(find_spec_checkout "$task_dir")" || find_rc=$?

if [[ "$find_rc" -eq 2 ]]; then
  exit 2
fi

if [[ "$find_rc" -ne 0 ]]; then
  echo "error: no spec repository configured — no repos.json entry with a specRoot (or an 'always' entry) has an OpenSpec checkout in worktrees/$task" >&2
  exit 1
fi

spec_prefix="$(spec_prefix_for "$spec_repo")"
spec_dir="$task_dir/$spec_repo"
changes_dir="$spec_dir/$spec_prefix/changes"

if [[ ! -d "$changes_dir" ]]; then
  echo "error: no OpenSpec changes directory: $changes_dir" >&2
  echo "hint: the trace belongs to a change with spec artifacts; a task without one has nothing to write it into" >&2
  exit 1
fi

if [[ -z "$change" ]]; then
  found=""
  count=0

  while read -r dir; do
    [[ -n "$dir" ]] || continue
    name="$(basename "$dir")"
    [[ "$name" != "archive" ]] || continue
    found="$name"
    count=$((count + 1))
  done < <(find "$changes_dir" -mindepth 1 -maxdepth 1 -type d | sort)

  if ((count != 1)); then
    echo "error: cannot infer the change ($count active in $changes_dir) — pass --change" >&2
    exit 1
  fi

  change="$found"
fi

change_dir="$changes_dir/$change"

if [[ ! -d "$change_dir" ]]; then
  echo "error: no such change: $spec_prefix/changes/$change" >&2
  exit 1
fi

out_file="$(mktemp)"

cleanup() {
  rm -f "$out_file"
}

trap cleanup EXIT

mr_cell=""
mr_target=""

# mr_for <relative-checkout> — read the MR URL recorded by commit-and-mr.
mr_for() {
  local checkout record url iid state
  checkout="worktrees/$task/$1"
  mr_cell=""
  mr_target=""
  for record in "$workspace_root"/.coordination/tasks/*.json; do
    [[ -f "$record" ]] || continue
    # A stepped checkout belongs to task `<task>/<step>`, while this trace is
    # generated for the parent task and lists all of its stepped repos. Match
    # both identities; the checkout key below still prevents an unrelated
    # descendant record from being selected.
    jq -e --arg task "$task" \
      '.task == $task or (.task | startswith($task + "/"))' \
      "$record" >/dev/null 2>&1 || continue
    url="$(jq -r --arg checkout "$checkout" '.repos[$checkout].mrUrl // empty' "$record")"
    state="$(jq -r --arg checkout "$checkout" '.repos[$checkout].mrState // "recorded"' "$record")"
    [[ -n "$url" ]] || continue
    mr_target="$(jq -r --arg checkout "$checkout" '.repos[$checkout].targetBranch // empty' "$record")"
    iid="$(sed -n 's#.*/pull/\([0-9][0-9]*\).*#\1#p' <<<"$url")"
    if [[ -n "$iid" ]]; then
      mr_cell="[!$iid]($url) · $state"
    else
      mr_cell="[$url]($url) · $state"
    fi
    return 0
  done
}

# Every repo of the task, alphabetically, with the spec repo last: it is the one
# being committed when this file is written, so it always trails by a commit.
#
# Two levels are scanned, not one. `wt new` puts a checkout at
# `worktrees/<task>/<repo>`, but a task whose branches are stepped —
# adopted from a branch that carries its own step in the name — lands at
# `worktrees/<task>/<step>/<repo>`. A one-level scan finds no code repo at all
# there and writes a trace naming only the spec, which is exactly the case the
# trace exists to prevent. The step directory itself is not a checkout (no
# `.git`), so it is skipped by the same test and cannot be mistaken for one.
#
# What is collected is the path RELATIVE to the task dir, because `repos.json` is
# keyed by repo name while git needs the full path — the loop below splits them
# again. A stepped task may hold the same repo twice (two steps, two branches),
# so the relative path is also what keeps those rows distinguishable.
repos=""

for dir in "$task_dir"/*/ "$task_dir"/*/*/; do
  [[ -d "$dir" ]] || continue
  [[ -e "$dir/.git" ]] || continue

  rel="${dir#"$task_dir"/}"
  rel="${rel%/}"

  [[ "$rel" != "$spec_repo" ]] || continue

  repos="$repos $rel"
done

if [[ -e "$spec_dir/.git" ]]; then
  repos="$repos $spec_repo"
fi

{
  printf '# Реализация\n\n'
  printf 'Change: `%s` · задача (worktree): `%s`\n\n' "$change" "$task"
  printf 'Файл генерирует `.claude/skills/spec-trace/trace.sh` из рабочего\n'
  printf 'пространства — он переписывается целиком, правки руками пропадут.\n'
  printf 'Порядок выката репозиториев задаёт `tasks.md`, раздел `## Порядок релиза`.\n\n'
  printf '## Ветки и MR\n\n'
  printf '| Репозиторий | Ветка | Целевая ветка | MR |\n'
  printf '| --- | --- | --- | --- |\n'
} > "$out_file"

commits_section="$(mktemp)"
trap 'cleanup; rm -f "$commits_section"' EXIT

printf '\n## Коммиты\n' > "$commits_section"

for rel in $repos; do
  dir="$task_dir/$rel"

  # `rel` may be `<repo>` or `<step>/<repo>`; `repos.json` and the label want
  # different halves of that. The name is what the manifest is keyed by; the
  # label keeps the step when there is one, so two steps of the same repo do not
  # collapse into two identical rows.
  name="$(basename "$rel")"
  label="$rel"

  branch="$(git -C "$dir" branch --show-current 2>/dev/null || true)"

  if [[ -z "$branch" ]]; then
    branch="(detached)"
  fi

  base="$(repo_branch "$name")"

  mr_for "$rel"

  mr="$mr_cell"

  if [[ -z "$mr" ]]; then
    mr="—"
  fi

  # A stacked MR's real target is not the base from repos.json, and the commit
  # range below must follow the MR, not the manifest: measured against the
  # default branch a stacked branch replays the whole stack it sits on.
  display_base="$base"
  if [[ -n "$mr_target" ]]; then
    base="$mr_target"
    display_base="$mr_target"
  elif [[ "$mr" != "—" ]]; then
    # A record without a target (written before commit-and-mr asked gh for it,
    # or by hand) has no observable target. Do not claim that the manifest
    # default is its actual comparison base.
    base=""
    display_base="unknown"
  fi

  printf '| %s | `%s` | `%s` | %s |\n' "$label" "$branch" "$display_base" "$mr" >> "$out_file"

  printf '\n### %s — `%s`\n\n' "$label" "$branch" >> "$commits_section"

  range=""

  if [[ -n "$base" ]] && git -C "$dir" rev-parse --verify --quiet "origin/$base" > /dev/null; then
    range="origin/$base..HEAD"
  elif [[ -n "$base" ]] && git -C "$dir" rev-parse --verify --quiet "$base" > /dev/null; then
    range="$base..HEAD"
  fi

  if [[ -z "$range" ]]; then
    if [[ -z "$base" ]]; then
      printf '_target branch MR не записана в coordination — история не построена_\n' >> "$commits_section"
    else
      printf '_база `%s` не найдена в чекауте — история не построена_\n' "$base" >> "$commits_section"
    fi
    continue
  fi

  log="$(git -C "$dir" log --no-merges --date=short --pretty=format:'- `%h` %ad %s' "$range")"

  if [[ -z "$log" ]]; then
    printf '_нет коммитов поверх `%s`_\n' "$base" >> "$commits_section"
  else
    printf '%s\n' "$log" >> "$commits_section"
  fi
done

cat "$commits_section" >> "$out_file"

printf '\n_Коммит, которым записан этот файл, в списке `%s` ещё не виден._\n' \
  "$spec_repo" >> "$out_file"

if ((print_only)); then
  cat "$out_file"
  exit 0
fi

cp "$out_file" "$change_dir/implementation.md"

printf 'TRACE_FILE=%s\n' "worktrees/$task/$spec_repo/$spec_prefix/changes/$change/implementation.md"
printf 'TRACE_REPOS=%s\n' "${repos# }"
