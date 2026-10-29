#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  run.sh --worktree <path> --repo <name> --message-file <path>
         (--mr-description-file <path> | --existing-mr | --no-mr)
         [--mr-title <title>] [--draft] [--no-coauthor]
         [--spec-change <name>] [--no-spec-link] [--no-task-link]
         [--transport auto|https]
         -- <path>...
  run.sh --worktree <path> --repo <name> --existing-mr
         --mr-description-file <path> --description-only
         [--spec-change <name>] [--no-spec-link] [--no-task-link]

Stages selected paths, commits, pushes over HTTPS with GITHUB_TOKEN and
opens or updates a Draft GitHub pull request through gh. Only github.com is
supported. Process GITHUB_TOKEN wins over the root .env; GH_TOKEN is mirrored
from it for each command. Missing credentials fail before staging.

When the workspace has a spec side (spec-ref.sh, from the config repo), the
commit gets a `Spec:` trailer and the PR description a block naming the spec this
branch implements. A known spec PR link comes from the local coordination record.
Without spec-ref.sh both are simply omitted.

What happens to the PR is settled before anything is staged or committed:

  --mr-description-file   the description of the PR. Must pass mr-description's
                          check (the sections of mr-description/template.md, all
                          filled in). Alone: open a new Draft PR with it (or, when
                          the branch already has an open PR, replace that PR's
                          description). With --existing-mr: replace the
                          description of the branch's open PR
  --existing-mr           the branch already has an open PR (for example a
                          review-fix round): push to it and report it, never open
                          one. No open PR found -> MR_STATE=not-created
  --no-mr                 commit and push only; print the prefilled "new PR" URL.
                          Excludes the other two
  --description-only      with --existing-mr and --mr-description-file: only
                          replace the open PR's description — no paths, no
                          --message-file, nothing staged, committed or pushed.
                          No open PR -> MR_STATE=not-created, exit 1

  --mr-title              PR title (default: the commit subject)
  --draft                 keep the default: create the PR as a draft
  --no-coauthor           do not append the Co-Authored-By trailer
  --spec-change           the change name, when the task has more than one active
  --no-spec-link          do not reference the spec in the commit or the PR
  --no-task-link          do not add the task block (author and the task's
                          other PRs) to the description, and do not refresh it
                          in the task's other open PRs afterwards
  --transport             https or auto (both use HTTPS only).

A description file may carry the managed spec-link/task-link blocks (one read
back with `gh pr view`): they are dropped before the check and rendered anew.
EOF
}

worktree=""
repo=""
message_file=""
mr_title=""
mr_description_file=""
existing_mr=0
with_coauthor=1
create_mr=1
draft=1
spec_change=""
spec_link=1
task_link=1
description_only=0
transport=""

while (($# > 0)); do
  case "$1" in
    --worktree)
      worktree="${2:-}"
      shift 2
      ;;
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --message-file)
      message_file="${2:-}"
      shift 2
      ;;
    --mr-title)
      mr_title="${2:-}"
      shift 2
      ;;
    --mr-description-file)
      mr_description_file="${2:-}"
      shift 2
      ;;
    --existing-mr)
      existing_mr=1
      shift
      ;;
    --draft)
      draft=1
      shift
      ;;
    --no-mr)
      create_mr=0
      shift
      ;;
    --no-coauthor)
      with_coauthor=0
      shift
      ;;
    --spec-change)
      spec_change="${2:-}"
      shift 2
      ;;
    --no-spec-link)
      spec_link=0
      shift
      ;;
    --no-task-link)
      task_link=0
      shift
      ;;
    --description-only)
      description_only=1
      shift
      ;;
    --transport)
      transport="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

case "$transport" in
  '') ;;
  auto|https)
    # The library reads the request from the environment, so wt-style callers
    # and this run take the same path.
    export GL_TRANSPORT_PREFER="$transport"
    ;;
  *)
    echo "error: --transport must be auto or https, got: $transport" >&2
    exit 1
    ;;
esac

