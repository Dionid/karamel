# The two phases of a wave

Reference for §3 and §5 of [SKILL.md](SKILL.md). **Read the half you are
about to dispatch before dispatching it** — the body carries the order and the two
gates, not the procedure.

## Phase 1 — the code

For each group first `writer.py spawn` its disposable checkout (scope = the group's
paths; see `agent-directed-routing`), then send the builders of **every group in
the wave in one message** (several `Agent` calls in the same response) so they run
concurrently, each in its own checkout. When a builder returns, `submit` and
`integrate` its patch into the canonical repo before anything is verified or
reviewed there. This holds for every
dispatch in the loop — fix rounds and phase 2 included. Each one implements its
group's `tasks.md` items and gets that repo's lint, typecheck/compile and build
green — **and writes no tests at all**, not a spec file, not a test-config file,
not a placeholder. Say it in the prompt; the agent's own instructions say it too,
and it is still the instruction most likely to be quietly disobeyed.

Only start this phase after the `ПАКЕТ ГОТОВ → build loop открыт` line is recorded in the
ledger. A capacity note about who *could* build something is not a queued
builder — the card/process is created here, at the build-loop boundary.

**Give each one the worktree path, the change name, and its group id and paths —
never a retelling of what another agent did.** It holds sideways too: never tell
G3's builder what G2's builder did. They are meant to read the code themselves; a
summary passed between them substitutes your paraphrase for it.

Verify rather than believe: `integrate` already refuses any path outside the
group's reserved scope, and `git -C worktrees/<task>/<repo> status --short` /
`diff --stat` after the integration say what actually changed. A refused patch
(`failed`, with its recovery bundle) is reported to the user, never retried by
hand in the canonical tree. **Test files in that diff mean phase 1 was not respected**: say
so, and let the review read them as part of the diff rather than pretending the
split held. An agent's closing paragraph is a report, not evidence (apply the
workspace's verification-before-completion rule if it has one, and the same
principle regardless): a builder's green claim gets checked at the review, and a
builder's **"not run"** goes to the ledger and to the user now.

Two things close a group later than its own build — a **contract** group (one
that publishes a package other groups' repos depend on) needs the publish *and*
the consumers' version bump; and **`<spec-repo>` belongs to no group**, you keep
the spec in step yourself, so no agent gets a checkout of it to write.

## The code review

One `reviewer`, over **all of the wave's groups' paths together**, once every
builder in the phase has returned. Not one review per group: the groups were built
by agents blind to each other, so the seam between them is where the defects are,
and only a review that sees both sides finds them. Do not dispatch it early
either — a review of two finished groups out of three costs a full pass and says
nothing about the third.

Put in the prompt that nothing has been executed: lint and a compiler do not prove
a query runs, a dependency is wired or a migration applies, and a suspicion about
runtime the reviewer cannot trace in the code is a question, not a finding.

Tell it what the severities now do, because it decides how carefully they are
labelled: **Blocking is fixed automatically, Should-fix is shown to the user and
they decide.** So a Should-fix needs to be legible to someone who is not reading
the code — the failure it causes, not just the line it sits on.

## Phase 2 — the tests

Past the wave's one gate (§4b of the body) — the code phase's Blocking rounds
closed *and* the user ruled on its Should-fix list — dispatch the same groups
again: **resume each
group's phase-1 `builder` with `SendMessage`** (pointing it at a new checkout — the
old one was removed on integration) where it survives — it holds the
code it just wrote and the findings it just closed — and only spawn a fresh one
where it does not. Each writes the suites its repo's layers call for, runs the
unit suites and the repo's standard checks locally, and drives them green.
Integration and e2e are written but run in CI only (`AGENTS.md`,
«Integration-тесты только в CI»): the report and the ledger say «integration не
запускались локально», never green.

- **Tests trace to the delta spec, not to the code.** The builder is writing
  against reviewed code, which makes reading behaviour off it legitimate; reading
  the *expected values* off a run does not become legitimate with it. The test
  review is aimed at exactly that difference.
- **If two groups' locally-run suites share one piece of infrastructure** (a
  single docker-compose stack with fixed container names or ports, say), they
  collide even from different repos' worktrees when run at once. Integration
  suites never do — they run in CI — but a unit suite or a standard check can.
  Phase 2 is where every group of the wave wants to run its suites at once — dispatch those
  groups one after the other and record why. This is also why a wave plan keeps
  such groups apart in the first place (§2 of the body); when it did not, this is
  where the bill arrives. No shared resource → nothing to serialise.
- **A red suite may mean the code is wrong**, and that code has already been
  reviewed. The builder fixes the implementation and reports it; you record it as
  `код правил`, because that is the measurement (§6 of the body).

## The test review

One `reviewer` again, over the wave's paths, with the test-pass prompt. Its
question is narrow: **do these suites assert the spec, or do they merely agree
with the code?** An expectation copied off a run, an assertion aimed at a mock, a
delta-spec requirement with no test that would go red if it broke.

**It also reviews whatever code phase 2 moved** — that code was passed by the code
review and then changed, so it is unreviewed again. The builders' reports name
those files and `git diff` confirms them; give the reviewer the list.

**Its Should-fix findings are not dispatched and not shown yet.** The wave already
spent its one gate before the tests, so these go to the close ([close.md](close.md))
— recorded in the ledger, marked as being about the suites or about the
implementation. Only a surviving **Blocking** interrupts here, and it interrupts
immediately: the wave stops and the user rules.
