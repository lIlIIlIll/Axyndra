# Native process plugin contract

Native executable packages use bounded IPC, the process launcher, lifecycle
controls, and host-held service brokers. The wire identifier remains
`axyndra-js-host-v2`; its historical name does not require Node for a native
executable. The implementation is
[javascript_host.cj](../agent_extension_runtime/src/javascript_host.cj), with the
product sandbox in
[javascript_plugin_host.cj](../agent_host_runtime/src/javascript_plugin_host.cj).

Native capability packages, including the MCP client, use this contract.
[Issue #45's migration](plugin-first-migration.md) records the scope and remaining
acceptance requirements.

Native Tools that request `network.http` additionally use
[prepared HTTP intents](plugin-http-services.md). Their endpoint remains
network-denied; only the exact operator-bound, canonically authorized child
request can enter the host gateway.

## Package and contribution identity

An `axyndra.plugin.json` package declares its executable and contributions:

```json
{
  "id": "native-hello",
  "version": "1.0.0",
  "entry_kind": "native-executable",
  "entrypoint": "bin/plugin",
  "sdk_range": "[2.0.0,3.0.0)",
  "protocol_range": "axyndra-js-host-v2",
  "capabilities": [],
  "contributions": [{"kind": "command", "name": "hello"}]
}
```

The package namespace is `axyndra:native-hello`. Its contribution identity is
`axyndra:native-hello/command/hello`; the command route is
`plugin.axyndra:native-hello.hello`. Runtime instances have separate monotonically
increasing mount generations. A frozen executor cannot target a reinstalled
instance, even when the package name and bytes are unchanged. Process state is
separated by thread and invocation authority scope. A process restart does not
prove recovery or authorize replay of an unfinished operation.

`entrypoint` must identify an executable regular file inside the package without
symlinks or path traversal. The parser requires a canonical semantic package
version and a bounded SDK interval that contains the current SDK. Supported native
contribution kinds are `tool`, `command`, `view`, `service`, `model_provider`,
`provider`, `context_provider`, and `resource_provider`. Tool names use the host's
tool-name grammar; other names use its command-name grammar. Duplicate `(kind, name)`
entries are rejected. `skill`, `event`, and unknown kinds fail with
`plugin.contribution_unsupported`. A command-only plugin declares no tool.

Legacy manifests without `entry_kind` remain inspectable as `legacy-process`, but
activation returns `plugin.entry_kind_migration_required`. There is no fallback
from native protocol initialization to the legacy one-shot invocation path.

## Install and enable the executable example

The repository includes a separately compiled, command-only C fixture in
[support_tests/native_plugin_fixture](../support_tests/native_plugin_fixture).
On the supported Linux sandbox platform, run from the checkout root:

```sh
bash support_tests/native_plugin_fixture/build.sh "$PWD/work/native-hello/bin/plugin"
cat > work/native-hello/axyndra.plugin.json <<'JSON'
{
  "id": "native-hello",
  "version": "1.0.0",
  "entry_kind": "native-executable",
  "entrypoint": "bin/plugin",
  "sdk_range": "[2.0.0,3.0.0)",
  "protocol_range": "axyndra-js-host-v2",
  "capabilities": [],
  "contributions": [{"kind": "command", "name": "hello"}]
}
JSON
```

In an Axyndra interactive session, replace the example absolute path with the
directory just created:

```text
/plugins inspect /absolute/path/to/work/native-hello
/plugins inspect /absolute/path/to/work/native-hello --json
/plugins import /absolute/path/to/work/native-hello --scope workspace
/plugins enable axyndra:native-hello --scope workspace
/plugin.axyndra:native-hello.hello
/plugins disable axyndra:native-hello --scope workspace
```

Import materializes and content-locks a managed snapshot, initially disabled.
Enable checks the executable handshake before publishing command routes or tools.
Inspection never launches the executable. JSON inspection includes `entry_kind`,
`contributions`, SDK/protocol ranges, requested capabilities, and whether a
signature was declared; it does not return signature bytes. The fixture returns a
successful command result; it does not emit a UI notification.

## Trust and capability policy

Native processes use the product's existing mandatory sandbox: the package is
read-only, ambient network is denied, environment is filtered, and process/resource
limits apply. Missing isolation fails closed. Native launch directly selects the
packaged binary; it does not invoke a shell or Node.

With no configured signature verifier, an unsigned package may be explicitly
enabled through this isolated path, like the existing Pi adapter. A package that
declares a signature requires a configured trust root and otherwise fails with
`plugin.signature_trust_root_missing`. When a verifier is configured, every native
activation must satisfy its signed-manifest check; unsigned packages fail that
check. A signature does not grant capabilities or permit an unsandboxed fallback.

Workspace requests are `workspace.read` and `workspace.write`. Native executable
Tools may also request `network.http`, subject to the separate prepared-intent and
operator-configuration boundary above. Requests are evaluated through host
policy and the ToolPipeline. The executable's
hello message contains an empty ambient capability grant. A tool may request
supported broker services within its canonical parent operation; the service
broker rechecks identity, cancellation, capabilities, budgets, and operation state.
The host pipeline creates an immutable `PreparedInvocationSource` for each plan:
`Direct` records host preparation without a model Decision, `Committed` retains
the canonical Decision attestation, and `Derived` binds a child to that attested
root, its parent operation, request key, run, session, and epoch. Approval preserves
this source. Program and plugin bridges admit derived plans through the existing
Operation runtime before execution; payload fields cannot select their origin.

A Direct tool invocation through `ProductVnextControl.executeCanonicalTool` commits
its own ToolCall Item with the exact Run and Operation provenance. The current
Thread owner then mints a sealed `DirectToolCallRef`; `ToolPipeline.bindDirectRoot`
binds it to the prepared invocation. It is not a ModelDecision or a
CommittedToolCallRef. Merely calling `ToolPipeline.prepare` does not provide this
root authority. Recovery may inspect these Items but cannot remint Direct process
authority from a recovered Run.

Direct plugin roots can request read-only broker children. The existing operation
store checks the live Run and epoch, canonical Item and provenance, parent plan,
executing state, and executor handoff before admission. The child retains the
original root Item and its own Operation and Receipt. Root and child share one
ExecutionBudget: a synchronous child owns its waiting parent's slot and consumes
one additional tool call. Cancellation or an exhausted budget prevents new child
admission. Program roots still require a committed model ToolCall. A successful parent
response does not hide a failed child: the Direct Run completes only when every
Operation has a completed Receipt. Known child failures settle the Run as failed;
unknown or unsettled effects retain recovery-required state and are not replayed.
The caller still receives the plugin's structured result to inspect `is_error`.
An actual invocation cancellation follows the Run cancellation state machine.

Internal `host.process.readonly` and `host.file.plan.propose` are excluded from model
definitions and run tool snapshots. Only a source-bound plugin child can resolve
them; direct, model-committed, trusted-control, Program, and recovered guessed-name
calls cannot. This source closure does
not complete issue #45 A1-03's waiting, task, and unknown-result recovery requirements.
Command invocations have no parent tool operation and cannot use the `exec`
service; their service adapter supports `ui.notify`, `ui.select`, and `ui.confirm`
subject to an available interactive host. Direct process network/filesystem access
is not granted by a manifest declaration.

## Read-only package processes

A tool can send `service: "process.readonly"` with these arguments:

```json
{"executable":"worker","arguments":["query","symbol"],"timeout_ms":30000}
```

`executable` must name a regular executable inside the installed package. It is a
relative path with no `.` or `..` segments and no symbolic links. `arguments`
contains at most 128 strings, no NUL bytes, and at most 64 KiB in total.
`timeout_ms` is an integer from 1 to 60,000; its default is 30,000. The working
directory is the host's workspace root, fixed by the host.

The frozen root executor supplies package identity; the wire payload cannot
choose a namespace, generation, or package digest. Before launching, the host
checks the active generation and the parent plan's implementation fingerprint
against that package digest. The worker runs with read-only workspace access,
denied network, and explicit environment values. It receives neither ambient
host environment variables nor an SDK mount; package authors must bundle worker
dependencies. Plugin disablement cancels the instance's active worker.

This service uses the same source-bound child Operation, parent budget, slot and
Receipt path as other supported broker calls. It does not grant `ProcessSpawn`,
workspace write, or trusted-control authority. Combined stdout/stderr is bounded
to 128 KiB and the serialized service output to 192 KiB. Exceeding the output
ceiling returns an error with truncation evidence instead of a successful partial
result. Command invocations and unbound/background requests cannot use this port.

## File change proposals

A tool can send `service: "file.plan.propose"` to validate and store a proposed
change without modifying workspace files. Its arguments contain only `proposal`:

```json
{
  "proposal": {
    "schema": "axyndra.file-change-proposal/v1",
    "operations": [{
      "kind": "replace",
      "path": "src/example.cj",
      "expected_content": "let oldName = 1\n",
      "content": "let newName = 1\n"
    }]
  }
}
```

The proposal contains only `schema` and `operations`; a `source` claim is rejected.
There must be 1 to 32 operations, and the encoded proposal must fit within 64 KiB.
The existing file-plan validator accepts `create` and `replace`. Paths must be
canonical workspace-relative paths without symlinks or sensitive targets; a
replacement must match the current whole-file `expected_content`. Conflicting
targets and malformed or oversized content are rejected.

The host supplies the frozen package namespace, instance generation and package
digest. The executor validates the parent Operation and current instance again,
then records the proposal's actual plugin source. These fields cannot be supplied
by the plugin. The service uses a read-only, denied-network child Operation with
WorkspaceRead authority, the same parent budget and slot, and its own Receipt.
It may store immutable host artifacts but grants no workspace-write authority.

The result includes the host's `plan_ref` and `plan_digest`. Applying that plan is
a separate `apply_file_plan` operation with its own capability, approval and
current-file checks. A plugin cannot approve or apply its own proposal through
this service. For example, a plugin that first runs a read-only worker and then
submits a proposal consumes three tool calls in total: the root and two sequential
children. They still share one active slot. Commands, Program children and
unbound/background requests cannot use this port.

Application and recovery also verify durable origin evidence. A plugin plan must
match its completed proposal Receipt and successful canonical root result; a
continuation must match the committed recovery result. Recomputing an artifact
digest does not establish that origin. The older Program plan format remains
readable, but application and recovery require its real Program or recovery
Operation and the exact plan reference in that result. Unverifiable historical
plans are retained for inspection and rejected for application; changing a
plugin plan to the older schema does not bypass the evidence check.

Both application and recovery now use implementation identity v2, so an old
prepared approval cannot silently execute the new implementation. Original v1
Program plans with verifiable generation evidence can be prepared again. A
continuation produced by the older recovery-v1 implementation is rejected with
`application_plan.origin_uncommitted`, even when its historical Receipt and
ToolResult completed successfully: that implementation did not verify the
original generator. Its artifacts and historical results remain readable.
Accepted continuations must name the current recovery implementation fingerprint
and exactly match its committed result.

## Wire lifecycle

Each frame is one UTF-8 JSON object followed by a newline on stdin/stdout. Keep
logs on stderr. The default frame maximum is 262,144 bytes, the product process
output budget is four frames' size, and the default initialization/invocation
timeout is 30 seconds. Individual requests also observe host cancellation and
process resource limits; these defaults are ceilings, not promises of execution.

The host first sends `hello` with `protocol`, `extension_id`, `extension_version`,
`generation`, `capabilities`, and `max_frame_bytes`. Respond with `ready`, echoing
the protocol, identity, generation, and exact granted capabilities. Include
`tools`, `commands`, and `hooks`; a command-only response has `tools: []` and
`hooks: []`, for example:

```json
{
  "type": "ready",
  "protocol": "axyndra-js-host-v2",
  "extension_id": "native-hello",
  "extension_version": "1.0.0",
  "generation": 1,
  "capabilities": [],
  "tools": [],
  "commands": [{"name": "hello", "description": "Native greeting"}],
  "hooks": []
}
```

Use the actual generation and identity from `hello`. A tool descriptor instead
contains `name`, `description`, and an object-valued `input_schema`. The entire
registered tool/command set must exactly match the manifest; extra, missing, or
kind-swapped contributions fail with `extension.contributions_mismatch` and the
process is closed. Runtime registration after ready is unsupported.

An `invoke` frame includes `id`, `tool`, `kind`, `command_id`, `thread_id`,
`run_id`, `epoch`, `operation_id`, and `call_id` in addition to the package envelope,
plus object-valued `arguments`. Commands receive `arguments.command_args` as text.
A response must copy every host-owned correlation field and set `type: "result"`,
`ok: true` or `false`, and `result` to its result JSON. Never create a run, operation,
or command identity yourself. The C fixture demonstrates copying the envelope.

### Pure Tool preparation

The native runtime also accepts `type: "invoke", kind: "prepare"` for an already
registered Tool. ProtocolWorker and Pi profiles reject this kind. The host supplies
nonempty `thread_id`, `run_id`, and `call_id`, with `epoch > 0`; `operation_id` and
`command_id` must both be empty. Preparation does not create an Operation, grant
capabilities, or prove that a returned intent is authorized. Its result remains
untrusted input for host validation and subsequent canonical preparation.

Preparation accepts at most 16 KiB of argument JSON and one response frame of at
most 64 KiB, including its envelope and terminating newline. Smaller configured
frame limits still apply. Its timeout is at most five seconds, further limited by
the configured or requested timeout. The ordinary `result`, `cancel`, and
`cancelled` envelopes retain every preparation identity field. Any nonempty
response `operation_id`, mismatched identity, or oversized response closes the
endpoint. Cancellation and deadlines use the existing managed process cleanup.

The host forces `context.has_ui` to false when context is provided, does not call
an observer during preparation, and rejects every `progress` or `service_request`
frame by closing the endpoint. This protocol boundary does not replace the
product's mandatory process sandbox. Tool execution, command, and hook invocation
rules are unchanged. The native fixture and
[prepare contract](../support_tests/extension_runtime_contract/src/native_prepare.cj)
exercise this runtime surface; product intent validation is a separate step.

`progress` and `service_request` messages retain that same correlation envelope;
broker calls additionally use `request_id`, `service`, and object `arguments`.
There are at most 32 service calls per invocation. Service responses carry the
same request ID. Cancellation is signaled by `cancel`; acknowledge with `cancelled`
using the same envelope. Malformed, mismatched, oversized, unsolicited cancellation,
late, or timed-out traffic closes the protocol endpoint instead of being accepted
as an unrelated invocation. Process disposal terminates the managed process tree.

Contract evidence lives in
[runtime tests](../agent_extension_runtime/src/native_plugin_test.cj) and
[product tests](../agent_product/src/native_plugin_test.cj), covering command-only
activation, declaration mismatch, disablement, frozen instance binding, and scope
separation. The fixture is a test example; its small JSON scanner is not a general
SDK parser for production plugin authors.


## Explicit logical service payloads

A pinned Native Service may use the operator `payload_limits` profile together with an explicit
`protocol_limits` profile. This changes only that endpoint's `service_prepare` and `service` transport.
Ordinary Tool preparation and Pi endpoints retain their existing limits. Declaration is not an
execution, network, workspace or credential grant.

The exact version-1 profile contains `version`, `max_message_bytes`, `max_input_bytes`,
`max_prepare_bytes`, `max_result_bytes`, and `max_write_bytes`. Its hard ceilings are respectively
16 MiB, 4 MiB, 8 MiB, 8 MiB and 4 MiB; the physical frame maximum remains 4 MiB. Each input,
preparation or result limit leaves 256 KiB inside the message limit. The preparation result must
also fit twice the raw-write limit plus 64 KiB, because pure preparation returns hexadecimal bytes.
The actual complete Operation plan and canonical result must separately fit the Store's 8 MiB
codec. JSON size alone cannot prove that bound.

For a message exceeding the physical frame, the sender uses `payload_begin`, `payload_chunk`,
and `payload_end`, carrying the same complete Native v2 invocation identity. Each frame's
`payload` object contains `schema: "axyndra.logical-json/v1"`, the host-minted invocation `window`,
and `transfer_sequence: 1`. This sequence is transport order, not a model Attempt. A begin also
contains `message_type`, exact UTF-8 byte length and lowercase SHA-256. Each chunk supplies the
next exact `offset` and at most 16 KiB encoded as lowercase `bytes_hex`. End has no extra fields.
The decoded message must repeat the same identity and `payload_window`; a transfer cannot change
the original invocation deadline. Duplicate, overlapping, late or foreign chunks close the endpoint.

Both ordinary and logical profile messages reserve bounded memory before expanded JSON parsing.
The host's shared 128 MiB pool has at most 32 reservations, with two per endpoint; every reservation
charges at least 16 MiB and eight times the selected byte bound. A lexical 65,536-node guard and
JSON depth 32 apply before decoding. Plugin caches and active assembly have their own bounded
aggregate accounting. Cancellation, malformed frames and consumer completion release ownership;
the internal Product result consumer must call `releasePayload()` in `finally`.

Large channel preparations still return bytes, never host artifact references. The host persists
those exact bytes using its existing content-addressed artifact store and substitutes a
`process-channel-intent-v2` intent. The reference binds encoding, raw length and digest, encoded
content digest, and the existing blob reference. An exact audit witness binds it to the actual
Thread, Run, epoch, canonical call, effective input and service binding. Store rechecks that witness
inside the same transactions as prepare, child admission, execution, handoff and settlement. The
actual writer re-reads and hashes the content after handoff and revalidates the live child before
writing. Final GC reference scan and deletion serialize with history pinning in the same SQLite
transaction; a reference created by an endpoint cannot grant access to an artifact.

A complete large result that fits the actual durable codec remains a complete ToolResult. If a
post-effect result exceeds that codec, its complete filtered JSON can be retained as an existing
artifact, referenced by an `OperationObservation` in the same Unknown Receipt. That observation
is explicitly untrusted data, authorizes no effect and permits no automatic retry. Cleanup failure
must preserve an already retained observation. HTTP request-body artifacts and all legacy size or
long-running timeout behavior are not implied by this stdio payload profile.
