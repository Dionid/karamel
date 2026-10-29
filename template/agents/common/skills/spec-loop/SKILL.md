---
name: spec-loop
description: Провести шаги 1-4 спек-цикла для изменения, которому нужна согласованная спека до кода — параллельная разведка analyst+architect, только блокирующие вопросы пользователю, затем proposal → delta specs → design → tasks, написанные одним заходом с cross-read между ролями и передачей в build-loop в том же ходе; остановка на одобрение спеки — только по явной просьбе пользователя. Использовать, когда изменению нужна спека до кода.
---

# The spec loop

Steps 1 through 4 of a spec-first change: everything before a line of code
exists. [`build-loop`](../build-loop/SKILL.md) takes over at step 5, and it
starts only from a completed spec bundle (validated, cross-read and coverage
closed) recorded in the ledger. By default nobody approves the spec: only the
blocking questions of step 2 stop the loop, and the complete bundle goes to
`build-loop` in the same turn. A review stop before code is an explicit opt-in
(§6); a spec without implementation is
[Track A](#track-a--a-spec-without-implementation) — approval mandatory, no `build-loop`.

Resolve the destination through the **`spec`** skill before dispatching either
role. **`<spec-repo>`** is the `repos.json` entry whose `openspec/` holds the
subject of this change; **`<spec-root>`** is its optional `specRoot` (unset or
empty: `openspec/` sits at the repo root). Either way `changes/` and `specs/`
live at `worktrees/<task>/<spec-repo>/<spec-root>/openspec/` — the `openspec`
segment is always there. If this workspace has `spec-trace`, its
`spec-checkout-lib.sh` (`find_spec_checkout`, `spec_prefix_for`) already resolves
this — read it rather than re-derive. No store in the worktree means nowhere to
write: stop and report. **The store follows the subject**: several stores is not
a broken manifest, but a subject spanning them means stop, show the candidates,
ask the user. Never write into both.

If the workspace has the **`work-items`** skill, the change must record its task per that skill (`task: <task>` in `.openspec.yaml`, a `Задача:` link under the proposal H1).

You are the **orchestrator**, and here that means something specific: **you are
the only participant with a voice.** The two agents cannot talk to the user, so
every question they raise is asked by you, and every answer reaches them only
because you wrote it into their next prompt.

During this loop only analyst/architect study and artifacts are allowed. **Do
not start builder work or wave assignments before the bundle is complete and
recorded in the ledger.**

Two agent types, in [`../../roles/`](../../roles/), prompts in
[prompts.md](prompts.md):

- **`analyst`** — what the system must do. Studies the code and the real data,
  raises the business questions, writes `proposal.md` and the delta specs, and
  reads the architect's design for coverage.
- **`architect`** — how it gets built and shipped. Studies the repos, contracts and
  schema, raises the design questions, reads the requirements for feasibility, and
  writes `design.md` and `tasks.md` with the `## Параллелизм` and
  `## Порядок релиза` tables the build loop runs on.

Neither writes code. Neither writes the other's files. **Each reads the other's
work before the bundle closes** — that cross-read is why there are two of them.

## 0. Before dispatching anything

The worktree, the change directory, and the ledger:

```bash
.claude/skills/wt/wt new <task> --repo <repo> [--repo <other>]... --pull
cd worktrees/<task>/<spec-repo>/<spec-root> && openspec new change <change-name>
cat worktrees/<task>/.build-loop/progress.md 2>/dev/null
```

If `<spec-repo>` is in `repos.json`'s `always` list, `wt new` already put it in
the worktree; otherwise `--repo <spec-repo>`. Read the existing specs — through the spec-reading skill this
workspace uses for OpenSpec (`.claude/skills/openspec-read/` if present;
otherwise `openspec show`/`openspec list` directly) — yourself before you brief
anyone: whether this is a new capability or an amendment to one decides what the
analyst is even asked to write.

**The ledger is shared with the build loop** — same file,
`worktrees/<task>/.build-loop/progress.md`, a `## Спека` section above the waves.
`openspec status --change <change>` says which artefacts exist; only the ledger
says whether the bundle is complete and the build loop opened, and that is the
thing you must not lose to a compaction. Format: [ledger.md](../build-loop/ledger.md).

## 1. The study — both agents, one message

Dispatch `analyst` and `architect` **concurrently, in the same message**. They read
the same tree and answer different questions, so neither is told what the other
found — a shared summary is how two independent studies become one.

Read-only, both of them: no artefact is written in this step. What comes back is
the picture (`path:line`, real row counts, the contracts involved) and two ranked
question lists.

**Live state is not optional here.** A study that never checked the real data
designed against assumed data. If this workspace has a read-only data-query
skill (for a product database, and separately for live infrastructure —
Kubernetes, logs, dashboards), use it; if it does not, say plainly that live
state was not checked rather than proceeding as if the schema and the deployed
state were known. Two answers must be in it before step 3: **what happens to the
rows that already exist**, in counts, and **what the running system does not
have yet** that this design would need. Both change data models; found after
the bundle is written they change them expensively.

## 2. The questions — only the blocking ones

Merge both lists, drop the duplicates and anything whose answer would not change
the spec. **Ask only what blocks writing** and no evidence settles — typically
the data model, what happens to existing rows or money in flight, a published
contract. Everything else is closed by the study or a sensible default and
written as a labelled assumption in the artefact (listed in the ledger), not asked.

Ask with `AskUserQuestion`, at most four per call. Give each option what it
costs — "additive column now, backfill later" against "one destructive
migration" is a decision the user can only make with the price attached.

**Do not start writing before the blocking answers are in**; with none, go
straight to step 3. In teams that use work-items, the Feature and its Tasks are
agreed in chat at this same stop. Without the opt-in of §6 it is the loop's only
user gate.

## 3–5. The artefacts, drafted together, handed off once

The writing order is a **drafting dependency between the two agents** — delta
specs write against `proposal.md`'s scope, design/tasks toward the delta specs —
not a series of user gates: nothing here waits for the user.

| # | Written by | What | Cross-read by | Then |
|---|---|---|---|---|
| 3 | `analyst` | `proposal.md` — why, what changes, the capability, and **what is out of scope** | — | next artefact |
| 4 | `analyst` | the delta specs — `### Requirement:` / `#### Scenario:`, `ADDED` / `MODIFIED` | `architect`, feasibility pass | next artefact |
| 5 | `architect` | `design.md` + `tasks.md`, with both tables | `analyst`, coverage pass | `ПАКЕТ ГОТОВ → build loop открыт` |

**The cross-read runs before the bundle is closed**, in between the drafting
steps above, not after the bundle is already assembled. The feasibility pass
answers "can this be built as written, and what does it cost"; the coverage
pass answers "does this design deliver every requirement, and does it
contradict any". Both hand back **findings, not edits** — neither agent touches
the other's file.

A finding that only the other agent can close goes back to its author first,
once — and the author is allowed to push back with a technical reason instead
of complying. A finding against `proposal.md` or the delta specs raised during
the feasibility pass can still mean redrafting them before design starts; a
finding against design/tasks from the coverage pass can mean redrafting those
before the bundle is closed — all inside this one pass.

**`openspec validate` after every write**, and read its output. An artefact
that does not validate is not ready to hand to `build-loop`.

Write artefacts in whatever language `<spec-repo>/<spec-root>/openspec/config.yaml`
declares for specs; if it declares none, match the language the user has been
using in this conversation.

## 6. The bundle is complete, and the handoff

Once both cross-reads are resolved, verify the two things `build-loop` cannot
recover from:

```bash
cd worktrees/<task>/<spec-repo>/<spec-root> && openspec status --change <change> && openspec validate
git -C worktrees/<task>/<repo> ls-files '<glob>'   # per group, per wave — do the paths overlap?
```

Only when `openspec validate` is clean and the paths are checked is the bundle
— `proposal.md`, the delta specs, `design.md`, `tasks.md` — complete. **Do not
ask the user to approve it**: you accept it yourself. Write to the ledger's
`## Спека` section the literal line `ПАКЕТ ГОТОВ → build loop открыт`, with the
findings from both cross-reads and how each was closed, tell the user in one
line that the build starts, and **start `build-loop` in the same turn**.

**The review stop is opt-in.** Only when the user explicitly asked to see or
approve the spec before code does the loop stop here: the ledger gets
`Ревью спеки до кода: да — по просьбе пользователя «<quote>»`, the bundle goes
to the user, and only after their «ок» come `ПРИНЯТ пользователем — <quote, date>`
and then the `ПАКЕТ ГОТОВ` line. A request for spec/tasks artefacts together
with the implementation (`AGENTS.md` → Track C) is not that request; a spec
with no implementation is Track A below.

A significant bundle change after the handoff goes back through this loop with
no re-approval; the ledger line is rewritten when the bundle is complete again.

`build-loop` re-checks the parallelism table against the code anyway, and it may
move a group to a later wave without touching `tasks.md`. What it cannot do is
invent a `## Порядок релиза` table that a multi-repo change never got.

**No code in this loop, at all.** Not a scaffold, not a migration file, not "just
the types". The spec repo is the only thing written, and it ships in the task's
MRs with the code at the close — `commit-and-mr` picks it up at step 7, spec repo last.

## Track A — a spec without implementation

When the request is the spec alone (`AGENTS.md` → «Track A»), run steps 0–6
as written, with three differences. **Explicit user approval is mandatory**:
first the independent closing review of the bundle (`worktree-review`, then
`receiving-code-review`) — *before* the bundle is shown to the user — then the
bundle goes to the user, and only their explicit «ок» counts. Instead of
`ПАКЕТ ГОТОВ → build loop открыт` the ledger's `## Спека` section gets the
literal line `Ревью спеки до кода: да — Track A, без build-loop`, and after
the approval `ПРИНЯТ пользователем — <quote, date>`. **`build-loop` is never
started**: the close is a Draft MR of the spec repository through
`commit-and-mr`. Any edit after ПРИНЯТ — even a wording fix — goes back to the
user for a new approval. A request to implement the spec is Track C.

## Red flags

- **an agent's question answered by you instead of by the user** — the one failure
  this whole loop is arranged to prevent
- writing `proposal.md` before the blocking questions came back
- asking the user to approve `proposal.md`, the delta specs, or the bundle
  without their explicit opt-in — a spec/tasks request with implementation is none
- a non-blocking question put to the user instead of a labelled assumption, or a
  blocking one (the data model) quietly settled as an assumption
- `ПАКЕТ ГОТОВ` written and `build-loop` left for a later turn
- a study of a change touching stored state that never looked at the real data,
  and did not say so
- the `analyst` writing `tasks.md` or a table, the `architect` editing a
  requirement to fit its design, either of them writing code
- an artefact handed to build-loop without its cross-read, or a cross-read whose
  findings were "resolved" by you
- a multi-repo change handed to `build-loop` with no `## Порядок релиза` table, or
  a `## Параллелизм` table whose globs nobody resolved
- a handoff to `build-loop` with no `ПАКЕТ ГОТОВ → build loop открыт` line in the ledger, or with
  an unclosed cross-read finding
- `openspec archive` — the change has not been built yet
- on Track A: the bundle shown to the user before the closing review, a
  `build-loop` dispatch, or an edit after ПРИНЯТ without a new approval
