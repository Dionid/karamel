# Root cause tracing

Where an error *surfaces* is rarely where it *originates*. A bad value is
usually created several frames — or several services — above the line that
finally chokes on it. Fixing at the surface leaves the source intact to poison
the next caller.

**Trace backwards to the original trigger, then fix there.**

## The process

1. **Observe the symptom precisely.** Not "withdrawal fails" — the exact error,
   the exact value: `expected fee > 0, got NaN in buildPsbt()`.
2. **Find the immediate cause.** Which line produced the bad value, and from
   what inputs?
3. **Ask what called it,** and with what arguments. Walk the stack up frame by
   frame, writing the chain down as you go.
4. **Keep going until the value is *created*, not merely passed on.** An empty
   string, a `undefined` defaulted to `0`, a string amount where satoshis were
   expected, a missing env var read as `""`.
5. **Cross the process boundary too.** The chain does not stop at the edge of
   the repo: a wrong number in `api` may have arrived from the app, from
   `shared-lib`'s serialisation, from a migration that left a nullable
   column, or from an indexer that wrote the row. Follow it into the next
   component — `db-query` shows what the database really holds, GitHub UI
   shows what the job really received.
6. **Fix at the origin.** Then decide, separately, whether the intermediate
   layers should also have rejected the bad value.

## Defence in depth, after the fix

Once the origin is fixed, ask whether the value should have been caught earlier:

- **validate at the boundary** — reject the malformed input where it enters the
  service, with an error that names the field;
- **make the illegal state unrepresentable** where the type system can — a
  branded `Satoshi`, a non-null column, a discriminated union instead of
  optional fields;
- **assert the invariant** at the point that depends on it, so the next
  violation fails loudly and near its cause.

Add these *in addition to* the root fix, never *instead of* it. A validation
that turns a wrong answer into a clean 400 is an improvement; it is not the fix.

## Dead ends

If tracing genuinely stops — the value comes from an external service, a
third-party callback, chain data — then the boundary **is** the origin as far as
you are concerned. Validate there, log the offending payload, and say in your
report that the true source is outside the system.

## Flaky and order-dependent failures

A test that passes alone and fails in a suite is the same problem in a different
shape: the bad state is created by something *earlier*, not by the failing test.
Bisect the suite — run the failing test after progressively smaller halves of
the ones before it — until you find the polluter. Shared fixtures, an unclosed
connection, a module-level cache and a row left in the database are the usual
culprits. Do not "fix" it with a retry, a longer timeout or a `sleep`; replace
arbitrary waits with polling on the actual condition.
