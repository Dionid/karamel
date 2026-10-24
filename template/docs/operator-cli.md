# Agent workspace operator CLI

`npm run ops --` is the package entrypoint for workspace setup, repository
root `./ops` executable, so the direct form remains available without npm. The
implementation scripts stay next to the skills that own their behavior; the CLI
supplies a discoverable command catalog and stable argument forwarding.

```bash
npm run ops -- help
npm run ops -- help wt
source <(npm run --silent ops -- completion zsh)
```

## Common operations

```bash
npm run ops -- setup
npm run ops -- status --json
npm run ops -- sync
npm run ops -- check

npm run ops -- clone
npm run ops -- doctor --repo <repo>
npm run ops -- pull --repo <repo>
npm run ops -- wt new my-task --repo <repo> --pull
npm run ops -- adopt feature/my-task --repo <repo>

npm run ops -- lint
npm run ops -- lint strict

npm run ops -- upgrade --dry-run
npm run ops -- upgrade
```

On a fresh clone, `./ops setup` also copies `.env.example` to the ignored
`.env` when that file does not exist. It never overwrites existing credentials.

The CLI resolves tools from a built `.claude/skills/` tree first and falls back
to their canonical sources under `agents/common/skills/`. Runtime trees are
built entirely from tracked sources in this repository; no external generator
or development checkout is required.

## Migration from Make

| Previous command | Operator CLI |
| --- | --- |
| `make setup` | `npm run ops -- setup` |
| `make sync` | `npm run ops -- sync` |
| `make update` | `npm run ops -- update` |
| `make status` | `npm run ops -- status` |
| `make check` | `npm run ops -- check` |
| `make clone ARGS="…"` | `npm run ops -- clone …` |
| `make doctor ARGS="…"` | `npm run ops -- doctor …` |
| `make wt ARGS="…"` | `npm run ops -- wt …` |
| `make wt-new TASK=x REPO="a b" ARGS=--pull` | `npm run ops -- wt new x --repo a --repo b --pull` |
| `make pull REPO="a b"` | `npm run ops -- pull --repo a --repo b` |
| `make adopt BRANCH=feature/x REPO="a b"` | `npm run ops -- adopt feature/x --repo a --repo b` |
| `make lint-strict` | `npm run ops -- lint strict` |
| `make lint-install` | `npm run ops -- lint install-hook` |
| `make lint-tools` | `npm run ops -- lint install-tools` |
| `make cleanup-worktrees ARGS=--apply` | заархивировано; после ручной проверки используйте `npm run ops -- wt rm …` |
