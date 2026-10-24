#!/usr/bin/env bash
# PreToolUse hook: refuse Claude Code's own schedulers.
#
# Seven entry points schedule work inside the CLI rather than in the runtime:
#   CronCreate / CronList / CronDelete   a job in the CLI's own store, not the
#                                        runtime's: it dies with the session,
#                                        and a recurring one also after 7 days
#   ScheduleWakeup                       /loop's dynamic pacing: the same
#                                        in-session repetition, under its own
#                                        tool name rather than Skill(loop)
#   RemoteTrigger create/update/run/     a routine on remote claude.ai, outside
#   create_webhook_trigger               this runtime's limits and visibility
#   Skill(schedule)                      a scheduled agent on remote claude.ai
#   Skill(loop)                          a prompt repeated inside this session
#
# RemoteTrigger's read actions (list, get, list_runs, get_run_log) are NOT
# denied: reading a routine somebody already made is how a question about one
# gets answered, and refusing it would only push the same answer into a raw
# HTTP call. What is refused is arming or firing one from here.
#
# Why a hook and not one more permissions.deny line: deny is enforced natively
# by Claude Code but not by every agent, and two of these carry the decision in
# a tool *argument* rather than the tool name — a glob over names cannot see
# `Skill(loop)` or `RemoteTrigger create`. This answers one question about one
# resolved call, which is the kind of question that has a finite answer.
#
# What replaces them is in "Расписания" in AGENTS.md: recurring work is a
# Cron Job of the runtime, which outlives the session that asked for it.
#
# Fails OPEN, and says so on stderr when it does: a crashing guard must not make
# an agent look broken.
#
# stdin: hook JSON. stdout: PreToolUse decision JSON when denying.
# Both agents feed this and they disagree about the input shape: Claude Code
# sends snake_case, Codex CLI sends camelCase. Both are read below, the same
# unwrapping as block-secret-reads.sh — Codex has no cron tools of its own
# today, and a guard that silently stopped applying if it grew some would be
# worse than one extra jq path.
#
# agents/common/tests/block-claude-crons.test.py runs every branch in both
# payload shapes, and `make lint` runs it.
set -uo pipefail

REFERENCE='Повторяющаяся работа заводится Cron Job рантайма — см. «Расписания» в AGENTS.md.'

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
skip() { printf 'block-claude-crons.sh: %s\n' "$1" >&2; }

command -v jq >/dev/null 2>&1 || { skip "no jq — Claude Code schedulers are NOT blocked"; exit 0; }

payload=$(cat)
[ -n "$payload" ] || exit 0

tool=$(printf '%s' "$payload" | jq -r '[.tool_name?, .toolName?] | map(select(. != null)) | first // ""' 2>/dev/null) || exit 0

case "$tool" in
  CronCreate | CronList | CronDelete)
    deny "$tool — планировщик самой сессии Claude Code: задача живёт в хранилище CLI, а не рантайма, и умирает вместе с сессией (повторяющаяся — ещё и через семь дней), то есть выглядит заведённой и молча перестаёт срабатывать. $REFERENCE"
    ;;
  ScheduleWakeup)
    deny "ScheduleWakeup — тот же повтор внутри сессии, что и скилл loop, но под своим именем инструмента: продолжение живёт ровно столько, сколько живёт сессия. $REFERENCE"
    ;;
  RemoteTrigger)
    action=$(printf '%s' "$payload" | jq -r '[.tool_input?.action?, .toolInput?.action?] | map(select(. != null)) | first // ""' 2>/dev/null) || exit 0
    case "$action" in
      create | update | run | create_webhook_trigger)
        deny "RemoteTrigger $action заводит или запускает routine во внешнем планировщике claude.ai — вне этого рантайма, его наблюдаемости и его лимитов. $REFERENCE"
        ;;
    esac
    ;;
  Skill)
    skill=$(printf '%s' "$payload" | jq -r '[.tool_input?.skill?, .toolInput?.skill?] | map(select(. != null)) | first // ""' 2>/dev/null) || exit 0
    case "$skill" in
      schedule)
        deny "Скилл schedule заводит задачу во внешнем планировщике claude.ai — вне этого рантайма, его наблюдаемости и его лимитов. $REFERENCE"
        ;;
      loop)
        deny "Скилл loop повторяет промпт внутри сессии и умирает вместе с ней. $REFERENCE"
        ;;
    esac
    ;;
esac

exit 0
