---
name: receiving-code-review
description: Обрабатывать находки reviewer, worktree-review, GitHub PR или пользователя. Использовать, когда feedback ревью нужно проверить, оспорить, если он ошибочен, и исправить в порядке severity.
---

# Receiving code review

**Core principle: verify before implementing, ask before assuming, technical
correctness over agreeableness.**

A finding is a hypothesis about the code, not an instruction. Reviewers — human
or agent — work from a diff and can be wrong about context they could not see.
Implementing a wrong finding makes the code worse *and* burns a round of the
build loop.

## The response pattern

1. **Read the whole list** before touching anything.
2. **Restate** each finding as a technical claim: "input X produces wrong result
   Y at `file:line`".
3. **Verify** it against the code — read the function, the call sites, the test.
4. **Evaluate**: is it correct *for this codebase*, given its conventions,
   compatibility constraints and the approved spec?
5. **Respond** — the fix, or reasoned pushback.
6. **Implement** one finding at a time, running the relevant checker or test
   after each so you know which change did what.

## If anything is unclear, ask before implementing *any* of it

Findings are often related: item 4 may be the reason item 2 was written that
way. Implementing the three you understood and asking about the other two
afterwards produces work that has to be undone. Ask about all the unclear ones
in one message, then implement the whole set.

## Order of work

1. Anything unclear → clarified first.
2. **Blocking** — correctness, money/auth flows, data loss, security, secrets.
3. Cheap, certain fixes — imports, types, naming that was actually wrong.
4. **Should-fix** — real defects needing thought or refactoring.
5. **Nits** — only if they are genuinely quick; otherwise note them and move on.

Re-run the affected suites after each group, not once at the end.

## When to push back

Push back — do not silently comply — when the finding:

- is factually wrong about what the code does;
- breaks existing behaviour or a compatibility guarantee;
- contradicts the approved spec in
  `worktrees/<task>/spec-repo/openspec/changes/<change>/`;
- asks for a feature nobody needs (YAGNI: validation for a case that cannot
  occur, configurability with one caller, an abstraction over one implementation);
- was already considered and rejected in the design, for a reason still valid.

**How:** state the technical reason, point at the code or test that proves it,
and offer the alternative if there is one. One or two sentences.

> `api/src/x.ts:44` — the nil check is unreachable: `parseAmount`
> throws on nil (`x.ts:12`) and is the only caller. Leaving as is.

**Finding vs. spec.** When a finding conflicts with what the spec explicitly
mandates, do not resolve it yourself in either direction. Put both in front of
the user — the finding, and the spec text that requires the thing it objects to
— and ask which governs.

## When the finding is right

Fix it and say what changed, in one line: `Fixed — parseAmount now rejects
negative values, test added at x.spec.ts:80`.

Skip the performance: no "You're absolutely right", no "Great catch", no "Let me
implement that now" before you have verified it. The fix is the acknowledgement.
And if you pushed back and turn out to be wrong, just say so briefly and fix it
— no post-mortem.

## Red flags

- agreeing with a finding you have not read the code for
- fixing a nit before a blocking issue
- "fixing" a finding by weakening a test, widening a type, or adding a `catch`
  that swallows it
- rewriting beyond the finding's scope because you were in the file anyway
- treating an agent reviewer's list as more authoritative than the code

| Excuse | Reality |
|---|---|
| "The reviewer probably knows something I don't" | Read the code and find out. It takes a minute. |
| "It's easier to just make the change" | Easier now, wrong forever, and it hides the real state. |
| "I'll fix them all in one commit and test at the end" | Then a new failure has five possible causes. |
| "Arguing wastes a round" | An unnecessary change wastes a round *and* ships worse code. |

## Where findings come from here

- **`reviewer` agent / `worktree-review` skill** — ranked Blocking / Should-fix /
  Nit over `worktrees/<task>/`. Feeds step 6 of Track C in `AGENTS.md`.
- **The user** — always triages the reviewer's list; their selection is what
  goes back through the loop.
- **GitHub PR comments** — copy them from GitHub UI into the task. Same pattern applies;
  reviewers there have even less of your context.
