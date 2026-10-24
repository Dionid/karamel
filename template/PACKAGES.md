# Repositories

`repos.json` is the repository catalog. It starts empty: no company repositories
are configured or fetched automatically.

Add repositories under `repos` with their URL and base branch, then use the
`clone` skill to populate `packages/`. Open task checkouts with the `wt` skill.
`packages/` is read-only; changes belong in `worktrees/<task>/<repo>/`.

Optional repository fields include `knowledgeRoot`, `specRoot`, `skills`, `deps`
and `postSetup`; see `WORKTREES.md` and the relevant skills for their contracts.
`always` lists repositories required in every task. Configure `notionSnapshotRepo`
only when using a dedicated Notion snapshot repository.
