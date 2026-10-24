#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for test in "$script_dir"/*.test.sh; do
  printf 'TEST=%s\n' "${test##*/}"
  bash "$test"
done
