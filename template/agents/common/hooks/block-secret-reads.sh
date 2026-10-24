#!/usr/bin/env bash
# PreToolUse/Bash hook: refuse commands that would put a secret into the
# transcript. The permissions.deny rule on Read(**/.env) only covers the Read
# tool; this covers the shell, which is where the leak actually happened.
#
# Allowed (the sanctioned pattern from AGENTS.md):
#   set -a; . ./.env; set +a          — sourcing, no value printed
#   psql "$MAIN_DEV_DB_URI" …        — value passed by reference
# Denied: reading a .env file with any reader, dumping the environment,
# printing a secret-named variable, and ${SECRET:-default} expansion.
#
# stdin: hook JSON. stdout: PreToolUse decision JSON when denying.
# The matched command is never echoed back — it may itself contain the secret.
#
# Two agents feed this, and they disagree about the input only. Claude Code
# sends snake_case with the command as a string (`.tool_input.command`); Codex
# CLI sends camelCase (`.toolInput.command`) and its shell tool carries argv as
# an array. Both are read below; the DECISION format is already common to both
# (hookSpecificOutput.permissionDecision = "deny").
#
# agents/common/tests/block-secret-reads.test.py runs every rule below in all three
# shapes, and `make lint` runs it — a rule that quietly stops matching denies
# nothing and says nothing about it.
set -uo pipefail

# URI/DSN/DB_URL are in here because a postgres connection URI embeds the
# password — printing one leaks exactly as much as printing $..._PASS did.
SECRET='[A-Za-z_][A-Za-z0-9_]*(TOKEN|PASS|PASSWORD|SECRET|KEY|CREDENTIAL|URI|DSN|DB_URL)[A-Za-z0-9_]*'
READER='(cat|bat|less|more|head|tail|sed|awk|nl|strings|xxd|od|hexdump|base64|cut|tr|rev|tac|tee|pbcopy|wc|grep|egrep|fgrep|rg|ag|ack|jq|yq|python|python3|node|bun|deno|ruby|perl|php|dd|cp|mv|rsync|scp|curl|split|paste|join|column|fold|shuf|diff|cmp|comm|shasum|md5|open|code|vim|vi|nano|emacs|xargs|read)'

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

# An argv array is inspected TWICE, on two lines: joined as it came, and — when
# it is a `bash -lc "…"` wrapper — the script argument on its own.
#
# The join alone is not enough, and this is the whole reason the array case gets
# special handling. Half the patterns below anchor to the start of a command
# (`env`, `printenv $SECRET`, `echo $SECRET`), because that is where a command
# sits in a shell line. Joined, the same call reads `bash -lc env`, the anchor
# does not match, and a whole-environment dump goes through. Unwrapping restores
# the invariant those patterns are written against.
#
# Both lines are kept rather than only the script: the segment loop splits on
# newlines anyway, so an argv shape this does not recognise still gets read in
# full instead of being silently dropped.
cmd=$(jq -r '
  def unwrap:
    map(tostring) as $a
    | [ $a | join(" ") ]
      + [ ($a | to_entries | map(select(.value | test("^-[A-Za-z]*c$"))) | first) as $f
          | if $f != null and ($a | length) > ($f.key + 1) then $a[$f.key + 1] else empty end ]
    | join("\n");
  def text: if type == "array" then unwrap else tostring end;
  [ .tool_input?.command?, .toolInput?.command? ]
  | map(select(. != null)) | first // "" | text
' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# ${SECRET:-default} / ${SECRET-default} / ${SECRET:=default} all expand to the
# VALUE when the variable is set. ${SECRET:+placeholder} is the safe form.
if printf '%s' "$cmd" | grep -Eq "\\\$\{$SECRET:?[-=]"; then
  deny 'Blocked: ${VAR:-default} on a secret-named variable expands to the secret itself. Use ${VAR:+set} to test presence without printing the value.'
fi

# curl -v / --trace prints request headers, including PRIVATE-TOKEN.
if printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])curl([[:space:]]|$)' \
  && printf '%s' "$cmd" | grep -Eq '(^|[[:space:]])(-v|--verbose|--trace|--trace-ascii)([[:space:]]|$)' \
  && printf '%s' "$cmd" | grep -Eq "\\\$\{?$SECRET"; then
  deny 'Blocked: curl --verbose/--trace echoes request headers, which would print the token. Drop the verbose flag; use -w "%{http_code}" or -i for status and response headers.'
fi

# Split into simple commands so "cat foo.txt && . ./.env" is not a false hit.
printf '%s\n' "$cmd" | tr '\n;|&' '\n\n\n\n' | while IFS= read -r seg || [ -n "$seg" ]; do
  [ -n "${seg//[[:space:]]/}" ] || continue

  # Sourcing is the sanctioned way to load .env — allow and move on.
  printf '%s' "$seg" | grep -Eq '^[[:space:]]*(\.|source)[[:space:]]' && continue

  # Whole-environment dumps.
  if printf '%s' "$seg" | grep -Eq '^[[:space:]]*(env|printenv|export[[:space:]]+-p|set)[[:space:]]*$'; then
    deny 'Blocked: this dumps the whole environment, secrets included. Name the specific variable you need instead.'
  fi
  if printf '%s' "$seg" | grep -Eq "^[[:space:]]*printenv[[:space:]]+$SECRET"; then
    deny 'Blocked: printenv on a secret-named variable prints its value.'
  fi

  # echo/printf of a secret-named variable. ${VAR:+placeholder} is the safe
  # presence test — drop those before looking for a real expansion.
  probe=$(printf '%s' "$seg" | sed -E "s/\\\$\{$SECRET:?\+[^}]*\}//g")
  if printf '%s' "$seg" | grep -Eq '^[[:space:]]*(echo|printf|print)[[:space:]]' \
    && printf '%s' "$probe" | grep -Eq "\\\$\{?$SECRET"; then
    deny 'Blocked: this would print a secret-named variable into the transcript. Report whether it is set, not what it contains.'
  fi

  # Any reader pointed at a real .env (templates are fine — they hold no secrets).
  stripped=$(printf '%s' "$seg" | sed -E 's/\.env\.(example|sample|template|dist)//g')
  if printf '%s' "$stripped" | grep -Eq '\.env' \
    && printf '%s' "$stripped" | grep -Eq "(^|[[:space:]/=\"'\(])$READER(\$|[[:space:]])"; then
    deny 'Blocked: reading .env would put credentials in the transcript. Source it instead (set -a; . ./.env; set +a) and pass the variable by name, or read .env.example for the variable names.'
  fi
done

exit 0
