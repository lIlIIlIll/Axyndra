# Native plugin compatibility

The supported author-source packages `agent_sdk` and `axyndra_agent_testkit`
are version **3.0.0**. This is an explicit breaking migration from the cooperative
business SDK: Extension/ExtensionTool, workspace-search/write intent dispatch,
HostOperationIntent, compiled providers and the Installer/runtime adapter are
not production author APIs. Full historical v2 oracles remain test-only in
`support_tests/legacy_*`; they are not a compatibility shim or default fallback.

The actual Native wire SDK constant remains **AGENT_SDK_VERSION = 2.1.0**.
Source-package release versions do not rewrite existing Native hello/ready or
manifest compatibility. The protocol remains `axyndra-js-host-v2`. Native
packages use the real `axyndra.plugin.json` fields: id, version, entry_kind
native-executable, package-relative entrypoint, sdk_range, protocol_range,
capabilities and the complete contribution array. There is no invented nested
entry object or legacy compiled manifest schema in the current author contract.

Native ranges retain their original bounded `[minimum,maximum)` policy.
Versions are canonical MAJOR.MINOR.PATCH signed-64-bit decimal components;
leading zeroes, whitespace, signs, missing/extra components and range algebra
remain rejected. Compatibility is exactly minimum <= host < maximum.
Malformed or incompatible declarations fail before activation; there is no
best-effort replay, ambient fallback, or automatic upgrade.

Contribution names/kinds, complete ready declarations, current package bytes,
Registry generation, operator configuration and requested Host capabilities
are checked on the existing actual Host path. A manifest or handler definition
does not grant Source, approval, policy, sandbox/I/O access, receipts, audit,
Run persistence or trusted execution. Approval of one frozen effect cannot
authorize another. Signatures and isolated-package validation remain on their
original Native paths, with no new executor authority in the public SDK.

The current source baselines are `compat/agent-sdk-native-v3.api.json` and
`compat/axyndra-agent-testkit-native-v3.api.json`. Original v2 baselines remain
unchanged historical evidence. The offline checker verifies the actual v3
package version and native-authoring-v3 contract, rejects stable removal,
signature change, enum-case changes or demotion without an explicit major
release, and keeps all existing negative diff-policy self-tests.

```text
python3 scripts/check_sdk_compatibility.py
python3 scripts/check_sdk_compatibility.py --self-test
python3 scripts/update_sdk_api_baseline.py agent_sdk --reviewed-breaking-release
python3 scripts/update_sdk_api_baseline.py axyndra_agent_testkit --reviewed-breaking-release
```

The updater is an explicit reviewed release operation; ordinary gates never
rewrite a baseline. The real independent v3 consumers use Native data handlers
and complete results. The previous cooperative consumer/assertion bodies are
also retained in runnable historical Support packages rather than removed.

Cancellation is idempotent and a deadline expires at nowMillis >= expiresAtMillis.
Denial, cancellation, deadline and Host failure remain distinct. Public handler
unit tests demonstrate data-contract behavior, not actual InstalledRoot policy,
physical close acknowledgement, cross-platform execution, or global capacity.

## Pi and Codex portable capability requests

Pi declares portable requests in `pi.axyndra.capabilities` in `package.json`.
Codex declares the same request-only subset in `extensions.axyndra.capabilities`
in `plugin.json`; this is an Axyndra extension, not an OpenAI permission grant.
Both accept an array of at most 16 strings containing only `workspace.read` and
`workspace.write`. Whitespace is trimmed and duplicate requests collapse.
A string instead of an array, nontext elements, empty/NUL-bearing values,
unknown capabilities, and unknown fields in the Codex Axyndra overlay are
refused during package inspection, before registry publication.

Keep Codex hook declarations in their vendor overlay and requests separate:

```json
{
  "name": "local-hooks",
  "version": "1.0.0",
  "extensions": {
    "com.openai": { "hooks": "./hooks/hooks.json" },
    "axyndra": { "capabilities": ["workspace.write"] }
  }
}
```

Static import executes no hook and starts disabled. Neither a hook declaration,
these requests, nor enabling a package authorizes execution: the current
invocation and its frozen normalized plan must still pass the actual policy and
capability checks. PreToolUse modification requires the existing workspace-write
boundary; PostToolUse observation requires the existing workspace-read or
workspace-write boundary. Hook package files remain read-only in isolated
execution. The supported Codex command-hook subset remains PreToolUse/PostToolUse,
exact-name or `*` matching, and finite command timeouts; it does not imply
arbitrary Codex JavaScript, vendor apps, hosted execution, or MCP activation.

