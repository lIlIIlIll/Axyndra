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

## Persisted state and inspection

The current SQLite format is **schema v28**. It is independent of the Native
wire SDK version and author-source package versions above. Migration v28 moves
nonempty legacy Todo/Goal bytes into namespaced `plugin_documents` in the same
transaction as the schema version change; unsupported historical payloads
remain data, not executable plugin configuration or authorization. The old
metadata columns are a read-only archive, not a second write owner.

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
