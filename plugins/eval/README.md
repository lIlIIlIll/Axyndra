# Persistent eval plugin — uncompiled migration candidate

This package owns the Python, Bun JavaScript, Ruby and Julia cell runners,
language selection, cell schema, reset behavior, request bytes and result
presentation. Its native endpoint has no interpreter inside it. An explicit
operator lifecycle grant launches one selected interpreter with its packaged
runner, inside the existing host process sandbox. Interpreter state is private
to that process and service instance; it is not the plugin host or PTC worker.
Installing or inspecting the package does not start any interpreter.

The native Service configuration is exactly:

```json
{"version":1,"language":"py","max_timeout_ms":30000}
```

The corresponding approved backend argv uses an absolute interpreter and the
fixed installed runner path: Python `-u runners/python.py`, Bun
`runners/javascript.mjs`, Ruby `runners/ruby.rb`, or Julia
`--startup-file=no --history-file=no runners/julia.jl`. Each service selects one
language. The host reads the real startup `READY|language|1` before publishing
its directory. Interpreter paths, environment, workspace mounts, network denial
and process budgets remain explicit host policy. A missing interpreter fails
only that service activation. There is no ambient executable search in this
package or eval-specific host dispatcher.

The `eval` tool retains `language`, `code`, optional `title`, `timeout` and
`reset`. Pure preparation validates and freezes the exact hexadecimal request
bytes. Execution consumes that identity once and asks the existing broker to
write only `eval-call` from the approved host plan. The real child Receipt is
required; code, target and reset cannot change between preparation and execution.
Cancellation revokes the channel and suppresses late results. Broken frames,
missing acknowledgements, deadline failures and oversized responses after a
write retain Unknown; the endpoint cannot retry cells or claim process cleanup.

`runners/extraction.json` records the source commit and exact original and
packaged runner hashes. Python, Bun and Ruby add only a language readiness line.
The Julia runner also fixes a demonstrated baseline defect: Julia 1.11.5 rejects
`redirect_stdout(IOBuffer)`. It uses nested temporary IOStreams with automatic
close/removal, preserving separate stdout/stderr and partial output on errors.
The original hash and this explicit behavior correction remain in provenance.
`check_runners.py` exercises real interpreter subprocesses separately from native
protocol and Product authorization tests. Unavailable optional interpreters are
reported as skipped, never counted as validated language support.

The initial actual four-language runner baseline executed 24 cases: 20 passed
and all four Julia cases failed with the unsupported IOBuffer redirection. After
the correction, the actual runner suite passed **27/27, with no skips**, using
Python 3, Bun 1.4.2, Ruby 3.4.10 and Julia 1.11.5. The three added Julia regressions
cover Unicode stdout/stderr separation, partial error output plus subsequent
reuse, and temporary-file cleanup after success and error. This proves the
runner processes only; native packaging and Product authority remain untested
for this candidate.

`scripts/prepare_eval_plugin.py --output NEW_DIRECTORY` builds a fresh package,
checks its manifest, runtime closure, licenses and runner hashes, removes SDK
loader environment variables, and requires all 20 native protocol cases to run
without skips. Those cases launch the packaged Python runner itself through a
fixture broker. They prove state/reset, pure preparation, exact prepared bytes,
replay refusal, known Python cell errors and timeouts, cancellation and unknown
outcomes. They do not replace the five Product/SQLite authorization tests in
`agent_product/src/plugin_eval_service_test.cj`; set
`AXYNDRA_EVAL_PLUGIN_PACKAGE` to the validated package for those tests. The package
is not a host workspace member and no default product includes its business code.

Every arbitrary-code call remains a mutation. Do not grant `read_only_tools` to
`eval`: even an expression that looks like a read can execute arbitrary Python,
JavaScript, Ruby or Julia code. An operator can allow automatic approval under a
chosen host policy, but the plugin does not invent readonly authority.

## Remaining migration work

The source retirement removes Product's static Eval schema, executor, raw
LocalProcessPort Eval API and persistent kernel cache. The installed native
package owns this business protocol. A frontend must explicitly configure and
start its actual Host service, then select the published
`plugin.axyndra:eval.service.stdio.eval` in the target Thread. Installation alone
does not authorize or publish a runnable tool. Startup and every cell use the
existing canonical Root/Source, approval, current configuration, finite channel
budget and durable Receipt. Disabling or losing a service withdraws its tool.

The source support migration preserves complete observed cell assertions,
Python timeout recovery, per-Thread state, workspace/profile isolation and
same-Product fork history. Accepted cancellation and output overflow retain
the real Unknown Receipt and cleanup owner; no closed cell, artifact, approval
or replay is fabricated. A lost service requires explicit fresh startup.
Current preparation has not proved these migrations by compiler or runtime.
Original native protocol20, current interpreter27, the five native Product
authorization cases, new publication case and all migrated support gates remain
required. Source removal and packaging are not whole A3/A7 acceptance.

The native profile accepts 16 KiB input, a 30 KiB request frame, 64 KiB final
result and at most 120 seconds configured timeout subject to stricter Host
bounds. The old `timeout=0` seven-day window and 3600-second calls are explicitly
unsupported and rejected before a cell effect is prepared. They are not silently
shortened. Large output artifacts and old preview/artifact result behavior still
need the generic artifact service; oversized output remains Unknown. Multiple
language services in a single Thread and equal long-duration capacity remain
unverified support boundaries.

The actual supported duration is also bounded by the operator's native Service
profile, startup/call window, backend lifetime, CPU budget and cumulative broker
poll quota. Configuring 120 seconds here alone does not grant a 120-second host
invocation. No long-duration capacity equivalence has been measured.

The Bun runner exits after a timed-out cell. Since the current generic protocol
has no completed-and-retire result with an actual cleanup acknowledgement, that
case returns Unknown and cannot reuse the service. Its bounded observed cell
stdout/stderr remain in the native wire result. The existing generic host
Unknown mapping does not yet persist that partial result; retaining it durably
requires the generic observation/artifact work. This is an explicit compatibility
gap, not a claim that the already observed cell output was never produced.
Ordinary Python cell errors and observed Python timeouts remain known complete
failures and leave the interpreter reusable.

Actual native/Product tests must cover mutation approval, no code write before
approval, reset/state isolation, language drift, cancellation of escaped process
descendants, missing interpreters, readonly/network boundaries, completed cell
failure versus unknown transport outcome, and restart without blind replay.
The retained language code runs with the approved interpreter's full process
authority; its in-language state isolation is not an OS security boundary.
A completed cell response is not proof that cell-created background threads or
descendants have finished. They remain owned by the approved backend lifetime
lease; stopping or cancelling that service must reclaim the whole namespace.
The migration does not silently redefine the old language background semantics.