if ((description_only)); then
  # Nothing is committed, so there is nothing to stage and no message: a path or
  # a message file here means the caller expected a commit that will not happen.
  if [[ -z "$worktree" || -z "$repo" || -z "$mr_description_file" ]] || ((existing_mr == 0)); then
    echo "error: --description-only needs --worktree, --repo, --existing-mr and --mr-description-file" >&2
    usage >&2
    exit 1
  fi
  if ((create_mr == 0)) || [[ -n "$message_file" ]] || (($# > 0)); then
    echo "error: --description-only commits nothing: it excludes --no-mr, --message-file and paths" >&2
    exit 1
  fi
elif [[ -z "$worktree" || -z "$repo" || -z "$message_file" || $# -eq 0 ]]; then
  usage >&2
  exit 1
fi

if [[ ! -d "$worktree" ]]; then
  echo "error: no such directory: $worktree" >&2
  exit 1
fi

if [[ ! -d "$worktree/.git" && ! -f "$worktree/.git" ]]; then
  echo "error: worktree is not a git checkout: $worktree" >&2
  exit 1
fi

# `.claude/`, so this works in a checkout with no generated tree (CI) as well as
# in a workspace. gl_load is deliberately NOT called here in this shell — see
# the pre-commit check and the push below.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Absolute, so the checks below don't depend on the caller's cwd.
worktree="$(cd "$worktree" && pwd)"

# The same resolver as preflight.sh: the real root first, not the first
# harness.json above — a checkout under worktrees/ that once ran `./ops sync`
# carries a harness.json of its own and would otherwise be taken for the root,
# failing the worktrees/<task>/ check below — then the nearest harness.json for a
# workspace that itself sits under some worktrees/ directory.
if ! workspace_root="$(find_workspace_root "$worktree")"; then
  echo "error: no harness.json above $worktree — not a checkout of this workspace" >&2
  exit 1
fi

worktree_rel="${worktree#"$workspace_root"/}"

# Any depth under the task dir is fine — tasks may nest (worktrees/<task>/<step>/<repo>).
case "$worktree_rel" in
  packages/*)
    echo "error: refusing to commit from packages/: $worktree_rel" >&2
    exit 1
    ;;
  worktrees/*/*)
    ;;
  *)
    echo "error: worktree must be under worktrees/<task>/, got: $worktree_rel" >&2
    exit 1
    ;;
esac

task_rel="${worktree_rel#worktrees/}"
task_name="${task_rel%/$repo}"

if ((description_only == 0)) && [[ ! -f "$message_file" ]]; then
  echo "error: message file not found: $message_file" >&2
  exit 1
fi

if ((description_only == 0)) && [[ ! -s "$message_file" ]]; then
  echo "error: message file is empty: $message_file" >&2
  exit 1
fi

# Temporary files of this run, removed on any exit.
tmp_files=()
cleanup() {
  ((${#tmp_files[@]} == 0)) || rm -f "${tmp_files[@]}"
}
trap cleanup EXIT

# The PR description is settled here, before anything is staged: a run that
# fails on it later has already made the commit, and run.sh cannot be re-run
# over a commit it made — there is nothing left to stage.
if ((create_mr == 0)) && { [[ -n "$mr_description_file" ]] || ((existing_mr)); }; then
  echo "error: --no-mr excludes --mr-description-file and --existing-mr" >&2
  exit 1
fi

if ((create_mr == 1)) && [[ -z "$mr_description_file" ]] && ((existing_mr == 0)); then
  echo "error: no PR description. A new PR is never opened without one: draft it per" >&2
  echo "  .claude/skills/mr-description/template.md and pass --mr-description-file <path>." >&2
  echo "  Pushing to a branch whose PR is already open: --existing-mr. Push only: --no-mr." >&2
  exit 1
fi

if [[ -n "$mr_description_file" ]]; then
  if [[ ! -f "$mr_description_file" ]]; then
    echo "error: PR description file not found: $mr_description_file" >&2
    exit 1
  fi

  # The managed blocks are this script's to render, so a description read back
  # (which rejects them in an authored body), and the fresh ones are added below.
  mr_description_body="$(mktemp)"
  tmp_files+=("$mr_description_body")
  if ! mr_description_strip_managed "$mr_description_file" "$mr_description_body"; then
    echo "error: cannot separate the managed blocks from the PR description (above). Nothing is staged or committed." >&2
    exit 1
  fi
  if ((MR_DESCRIPTION_STRIPPED > 0)); then
    echo "note: dropped $MR_DESCRIPTION_STRIPPED managed spec-link/task-link block(s) from $mr_description_file — they are rendered anew" >&2
  fi

  if ! mr_description_check "$mr_description_body"; then
    echo "error: the PR description is incomplete (DESCRIPTION_ERROR lines above); sections, in order:" >&2
    printf '  ## %s\n' "${MR_DESCRIPTION_SECTIONS[@]}" >&2
    echo "  — template: .claude/skills/mr-description/template.md. Nothing is staged or committed." >&2
    exit 1
  fi
fi

branch="$(git -C "$worktree" branch --show-current)"

if [[ -z "$branch" ]]; then
  echo "error: detached HEAD in $worktree" >&2
  exit 1
fi

case "$branch" in
  main|master|development|dev)
    echo "error: refusing to push base branch: $branch" >&2
    exit 1
    ;;
esac

remote="$(git -C "$worktree" remote get-url origin)"

# from means the PR can never be opened, and finding that out after the push
# leaves a branch on the remote with nothing pointing at it.
if ! proj_from_url "$remote"; then
  echo "error: cannot derive a GitHub project from the origin of $worktree_rel" >&2
  exit 1
fi

proj="$PROJ_PATH"

# The PR target: the repo's base from repos.json, or the personal base
# <owner>-<base> for a "personalBase" repo with an owner — one resolver for wt,
# adopt.sh, preflight.sh, task-link.sh and spec-trace (lib.sh).
base="$(resolve_task_base "$workspace_root" "$repo")" || exit 1

# The personal base is a base branch too: work reaches it only through a PR.
if [[ "$branch" == "$base" ]]; then
  echo "error: refusing to push base branch: $branch" >&2
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Which spec does the code on this branch implement. Resolved before the commit,
# so the answer can ride in the commit message — the PR description is editable
# and the PR itself can be recreated, the trailer on the commit cannot be lost.
spec_ref=""
spec_state="skipped"
spec_change_name=""
spec_mr_url=""
spec_branch=""
spec_project=""
spec_change_path=""

# The spec side is OPTIONAL and lives in the config repo: a team may use any spec
# framework, several spec repos, or none. Core knows only two things about it —
# where spec-ref.sh would be if it exists, and what directory marks a checkout as
# the spec one (SPEC_MARKER_DIR, so a non-OpenSpec layout is a variable, not a
# fork). No spec-ref.sh means the state stays "skipped" rather than becoming
# "unresolved", which would claim there is a spec nobody could resolve.
spec_ref_sh="$workspace_root/.claude/skills/spec-trace/spec-ref.sh"
spec_marker_dir="${SPEC_MARKER_DIR:-openspec}"

# The spec checkout does not link to itself.
if ((spec_link)) && [[ -x "$spec_ref_sh" && ! -d "$worktree/$spec_marker_dir" ]]; then
  spec_args=(--worktree "$worktree")
  [[ -z "$spec_change" ]] || spec_args+=(--change "$spec_change")

  # Код 2 — отдельное состояние, а не общий провал: в задаче несколько spec
  # store, и какой из них субъект этого изменения, скрипт не решает. Своё
  # сообщение с подсказкой он уже напечатал, поэтому stderr здесь пропускается
  # наружу: заглушённое, оно оставляло бы «unresolved» без единой причины.
  spec_rc=0
  spec_err_file="$(mktemp)"
  spec_ref="$("$spec_ref_sh" "${spec_args[@]}" 2>"$spec_err_file")" || spec_rc=$?

  if ((spec_rc == 0)); then
    spec_state="$(printf '%s\n' "$spec_ref" | sed -n 's/^SPEC_STATE=//p')"
    spec_change_name="$(printf '%s\n' "$spec_ref" | sed -n 's/^SPEC_CHANGE=//p')"
    spec_mr_url="$(printf '%s\n' "$spec_ref" | sed -n 's/^SPEC_MR_URL=//p')"
    spec_branch="$(printf '%s\n' "$spec_ref" | sed -n 's/^SPEC_BRANCH=//p')"
    spec_project="$(printf '%s\n' "$spec_ref" | sed -n 's/^SPEC_PROJECT=//p')"
    # Optional: where the change lives inside the spec repo. The layout belongs
    # to the spec framework, so the path is reported by spec-ref.sh rather than
    # assembled here.
    spec_change_path="$(printf '%s\n' "$spec_ref" | sed -n 's/^SPEC_CHANGE_PATH=//p')"
  elif ((spec_rc == 2)); then
    spec_state="ambiguous"
    cat "$spec_err_file" >&2
  else
    spec_state="unresolved"
  fi

  rm -f "$spec_err_file"
fi

# Validate token access before staging, in a subshell so root .env credentials
# cannot reach repository commit hooks. A local mirror in --no-mr needs no gh.
push_url="$(gl_origin_raw_url "$worktree" push)"
need_remote=1
if ((create_mr == 0)); then
  case "$push_url" in file://*|/*|./*|../*) need_remote=0 ;; esac
fi
if ! gl_origin_projects_match "$worktree"; then
  echo "error: origin must have one matching GitHub fetch/push destination; nothing staged or committed" >&2
  exit 1
fi
mr_transport=none
if ((need_remote)); then
  gh_rc=0
  (gl_load "$workspace_root" && gl_require_gh "$PROJ_HOST") || gh_rc=$?
  if ((gh_rc)); then
    printf 'MR_STATE=not-created\n'
    ((gh_rc != 3)) || printf 'NEXT=github-login\n'
    exit "$gh_rc"
  fi
  ((create_mr == 0)) || mr_transport=https-gh
fi

# --description-only stops short of everything below up to the PR lookup: no
# staging, no commit, no push. The checks above (description, branch, origin,
if ((description_only == 0)); then
  git -C "$worktree" add -- "$@"

  if [[ -z "$(git -C "$worktree" diff --cached --stat)" ]]; then
    echo "error: nothing staged after git add" >&2
    exit 1
  fi

  commit_message_file="$message_file"

  # One trailer block, both trailers in it — git only recognises them as trailers
  # when they sit together at the end with no prose after them.
  if ((with_coauthor)) || [[ "$spec_state" == "ok" ]]; then
    commit_message_file="$(mktemp)"
    tmp_files+=("$commit_message_file")
    cp "$message_file" "$commit_message_file"
    printf '\n' >> "$commit_message_file"

    if [[ "$spec_state" == "ok" ]]; then
      # The path inside the spec repo comes from spec-ref.sh when it reports one;
      # otherwise the change name alone still identifies it.
      spec_suffix=""
      if [[ -n "$spec_change_path" ]]; then
        spec_suffix=" $spec_change_path"
      elif [[ -n "$spec_change_name" ]]; then
        spec_suffix=" $spec_change_name"
      fi

      printf 'Spec: %s@%s%s\n' \
        "${spec_project:-spec}" \
        "${spec_branch:-?}" \
        "$spec_suffix" \
        >> "$commit_message_file"
    fi

    if ((with_coauthor)); then
      printf 'Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>\n' >> "$commit_message_file"
    fi
  fi

  # A git commit carries two identities, and only one of them was ever set here.
  # GIT_AUTHOR_EMAIL, which git uses for the AUTHOR on its own; the COMMITTER was
  # left to fall through to the checkout's git config — in this runtime a single
  # shared ~/.gitconfig naming the agent, not the person. The two then disagree,
  # the commit is already made, which run.sh cannot be re-run over.
  #
  # Exported rather than prefixed onto this one command: the attribution belongs
  # to the run, so any further commit made here — including one a repository's own
  # pre-commit hook makes — carries it too. Exporting is safe at this point and
  # only at this point: gl_load runs after the commit, so nothing from the
  # workspace .env is in the environment the hooks inherit.
  #
  # Both variables or neither. With only one set, git's own author fallback is
  # half config already, and copying half an identity onto the committer would
  # invent a person who does not exist. With neither set the behaviour is exactly
  # what it was: the checkout's git config decides.
  #
  # And only when the committer is not spoken for already. GIT_COMMITTER_NAME /
  # GIT_COMMITTER_EMAIL are the more specific signal: whoever set one of them
  # named who signs this commit, and overwriting that silently would be the same
  # surprise in the other direction. Either one set leaves the committer to git
  # entirely — filling in only the missing half would invent the same person who
  # does not exist, just out of a deliberate value instead of a config one.
  if [[ -n "${GIT_AUTHOR_NAME-}" && -n "${GIT_AUTHOR_EMAIL-}" \
    && -z "${GIT_COMMITTER_NAME-}" && -z "${GIT_COMMITTER_EMAIL-}" ]]; then
    export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
    export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  fi

  git -C "$worktree" commit -F "$commit_message_file"
fi

# and sourcing it before the commit would export credentials into every
gl_load "$workspace_root"
gl_use "$PROJ_HOST"
# A --description-only run made no commit, so it reports none.
commit_sha=""
commit_subject=""
if ((description_only == 0)); then
  commit_sha="$(git -C "$worktree" rev-parse --short HEAD)"
  commit_subject="$(git -C "$worktree" log -1 --pretty=%s)"
fi

# $GL_BASE, not a literal: this URL is what the caller is told to open when the
# PR could not be created, and one pointing at the wrong instance is worse than
# none — it looks like a working link.
new_mr_url="$GL_BASE/$proj/compare/$base...$branch?expand=1"

report() {
  local -a coord_args

  coord="$workspace_root/.claude/skills/coordination/coord"
  [[ -x "$coord" ]] || coord="$script_dir/../coordination/coord"
  [[ -x "$coord" ]] || coord="$workspace_root/agents/common/skills/coordination/coord"
  local coord_state="$1"
  # A --description-only run pushed nothing: the handoff of the PR's current
  # head belongs to the run that pushed it.
  if ((description_only == 0)) && [[ -x "$coord" && -n "$2" && "$coord_state" =~ ^(created|existing)$ ]]; then
    coord_args=(
      record-mr \
      --task "$task_name" \
      --repo "$repo" \
      --checkout "$worktree_rel" \
      --branch "$branch" \
      --sha "$(git -C "$worktree" rev-parse HEAD)" \
      --state "$coord_state" \
      --url "$2"
    )
    # when it created it. Unknown stays unknown rather than copying the manifest.
    [[ -z "${3-}" ]] || coord_args+=(--target "$3")
    "$coord" "${coord_args[@]}" \
      >/dev/null \
      || echo "warning: could not record coordination PR handoff" >&2
  fi
  printf 'COMMIT_SHA=%s\n' "$commit_sha"
  printf 'COMMIT_SUBJECT=%s\n' "$commit_subject"
  printf 'BRANCH=%s\n' "$branch"
  printf 'TARGET_BRANCH=%s\n' "${3:-$base}"
  printf 'MR_STATE=%s\n' "$1"
  printf 'MR_URL=%s\n' "$2"
  printf 'TRANSPORT=%s\n' "${GL_TRANSPORT:-none}"
  printf 'MR_TRANSPORT=%s\n' "$mr_transport"
  printf 'SPEC_STATE=%s\n' "$spec_state"
  printf 'SPEC_CHANGE=%s\n' "$spec_change_name"
  printf 'SPEC_MR_URL=%s\n' "$spec_mr_url"
}

if [[ -z "$mr_title" ]]; then
  mr_title="$commit_subject"
fi

if ((draft)); then
  case "$mr_title" in
    Draft:*|draft:*) ;;
    *) mr_title="Draft: $mr_title" ;;
  esac
fi

# Only a run with a description file sends a description, and it was checked
# before the commit. There is no fallback to the commit body: that is how PRs
# used to be opened with one line, or nothing, in place of a description.
mr_description=""

if [[ -n "$mr_description_file" ]]; then
  mr_description="$(cat "$mr_description_body")"
fi

# Who wrote this and what else belongs to the task. Rendered offline here, so
# the description the PR is created with already carries it; task-link.sh
# --update rewrites the same block with live PR links once the PR exists.
#
# Only when a description is sent: --existing-mr alone and --no-mr send none,
# and the --update pass below is what refreshes an existing PR's block.
task_block=""

if ((task_link)) && [[ -n "$mr_description_file" ]]; then
  # A block that fails to render is a worse description, not a failed push: the
  # commit is already made and the branch still has to reach the remote.
  if ! task_block="$("$script_dir/task-link.sh" \
    --task "$task_name" --self "$worktree_rel" --workspace "$workspace_root" 2>&1)"; then
    echo "warning: could not render the task block, the PR description goes without it:" >&2
    printf '%s\n' "$task_block" >&2
    task_block=""
  fi

  if [[ -n "$task_block" ]]; then
    if [[ -n "$mr_description" ]]; then
      mr_description="$task_block

$mr_description"
    else
      mr_description="$task_block"
    fi
  fi
fi

# The spec block goes at the top of the description: whoever opens this PR — a
# reviewer or an agent handed nothing but the link — has to see
# what the code was written against before they read the diff.
if [[ "$spec_state" == "ok" ]]; then
  spec_block="$("$spec_ref_sh" "${spec_args[@]}" --block 2>/dev/null || true)"

  if [[ -n "$spec_block" ]]; then
    if [[ -n "$mr_description" ]]; then
      mr_description="$spec_block

$mr_description"
    else
      mr_description="$spec_block"
    fi
  fi
fi

# Into a file, not $(…): GL_TRANSPORT — which transport carried the push — is
# set by the call and would be lost with a subshell.
push_output=""
if ((description_only == 0)); then
  push_log="$(mktemp)"
  tmp_files+=("$push_log")
  push_rc=0
  gl_push "$worktree" "$branch" > "$push_log" || push_rc=$?
  push_output="$(cat "$push_log")"
  if ((push_rc != 0)); then
    printf '%s\n' "$push_output" >&2
    echo "error: push of $branch to origin failed - the commit is made, nothing is pushed" >&2
    exit 1
  fi
  printf '%s\n' "$push_output" >&2
fi

if ((create_mr == 0)); then
  report "not-created" ""
  printf 'PREFILL_URL=%s\n' "$new_mr_url"
  exit 0
fi

description_not_sent_warning() {
  [[ -n "$mr_description_file" ]] || return 0
  echo "warning: the description did not reach GitHub; paste $mr_description_file into the PR (or the prefilled form)" >&2
}

no_open_mr_warning() {
  echo "warning: --existing-mr, but $branch has no open PR — none was opened: a new PR needs a description." >&2
  echo "  The branch is pushed; rerun with --mr-description-file, or open the prefilled PR form and paste the checked description." >&2
}

# The task block in every open PR of the task, this one included, rewritten
# with live links. This is what makes the cross-link two-way: the PRs opened
# earlier learn about this one. Best-effort by construction — the commit is
# pushed and the PR exists, so a refusal here is a warning, and the same
# command repairs it later.
refresh_task_links() {
  ((task_link)) || return 0
  "$script_dir/task-link.sh" --task "$task_name" --workspace "$workspace_root" --update --quiet \
    || echo "warning: task-link.sh --update failed — rerun: .claude/skills/commit-and-mr/task-link.sh --task $task_name --update" >&2
}

lookup_rc=0
gl_mr_find "$worktree" "$branch" || lookup_rc=$?

if ((lookup_rc == 0)); then
  open_mr_url="$MR_URL"
  open_mr_target="$MR_TARGET"

  # Same PR, same branch. A description sent with it replaces the old one:
  if [[ -n "$mr_description" ]]; then
    if ! gl_mr_update_description "$worktree" "$MR_IID" "$mr_description"; then
      if ((description_only)); then
        # Replacing the description was the whole run; failing it is failing.
        echo "error: gh did not update the description of !$MR_IID" >&2
        report "existing" "$open_mr_url" "$open_mr_target"
        exit 1
      fi
      echo "warning: the push reached !$MR_IID, but its description was not updated" >&2
      description_not_sent_warning
    fi
  fi

  report "existing" "$open_mr_url" "$open_mr_target"
  refresh_task_links
  exit 0
fi

# just failed to list. Whatever the mode, nothing is created.
if ((lookup_rc == 2)); then
  echo "error: gh could not list the PRs of $branch — whether one is open is unknown; none was opened or updated" >&2
  description_not_sent_warning
  report "unconfirmed" ""
  printf 'PREFILL_URL=%s\n' "$new_mr_url"
  exit 1
fi

if ((description_only)); then
  echo "error: --description-only, but $branch has no open PR — nothing was updated. Open one with run.sh --mr-description-file." >&2
  report "not-created" ""
  exit 1
fi

if ((existing_mr)); then
  no_open_mr_warning
  report "not-created" ""
  printf 'PREFILL_URL=%s\n' "$new_mr_url"
  exit 0
fi

if gl_mr_create "$worktree" "$branch" "$base" "$mr_title" "$mr_description"; then
  report "created" "$MR_URL" "$base"
  refresh_task_links
  exit 0
fi

echo "error: the branch is pushed, but gh did not open or confirm the PR" >&2
description_not_sent_warning
report "create-failed" ""
printf 'PREFILL_URL=%s\n' "$new_mr_url"
exit 1
