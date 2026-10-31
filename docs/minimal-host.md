# Minimal plugin host

The default packaged artifact uses the separate `agent_minimal` executable with
no bundled or default-enabled optional plugins. It shares the existing registry,
Core, Runtime, canonical Tool pipeline, Store and Host lifecycle owners. Its
neutral ModelProvider contract does not include vendor adapters or provider wire
implementations. Explicit Coding and Full packages use `agent_app`; see
[distribution profiles](distribution-profiles.md).

## Commands and operator configuration

```sh
axyndra --help
axyndra --settings-root /settings --workspace-root /workspace plugin list
axyndra --settings-root /settings --workspace-root /workspace plugin inspect /package
axyndra --settings-root /settings --workspace-root /workspace plugin install /package user
axyndra --settings-root /settings --workspace-root /workspace plugin enable namespace user
axyndra --settings-root /settings --workspace-root /workspace plugin update namespace /new-package user
axyndra --settings-root /settings --workspace-root /workspace plugin rollback namespace user
axyndra --settings-root /settings --workspace-root /workspace plugin disable namespace user
axyndra --settings-root /settings --workspace-root /workspace plugin uninstall namespace user
axyndra --settings-root /settings --workspace-root /workspace plugin doctor
axyndra --settings-root /settings --workspace-root /workspace plugin gc
axyndra history latest /state/state.db thread-id
axyndra history inspect /state/state.db thread-id run-id 0 25
```

Install/update accept local package directories; `workspace` can replace `user`.
Installation records a package disabled. Enabling records operator intent without
executing its code. Existing user-disable precedence, staging, content identity,
version history and retained-package GC apply. This CLI has no remote-acquisition
command. Registry API 2.0 serializes all management writers with Linux x86_64
kernel-released locks and reloads durable state before each mutation. Busy or
interrupted workspace publications fail closed; see [registry writer boundaries](registry-process-writers.md).
Installed executions additionally use the same Registry's retained descriptor and
short shared-lock admission pin; see [execution freshness](registry-execution-freshness.md).
This does not yet establish cross-process freshness for an already-running host's
cached execution grants.

Runtime commands additionally require explicit `--state-root`:

```sh
axyndra --settings-root /settings --workspace-root /workspace --state-root /state tools thread-id
axyndra --settings-root /settings --workspace-root /workspace --state-root /state invoke thread-id plugin.namespace.tool '{}'
axyndra --settings-root /settings --workspace-root /workspace --state-root /state infer thread-id namespace contribution mapped-model 'prompt'
axyndra --settings-root /settings --workspace-root /workspace --state-root /state service thread-id namespace service-id route approve '[]'
axyndra --settings-root /settings --workspace-root /workspace --state-root /state serve operator-grant-id
```

These are syntax examples, not implicit grants. Invoking an installed contribution
uses the same canonical Run/Call/Receipt and captured owner as the trusted Host.
Inference requires an actual installed ModelProvider and operator model mapping;
an absent provider or invalid mapping returns a typed diagnostic. Service startup
uses the real maintenance manager, configured route and explicit operator decision.
`serve` uses `plugins/ingress.json`; optional bounded service-start requests must
also carry explicit decisions. No package manifest, approval string or historical
record can manufacture service/model authority.

`--grant <capability[:resource]>` is repeatable. Runtime defaults to `always-ask`;
`--approval-mode write|yolo` is an explicit operator choice. Timeouts remain
1..120000 ms, tool budgets 1..32, and tools execute serially. `--ca-bundle` names an
operator file and does not select credentials. Native services need their declared
isolation/runtime dependencies; executable JS/Pi contributions need a supported
JavaScript runtime. Local package management and read-only history do not run them.

History uses `SQLITE_OPEN_READONLY`, `query_only=ON` and a bounded busy timeout. It
neither creates a missing DB nor migrates schemas or changes journal mode. It reads
live WAL rather than using SQLite immutable-file mode. Incompatible historical
columns return an inspection error without rewriting them; ordinary WAL sidecars
may still be accessed. See [migration/rollback boundaries](architecture.md#schema-v28-evolution-and-rollback-boundary).

## Independent source/build and portable package

```sh
python3 scripts/minimal_host_source_test.py -v
python3 scripts/minimal_host_gate.py --root "$PWD" --output /work/minimal-verification-1
AXYNDRA_DISTRIBUTION=minimal scripts/package_candidate.sh
```

Build the separate host before packaging. The materializer follows actual local
manifests, excludes caches and optional business roots, and rejects escapes and
forbidden imports. The current local package set is eighteen: `agent_minimal`,
`agent_plugin_registry`, `agent_history`, `agent_extension_runtime`, `agent_sdk`,
`agent_app_protocol`, `agent_domain`, `agent_ports`, `agent_runtime`, `agent_store`,
`agent_host_runtime`, `agent_core`, `tool_runtime`, `persistence_runtime`,
`model_provider_runtime`, `process4cj`, `sandbox4cj` and `yjson_support`, plus the
pinned external JSON dependency. The provider contract is neutral; Product, vendor
model adapters, Shell, MCP, Skills, LSP, DAP and native plugin business packages are
forbidden in this source closure. Generic native process primitives remain.

The gate derives exact unit inventory from materialized source and preserves all
required original cases: currently nineteen Registry plus four History units. It
also requires nine CLI checks and fifteen source
boundary cases, then records source/lock/binary/loader evidence. The shared-runtime
acceptance additionally has twenty neutral model units and independent Runtime10,
Model10, Service10 and two terminal-cancellation negatives. Current Domain, Store
and Core inventories are tracked separately when those packages change. A source
copy or case enumeration is never an actual test pass.

`minimal_host_gate.py` produces a build tree, not a portable bundle. Packaging
copies the declared Cangjie/StdX/native runtime closure, checks the loader and binds
source/output bytes in `package-provenance.json`. Prior Linux source102 relocation
and source124 runtime gates have actual scoped evidence; subsequent source changes
need current source/package guards and actual acceptance. A clean environment is
not itself proof of network denial or a no-Node matrix. Current Coding/Full,
cross-platform, complete backup/rollback and final release acceptance are separate.
