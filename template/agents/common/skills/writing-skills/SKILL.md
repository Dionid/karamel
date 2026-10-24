---
name: writing-skills
description: Писать, тестировать и дорабатывать скиллы и agent-определения воркспейса. Использовать при добавлении/правке скиллов или agents, при починке несработавших триггеров скилла, или при сокращении context-бюджета скилла.
---

# Writing skills

A skill is a reusable instruction file that changes how an agent behaves in a
recurring situation. In this workspace they live at
`.claude/skills/<name>/SKILL.md`, with heavier material in sibling files loaded
only on demand; agent definitions live at `.claude/agents/<name>.md`.

**Core principle: if you did not watch an agent fail without the skill, you do
not know whether the skill teaches the right thing.** Write against an observed
failure, not against an imagined one.

## When a skill is warranted

- The same correction has been given more than twice.
- A workflow has real preconditions or ordering that is easy to get wrong
  (`commit-and-mr`, `db-query`, the build loop).
- A discipline gets abandoned exactly when it matters most — under pressure, on
  a "simple" change (`verification-before-completion`, `systematic-debugging`).

**Not** warranted for: a one-off instruction, something already in `AGENTS.md`,
or general programming knowledge the model already has.

## The description field is the whole trigger

Nothing else is loaded until the description matches. Two rules, both easy to
get wrong:

**Say when to use it, in the words that will appear in the situation.** Name the
concrete triggers — file paths, command names, phrases the user actually types,
symptoms as they present.

**Do not summarise the workflow in it.** A description that describes the steps
gets followed *instead of* the body — the agent thinks it already knows what the
skill says, and never reads the file.

```yaml
# ✗ summarises the procedure — the body never gets read
description: Creates a worktree, implements the change, runs the tests, commits.

# ✗ too abstract to ever match
description: Helps with code quality.

# ✓ triggers only, in the vocabulary of the moment
description: Review local changes across every repo in a worktrees/<task>/
  checkout — branch commits plus uncommitted work — and report defect-first
  findings. Use when the user asks to code-review a worktree, review a task's
  changes, or review all repos under worktrees/<task>/.
```

Third person, no "I". Cover the synonyms — a skill for pull requests should
name PR *and* push; a debugging skill should name bug, failing test,
red pipeline and flaky.

## Token budget

Every loaded skill costs context on every turn it is loaded. Keep `SKILL.md`
under ~200 lines; push detail into sibling files the body links to, so they load
only when needed (`systematic-debugging/root-cause-tracing.md`,
`build-loop/prompts.md`).

`AGENTS.md` costs more: it is loaded before the task can choose a skill. Keep a
shared root file under ~200 lines; when shared and team policy intentionally live
in one `AGENTS.md`, keep that file under ~400. It contains routing, permissions
and cross-cutting invariants; procedures, command references, rationale and
history belong in `SKILL.md`, reference docs and decision records.

- Reference `--help` and `package.json` scripts instead of transcribing flags.
- Link to the other skill instead of restating its procedure.
- Cut the second example when the first one already teaches the pattern.
- A long deterministic procedure belongs in a `run.sh` beside the skill (see
  `commit-and-mr`, `bump-shared-lib`) — the model should invoke it, not re-derive it.

Two budgets are hard limits of the CLIs, not attention guidance, and `lint.py`
fails on them:

- **The skill listing.** Claude Code shows the model every skill's name and
  description under one character budget — `SLASH_COMMAND_TOOL_CHAR_BUDGET` in
  `agents/claude/settings.base.json`, about 1% of the context window when
  unset. Past it, descriptions are dropped starting with the least-used skills:
  the name stays, the trigger is gone, and the skill looks lost. Lint counts
  this repository's share only — skills and slash commands; plugin and
  user-level skills of the runtime spend from the same budget unseen. A new
  skill spends from it too; when lint reports it full, raise the value
  deliberately or shorten descriptions.
- **The size of `AGENTS.md`.** Codex reads the `AGENTS.md` chain only up to
  `project_doc_max_bytes` in `agents/codex/config.base.toml` (32 KiB by its
  default) and silently drops the tail — the team rules at the end of the
  file. Codex also reads no `@IDENTITY.md`/`@SOUL.md` imports, so what those
  files say reaches only Claude Code.

## Body shape

Open with the core principle in one line, then: when to use, the procedure,
boundaries, and how to report. Be specific to *this* workspace — real paths
(`worktrees/<task>/<repo>/`), real commands, the real repo names. A generic
skill is one the agent has to translate before it can act on it.

For a **discipline** skill — one that is abandoned under pressure — three
devices do the work, and they are worth their tokens:

- **An iron law**, one sentence, stated as an absolute.
- **A rationalisation table** (`| Excuse | Reality |`) closing the specific
  loopholes you have watched an agent talk itself through.
- **A red-flags list** of the thoughts that precede the violation, so the agent
  can catch itself mid-thought rather than after the fact.

Every loophole you leave open will be used. "Unless it's urgent", "unless it's
trivial", "use judgement" — each of those is where the skill fails. If an
exception is real, name it exactly; otherwise close it explicitly, including the
letter-versus-spirit move ("different wording, so the rule doesn't apply").

## Test it with a subagent

The only real test. Do not skip it because the skill "reads well".

1. **Red** — give a fresh subagent a task that provokes the failure, *without*
   the skill. Watch how it fails, and keep the transcript.
2. **Green** — same task, same prompt, with the skill available. Did the
   behaviour change?
3. **Refactor** — where it still slipped, find the sentence it reasoned around,
   and close that specific loophole. Re-test.

Cheap variants when a full run is overkill: paste the description alone and ask
whether it applies to a described situation (tests triggering); paste the body
and ask what it forbids (tests clarity); ask the agent to argue its way out of
the rule (tests the loopholes).

## Agent definitions

`.claude/agents/<name>.md` follows the same rules with two additions: its
`description` decides when the orchestrator dispatches it, so it must name the
agent's place in the loop; and it must state its **boundaries** explicitly —
what it may edit, what it must not commit, what it must not do to make a
checker green. Restrict `tools:` where the role demands it, as `reviewer` does
by having no `Edit` or `Write`.

## After adding a skill

Register it where it will actually be found: link it from `AGENTS.md` at the
point in the workflow where it applies. A skill nobody references is one that
fires by luck.

## Red flags

- writing a skill for a failure you have not observed
- a description that recites the steps
- a `SKILL.md` past ~200 lines with no sibling files
- generic examples with `foo` and `bar` instead of this workspace's paths
- "use your judgement" left in a discipline skill
- shipping without a subagent test because the skill "obviously helps"
