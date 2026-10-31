# Native component dependencies

Native packages may declare required typed contributions from other installed
native packages. This extends the existing package descriptor and mounted
generation catalog. It does not add an installer, registry, execution service,
permission grant, or automatic dependency activation.

Packages with nonempty `component_dependencies` must set an SDK minimum of
**2.1.0** or later. Older hosts already reject that SDK interval before running
the package, so they cannot silently ignore this requirement. Existing packages
without component dependencies keep their declared SDK compatibility interval.

```json
{
  "id": "consumer",
  "version": "1.0.0",
  "entry_kind": "native-executable",
  "entrypoint": "bin/consumer",
  "sdk_range": "[2.1.0,3.0.0)",
  "protocol_range": "axyndra-js-host-v2",
  "contributions": [{"kind": "command", "name": "check"}],
  "component_dependencies": [{
    "namespace": "axyndra:project-context",
    "version_range": "[1.0.0,2.0.0)",
    "kind": "context_provider",
    "name": "context"
  }]
}
```

Each dependency has exactly those four string fields. `version_range` is a
canonical `[MAJOR.MINOR.PATCH,MAJOR.MINOR.PATCH)` interval for the containing
package; prerelease, wildcard and inferred versions are unsupported. Supported
kinds are Tool, Command, Service, ModelProvider, ContextProvider and
ResourceProvider using their manifest spellings. The contribution must actually
be declared and accepted by the dependency's ready handshake. No Tool is needed
for a command-only or context-only dependency.

The first implementation supports native package namespaces. Pi/npm package
dependencies keep their separate existing meaning; a package cannot declare a
Pi or Codex package as an implicitly executable native dependency. Requirements
are mandatory, unique and limited to 32 per package, graph depth 32 and 256
effective installed packages for resolution of a package with dependencies.
An unrelated package without dependencies does not acquire that graph limit.

`plugin inspect --json` reports the requirements without running code. Import
preserves missing or cyclic packages as disabled, inspectable installations.
Enable checks the existing user/workspace scope selection, explicit user deny,
installed package content locks, versions, contributions, cycles, and enabled
status. Dependencies must be explicitly enabled first. Startup derives a
topological order from the same installed records. Failure quarantines the
affected package while other management operations and unrelated packages remain
available. Diagnostics name the missing, disabled, incompatible or cyclic edge.

Activation captures the actual dependency instances before initialization and
checks those same objects before publishing the new generation. Initialization
failure or dependency replacement cannot publish a partial dependent catalog.
Disabling, uninstalling or replacing a mounted dependency removes the transitive
dependent command/tool/hook registrations and revokes their worker/service/model
handles through the existing cancellation and cleanup owners. Package metadata
remains installed; `enabled` and `active` remain distinct. Dependents require an
explicit enable after dependencies are repaired, even when their persisted
enabled preference was already true. Old frozen executors cannot target that
new instance. History and immutable package versions are retained under the
existing retention rules.

A dependency does not convey its capabilities, configuration, credential refs,
workspace grants or process/network authority to its consumer. All execution
still enters the existing host admission and service interfaces. This field
describes a required lifecycle component; it does not introduce ambient
cross-plugin calls or arbitrary RPC.

Verification is in `PluginComponentDependencyTests` and
`PluginComponentDependencyProductTests`. The Product cases use installed
independent native fixture executables and the actual Product lifecycle,
canonical tool execution, update and restart entries. Before those cases have
actually compiled and run, this document is an interface description only.
