# SDK, manifest, and extension compatibility

The minimum supported Cangjie compiler and cjpm version is `1.1.0`, matching the
language baseline declared by the workspace manifests. Ordinary local builds and
tests accept newer STS and nightly versions. The SDK, runtime, and stdx must still
come from a matching distribution.

Local reference verification and the PR workflow use Cangjie STS `1.1.3` with
cjpm `1.1.3`. The scheduled nightly workflow runs weekly, resolves the latest
complete official nightly, installs its matching stdx component, and uses LLVM 18
as a forward-compatibility canary. The protected release workflow alone enables
the exact STS `1.1.3` toolchain check and owns fixed-toolchain release evidence.
The PR gate has a 120-minute timeout and runs repository policy and architecture
checks, a clean Cangjie check, focused execution/permission/recovery contracts,
workspace unit integration, the product executable build, product regression
fixtures, and CI evidence writing/upload. Focused contracts run before the full
workspace layer to shorten targeted failure feedback without dropping commands.
A Linux x86_64 STS `1.1.3` timing sample measured
`python3 scripts/product_unit_gate.py` at 195.541 seconds and
`scripts/pinned_cangjie cjpm build -m agent_app -o agent_app` at 109.905 seconds.
Under the previous order those two layers added 305.446 seconds before a focused
execution failure could be reported; the current order removes that delay from
that failure path. The workflow command set is unchanged, so measured coverage
diff is zero. These single-host measurements document gate ordering, not a
performance guarantee.
The protected release gate is separate and manual; its real-provider smoke runs
through `scripts/release_gate.sh`.
`scripts/check_sdk.sh` owns the minimum compiler check and provides the explicit
`AXYNDRA_REQUIRE_EXACT_TOOLCHAIN=1` release mode. Package
`cjc-version = "1.1.0"` fields describe the same minimum language compatibility.
`scripts/pinned_cangjie` derives compiler, runtime, and dynamic stdx paths from
the validated SDK root and never consults a mutable `daily` symlink. Canonical
verification may set
`AXYNDRA_CANONICAL_TARGET_ROOT` to isolate cjpm artifacts by both workspace and
validated SDK/stdx/native-compiler identity. Switching any selected toolchain
therefore cannot reuse another compiler's canonical target tree.
Known-bad compiler builds should be rejected explicitly when a reproducible
compiler defect is identified; release channel names are not compatibility
proxies.

The minimum supported LLVM/Clang major is 15. The native `process4cj` shim also
probes the selected compiler against its C11/Linux source instead of assuming
that a version number is sufficient. LLVM 15 is the reference and release
baseline, not an exact compatibility requirement. `AXYNDRA_NATIVE_CC` and
`AXYNDRA_NATIVE_AR` select another toolchain; otherwise `clang` and `llvm-ar` are
discovered from `PATH`. The wrapper exports the selected compiler's runtime
directory as `AXYNDRA_CLANG_RUNTIME_PATH`, and contract manifests add it as an
explicit linker search path. Native artifact freshness includes the compiler
identity, so changing compilers cannot silently reuse an older shim. The nightly
gate exercises LLVM 18.

The SDK and stdx pairing requirements remain in force. The candidate network-library
migration has not been switched on; see [the stdx migration specification](stdx-migration.md).
This is the compatibility contract for compile-time cooperative extensions. It
separates version identity, source shape, observable semantics, and security
invariants. A matching range is necessary, but never overrides authorization.

## Independent versions

| Dimension | Owner | Baseline | Meaning |
|---|---|---:|---|
| Manifest schema | `agent_extension_runtime.EXTENSION_MANIFEST_SCHEMA_VERSION` | `1` | JSON syntax and field semantics |
| Agent SDK API | `agent_sdk.AGENT_SDK_VERSION` | `2.0.0` | extension author source and semantic contract |
| Extension | each manifest and `ExtensionMetadata` | extension-owned | release of one extension identity |

`axyndra_agent_testkit` is a companion source package with a checked public API
baseline (`1.0.0` in its snapshot), not a fourth runtime compatibility field.
The product version, Git tag, and package version do not determine SDK version.

Versions use canonical `MAJOR.MINOR.PATCH`. Each component is a non-negative
signed-64-bit decimal. Whitespace, signs, leading zeroes (except `0`), missing
or extra components, prerelease/build labels, wildcards, and range algebra are
rejected. Compatibility is exactly:

```text
minInclusive <= host AGENT_SDK_VERSION < maxExclusive
```

Empty or reversed ranges are malformed. The runtime never infers compatibility
from a shared major and never attempts best-effort activation.

| Extension range | Host | Result |
|---|---:|---|
| `[1.0.0, 2.0.0)` | `2.0.0` | reject (`SdkTooNew`) |
| `[2.0.0, 3.0.0)` | `2.0.0` | compatible |
| `[2.0.0, 3.0.0)` | `2.5.0` | compatible |
| `[2.0.0, 3.0.0)` | `3.0.0` | reject (`SdkTooNew`) |

## Stability and SDK releases

- **STABLE** is a compatibility promise. Removal, rename, signature/type/
  visibility/generic-constraint changes, new required constructor inputs, or
  demotion require a major SDK release. Public enum cases are source surface:
  Cangjie exhaustive matching means adding a payload variant can break old
  source and is treated as breaking for a stable enum.
- **EXPERIMENTAL** is documented and deterministic but may change or disappear
  in a minor release. Promotion to stable is additive only after contracts are
  frozen. Stable-to-experimental is breaking.
- **INTERNAL** carries no third-party promise and is forbidden to frozen
  external consumers.

Patch releases allow compatible fixes, documentation, internal refactors, and
security fixes. Minor releases allow stable additions, experimental promotion,
and compatible semantic extension. Stable source or semantic breaks require a
major release. Security hardening is the deliberate exception: patch/minor may
reject behavior that endangered host authority, but rejection and diagnostics
must be explicit and tested.

