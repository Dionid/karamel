#!/usr/bin/env bash
# q.sh must refuse on its own what the prose could only ask for: writes on prod,
# unconfirmed writes on dev, an unbounded prod SELECT, and a --db value that
# isn't a safe environment-variable component. --print never touches .env, so
# this runs without credentials.
set -euo pipefail

SKILL="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
Q="$SKILL/q.sh"
WS="$(mktemp -d)"
trap 'rm -rf "$WS"' EXIT
: > "$WS/harness.json"
cd "$WS"

run() { set +e; out=$("$Q" "$@" 2>&1); rc=$?; set -e; }

run --db payments --env prod --sql 'DELETE FROM orders' --print
[[ $rc -eq 4 ]] || { echo "prod DELETE must exit 4, got $rc: $out" >&2; exit 1; }

run --db payments --env prod --sql 'WITH d AS (DELETE FROM x RETURNING *) SELECT count(*) FROM d' --print
[[ $rc -eq 4 ]] || { echo "prod WITH+DML must be refused, got $rc: $out" >&2; exit 1; }

run --db payments --env prod --sql 'SELECT * FROM orders' --print
[[ $rc -eq 4 ]] || { echo "unbounded prod SELECT must be refused, got $rc: $out" >&2; exit 1; }

run --db payments --env prod --sql 'SELECT * FROM orders' --no-limit --print
[[ $rc -eq 0 ]] || { echo "--no-limit must lift the bound: $out" >&2; exit 1; }

run --db payments --env prod --sql 'SELECT count(*) FROM orders' --print
[[ $rc -eq 0 ]] || { echo "aggregate is bounded: $out" >&2; exit 1; }

# An aggregate in the second statement does not bound the first.
run --db payments --env prod --sql 'SELECT * FROM a; SELECT count(*) FROM b' --print
[[ $rc -eq 4 ]] || { echo "each statement must be bounded on its own, got $rc: $out" >&2; exit 1; }

# A comment is not a statement: this must not read as a write.
run --db payments --env prod --sql 'SELECT 1 LIMIT 1 -- DELETE FROM x' --print
[[ $rc -eq 0 ]] || { echo "commented-out DML must not be classified as a write: $out" >&2; exit 1; }

# EXPLAIN ANALYZE actually executes the statement, unlike a plain EXPLAIN — so
# it must be classified by what it runs, not by the word EXPLAIN.
run --db payments --env prod --sql 'EXPLAIN ANALYZE DELETE FROM orders' --print
[[ $rc -eq 4 ]] || { echo "EXPLAIN ANALYZE of a DML statement must be refused on prod, got $rc: $out" >&2; exit 1; }

run --db payments --env prod --sql 'EXPLAIN (ANALYZE, BUFFERS) DELETE FROM orders' --print
[[ $rc -eq 4 ]] || { echo "EXPLAIN (ANALYZE, ...) of a DML statement must be refused on prod, got $rc: $out" >&2; exit 1; }

run --db payments --env dev --sql 'EXPLAIN ANALYZE UPDATE orders SET status = 1' --print
[[ $rc -eq 4 ]] || { echo "EXPLAIN ANALYZE of a dev write without --confirm must be refused, got $rc: $out" >&2; exit 1; }
run --db payments --env dev --sql 'EXPLAIN ANALYZE UPDATE orders SET status = 1' --confirm --print
[[ $rc -eq 0 ]] || { echo "--confirm must allow EXPLAIN ANALYZE of a dev write: $out" >&2; exit 1; }

# A plain EXPLAIN never executes the statement, so it stays read-only even over
# a DML statement. --no-limit isolates the write-classification guard from the
# separate (and, for a non-SELECT, coincidental) unbounded-prod-SELECT guard.
run --db payments --env prod --sql 'EXPLAIN DELETE FROM orders' --no-limit --print
[[ $rc -eq 0 ]] || { echo "a plain EXPLAIN must not be classified as a write: $out" >&2; exit 1; }

# EXPLAIN ANALYZE of an actual read stays read-only.
run --db payments --env prod --sql 'EXPLAIN ANALYZE SELECT 1' --print
[[ $rc -eq 0 ]] || { echo "EXPLAIN ANALYZE of a SELECT must stay read-only: $out" >&2; exit 1; }

run --db payments --env dev --sql 'UPDATE t SET a = 1' --print
[[ $rc -eq 4 ]] || { echo "dev write without --confirm must be refused, got $rc: $out" >&2; exit 1; }

run --db payments --env dev --sql 'UPDATE t SET a = 1' --confirm --print
[[ $rc -eq 0 ]] || { echo "--confirm must allow a dev write: $out" >&2; exit 1; }

# Prod always carries both guards; dev carries only the timeout.
run --db payments --env prod --sql 'SELECT 1' --print
grep -q 'default_transaction_read_only=on' <<<"$out" || { echo "prod must set read-only: $out" >&2; exit 1; }
grep -q 'statement_timeout=15s'            <<<"$out" || { echo "prod must set a timeout: $out" >&2; exit 1; }
run --db payments --env dev --sql 'SELECT 1' --print
grep -q 'default_transaction_read_only'    <<<"$out" && { echo "dev must stay writable: $out" >&2; exit 1; }

# The URI is named, never expanded.
run --db payments --env prod --sql 'SELECT 1' --print
grep -q 'DB_URI_PAYMENTS_PROD' <<<"$out" || { echo "must name the variable: $out" >&2; exit 1; }
grep -q 'postgresql://'        <<<"$out" && { echo "must never print a URI: $out" >&2; exit 1; }

# --db is not a free-form environment-variable name: only lowercase letters,
# digits and underscore, so it can only ever address DB_URI_<NAME>_<ENV>.
run --db 'payments;evil' --env dev --sql 'SELECT 1' --print
[[ $rc -eq 2 ]] || { echo "an unsafe --db value must be a usage error, got $rc: $out" >&2; exit 1; }

run --env dev --sql 'SELECT 1' --print
[[ $rc -eq 2 ]] || { echo "a missing --db must be a usage error, got $rc" >&2; exit 1; }

run --db payments --sql 'SELECT 1' --print
[[ $rc -eq 2 ]] || { echo "a missing --env must be a usage error, got $rc" >&2; exit 1; }

echo 'q.sh guards ok'
