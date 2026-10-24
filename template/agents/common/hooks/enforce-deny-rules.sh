#!/usr/bin/env bash
# PreToolUse hook: enforce this workspace's permissions.deny for agents that do
# NOT enforce it themselves.
#
# Claude Code applies `permissions.deny` from .claude/settings.json natively, so
# for it this hook is redundant and harmless. Codex does not: it has no such
# setting at all, so without this hook the deny list applies to Claude Code
# only. Malformed input is allowed; recognized unsafe actions are blocked.
#
# So the rules live here, next to block-secret-reads.sh, which already runs
# under Codex for the same reason. One deny list, in .claude/settings.json,
# read live — not a second copy that drifts.
#
# What is enforced, in order:
#   1. .claude/ itself — this hook and the secret hook read their rules from
#      there on every call, so an agent that may rewrite them is unguarded from
#      the next tool call on.
#   2. permissions.deny — Bash(...)/Read(...)/Edit(...)/Write(...) globs.
#
# NOT enforced here: the secret rules. block-secret-reads.sh owns those and is
# registered separately; duplicating them would give two places to fix.
#
# Payload shapes, and why both are read: Claude Code sends snake_case with the
# command as a string (`.tool_input.command`); Codex CLI sends camelCase
# (`.toolInput.command`) and its shell tools carry argv as an array. A hook that
# reads only the Claude Code shape would see an empty command under Codex and
# allow everything — silently, which is worse than not being installed. The
# DECISION format is already common to both.
#
# Fails OPEN, except where a check itself failed: a crashing hook must not make
# an agent look broken. Every skipped check says so on stderr.
#
# agents/common/tests/enforce-deny-rules.test.py runs every branch in all
# three payload shapes, and `make lint` runs it.
set -uo pipefail

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
skip() { printf 'enforce-deny-rules.sh: %s\n' "$1" >&2; }

command -v jq >/dev/null 2>&1 || { skip "no jq — the deny list is NOT enforced"; exit 0; }

payload=$(cat)
[ -n "$payload" ] || exit 0

tool=$(printf '%s' "$payload" | jq -r '[.tool_name?, .toolName?] | map(select(. != null)) | first // ""' 2>/dev/null) || exit 0
cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null)

# Same unwrapping as block-secret-reads.sh: an argv array is read joined AND,
# when it is a `bash -lc "…"` wrapper, as the script argument on its own — the
# segment patterns below anchor to the start of a command, and joined argv moves
# that anchor.
cmd=$(printf '%s' "$payload" | jq -r '
  def unwrap:
    map(tostring) as $a
    | [ $a | join(" ") ]
      + [ ($a | to_entries | map(select(.value | test("^-[A-Za-z]*c$"))) | first) as $f
          | if $f != null and ($a | length) > ($f.key + 1) then $a[$f.key + 1] else empty end ]
    | join("\n");
  def text: if type == "array" then unwrap else tostring end;
  [ .tool_input?.command?, .toolInput?.command? ]
  | map(select(. != null)) | first // "" | text
' 2>/dev/null)

path=$(printf '%s' "$payload" | jq -r '
  [ .tool_input?.path?, .toolInput?.path?,
    .tool_input?.file_path?, .toolInput?.file_path? ]
  | map(select(. != null)) | first // ""
' 2>/dev/null)

# Tool classification. Both vocabularies are listed because one hook serves both
# agents: Claude Code names on the left of each group, Codex on the right.
is_shell=0
case "$tool" in
  Bash|terminal|execute_code|shell|local_shell|exec_command|unified_exec) is_shell=1 ;;
esac
is_write=0
case "$tool" in
  Edit|Write|NotebookEdit|write_file|patch|apply_patch|edit_file) is_write=1 ;;
esac
is_read=0
case "$tool" in Read|read_file|view_image) is_read=1 ;; esac

# Nothing to judge.
[ "$is_shell" = 1 ] || [ "$is_write" = 1 ] || [ "$is_read" = 1 ] || exit 0

# ── Where the workspace is ───────────────────────────────────────────────────
# harness.json is the root marker every script in this workspace climbs to. The
# container sets WORKSPACE, so that wins when present.
find_root() {
  local dir="${1:-$PWD}"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -e "$dir/harness.json" ] && { printf '%s' "$dir"; return 0; }
    dir=$(dirname "$dir")
  done
  return 1
}
WORKSPACE="${WORKSPACE:-$(find_root "${cwd:-$PWD}" || find_root "$PWD" || true)}"
if [ -z "$WORKSPACE" ]; then
  skip "workspace root not found (no harness.json above cwd) — the deny list is NOT enforced"
  exit 0
fi
SETTINGS="${WORKSPACE_DENY_SETTINGS:-$WORKSPACE/.claude/settings.json}"