## Migrate a host tool descriptor resolver

Rebuild custom host descriptors and their callers together. The primary and additional capability, network policy, side-effect and approval metadata resolvers now take `agent_domain.ToolResolverInput` instead of `ToolCall`. Their return types are unchanged. This is a host source and binary interface change, not a change to the Native plugin wire SDK, manifest or stored plans.

Read the input during the actual callback. Use `ToolResolverText.Name` and `CallId` to compare identities, or select an argument with a path of `ToolResolverStep.Field`, `Index` or `MemberAt`. An empty path selects the arguments root. Check `kind` for optional fields; `count` requires an array or object. For example, a descriptor that previously compared `call.arguments.field("mode")` to a string can use:

```cangjie
sideEffectResolver: Some({ input =>
    let path = [ToolResolverStep.Field("mode")]
    !input.hasKind(path, JsonKind.String) ||
        !input.textEquals(ToolResolverText.Scalar(path), "read")
})
```

`Scalar` preserves text and the original number spelling. `Key(path, index)` selects an object's member name. To retain text, use `copyText` or `readBytes` into a caller-owned buffer; `byteCount` and `readBytes` use byte offsets, not character indices. A saved input is invalid as soon as that callback returns or throws. Do not pass it into a worker. Returning from a resolver drops only its scoped reference: it neither authorizes execution nor acknowledges unrelated Prepared or result data. Roll back an incompatible host and its descriptor libraries together; no database migration is required.

The pure Host helpers for Context Read, Read View, readonly delegation and the HTTP root also take the new input in `agent_domain`: replace the `host` prefix with `resolver` (for example, `hostContextReadCapabilities` becomes `resolverContextReadCapabilities`). For non-descriptor code that already owns a real `ToolCall`, use `withToolResolverInput(call, resolverContextReadCapabilities)`. Registration and invocation remain distinct; a missing invocation is not permission to synthesize a call or a grant.

## Migrate a derived Operation store

The host-side `OperationRuntimePort.settleDerivedOperation` takes a fourth
argument, `binding: DerivedReceiptBinding`. Rebuild custom Store adapters and
callers together; the three-argument entry is gone. This change does not alter
the Native plugin wire protocol or require a database migration.

Pass the binding from the **same prepared child**. Select `true` when the
Receipt must publish `request_digest`, and leave that field out of the input:

```cangjie
child.withReceiptBinding(true, { binding =>
    store.settleDerivedOperation(runId, parentId, receipt, binding)
})
```

Inside the existing settlement transaction, load the admitted child's stored
plan, validate the original Run, parent, handoff and reserved Receipt, and call
`binding.checkedReceipt(receipt, storedPlan.bindingDigest)`. Reject `None`
without writing. Persist the returned Receipt, not the input. Its digest comes
from the Store; the handle exports neither the caller's digest nor its plan.
A mismatched child or digest is rejected. With `false`, verification that had
no digest stays that way. Matching a digest does not authorize settlement.

Do not retain the handle to finish settlement later. Once `withReceiptBinding`
returns or throws, even a saved handle can no longer match. Existing Receipts
are not rewritten and earlier raw Prepared exports are not retroactively
released. The wider Prepared call/plan API migration remains open.

## Verify a child operation without borrowing its plan

Rebuild custom `OperationRuntimePort` implementations. The last argument to
`verifyPluginChildExecution111` and `pluginChildStartReceipt111` is now a
`PluginChildPlanMatch`, not a `NormalizedOperationPlan`. The Host calls each
method inside `withStoredPluginChildPlan(frozenPlan, { proof => … })`.

Compare the receiver’s own durable plan inside the same transaction as the
Source, parent, Run, thread, epoch, handoff and Receipt checks. Use
`proof.matchesStored(encodedRow)` for the Store’s original bytes, or
`storedPluginChildPlanMatches(storedPlan, proof)` from `agent_store` for a
typed record. Neither a match nor `proof.hasCandidate()` authorizes a child.
A saved proof no longer matches after the call returns or throws; do not
queue it for a later execution. Unsupported ports still deny both operations.
Stored rows and the SQLite schema do not change.

## Read a prepared call without exporting its arguments

