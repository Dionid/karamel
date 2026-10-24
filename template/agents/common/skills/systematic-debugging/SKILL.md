---
name: systematic-debugging
description: Найти root cause прежде чем чинить баги, падающие тесты, красные pipeline, flaky suites, проблемы в проде и неудавшиеся предыдущие фиксы. Использовать цикл investigate/compare/hypothesise/fix.
---

# Systematic debugging

**Core principle: always find the root cause before attempting a fix. A
symptom fix is a failure, even when the symptom goes away.**

## The iron law

```text
NO FIX WITHOUT ROOT CAUSE INVESTIGATION FIRST.
```

If phase 1 is not finished, you may not propose a fix.

Use this for every technical failure: failing test, bug report, red pipeline,
wrong balance, stuck withdrawal, slow endpoint, broken build, flaky e2e.
Especially use it when it feels unnecessary — under time pressure, on an
"obvious" one-liner, or when you have already tried something and it did not
work.

## Phase 1 — root cause investigation

1. **Read the error completely.** The whole stack trace, the exit code, the
   line numbers. Errors usually name their own cause; skimming loses it.
2. **Reproduce it.** What are the exact steps, and does it happen every time?
   Not reproducible → gather more data. Do not guess at a fix for something you
   cannot trigger.
3. **Check what changed.** `git log`, `git diff` against the base branch, a
   recent shared-lib bump, a migration, a config or env change, a deploy. Use
   the GitHub UI or a read-only `gh run view` / `gh run view --log-failed` for the
   pipeline and job trace, not your memory of it.
4. **Instrument every boundary — before proposing anything.** These are
   multi-component systems: app → backend → shared lib → database → chain
   indexer, or CI → build → deploy → e2e. For each boundary, log what goes in
   and what comes out, then run **once** and read the evidence to find which
   hop is wrong. Narrow to a component before you theorise about it.
5. **Look at the real data.** `db-query` against main-db / ledger-db / cards-db
   answers "what does the row actually say" in seconds. Never design a fix
   against an assumed row shape; prod URIs are read-only diagnostics and exist
   for exactly this.
6. **Trace the bad value backwards.** Where the error surfaces is rarely where
   it originates — see [root-cause-tracing.md](root-cause-tracing.md).

## Phase 2 — pattern analysis

- Find something similar that **works** in the same codebase, and read it in
  full. Partial reading of the reference is how the bug got written.
- List every difference between the working and the broken path, including the
  ones you are sure cannot matter.
- Note what the broken code depends on: config, env vars, migrations, a shared
  lib version, an upstream service.

## Phase 3 — hypothesis

State it out loud, specifically: *"X is the root cause, because Y."* Then test
it with the **smallest possible change**, one variable at a time.

- Confirmed → phase 4.
- Not confirmed → form a *new* hypothesis. Do not stack another change on top
  of the failed one; revert it first.
- Do not understand something? Say "I don't understand X" and go find out.
  A guess dressed as an explanation costs more than the question.

## Phase 4 — fix

1. **Write the failing test first.** Simplest possible reproduction, in the
   layer that owns the behaviour. You must see it red before the fix.
2. **One fix, at the root.** No bundled refactoring, no "while I'm here".
3. **Verify** — the new test green, the surrounding suites still green, the
   original symptom gone. Use `verification-before-completion` before saying so.
4. **Prove the test tests the bug**: revert the fix, watch the test fail,
   restore the fix, watch it pass. A regression test that never went red guards
   nothing.

## The circuit breaker — three failed fixes

Count your attempts. After the **third** fix that did not work:

**Stop. Do not attempt fix #4.**

That pattern — each fix revealing a new problem somewhere else, each one needing
"just a bit of refactoring", each one creating a symptom elsewhere — is not a
sequence of wrong hypotheses. It is a wrong architecture, or a wrong model of
the system. Take it to the user with what you learned: the three attempts, what
each one revealed, and the structural question you now have.

## Red flags — stop, return to phase 1

- "Quick fix now, investigate later"
- "Let me just try changing X and see"
- listing fixes before having traced anything
- changing several things at once so you cannot tell what worked
- "I don't fully understand it, but this might work"
- "one more attempt" after two or more failures
- adding a retry, a `sleep`, or a widened timeout to make a failure go away

| Excuse | Reality |
|---|---|
| "It's simple, no process needed" | Simple bugs have root causes too, and the process is fast on them. |
| "It's urgent" | Guess-and-check thrashing is slower than investigating once. |
| "I'll investigate after this fix works" | The first fix sets the pattern, and nobody comes back. |
| "The reference is long, I'll adapt it" | Partial understanding guarantees the next bug. |
| "I can see the problem" | You can see the symptom. |
| "Just add a retry" | That hides a race instead of finding it. |

## When there really is no root cause

Sometimes it is genuinely environmental, timing-dependent, or upstream. Then:
document what you ruled out and how, implement deliberate handling (retry with
a reason, an explicit timeout, a clear error), and add the logging that would
identify it next time. Say that this is what you did.

Most "no root cause" conclusions are unfinished investigations.
