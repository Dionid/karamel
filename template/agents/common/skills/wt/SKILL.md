---
name: wt
description: Создавать, перечислять, подтягивать, диагностировать и удалять worktree воркспейса через .claude/skills/wt/wt. Использовать для веток/checkout'ов, работы с кодом в репозиториях packages, устаревших packages и битых ссылок .env/node_modules.
---

# wt — the worktree of a task

**One task, one `worktrees/<task>/` tree, created only by this script.** Every
repo the task touches goes under the same `<task>` name on branch
`feature/<task>`, so the whole surface of the task is one searchable tree.

**Always call it by path: `.claude/skills/wt/wt`.** There is no `./wt` at the
workspace root — a human may have a `wt` alias in their shell rc, but your Bash
calls do not. The path is the same from anywhere (`../../.claude/skills/wt/wt`
from inside `packages/<repo>`), because the script finds the workspace by walking
up to `repos.json` rather than from cwd.

**Never use the built-in `EnterWorktree` tool in this workspace.** It knows
nothing about `repos.json`, the `worktrees/<task>/<repo>/` layout, or the
`.env*`/deps linking, and leaves a checkout nothing else here understands.

## Answering a question — pull before you read

```bash
.claude/skills/wt/wt pull --repo <name>      # or bare names: wt pull api signer
```

**Every question about the code in `packages/` starts here.** A checkout
behind `origin/<base>` answers confidently and wrongly, and the answer
carries no sign of it — the file is there, the line number is plausible.

