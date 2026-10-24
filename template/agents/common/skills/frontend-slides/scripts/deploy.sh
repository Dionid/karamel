#!/usr/bin/env bash
# deploy.sh — deploy a slide deck to Vercel for instant sharing.
#
# Usage:
#   bash scripts/deploy.sh <path-to-slide-folder-or-html> --yes [--allow-npx]
#
# This is an EXTERNAL WRITE (a public URL, however easy to take down), so by
# engine rule it only runs after the user explicitly agreed to it — hence the
# mandatory --yes flag. Without it the script only explains what it would do.
#
# It also never installs or downloads anything without asking: if the Vercel
# CLI is not present, this refuses and tells the user the exact command to
# run themselves, instead of running `npm install -g vercel` on their behalf
# — and it will not fetch it on demand via `npx` either unless `--allow-npx`
# is also passed, because that downloads and runs someone else's code from
# the npm registry just as much as an install would.
#
# Requires VERCEL_TOKEN in the workspace root .env (checked via env-check.sh,
# never printed). The token lets deploys run non-interactively — no
# `vercel login` browser flow, no session left behind.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; CYAN=""; YELLOW=""; BOLD=""; NC=""; }

info()  { echo -e "${CYAN}i${NC} $*"; }
ok()    { echo -e "${GREEN}ok${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
err()   { echo -e "${RED}x${NC} $*" >&2; }

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$SCRIPT_DIR"
while [ "$ROOT" != "/" ] && [ ! -f "$ROOT/harness.json" ] && [ ! -f "$ROOT/workspace.json" ]; do ROOT="$(dirname "$ROOT")"; done
ENV_CHECK="$ROOT/.claude/skills/env-check/env-check.sh"
[ -x "$ENV_CHECK" ] || ENV_CHECK="$ROOT/agents/common/skills/env-check/env-check.sh"

# env-check.sh only inspects .env — it never loads it into this process, so
# VERCEL_TOKEN would otherwise be unbound here even though env-check just
# confirmed it is set. Load it ourselves.
ENV_FILE="$ROOT/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

INPUT=""
CONFIRMED=0
ALLOW_NPX=0
for arg in "$@"; do
  case "$arg" in
    --yes) CONFIRMED=1 ;;
    --allow-npx) ALLOW_NPX=1 ;;
    -h|--help)
      sed -n '2,20p;22,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) [ -z "$INPUT" ] && INPUT="$arg" ;;
  esac
done

if [ -z "$INPUT" ]; then
  err "usage: bash scripts/deploy.sh <path-to-slide-folder-or-html> --yes"
  exit 1
fi

if [ "$CONFIRMED" -ne 1 ]; then
  err "деплой — внешняя запись (публичный URL), нужно явное согласие пользователя на точный деплой: повтори с --yes только после того, как он согласился"
  exit 1
fi

[ -x "$ENV_CHECK" ] || { err "не нашёл env-check.sh, честно отказываю"; exit 1; }
"$ENV_CHECK" VERCEL_TOKEN >/dev/null 2>&1 || {
  err "VERCEL_TOKEN не задан в .env — деплой невозможен, см. env.example"
  exit 1
}

if [[ -f "$INPUT" && "$INPUT" == *.html ]]; then
  DEPLOY_DIR=$(mktemp -d)
  cp "$INPUT" "$DEPLOY_DIR/index.html"
  PARENT_DIR=$(dirname "$INPUT")

  grep -oE '(src|href|url\()["'"'"']?[^"'"'"'>)]+' "$INPUT" 2>/dev/null | \
    sed "s/^src=//; s/^href=//; s/^url(//; s/[\"']//g" | \
    grep -v '^http' | grep -v '^data:' | grep -v '^#' | grep -v '^/' | \
    sort -u | while read -r ref; do
      SOURCE_FILE="$PARENT_DIR/$ref"
      if [[ -e "$SOURCE_FILE" ]]; then
        TARGET_DIR="$DEPLOY_DIR/$(dirname "$ref")"
        mkdir -p "$TARGET_DIR"
        cp -r "$SOURCE_FILE" "$TARGET_DIR/"
      fi
    done

  if [[ -d "$PARENT_DIR/assets" ]]; then
    cp -r "$PARENT_DIR/assets" "$DEPLOY_DIR/assets" 2>/dev/null || true
  fi

  CLEANUP_TEMP=true
  info "single HTML file detected — preparing for deployment..."
