# Service transport and content budgets

## Frozen process shutdown

An operator process service may set `lifecycle_policy` to
`{"schema":"axyndra.process-shutdown/v1","grace_ms":3000}`. The duration is an
exact nonnegative Int64, independent of request/startup timeouts. Omission
normalizes to immediate cleanup (zero); no plugin setting grants a grace.
The policy is part of the immutable launch digest and the normalized managed
channel binding. A prepared close may request a smaller `grace_ms`, never a
larger one. Changed configuration, executable, descriptor, source or current
capability/resource ceilings do not adapt an already approved plan.

Normal idle operator stop withdraws the catalog and invocation authority
immediately, closes process stdin, and privately drains within that frozen
interval. It then force-aborts the retained process group if necessary and
uses the original cleanup owner for actual wait/reap, reader/monitor Future
returns, callbacks and resource reservations. EOF, an exit observation or a
request-to-close are not release acknowledgements. Cancellation, revocation,
an active invocation stop and lifetime expiry keep immediate forced cleanup;
shutdown introduces no additional tool, network or caller read authority.
The existing bounded stop reply may report cleanup pending; it does not
extend its deadline or release custody. Public acknowledgement waits for the
same canonical operation settlement and actual cleanup Future/callback return.

Managed-owned startup links the original caller cancellation token and deadline
to service revocation before native directory I/O begins. The same scoped link
remains armed through publication, then is disposed before startup custody is
finished. A cancelled caller cannot acquire catalog authority while startup is
blocked; cleanup still waits for actual endpoint and backend acknowledgement.

An operator's lifecycle `max_output_bytes` and `resources.max_output_bytes`
are equal, finite raw stdout-plus-stderr byte budgets for the entire service
lifetime. They include protocol framing and escaping. The maximum is 128 MiB;
the actual Run budget can reduce it. Startup and refresh windows retain their
16 MiB ceilings, as do service input and normal raw process-channel output.

Product explicitly sets its lifecycle channel transport ceiling to 128 MiB.
Only the private launcher, reached after the real canonical lifecycle handoff,
uses that ceiling. An embedder can set `LocalProcessPort`'s
`lifecycleChannelOutputBytes` independently; when omitted it inherits the
ordinary sandbox output limit, capped at 16 MiB. An insufficient actual host
ceiling rejects the grant before launch. Copying a ProcessRequest or its owner
does not enable the private allowance. All other sandbox resource intersections,
the bounded channel queue, cancellation, lease and close acknowledgement remain.

For Shell `--stream-output`, grant 128 MiB transport output to support one full
16 MiB captured result even when JSON escaping expands NUL bytes sixfold. The
content/artifact maximum remains 16 MiB, with bounded previews and full digests.
Increasing transport output does not grant a larger artifact or tool result.
The backend probe measured 17,055,101 raw bytes for 16 MiB ASCII and 100,957,559
for 16 MiB NUL (including protocol frames). These are backend observations,
not proof that the complete host path meets capacity or performance targets.

The budget is cumulative across calls. Exhaustion closes the service with a
bounded error; it does not silently reset counters, restart the backend, or
replay effects. Starting a new lifecycle requires the normal operator approval
and ownership path; mutable shell state is not transparently reconstructed.

New Product tests exercise the exact content boundary through the installed
package, canonical child Receipt and retained blob. They are authored but not
executed at this source checkpoint. Full capacity, cancellation under sustained
backpressure, and resource release must pass against the integrated binary.
