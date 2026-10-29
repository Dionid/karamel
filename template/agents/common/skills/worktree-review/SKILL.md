---
name: worktree-review
description: Ревью локальных изменений по всем репозиториям checkout'а worktrees/<task>/ — коммиты ветки плюс незакоммиченная работа — с отчётом, где сначала дефекты. Использовать, когда пользователь просит code-review worktree, ревью изменений задачи, или ревью всех репозиториев под worktrees/<task>/.
---

# Review a worktree across all its repos

Read-only code review of everything that differs from the base branch in
`worktrees/<task>/`. A task can span several repos; review **every** repo that
has a checkout there, not only the one currently in cwd.

Do **not** edit files, commit, push, or post to GitHub unless the user asks for
that after the review.

## 1. Resolve which worktree

```bash
pwd
.claude/skills/wt/wt list   # tasks, repos, branches; dirty ones marked *
```

- cwd inside `worktrees/<task>/<repo>/` or `worktrees/<task>/` → that `<task>`.
- cwd at the `workspace/` root → infer from what this session edited. If several
  tasks look plausible, **ask which task**.
- User named a task → use `worktrees/<task>/` directly.
- **Refuse if cwd is under `packages/`.** Point them at the matching
  `worktrees/<task>/` checkout.

List every directory under `worktrees/<task>/` that is a git repo:

```bash
ls -1 worktrees/<task>/
```

Skip empty / missing repos. Review all that exist, even if only one is dirty.

## 2. Collect the diff per repo

For each `<repo>` under `worktrees/<task>/<repo>/`:

```bash
base="$(jq -r --arg r "<repo>" '.repos[$r].branch // "main"' repos.json)"
git -C "worktrees/<task>/<repo>" fetch origin "$base" --quiet 2>/dev/null || true
mb="$(git -C "worktrees/<task>/<repo>" merge-base HEAD "origin/$base" 2>/dev/null \
  || git -C "worktrees/<task>/<repo>" merge-base HEAD "$base")"

git -C "worktrees/<task>/<repo>" status --short
git -C "worktrees/<task>/<repo>" log --oneline "$mb..HEAD"
git -C "worktrees/<task>/<repo>" diff --stat "$mb"
git -C "worktrees/<task>/<repo>" diff "$mb"          # committed + unstaged vs merge-base
git -C "worktrees/<task>/<repo>" diff --cached       # staged-only delta (if any)
```

`git diff $mb` covers committed branch work plus unstaged working-tree changes.
Also read `--cached` when the index differs from HEAD so staged-but-uncommitted
edits are not missed. If both are empty and there are no untracked source files,
say that repo is clean and move on.

Untracked files that look like source (not `node_modules`, build output, `.env*`)
must be **Read** and included in the review.

Never read or quote secret files (`.env`, `.env.*` except templates, keys,
certs). If they appear in the diff, flag that as a **Blocking** finding and do
not print their contents.

Skip noise: lockfiles, generated code, vendored dirs, `dist/`, `.dart_tool/`.

## 3. Review — defect-first

Scope searches and file reads to `worktrees/<task>/` only — never the twin paths
under `packages/`.

For each changed path, read enough surrounding code and call sites to verify the
finding. Check the other repos in the same task for contract drift (shared types,
RPC/call defs in `shared-lib` vs handlers in `api` vs clients in
`mobile-app`, migrations vs model usage, etc.).

Flag an issue only when all of these hold:

- Affects correctness, security, money/auth flows, performance, or maintainability
  in a meaningful way — or breaks cross-repo consistency for this task.
- Discrete and actionable.
- Introduced (or exposed) by the reviewed change.
- Demonstrable from the code.
- The author would likely fix it if they knew.

Do **not** flag speculative concerns, pre-existing debt, intentional behavior
changes, or pure style nits.

Priority order while reading:

1. Correctness / logic bugs, error handling, edge cases (balances, withdrawals,
   деньги, права доступа, восстановление)
2. Security (authz, injection, secrets in diff, unsafe input)
3. Cross-repo contract mismatches
4. Missing tests for new logic
5. Conventions / dead code only when they obscure real risk

Honor each repo's `CLAUDE.md` / lint rules when present under the worktree.
When the repo documents no standard of its own for a §5 judgement call,
[`references/code-smells.md`](references/code-smells.md) is an optional
baseline (Fowler smells) — a documented repo convention always overrides it.

## 4. Does the spec have to change?

Answer it explicitly, every time — it is the second half of the review, not an
afterthought. Compare what the diff now makes the system *do* against
`worktrees/<task>/spec-repo/openspec/specs/<capability>/spec.md`:

- **Unaffected** — an implementation detail: refactor, performance, an internal
  rename, error handling, a fix that restores behaviour the spec already
  promises. The common case.
- **Drift** — a spec describes this behaviour and the code no longer matches it.
  Name the file and the requirement, and quote the line that is now false.
- **Unspecified** — something observable changed that no spec covers. Name the
  capability it belongs under, and what the requirement would have to say.

This skill only *reports* the ruling. Writing it is a caller's decision: on
Track F the `reviewer` agent may create or update the spec (`AGENTS.md` →
[the closing review](../../../../AGENTS.md)); a human running this skill decides for
themselves. On Track C the spec was written before the code, so drift is a
finding for the user to rule on and nothing gets rewritten to match the code.

## 5. Report

Lead with a one- or two-line verdict (ship / fix-then-ship / blocked).

Then findings, highest severity first. Group by repo when there are several.
Every finding is a numbered list item with Arabic digits (`1.`, `2.`, `3.`),
numbered continuously across the whole report. Do not restart numbering per
severity or repo; later messages must be able to say "fix item 3".

One entry per issue:

```markdown
### Blocking | Should-fix | Nit

1. **`repo`** `path/to/file.ts:LINE` — short imperative title.
  Why it's wrong in the affected scenario; suggested fix in one sentence.
  Options: default fix; alternative fix when there is a real tradeoff.
```

Include at least one concrete solution option for every finding. When there are
multiple defensible approaches, list the practical options and name the
recommended one with the reason; when there is only one sensible fix, say that
single fix plainly.

- **Blocking** — must fix before merge (P0/P1).
- **Should-fix** — real defect; fix soon (P2).
- **Nit** — low-impact but still worth fixing (P3). Only include if actionable.

If a repo is clean: `No findings` for that repo — do not invent issues.

After findings, a short overall note: residual risk, test gaps, and (for
multi-repo tasks) suggested PR/land order (shared lib → backend → app).

Close with the spec ruling from §4 on its own line — `SPEC: unaffected | drift |
unspecified — <detail>`. "No findings" is not an answer to it.

## Guardrails

- Read-only: no edits, commits, pushes, or GitHub notes from this skill alone.
  The spec ruling in §4 is a report; whoever runs the skill decides whether to
  act on it.
- Do not use `EnterWorktree`; the checkout already exists under `worktrees/`.
- Do not review `packages/<repo>/` as a substitute for the worktree.
