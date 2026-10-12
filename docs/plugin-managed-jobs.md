# Managed service jobs

This increment connects native services to the existing Task runtime. It is
staged and uncompiled; authored tests are not execution evidence. It does not
remove the built-in Bash path or complete A4-02.

## Declaration and approval

A Service contribution explicitly declares `supports_preparation_reference`
in both its manifest and native ready frame. The default is false, mismatches
are rejected, and other contribution kinds cannot opt in. This declaration is
protocol support, not permission.

For a process-channel service, powerless `service_prepare` may return
`managed_job: {"timeout_ms": N}` alongside its exact byte intents. The host
creates the job/child Thread/Run identities and freezes a deadline and tool
budget into `host_plan.managed_job`. The deadline is bounded by the explicit
service profile, parent Run and cancellation deadline. Repeated preparation
of the same Thread/Run/epoch/call retains the same immutable declaration;
changed input or intent bytes are rejected.

The complete frozen parent plan preserves its original effects, service
identity and exact intents. It additionally requires `Delegate` for
`managed-job`. Ordinary policy and approval still apply. Disabling async,
lacking delegation, stale publication or the wrong Thread denies launch.
This implementation supports process-channel services. HTTP services retain
their existing Thread-local invocation path.

## Canonical execution and ownership

After real parent handoff, the Task runtime reserves the original cumulative
child budget and persists a managed job in its existing journal. The returned
`axyndra.managed-job-started/v1` result means queued delegation. The worker
waits for the exact completed parent Receipt and matching canonical ToolResult
before atomically claiming the Runtime-sealed reservation once. Descriptive
IDs, restored journal data or `preparation_ref` cannot mint this seal.

The claimed job starts a real Task-source Thread/Run with its canonical
SystemNote, ToolCall, Operation and Receipt. It executes the original full
normalized plan, without another model decision or approval and without
replacing byte intents. Shared Direct execution machinery retains actual
ledger, handoff, nested tool slot and owned-task behavior. A stale executor
after source admission is settled from the Prepared stage when the original
source remains valid; revoked sources remain fail-closed.

The host-only `preparation_ref` contains the original `thread_id`, `run_id`,
`epoch` and `call_id`. It locates the endpoint's immutable preparation; the wire
identity remains the actual child. The pinned endpoint and resource lease also
verify the live Task source, original publication/binding digest, permission
domain, target Thread and cancellation token. A reference alone never grants
access to a different service or resource.

The same Task runtime owns the worker Future, live cancellation handle,
cumulative budget lease, job journal and completion notification. Normal
parent completion does not cancel the child. Parent cancellation while active
and explicit job cancellation propagate to the real child. A cancellation
request is not recorded as a completed command before canonical settlement.

## Unknown outcomes, cleanup and restart

Physical cleanup acknowledgement and known command outcome are separate. A
terminal Run (including Cancelled) is insufficient for refund: every child
Operation must have a known terminal Receipt and no unsettled state. Unknown
effects retain the existing child budget after cleanup succeeds. Failed cleanup
retains the actual resource handle for the existing close/retry path. No
Unknown result is automatically retried.

One job reserves its persistent service instance. Other preparation, calls and
refresh cannot reuse the interpreter until that job's invocation has closed
and, for a revoked service, endpoint and backend cleanup are acknowledged.
Other Thread-scoped instances remain independent. Parent-token subscriptions
are detached only after cleanup; a launch that never issued an admission has
a separate one-way, unclaimed cleanup path.

The existing Task journal recognizes `jobType: managed`, with its actual child
Run and Operation identity. On restart unfinished entries become recovery
records; they do not recreate reservations, plugin preparations or executable
authority. Canonical facts remain in the existing Runtime/Store.

## Validation still required

The candidate authors six actual Product/SQLite cases: Direct completion across
the parent's terminal state, Committed rejection and exact approved delegation,
capability/Thread/async denial, post-write cancellation with Unknown budget
retention, disable/restart without replay, and same-call cross-Thread isolation.
Three native host cases validate declaration and real worker handshake.
Fourteen packaged Shell wire cases include zero-I/O preparation, exact byte
reuse, full reference binding, replay refusal and missing-write-Receipt Unknown.

None of those Cangjie/native candidate cases has run at seal time. Run them
with the source-foundation Store/Tool contracts, existing Task and synchronous
Shell tests, then the combined product checks before marking migration done.
Input capacity, complete legacy output/artifact parity, defaults/distribution
and deletion of the old Shell assembly remain separate work.
