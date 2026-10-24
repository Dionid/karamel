#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  spec-ref.sh (--worktree <path> | --task <task>) [--change <name>]
              [--block | --markdown]

Answers "which spec was the code on this branch written against" for a checkout
under worktrees/<task>/: the spec repo checkout, its branch, the OpenSpec change,
and the merge request that carries it.

  --worktree   any checkout of the task, at any depth (default: cwd)
  --task       the task under worktrees/, when no checkout is at hand
  --change     the change name, when the task has more than one active
  --block      print the managed markdown block for an MR description
  --markdown   print a short human-readable pointer instead of KEY=value

Default output is KEY=value lines:

  SPEC_STATE          ok | untouched | no-spec-repo
  SPEC_TASK           the task
  SPEC_REPO           the spec checkout, relative to worktrees/<task>/
  SPEC_DIR            the same, relative to the workspace root
  SPEC_BRANCH         the branch the spec sits on
  SPEC_PROJECT        the GitHub project path of the spec repo
  SPEC_CHANGE         the OpenSpec change, empty when the task has none
  SPEC_CHANGE_PATH    <specRoot>/openspec/changes/<change>, empty likewise
  SPEC_SPECS          edited <specRoot>/openspec/specs/... paths, space separated
  SPEC_MR_URL         the spec MR, empty when it is not open yet
  SPEC_MR_STATE       state last recorded in local coordination, or none

A missing spec MR is normal and not an error: the code repos are committed before
the spec repo, so at that moment the MR may not exist yet.

no-spec-repo means this task carries no spec checkout at all — there is nothing
to point at, and this is not an error.

Several spec stores in one task (a product with its own store next to the shared
one) is a different case: the address then follows the subject of the change, not
the manifest, so this script refuses with exit 2 instead of picking one. Name the
subject with SPEC_SUBJECT_REPO=<repo> or ask the user.
EOF
}

worktree=""
task=""
change=""
mode="env"

while (($# > 0)); do
  case "$1" in
    --worktree)
      worktree="${2:-}"
      shift 2
      ;;
    --task)
      task="${2:-}"
      shift 2
      ;;
    --change)
      change="${2:-}"
      shift 2
      ;;
    --block)
      mode="block"
      shift
      ;;
    --markdown)
      mode="markdown"
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

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# lib.sh (shared GitHub URL/gh helpers, managed blocks, repos_manifest) belongs to
# the commit-and-mr skill in core; the spec side — which checkout holds the
# spec — is local, in spec-checkout-lib.sh, because that is the part a
# different spec framework changes. Found through .claude/, so the layer it
# comes from does not matter here.
_root="$script_dir"
while [[ "$_root" != "/" && ! -f "$_root/harness.json" ]]; do _root="$(dirname "$_root")"; done
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
if ! WORKSPACE_ROOT="$(find_real_workspace_root "${worktree:-$script_dir}")"; then
  echo "error: no workspace harness.json above ${worktree:-$script_dir}" >&2
  exit 1
fi

# shellcheck source=spec-checkout-lib.sh
. "$script_dir/spec-checkout-lib.sh"

if [[ -z "$worktree" && -z "$task" ]]; then
  worktree="$(pwd)"
fi

near_dir=""

