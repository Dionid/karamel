# Close — the final review, the commits, the trace

Reference for §7 of [SKILL.md](SKILL.md), which carries the ordering. This is the
detail behind each step.

## 1. The full-worktree review

**After the last wave, one `reviewer` over the whole worktree** — the full-pass
prompt, no path scope. Every review until now saw one wave's paths, so this is the
first read of the change as a whole: a contract wave 1 defined and wave 3 consumed
differently, a spec requirement that fell between waves, the same logic
implemented twice. Code and tests both exist by now, so it is a single pass over
both, not another two. Its findings go through §4 and §4b like any others — its
Blocking dispatched, its Should-fix taken to a last ruling gate — and skipping the
pass is how parallelism buys speed by losing correctness.

**Give this reviewer the ledger.** It is the only pass that reads code the user
has already ruled on, and a declined finding re-filed here is noise; the ledger
lines are what tell it which ones those are.

**A single-wave change skips it** — its two wave reviews already covered the whole
worktree, and repeating it pays a third time for the same paths.

## 2. The closing ruling — the phase-2 Should-fix of every wave

**Before the commits, and it is not optional: this is what the phase-2 gate was
traded away for.** Each wave stopped once, before its tests, so nobody has ruled
on anything the test reviews found — those findings have been accumulating in the
ledger since wave 1.

One list, assembled the same way as a gate list ([fix-rounds.md](fix-rounds.md)):

- **every phase-2 Should-fix of every wave**, marked with the wave it came from and
  with whether it is about the *suites* or about the *implementation* — the second
  kind means touching code that a review already passed, and the user is entitled
  to know that is what they are agreeing to;
- **the full pass's own findings** — its Blocking has already been through §4 of
  the body; what is left is its Should-fix and what it says about the seams between
  waves;
- **what they declined earlier**, with the ruling they gave. They decided those one
  wave at a time, and the close is the only place they see them as a set — which is
  where "three deferrals in the same module" becomes visible and a fourth stops
  being reasonable. These are not re-argued: a ruling repeated back as an objection
  is you overturning it a second time.

What they pick is dispatched as one round, closed by one scoped re-review, exactly
like a gate's. Then the commits.

## 3. Commits, in order

`commit-and-mr` for every repo the task touched, spec repo included — **code repos
first, `<spec-repo>` last**, with the trace written in between:

```bash
.claude/skills/spec-trace/trace.sh --task <task>   # if this workspace has that skill
```

Where it exists, that writes `<spec-root>/openspec/changes/<change>/implementation.md` —
every repo's branch, PR and commits — and it goes into the spec repo's commit. The
ordering is the whole trick: the trace can only name PRs that already exist. Where
no such skill exists, write the equivalent by hand — the change is what someone
reads in a year; without it the change names no code.

A worktree can hold more than one spec store, and then the subject of the change
names which one — `SPEC_SUBJECT_REPO=<repo> .claude/skills/spec-trace/trace.sh
--task <task>`. Unnamed, or named but not checked out, the script exits **2** and
writes nothing: that is a question for the user, not a missing spec. Filing the
trace into the other store would put it where nobody looks for it.

Re-run the trace after any later round of commits (an accepted finding, a PR fix,
a rebase) and again before `openspec archive`, so the archived copy names the
merged PRs.

Then, if this workspace has a spec-link skill, one pass of it after the spec
repo's PR exists — it cross-links the code PRs and the spec PR. A task that
touched no spec reports `SPEC_STATE=untouched`, out loud.

## 4. Handing the links back

**In the order of the change's `## Порядок релиза` table**: what each PR waits
for, and which steps are irreversible (a published package version, an applied
migration, a store release). The person merging only knows the order if you
repeat it.

A multi-repo change with no such table predates that rule — say so, and derive the
order from the dependency direction: contracts and libraries (published and
bumped in their consumers) → DB migrations → back ends → clients that depend on
them → any app-store release last, because that kind of release is never instant.

## 5. The measurement

Report it per wave: **how many phase-2 findings turned out to be code fixes**, i.e.
how often running the tests caught what the code review had passed. Near zero says
static review is carrying the correctness load and the code-first order is doing
its job. Consistently non-zero says it is not — the defects live where a reviewer
cannot see them, and testing after the review only finds them later. That number is
the argument for keeping or dropping the split, so do not lose it.

## 6. What "done" means

**No `COMMIT_SHA=` and no `MR_URL=` in `commit-and-mr`'s output means the task is
not done**: a pre-commit hook failed. Read its output, fix the cause, commit
again. Never `--no-verify`.

The ledger is scratch — `worktrees/` is gitignored here, and `wt rm` takes it with
the worktree. Leave it in place until the PRs are open.
