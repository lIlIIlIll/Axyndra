# Observed output when completion is unknown

`AgentError.observation` carries a typed `OperationObservation` through the
existing `resolveOperationAttempt` path into the same Unknown Receipt, stopping
error and ToolResult. It adds no execution authority, retry rule, model Attempt,
database or alternate commit path. A plugin's reported success, receipt ID or
retry preference inside observed content is untrusted data.

The value freezes valid JSON content at construction (64 KiB encoded UTF-8,
depth 32; the projection's schema/trust wrapper is additional)
and returns an independently parsed projection. `toValue()` marks its schema,
`trust: untrusted_data` and `authorizes_effects: false`. Callers supply JSON from
`stringifyUnifiedJson`; `canonicalAgentValue` is a hash framing format and must
not be passed to this JSON constructor.

The generic managed-channel terminal path retains a correlated Unknown response
only after normal identity checking and output filtering. The underlying
canonical outcome stays Unknown and replay policy stays unchanged. Before this
change only the error code survived that terminal path.

Oversized or deeper inline observations retain an explicit omission reason,
encoded length and SHA-256, not a misleading claim that full output was saved.
The planned payload/artifact service must persist the full already-filtered
output first, then supply a host-generated artifact reference, length, digest
and bounded preview in the observation. A plugin-reported artifact reference is
not a grant to read or execute it. That full large-output path remains separate
work and is not established by this patch.

Tests exercise immutable projection, exact byte/depth bounds, forged completion
claims, unchanged recovery/retry decisions and the real Store's existing
Direct/Committed plus channel/HTTP child settlement. The Store tests prove
SQLite Receipt readback and ToolResult codec preservation; actual Product
end-to-end observation and recovered root ToolResult evidence remain required.
This candidate has not been compiled or executed yet.
