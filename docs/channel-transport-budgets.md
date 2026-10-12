# Service transport and content budgets

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