# Resolve a file argument the way the tool will. Relative paths hang off the
# session's cwd. ./ and ../ are collapsed textually rather than with realpath:
# realpath would resolve symlinks out of the workspace, and a file about to be
# written does not exist yet.
abs_path=""
if [ -n "$path" ]; then
  case "$path" in
    /*) abs_path="$path" ;;
    *)  abs_path="${cwd:-$WORKSPACE}/$path" ;;
  esac
  while [[ "$abs_path" == *"/./"* ]]; do abs_path="${abs_path//\/.\//\/}"; done
  while [[ "$abs_path" =~ (^|/)[^/]+/\.\.(/|$) ]]; do
    abs_path=$(printf '%s' "$abs_path" | sed -E 's![^/]+/\.\.(/|$)!!')
  done
fi

# Simple commands, so `ls && rm -rf /` is caught where a whole-string match
# would miss it. Claude Code matches the whole string; this is deliberately the
# stricter of the two.
segments=()
if [ "$is_shell" = 1 ] && [ -n "$cmd" ]; then
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg="${seg%"${seg##*[![:space:]]}"}"
    [ -n "$seg" ] && segments+=("$seg")
  done < <(printf '%s\n' "$cmd" | tr '\n;|&' '\n\n\n\n')
fi

# ── 1. The guard's own inputs ────────────────────────────────────────────────
# This hook and block-secret-reads.sh read their rules out of .claude/ on every
# call. An agent that rewrites them is unguarded from the next tool call on, so
# they are not writable through any agent — the change belongs on the host,
# where it is reviewed. Reading them is fine and often useful.
CLAUDE_DIR="$WORKSPACE/.claude"
if [ "$is_write" = 1 ] && [ -n "$abs_path" ]; then
  case "$abs_path" in
    "$CLAUDE_DIR"/*)
      deny "Blocked: $CLAUDE_DIR is where the deny list and the secret hook are read from, so no agent may write there. Edit the owning layer under agents/ or config/agents/ on the host, then make sync."
      ;;
  esac
fi
if [ "$is_shell" = 1 ] && [ -n "$cmd" ]; then
  if printf '%s' "$cmd" | grep -Eq '\.claude/(settings|hooks|agents|skills)' \
    && printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])(sed[[:space:]]+-i|perl[[:space:]]+-i|tee|truncate|dd|rm|mv|cp|chmod|chown|install|patch|ln)([[:space:]]|$)|>{1,2}[[:space:]]*[^&[:space:]]*\.claude'; then
    deny "Blocked: this would modify $CLAUDE_DIR, which is where the deny list and the secret hook are read from. Edit the owning layer on the host, then make sync."
  fi
fi

# ── 2. permissions.deny from .claude/settings.json ───────────────────────────
# One source of truth with Claude Code. Entries are Claude Code globs:
#   Bash(kubectl apply*)   Read(**/.env)   Edit(/packages/**)
# A leading / in a path glob means the project root, which here is $WORKSPACE.
if [ ! -r "$SETTINGS" ]; then
  skip "$SETTINGS unreadable — the deny list is NOT enforced"
  exit 0
fi
deny_list=$(jq -r '.permissions.deny // [] | .[]' "$SETTINGS" 2>/dev/null) || {
  skip "$SETTINGS is not valid JSON — the deny list is NOT enforced"
  exit 0
}
[ -n "$deny_list" ] || exit 0

while IFS= read -r rule; do
  [ -n "$rule" ] || continue
  kind="${rule%%(*}"
  pattern="${rule#*(}"
  pattern="${pattern%)}"
  [ "$kind" = "$rule" ] && continue   # not a Kind(pattern) entry

  case "$kind" in
    Bash)
      [ "$is_shell" = 1 ] || continue
      for seg in ${segments+"${segments[@]}"}; do
        # Unquoted RHS: this is glob matching, which is what the rule is.
        # shellcheck disable=SC2053
        if [[ "$seg" == $pattern ]]; then
          deny "Blocked by permissions.deny in .claude/settings.json: '$rule'. This workspace forbids it in Claude Code too — infrastructure changes ship as manifests through an MR, and history is never rewritten on a remote."
        fi
      done
      ;;
    Read|Edit|Write)
      [ -n "$abs_path" ] || continue
      if [ "$kind" = "Read" ]; then
        [ "$is_read" = 1 ] || continue
      else
        [ "$is_write" = 1 ] || continue
      fi
      abs_pattern="$pattern"
      case "$pattern" in
        /*) abs_pattern="$WORKSPACE$pattern" ;;
      esac
      # shellcheck disable=SC2053
      if [[ "$abs_path" == $abs_pattern ]] || [[ "$abs_path" == $pattern ]]; then
        deny "Blocked by permissions.deny in .claude/settings.json: '$rule'. Path: ${abs_path#"$WORKSPACE"/}."
      fi
      ;;
  esac
done <<< "$deny_list"

exit 0
