# Compaction policy plugin

This native provider owns semantic-summary prompt construction and overview
selection/truncation. It receives already-authorized structured facts or the
Host's typed model reply as data. It cannot call a model or modify a checkpoint.

The Host must choose a configured model, apply its existing unique internal
Attempt/retry/usage/cancellation path, and validate every proposal before
committing a checkpoint at the original legal cut. Canonical history remains
in the existing Store. This source candidate is still awaiting the Host
consumer, actual package gate and Product tests; it is not a completed migration.


Version 1.1 offers `event_batch: true` in `reference_layout` and requires a Host
that accepts that layout field. Updated Hosts still accept the previous exact
two-field layout and use the original request sequence for such Providers.
`reference_event` reuses the original Plan, TextFragment and Fold algorithms;
only inline sources at most 2048 bytes are reduced without another Host read.
Empty recipes run the original Merge locally. Recipes requiring Host intern
identities still return to the Host, and hashline/large fragments retain their
original observation and coverage boundaries. No EOF or truncation rule changes.
Every actual pure invocation retains full package verification before and after
the request; the original maintenance timeout, fragment/profile/aggregate bounds
and final consumer revocation checks are unchanged.

The independent preparation gate selects the mixed connection's exact
`provider-invoke-i63-v1` sequence profile. Its separate three-case sequence
suite retains 4097 negotiated queries, the unnegotiated 4096-query limit,
stale/duplicate/overflow checks and rejection of the pure-only
`invoke-i63-v1` offer. The shared runner defaults to the pure-only profile;
pass `--sequence-profile provider-invoke-i63-v1` for this package.

The companion authors four pure cases, three packaged protocol cases and one
actual installed Product case, all unrun until the sole builder validates the
combined graph. Pure and native oracles compare original whole-history and
unbatched reference output bytes, including 2048-byte boundaries, UTF-8, late
markers, long whitespace and hashline paths. Call-count assertions describe
protocol structure, not measured latency or a performance pass.
