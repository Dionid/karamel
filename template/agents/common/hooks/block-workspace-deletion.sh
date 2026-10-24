#!/usr/bin/env bash
# PreToolUse/Bash hook: refuse a command that would delete the workspace tree
# itself — the ./ops checkout and the shared root it sits in.
#
# What is protected, and nothing else:
#   <workspace>            the team repository (the dir holding harness.json)
#   dirname <workspace>    the shared root above it, on a host where several
#                          sessions share one filesystem tree
# plus every ancestor of those, because deleting an ancestor deletes them.
#
# Everything INSIDE stays deletable: worktrees/<task>/, packages/<repo>/, a
# scratch file, node_modules. Cleanup is normal work, and a guard that blocked it
# would be turned off inside a week.
#
# Why a hook and not one more permissions.deny line. Three reasons, each of them
# measured rather than assumed, 2026-09-13 in this workspace:
#   1. `Bash(rm -rf *)` matches the literal flag string. `rm -r -f <path>` ran
#      through it and deleted its target; so do `-fR`, `-rvf`, `--recursive`.
#   2. A glob list cannot answer "is this path the workspace root": `rm -rf ..`,
#      `rm -rf /data/workspaces/*` and `mv <root> /tmp/x` are all deletions of
#      the root written without the string `rm -rf <root>` in them.
#   3. deny is a list of forbidden spellings; this is a question about one
#      resolved path. Only the second one has a finite answer.
# The deny list keeps its entries — this runs beside it, not instead of it.
#
# Fails OPEN, and says so on stderr when it does: a crashing guard must not make
# an agent look broken. The cases where it cannot answer (an unexpanded `$VAR`
# in the path, a wrapper it does not parse) are listed in
#
# stdin: hook JSON. stdout: PreToolUse decision JSON when denying.
# Both agents feed this and they disagree about the input shape: Claude Code
# sends snake_case with the command as a string, Codex CLI sends camelCase and
# its shell tools carry argv as an array. Both are read below — the same
# unwrapping as block-secret-reads.sh, for the same reason.
#
# agents/common/tests/block-workspace-deletion.test.py runs every rule in all
# three shapes, and `make lint` runs it.
set -uo pipefail
# No globbing anywhere in this script: the words being inspected are somebody
# else's command line, and `rm -rf *` must stay a literal `*` rather than
# expanding against the hook's own cwd.
set -f

deny() {
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}
skip() { printf 'block-workspace-deletion.sh: %s\n' "$1" >&2; }

command -v jq >/dev/null 2>&1 || { skip "no jq — workspace deletion is NOT guarded"; exit 0; }

payload=$(cat)
[ -n "$payload" ] || exit 0