Host executors can use `prepared.withCallInput` for the display call. Use
`prepared.withCanonicalCallInput` for execution: it supplies the call ID and
name from the original call, but the arguments from the frozen operation plan.
For example, `prepared.withCanonicalCallInput({ input => input.stringField("path") })`
copies a text field. Neither view grants permission to execute. A saved view
rejects reads after the callback returns or throws.

For a counted metadata consumer, replace `reader.withCall204` with
`reader.withCallInput` for display arguments or `reader.withCanonicalCallInput`
for the frozen arguments. For Task selection, `resolverChildStartOrWaitGeneration`
reads the matching namespace and contribution; `resolverSelectsChildWait`
compares the start ID and complete binding. To name a derived child call, use
`resolverChildServiceIds(input, requestId)` inside `withCallInput`. It returns
only the child call ID and its idempotency key; neither string retains the parent
call or its arguments. These reads do not grant permission to launch or reuse a Receipt. Use `textEquals` for comparisons and
`copyText` only when the recipient needs its own string. The raw-call callback on the reader
no longer compiles; recompile host extensions against the updated Tool API.
Returning a scoped view does **not** return the reader. Call
`reader.returnConsumerFrame204()` only when that reader's real consumers have
finished, including a published result's payload acknowledgement if it still
owns the reader. One reader cannot acknowledge another. Earlier raw exports
remain charged; the rest of the Prepared call/plan migration is still open.
Neither the plugin wire protocol nor the database format changes.

When a Host only needs to classify a plugin plan, use a closed predicate, for
example `prepared.matchesFrozenPlan(FrozenPluginPlanRule.ReadViewChild)`.
`ReadViewChildOf(parent)` also checks that the frozen child matches the parent
intent. Both return a Boolean, not a plan or its arguments. A reader retained
before the producer returns can make the same comparisons until its own return.
A match does not replace Source, approval or current capability checks.

## Migrate a Host scheduler's derived-frame callback

The third parameter of `ToolInvocationContext.setDerivedToolFrameHandler` is
now a `DerivedToolFrameName`, not a `String`. Rebuild custom Host schedulers.
Use `name.matches("plugin.workspace.read")` for an exact match, or
`name.startsWith("plugin.")` for a prefix. A scheduler using
`NestedToolSlotFrames` can pass `name` directly to `frames.enter(parent, child, name)`;
on exit, call `frames.leave(child)`. The handle reads the actual display name
and expires when that particular callback returns or throws. Enter and leave
receive separate handles. Keep a classification if needed, not the handle.

This changes the Host source API, not Native plugin messages or stored plans.
Frame checks schedule an already-admitted child; they do not authorize it or
acknowledge its result. Roll back a custom scheduler and Host library together.

## Persisted state and inspection

The current SQLite format is **schema v29**. It is independent of the Native
wire SDK version and author-source package versions above. Migration v28 moves
nonempty legacy Todo/Goal bytes into namespaced `plugin_documents` in the same
transaction as the schema version change; unsupported historical payloads
remain data, not executable plugin configuration or authorization. The old
metadata columns are a read-only archive, not a second write owner.

Plugin lock rows use schema v1; known unversioned rows remain readable without
rewriting them merely for inspection. Public enable/disable, update, rollback
and uninstall resolve the existing Registry's fatal load error before choosing
a record or changing an active instance. Unknown schema versions, fields or
typed facts return `plugin.lock_format_unsupported` and preserve the original
lock bytes; they are not reported as an unimported plugin or silently normalized.
The existing writer fence still reloads and checks current state before every
publication. This preflight is metadata validation, not a grant or execution pin.

Schema migrations are forward-only. Stop other writers and back up the database
and every referenced artifact blob before upgrading. Rolling back an executable
or a plugin does not downgrade the database; restore the matching complete
pre-upgrade database-and-blob backup for an older executable. The incremental
migration and recovery boundaries are documented in [architecture](architecture.md).
These format rules do not establish completion of the current migration's
runtime acceptance; see [the draft status](issue-45-draft-status.md).

`/inspect [run-id] [before-operation-cursor]` reads the canonical Run inspection
projection without calling a model. Omitting `run-id` selects the current
Thread's latest Run; `before-operation-cursor` paginates its Operations. Missing
plugin versions or unavailable executors do not make historical records
executable: inspection preserves evidence, while continuation must report its
actual recovery requirement. CLI, RPC and TUI consume the same host projection
rather than reconstructing execution authority in a frontend.
