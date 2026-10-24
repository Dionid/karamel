@AGENTS.md

# Workspace quick reference

`AGENTS.md` is the canonical source of workspace rules. Read it before acting;
this file only provides command shortcuts and does not replace those rules.

- Build or refresh runtime trees: `./ops setup` / `./ops sync` (workspace root only).
- Verify the agent layer: `./ops check`.
- Run workspace lint: `agents/common/skills/lint/lint.sh --require-tools`.
- Open a task: `.claude/skills/wt/wt new <task> --repo <repo> --pull`.
- Claim ownership: `.claude/skills/coordination/coord claim <task>`.
- Update the root checkout: follow `.claude/skills/self-update/SKILL.md`.

Repository roles and knowledge/spec locations come from `repos.json` and
`PACKAGES.md`; do not hardcode them here. Edit agent sources in `agents/`,
not generated `.claude/`, `.agents/`, or `.codex/` trees.