if [[ -n "$worktree" ]]; then
  if [[ ! -d "$worktree" ]]; then
    echo "error: no such directory: $worktree" >&2
    exit 1
  fi

  worktree="$(cd "$worktree" && pwd)"
  rel="${worktree#"$WORKSPACE_ROOT"/}"

  case "$rel" in
    worktrees/*/*)
      task="${rel#worktrees/}"
      task="${task%%/*}"
      near_dir="$(dirname "$worktree")"
      ;;
    worktrees/*)
      task="${rel#worktrees/}"
      ;;
    *)
      if [[ -z "$task" ]]; then
        echo "error: not a checkout under worktrees/<task>/: $rel" >&2
        exit 1
      fi
      ;;
  esac
fi

task_dir="$WORKSPACE_ROOT/worktrees/$task"

if [[ ! -d "$task_dir" ]]; then
  echo "error: no such task worktree: worktrees/$task" >&2
  exit 1
fi

report() {
  printf 'SPEC_STATE=%s\n' "$1"
  printf 'SPEC_TASK=%s\n' "$task"
  printf 'SPEC_REPO=%s\n' "${spec_repo-}"
  printf 'SPEC_DIR=%s\n' "${spec_dir_rel-}"
  printf 'SPEC_BRANCH=%s\n' "${spec_branch-}"
  printf 'SPEC_PROJECT=%s\n' "${spec_project-}"
  printf 'SPEC_CHANGE=%s\n' "${change-}"
  printf 'SPEC_CHANGE_PATH=%s\n' "${change_path-}"
  printf 'SPEC_SPECS=%s\n' "${spec_specs-}"
  printf 'SPEC_MR_URL=%s\n' "${MR_URL-}"
  printf 'SPEC_MR_STATE=%s\n' "${mr_state-}"
}

# Отказ find_spec_checkout разделён по коду: 1 — store в задаче нет, это
# нормальное состояние; 2 — их несколько и субъект не назван, и это обязан
# увидеть вызывающий. Свести второе к нейтральному no-spec-repo значило бы
# тихо потерять ссылку на спеку там, где она как раз есть.
find_rc=0
spec_repo="$(find_spec_checkout "$task_dir" "$near_dir")" || find_rc=$?

if [[ "$find_rc" -eq 2 ]]; then
  exit 2
fi

if [[ "$find_rc" -ne 0 ]]; then
  if [[ "$mode" == "env" ]]; then
    report "no-spec-repo"
  fi
  exit 0
fi

spec_dir="$task_dir/$spec_repo"
spec_dir_rel="worktrees/$task/$spec_repo"
spec_name="$(basename "$spec_repo")"

# Где спека лежит ВНУТРИ чекаута: `openspec` или `<specRoot>/openspec`, по полю
# specRoot этого репозитория в манифесте. Всё ниже адресуется отсюда — в чужом
# форке корневой `openspec/` тоже может существовать, и литеральный путь
# нашёлся бы, просто указывал бы на другое дерево.
spec_prefix="$(spec_prefix_for "$spec_repo")"
spec_branch="$(git -C "$spec_dir" branch --show-current 2>/dev/null || true)"
spec_base="$(repo_branch "$spec_name")"

if proj_of "$spec_dir"; then
  spec_project="$PROJ_PATH"
fi

# Everything below judges this branch by its OWN diff against $spec_base, never
# by what merely sits in the working tree. The shared spec repo's default
# branch routinely carries several other tasks' unarchived active changes —
# a task that never touched a change directory at all (the common "no spec
# impact" case) must not trip the same "several active changes, pass --change"
# refusal as a genuine conflict.
range=""

if git -C "$spec_dir" rev-parse --verify --quiet "origin/$spec_base" > /dev/null; then
  range="origin/$spec_base...HEAD"
fi

own_changes_list=""

if [[ -z "$change" && -n "$range" ]]; then
  own_changes_list="$(
    {
      git -C "$spec_dir" diff --name-only "$range" -- "$spec_prefix/changes" 2>/dev/null || true
      git -C "$spec_dir" status --porcelain -uall -- "$spec_prefix/changes" 2>/dev/null | cut -c4- || true
    } | while read -r path; do
      [[ -n "$path" ]] || continue
      rel="${path#"$spec_prefix"/changes/}"
      [[ "$rel" != "$path" ]] || continue # outside changes/ entirely
      name="${rel%%/*}"
      [[ "$name" != "archive" ]] || continue
      printf '%s\n' "$name"
    done | sort -u
  )"
fi

if [[ -z "$change" ]]; then
  own_changes_count="$(printf '%s' "$own_changes_list" | grep -c . || true)"

  if ((own_changes_count == 1)); then
    change="$own_changes_list"
  elif ((own_changes_count > 1)); then
    # This branch's own diff touches more than one change directory — a
    # genuine conflict, unlike the false positive above, so --change is still
    # required.
    {
      echo "error: this branch touches $own_changes_count change directories in $spec_prefix/changes — pass --change to pick one"
      printf '%s\n' "$own_changes_list" | sed 's/^/  - /'
    } >&2
    exit 1
  fi
  # Zero means this branch's own diff touches no change directory — not an
  # error, handled by the "untouched" check below like any other case with
  # nothing to point at.
fi

change_path=""

if [[ -n "$change" ]]; then
  if [[ ! -d "$spec_dir/$spec_prefix/changes/$change" ]]; then
    echo "error: no such change: $spec_prefix/changes/$change in $spec_dir_rel" >&2
    exit 1
  fi
  change_path="$spec_prefix/changes/$change"
fi

# Which capability specs this branch edits — the case where a change directory
# does not exist and a reviewer amends specs/<capability>/spec.md directly.
spec_specs=""

specs_list="$(mktemp)"
trap 'rm -f "$specs_list"' EXIT

{
  if [[ -n "$range" ]]; then
    git -C "$spec_dir" diff --name-only "$range" -- "$spec_prefix/specs" 2>/dev/null || true
  fi
  # -uall, or an untracked capability collapses to the bare `<specRoot>/openspec/specs/`
  # directory and the pointer names no spec at all.
  git -C "$spec_dir" status --porcelain -uall -- "$spec_prefix/specs" 2>/dev/null | cut -c4- || true
} | sort -u > "$specs_list" || true

spec_specs="$(tr '\n' ' ' < "$specs_list" | sed 's/ *$//')"

# Untouched means there is nothing on this branch to point at: no change
# directory, no edited spec, no commits of its own. Saying so is the point —
# a task whose spec repo is clean has no spec link, and inventing one would
# send the next agent to read the default branch instead.
has_commits=0

if [[ -n "$range" ]] && [[ -n "$(git -C "$spec_dir" log --oneline "origin/$spec_base..HEAD" 2>/dev/null || true)" ]]; then
  has_commits=1
fi

if [[ -z "$change" && -z "$spec_specs" && $has_commits -eq 0 ]]; then
  if [[ "$mode" == "env" ]]; then
    report "untouched"
  fi
  exit 0
fi

mr_state="none"
spec_mr=""
for record in "$WORKSPACE_ROOT"/.coordination/tasks/*.json; do
  [[ -f "$record" ]] || continue
  jq -e --arg task "$task" '.task == $task' "$record" >/dev/null 2>&1 || continue
  spec_mr="$(jq -r --arg checkout "$spec_dir_rel" '.repos[$checkout].mrUrl // empty' "$record")"
  mr_state="$(jq -r --arg checkout "$spec_dir_rel" '.repos[$checkout].mrState // "recorded"' "$record")"
  break
done

case "$mode" in
  env)
    report "ok"
    ;;
  markdown|block)
    if [[ "$mode" == "block" ]]; then
      printf '%s\n' "$SPEC_BLOCK_START"
    fi

    printf '### Спека\n\n'

    if [[ -n "$change" ]]; then
      printf -- '- **Change:** `%s`\n' "$change_path"
    fi

    if [[ -n "$spec_specs" ]]; then
      printf -- '- **Правки в спеках:**'
      for path in $spec_specs; do
        printf ' `%s`' "$path"
      done
      printf '\n'
    fi

    if [[ -n "$spec_mr" ]]; then
      printf -- '- **MR спеки:** %s\n' "$spec_mr"
    else
      printf -- '- **MR спеки:** _ещё не открыт или URL не записан в coordination_\n'
    fi

    printf -- '- **Ветка спеки:** `%s` @ `%s`\n' "${spec_project:-$spec_name}" "${spec_branch:-?}"
    printf '\n'
    printf 'Прежде чем править код в этой ветке, прочитай спеку — требуемое поведение\n'
    printf 'описывает она, а не этот MR. Локально:\n\n'
    printf '```bash\n'
    printf '.claude/skills/spec-trace/spec-ref.sh --task %s --markdown\n' "$task"
    printf '```\n'

    if [[ "$mode" == "block" ]]; then
      printf '%s\n' "$SPEC_BLOCK_END"
    fi
    ;;
esac