The SDK 2 reference surface lives in `compat/agent-sdk-v2.api.json`. The
companion testkit 2 surface lives in
`compat/axyndra-agent-testkit-v2.api.json`. `scripts/check_sdk_compatibility.py`
fails stable removal, signature change, or demotion while the major is
unchanged, and self-tests additive/breaking classification. Gates never rewrite
baselines. A reviewed breaking release updates them explicitly:

```text
python3 scripts/update_sdk_api_baseline.py agent_sdk --reviewed-breaking-release
python3 scripts/update_sdk_api_baseline.py axyndra_agent_testkit --reviewed-breaking-release
```

`support_tests/sdk_fixture_extension` and `support_tests/testkit_consumer` are
frozen stable source consumers. They compile against current packages and use
no experimental API; ordinary changes must not edit them to hide a break.

## Manifest schema version 1

Schema `1` is the only supported schema. Lower and higher versions are rejected;
the runtime does not guess migrations or future meaning. Unknown optional
top-level fields are tolerated, while malformed known fields fail. Adding an
optional ignorable field is compatible. Adding a required field, removing or
renaming a field, or changing a known field's type/semantics requires a schema
bump.

Manifest capabilities are declarations for visibility and consistency. They
never grant policy, approval, sandbox access, credentials, execution, receipt,
audit, or persistence authority.

| Schema | Parser supports | Result |
|---:|---:|---|
| `0` | `1` | reject unsupported old schema |
| `1` | `1` | parse and validate |
| `2` | `1` | reject unsupported future schema |

## Extension and tool compatibility

An extension ID is stable identity; changing it creates a different extension.
Extension versions use major for breaking tool/config behavior, minor for
additive compatible behavior, and patch for compatible fixes. They do not
determine SDK compatibility—the declared SDK range does.

Removing/renaming a tool, making optional input required, changing a field type,
or changing output meaning is breaking. Adding optional input/output metadata
is normally additive. Compatibility is checked before requirements and
activation. Required incompatibility aborts startup; optional incompatibility
remains failed with structured diagnostics and exposes zero tools. Built-ins and
third parties use the same path.

All bundled extensions declare `[2.0.0, 3.0.0)`. SDK 1 manifests are rejected
instead of being loaded through a best-effort JSON compatibility shim. AST/Web
Search still use experimental `HostOperationIntent`; the major range does not
promote that API to stable.

## Semantic and security compatibility

- `workspace.read` requests workspace-scoped observation, not writes or
  arbitrary filesystem reads.
- `workspace.write` requests a normalized workspace-bound mutation; the host
  owns capability, policy, approval, and approved-intent binding.
- `network.http` declares HTTP use, not all-host access or allowlist/TLS/policy
  bypass.
- Stable intents are `WorkspaceSearchIntent` and `WorkspaceWriteIntent`; fields,
  validation, normalization, and exact execution binding are contracts.
  `HostOperationIntent` remains experimental.
- Cancellation observation is idempotent. A deadline expires when
  `nowMillis >= expiresAtMillis`; cancellation, deadline, denial, and host
  failure remain distinct.

Every compatible release preserves that a manifest cannot grant authority; an
extension cannot grant approval, create `PreparedOperation`, forge Receipt,
mutate Audit or Run persistence, or invoke the trusted executor; and approval
of intent A cannot authorize execution of intent B. Compatibility never
preserves an authority bypass.

Runtime diagnostics promise structured category, phase, extension ID/version,
declared range, and host SDK fields. Human message text is not a byte-stable
machine API.

## Product execution and operator matrix

The following commands use product entrypoints, not database inspection:

```text
Usage: /inspect [run-id] [before-operation-cursor]
axyndra --print "/inspect"
axyndra --print "/inspect <run-id> <before-operation-cursor>"
axyndra --print "/plugins inspect <package-path>"
axyndra --print "/plugins import <package-path> --scope workspace"
axyndra --print "/plugins doctor"
axyndra --print "/plugins enable <plugin-id> --scope workspace"
axyndra --print "/plugins disable <plugin-id> --scope workspace"
axyndra --print "/plugins update <plugin-id> <package-path> --scope workspace"
axyndra --print "/plugins rollback <plugin-id> --scope workspace"
axyndra --print "/plugins uninstall <plugin-id> --scope workspace"
```

These `--print` forms are the headless examples: they return local command output
without starting a model turn or requiring TUI state. A plugin command that needs
`select` or `confirm` without an active responder returns the documented
input-required/unsupported diagnostic; it never hangs or invents consent.
`/plugins doctor` lists stable diagnostic codes with operator-facing messages.
Use it after import or update, then `/plugins inspect` to verify the pinned source,
component status, compatibility profile, missing dependency or isolation runtime,
and effective scope. Enablement never expands declared capabilities; changed
content, permissions, or approval inputs require a new snapshot and authorization.

`/inspect` is local and never invokes the model. It shows the frozen model/tool/
Skill/plugin source digests, parent-child Operation chain, approval and handoff
evidence, Receipt/result status, usage provenance, partial outcomes, and the
supported recovery action. CLI, RPC, and TUI render the same typed query. RPC
accepts the same slash prompt and returns `agentInvoked:false`; the TUI keeps the
result inline in the transcript rather than opening a separate authority-bearing
state machine.

The controlled application user flow is conversational: request a change; a
read-only Program may return an `application_plan`; review the host-rendered
bounded diff and complete target summary; submit the separate canonical
`apply_file_plan` call; then approve or reject the exact prepared Operation. A
model proposal, preview confirmation, `plan_ref`, or `plan_digest` alone does not
grant write authority. The model receives only bounded summaries and immutable
references; `/inspect` explains durable evidence without replaying source or
secret environment values.

