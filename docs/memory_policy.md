# Installed Memory policy migration

Memory records, event history, scopes, lifecycle statuses, correction links and
SQLite transactions remain in the original repository. Ranking, embedding-fact
fusion, automatic context rendering and correction field defaults execute in
the independently installed Memory Provider. There is no second memory DB or
Host ranking fallback.

The exact operator selection is `plugins/policies.json`, shared with other pure
policies. `memory` binds the installed namespace, provider and package digest.
The complete configuration and actual instance generation are rechecked across
retrieval/render/correction phases. A selected policy failure is a typed error.
No selection means automatic recall is absent; explicit CRUD still works, while
explicit recall/reflect and correction proposals require a policy. The Coding
distribution supplies normal Memory and Compaction defaults without overwriting
an existing operator file or re-enabling a disabled plugin.

Use `ProductRuntime.prepareRequest` when constructing a request: it returns
`Result<AgentRunRequest>` and does not return an executable request if an
explicitly selected Memory policy is unavailable. The compatible `request`
method preserves its original parameters and return type but throws
`ProductRequestPreparationError` with the original `AgentError`. Application,
CLI/TUI/RPC entry paths and Task consumers use the Result method. This policy
does not impose Memory on independently constructed generic `AgentRunRequest`s.

SDK applications using their own `MemoryV3Repository` can supply an explicit
`MemoryRetrievalPolicy`, or obtain the normal installed policy from
`ProductRuntime.memoryPolicy`. Repository visibility filters and immutable
ID/revision validation still run independently. The repository has no default
ranking implementation. A correction prepared outside the repository supplies
`expectedRevision`; SQLite rechecks the complete original record in the same
transaction that appends the corrected state and replacement.

The existing trusted `MemoryEmbeddingPort` remains the only embedding I/O seam.
Its results become data for the pure provider. Absence reports `lexical` with no
fallback; actual adapter failure or invalid vector reports `lexical_fallback`.
The package cannot select a model, network endpoint or credential. Non-JSON
NaN/Infinity are invalid embedding facts rather than authority or valid scores.

The external candidate is not a completed capacity migration. The legacy
repository accepts a much larger accumulated history than a single pure-content
query. Until immutable paged facts are implemented, exceeding that finite query
bound is an explicit error before a mutation, with no hidden truncation or
fallback. Independent protocol and actual Product tests must pass before old
production algorithm deletion is integrated. Native package existence alone is
not a full A5 completion claim.
