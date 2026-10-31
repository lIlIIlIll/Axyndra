# Installed structured compaction policy

The existing structured-summary algorithm runs in the independently installed
Compaction provider. Product supplies the neutral history projection plus current
goal/todo data. It validates the response witness and the selected package and
configuration before consumption. The original algorithm and its formatting,
limits and file/tool classification are copied into the package.

Product still selects and validates legal history cuts, tool call/result pairing,
input budgets, current source digest, canonical checkpoint CAS, projector/lane
compatibility and cacheEpoch. The original Items remain unchanged. Both structured
and hybrid strategies require the selected installed policy. Structured strategy
makes no model call. Missing or disabled policy returns an explicit error.

Checkpoint rewind obtains the same installed policy after its canonical ToolResult
exists. Its caller retains the canonical source snapshot and final checkpoint
commit. Standalone Host composition can supply the same Product policy callback;
there is no default Host algorithm behind the callback.

Validation authored: 20 native protocol cases (16 existing plus four structured
golden/invalid/large-input cases); 12 Product cases (10 prior plus two structured
cases, one old no-provider expectation intentionally replaced); existing real
support contracts now install the normal package and use the same callback.
No Cangjie compilation or native execution has been performed for this candidate.

Not ready to apply: the complete neutral history projection can exceed the current
pure-policy transport capacity. This candidate fails explicitly, does not truncate
history and does not fall back to a Host algorithm, but this remains a compatibility
gap requiring an independent bounded transport/streaming delta. Full caller
cancellation ownership across structured proposal, optional overview and checkpoint
commit also needs an explicit review; each provider phase currently owns its token,
and final proposal validation checks its observed token and current binding.
