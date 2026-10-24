#!/usr/bin/env bash
# Offline MR-description template gate used by commit-and-mr.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  describe.sh check --file <path>
  describe.sh strip --file <path>

check: the file contains every required section from template.md, in order,
with no placeholders or generated spec/task-link blocks.
strip: prints the file without its managed spec-link/task-link blocks — for a
description read back with `gh mr view`, before check. Offline.
EOF
}

cmd="${1-}"
case "$cmd" in
  check|strip) shift ;;
  -h|--help|"") usage; exit 0 ;;
  *) echo "error: only the offline 'check' and 'strip' commands are available" >&2; exit 2 ;;
esac

file=""
while (($#)); do
  case "$1" in
    --file) file="${2-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$file" ]] || { echo "error: check requires --file <path>" >&2; exit 2; }
[[ -f "$file" ]] || { echo "error: not found: $file" >&2; exit 2; }

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$script_dir"
while [[ "$root" != "/" && ! -f "$root/harness.json" && ! -f "$root/workspace.json" ]]; do
  root="$(dirname "$root")"
done
lib="$script_dir/../commit-and-mr/lib.sh"
[[ -f "$lib" ]] || { echo "error: commit-and-mr/lib.sh not found" >&2; exit 1; }
# shellcheck source=/dev/null
. "$lib"

if [[ "$cmd" == strip ]]; then
  out="$(mktemp)"
  trap 'rm -f "$out"' EXIT
  mr_description_strip_managed "$file" "$out" || exit 1
  cat "$out"
  exit 0
fi

if ! mr_description_check "$file"; then
  echo "error: incomplete MR description — template: $script_dir/template.md" >&2
  exit 1
fi

echo "DESCRIPTION_OK=true"