# ONE jq call, not three: this hook runs on every Bash tool call, beside the
# coordination hook and block-secret-reads.sh, and a jq start-up is ~35 ms of
# that budget each. Tool name and cwd come back on the first two lines; the
# command is everything after them, because it is the only field that can itself
# contain a newline (the argv unwrap below joins with one).
fields=$(printf '%s' "$payload" | jq -r '
  def unwrap:
    map(tostring) as $a
    | [ $a | join(" ") ]
      + [ ($a | to_entries | map(select(.value | test("^-[A-Za-z]*c$"))) | first) as $f
          | if $f != null and ($a | length) > ($f.key + 1) then $a[$f.key + 1] else empty end ]
    | join("\n");
  def text: if type == "array" then unwrap else tostring end;
  ([.tool_name?, .toolName?] | map(select(. != null)) | first // ""),
  (.cwd // ""),
  ([ .tool_input?.command?, .toolInput?.command? ]
   | map(select(. != null)) | first // "" | text)
' 2>/dev/null) || exit 0

tool=$(printf '%s\n' "$fields" | sed -n 1p)
payload_cwd=$(printf '%s\n' "$fields" | sed -n 2p)
cmd=$(printf '%s\n' "$fields" | sed '1,2d')

case "$tool" in
  Bash|bash|shell|local_shell|exec_command|unified_exec|"") ;;
  *) exit 0 ;;
esac
[ -n "${cmd//[[:space:]]/}" ] || exit 0

# ── what counts as the workspace ─────────────────────────────────────────────
find_root() {
  local dir="${1:-}"
  [ -n "$dir" ] || return 1
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -e "$dir/harness.json" ] && { printf '%s' "$dir"; return 0; }
    dir=$(dirname "$dir")
  done
  return 1
}

WORKSPACE="${WORKSPACE:-$(find_root "${payload_cwd:-$PWD}" || find_root "$PWD" || find_root "${CLAUDE_PROJECT_DIR:-}" || true)}"
if [ -z "$WORKSPACE" ]; then
  skip "workspace root not found (no harness.json above cwd) — workspace deletion is NOT guarded"
  exit 0
fi

# The shared root above it — on a host where every session materializes into
# one tree below it, losing it loses every session's work at once — is NOT a
# second entry here, and does not need to be: covers() below answers for every
# ancestor of a protected path already, and the shared root is one by
# construction. Naming it in the refusal is WHY's job, which carries the exact
# path the command resolved to.
PROTECTED=("$WORKSPACE")

# ── path arithmetic ──────────────────────────────────────────────────────────
# Textual, not realpath: realpath would resolve symlinks out of the workspace,
# and it answers nothing about a path that no longer has to exist.
# The leading `~` is matched through a variable rather than written literally in
# the pattern: quoted, shellcheck reads it as a tilde that failed to expand
# (SC2088); unquoted, the shell would expand it against THIS hook's $HOME before
# the comparison. It is a pattern, and the character is the one the inspected
# command was written with.
TILDE='~'
norm() {
  local p="$1" cwd="$2"
  case "$p" in
    /*) ;;
    "$TILDE") p="${HOME:-/}" ;;
    "$TILDE/"*) p="${HOME:-}/${p#\~/}" ;;
    *) p="$cwd/$p" ;;
  esac
  while [ "${p#*//}" != "$p" ]; do p="${p//\/\//\/}"; done
  while [ "${p#*/./}" != "$p" ]; do p="${p//\/.\//\/}"; done
  p="${p%/.}"
  while [[ "$p" =~ (^|/)[^/]+/\.\.(/|$) ]]; do
    p=$(printf '%s' "$p" | sed -E 's![^/]+/\.\.(/|$)!!')
  done
  while [ ${#p} -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  [ -n "$p" ] && printf '%s' "$p" || printf '/'
}

# True when deleting $1 takes a protected root with it — $1 IS one, or $1 is an
# ancestor of one. A path below a protected root is deliberately not covered.
covers() {
  local c="$1" p
  [ -n "$c" ] || return 1
  [ "$c" = "/" ] && return 0
  for p in "${PROTECTED[@]}"; do
    [ "$c" = "$p" ] && return 0
    case "$p" in "$c"/*) return 0 ;; esac
  done
  return 1
}

# `find <root> -name '*.log' -delete` deletes inside the workspace, which is
# ordinary work; `find <root> -delete` empties it. The difference is whether the
# expression carries a filter that CANNOT match the root being walked — an
# unfiltered find, or one whose pattern would match it, is the dangerous one.
# $1 = the path that covered a protected root, rest = the find arguments.
find_is_scoped() {
  local target="$1" pat scoped=0 j=1 candidate
  local -a a=("$@")
  # Every path the walk could reach and must not delete: the directory it is
  # rooted at, and each protected root below it — `find <shared> -name workspace
  # -exec rm -rf {} +` is filtered and still deletes the workspace.
  local -a risky=("$target" "${PROTECTED[@]}")
  while [ $j -lt ${#a[@]} ]; do
    case "${a[$j]}" in
      -name|-iname|-lname|-ilname)
        j=$((j + 1)); pat="${a[$j]:-}"; scoped=1
        for candidate in "${risky[@]}"; do
          # shellcheck disable=SC2254
          case "$(basename "$candidate")" in $pat) return 1 ;; esac
        done
        ;;
      -path|-ipath|-wholename|-iwholename)
        j=$((j + 1)); pat="${a[$j]:-}"; scoped=1
        for candidate in "${risky[@]}"; do
          # shellcheck disable=SC2254
          case "$candidate" in $pat) return 1 ;; esac
        done
        ;;
      # A regex is not a glob and this guard will not pretend to evaluate one.
      -regex|-iregex) return 1 ;;
    esac
    j=$((j + 1))
  done
  [ "$scoped" = 1 ]
}

WHY=""
# $1 = the effective cwd, rest = candidate path arguments.
hits() {
  local cwd="$1" a abs pat p; shift
  for a in "$@"; do
    [ -n "$a" ] || continue
    case "$a" in
      *'*'*|*'?'*|*'['*)
        # A wildcard argument asks two different questions, and reading them as
        # one is what made `rm -f *.log` look like a deletion of the directory.
        case "$a" in
          '*'|'.*'|*/'*'|*/'.*')
            # A whole directory spelled as its contents. `rm -rf *` in the root
            # and `rm -rf <shared>/*` do delete it.
            abs="${a%/*}"; [ "$abs" = "$a" ] && abs="."
            abs="$(norm "$abs" "$cwd")"
            covers "$abs" && { WHY="$abs"; return 0; }
            ;;
          *)
            # A partial pattern deletes only what it matches, so it is matched
            # AGAINST the protected paths instead of standing in for their
            # parent: `<shared>/godd*` hits, `*.log` does not. `*` crossing `/`
            # in a case pattern is deliberate here — it can only widen the net.
            pat="$(norm "$a" "$cwd")"
            for p in "${PROTECTED[@]}"; do
              # shellcheck disable=SC2254
              case "$p" in $pat) WHY="$p"; return 0 ;; esac
            done
            ;;
        esac
        ;;
      *)
        abs="$(norm "$a" "$cwd")"
        covers "$abs" && { WHY="$abs"; return 0; }
        ;;
    esac
  done
  return 1
}

