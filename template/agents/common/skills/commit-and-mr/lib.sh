#!/usr/bin/env bash
# Shared helpers for the commit-and-mr scripts. Sourced, never executed.
#
# Everything here is about one question: given a checkout under worktrees/<task>/,
# where is the spec that the code on this branch was written against, and which
# pull request carries it. run.sh writes the locally known answer into the
# commit and the PR it opens, and spec-ref.sh prints it for whoever picked up
# the branch without the session that created it.
#
# PROJ_* / MR_* / GL_* are this library's return channel — set here, read by the
# callers. shellcheck sees only this file, so all of them look unused to it; the
# directive is file-wide because that is what the whole file is for.
# shellcheck disable=SC2034

# The markers of the managed block in an PR description. Everything between them
# is generated, so a description is rewritten by replacing the block and leaving
# the human-written half alone.
SPEC_BLOCK_START='<!-- spec-link:start -->'
SPEC_BLOCK_END='<!-- spec-link:end -->'

# The same mechanism for the other managed block: who authored the task and which
# other PRs belong to it. Separate markers, because the two blocks are written by
# different scripts at different moments and neither may eat the other.
TASK_BLOCK_START='<!-- task-link:start -->'
TASK_BLOCK_END='<!-- task-link:end -->'

# find_workspace_root <dir> — the workspace root for <dir>: the real root when
# there is one (find_real_workspace_root below), otherwise the nearest directory
# holding harness.json. Deferring to the real root first keeps preflight.sh and
# harness_base_branch on the same root as run.sh when a checkout under
# worktrees/ carries a stray harness.json; the fallback keeps a workspace that
# itself sits under some `worktrees/` directory resolvable as before.
find_workspace_root() {
  local dir

  if find_real_workspace_root "$1"; then
    return 0
  fi

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

# find_real_workspace_root <dir> — the root that `worktrees/<task>/` hangs off.
#
# Not the nearest harness.json. A nested checkout under `worktrees/<task>/<repo>/`
# can carry a harness.json of its own — a SYMLINK, placed there by that repo's own
# tooling so it can resolve its own root, or a regular file left by an
# `./ops sync` run inside a agent-workspace worktree — and a resolver that stops at the
# first one it sees would look for the task's checkouts inside that nested
# repo instead of the real workspace above it.
#
# So a candidate is skipped when its harness.json is a symlink, or when the
# directory itself sits under worktrees/.
find_real_workspace_root() {
  local dir
  dir="$(cd "$1" && pwd)"

  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/harness.json" && ! -L "$dir/harness.json" && "$dir" != */worktrees/* ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  return 1
}

# GitHub.com only. GITHUB_TOKEN is the sole authentication source; GH_TOKEN is
# supplied from it per invocation because gh gives GH_TOKEN higher precedence.
# No stored login, credential store, alternate host or interactive prompt is used.
GL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

gl_slug() { printf '%s' "${1//[^a-zA-Z0-9]/_}" | tr '[:lower:]' '[:upper:]'; }
gl_host_from_url() {
  local authority
  case "$1" in
    *://*) authority="${1#*://}"; authority="${authority%%/*}" ;;
    *:*) [[ "${1%%:*}" != */* ]] || return 1; authority="${1%%:*}" ;;
    *) return 1 ;;
  esac
  authority="${authority##*@}"
  [[ -n "$authority" ]] || return 1
  printf '%s' "${authority%%:*}"
}
gl_web_base() { [[ "$1" == github.com ]] || return 1; printf 'https://github.com'; }
gl_use() {
  [[ -z "${1-}" || "$1" == github.com ]] || return 1
  GL_BASE=https://github.com
}

# Import selected literal dotenv values without executing shell code. A variable
# already present in the process (even empty) always wins. This shared entry point
# can also serve sibling skills that need a named credential from the root .env.
workspace_env_load() {
  set +x
  local root="$1" payload name value
  shift
  [[ -f "$root/.env" ]] || return 0
  payload="$(python3 "$GL_LIB_DIR/env.py" "$root/.env" "$@")" || return 1
  while IFS= read -r -d '' name && IFS= read -r -d '' value; do
    [[ -z "${!name+x}" ]] || continue
    export "$name=$value"
  done < <(python3 -c 'import json,sys
for k,v in json.load(sys.stdin).items():
 sys.stdout.buffer.write(k.encode()+b"\0"+v.encode()+b"\0")' <<<"$payload")
}
gl_load() {
  local root
  root="$(find_workspace_root "$1" 2>/dev/null)" || root="$1"
  workspace_env_load "$root" GITHUB_TOKEN NOTION_TOKEN NOTION_VERSION \
    NOTION_SNAPSHOT_PROJECT NOTION_SNAPSHOT_ALLOW_FOREIGN_PROJECT \
    NOTION_SNAPSHOT_DIR NOTION_SNAPSHOT_BRANCH NOTION_SNAPSHOT_GIT_NAME \
    NOTION_SNAPSHOT_GIT_EMAIL || return 1
  GL_DEFAULT_BASE=https://github.com
  GL_DEFAULT_HOST=github.com
  GL_WORKSPACE_ROOT="$root"
  gl_use ""
}

# URL parsing is pure and safe before credentials are loaded. Legacy remote URL
# spelling may be converted for transport; only github.com owner/repository is valid.
proj_from_url() {
  local url="$1" path
  [[ "$(gl_host_from_url "$url" 2>/dev/null)" == github.com ]] || return 1
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    git@github.com:*) path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%/}"; path="${path%.git}"
  [[ "$path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  [[ "$path" != */. && "$path" != */.. && "$path" != ./* && "$path" != ../* ]] || return 1
  PROJ_HOST=github.com
  PROJ_PATH="$path"
  PROJ_ENCODED="$path"
  gl_use "$PROJ_HOST"
}
# harness_base_branch <checkout> — the base branch of the team repository:
# what its worktrees fork from and what its PRs target.
#
# `main` is not a constant here. A team may run the repository on `development`,
# exactly like the product repos whose base lives in `repos.json`; core must not
# carry one team's branch names. So the value comes from `harness.json`.
#
# Two fields, in this order, because the branch a live checkout sits on and the
# branch new work forks from are not the same question. A deployed runtime can
# serve one branch while its changes are expected to go out through another,
# the way every product repo's `feature/… → development → main` flow already works.
# `baseBranch` is that second branch. Absent, it falls back to `branch`, so a
# workspace that never split the two keeps its single answer, and then to
# `main` for a manifest that predates both fields.
harness_base_branch() {
  local checkout root manifest branch

  checkout="$1"

  root="$(find_workspace_root "$checkout" 2>/dev/null)" || { printf 'main\n'; return 0; }
  manifest="$root/harness.json"
  [[ -f "$manifest" ]] || { printf 'main\n'; return 0; }

  branch="$(jq -r '.baseBranch // .branch // empty' "$manifest" 2>/dev/null || true)"

  printf '%s\n' "${branch:-main}"
}

# repos_manifest <workspace_root> — путь до repos.json, манифеста продуктовых
# репозиториев команды. Возвращает путь, даже когда файла ещё нет: понятную
# ошибку печатает вызывающий код.
repos_manifest() {
  local root="${1:?repos_manifest: no workspace root}"
  printf '%s\n' "$root/repos.json"
}

# proj_of <worktree> — the GitHub project path of its `origin`, url-encoded.
proj_of() {
  local remote
  remote="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  [[ -n "$remote" ]] || return 1

  proj_from_url "$remote"
}

# infer_change <changes_dir> — the single active change, or nothing. Prints the
# candidates to stderr when there are several: the caller decides whether that is
# fatal (trace.sh) or merely means a less precise pointer (run.sh).
infer_change() {
  local changes_dir found count name dir
  changes_dir="$1"
  found=""
  count=0

  [[ -d "$changes_dir" ]] || return 1

  while read -r dir; do
    [[ -n "$dir" ]] || continue
    name="$(basename "$dir")"
    [[ "$name" != "archive" ]] || continue
    found="$name"
    count=$((count + 1))
  done < <(find "$changes_dir" -mindepth 1 -maxdepth 1 -type d | sort)

  if ((count == 1)); then
    printf '%s\n' "$found"
    return 0
  fi

  if ((count > 1)); then
    echo "warning: $count active changes in $changes_dir — pass --change to pick one" >&2
  fi

  return 1
}

# HTTPS transport and noninteractive gh wrappers.
gl_remote_is_github() { (proj_from_url "$1"); }
gl_https_url() {
  if gl_remote_is_github "$1"; then
    (proj_from_url "$1"; printf 'https://github.com/%s.git' "$PROJ_PATH")
  else
    printf '%s' "$1"
  fi
}
gl_transport_args() {
  local url rule
  GL_TRANSPORT_ARGS=()
  GL_TRANSPORT_HOST=""
  for url in "$@"; do
    gl_remote_is_github "$url" || continue
    GL_TRANSPORT_HOST=github.com
    case "$url" in
      git@github.com:*) rule='url.https://github.com/.insteadOf=git@github.com:' ;;
      ssh://git@github.com/*) rule='url.https://github.com/.insteadOf=ssh://git@github.com/' ;;
      *) rule='' ;;
    esac
    [[ -z "$rule" ]] || GL_TRANSPORT_ARGS+=(-c "$rule")
  done
  [[ -n "$GL_TRANSPORT_HOST" ]] || return 0
  GL_TRANSPORT_ARGS+=(-c credential.helper= -c 'credential.helper=!gh auth git-credential'
    -c core.askPass= -c credential.interactive=false
    -c protocol.allow=never -c protocol.https.allow=always)
}
gl_in_managed_session() { [[ -n "${AGENT_SESSION_ID-}" ]]; }
gl_transport_prefer() { printf 'https'; }
gl_login_next() { printf 'github-login'; }
gl_gh_login_hint() { printf 'set GITHUB_TOKEN in the process environment or root .env, then run github-login'; }
gl_gh_missing_hint() {
  if gl_have_gh; then gl_gh_login_hint; else printf 'install gh, then set GITHUB_TOKEN and run github-login'; fi
}
gl_no_transport_hint() { gl_gh_missing_hint; }
gl_have_gh() { command -v gh >/dev/null 2>&1; }
gl_gh_mark() { printf -v "GL_GH_STATE_$(gl_slug "$1")" '%s' "$2"; }
gl_gh_state() { local var; var="GL_GH_STATE_$(gl_slug "$1")"; printf '%s' "${!var-}"; }
gl_gh_unusable() { [[ "$(gl_gh_state "$1")" != ok ]]; }
gl_gh_logged_out() { [[ "$(gl_gh_state "$1")" == logged-out ]]; }
gl_auth_host() { [[ -z "${1-}" || "$1" == github.com ]] || return 1; printf 'github.com'; }

# The only gh invocation boundary. Suppress debug modes that could print HTTP
# headers; refuse a missing token before gh can consult its saved credentials.
gl_redact() {
  python3 "$GL_LIB_DIR/redact.py"
}
gl_gh_env() (
  set +x
  [[ -n "${GITHUB_TOKEN-}" ]] || { echo 'error: GITHUB_TOKEN is not set' >&2; return 3; }
  unset GH_DEBUG DEBUG GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
  export GH_TOKEN="$GITHUB_TOKEN" GH_HOST=github.com GH_PROMPT_DISABLED=1
  export GH_PAGER=cat PAGER=cat GIT_TERMINAL_PROMPT=0 GIT_ASKPASS='' SSH_ASKPASS=''
  local rc=0 log
  log="$(mktemp)"
  set -o pipefail
  "$@" </dev/null 2>"$log" | gl_redact || rc=$?
  gl_redact <"$log" >&2
  rm -f "$log"
  return "$rc"
)
# Return 1: missing executable, 2: network/unknown, 3: missing token, 4: rejected.
# API error bodies are deliberately not relayed: a proxy can echo a credential.
gl_require_gh() {
  local host user err rc=0
  host="$(gl_auth_host "${1-}")" || { echo 'error: unsupported GitHub host' >&2; return 2; }
  GL_GH_HOST="$host"; GL_GH_USER=""; GL_NEXT=""
  if ! gl_have_gh; then gl_gh_mark "$host" missing; echo 'error: gh is not installed' >&2; return 1; fi
  if [[ -z "${GITHUB_TOKEN-}" ]]; then
    gl_gh_mark "$host" logged-out; GL_NEXT=github-login
    echo 'error: GITHUB_TOKEN is not set — run github-login' >&2; return 3
  fi
  err="$(mktemp)"
  user="$(gl_gh_env gh api --hostname "$host" user --jq .login 2>"$err")" || rc=$?
  if ((rc == 0)) && [[ "$user" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]]; then
    rm -f "$err"; GL_GH_USER="$user"; gl_gh_mark "$host" ok; return 0
  fi
  if grep -Eq '401|403|Bad credentials|Unauthorized|Forbidden' "$err"; then
    rm -f "$err"; gl_gh_mark "$host" refused
    echo 'error: GitHub refused GITHUB_TOKEN; check expiry and repository permissions' >&2; return 4
  fi
  rm -f "$err"
  echo 'error: gh could not verify GitHub access (network or unexpected response)' >&2
  return 2
}
gl_is_auth_failure() {
  case "$1" in
    *'could not read Username'*|*'Authentication failed'*|*'GITHUB_TOKEN is not set'*|*'GitHub refused'*|*'gh is not installed'*|*'401'*|*'403'*) return 0 ;;
  esac
  return 1
}
gl_is_network_failure() {
  case "$1" in
    *'Could not resolve'*|*'no such host'*|*'dial tcp'*|*'connection refused'*|*'Connection refused'*|*'timed out'*|*'timeout'*|*'TLS'*|*'Network is unreachable'*|*'Failed to connect'*) return 0 ;;
  esac
  return 1
}
gl_remote_run() {
  local url="$1" rc=0
  shift
  GL_TRANSPORT=none; GL_GIT_AUTH_FAILED=0; GL_GIT_LOGGED_OUT=0
  GL_TRANSPORT_HOST=""; GL_GIT_HOST=""; GL_NEXT=""
  case "$url" in
    file://*|/*|./*|../*) GL_TRANSPORT=local; GIT_TERMINAL_PROMPT=0 git "$@"; return $? ;;
    *://*|*:*) ;;
    *) GL_TRANSPORT=local; GIT_TERMINAL_PROMPT=0 git "$@"; return $? ;;
  esac
  if ! gl_remote_is_github "$url"; then echo 'error: remote must identify a GitHub.com repository' >&2; return 1; fi
  GL_GIT_HOST=github.com
  gl_require_gh github.com || rc=$?
  if ((rc)); then
    ((rc != 3)) || { GL_GIT_LOGGED_OUT=1; GL_NEXT=github-login; }
    ((rc != 1 && rc != 3 && rc != 4)) || GL_GIT_AUTH_FAILED=1
    return "$rc"
  fi
  gl_transport_args "$url"
  GL_TRANSPORT=https-gh
  local log
  log="$(mktemp)"
  gl_gh_env git "${GL_TRANSPORT_ARGS[@]}" "$@" 2>"$log" || rc=$?
  if ((rc)) && gl_is_auth_failure "$(cat "$log")"; then GL_GIT_AUTH_FAILED=1; fi
  cat "$log" >&2
  rm -f "$log"
  return "$rc"
}
gl_git() {
  local checkout="$1" url
  shift
  if [[ "${1-}" == push ]]; then
    gl_origin_projects_match "$checkout" || { echo 'error: origin must have one matching GitHub fetch/push destination' >&2; return 1; }
    url="$(gl_origin_raw_url "$checkout" push)" || return 1
  else url="$(gl_origin_raw_url "$checkout")" || return 1; fi
  gl_remote_run "$url" -C "$checkout" "$@"
}

# gl_origin_raw_url <checkout> [push] — origin's URL as configured, before any
# URL rewriting: the push URL (pushurl, else url) with
# `push`. Not `git remote get-url`, which prints the rewritten URL: the rules
# this library adds for one call are keyed on the URL git starts from, and a
# user's global `url.https://host/.insteadOf=git@host:` would otherwise make
# the configured origin use a different spelling from its stored value.
gl_origin_raw_url() {
  local urls=""
  if [[ "${2-}" == push ]]; then
    if urls="$(git -C "$1" config --get-all remote.origin.pushurl 2>/dev/null)"; then
      [[ -n "$urls" && "$urls" != *$'\n'* ]] || return 1
      printf '%s' "$urls"
      return 0
    fi
  fi
  urls="$(git -C "$1" config --get-all remote.origin.url 2>/dev/null)" || return 1
  [[ -n "$urls" && "$urls" != *$'\n'* ]] || return 1
  printf '%s' "$urls"
}

# gl_git_url <url> <git args...> — the same transport for a command that names
# the remote URL itself instead of a checkout's origin (`ls-remote <url>`). The
# URL must appear in the args; it is only read here to pick the mapping.
gl_git_url() {
  local url
  url="$1"
  shift
  gl_remote_run "$url" "$@"
}

# gl_push <checkout> <branch> [git push flags...] — plain push of <branch> to
# origin with upstream tracking. Opens no PR: that is gl_mr_create's job.
gl_push() {
  local checkout branch
  checkout="$1"
  branch="$2"
  shift 2

  gl_git "$checkout" push "$@" -u origin "$branch"
}

# gl_origin_projects_match <checkout> — fetch and push URLs must identify the
# same GitHub project: `git push` follows pushurl, and gh -R follows origin,
# so a mismatch would open the PR in another project than the push reached.
# Sets redacted identities for diagnostics (host/path only, never userinfo).
gl_origin_projects_match() {
  local checkout="$1" fetch_url push_url effective_fetch effective_push url identity expected=""
  GL_ORIGIN_FETCH_PROJECT=""; GL_ORIGIN_PUSH_PROJECT=""
  fetch_url="$(gl_origin_raw_url "$checkout")" || return 1
  push_url="$(gl_origin_raw_url "$checkout" push)" || return 1
  effective_fetch="$(git -C "$checkout" remote get-url --all origin 2>/dev/null)" || return 1
  effective_push="$(git -C "$checkout" remote get-url --push --all origin 2>/dev/null)" || return 1
  # Git pushes to every pushurl (or every url when pushurl is absent). A single
  # inspected URL cannot authorize the command; raw and rewritten sets must each
  # contain exactly one destination, all identifying the same GitHub repository.
  for url in "$fetch_url" "$push_url" "$effective_fetch" "$effective_push"; do
    [[ -n "$url" && "$url" != *$'\n'* ]] || return 1
    identity="$(proj_from_url "$url" || exit 1; printf '%s/%s' "$PROJ_HOST" "$PROJ_PATH")" || return 1
    [[ -z "$expected" || "$identity" == "$expected" ]] || return 1
    expected="$identity"
  done
  GL_ORIGIN_FETCH_PROJECT="$expected"; GL_ORIGIN_PUSH_PROJECT="$expected"
}

gl_fetch() { local checkout="$1"; shift; gl_git "$checkout" fetch origin "$@"; }
gl_clone() { local url="$1" dest="$2"; shift 2; gl_remote_run "$url" clone "$@" "$url" "$dest"; }

# MR_* names and gl_mr_* signatures remain a local compatibility interface;
# the external objects are GitHub pull requests. State maps to opened/closed/merged.
gl_gh_repo() {
  local origin
  origin="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  (proj_from_url "$origin" || exit 1; printf '%s/%s' "$PROJ_HOST" "$PROJ_PATH")
}
gl_gh() { local checkout="$1"; shift; (cd "$checkout" && gl_gh_env gh "$@"); }
gl_mr_find() {
  local checkout="$1" branch="$2" repo json pick state=open
  [[ "${3-}" != --all ]] || state=all
  MR_IID=""; MR_URL=""; MR_STATE=""; MR_TARGET=""; MR_TITLE=""; MR_DESCRIPTION=""
  repo="$(gl_gh_repo "$checkout")" || return 2
  json="$(gl_gh "$checkout" pr list -R "$repo" --head "$branch" --state "$state" \
    --json number,url,state,baseRefName,title,body --limit 100)" || return 2
  if ! jq -se --arg repo "$repo" '
    length == 1 and (.[0] | type == "array" and all(.[];
      type == "object" and
      (.number | type == "number" and . > 0 and floor == .) and
      (.url == ("https://" + $repo + "/pull/" + (.number | tostring))) and
      (.state == "OPEN" or .state == "CLOSED" or .state == "MERGED") and
      (.baseRefName | type == "string" and length > 0) and
      (.title | type == "string") and (.body | type == "string")
    ))' >/dev/null 2>&1 <<<"$json"; then
    echo 'error: gh pr list returned malformed JSON entries' >&2; return 2
  fi
  pick='([.[] | select(.state == "OPEN")][0] // .[0]) // empty'
  jq -e "$pick" >/dev/null 2>&1 <<<"$json" || return 1
  MR_IID="$(jq -r "$pick | .number // empty" <<<"$json")"
  MR_URL="$(jq -r "$pick | .url // empty" <<<"$json")"
  MR_STATE="$(jq -r "$pick | .state // empty" <<<"$json")"
  case "$MR_STATE" in OPEN) MR_STATE=opened ;; CLOSED) MR_STATE=closed ;; MERGED) MR_STATE=merged ;; *) return 2 ;; esac
  MR_TARGET="$(jq -r "$pick | .baseRefName // empty" <<<"$json")"
  MR_TITLE="$(jq -r "$pick | .title // empty" <<<"$json")"
  MR_DESCRIPTION="$(jq -r "$pick | .body // empty" <<<"$json")"
  [[ "$MR_IID" =~ ^[1-9][0-9]*$ && "$MR_URL" == "https://$repo/pull/$MR_IID" ]] || return 2
}
gl_mr_create() {
  local checkout="$1" branch="$2" target="$3" title="${4//$'\n'/ }" description="$5"
  local repo body output rc=0
  MR_URL=""
  repo="$(gl_gh_repo "$checkout")" || return 1
  body="$(mktemp)"; printf '%s\n' "$description" > "$body"
  output="$(gl_gh "$checkout" pr create -R "$repo" --head "$branch" --base "$target" \
    --title "$title" --body-file "$body" --draft)" || rc=$?
  rm -f "$body"
  ((rc == 0)) || return "$rc"
  MR_URL="$(gl_mr_url_from_output "$output")"
  case "$MR_URL" in "https://$repo/pull/"*) ;; *) MR_URL='' ;; esac
  if [[ -z "$MR_URL" ]]; then gl_mr_find "$checkout" "$branch" || return 1; fi
  [[ -n "$MR_URL" ]]
}
gl_mr_update_description() {
  local checkout="$1" iid="$2" description="$3" repo body rc=0
  repo="$(gl_gh_repo "$checkout")" || return 1
  body="$(mktemp)"; printf '%s\n' "$description" > "$body"
  gl_gh "$checkout" pr edit "$iid" -R "$repo" --body-file "$body" >/dev/null || rc=$?
  rm -f "$body"
  return "$rc"
}

# The sections every PR description opens with, in this order. One list for the
# template (mr-description/template.md), the check below and run.sh's error.
MR_DESCRIPTION_SECTIONS=(
  "Что и зачем"
  "Изменения"
  "Инфраструктура, схема, зависимости"
  "Как проверить"
  "Риски и что осталось"
  "Changelog"
)

# Sections that may honestly say "нет": an PR without migrations or open risks
# exists, and so does an PR that changes nothing a person would read about in
# the team's history. The rest may not — every PR has a reason, a change and a
# way to check.
#
# Changelog is on this list on purpose. Required so the question is ASKED in
# every PR (the rule it serves is in AGENTS.md, "Правка этого репозитория", and
# the skill that answers it is `changelog`); allowed to say "нет" so that an
# internal refactor is not pushed into inventing an entry. What the gate can
# check is presence, not honesty.
MR_DESCRIPTION_MAY_BE_NONE=(
  "Инфраструктура, схема, зависимости"
  "Риски и что осталось"
  "Changelog"
)

# mr_description_check <file> — whether <file> is a complete PR description body:
# every MR_DESCRIPTION_SECTIONS heading as `## <name>`, in order, each with
# content; no template placeholder `{{…}}` left outside code (an inline
# `{{ .Release.Name }}` is Helm, not an unfilled template); no legacy managed
# spec/task-link block. Headings inside fenced code do
# not count. Prints one `DESCRIPTION_ERROR=` per problem on stderr; returns 1
# when there is any.
mr_description_check() {
  local file report line kind name body
  local -a errors=()
  file="$1"

  if [[ ! -s "$file" ]]; then
    printf 'DESCRIPTION_ERROR=%s\n' "empty or missing: $file" >&2
    return 1
  fi

  # One line per finding from awk: `H<TAB>name<TAB>body` per level-2 heading
  # (body = its non-blank text joined), `P<TAB>lineno` per placeholder,
  # `M<TAB>lineno` per managed marker.
  report="$(awk '
    function flush() {
      if (name != "") { gsub(/\t/, " ", body); printf "H\t%s\t%s\n", name, body }
    }
    /^[[:space:]]*(```|~~~)/ { fence = !fence; if (name != "") body = body " code"; next }
    fence { if (name != "") body = body " code"; next }
    /^## / {
      flush()
      name = substr($0, 4); sub(/[[:space:]]+$/, "", name); body = ""
      next
    }
    { line = $0; gsub(/`[^`]*`/, "", line) }
    line ~ /\{\{[^}]*\}\}/ { printf "P\t%d\n", NR }
    /<!-- (spec-link|task-link):(start|end) -->/ { printf "M\t%d\n", NR }
    name != "" && NF { body = body " " $0 }
    END { flush() }
  ' "$file")"

  local -a found_names=() found_bodies=()
  while IFS=$'\t' read -r kind name body; do
    case "$kind" in
      H) found_names+=("$name"); found_bodies+=("$body") ;;
      P) errors+=("line $name: template placeholder {{…}} left unfilled (template syntax that belongs in the text goes in \`code\`)") ;;
      M) errors+=("line $name: managed spec-link/task-link marker — legacy generated blocks do not belong in the authored body") ;;
    esac
  done <<< "$report"

  local section i pos last_pos=-1 content none
  for section in "${MR_DESCRIPTION_SECTIONS[@]}"; do
    pos=-1
    for i in "${!found_names[@]}"; do
      if [[ "${found_names[$i]}" == "$section" ]]; then
        pos="$i"
        break
      fi
    done

    if ((pos < 0)); then
      errors+=("missing section: ## $section")
      continue
    fi
    if ((pos < last_pos)); then
      errors+=("section out of order: ## $section")
    fi
    last_pos="$pos"

    content="$(printf '%s' "${found_bodies[$pos]}" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')"
    if [[ -z "$content" ]]; then
      errors+=("empty section: ## $section")
      continue
    fi

    # Spelled out rather than lowercased or bracketed: neither tr nor a [Нн]
    # class handles Cyrillic in the C locale, and bash 3.2 (macOS /bin/bash) has
    # no ${var,,}.
    none=0
    case "$content" in
      Нет | нет | НЕТ | Нет. | нет. | "- Нет" | "- нет" | "— Нет" | "— нет" | \
        "-" | "—" | N/A | n/a | None | none) none=1 ;;
    esac
    if ((none)) && ! printf '%s\n' "${MR_DESCRIPTION_MAY_BE_NONE[@]}" | grep -qxF "$section"; then
      errors+=("section says nothing: ## $section — it cannot be \"нет\"")
    fi
  done

  if ((${#errors[@]} > 0)); then
    printf 'DESCRIPTION_ERROR=%s\n' "${errors[@]}" >&2
    return 1
  fi
}

# mr_description_strip_managed <in> <out> — <in> without the managed spec-link
# and task-link blocks, written to <out>. A description read back from GitHub
# (`gh pr view … --json body`, field `body`) carries the blocks commit-and-mr
# put there; mr_description_check rejects them in an authored body, and run.sh
# renders them anew anyway, so sending them back would give the PR two of each.
# Only whole blocks outside fenced code are removed — an PR that documents the
# blocks keeps its example. Leading blank lines left behind are dropped. Sets
# MR_DESCRIPTION_STRIPPED to the number of blocks removed. A start marker with no
# end returns 1: everything after it would go, and that is a guess.
mr_description_strip_managed() {
  local in out result rc
  in="$1"
  out="$2"
  MR_DESCRIPTION_STRIPPED=0

  rc=0
  result="$(awk -v out="$out" \
    -v ss="$SPEC_BLOCK_START" -v se="$SPEC_BLOCK_END" \
    -v ts="$TASK_BLOCK_START" -v te="$TASK_BLOCK_END" '
    BEGIN { skip = ""; n = 0; started = 0; fence = 0; printf "" > out }
    skip != "" {
      if (index($0, skip)) { skip = ""; n++ }
      next
    }
    /^[[:space:]]*(```|~~~)/ { fence = !fence }
    !fence && index($0, ss) {
      if (index($0, se)) { n++ } else { skip = se; start = NR }
      next
    }
    !fence && index($0, ts) {
      if (index($0, te)) { n++ } else { skip = te; start = NR }
      next
    }
    !started && $0 ~ /^[[:space:]]*$/ { next }
    { started = 1; print > out }
    END {
      if (skip != "") { print "unterminated:" start; exit 3 }
      print n
    }
  ' "$in")" || rc=$?

  if ((rc != 0)); then
    printf 'DESCRIPTION_ERROR=%s\n' \
      "line ${result#unterminated:}: managed block start with no end marker — remove it by hand" >&2
    return 1
  fi
  MR_DESCRIPTION_STRIPPED="$result"
}

# gl_mr_url_from_output <output> — the last PR link in gh's (or git's) output.
# No guessed URL is promoted to success: if the output carries no concrete PR
# link, the caller looks the PR up or reports it as unconfirmed.
gl_mr_url_from_output() {
  local output
  output="$1"
  printf '%s\n' "$output" \
    | grep -Eo 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' \
    | tail -1 \
    || true
}

# task_checkouts <task_dir> — every git checkout of the task, relative to it,
# one per line. Two levels, because a stepped task nests them one deeper.
#
# Каждый чекаут ровно один раз, и это не педантизм: задача может содержать
# симлинк на собственный чекаут — вложенный репозиторий, который кладёт ссылку
# на соседа своей же процедурой раскладки, — и тогда второй уровень глоба
# находит тот же репозиторий ещё раз. Дубликат тихо въезжает в таблицу PR
# отдельной строкой, где один PR выглядит как два, с одной и той же ссылкой.
#
# Различаются каталоги по физическому пути, а не по origin и ветке: двух
# рабочих деревьев одного репозитория на одной ветке git не допускает, так что
# совпадение физического пути — это ровно «тот же самый чекаут», и два разных
# чекаута одного репозитория (если они когда-нибудь появятся) не схлопнутся.
# Первым остаётся верхний уровень: он идёт раньше в глобе, и его путь короче.
task_checkouts() {
  local task_dir dir rel real seen_path
  local -a seen_reals=()
  task_dir="$1"

  for dir in "$task_dir"/*/ "$task_dir"/*/*/; do
    [[ -d "$dir" ]] || continue
    [[ -e "$dir/.git" ]] || continue

    real="$(cd -P "$dir" 2>/dev/null && pwd)" || continue

    for seen_path in ${seen_reals[@]+"${seen_reals[@]}"}; do
      [[ "$seen_path" == "$real" ]] && continue 2
    done

    seen_reals+=("$real")

    rel="${dir#"$task_dir"/}"
    printf '%s\n' "${rel%/}"
  done
}

# The local coordination record of a task keyed by checkout, with the record key
# as the fallback: coord keys by checkout when run.sh passes one and by repo name
# when it does not. One selector for every reader of that record — task-link.sh
# wants the PR of a checkout, changelog/links.sh the pushed SHA of the same one,
# and a second copy of this jq would drift from the first the day the record
# grows a field.
COORD_RECORD_SELECT='([to_entries[] | select((((.value.checkout // "") | if . == "" then null else . end) // .key) == $c)][0].value // {})'

# coord_record_field <repos-json> <checkout-rel-from-root> <field> — that one
# field of the record, or empty.
coord_record_field() {
  printf '%s' "$1" \
    | jq -r --arg c "$2" --arg f "$3" \
      "$COORD_RECORD_SELECT"' | (.[$f] // "")' 2>/dev/null \
    || printf ''
}

# mr_of <repos-json> <checkout-rel-from-root> — "<url><TAB><state>", both
# possibly empty.
mr_of() {
  printf '%s' "$1" \
    | jq -r --arg c "$2" \
      "$COORD_RECORD_SELECT"' | [(.mrUrl // ""), (.mrState // "")] | @tsv' 2>/dev/null \
    || printf '\t\n'
}

# splice_marked_block <description> <block> <start_marker> <end_marker> — the
# description with that managed block replaced in place, or prepended when it has
# none. Reads nothing from disk so it is safe on a description written by a human,
# and touches only its own pair of markers, so the spec block and the task block
# coexist in one description.
#
# The scan is per line and skips fenced code, because the description of an PR
# that *documents* one of these blocks contains the markers as an example. A
# substring search finds that example first and the splice then overwrites the
# documentation instead of adding the block — silently, since the result still
# renders. A marker inside ``` or ~~~ is therefore text, not a marker.
#
# Two start markers outside fences mean the description already carries something
# this function cannot tell apart from its own block. Guessing would eat one of
# them, so it refuses with exit 2 and lets the caller report that PR as failed.
splice_marked_block() {
  local description block start end line i
  description="$1"
  block="$2"
  start="$3"
  end="$4"

  if [[ -z "$description" ]]; then
    printf '%s\n' "$block"
    return 0
  fi

  # `while read` rather than mapfile: nothing else in the harness needs bash 4,
  # and a macOS /bin/bash first in PATH is still 3.2.
  local -a lines=()
  while IFS= read -r line; do
    lines+=("$line")
  done <<< "$description"

  local fence=0 starts=0 open=-1 close=-1 trimmed
  for ((i = 0; i < ${#lines[@]}; i++)); do
    line="${lines[$i]}"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '```'* | '~~~'*)
        fence=$((1 - fence))
        continue
        ;;
    esac
    if ((fence)); then
      continue
    fi
    if [[ "$line" == *"$start"* ]]; then
      starts=$((starts + 1))
      if ((open < 0)); then
        open=$i
      fi
    elif ((open >= 0)) && ((close < 0)) && [[ "$line" == *"$end"* ]]; then
      close=$i
    fi
  done

  if ((starts > 1)); then
    printf 'splice_marked_block: %d "%s" markers outside code fences — refusing to guess which is the managed block\n' \
      "$starts" "$start" >&2
    return 2
  fi

  # An unbalanced fence makes the scan above unreliable: a stray ``` in prose can
  # hide a real marker, and prepending then gives the description two blocks. The
  # ambiguity is reported, never resolved by guessing.
  if ((starts == 0)) && ((fence != 0)) && [[ "$description" == *"$start"* ]]; then
    printf 'splice_marked_block: unbalanced code fence hides a "%s" marker — refusing to write\n' \
      "$start" >&2
    return 2
  fi

  if ((open < 0)); then
    printf '%s\n\n%s\n' "$block" "$description"
    return 0
  fi

  local before="" after=""
  for ((i = 0; i < open; i++)); do
    before+="${lines[$i]}"$'\n'
  done

  # A start marker with no end — hand-truncated, or a previous run cut off —
  # keeps only what precedes it. Otherwise the tail would be the whole
  # description again and the block would be duplicated on every run.
  if ((close >= 0)); then
    for ((i = close + 1; i < ${#lines[@]}; i++)); do
      after+=$'\n'"${lines[$i]}"
    done
  fi

  printf '%s%s%s\n' "$before" "$block" "$after"
}

# splice_block <description> <block> — the spec-link block. Kept for the spec
# side; task-link.sh --update uses splice_task_block below.
splice_block() {
  splice_marked_block "$1" "$2" "$SPEC_BLOCK_START" "$SPEC_BLOCK_END"
}

# splice_task_block <description> <block> — the task-link block.
splice_task_block() {
  splice_marked_block "$1" "$2" "$TASK_BLOCK_START" "$TASK_BLOCK_END"
}
