# Waves — verifying the plan before the first dispatch

Reference for §2 of [SKILL.md](SKILL.md), which carries the rule: the table is
checked against the code, in both directions, before anything is dispatched.

## What the table is

The **`## Параллелизм`** table at the top of the change's `tasks.md`: every group
with its repo, its paths, what it depends on, and its wave. **Waves run one after
another; the groups inside a wave run in parallel, one `builder` each.** No table —
a small change in one repo — means one wave with one group, and nothing here
applies.

It was written during `spec-loop`, by an architect reading code that did not yet
contain this change. **So it is a plan, not an input you trust**, and checking it
is cheap: two `ls-files` per group against a wave of wasted wall-clock or a
collision that costs the wave.

It remains a pending plan until the `ПАКЕТ ГОТОВ → build loop открыт` line in the ledger records
it. Do not start builder work while you are only validating or displaying the
table.

## Downward — a wave that is too full

Two conditions, both required of every wave:

- **no repo appears twice in the same wave.** Writers have their own checkouts, but
  two groups of one repo still contend over integration into the one canonical
  worktree and over shared build/test infrastructure (package manifest, lockfile,
  generated output, a fixed-port compose stack) — in phase 2 they race each
  other's test runs too;
- **the paths of a wave's groups do not overlap.** Resolve the globs rather than
  eyeballing them:

  ```bash
  git -C worktrees/<task>/<repo> ls-files '<glob>'
  ```

  Count as an overlap: a shared package manifest or lockfile, a migrations
  directory, a DI/module registry, an exported `index`, a shared test-config
  file, a shared localization/resource file. Two groups editing the same file is
  the failure this check exists for, and it does not announce itself — the
  second write simply wins.

Either one broken → **move the group to the next wave** and record the reason in
the ledger. Serialising is always allowed, the dispatch order within a wave is
yours, and **you do not edit `tasks.md`** to make a different parallelism fit.

## Upward — a wave that is too thin

**This is the direction that gets skipped**, and it costs more than the other one.
The architect is instructed to put uncertain independence into a later wave, so the
table errs serial by design: a group sitting alone in wave 3 for a dependency that
does not exist in the finished code costs a whole wave of wall-clock, and the loop
runs to the end without anyone noticing.

For every group in a wave after the first, ask **what it actually depends on**:

- the dependency is named in the table and you can find it in the code → leave it;
- the dependency is named and you **cannot** find it — the symbol, the migration,
  the published version it supposedly waits for → the group moves **up**, subject
  to the same two conditions above, with its globs resolved against the earlier
  wave's;
- the table names no dependency at all → treat it as unverified, and decide by the
  code.

Record the promotion and its evidence in the ledger. A promotion you cannot
justify from the code is not one — leave the group where it is and say so.

## The one exception, and it comes from phase 2

**Two groups whose locally-run suites would collide over shared infrastructure**
(one docker-compose stack with fixed container names or ports, say) **stay in
different waves**, disjoint paths or not — their suites will serialise anyway in
phase 2, so putting them in one wave buys nothing there and adds a collision risk
in phase 1. If a promotion would create that pair, do not make it. No such shared
resource in this workspace → this exception does not apply. Integration and e2e
suites never create it: they run in CI only, not in phase 2.

## `## Порядок релиза` is not a dispatch input

Waves say what may be *written* at once; release steps say what order the repos
reach production. A wave-1 group can well be release step 4. **Never reorder waves
to match it** — it is read at the close (§7 of the body), when the PR links are
handed back.

The one place the two touch: **a contract group that is built but not yet published
and bumped** blocks the consumers that need the new version, whatever wave they sit
in. That is a real dependency, and it belongs in the table.
