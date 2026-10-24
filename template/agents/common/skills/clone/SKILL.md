---
name: clone
description: Наполнить packages/ из repos.json через .claude/skills/clone/clone.sh и поддерживать манифест. Использовать, когда репозиториев не хватает, packages/ пуст, wt new не находит репозиторий, или репозитории добавляются/удаляются.
---

# clone — packages/ from repos.json

**`repos.json` is the source of truth for what belongs in `packages/`; nothing is
cloned into it by hand.** `packages/` is gitignored, so a fresh clone of the
workspace has the manifest and the docs and nothing else.

**Always call it by path: `.claude/skills/clone/clone.sh`.** There is no
`./clone.sh` at the workspace root, and a human's shell alias doesn't exist in
your Bash calls. It finds the workspace by walking up to `repos.json`, so cwd
never matters. `.claude/skills/wt/wt clone` does the same job through `jq`;
`clone.sh` needs only `git` + `python3` and clones in parallel, which is why it is
the fresh-machine entry point.

## Cloning

```bash
CLONE=.claude/skills/clone/clone.sh

$CLONE --list                    # what would be cloned, and from where
$CLONE                           # everything not in "exclude"
$CLONE --always                  # only repos.json "always" repositories
$CLONE api signer     # only these (an excluded name given explicitly
                                 # is still cloned)
$CLONE --install                 # …and install deps in each checkout
```

- **Existing directories are skipped**, so re-running is safe and is the normal
  way to pick up a repo added to the manifest. **`--install` is not skipped with
  them**: an already-cloned repo still gets its dependencies installed, which is
  what makes "clone everything now, install the one repo the task needs later"
  work.
- **A lockfile without a `package.json` next to it installs nothing**, and says
  so. The project then lives in a subdirectory — a frontend repository
  keeps `package-lock.json` at the root and the app in `app/` — and that
  subdirectory belongs to the manifest's `postSetup`, which `wt` runs when it
  sets up a worktree. `clone.sh --install` only ever installs at the root.
- **Repository acquisition is atomic.** Both `clone.sh` and `wt new` use
  `ensure-repository`: manifest validation, a per-repo lock, temporary clone
  under `packages/` on the same filesystem, token-free origin verification,
  `git fsck`, and atomic rename into place. A failed clone never becomes the
  checkout that `wt new` branches from.
- **GitHub repositories clone over HTTPS with one `GITHUB_TOKEN`.**
  [`commit-and-mr/lib.sh`](../commit-and-mr/lib.sh) selects the process
  environment before the workspace root `.env`, including an explicitly
  empty process value. The same token authenticates git and `gh`; stored CLI
  credentials and other token variables cannot override it. The stored
  origin stays token-free. Missing credentials or denied access stops the
  clone with an actionable message.
- **`--always` is narrow on purpose.** It clones only the manifest's `always`
  set for installation/bootstrap boundaries. Running `clone.sh` without repo
  names remains the explicit manual clone-all mode.
- **Installing needs the private-registry token.** `@org/*` comes from the
  package registry, so `NPM_TOKEN` must be exported — the script
  sources the workspace root `.env` for the install step itself, but load it the
  same way (`set -a; . ./.env; set +a`) in the same Bash call if you install by
  hand. Never print a value out of it.
- **Don't `--install` unprompted.** Ten repos of `node_modules` is a long wait;
  clone first, install the one repo the task needs.
- Which repo does what, and which are similarly named but different
  (`api` vs `api-backend` vs `backend-utils-lib`):
  [`PACKAGES.md`](../../../../PACKAGES.md). Read it before cloning "the application repo".

## Adding or removing a repo

For manifest creation, field semantics and changes use
[repos-manifest](../repos-manifest/SKILL.md) and its
[schema reference](../repos-manifest/schema.md). Edit the manifest in a task
worktree of the workspace repository, never in the root checkout.
After delivery to the workspace manifest, acquire the new repository with
`.claude/skills/clone/clone.sh <name>`.

`wt manifest` writes the manifest of its discovered workspace root; do not run
it from the root checkout to bypass task-worktree editing. It refreshes URLs,
adds entries and preserves existing nonempty base branches and other fields.

## Boundaries

- This skill only fills `packages/`. **Never edit anything inside it** — a
  `permissions.deny` rule on `Edit(/packages/**)` enforces that; work happens in
  a worktree (the `wt` skill).
- `clone.sh` clones and optionally installs. It does not branch, pull or update
  an existing checkout: pulling is `git -C packages/<repo> pull`, and
  `.claude/skills/wt/wt doctor` says which ones need it.
- Editing `repos.json` is a change to the workspace repo like any other — it gets
  committed, not left dirty.
