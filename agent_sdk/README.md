# agent_sdk

The supported source-authoring package is version **3.0.0**. It contains
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
