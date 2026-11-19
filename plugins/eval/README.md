# Persistent Eval plugin

This package owns the Python, Bun JavaScript, Ruby and Julia cell runners,
language selection, cell schema, reset behavior, request bytes and result
presentation. Its native endpoint has no interpreter inside it. An explicit
operator lifecycle grant launches one selected interpreter with its packaged
runner, inside the existing host process sandbox. Interpreter state is private
to that process and service instance; it is not the plugin host or PTC worker.
Installing or inspecting the package does not start any interpreter.

By default the native Service returns inline output:

```json
{"version":1,"language":"py","max_timeout_ms":30000}
```

To retain large output, set `"output_artifacts": true` in this Service configuration
and explicitly start the configured service. The option does not change the Host
output budget, grant a capability, or modify an existing service.

When stdout and stderr together exceed 4 KiB, the runner streams both. Each
stream over 1 KiB gets a preview and a reference to the complete content after
the Host confirms its byte count and SHA-256. Smaller streams remain inline.
If storage is unsafe, the Host can confirm the bytes without retaining them:
`artifact_error.errors` identifies the affected stream and no reference is returned.
If an acknowledgement is missing or inconsistent after the cell write, the
outcome is `unknown`. Do not replay the cell.

The corresponding approved backend argv uses an absolute interpreter and the
fixed installed runner path: Python `-u runners/python.py`, Bun with the inline
module import below, Ruby `runners/ruby.rb`, or Julia
`--startup-file=no --history-file=no runners/julia.jl`. Each service selects one
language. The host reads the real startup `READY|language|1` before publishing
its directory. Interpreter paths, environment, workspace mounts, network denial
and process budgets remain explicit host policy. A missing interpreter fails
only that service activation. There is no ambient executable search in this
package or eval-specific host dispatcher.

For Bun 1.4.4 with the tested 512 MiB address-space and eight-process profile,
configure the backend arguments as follows. Replace the example path with the
absolute path of the installed package's runner:

```json
["--eval", "await import((await import('node:url')).pathToFileURL('/opt/axyndra/plugins/eval/runners/javascript.mjs').href)"]
```

The selected Bun executable imports the same module and preserves
`import.meta.url`. `pathToFileURL` handles spaces, quotes, Unicode and `#` in the
installed path. The host executes the operator's frozen argv unchanged; it does
not rewrite existing grants. Reconfigure and explicitly start a new service to
adopt this argv. Existing instances are not restarted or replayed. No package
wire or stored-data migration is required. File-mode startup on this Bun build
can emit READY and then abort while stdin remains open under these limits.
`check_runners.py JavaScriptBoundedRunnerTests` covers idle persistence, reset,
async results, cell errors, and timeout retirement with the original limits.
Bun-specific behavior on another version still needs that version's tests.

The `eval` tool retains `language`, `code`, optional `title`, `timeout` and
`reset`. Pure preparation validates and freezes the exact hexadecimal request
bytes. Execution consumes that identity once and asks the existing broker to
write only `eval-call` from the approved host plan. The real child Receipt is
required; code, target and reset cannot change between preparation and execution.
Cancellation revokes the channel and suppresses late results. Broken frames,
missing acknowledgements, deadline failures and oversized responses after a
write retain Unknown; the endpoint cannot retry cells or claim process cleanup.

`runners/extraction.json` records the source commit and exact original and
packaged runner hashes. All four runners support bound output frames when enabled.
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
reuse, and temporary-file cleanup after success and error. Interpreter tests do
not verify Host approval or artifact persistence.

`scripts/prepare_eval_plugin.py --output NEW_DIRECTORY` builds a fresh package,
checks its manifest, runtime closure, licenses and runner hashes, removes SDK
loader environment variables, and requires all 21 native protocol cases to run
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
The aggregate release contract in `support_tests/artifact_contract` exercises
explicit approval and reads back both complete streams from the Product Store.
See the [acceptance ledger](../../docs/issue-45-draft-status.md) for remaining
Product and release gates.

The native profile accepts 16 KiB input, a 30 KiB request frame, 64 KiB final
result and at most 120 seconds configured timeout subject to stricter Host
bounds. The old `timeout=0` seven-day window and 3600-second calls are explicitly
unsupported and rejected before a cell effect is prepared. With inline output,
oversized responses remain `unknown`. Multiple language services in one Thread
and equivalent long-duration capacity remain unverified.

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
