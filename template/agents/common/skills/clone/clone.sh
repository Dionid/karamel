#!/usr/bin/env bash
#
# clone.sh — bootstrap packages/ from repos.json on a fresh machine.
#
# Existing directories are left alone, so re-running is safe. Per-repo
# "postClone" hooks from repos.json run after a successful clone.
#
# `.claude/skills/wt/wt clone` does the same thing and is the usual entry point;
# this script exists so a fresh machine can bootstrap without jq (it parses
# repos.json with python3) and clones in parallel.
#
# The file lives at .claude/skills/clone/clone.sh and that path is the entry
# point — there is deliberately no ./clone.sh at the workspace root. The root is
# found by walking up to repos.json, so cwd never matters.

set -euo pipefail

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_off=$'\033[0m'
info() { printf '%s%s%s\n' "$c_grn" "$*" "$c_off"; }
warn() { printf '%s%s%s\n' "$c_ylw" "$*" "$c_off"; }
err()  { printf '%s%s%s\n' "$c_red" "$*" "$c_off" >&2; }

usage() {
  # @SELF@ -> the actual invocation path, so the examples can be pasted back.
  sed "s|@SELF@|$SELF|g" <<'EOF'
clone.sh — bootstrap packages/ from repos.json on a fresh machine.

Invoked by path; there is no ./clone.sh at the workspace root.

  @SELF@ [--list] [--install] [--always] [-j N] [<repo>...]

  (no repo)     clone everything not in "exclude"
  <repo>...     only these — an excluded name given explicitly is still cloned
  --always      clone only repos.json "always" repositories
  --list        just print what would be cloned, and from where
  --install     ...and install deps in each checkout
  -j N          parallel clones (default 4, or $CLONE_JOBS)

Existing directories are skipped, so re-running is safe.
`.claude/skills/wt/wt clone` does the same thing through the manifest-aware path;
this one needs only git + python3.
EOF
}

# The workspace root is the directory holding harness.json. Resolve the symlink
# chain first (so a symlink or a PATH shim to this file works too), then walk up
# from the real file — dirname alone would give .claude/skills/clone.
resolve_workspace_root() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  if [ "${1-}" = --source-dir ]; then printf '%s\n' "$dir"; return 0; fi
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/harness.json" ]; then printf '%s\n' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

ROOT_DIR="$(resolve_workspace_root)" \
  || { err "cannot locate the workspace root — no harness.json above ${BASH_SOURCE[0]}"; exit 1; }
SOURCE_DIR="$(resolve_workspace_root --source-dir)"
SELF="$0"   # how this run was invoked, for pasteable hints (see usage)
MANIFEST="$ROOT_DIR/repos.json"
PKGS="$ROOT_DIR/packages"
JOBS="${CLONE_JOBS:-4}"

command -v git >/dev/null 2>&1 || { err "git not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 not found (needed to read repos.json)"; exit 1; }
[ -f "$MANIFEST" ] || { err "no manifest at $MANIFEST"; exit 1; }

INSTALL=0; LIST=0; NAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --install) INSTALL=1 ;;
    --always)  ALWAYS=1 ;;
    --list)    LIST=1 ;;
    -j|--jobs) JOBS="${2:?--jobs needs a number}"; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        err "unknown flag: $1"; exit 1 ;;
    *)         NAMES+=("$1") ;;
  esac
  shift
done
[ "${ALWAYS:-0}" = 1 ] && [ "${#NAMES[@]}" -gt 0 ] && { err "--always cannot be combined with explicit repo names"; exit 1; }

# Emit "<name>\t<url>\t<branch>\t<postClone joined by \x1f>" for the repos to
# clone. With no explicit names, .exclude is honoured; named repos always pass.
plan() {
  python3 - "$MANIFEST" "${ALWAYS:-0}" "$@" <<'PY'
import json, sys
manifest, always, *names = sys.argv[1:]
with open(manifest) as fh:
    data = json.load(fh)
repos = data.get("repos", {})
excluded = set(data.get("exclude", []))
if always == "1":
    wanted = data.get("always", [])
    unknown = [n for n in wanted if n not in repos]
    if unknown:
        sys.exit("always repos not in repos.json: " + " ".join(unknown))
elif names:
    unknown = [n for n in names if n not in repos]
    if unknown:
        sys.exit("not in repos.json: " + " ".join(unknown))
    wanted = names
else:
    wanted = [n for n in sorted(repos) if n not in excluded]
for name in wanted:
    entry = repos[name]
    url = entry.get("url", "")
    if not url:
        sys.exit(f'{name}: no "url" in repos.json')
    hooks = "\x1f".join(entry.get("postClone") or [])
    print("\t".join([name, url, entry.get("branch", ""), hooks]))
PY
}

