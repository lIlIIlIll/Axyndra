# Installed Compaction policy: large histories

Compaction sends immutable history pages to the selected installed policy. Large individual values travel as bounded fragments over query-local data references; the policy still applies the old deterministic summary and overview algorithms. A reference carries data only: it cannot read a file, create an artifact, authorize an effect, or choose a different provider.

The host keeps its canonical history, legal-cut and source-digest checks. Every fragment uses one fixed phase deadline and the same caller cancellation/configuration/provider generation. Monotonic request IDs require explicit pure-provider negotiation; older connections keep the original one-shot limit. Transport errors do not trigger automatic replay.

The resulting complete checkpoint must fit the existing 8 MiB stored-value codec, including all checkpoint fields. A too-large projection fails explicitly before optional model dispatch where possible; a too-large final checkpoint leaves the previous checkpoint unchanged. The shared 128 MiB native allocation reservation remains enforced. This supports bounded large values, not unlimited host memory or unlimited deadlines.

For embedders, `ProductRuntime.proposeContextSummary` returns an owned `ProductCompactionStructure`. Keep it open through the final consumer, validate its current binding before committing any proposal, and always call `close()` in a finally block. Closing is idempotent and subsequent validation fails. Host checkpoint, rewind and compacted-message paths manage those leases internally.

Validation status for this candidate: authored pure, packaged native, Product/SQLite and ownership cases have not yet been compiled or executed. Static review is not a runtime compatibility result.
