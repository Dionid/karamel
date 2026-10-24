---
name: lint
description: Линтовать харнесс этого воркспейса: AGENTS.md, WORKTREES.md, skills, agents, hooks и скрипты под .claude/. Использовать перед коммитами в харнесс, после правок skill/agent, или когда CI харнесса красный.
---

# Lint the harness

**The harness is instructions, and a wrong instruction fails silently.** A path in
`AGENTS.md` that no longer exists, a skill whose frontmatter name stopped matching
its directory, a fenced command an agent will paste that does not parse — none of
these break a build anywhere, they just make an agent do the wrong thing quietly.
That is what this checks.

```bash
.claude/skills/lint/lint.sh          # everything; or: make lint
```

Run it **before `git commit` in the workspace repo**, and read the output rather
than the exit code alone — it separates errors (fail) from warnings (report).

## Scope

**This repo only.** The product repos under `packages/` have their own lint,
typecheck and build, run by whoever is working in their worktree; this script
never looks at them. What it does look at: `*.md` tracked by git, the shell
scripts under `.claude/`, `repos.json`, and the frontmatter of every skill and
agent.

## The checks

| Check | What it catches |
| --- | --- |
| `syntax` | `bash -n` on every tracked shell script |
| `shellcheck` | static analysis, `-x` so sourced libs are followed, `-S warning` (see below) |
| `execbit` | a shebanged script that is not `+x`; a sourced `lib.sh` that is |
| `manifest` | `repos.json` vs `packages/` in both directions (warning, not error) |
| `markdown` | markdownlint over the tracked `.md`, config in `.markdownlint.jsonc` |
| `harness` | `lint.py`: skill contract, links, anchors, doc paths, fences, forbidden command forms, cross-doc coverage |
| `hooks` | coordination lifecycle/concurrency plus identical secret-leak decisions on both agents' payload shapes |
| `scanner` | a line a context-scanning agent runtime would reject — it drops the **whole file** from the prompt, so one bad line in `AGENTS.md` costs the entire ruleset |

**`hooks` is the one check that runs something instead of reading it**, and it is
here because hooks fail silently by construction: a broken heartbeat leaves no
lease, while a broken guard leaks into a transcript. It exercises concurrent
coordination writers and both payload families; the secret rules still run in
all three command shapes.

```bash
.claude/skills/lint/lint.sh --only shellcheck --only harness
.claude/skills/lint/lint.sh --list
.claude/skills/lint/lint.sh --strict           # warnings fail too; optional local hard gate
.claude/skills/lint/lint.sh --install-hook     # .git/hooks/pre-commit
make lint-tools                                # one networked install, then local reuse
```

`make lint` never downloads tools implicitly. `make lint-tools` installs the
pinned `markdownlint-cli2` once into the main checkout's ignored `.agent-tools/`
cache; harness worktrees resolve the same git common directory and reuse it.
This makes a normal lint run deterministic and makes its one networked setup
explicit. A missing cache remains `SKIPPED`, or fails with `--require-tools`.

## Why shellcheck runs at `-S warning`

The gate is `warning`, not `info`, and that is a measured choice rather than a
default: at `warning` these scripts are clean, at `info` there are 23 findings —
almost all `SC2086` (an unquoted expansion that is provably safe here). Lowering
the threshold would mean a linter that is red from the day it lands, which is how
linters get ignored.

`warning` is not a toothless setting. `SC2318` is warning-level, and it is what
found the latent bug `clone.sh` had been carrying: in
`local name="$1" … dir="$PKGS/$name"` the `$name` inside `dir` is the *global*
`name`, because `local` is a builtin and expands all its arguments before
assigning any of them. It produced the right path only because the driver loop
reads into a global `name` holding the same value — rename that loop variable and
`dir` becomes `$PKGS/`, at which point `[ -e "$dir" ]` matches `packages/` itself
and every repo reports "already present".

Raising it to `info` later is a deliberate piece of work: fix the 23, then change
the flag. Do not lower it and add suppressions.