- Fast-forward only, and the refusals are the point: a dirty tree, local commits
  or a checkout on another branch is **reported and skipped**, and the command
  exits non-zero. Report that to the user with the answer ("`packages/<repo>` is N
  behind, I left it"). Never `stash`, `reset` or `checkout` in `packages/` to
  clear the way — that is someone's work in progress.
- Default scope is the repo the cwd is in; `--repo`/bare names for specific ones;
  `all` for every repo in `repos.json`, which a question almost never needs.
- **A question about a named branch is a worktree, not a pull** —
  `.claude/skills/wt/adopt.sh <feature/branch> --repo <name>`, because the branch
  already exists on origin. `wt pull` only ever touches `packages/`.
- Within one session, a tree pulled for the first question answers a follow-up
  about the same repo without pulling again.

## Opening a task

```bash
.claude/skills/wt/wt new <task> --repo <name> [--repo <other>]... --pull
```

- **`--pull` is what replaces "remember to `git pull` first".** `wt new`
  *refuses* to branch off a `packages/<repo>` that is behind `origin/<base>`:
  that checkout is both the branch point and the source of the `.env*`,
  `.husky/_`, and `node_modules` the worktree gets, so a stale one means stale
  deps and hook support files.
  `--pull` fast-forwards it; `--allow-stale` proceeds and says what you accepted.
  If the refusal names a repo whose checkout sits on a *different* branch than
  its base, `--pull` won't touch it — report that to the user instead of forcing
  it.
- **One `<task>` for every repo**, however many `--repo` flags it takes. Never
  invent per-repo task names — that splits one task across several trees.
- `spec-repo` joins every `wt new` by itself (`repos.json` → `always`).
  Don't pass it, don't be surprised by it.
- If a requested repo is in `repos.json` but absent from `packages/`, `wt new`
  lazily calls `.claude/skills/clone/ensure-repository` before freshness checks
  and worktree creation. The ensure step is locked per repo, clones into a temp
  directory on the same filesystem, verifies token-free origin, runs `git fsck`,
  and atomically renames the complete checkout into place. Partial checkouts are
  never used as a branch point.
- **Don't pass dependency flags unless asked.** `deps` and `postSetup` in
  `repos.json` already say what each repo needs.
- A failing repo doesn't abort the others: read the `created:` / `failed:` lines
  at the end, and fix the failures before starting work.
- **Then, once, before writing anything:**

  ```bash
  .claude/skills/commit-and-mr/preflight.sh --worktree worktrees/<task>/<repo> --repo <repo>
  ```

  Read-only. It answers whether this checkout can commit, push and reach its
  GitHub project *at all* — the questions `commit-and-mr` asks at the end, when
  the diff already exists and each answer costs another attempt. `PREFLIGHT=ok`
  is one call; a missing git identity found at close is the close.

## No `npm i` per worktree — and versions you can still change

**Husky support files are copied into the worktree.** Git carries tracked hook
entrypoints like `.husky/pre-commit`, but Husky's installed support directory
`.husky/_` is normally gitignored. `wt new` copies `.husky/_` from
`packages/<repo>` when it exists, so pre-commit hooks work immediately in the
task checkout.

**`node_modules` is copy-on-write cloned from `packages/<repo>`, by default.**
`wt new` runs `cp -Rc` (APFS clonefile), so a worktree gets its deps in seconds
for metadata-only disk — `api`'s 936 MB of packages cost ~39 MB and
~40 s — instead of minutes and a full copy for an install.

The clone is a **real, independent tree**, and that is the point:

```bash
cd worktrees/<task>/<repo>
npm install @org/shared@1.67.1   # ~4 s, "changed 1 package"
```

changes this worktree's `node_modules`, `package.json` and lockfile and nothing
else — not `packages/<repo>`, not another task's tree. That is what the old
`--link-modules` could never do, and why it is no longer the way to save time.

Three rules follow from it:

- **`npm install` in a worktree, never `npm ci`.** `ci` wipes `node_modules` and
  rebuilds it from the lockfile, throwing away the clone and paying the full
  install. This is why `bump-shared-lib` is cheap now.
- **The clone needs `packages/<repo>/node_modules` to exist — and `wt new`
  seeds it there, not in the worktree.** With nothing to clone it installs in
  `packages/<repo>` and then clones the result, so the full install is paid
  **once per repo**, never once per task. A worktree-local install would look
  identical the first time and leave the main checkout empty, so the next task
  would pay it again. `wt seed [--repo <name>|all]` is the same install on
  demand — for paying the wait outside a task, e.g. right after `wt clone` — and
  it **skips a repo that already has `node_modules`** instead of reinstalling.
  `wt doctor` names the repos still unseeded.
- **`--link-modules` is for read-only work only.** It shares one directory with
  every other worktree, so a version change there hits all of them, and in a
  workspace monorepo the internal `@scope/*` imports resolve to the *main*
  checkout. `--install` (from scratch) and `--no-deps` are the other overrides;
  none of the three is needed unless the user asks.

## Continuing a branch that is already on origin

`wt new` *creates* a branch, so it is the wrong tool for one that is already
pushed — it would fork a second branch under the same name:

```bash
.claude/skills/wt/adopt.sh <feature/branch> --repo <name>   # or: make adopt BRANCH=… REPO=…
```

The task name is whatever follows `feature/`, so
`feature/billing-rework/03-invoices` lands in
`worktrees/billing-rework/03-invoices/` and everything else on this page
applies unchanged — `list`, `rm` and `doctor` find a checkout at whatever depth
the task name puts it, and `rm <task>/<sub>` cleans the grouping dirs it
empties. Either name works as the task: the full nested one
(`wt rm billing-rework/03-invoices`) or the outer one, in which case
`--repo` is matched against the checkouts that task actually has —
`wt rm billing-rework --repo api` finds it at
`03-wallets/api`. When the task holds that repo more than once the name
is ambiguous and `rm` refuses, listing the sub-paths to pick from; removing a
checkout is destructive, so it never guesses. The wrapper prunes dead worktree registrations, deletes the
local branches whose *name* blocks the nested one (git keeps refs as files, so
`refs/heads/feature/x` blocks `refs/heads/feature/x/03`) — each only after being
proved contained in an origin ref, with its sha printed — then calls `wt new`
with `--base <branch> --allow-stale --no-always`.

It refuses instead of guessing when a blocker's commits are on no origin ref
(`--drop-unmerged` overrides it), when local branches live *below* the name, or
when the branch is not on origin at all — that last one means `wt new` was the
right command. `--dry-run` prints the plan and touches nothing.

## While the task is open

- **Read and claim before editing:**
  `.claude/skills/coordination/coord status`, then
  `.claude/skills/coordination/coord claim <task>`. An overlapping owner warns;
  coordinate writer scopes instead of assuming the other session died.
- **Edit only in `worktrees/<task>/<repo>/`**, never in `packages/<repo>/` — a
  `permissions.deny` rule on `Edit(/packages/**)` enforces it.
- **Scope every search to `worktrees/<task>/`.** From the workspace root the same
  file matches in `packages/` and in every other task's tree.
- `.claude/skills/wt/wt list` — open tasks, coordination state, repos, branches,
  and a `*` on dirty ones.

## Closing a task

`commit-and-mr` first — pushing is what makes the branch survive the worktree.
Record the handoff through the `coordination` skill. Only then:

```bash
.claude/skills/wt/wt rm <task> --delete-branch
```

To sweep every task whose work already reached its base branch — HEAD is an
ancestor of `origin/<base>` or `git cherry` finds every patch there — run
`.claude/skills/wt/wt cleanup --dry-run`, show the user the list, then
`.claude/skills/wt/wt cleanup`. It keeps dirty or detached checkouts, leased
tasks, tasks that never committed, non-rebuildable ignored files and
squash-merged branches, and says why for each.

`worktrees/<task>/.agent-routing/` (agent-directed-routing bookkeeping) is never a
task or a repo. While it holds work — a writer checkout in `checkouts/`, a ledger
entry not `integrated`/`failed`, an unreadable ledger, files in `recovery/` or
`journals/`, nested `<task>/<sub>/` included — `cleanup` keeps the task and
`rm` refuses; finish or `writer.py recover` it instead of reaching for `--force`.
Idle bookkeeping goes with the task's last checkout.

With no `--repo` it removes **every** repo of the task and the `worktrees/<task>/`
dir. It refuses while your shell is inside that tree or a fresh agent lease owns
the task. A worktree with untracked
files (its cloned or linked `node_modules`) needs `--force`, which is
deny-listed here — ask the user rather than working around it.

## When something looks wrong

```bash
.claude/skills/wt/wt doctor [--repo <name>]... [--no-fetch]
```

Exits non-zero on a real problem, warns on a note. What it reports:

| Reported | Meaning | Fix |
| --- | --- | --- |
| behind `origin/<base>` | `wt new` will refuse for that repo, and a Track Q answer off it is stale | `.claude/skills/wt/wt pull --repo <repo>` |
| in `repos.json`, not on disk | never cloned | `.claude/skills/wt/wt clone <name>` — the `clone` skill |
| broken symlink in a worktree | its `.env`/`node_modules` target is gone | relink, or reinstall in `packages/<repo>` |
| no `node_modules` in `packages/<repo>` | nothing to clone — the next `wt new` installs there once, then clones | nothing, or `.claude/skills/wt/wt seed --repo <repo>` to pay it now |
| missing `.env*` | added to `packages/<repo>` after `wt new` | the `ln -s` it prints |
| missing `.husky/_` | Husky support files exist in `packages/<repo>` but not in this checkout | copy the directory from the printed source path |
| stale worktree registration | directory removed by hand, not by `wt rm` | `.claude/skills/wt/wt prune --repo <name>` |
| checkout on a non-base branch | note — `--pull` can't fast-forward it | check it out to the base, or leave it |

Run it before blaming a build: a missing nested `.env` or a `node_modules`
pointing at a reinstalled main checkout looks exactly like a code failure.
It also runs `coordination doctor`, so corrupt/stale leases are visible beside
filesystem problems.

**Remote Git uses HTTPS and one `GITHUB_TOKEN`.** `wt new`, `wt pull`,
`wt doctor`, `adopt.sh` and `wt clone-url` use
[`commit-and-mr/lib.sh`](../commit-and-mr/lib.sh). The process environment
wins over the workspace root `.env`, including an explicitly empty value.
The same selected token authenticates git and `gh`; stored CLI credentials
and other token variables cannot override it. Remote URLs stay token-free.

Missing credentials or refused authentication stops the command and names
`NEXT=github-login`. Network failures retain the command's documented
`--allow-stale`/offline behavior; never report a stale ref as freshly fetched.

For the workspace repository itself, which need not appear in `repos.json`, use
`wt clone-url <task> <url> --name <repo> --task-branch`. This creates the configured
`branchPrefix` plus task. Repeating the command accepts the same clean checkout
on that task branch. A matching origin and clean default/base branch are required
before creating a branch in an existing clone; foreign branches and detached HEAD
are refused without switching or resetting.

## Boundaries

- `wt` creates branches and local worktrees. It never pushes, merges, tags or
  opens a PR — that is `commit-and-mr`.
- Branch names come from `wt` (`feature/<task>`). Don't hand-create branches, and
  never one starting with `claude`.
- Adding, removing or re-cloning a repo in `packages/` is the `clone` skill and
  `repos.json`, not this one.

Full reference — flags, the `deps` strategies, `.env` handling, `repos.json`
fields: [`WORKTREES.md`](../../../../WORKTREES.md) and `.claude/skills/wt/wt --help`.
