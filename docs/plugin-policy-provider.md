# Pure policy providers

The existing SDK `Provider` contribution kind now names a native, pure data
provider. Its ready declaration belongs in `providers`, with exactly `name`,
`description` and `protocol: axyndra.policy-provider/v1`. The package manifest
declares `{ "kind": "provider", "name": "..." }`. No Tool is required.

Invocation kind `provider` carries a Thread and a unique query nonce, with empty
Run/Operation/command and epoch zero. It uses the same native isolation, bounded
logical content codec, generation registry, cancellation and payload owner
accounting as context/resource queries. Host service quota is exactly zero.
Progress, service calls and an unsupported ready protocol are rejected.

Product sends `{ "schema": "axyndra.policy-query/v1", "input": ... }` and accepts
only `{ "schema": "axyndra.policy-result/v1", "value": ... }`. The consumer
retains the response charge until it releases the result. Selection pins the
actual package digest and current generation before and after the query.

A proposal is untrusted data. Each consumer must validate it against the facts
it was authorized to supply, its own finite limits and unchanged configuration.
Only existing Host ports can invoke a model, access/delete data, authorize a
child Run or commit state. A provider cannot choose a trust level, manufacture
a Receipt, install a grant or acquire those permissions from its output.

This contribution is the common data boundary for the pending Memory,
Compaction and workflow policy implementations. It does not claim their
algorithms or legacy tool paths have already migrated. Five native protocol
cases are authored, including actual provider-only processes; Cangjie tests and
the actual policy consumer/plugin integration remain unrun in this candidate.