# Package manager of a checkout, from its lockfile.
#
# The `package.json` guard comes first, and a lockfile never overrides it: a
# repository can keep a lockfile at its root while the project it belongs to
# lives in a subdirectory (a frontend repository keeps
# `package-lock.json` next to `app/package.json`). Choosing `npm ci` from the
# lockfile alone makes every package manager fail with ENOENT on a checkout
# that has nothing to install at its root — and that subdirectory is what the
# manifest's `postSetup` is for, not this function.
pm_for() {
  local dir="$1"
  [ -f "$dir/package.json" ] || { echo ""; return; }
  if [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then echo "bun install"; return; fi
  [ -f "$dir/pnpm-lock.yaml" ] && { echo "pnpm install"; return; }
  [ -f "$dir/yarn.lock" ]      && { echo "yarn install"; return; }
  [ -f "$dir/package-lock.json" ] && { echo "npm ci"; return; }
  echo "npm install"
}

clone_one() {
  # Two statements, not one. `local` is a builtin, so ALL of its arguments are
  # expanded before any of its assignments take effect: in
  # `local name="$1" dir="$PKGS/$name"`, the `$name` inside dir is the GLOBAL
  # name, not the one being declared on the same line.
  #
  # This used to be one statement, and it worked only by coincidence — the driver
  # loop below reads into a global `name`, which held the same value being passed
  # as $1. Rename that loop variable, or call this function from anywhere else,
  # and dir silently becomes "$PKGS/" (whereupon `[ -e "$dir" ]` matches packages/
  # itself and every repo reports "already present") or "$PKGS/<some stale name>"
  # (whereupon the clone lands in the wrong directory).
  local name="$1" url="$2" branch="$3" hooks="$4"
  local dir="$PKGS/$name"
  local ensure="$SOURCE_DIR/ensure-repository"

  # An existing checkout skips the clone and its postClone hooks — those belong
  # to a fresh tree — but NOT the install below. `--install` is the flag of the
  # normal workflow: clone everything first, then install into the one repo the
  # task needs. Returning here made that flag a silent no-op on every workspace
  # that had already been cloned, which is every workspace after its first day.
  if [ -e "$dir" ]; then
    info "[$name] already present — clone skipped"
  else
    "$ensure" "$name" || return 1

    local n=0 cmd hook_list=()
    IFS=$'\x1f' read -r -a hook_list <<< "$hooks"
    for cmd in ${hook_list[@]+"${hook_list[@]}"}; do
      [ -n "${cmd//[[:space:]]/}" ] || continue
      n=$((n + 1))
      info "[$name] postClone[$n]: $cmd"
      ( cd "$dir" && ROOT_WORKTREE_PATH="$dir" REPO_NAME="$name" bash -c "$cmd" ) \
        || { err "[$name] postClone[$n] failed: $cmd"; return 1; }
    done
  fi

  if [ "$INSTALL" = 1 ]; then
    local cmd_i; cmd_i="$(pm_for "$dir")"
    if [ -n "$cmd_i" ]; then
      info "[$name] $cmd_i"
      # NPM_TOKEN from the root .env is needed for private registries.
      ( cd "$dir" \
          && if [ -f "$ROOT_DIR/.env" ]; then set -a; . "$ROOT_DIR/.env"; set +a; fi \
          && bash -c "$cmd_i" ) || { err "[$name] install failed"; return 1; }
    else
      warn "[$name] nothing to install (no package.json)"
    fi
  fi
  return 0
}

PLAN="$(plan "${NAMES[@]+"${NAMES[@]}"}")" || exit 1
[ -n "$PLAN" ] || { warn "nothing to clone"; exit 0; }

if [ "$LIST" = 1 ]; then
  printf '%s\n' "$PLAN" | while IFS=$'\t' read -r name url branch _; do
    printf '%-32s %s%s\n' "$name" "$url" "${branch:+ ($branch)}"
  done
  exit 0
fi

mkdir -p "$PKGS"

# One log per repo so parallel clones don't interleave their output.
LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

running=0
while IFS=$'\t' read -r name url branch hooks; do
  [ -n "$name" ] || continue
  ( clone_one "$name" "$url" "$branch" "$hooks" >"$LOGS/$name.log" 2>&1 \
      && : >"$LOGS/$name.ok" ) &
  running=$((running + 1))
  if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || wait; running=$((running - 1)); fi
done <<< "$PLAN"
wait

ok=""; bad=""
while IFS=$'\t' read -r name _ _ _; do
  [ -n "$name" ] || continue
  cat "$LOGS/$name.log" 2>/dev/null || true
  if [ -f "$LOGS/$name.ok" ]; then ok="$ok $name"; else bad="$bad $name"; fi
done <<< "$PLAN"

echo
[ -n "$ok" ] && info "ok:$ok" || true
if [ -n "$bad" ]; then err "failed:$bad"; exit 1; fi
[ "$INSTALL" = 1 ] || warn "deps not installed — run $SELF --install, or install per repo"
