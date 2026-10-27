# Installed semantic compaction policy

The independent native `plugins/compaction` package owns the semantic summary
prompt and interpretation of the model reply. It contributes the pure
`summarize` provider, with no capabilities or Tools. Its runtime library shares
the bounded native logical-content codec and payload ownership with other pure
providers. It cannot dispatch a model or create a checkpoint.

Install and enable the built package through the ordinary plugin registry.
Select the exact installed package in `<settings>/plugins/policies.json`:

```json
{
  "version": 1,
  "bindings": {
    "compaction": {
      "namespace": "axyndra:compaction",
      "provider": "summarize",
      "package_digest": "sha256:<actual installed content_digest>"
    }
  }
}
```

This is operator configuration, not an execution grant. The file has a 64 KiB
actual-read limit and an exact schema; every binding is validated. Product pins
the complete file digest and the installed generation across both policy calls
and the internal model call. Missing, disabled, changed, or malformed selected
policies fail explicitly when hybrid compaction is requested. Startup and
history inspection do not require the policy. Existing operator files are not
silently rewritten or repaired.

The `prepare` policy input contains the already selected canonical fact summary,
operator-selected model, and output limit. The proposal may supply bounded
system/user text and the supported low-thinking setting. Product validates the
model against the operator selection and disables Tools. It then calls the
existing canonical internal-model port with purpose `ContextCompaction`.
Each real request keeps its own durable Attempt, shared retry/request budget,
observed usage and maintenance Run. This is not a conversation ModelDecision.

The `finalize` policy sees the observed provider-neutral reply and proposes
optional overview text. Product validates its bounds and unchanged binding.
The checkpoint records the package/configuration provenance and marks the
overview non-authoritative. Its legal cut, original canonical items, call/result
completeness, source digest, and input-token limit remain Host checks. Policy
output cannot rewrite the cut or replace canonical history.

The summary phase is bounded by `summary_timeout_ms` (also accepted as
`summaryTimeoutMs`), an operator setting in the range 1..60000 whose default is
15000. The deadline covers the whole canonical save phase — reference reduction
plus the summary model call — not one policy query. Raising it is operator
configuration; it does not relax any verification, freshness, package-byte or
ownership check. At the default a save whose phase does not finish in time
fails with `run.deadline_exceeded` rather than publishing a partial checkpoint.

Ordinary model failure retains the existing `fallback_structured` behavior;
explicit cancellation, exhausted authority/budget, and unresolved resource
cleanup do not become a successful checkpoint. One cancellation source spans
preparation, the model and finalization. Its token is linked to the actual
maintenance Run, preventing a cancel-before-provider-registration race. No
approval-review parent is cancelled by this maintenance-only token API.

`summary_strategy: structured` still uses the existing Host deterministic fact
projection. The configurable deterministic summary/routing algorithms still
need a later extraction; this increment does not complete issue #45 A5-02 by
itself. Memory and workflow policies share the same selection schema and native
pure-provider library, rather than a second registry or database.

Run `python3 scripts/prepare_compaction_plugin.py` to build a fresh package,
verify its runtime/license closure and execute all 16 real protocol cases with
SDK loader variables removed. Ten Product cases cover real installation,
canonical compaction, failed models, missing/revoked/changed selection, preserved
history and actual maintenance cancellation. The Product contract and TUI
compaction contract now install the real package through their normal public
entry points. These are authored requirements; their execution results belong
in gate evidence and are not inferred from source inspection.
