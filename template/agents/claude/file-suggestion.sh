#!/usr/bin/env bash
# @-autocomplete for this workspace.
#
# The built-in file suggestion honours .gitignore, and this repo gitignores
# /packages/* and /worktrees/ — i.e. every directory anyone actually works in.
# So @ never suggested anything useful. This replaces it with a search that
# ignores VCS ignore rules and lists directories as well as files.
#
# stdin:  {"query": "worktrees/merch"}
# stdout: newline-separated paths, at most 15 (the UI takes no more).
#
# No `pipefail` and an explicit `exit 0` at the end, both load-bearing: every
# pipeline here ends in `head -15`, so as soon as there are more than 15 matches
# head closes the pipe and the producer dies of SIGPIPE. With pipefail that is
# exit 141, and a non-zero exit makes Claude Code discard the suggestions —
# i.e. autocomplete broke in exactly the crowded directories it exists for.
set -u

root="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$root" || exit 0

query=$(jq -r '.query // ""' 2>/dev/null)
# Claude Code usually sends the path fragment after `@`, but some builds and
# hosts pass the raw token. Normalise both forms so @packages and packages match.
query="${query#@}"
query="${query#./}"

# Directories we never want to walk into or offer.
PRUNE_NAMES=(
  .git node_modules .dart_tool .gradle .idea .venv __pycache__
  dist build coverage .next .turbo .nuxt .output Pods DerivedData
)
# Prune-by-path, relative to the workspace root. Empty here on purpose: which
# checkouts are noise is a property of the repo set, not of the harness. A
# workspace with a vendored SDK under packages/ overrides this file from its
# config layer (config/agents/claude/file-suggestion.sh) and lists it here.
PRUNE_PATHS=()

find_prune=()
for n in "${PRUNE_NAMES[@]}"; do
  find_prune+=(-name "$n" -o)
done
for p in ${PRUNE_PATHS[@]+"${PRUNE_PATHS[@]}"}; do
  find_prune+=(-path "$p" -o)
done
unset 'find_prune[${#find_prune[@]}-1]'   # drop the trailing -o

rg_globs=()
for n in "${PRUNE_NAMES[@]}"; do
  rg_globs+=(-g "!**/$n/**" -g "!**/$n")   # …/$n also matches the worktree gitlink *file* .git
done
for p in ${PRUNE_PATHS[@]+"${PRUNE_PATHS[@]}"}; do
  rg_globs+=(-g "!${p#./}/**")
done

# `rg` is preferred but must not be assumed: on a machine where ripgrep comes
# only from Claude Code's shell init it is a *shell function*, which does not
# exist in this script — the call then failed silently and @ offered directories
# and no files at all. find is the fallback, walking the same pruned tree.
list_files() {
  if command -v rg >/dev/null 2>&1; then
    rg --files --no-ignore-vcs --hidden --follow "${rg_globs[@]}" 2>/dev/null
  else
    find . -mindepth 1 -maxdepth 8 \( "${find_prune[@]}" \) -prune -o \
      -type f -print 2>/dev/null | sed 's|^\./||'
  fi
}

# No query yet: offer the top-level directories, which is the useful default
# in a workspace whose whole layout is packages/<repo> and worktrees/<task>.
if [[ -z "$query" ]]; then
  {
    find . -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print
    find ./worktrees ./packages -mindepth 1 -maxdepth 1 -type d -not -name '.*' -print
  } 2>/dev/null | sed -e 's|^\./||' -e 's|$|/|' | awk '!seen[$0]++' | head -15
  exit 0
fi

# Match case-insensitively on the whole relative path, so "merch" finds
# worktrees/refund-flow and "wb/src" finds nothing surprising.
pattern=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]')

# Directories and files in one ranking, shortest path first, so the parent
# beats its children and the root file beats a deep namesake. A directory wins
# ties against an equally long file — directories are the thing the built-in
# suggestion could never offer here, and typing on from one is the point.
{
  find . -mindepth 1 -maxdepth 8 \( "${find_prune[@]}" \) -prune -o \
    -type d -print 2>/dev/null |
    sed 's|^\./||' |
    awk -v q="$pattern" 'index(tolower($0), q) { print length($0) - 1, $0 "/" }'

  list_files |
    awk -v q="$pattern" 'index(tolower($0), q) { print length($0), $0 }'
} | sort -n -k1,1 -s | cut -d' ' -f2- | awk '!seen[$0]++' | head -15

exit 0