| Capability/profile | Current status | Required environment and limit |
| --- | --- | --- |
| Default CLI/TUI/RPC with no plugin | verified on packaged Linux x86_64 candidate | No Node, Bun, Cangjie SDK, workspace checkout, or `LD_LIBRARY_PATH` is required after packaging. |
| Read-only JavaScript PTC | verified on Linux x86_64 | Runs in an independent sandboxed product worker, uses denied ambient network/workspace access, and calls only the frozen read-only broker subset. Python PTC and writable nested PTC are unsupported. |
| Pi executable extension subset | verified against the pinned v0.87.1 fixtures on Linux x86_64 | Requires a supported JavaScript runtime plus enforced process isolation. Missing runtime or isolation is an explicit diagnostic; there is no bare fallback. |
| Codex Skills and selected hooks | partial | Declarative Skills and `PreToolUse`/`PostToolUse` command hooks are covered as documented below; full Agent Plugins host behavior is not claimed. |
| External Agent execution | unsupported | External answers cannot be represented as internal Receipts. No delegated identity, tool-filter, cancellation, usage, or recovery protocol is implemented. |
| Non-Linux, Bun-hosted extensions, arbitrary third-party packages | unverified | Parser acceptance is not execution support. |

Operator-facing diagnostic families are stable identifiers rather than text
matching: `application_plan.structure_invalid`, `.schema_unsupported`,
`.source_mismatch`, `.path_invalid`, `.targets_conflict`, `.limit_exceeded`,
`.plan_reference_invalid`, `.write_unconfirmed`; `extension.process_failed`,
`.protocol_identity_mismatch`, `.pi_interaction_unsupported`; and
`persistence.sqlite_reset_failed`. Conflict and denied results must be corrected
or re-authorized as a new Operation. `write_unconfirmed`, an Unknown effect, or
missing historical implementation requires inspection and reconciliation; it
must not be retried blindly.
Database upgrades are forward-only through schema v26; a database with a newer
schema version is rejected before use. Stop other writers and back up the SQLite
database together with referenced artifact blobs before first startup with a
newer binary. Code rollback uses the matching pre-upgrade backup; database
restore and plugin-generation rollback are separate procedures. See
[Schema v26 evolution and rollback boundary](architecture.md#schema-v26-evolution-and-rollback-boundary).

The pinned Pi and Codex sources and their license treatment are recorded in
[Pinned upstream references](#pinned-upstream-references). The vendored cj-tui
publication risk remains separately disclosed in
[cj-tui dependency provenance](cj-tui-dependency.md); technical package evidence
does not resolve that legal gate.

## Compatibility scope

P2.5 supports source/API compatibility for frozen consumers, manifest
compatibility, and semantic/security compatibility. Extensions are rebuilt
against a compatible SDK. Precompiled binary ABI compatibility is **not yet
guaranteed** by the compile-time package model or these gates.
## Pi and Codex package compatibility

This section records pinned upstream references for issues #34 and #35, verified issue #34 M2 Pi behavior, and the implemented M3 Codex command-hook subset. It separates upstream contracts from Axyndra's versioned, isolated Pi executable subset and partial Codex `PreToolUse`/`PostToolUse` command-hook execution; parser acceptance alone is not execution evidence.

### Pinned upstream references

| Ecosystem | Fixed source and schema | License and use |
| --- | --- | --- |
| Pi | Release `v0.87.1`, commit `f07218c4d4bbc12bef056a7058c3dd49dfe41abe`. Package rules: [packages.md](https://github.com/earendil-works/pi/blob/f07218c4d4bbc12bef056a7058c3dd49dfe41abe/packages/coding-agent/docs/packages.md). Extension API: [extensions.md](https://github.com/earendil-works/pi/blob/f07218c4d4bbc12bef056a7058c3dd49dfe41abe/packages/coding-agent/docs/extensions.md), [types.ts](https://github.com/earendil-works/pi/blob/f07218c4d4bbc12bef056a7058c3dd49dfe41abe/packages/coding-agent/src/core/extensions/types.ts). Representative tool source: [hello.ts](https://github.com/earendil-works/pi/blob/f07218c4d4bbc12bef056a7058c3dd49dfe41abe/packages/coding-agent/examples/extensions/hello.ts). | Pi repository MIT license. The fixed package document defines `package.json.pi` resource paths, glob and exclusion syntax, conventional directories, and package dependencies. The example imports the Pi packages and registers an `ExtensionAPI` tool; it is a reference fixture, not an Axyndra end-to-end pass. |
| Codex / Agent Plugins | Codex source snapshot `4981037e99a322ee9cf29bc8730cb64d263fa00b` (snapshot, not a released compatibility tag). Agent Plugins schema URI: `https://agent-plugins.org/schemas/1.0.0/plugin.schema.json`. Pinned implementation: [plugin_namespace.rs](https://github.com/openai/codex/blob/4981037e99a322ee9cf29bc8730cb64d263fa00b/codex-rs/utils/plugins/src/plugin_namespace.rs), [manifest.rs](https://github.com/openai/codex/blob/4981037e99a322ee9cf29bc8730cb64d263fa00b/codex-rs/core-plugins/src/manifest.rs), and [agent_plugin_manifest.rs](https://github.com/openai/codex/blob/4981037e99a322ee9cf29bc8730cb64d263fa00b/codex-rs/core-plugins/src/agent_plugin_manifest.rs). The legacy field sample is [plugin-json-spec.md](https://github.com/openai/codex/blob/4981037e99a322ee9cf29bc8730cb64d263fa00b/codex-rs/skills/src/assets/samples/plugin-creator/references/plugin-json-spec.md). | Codex repository Apache-2.0 license. Agent Plugins has schema version 1.0.0. The legacy sample has no separate schema version; the commit pins the sample and parser behavior. OpenAI's [packaging guide](https://developers.openai.com/plugins/build/plugins) was also checked on 2026-09-24 for the portable/legacy overlay rule. |

The Pi package format does not carry a separate schema-version field. Axyndra’s Codex package parser accepts the pinned Agent Plugins schema URI and rejects other URIs in the same schema family as unsupported. These pins identify reproducible reference evidence; they do not limit future compatibility to those exact plugin releases.

### Selection and field precedence

`parsePluginPackageManifest(family, ...)` parses an explicitly selected manifest family; `inspectPluginPackage(root)` performs automatic selection and has no separate profile argument. Automatic selection rejects conflicting recognized Pi, Codex, and Axyndra package identities rather than merging them or choosing the first file found.

| Profile | Selection and precedence contract |
| --- | --- |
| Pi package | `package.json` declaring `pi`, or `package.json` with at least one conventional resource directory, selects Pi. A declared `pi.<type>` array replaces that type’s conventional scan; absent uses the conventional directory and `[]` disables it. Positive globs and `!` exclusions are preserved. |
| Portable Codex | Root `plugin.json` is portable only with the exact supported Agent Plugins `$schema` URI. Another URI under the Agent Plugins schema family is an error, not a fallback. A root file outside that family may be ignored while a recognized legacy manifest is selected. |
| Codex overlay | For a selected portable root manifest, an object at `extensions.com.openai` supplies the Codex overlay and takes precedence over `.codex-plugin/plugin.json`; if absent, the hidden legacy manifest supplies the compatibility overlay. The portable root keeps package identity. Root `skills/` and `mcp.json` are components when present. |
| Legacy Codex | When no supported portable root is selected, `.codex-plugin/plugin.json` supplies the legacy manifest. Its `skills`, `hooks`, `mcpServers`, `apps`, and `interface` fields retain their legacy meanings. `mcpServers` can reference a companion configuration file or contain inline definitions; `apps` is hosted-registration metadata, not an endpoint. |
| Standalone MCP config | Root `mcp.json` and `.mcp.json` can form distinct MCP-only profiles when no higher-priority plugin manifest is selected. They do not replace or merge a selected plugin identity. |
| Standalone Skill / Axyndra | `axyndra.plugin.json` selects the Axyndra profile; recognized Pi/Codex identity conflicts are rejected. A standalone `SKILL.md` is the final fallback when no manifest candidate is selected. |

`inspectPluginPackage()` performs auto-selection in this order: Axyndra manifest, supported portable Codex root manifest, legacy Codex manifest, recognized Pi package, standalone `mcp.json`, standalone `.mcp.json`, then standalone `SKILL.md`. Root Codex schema-family versions are checked before fallback. This is ecosystem-aware selection, not first-present-file parsing. `parsePluginPackageManifest(family, ...)` remains the explicit-family parser; `ProductPluginRuntime.inspect` does not take a profile argument.

### Component and API matrix

| Upstream component | Axyndra mapping | Current evidence and status |
| --- | --- | --- |
| Pi Skills | Import a package-root Skill tree through a static managed snapshot and expose selected Skills through ProductSkillRuntime. | `pi.skills` selectors, globs, exclusions, metadata, prompt routing, and reference reads are exercised end to end. The implemented declarative subset is `partial`; this is not a claim for every Pi package behavior. |
| Pi prompt templates | Expose enabled declared templates through the product prompt-template runtime. | Product tests cover selectors/exclusions, `$ARGUMENTS`, traversal rejection, and disabled/enabled visibility. Full upstream command semantics are not claimed. `partial`. |
| Pi themes | Preserve metadata for inspection without rendering. | A discovered `themes` component is blocked and diagnosed; rendering is `unsupported`. |
| Pi executable extensions | Run the pinned v0.87.1 tool subset in the isolated Pi ExtensionAPI host. | Contract fixtures execute the upstream `hello.ts` and `with-deps/index.ts` examples. Product tests cover registration, tool schemas and results, controlled `pi.exec`, and the supported Pi event subset, including input revalidation, result immutability, and per-Thread state. Support is `partial`; other Pi APIs remain unsupported. |
| Codex Skills | Resolve the portable root `skills/` component into the existing Skill runtime. | Portable Codex Skill metadata, trigger routing, and reference reads are Product-tested. The no-plugin/no-runtime smoke below covers default application startup, not Codex Skill execution with Node absent. Full Agent Plugins host compatibility is `partial`. |
| Codex MCP | Normalize portable `mcp.json` and legacy `mcpServers` definitions into the existing product MCP configuration. | Product tests cover portable stdio and streamable-HTTP settings plus legacy inline and companion-file forms. Actual server launch or request execution is unverified; overall host compatibility is `partial`. |
| Pi hooks and commands | Register Pi event handlers during extension initialization. Expose registered commands only through TUI and RPC routes. | `pi.on` supports `tool_call` and `tool_result` only. `tool_call` may modify input or block a call; Axyndra revalidates modifications. `tool_result` is observational. Enabled `registerCommand` handlers support `notify`, `select`, and `confirm` through an active frontend responder. Other Pi events and session APIs remain unsupported. Support is `partial`. |
| Codex hooks | Preserve static command-hook declarations without treating package content as authority. | Portable Codex package metadata cannot grant Axyndra capabilities. Imported `PreToolUse` and `PostToolUse` declarations therefore remain inactive until a host-owned grant path exists. The command-hook runtime supports exact tool-name and `*` matchers, but package enablement alone never activates it, so status is `partial`. |
| Codex apps | Preserve app metadata without claiming a live endpoint. | App metadata remains declarative; no hosted endpoint or app execution runtime is present. Execution is `unsupported`. |
Codex package content and package enablement are not capability grants. In particular, a package cannot obtain host-mediated workspace mutation by declaring or shipping a `PreToolUse` command.

All executable snapshots, including workspace-scoped imports, live in the host-owned settings package cache rather than under the writable workspace. Workspace scope keeps only its lock and grant state under `.axyndra`. The content-addressed package tree is never updated in place, is mounted read-only into plugin processes, and is rejected by the isolated host when it resolves inside the workspace or outside the configured managed cache. Process and WASM operations are reserved atomically with generation admission; disable, update, and uninstall cancellation therefore remains effective even before process registration completes.

### E4-08 real compatibility findings

| Result | Evidence | Boundary |
| --- | --- | --- |
| Upstream source runs unchanged | `support_tests/extension_runtime_contract` executes the pinned Pi v0.87.1 `hello.ts` and `with-deps/index.ts` sources. | This demonstrates only the API exercised by these two examples through Axyndra’s host adapter, not full Pi compatibility. |
| Host-adapted subset | Product tests exercise Pi tools, events, and commands plus selected Codex Skills and command hooks. | These are Axyndra-side adapters; they do not demonstrate a native Codex plugin host. |
| Modified upstream source | No source-modified third-party extension has been validated; the pinned Pi examples run without source patches. | Do not claim support for plugins requiring source changes. |
| Unsupported | Pi session APIs and other Pi events, Pi theme rendering, Codex app execution, and unimplemented Pi helpers. | Unsupported behavior is diagnosed or retained as declarative metadata; it is not silently treated as executable. |
| Unverified | Other Node versions, Bun, non-Linux isolation profiles, arbitrary third-party extensions, public package endpoints, and actual Codex MCP server execution. | Compatibility remains `partial` for the tested profiles and components above. |
### E4-05 selected hook decision contract

This table defines Axyndra’s selected Codex hook profile and Pi event subset. It does not define the full Codex or Pi ExtensionAPI contract.
The Codex event profile selects `PreToolUse` and `PostToolUse` command hooks only. Other Codex hook events and non-command Codex handlers are unsupported. Pi `pi.on` separately supports `tool_call` and `tool_result` as described below; other Pi events, including session events, are unsupported.
| Event | Trigger, order, and input | Decision | Failure and authority |
| --- | --- | --- | --- |
| `PreToolUse` | Once after the canonical tool-call item is committed and before `ToolPipeline.prepareCommitted`; handlers run serially in frozen plugin-snapshot order, then declaration order. The JSON input contains event name, plugin identity/version, Thread/Run/epoch, call ID, tool name, and arguments. | `continue`, `allow`, `deny(reason)`, or `modify(arguments)`; modification keeps the original call ID and tool name. `allow` is an alias for `continue`, not an authorization grant. | Malformed output, nonzero exit, or timeout denies before executor admission. Modified arguments are revalidated and renormalized by `ToolPipeline.prepareCommitted`; policy and approval apply to the final plan. Host denial remains authoritative. |
| `PostToolUse` | Once after the canonical Operation, Receipt, and result commit; handlers receive the final outcome and a bounded, redacted, read-only result view. | Observe only; handler output is ignored. | Failure is diagnostic-only and cannot reopen, replace, or rewrite the committed result or Receipt. |
| Command execution | Each handler receives one JSON event on stdin; only `PreToolUse` stdout is interpreted as a decision. | No separate decision. | `ToolCatalog` caps the enabled snapshot at 32 handlers per event; event frames are limited to 262,144 bytes. PreToolUse decision output is limited to 262,144 bytes and parsed at JSON depth 16. Timeout defaults to 2 seconds and accepts 1–30 seconds; cancellation and the owning Operation deadline remain authoritative. Each launch rechecks package root, identity, version, and content digest; commands run with a read-only package root, process isolation, network denied, and a controlled `PATH`. |
| Pi `tool_call` (`pi.on`) | Once after the canonical ToolCall is committed and before `ToolPipeline.prepareCommitted`. The event carries `type`, `toolCallId`, `toolName`, and `input`. Handlers run in frozen plugin-snapshot order, then event registration order. | A handler may mutate `event.input` or return `{block: true, reason}`. Axyndra validates modified arguments against the tool schema. Policy and approval use the normalized plan. | Handler errors, invalid output, or timeouts deny the call before execution. The core ToolPipeline remains authoritative. |
| Pi `tool_result` (`pi.on`) | After the canonical Operation, Receipt, and result commit. The event carries call identifiers, input, error status, and a bounded redacted result in a text content block. | Observation only; a handler must return `undefined`. | Handler errors or replacement values produce diagnostics only. They cannot change the committed result or Receipt. |
PreToolUse request and response schema:
A request is a JSON object with `event_name: PreToolUse`, string `plugin_id`, `plugin_version`, `thread_id`, `run_id`, `call_id`, and `tool_name`, integer `epoch` ≥ 1, and object `arguments`. A response is exactly one of `{"decision":"continue"}`, `{"decision":"allow"}`, `{"decision":"deny","reason":string}`, or `{"decision":"modify","arguments":object}`. A deny reason is limited to 512 UTF-8 bytes. Unknown fields and variants are rejected. Modified arguments are revalidated before approval or execution.
PostToolUse adds `operation_id`, `receipt_id`, and `outcome` (`completed`, `denied`, `cancelled`, or `failed`). It includes a redacted `result` when available; if its serialized form exceeds 65,536 bytes, the result is replaced by `{"omitted":"result exceeded observer limit"}.
Pi hook state is process-local. Axyndra starts one JavaScript host process for each plugin and Thread. Calls within a Thread are serialized, and different Thread IDs use isolated processes. Module closure state persists across calls in one process and resets when Axyndra starts a replacement process. Axyndra does not replay interrupted hook calls. Each plugin generation retains at most 64 Thread processes. A new, distinct Thread fails with `extension.pi_thread_limit`. Pi session events and APIs, including `session_start`, remain unsupported. The runtime exposes no durable Pi session storage.

### E4-06 command and frontend interaction contract

The implemented command subset registers Pi commands during extension initialization and exposes enabled commands as `plugin.<namespace>.<name>` routes. The TUI invokes a route with `/plugin.<namespace>.<name> <arguments>`; RPC clients list routes with `get_plugin_commands` and invoke `plugin_command` with `routeName` and `arguments`. This is a partial Pi API implementation, not full command or event compatibility.

The TUI enables its Ask responder when attaching the interactive session. RPC clients must negotiate `negotiate_interactions` with `profile: basic-v1`; `profile: none` disables the responder. Without a negotiated frontend, command UI calls fail with `extension.pi_interaction_unsupported` instead of waiting for input.

RPC `interaction_request` frames carry `interactionId`, `interactionKind`, `sessionId`, `runId`, `operationId`, `callId`, `commandId`, and `epoch`. `interaction_response` must echo those identity fields, send a Boolean `cancelled`, and include `choice` or `confirmed` only for a non-cancelled response. Tool asks retain their Run/Operation/call identity; command asks use a `commandId` with empty `runId`, `operationId`, and `callId`, and epoch zero. TUI responses resolve the matching active request.

`select` returns one submitted option label; `confirm` returns a Boolean. Notifications are one-way `plugin_notice` events/cards, not tool progress or approvals. These interactions provide business input only: they cannot approve a ToolPipeline operation, change a prepared plan, or rewrite an Operation or Receipt. Cancellation does not create an affirmative answer, and stale, malformed, duplicate, or mismatched RPC responses are rejected.

Product tests cover Pi event registration and behavior, command registration, correlated select/confirm requests, and unsupported UI without a responder. A real TUI PTY run verifies visible notifications, selection and confirmation, Escape cancellation, and a subsequent command. A production JSONL RPC smoke verifies command discovery, correlated select/confirm, successful completion, and unsupported completion after negotiating profile `none`. Other Pi events and session APIs remain unsupported.

M2 evidence goes beyond parser-only fixtures. `agent_product/src/plugin_runtime_test.cj` verifies direct filesystem, process, and loopback-network denial, cancellation of a pending `pi.exec` followed by another successful call, process crash/restart, serialized calls, path-redacted diagnostics, and transactional tool publication. `support_tests/extension_runtime_contract` executes the two pinned Pi examples and the Pi event-hook protocol fixture. `support_tests/product_thread_runtime_contract` proves the Product `pi.exec` path emits progress and persists a read-only, network-denied child Operation, Receipt, and result Item. Linux with Node `v26.9.0` is tested; other platforms and Node versions remain unverified.
M3 evidence: `agent_product/src/plugin_runtime_test.cj::codexCommandHooksWithoutCapabilityGrantsRemainInactive` verifies that portable Codex hook declarations remain inactive without a host grant, and `codexHooksRequireExplicitWorkspaceCapabilities` covers the read/write event matrix. `support_tests/agent_core_contract/src/main.cj::modifiedToolArgumentsAreRevalidatedAndApprovalBoundContract` verifies schema revalidation, final-plan approval binding, and preservation of the original ToolCall. P3 evidence: `piEventHooksPreserveOrderRevalidateAndIsolateThreadState` verifies Pi callback order, same-Thread state, Thread isolation, modification revalidation, blocking, and committed-result immutability. `piSupportedEventContracts` verifies event descriptors, callback state, and rejection of result replacement; `piUnsupportedApiContracts` verifies unsupported session-event diagnostics. Linux is tested; other platforms remain unverified.

E4-08 acceptance evidence: all 81 `agent_product` tests pass. They cover
transactional update/rollback (`updateRollbackUninstallAndGarbageCollectionAreTransactional`,
`rollbackHistorySurvivesRuntimeRestart`), workspace-isolated snapshot collection
(`workspaceGarbageCollectionDoesNotCrossWorkspaceCaches`), Product command
revocation (`commandOnlyPiPluginActivationIsAdvertisedAndRevoked`), active
invocation cancellation on host unmount
(`piExtensionApiHostCancellationAndRevocationAreTerminal`), and host crash
recovery (`piExtensionApiHostRestartsAfterPluginCrash`).

A relocated packaged `agent_app` entrypoint opened Product with an isolated empty
home/workspace and printed `/help` successfully while `PATH` exposed only a copy
of the declared `rg` workspace-search dependency. Node, Bun, `cjc`, the source
checkout, SDK variables, and `LD_LIBRARY_PATH` were absent. This smoke proves the
default no-plugin startup path, not plugin execution without a JavaScript runtime.
Linux with Node `v26.9.0` remains the tested executable-extension profile; other
Node versions, Bun, and platforms remain unverified.

### M4/P4 plugin performance baseline

Run the independently reproducible baseline against a packaged candidate:

```sh
AXYNDRA_SDK_ROOT=<sdk> AXYNDRA_BINARY=<candidate>/bin/axyndra \
  python3 support_tests/plugin_performance_baseline/check.py
```

The current same-host sample used the working tree based on commit
`de3e03882412ad171bba84e6d973a1e854a229b7`, Cangjie
`1.3.0-alpha.06 (cjnative)`, Node `v26.9.0`, and Linux x86_64. The Product
profiles use `--fixture`; the JavaScript host uses its permission-enforced local
fixture profile. No Provider, public package endpoint, or external network was
used. Results are microseconds except RSS:

| Profile / metric | Samples | P50 | P95 | Investigation budget |
| --- | ---: | ---: | ---: | ---: |
| plugins disabled: Product cold start | 20 | 266,071 us | 290,740 us | 600,000 us |
| plugins disabled: Product peak RSS | 20 | 113,012,736 B | 113,336,320 B | 201,326,592 B |
| declarative package inspect: Product cold start | 20 | 258,991 us | 283,712 us | 600,000 us |
| declarative package inspect: Product peak RSS | 20 | 113,037,312 B | 113,483,776 B | 201,326,592 B |
| tool extension host cold start and handshake | 12 | 82,429 us | 103,492 us | 250,000 us |
| tool extension first call | 12 | 3,441 us | 6,130 us | 20,000 us |
| tool extension steady IPC | 240 | 2,936 us | 12,387 us | 30,000 us |
| tool extension host RSS | 12 | 20,586,496 B | 31,326,208 B | 67,108,864 B |
| cancellation after a 100 ms trigger | 12 | 128,020 us | 138,039 us | 300,000 us |

The rounded budgets are change-detection thresholds: at least roughly twice the
observed P95, with extra scheduler margin for startup and cancellation. They are
not product latency or memory guarantees. First-call, IPC, and cancellation are
not applicable to the disabled and declarative-only profiles because neither
starts an executable plugin. This sample does not cover other hosts, operating
systems, Cangjie/Node versions, public Git/npm, or real Provider traffic. The
implementation release gate records the seven JSON baseline rows in candidate
diagnostics; the protected release gate additionally owns real-provider smoke.

### Integrated implementation and release evidence

Run the complete credential-free candidate gate with a disk-backed temporary
directory and a new evidence directory:

```sh
AXYNDRA_GATE_KIND=implementation AXYNDRA_SDK_ROOT=<sdk> \
AXYNDRA_EVIDENCE_DIR=<new-evidence-dir> TMPDIR=<disk-backed-temp> \
  bash scripts/release_gate.sh
python3 support_tests/fault_matrix/check.py \
  --output <new-fault-evidence-dir> --jobs 3
```

The implementation gate builds and packages the product, runs the architecture,
vNext, package-readiness, MCP, release-contract, provider-fixture, frontend, cold
start, plugin-performance, and TUI gates, and ends with
`axyndra implementation gate passed (real-provider smoke not run)`. Its evidence
directory records the candidate and package-root paths. The package diagnostics
contain Cangjie/cjpm versions, cold-start measurements, and
`plugin-performance.jsonl`. The fault runner writes `report.json`, per-suite logs,
hashes, expected outcomes, and actual executable status for F01-F14; success ends
with `FAULT_MATRIX_READY rows=14 passed=14 failed=0 suites=9`.

The protected variant sets `AXYNDRA_GATE_KIND=release`,
`AXYNDRA_REAL_SMOKE=1`, and `DEEPSEEK_API_KEY`; it is the only gate that may claim
the real-provider smoke. Public Git/npm endpoints, non-Linux platforms, other
Node/Bun/Cangjie profiles, and long soak matrices remain unverified until their
separate gates run. Local exact-commit Git and loopback exact-version npm fixtures
do not promote those public services to verified.

Use `supported`, `partial`, `unsupported`, and `unverified` per package version, component, profile, runtime, and platform. Track activation health separately (`disabled`, `blocked`, `failed`). Parsing, module loading, or a healthy host process cannot promote an untested component to `supported`.
The generic worker and Pi v0.87.1 bootstrap use internal `axyndra-js-host-v2` JSONL framing, not a Pi ABI. The Pi facade exposes initialization-time `registerTool`, `registerCommand`, and `on`. `pi.exec` is available only while a tool executes. `defineTool` is an identity helper. The TypeBox shim supports `Type.Object` with required string properties and descriptions, plus `Type.String` with descriptions.

Tool `execute` receives the call ID, parameters, active `AbortSignal`, and `onUpdate` progress callback; its context exposes `cwd`. Command handlers receive their argument string and a restricted context. The command context supports only the finite `ctx.ui.notify`, `ctx.ui.select`, and `ctx.ui.confirm` services, resolved through an active frontend responder. Results support bounded text content and JSON-serializable details.

The `pi.exec` bridge sends safely quoted command arguments through the existing read-only `bash_readonly` broker using the active tool context cwd. An explicit cwd must match that context. The bridge supports the active signal and an optional bounded timeout; it grants no process-spawn or network authority. Tool labels are not published to the model tool catalog. Post-initialization tool, command, and event registration is unsupported. Other Pi events, session APIs, provider registration, and unsupported TypeBox helpers are also unsupported.

For this internal host protocol, Product sends tool definitions in the initial `ready.tools` frame.
It validates each descriptor and stages the namespaced `plugin.<namespace>.<tool>` definition with its callback binding.
Product publishes the complete batch to `ToolCatalog` in one commit.

A rejected batch leaves `ToolCatalog` unchanged and tears down the host generation. Each Run keeps its captured `ToolSetSnapshot`.
Product serializes calls within each per-Thread plugin process. Each process keeps the extension’s module closure, and processes for distinct Thread IDs do not share that closure. The regression test starts a second call after the first emits progress and verifies both results with a peak of one active callback.
The host rejects a post-ready `register_tool` frame with `extension.tool_registration_unsupported` and closes that generation.
Plugin tool plans require `ExtensionInvoke`.
The Axyndra-specific `pi.axyndra.capabilities` overlay can request `workspace.read` or `workspace.write` for the controlled service. Product adds the declared workspace capability to plugin Operations; a write grant is required before a Pi `tool_call` hook can modify normalized arguments, while a read grant exposes only `tool_result` observation.

### E4-04 JavaScript host service broker

The `pi.axyndra` object is an Axyndra overlay, not a Pi package field. Its accepted capabilities are `workspace.read` and `workspace.write`; write implies read access for hook registration. The parser rejects malformed lists and other capability names. This `package.json` fragment shows the mutation opt-in:

```json
{
  "pi": {
    "extensions": ["service.js"],
    "axyndra": { "capabilities": ["workspace.read", "workspace.write"] }
  }
}
```

The JSONL host accepts up to 32 unique `service_request` frames per invocation. It supports only `exec`.
Product maps object arguments to a `bash_readonly` ToolCall and uses the prepared-invocation pipeline.
The child plan is read-only, denies network access, and requires no capability beyond `WorkspaceRead` in the committed plugin plan.
The broker does not pause the JavaScript host for approval. It settles any unexpected `NeedsApproval` child as rejected and returns immediately. The child context carries the parent cancellation token.

Product publishes host progress through the owning Run's `ToolOutputSink` as `ToolOutputChannel.Progress`. Each admitted child has a durable Operation and Receipt linked to the committed plugin Operation. The admission records a stable key for the parent call and request. Recovery resolves a matching admission to its existing child Receipt instead of executing the request again.

The broker adds neither `ProcessSpawn` nor a method to the read-only PTC allowlist (`read`, `grep`, `glob`). The Pi host exposes only the separately documented v0.87.1 tool subset; it does not implement the broader Pi ExtensionAPI.

### Runtime boundary and evidence

The product launcher requires a Linux `WorkspaceSandbox` plan and fails closed when isolation is unavailable. The OS-isolation fixture with Node permission flags disabled confirms that the extension cannot write into its package root or connect to a host-loopback listener. Product Pi-host tests also confirm direct filesystem and process denials, loopback denial, per-Thread state isolation, and state reset after a worker crash. This is Linux evidence only; other platforms and isolation profiles remain unverified.

The local runtime reference observed for this evidence was Node `v26.9.0` on Linux with Cangjie STS `1.1.3`. This is a tested profile, not a minimum Node version or a cross-platform compatibility promise. Other Node versions, Bun, and non-Linux isolation profiles remain unverified.

### E4-01 executable profile

| Profile | Module and dependency shape | Acceptance boundary |
| --- | --- | --- |
| Pi v0.87.1 upstream extensions | The pinned `hello.ts` imports `Type` and `defineTool`; `with-deps/index.ts` imports the exact `ms@2.1.3` runtime dependency. | Both upstream sources, package metadata, MIT notices, and commit provenance are stored in the fixture. Both execute through the restricted Pi host; this proves only the API methods exercised by these examples, not full Pi compatibility. |
| `axyndra-js-host-v2` | Node `v26.9.0` on Linux; Pi profile uses `--permission`, package-root reads, and `--experimental-strip-types` for `.ts`. Generic entrypoints accept `.js`, `.mjs`, `.cjs`, and `.ts`. | Generic CJS/ESM/TypeScript fixtures cover the internal protocol; Pi contract fixtures execute the upstream API examples. This is a tested Linux profile, not a minimum Node version or cross-platform claim. |

When Node permission enforcement is enabled, the host adds `--permission` and `--allow-fs-read=<package root>`; TypeScript entrypoints also receive `--experimental-strip-types`.

| Fixture or test | Provenance | What it proves / does not prove |
| --- | --- | --- |
| `agent_extension_runtime/src/plugin_package_test.cj` | Locally authored inline JSON; project license. | Positive Pi component and Codex MCP parser cases; negative unsafe Axyndra entrypoint and blocked Pi hooks/commands. Parser-only; not full upstream package fixtures. |
| `agent_product/src/plugin_runtime_test.cj` | Locally authored package fixtures; product-level tests. | Covers Pi Skills/prompts, portable Codex Skills/MCP, precedence and management, plus real Pi host registration, schema/result handling, direct-access denial, cancellation, crash recovery, and transactional tool publication. It complements rather than replaces the pinned upstream extension contract and Product thread broker tests. |
| `support_tests/product_thread_runtime_contract` | Locally authored Git repository, loopback npm registry, and Node service fixture. | Proves exact-commit Git and exact-version npm acquisition, integrity-locked snapshots, disabled lifecycle scripts, and update rollback for local sources. Its broker fixture emits progress, runs read-only `exec`, and verifies parent-child Operation/Receipt evidence and the result Item. Local sources do not prove public registry behavior. |
| `support_tests/extension_runtime_contract/src/main.cj` and `fixtures/axyndra_host_*` / `pi_*` protocol files | Locally authored protocol fixtures plus separately pinned Pi sources. | Generic CJS/ESM/TypeScript handshake, invocation, progress, cancellation, bounds, and errors; the Pi fixtures cover supported event registration and invocation plus explicit unsupported-event diagnostics. The pinned Pi sources and execution evidence are listed below. |
| `fixtures/upstream_pi_v0_87_1/hello.ts`, `with-deps/index.ts`, and `event-hooks.js` | Upstream examples are pinned to Pi v0.87.1; `event-hooks.js` is a local protocol fixture. | `piJavascriptApiContracts` and `piNoUiDependencyContracts` execute the upstream examples. `piSupportedEventContracts` checks event descriptors, mutable `tool_call` input, state within one host, and rejected `tool_result` replacement. This proves only the listed Pi subset. |
| Codex plugin schema/parser files at the pinned commit | Upstream Codex Apache-2.0 source, linked above. | Reproducible schema and precedence references. Product fixtures exercise declarative selection and MCP/Skill adaptation; this is not validation against a running Codex plugin host. |

`PluginPackageDescriptor` remains an inspection result, not an immutable snapshot. `ProductRuntime` imports create content-locked snapshots from local paths, exact Git commits, and exact npm versions. Acquisition uses an explicitly approved, prepared, control-only tool rooted under the host settings directory; the tool is absent from model-visible definitions, and workspace-confined processes cannot mutate its staging tree. User and workspace snapshot caches are separate, so collection for one workspace cannot delete another workspace's package. npm lifecycle scripts are disabled, and lock files carry SHA-512 integrity for the root and transitive dependencies. Imported snapshots are disabled by default, and failed updates preserve the prior snapshot. Each signed Axyndra Process or WASM invocation re-inspects the bound package identity, version, entrypoint, signature, and content digest immediately before launch; changed bytes fail with `extension.snapshot_stale` and no process admission. Evidence covers local Git and a loopback registry, not public endpoints. Pi v0.87.1 executable extensions remain `partial` as described above. Pi session APIs and events outside the selected subset are unsupported; broader Codex executable-host compatibility remains unverified.
