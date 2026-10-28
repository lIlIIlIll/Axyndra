# agent_sdk

The supported source-authoring package is version **4.0.0**. It contains
Native contribution declarations, `NativePluginDefinition`,
`NativePluginInvocation`, `NativePluginHandler`, typed errors, cancellation,
and deadline observations. It depends only on yjson and the JSON seam.

A handler runs inside its Native executable and returns complete data. These
types cannot grant Host services, policy, approval, Source, receipts, or I/O.
The executable connects to the current bounded Native protocol; package
inspection, enabled Registry records, current-source checks and normal policy
remain mandatory in the Host.

`AGENT_SDK_VERSION` remains **2.1.0** for the existing Native handshake and
manifest range. The source package release and wire compatibility range are
separate; this change does not alter existing executable wire versions.

The actual independent sample is `support_tests/sdk_fixture_extension` with
the executable wrapper and current `axyndra.plugin.json` in
`support_tests/native_sdk_fixture`. Its provider is pure, requests no Host
capabilities, and retains full NUL/Unicode result data. A fresh build must place
its executable at the manifest's `bin/native-sdk-fixture` path before import.

The old `Extension`, `ExtensionTool`, workspace intents, Host-operation intent,
and compiled Installer/executor are removed from the production surface. Their
complete historical assertions run only through explicit `support_tests/legacy_*`
oracle packages; production and Minimal cannot import those packages.

The checked source baseline is `compat/agent-sdk-native-v3.api.json`.
The original v2 baseline is retained as historical evidence, not a promise that
v2 author source still compiles. See [compatibility](../docs/compatibility.md).

## Bounded View documents

`validatePluginViewDocument` validates the `axyndra.view/v1` data model.
`PLUGIN_VIEW_MAX_BYTES` is 196,608 bytes and `PLUGIN_VIEW_MAX_NODES` is 128.
The model supports plain text, status, code, diff, tool-result, document-source,
input, list and table nodes. Aggregate text is limited to 64 KiB; a model has
at most 16 actions. Action input is bounded to 256 values and depth eight.
Unknown fields, duplicate identifiers, invalid selections, terminal control
characters and directional overrides are rejected. `isPluginViewPlainText`
checks the same plain-text restriction for Host-owned source presentation.

A View action names a local Command, not a Tool or executor. Presentation
status and labels are plugin data, not canonical Run state or approval facts.
Large canonical documents remain Host-owned; a node can refer to a source
instead of duplicating its body inside the bounded model.

### Basic and headless presentation

```sh
axyndra --cwd <workspace> plugin views --json
axyndra --cwd <workspace> plugin view <discovered-route> --json
axyndra --cwd <workspace> plugin view <discovered-route>
axyndra --cwd <workspace> --print '/view <discovered-route>'
axyndra --cwd <workspace> --mode json '/view <discovered-route>'
```

Use the route returned by discovery, including the installed namespace.
JSON observations have schema `axyndra.view-observation/v1`, with separate
Host metadata, the validated plugin model and Host-owned primary content.
In JSON stream mode the observation precedes the final `result` record.
Basic presentation never invokes actions. Required interaction or an
`input_required`/`unsupported` model returns exit code 3; a failed query or
invalid model returns exit code 1.

### Generic interactive presentation

The TUI presents one node pane or the action list at a time. Enter
`/view <discovered-route>` and use Tab to cycle through every declared node and
the actions. Arrows move list/table selections or choose an action;
Page Up/Down scroll a read-only preview. Document nodes are read-only.
Enter opens an input editor or invokes the selected declared action. Ctrl-S
or Esc stages an edit locally and leaves the editor; staging does not invoke
the Command. Esc outside the editor or Ctrl-C closes an open View.

Plugin labels and status remain separate from Host status. A typed business
control request requires a separate Host confirmation, initially No. It does
not approve a Tool operation; any security approval remains Host-owned.

RPC clients first send `negotiate_protocol` with `protocolVersion: 2`, then
`negotiate_interactions` with `profile: "views-v1"`. `plugin_view` takes a
discovered `routeName` and an `input` object. Its `plugin_view_document` event
contains Host `view_id` and `revision` values. Send those exact values, a
declared `actionId` and actual declared `fields` in `plugin_view_action`.
Command notices arrive as `command_output`; a typed control request instead
produces `plugin_view_confirmation`. `plugin_view_confirm` requires its exact
`viewId`, `revision`, `requestDigest` and an explicit `confirmed` boolean.
`plugin_view_close` closes the identified View.

A large RPC View action can use the existing `rpc_chunk` envelope after both
negotiations. Each physical JSON line remains at most 1 MiB. The six fields
are `type: "rpc_chunk"`, a stable `chunkId`, zero-based contiguous `index`,
stable `count`, the complete JSON request's UTF-8 `byteLength`, and canonical
Base64 `data` for that byte fragment. The complete request must be
`plugin_view_action`. One incoming stream is accepted at a time; conflicting
streams, inconsistent extents and invalid Base64 are rejected. Partial EOF
does not submit an action. The 64 MiB transport ceiling does not waive actual
DATA capacity or field limits: inline inputs remain bounded to 16 KiB and
Host-source inputs to 4 MiB.

Plan review can display a persisted user edit only while its original completed
read-only Tool has an exact canonical Receipt and its package identity still
matches the selected, published Workflow contribution. A process restart or
same-package remount does not replay or reauthorize that historical Tool.
View event identifiers remain bound to the live session and presentation;
replaced or disabled presentations cannot consume an old confirmation.

The [acceptance ledger](../docs/issue-45-draft-status.md) records real-process
proof for the first-party 3 MiB RPC/TUI save and reopen flows (E532), 29 public
lifecycle checks (E536), all seven first-party RPC decisions (E541), and all
nine node kinds through headless, RPC and real PTY presentation (E542).
These working-source results do not complete the final-source physical-wire,
pressure or distribution gates. See also the [Command boundary](../docs/plugin-user-commands.md).
