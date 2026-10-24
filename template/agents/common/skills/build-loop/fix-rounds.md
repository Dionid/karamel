# Fix rounds, and the gate where the user rules

Reference for §4 and §4b of [SKILL.md](SKILL.md), which carry the three rules you
must not lose: only Blocking is dispatched, Should-fix waits for the user, and a
finding contradicting the approved spec goes to the user immediately. This is how
a round runs and what the gate looks like.

## What a round is

Rounds `R = 1, 2, 3`, **counted per phase per wave**, not per group: one round is
one pass over every affected group, dispatched in a single message, and closed by
one re-review scoped to *just those findings* — never the whole wave again. The
three rounds of phase 1 and the three of phase 2 are separate budgets.

**Only Blocking travels in these rounds.** Each builder gets **all** of its
group's Blocking findings in one message, not one per round: closing the easy half
now and the rest next time spends a round on nothing. Should-fix is not in the
message at all — a builder that fixes one anyway was told about it by you, so do
not put it there "for context".

| Round | Who fixes |
|---|---|
| 1 | **Resume** each affected group's `builder` with `SendMessage` — it still has the code in context |
| 2 | **Fresh `builder`** per still-affected group (new `Agent` call), minimum `strong/high` from the tracked catalog, told which findings survived round 1 and what was already tried |
| 3 | **Fresh `builder`** again, minimum `strong/high`, told what *both* previous rounds changed and why each failed — and told plainly that this is the last one, so a structural obstacle named clearly is worth more than a workaround |

Every round is another write-capable dispatch, so each affected group gets a
**new** `writer.py spawn` (fresh checkout from the canonical tree, which already
holds what earlier rounds integrated) and its patch is `submit`ted and
`integrate`d before the re-review. A resumed round-1 builder is told its new
checkout path; never point it at the canonical `worktrees/<task>/<repo>` to write.

The builders handle the list with the workspace's receiving-code-review skill if
it has one, and the same discipline regardless: each finding verified against the
code before anything changes, and one that is technically wrong comes back with
the code that proves it rather than implemented anyway.

## Round 3 ends the automatic budget

**There is no round 4**, and round 3 does not end in a verdict of yours either.
Where a surviving Blocking goes depends on the phase:

- **phase 1** → the gate below, together with the Should-fix list;
- **phase 2** → **straight to the user, out of band**, the moment the re-review
  says it is still open. There is no gate in that phase to hold it, and the wave
  is stopped until they rule — as is every wave behind it. A suite still red after
  three rounds is this case, not "flaky".

Either way, three failed rounds on a finding the builder understood is an
architecture or spec problem, not a coding problem.

What you bring for each surviving Blocking: the finding as written, what each of
the three rounds changed, and why it did not close. A builder's "structural
obstacle" answer from round 3 is the most useful thing on the page — quote it
rather than summarising it.

## The gate — the list and the ask

**Once per wave, at the end of phase 1** — the code's Blocking rounds are closed
and the tests have not been written yet, which is the only point where changing
the implementation is still cheap. Assemble it from the code review plus its
re-reviews, and show everything: filtering the list is the one thing the gate
exists to stop you doing.

```markdown
Волна 2, фаза кода — решение по находкам.

Открытые Blocking (три раунда не закрыли):
1. [Blocking] G2 <repo> src/fee/fee.service.ts:88 — при amount < dust
   комиссия уходит в минус, выплата падает с 500. Раунд 1 добавил clamp — ушла
   в 0 и сломала утверждение спеки о min-fee; раунд 2 перенёс clamp в
   калькулятор — тот же результат; раунд 3: «без изменения требования
   min-fee не закрывается». → моя рекомендация: решать по спеке, это не код.

Should-fix (не отдавались билдерам, решение за вами):
2. [Should-fix] G2 <repo> src/fee/fee.repo.ts:41 — N+1 на списке выплат,
   ~40 запросов на страницу. → рекомендую править: дешево, один join.
3. [Should-fix] G3 <repo2> src/api/client.ts:120 — ошибка сети
   глотается и превращается в «отклонено». → рекомендую править.
4. [Should-fix] G3 … → рекомендую отложить: касается кода, который волна 3
   всё равно переписывает.

Хвост (докладываю, не спрашиваю): 3 nit'а, 1 вопрос про рантайм —
findings-w2-code.md.

Что правим?
```

Four or fewer decisions → `AskUserQuestion`, one question, `multiSelect: true`,
one option per finding. More than four → the numbered list above and "назовите
номера". Either way **every item carries your recommendation and its reason** —
the user is ruling on a technical call, and a list without recommendations makes
them do the reading you already did.

## After the ruling

- **Picked** → one dispatch to the affected groups, exactly like round 1 (resume
  the builders), closed by one scoped re-review. **A separate budget**: it does
  not consume R1–R3, and it does not get a second automatic attempt. Still failing
  → report it to the user and stop there; they already ruled once, and guessing
  again is what the three rounds were for.
- **Declined / deferred** → one ledger line each with the user's ruling and the
  reason. Reported again at the close (§6 of the body), and **never re-raised by a
  later review of the same code** — when the final full pass files it again, answer
  "ruled on at wave N, declined" and move on.
- **A Blocking the user rules is a spec or design problem** → that is `spec-loop`
  again, not a coding round. Stop the wave, say what is stalled behind it, and let
  them change the approved change.

Nothing else waits for the gate: the tail is reported, and phase 2 opens as soon
as every item above has an outcome.

## Phase 2 has no gate

Its Should-fix findings — from the test review and from the re-reviews of the
rounds — are **collected and carried to the close**, where every wave's are ruled
on in one list together with the final full pass's own findings ([close.md](close.md)).
They are not dispatched in the meantime, and not shown wave by wave either: the
whole point of putting the wave's gate before the tests is that the wave then runs
to its barrier without stopping again.

Two things do not wait for the close, and they are the ones above: a **Blocking**
that survived three rounds, and a finding that **contradicts the approved spec**.
Both go to the user immediately.

A phase-2 Should-fix that is really about the *implementation* rather than the
suites is worth flagging in the ledger as such when you record it — at the close
it reads as one more test finding otherwise, and the user is ruling on whether to
touch reviewed code.
