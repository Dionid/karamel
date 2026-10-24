# Agent-directed routing

Added a tracked provider catalog, generated role/capability profiles, mandatory
parent-directed dispatch policy, bounded fallback, depth limits, and isolated
writers: every write-capable child works in its own disposable checkout
(`worktrees/<task>/.agent-routing/checkouts/`) and its patch is verified against
the reserved scope and integrated hop by hop with compare-and-swap, so the
canonical task worktree is never written by a child. A failed hop leaves the
target unchanged and keeps a recovery bundle in
`worktrees/<task>/.agent-routing/recovery/<agentPath>/`. Stale checkouts after a
crash are cleaned with `writer.py recover` (registered paths only; unregistered
directories are reported, not deleted). Upgrade with `git pull && ./ops sync`;
rollback by reverting this change and running `./ops sync` again, then delete
leftover `.agent-routing/` directories of open tasks by hand once no writer is live.
