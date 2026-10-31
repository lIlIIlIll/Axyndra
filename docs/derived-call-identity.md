# Derived call identity

ToolRuntime now sends the actual host-prepared child call to the same durable
Operation admission transaction. A transport request key is not a ToolCall ID.
The Store persists both independently, binds the direct parent/root, and returns
the actual child identity from `loadCall`. Replaying a request with another call
is rejected, as is changing normalized arguments or erasing identity through the
legacy admission entry. This does not alter authority, approval or Receipt rules.

SQLite schema 27 adds child identity and ancestry columns plus per-parent child
identity uniqueness. Existing rows retain their facts and their previous
historical call representation. Empty identity/depth zero identifies these old
rows explicitly; migration does not guess a call ID from a request key.

All newly identified admissions currently have depth one. The existing root-only
admission, exact ParentIntent, handoff and settlement checks remain in force.
This is a prerequisite for Program migration, **not** a claim that nested plugin
tools, the installed Program worker, or general bounded trees are complete.
Deeper execution must also preserve the scheduler slot, each live ancestor,
exact service intent and cancellation/settlement rules before it is enabled.

Verification authored: actual SQLite Direct and Committed source cases for
identity/replay/drift/legacy/no-handoff/rollback/depth denial, plus a schema26
upgrade preserving the original plan. From each of `support_tests/agent_store_contract`,
`support_tests/tool_runtime_contract` and `support_tests/agent_core_contract`,
run `../../scripts/pinned_cangjie cjpm run`.
No Cangjie execution result is claimed by this candidate.

Independent schema probe executed all four exact migration SQL statements on
SQLite: seven checks passed, including failure at the final statement rolling
back all earlier column additions and the version marker. This does not replace
the authored Cangjie Store/ToolRuntime/Core tests.