## Errors versus warnings

**An error is a statement that is false**: a link to a file that is not there, an
anchor with no heading, a skill whose `name` will not resolve, a fence that cannot
run. These fail the run and the pre-commit hook.

**A warning is a budget or a drift**: a `SKILL.md` past the ~200-line guidance in
[`writing-skills`](../writing-skills/SKILL.md), the unified `AGENTS.md` past its
~400-line policy budget, a repo in `packages/` that
`repos.json` has not been told about, a skill `AGENTS.md` never names. These are
reported and let the commit through — the docs write them as approximations, and a
tilde must not become a red pipeline. `--strict` promotes them; **CI does not use
it**, on purpose, because three skills exceed that ~200 today and were fine.

**A missing external tool is a SKIPPED line, never a pass.** No `shellcheck` on
the machine means the shellcheck check did not run, and the report says so.
`--require-tools` turns that into a failure.

## Two escape hatches, and their cost

- **A fence that must show a forbidden command** — the counter-examples in
  `AGENTS.md`'s docker-compose section — marks the line `# WRONG` (or
  `# lint:allow`). The marker has to be on the line itself.
- **A path in prose that genuinely is not on disk** — it lives in the spec repo,
  or the text is explaining the old layout — goes in `PATH_ALLOWLIST` in
  `lint.py`, with the reason next to it.

Both are deliberately edits to a reviewed file rather than a flag, so nobody
silences a check in passing.

**Links into `packages/`, `worktrees/` and `.claude/` are checked only when
those trees are there.** They are gitignored and created on
demand, so whether such a link resolves depends on the machine — enforced on a
developer's checkout, where a wrong path is worth catching, skipped in CI, where
`PACKAGES.md`'s ten correct links would otherwise all fail.

**A `.claude/…` path named in prose is resolved through the layers**, because
`.claude/` itself is a build: the path counts as real if the built tree, or
`agents/`, carries it. If neither source nor built tree exists, every path named
in the docs is unknowable — reported once as an
aggregated `warn` rather than an error per line. Once `agents/` exists (the
state of every developer checkout after the first `./ops sync`), an unresolved
path fails outright.

## When a check is wrong

Fix the check, not the file, and do it in the same commit. Two rules earned the
hard way while writing this, both preserved in `lint.py`'s comments:

- **Never grep prose for a forbidden command.** These docs say "never
  `--no-verify`" four times and "there is no `./wt`" three times. A whole-file
  grep is ten hits and all ten are false.
- **Normalise `<placeholders>` before parsing a fence.** `bash` reads `<task>` as
  a redirect; without the substitution 23 of 74 fences in this repo "fail".

Adding a check → [`writing-skills`](../writing-skills/SKILL.md) applies to this
skill like any other, and the new check needs a case that fails before it lands.

## CI

`.github/workflows/lint.yml` runs the same gate in `node:22-bookworm-slim`.
It installs bash, git, jq, Python, shellcheck, tzdata, curl and the same pinned
markdownlint-cli2 version as `lint.sh`, then runs
`bash agents/common/skills/lint/lint.sh --require-tools`.

`--require-tools` makes a missing checker fail instead of printing SKIPPED.
The workflow runs for branch pushes and pull requests with read-only repository
permissions. Checkout does not persist the workflow credential in git config.
The `manifest` check remains local-only because `packages/` is absent in CI.

Re-run a changed job in its image before pushing:

```bash
docker run --rm -v "$PWD:/w" -w /w node:22-bookworm-slim sh -c \
  'apt-get update &&
   apt-get install -y --no-install-recommends bash git jq python3 shellcheck tzdata curl ca-certificates &&
   npm i -g markdownlint-cli2@0.23.2 &&
   git config --global --add safe.directory /w &&
   bash agents/common/skills/lint/lint.sh --require-tools'
```

A red pipeline is diagnosed from its trace like any other failure — the
GitHub Actions UI, or a child reading it with `gh run view --log-failed` /
`gh run view` through the shared token-authenticated transport.
