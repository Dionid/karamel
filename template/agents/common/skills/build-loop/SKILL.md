---
name: build-loop
description: Провести build loop для OpenSpec change с готовым пакетом спеки — реализация change: волны билдеров, ревью, ограниченные раунды исправлений, гейт решения раз на волну и resume по .build-loop/progress.md. Использовать при реализации change с готовой спекой или при возобновлении уже начатой работы.
---

# The build loop

Picks up where [`spec-loop`](../spec-loop/SKILL.md) leaves off: it starts only
from a change whose spec bundle is complete (that loop's steps 1-4: validated,
cross-read and coverage closed), and it is what makes that state resumable
across compactions. You are the **orchestrator**: you dispatch agents, keep the
ledger, and put in front of the user the few things only they can rule on. You
do not implement, test or review the change yourself — doing it inline burns the
context you need to keep driving.

Like `spec-loop`, `<spec-repo>` is the `always` repo holding `openspec/`; its
optional `specRoot` field is `<spec-root>`. Changes/specs live under
`<spec-repo>/<spec-root>/openspec/`. See [spec-loop §0](../spec-loop/SKILL.md)
and `spec-trace`'s `spec-checkout-lib.sh` when available.

Two agent types, in [`../../roles/`](../../roles/), prompts in
[prompts.md](prompts.md):

- **`builder`** — one per task group, dispatched **twice**: phase 1 writes the code
  and gets the checkers green, phase 2 writes the tests. The builders of a wave run
  concurrently within each phase.
- **`reviewer`** — **twice per wave**, once after each phase, across all of that
  wave's paths, with up to three fix rounds after each. On this loop it writes
  nothing in the spec: the spec came first, so code diverging from it is a
  finding for the user to rule on, not a spec to rewrite.

The code review checks implementation against the change's spec before tests
are written. Phase 2 then measures what execution catches beyond static review.

Prerequisites: existing worktree and a completed spec bundle (`openspec validate`
ok, cross-read and coverage closed) that the root itself recorded as `ПАКЕТ ГОТОВ → build loop открыт`
and handed over in the same turn; user approval of the spec is not required — only
the user's explicit opt-in puts a `ПРИНЯТ` line before it ([ledger.md](ledger.md)).
The spec ships in the task's MRs with the code (§7).
**A ledger line `Ревью спеки до кода: да — Track A, без build-loop` means
refuse** — no dispatch; implementing that spec is a new Track C task with its
own `<task>` and ledger ([ledger.md](ledger.md)). Read requirements
with `openspec-read` or `openspec show/status`; a `MODIFIED` delta amends the base
spec. A missing or incomplete bundle means return to `spec-loop`, not dispatch
builders; a significant spec change during the build goes back through
`spec-loop` (re-draft), with no re-approval gate.

## 1. The ledger — before dispatching anything

The ledger at **`worktrees/<task>/.build-loop/progress.md`** survives compaction
without entering a repo diff. Its format is in [ledger.md](ledger.md). Read it at
the start of every loop and after compaction.

```bash
cat worktrees/<task>/.build-loop/progress.md 2>/dev/null
```

Missing → create it. Matching task/change → resume per group and phase; completed
rounds stay complete. Append after each agent returns. The ledger and `git log`
outweigh recollection.

## 2. Waves — what may run at the same time

Dispatch follows `## Параллелизм` in `tasks.md`: waves run sequentially; groups in
one wave run concurrently, one builder each. Verify paths and dependencies against
code first ([waves.md](waves.md)); if adjusting groups, record why and leave
`tasks.md` unchanged. `## Порядок релиза` governs release, not dispatch.

## 3. Phase 1 — the code, then its review

**Read [phases.md](phases.md) before dispatch.** Send all wave builders in one
message with separate group ids/paths; do not pass another agent's findings as
fact. After all return, one reviewer covers every path in the wave.

- **Choose builder tier/effort from the catalog**, never below the role minimum
  in `agent-directed-routing`. Missing task fields or `**Образец:**` paths require
  clarification. Phase 2 uses the same builder minimum.
- **No tests in phase 1. None** — not a spec file, not a test-config file, not a
  placeholder. Test files in the diff mean the phase was not respected: say so
  rather than pretending the split held.
- **Builders never write in the canonical worktree.** Each group gets its own
  checkout via `agent-directed-routing`'s `writer.py spawn` (scope = group paths);
  you `submit` and `integrate` its patch hop by hop. An out-of-scope path fails the
  integration atomically (`failed` + recovery bundle) instead of landing as a
  collision to find later.
- Ticking `tasks.md` is the orchestrator's job (it lives in `<spec-repo>`, outside
  every builder checkout): builders report which items they completed, you tick them
  after integration.
- After integration verify with `git status --short` and `diff --stat`. Record and
  report every builder's **"not run"**.

## 4. Fix rounds — Blocking only, three of them

**Only Blocking is dispatched.** It goes straight back to the builder — **do not
stop for the user first**, and do not fix anything yourself.

**Should-fix is never dispatched automatically.** It is collected verbatim — its
`path:line` and its failure scenario — and so is everything under it, as a tail.
Where it goes depends on the phase, and that is §4b.

