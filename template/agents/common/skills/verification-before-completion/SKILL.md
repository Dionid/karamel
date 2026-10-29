---
name: verification-before-completion
description: Проверять перед тем, как заявить done, fixed, green, passed, succeeded или ready. Использовать перед отчётами о завершении, commit-and-mr, заявлениями о pipeline/test/build и заявлениями subagent об успехе.
---

# Verification before completion

**Core principle: evidence before claims, always.**

## The iron law

```text
NO COMPLETION CLAIM WITHOUT FRESH VERIFICATION OUTPUT IN THIS SAME TURN.
```

A command you ran five messages ago does not prove the state after the edit you
made since. Neither does a subagent's report, a green checker in a different
repo, or your own confidence.

## The gate

Before any statement that work is done, correct, passing or fixed:

1. **Identify** — which single command proves this exact claim?
2. **Run** it, in full. Not a subset, not `--onlyChanged`, not one file.
3. **Read** the whole output: exit code, failure count, the last lines.
4. **Decide** — does the output actually support the claim?
   - No → state the real status, with the output.
   - Yes → state the claim *with* the evidence.

Skipping a step is not a shortcut, it is a false report.

## One gate, one status

Run distinct verification commands in distinct tool calls so each exit status is
visible. Never use a semicolon chain such as `make check; check.sh; make lint` as
evidence: a later success replaces an earlier failure as the shell's final status.

If several commands genuinely form one atomic gate, put them in a checked-in Bash
script that starts with `set -euo pipefail`. Do not improvise a multiline shell
program in a tool argument. The workspace shell is zsh; scalar values do not gain
Bash-style word splitting. Use literal arguments or an array expanded as
`"${items[@]}"`.

## What proves what, in this workspace

| Claim | What proves it | What does **not** |
|---|---|---|
| "Lint is clean" | `npm run lint …` exit 0 | typecheck passing |
| "It compiles" | `npm run build` / `tsc -P …` exit 0 | lint passing — the linter is not the compiler |
| "Unit tests pass" | `npm run test:unit -w <svc>`, 0 failed | a previous run, before your last edit |
| "Integration tests pass" / "E2E passes" | the CI job for *that* commit, with its link — integration and e2e run in CI only | unit tests passing, or a local run. Not run in CI yet → **«integration не запускались локально»**, never "passing" |
| "The bug is fixed" | the original failing reproduction, now green | the code looks right now |
| "The regression test works" | red-green: revert the fix → test **fails** → restore → passes | the test passes once |
| "The migration landed" | `db-query` against the real database | the migration file exists in the diff |
| "The pipeline is green" | GitHub UI job status for *that* commit | the previous pipeline, or a local build |
| "The builder agent finished" | `git -C worktrees/<task>/<repo> status/diff` shows the changes, tests included | the agent's final message |
| "The task is committed and has a PR" | `COMMIT_SHA=` **and** `MR_URL=` in `commit-and-mr` output | the skill was invoked |
| "Spec requirements are met" | the delta spec re-read line by line against the diff | tests passing |

## Subagents are reports, not evidence

`builder` and `reviewer` return prose. Prose can be wrong — an agent that hit a
checker failure and ran out of room can still close with an optimistic summary.
Before you repeat any agent's success claim to the user or move to the next step,
check the artifact yourself: `git status`, `git diff --stat`, the file it says it
wrote, the checker it says it ran.

A `builder` tested its own code, so its green counts carry a second question
beyond "did this run": *does the suite assert the spec, or the implementation?*
That one is the wave `reviewer`'s job — never treat a builder's own green as the
review having happened.

## Pre-commit hooks

`commit-and-mr`'s `run.sh` runs under `set -euo pipefail`: a failing husky /
lint-staged hook kills it before the push and before the PR. **No `COMMIT_SHA=`
line and no `MR_URL=` line means the task is not done.** Report the hook's
output as a failure. Never `--no-verify`, never edit the hook.

## Red flags — stop and run the command

- "should work now", "probably", "seems to", "looks correct"
- "Готово!" / "Perfect!" / "All set" written before any command ran in this turn
- about to call `commit-and-mr` on work whose checkers you have not seen green
- passing a subagent's success report upward as fact
- partial verification standing in for the full suite ("the one test I changed passes")
- a semicolon-separated verification chain whose last command passed
- a loop over `$items` whose correctness depends on implicit word splitting
- "just this once, it's a one-line change"

| Excuse | Reality |
|---|---|
| "It's a one-liner" | One-liners break builds. The command takes seconds. |
| "I'm confident" | Confidence is not evidence. |
| "The linter passed" | The linter does not compile, and does not run tests. |
| "The agent said it succeeded" | Verify independently — `git diff` is cheap. |
| "The e2e env is down, but it'd pass" | Then it is **not run**. Say that. |
| "I'll just run integration locally to be sure" | Integration and e2e run in CI only; the human sets `WORKSPACE_ALLOW_LOCAL_INTEGRATION=1` and asks for a local run, and then it is reported as local at their request. |
| "I ran it before the last edit" | The last edit is exactly what is unverified. |
| "Different wording, so the rule doesn't apply" | Spirit over letter. Any implication of success is a claim. |

## Reporting an honest failure

A red result reported plainly is a *successful* turn. Give the command, the
relevant output, and what you think it means — then either fix it or hand it
back. Do not soften it, do not bury it under what did work, and do not proceed
to the next step as though it were green.