# ── walk the command, segment by segment ─────────────────────────────────────
# Simple commands, so `cd /data/workspaces && rm -rf shared` is read the way the
# shell will read it: the `cd` moves the cwd that the next segment's relative
# path resolves against, and without tracking it the guard would resolve
# `shared` against the session's cwd and see an unrelated path.
eff_cwd="${payload_cwd:-$PWD}"
DESTRUCTIVE_VERB='(^|[[:space:]])(rm|rmdir|unlink|shred|srm|trash|trash-put|-delete|--delete)([[:space:]]|$)'

while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  seg="${seg%"${seg##*[![:space:]]}"}"
  [ -n "$seg" ] || continue

  # Quotes are stripped rather than parsed: the paths this guard is about never
  # contain spaces, and `rm -rf "/data/workspaces/shared"` must read the same as
  # the bare form.
  bare="${seg//\"/}"
  bare="${bare//\'/}"

  # `(cd X && rm -rf y)` is the standard way to run something without moving the
  # session's cwd, and without this the verb reads as `(cd` and nothing matches.
  while :; do
    case "$bare" in
      '('*|'{'*) bare="${bare#?}"; bare="${bare#"${bare%%[![:space:]]*}"}" ;;
      *) break ;;
    esac
  done
  while :; do
    case "$bare" in
      *')'|*'}') bare="${bare%?}"; bare="${bare%"${bare##*[![:space:]]}"}" ;;
      *) break ;;
    esac
  done
  [ -n "$bare" ] || continue
  words=()
  read -ra words <<< "$bare"
  [ ${#words[@]} -gt 0 ] || continue

  # Strip env assignments and the wrappers that just prefix another command, so
  # `sudo rm …` and `bash -lc rm …` are read as the `rm` they are. The shell
  # wrappers matter twice over: Codex sends argv arrays, and this hook sees them
  # both joined (`bash -lc rm -rf /x`) and unwrapped, so the joined line has to
  # resolve to the same verdict as the script inside it — otherwise
  # `bash -lc grep -r "rm -rf" <root>` reads as a deletion of <root>.
  i=0
  while [ $i -lt ${#words[@]} ]; do
    case "${words[$i]##*/}" in
      *=*) i=$((i + 1)) ;;
      sudo|command|builtin|nice|nohup|time|exec|doas) i=$((i + 1)) ;;
      sh|bash|zsh|dash|ksh|timeout|stdbuf|env)
        wrapper="${words[$i]##*/}"
        i=$((i + 1))
        while [ $i -lt ${#words[@]} ]; do
          case "${words[$i]}" in -*) i=$((i + 1)) ;; *) break ;; esac
        done
        # `timeout 30 rm …`: the duration is a positional argument of the
        # wrapper, not the command.
        if [ "$wrapper" = "timeout" ] && [ $i -lt ${#words[@]} ]; then
          case "${words[$i]}" in [0-9]*) i=$((i + 1)) ;; esac
        fi
        ;;
      *) break ;;
    esac
  done
  [ $i -lt ${#words[@]} ] || continue
  verb="${words[$i]##*/}"
  args=("${words[@]:$((i + 1))}")

  # `cd`/`pushd` move the cwd the following segments resolve against.
  if [ "$verb" = "cd" ] || [ "$verb" = "pushd" ]; then
    for a in ${args+"${args[@]}"}; do
      case "$a" in -*) continue ;; esac
      eff_cwd="$(norm "$a" "$eff_cwd")"
      break
    done
    continue
  fi

  # Positional arguments, with flags dropped and `--` ending the flags.
  paths=()
  end_flags=0
  for a in ${args+"${args[@]}"}; do
    if [ "$end_flags" = 0 ]; then
      [ "$a" = "--" ] && { end_flags=1; continue; }
      case "$a" in -*) continue ;; esac
    fi
    paths+=("$a")
  done

  case "$verb" in
    rm|rmdir|unlink|shred|srm|trash|trash-put|wipe)
      hits "$eff_cwd" ${paths+"${paths[@]}"} && deny \
        "Blocked: this would delete $WHY, which is the workspace itself ($WORKSPACE and the shared root above it). Everything inside it is deletable — name the subdirectory you meant (worktrees/<task>/, packages/<repo>/, a scratch path). Removing a task's checkout is '.claude/skills/wt/wt rm <task>'."
      ;;
    gio)
      [ "${paths[0]:-}" = "trash" ] && hits "$eff_cwd" ${paths+"${paths[@]:1}"} && deny \
        "Blocked: this would delete $WHY, which is the workspace itself ($WORKSPACE and the shared root above it)."
      ;;
    mv)
      # Moving the root away is a deletion with extra steps; the destination is
      # not a candidate, writing INTO the workspace is ordinary work.
      n=${#paths[@]}
      if [ "$n" -gt 1 ]; then
        srcs=("${paths[@]:0:$((n - 1))}")
        # `mv -t DEST src...` inverts the positions: everything is a source.
        case " ${args[*]} " in *" -t "*|*" --target-directory"*) srcs=("${paths[@]}") ;; esac
        hits "$eff_cwd" ${srcs+"${srcs[@]}"} && deny \
          "Blocked: this would move $WHY out from under the session — the workspace itself ($WORKSPACE and the shared root above it). Move a subdirectory, not the root."
      fi
      ;;
    find)
      # Only when the expression actually deletes: `find <root> -name x` is a
      # read and stays one.
      if printf '%s' "$bare" | grep -Eq '(^|[[:space:]])-delete([[:space:]]|$)' \
        || printf '%s' "$bare" | grep -Eq '(^|[[:space:]])-(exec|execdir)[[:space:]]+(/bin/|/usr/bin/)?rm([[:space:]]|$)'; then
        # Start paths only — everything from the first `-expression` on is the
        # predicate, not a path.
        starts=()
        for a in ${args+"${args[@]}"}; do
          case "$a" in -*|'('|'!') break ;; esac
          starts+=("$a")
        done
        if hits "$eff_cwd" ${starts+"${starts[@]}"} && ! find_is_scoped "$WHY" ${args+"${args[@]}"}; then
          deny "Blocked: this find is rooted at $WHY — the workspace itself ($WORKSPACE and the shared root above it) — and its expression does not restrict what it deletes. Root it at the subtree you meant, or give it a -name/-path filter."
        fi
      fi
      ;;
    rsync)
      if printf '%s' "$bare" | grep -Eq '(^|[[:space:]])--delete([-=][a-z-]*)?([[:space:]]|$)'; then
        n=${#paths[@]}
        if [ "$n" -gt 0 ]; then
          hits "$eff_cwd" "${paths[$((n - 1))]}" && deny \
            "Blocked: rsync --delete into $WHY would wipe the workspace itself ($WORKSPACE and the shared root above it) down to the source tree."
        fi
      fi
      ;;
    xargs)
      # The paths arrive down the pipe, so this segment never carries one of its
      # own: `ls <shared> | xargs rm -rf` splits into a segment with the path and
      # a segment with the verb. When the verb is here, the whole line is what
      # has to be searched for a protected path.
      if printf '%s' "$bare" | grep -Eq "$DESTRUCTIVE_VERB"; then
        line_words=()
        read -ra line_words <<< "${cmd//[\"\']/}"
        hits "$eff_cwd" ${line_words+"${line_words[@]}"} && deny \
          "Blocked: this pipes $WHY — the workspace itself ($WORKSPACE and the shared root above it) — into a deleting xargs. Feed it the subtree you meant instead."
      fi
      ;;
    docker|podman|ssh|eval)
      # Wrappers this guard does not parse into a command of their own. It does
      # not try: it asks the cheaper question — does this line both delete and
      # name a protected root?
      if printf '%s' "$bare" | grep -Eq "$DESTRUCTIVE_VERB"; then
        # A bind mount is written `-v <host>:<container>`, which is where the
        # host path hides: `docker run -v <shared>:/w img rm -rf /w` deletes the
        # tree without ever naming it as an argument of a command.
        for a in ${paths+"${paths[@]}"} ${args+"${args[@]}"}; do
          case "$a" in /*:*) paths+=("${a%%:*}") ;; esac
        done
        hits "$eff_cwd" ${paths+"${paths[@]}"} && deny \
          "Blocked: this line deletes and names $WHY, the workspace itself ($WORKSPACE and the shared root above it). If that is not what it does, run it against the subdirectory you meant."
      fi
      ;;
  esac
done < <(printf '%s\n' "$cmd" | tr '\n;|&' '\n\n\n\n')

exit 0