**One exception, and it is not negotiable: a finding that contradicts the
change's spec stops the round.** No builder can settle it — put the finding and the spec
text in front of the user and ask which governs, while everything else dispatches.

Rounds `R = 1, 2, 3`, **counted per phase per wave**, not per group — resume the
builders in round 1, fresh ones at `strong/high` in rounds 2 and 3, each getting
its whole Blocking list at once and closed by one re-review scoped to just those
findings. **Round 3 ends the budget: there is no round 4.** Who fixes what:
[fix-rounds.md](fix-rounds.md).

## 4b. The ruling gate — once per wave, at the end of phase 1

**One gate per wave, and it sits between the two phases.** After the code phase's
Blocking rounds close, the loop stops and puts one numbered list in front of the
user: the **Blocking that survived three rounds** (with what each round changed and
why it failed), **every Should-fix** of the code phase, and the tail as an
appendix — each item with `path:line`, what breaks, and **your recommendation and
its reason**. Nothing is filtered by you: a Should-fix you find unconvincing is
still shown, because deciding what is worth changing is the point of the gate.

**Here and not later, because this is where the code has to stop moving**:
everything downstream assumes the implementation is settled, and a Should-fix ruled
on after the suites exist means rewriting them.

Whatever they pick is dispatched as **one round** on a **separate budget** — it
does not consume R1–R3 and gets no second automatic attempt; still failing, it goes
back to them. What they decline is **parked in the ledger with their ruling**,
reported at the close, and never re-raised by a later review of the same code.

**Phase 2 has no gate**, and its findings go two ways: Blocking through the three
rounds of §4, and a Blocking still open after them **straight to the user, out of
band** — that is a stopped wave, not something to schedule. Its Should-fix are
collected and ruled on **once, at the close** (§7), where the user sees them
together with the final full-pass findings. The list's shape, how to ask, and what
to do with each answer: [fix-rounds.md](fix-rounds.md).

## 5. Phase 2 — the tests, then their review

**The entry condition, and it is the one that gets rushed: every finding of phase 1
has an outcome.** Blocking came back ADDRESSED, or the user ruled on it at the
gate; every Should-fix has their ruling, and the ones they picked came back
ADDRESSED too. A Blocking the user told you to fix and that still fails does not
enter phase 2 — it is BLOCKED and it stops there. A finding they declined is
closed, not open.

**Procedure: [phases.md](phases.md)** — the same groups again (resumed where their
builders survive), then one `reviewer` with the test-pass prompt, whose question is
narrow: do these suites assert the spec, or merely agree with the code they were
written from? Its Blocking goes through §4 unchanged; its Should-fix waits for the
close, per §4b, and is not dispatched on your own authority either.

**The wave's barrier is the end of this**, not the end of phase 1: nothing
downstream starts until the test review has closed.

## 6. What reaches the user

The user hears from you at these moments and no others:

1. **the ruling gate** — once per wave, between the phases, per §4b. The one stop
   the loop makes by design: one per wave, three on a three-wave change;
2. **a finding that contradicts the spec** — immediately, per §4, without
   waiting for the gate;
3. **a Blocking still open after phase 2's three rounds** — out of band, the wave
   is stopped, and every wave behind it with it;
4. **a builder's "not run"**, or **a finding the user picked that failed anyway** —
   both reported when they happen, neither folded into a summary at the end;
5. **the close** — one last ruling list: **every phase-2 Should-fix of every wave**
   plus the final full pass's own, then what they declined earlier with their
   rulings, and **the measurement**: how many phase-2 findings turned out to be
   code fixes, i.e. how often the tests caught what the code review had passed. It
   is the argument for keeping or dropping the split ([close.md](close.md)).

## 7. Close

Five steps, in this order, detailed in [close.md](close.md):

1. **one `reviewer` over the whole worktree**, full-pass prompt — the first read of
   the change as a whole. A single-wave change skips it;
2. **the closing ruling** — every phase-2 Should-fix of every wave, plus the full
   pass's own findings, in one list. The Blocking of the full pass goes through §4
   first; this is what the phase-2 gate was traded away for, so it is not optional;
3. **`commit-and-mr` for the code repos**;
4. **the spec-trace skill (if this workspace has one, e.g. `.claude/skills/spec-trace/`)
   over `<task>`**, then `commit-and-mr` for `<spec-repo>` — the trace can only
   name PRs that already exist, which is why the spec repo is last. No such
   skill → note in the spec repo's commit what code PRs this change shipped with,
   by hand;
5. **spec-link, if that skill exists**, then hand the PR links back in the order
   of the change's `## Порядок релиза` table. No `COMMIT_SHA=` and no `MR_URL=`
   from `commit-and-mr` means the task is **not** done: a pre-commit hook failed,
   and `--no-verify` is never the answer.

## Red flags

Never skip ledger reads, phase/wave barriers, code verification, review, a user
ruling, or the phase-2 code-fix count. Do not write tests in phase 1, dispatch
Should-fix without a ruling, run overlapping same-repo groups, exceed three fix
rounds, or commit the spec repo before code repos. Follow [phases.md](phases.md),
[fix-rounds.md](fix-rounds.md), and [close.md](close.md) for the exact gates.
