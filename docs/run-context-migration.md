# Generic Run context snapshot migration

The trusted Core, Runtime, Store and Embed APIs accept `InvocationContextProjection`
and the versioned `axyndra.run-context/v1` codec. They no longer import or link
`agent_skills`. Coding selects an independently installed ContextProvider. Metadata
and body preparation use canonical reads inside the admitted Run; request
construction does not read Skills resources. The remaining A5 acceptance matrix
and actual migrated contract runs are tracked separately.

Every contribution has a provider identity, local id, source locator, immutable
content and a limited trust label. Loaded references have exact content digests;
unloaded references remain locators. Neither label nor digest grants execution
authority. The model receives a host-owned generic data envelope; markup in
provider content is escaped. Existing host policy and user instructions still
take precedence. This intentionally changes the old Skills-specific prompt
envelope while preserving task guidance and lazy references.

The same Run launch and continuation slots carry these bytes. Existing SQL
`runs.skill_snapshot` and continuation wire `skill_stack` names remain historical
storage labels, with no second table, registry, dual write, revision or authority.
The API names become `contextSnapshot`, `contextSnapshotPayload` and
`runContextSnapshot`. Embed's builder now uses `contextSnapshot(...)`.

Bounds are 4 MiB encoded UTF-8, 1024 contributions and 4096 references in total.
Unknown schema, fields, trust levels, duplicate identities or content digest
mismatches are rejected. This format does not import old Skill business DTOs.
Nonempty legacy or unsupported stored context is retained byte for byte and
basic Run/history inspection remains available. Resume reports
`context.snapshot_unsupported_or_invalid` before starting work. Empty missing
launch context reports `run.launch_snapshot_missing`. There is no destructive
automatic migration or promised downgrade. Existing backups remain the recovery
source for runs requiring an older implementation.

The new contract sources cover generic codec/trust/bounds and actual SQLite
close/reopen, unique Run ownership, preserved frozen bytes, and repeated refused
resume without new model/operation facts. They are authored but NOT RUN until
the validation record identifies a compiled source graph. Core, Runtime, Store,
Embed, Product prompt and ThreadRuntime contracts must all be rebuilt. Ordinary
Skills discovery/reference tests remain in the provider layer.


## Active Run context updates

An installed ContextProvider can be queried by the trusted Product API
`queuePluginContextUpdate`. The host fixes the provider namespace, package and
enabled generation, checks the target Thread/Run/epoch and expected context
digest, and replaces only contributions owned by that provider. Its query is
pure and gives neither the provider nor its result any capability authority.
Ordinary host code can also queue an immutable `InvocationContextProjection`
on the existing `AgentThreadRuntime`. Plugin IPC cannot call that API.

The returned ticket distinguishes `Queued`, `Applied` and `Discarded`.
`Queued` is a bounded, volatile request on the actual Run, not a durable promise
or an effective context version. Cancellation, provider revocation before the
cut, a stale epoch, transaction failure, or Run completion before a cut prevents
publication. An applied snapshot remains historical data after provider disable;
unresolved lazy resource references still require the exact current provider.
The caller may inspect the ticket diagnostic or withdraw a queued update.

Core consumes a pending update at its existing model boundary after the prior
canonical Tool round and before compiling the next model effect. It uses the
same `ModelLaneChanged` transaction and ContextVersion history. SQLite checks
active ownership, full expected projection, no pending Attempt/Decision,
Operation/Approval or Tool round, and preserves all background work debt. The
transaction replaces `runs.skill_snapshot`, the prompt composition digest and
the request projection in the sealed continuation together. Audit points to
the retained old continuation revision/digest and records both context digests;
it does not duplicate two large snapshots in an unbounded audit value.

The next ModelContextManifest checks its context digest against the actual
stored Run snapshot in the same transaction that publishes ContextReady.
Core builds both the next model system and its ToolInvocationContext from that
version. Old Prepared invocations retain their prior immutable projection;
budget, cancellation, event sequence, task ownership and the single Tool slot
remain owned by the same Run. The existing 4 MiB snapshot and durable codec
bounds still apply; no read or execution budget is created by updating data.

Restart uses only the committed version. Volatile pending selections are never
reconstructed as Applied, and unsupported historical continuation shapes fail
closed. The existing repository deliberately exposes no replayable continuation
between a settled context cut and the next actual model checkpoint; this change
does not add automatic crash recovery across that gap. This change does not yet
remove the legacy Skills discovery path or
implement automatic user/workspace Skill reads. Those require the same-Run
verified resource-read continuation; the installed package query currently
consumes its immutable package resources. It does not privately read host paths.