elif [[ -d "$INPUT" ]]; then
  if [[ ! -f "$INPUT/index.html" ]]; then
    err "folder '$INPUT' does not contain an index.html file"
    exit 1
  fi
  DEPLOY_DIR="$INPUT"
  CLEANUP_TEMP=false
else
  err "'$INPUT' is not a valid HTML file or directory"
  exit 1
fi

echo ""
echo -e "${BOLD}Deploy slides to Vercel${NC}"
echo ""

if ! command -v npx &>/dev/null; then
  err "Node.js is required but not installed (brew install node, or https://nodejs.org)"
  [[ "$CLEANUP_TEMP" == "true" ]] && rm -rf "$DEPLOY_DIR"
  exit 1
fi

info "checking Vercel CLI..."
if command -v vercel &>/dev/null; then
  VERCEL_CMD="vercel"
  ok "Vercel CLI found"
elif [ "$ALLOW_NPX" -eq 1 ] && npx --yes vercel --version &>/dev/null 2>&1; then
  VERCEL_CMD="npx --yes vercel"
  ok "Vercel CLI available via npx (fetched with --allow-npx consent)"
else
  err "Vercel CLI is not installed."
  if [ "$ALLOW_NPX" -ne 1 ]; then
    err "This script will not silently download and run it from the npm registry via npx either — that also needs consent."
  fi
  err "Ask the user to approve one of these, then re-run:"
  err "  npm install -g vercel"
  err "  bash scripts/deploy.sh ... --yes --allow-npx   # let this script fetch it via npx, on demand, once approved"
  [[ "$CLEANUP_TEMP" == "true" ]] && rm -rf "$DEPLOY_DIR"
  exit 1
fi

DECK_NAME=$(basename "$DEPLOY_DIR")
if [[ "$CLEANUP_TEMP" == "true" ]]; then
  DECK_NAME=$(basename "$INPUT" .html)
fi
DECK_NAME=$(echo "$DECK_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-100)

if [[ "$CLEANUP_TEMP" == "true" ]]; then
  RENAMED_DIR="$(dirname "$DEPLOY_DIR")/$DECK_NAME"
  if [ -e "$RENAMED_DIR" ]; then
    # A path at this exact name could be a stale leftover of our own from an
    # interrupted run, or it could be something completely unrelated that
    # just happens to share the sanitized deck name — never rm -rf without
    # proof it's ours. Only our own runs leave this marker.
    if [ -f "$RENAMED_DIR/.frontend-slides-deploy-tmp" ]; then
      rm -rf "$RENAMED_DIR"
    else
      err "'$RENAMED_DIR' already exists and wasn't created by this script — refusing to overwrite it."
      err "Move or remove it yourself, or rename the deck, then re-run."
      rm -rf "$DEPLOY_DIR"
      exit 1
    fi
  fi
  touch "$DEPLOY_DIR/.frontend-slides-deploy-tmp"
  mv "$DEPLOY_DIR" "$RENAMED_DIR"
  # The marker must not end up served as part of the deployed site.
  rm -f "$RENAMED_DIR/.frontend-slides-deploy-tmp"
  DEPLOY_DIR="$RENAMED_DIR"
fi

# Vercel names the project after the deployed directory, so redeploying the
# same deck intentionally reuses the same project/URL (see SKILL.md). That
# is also the one case where this command can overwrite something already
# live — surface it instead of deploying silently.
if EXISTING=$($VERCEL_CMD ls "$DECK_NAME" --yes 2>/dev/null) && [ -n "$EXISTING" ]; then
  warn "project '$DECK_NAME' already has deployments — this will redeploy over it, not create a new one."
fi

echo ""
info "deploying (non-interactive, via VERCEL_TOKEN)..."
# Passed through the environment, not --token, so it never shows up in argv/ps.
DEPLOY_OUTPUT=$(VERCEL_TOKEN="$VERCEL_TOKEN" $VERCEL_CMD deploy "$DEPLOY_DIR" --yes --prod 2>&1) || {
  err "deployment failed:"
  echo "$DEPLOY_OUTPUT"
  [[ "$CLEANUP_TEMP" == "true" ]] && rm -rf "$DEPLOY_DIR"
  exit 1
}

DEPLOY_URL=$(echo "$DEPLOY_OUTPUT" | grep -o 'https://[^ ]*' | tail -1)

echo ""
ok "slides deployed"
echo -e "  ${BOLD}URL:${NC} $DEPLOY_URL"
echo "  take it down later at https://vercel.com/dashboard (project '$DECK_NAME')"
echo ""

if [[ "$CLEANUP_TEMP" == "true" ]]; then
  rm -rf "$DEPLOY_DIR"
fi
