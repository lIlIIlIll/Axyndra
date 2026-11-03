# ADR 0004: Plugin-owned capabilities and one execution authority

- Status: Accepted design; migration incomplete
- Date: 2026-10-04
- Scope: [Epic #45](https://github.com/lIlIIlIll/Axyndra/issues/45)
- Baseline: `4d88fa6072f7176a6d236a1cb39b33529d5b609d` (#43)

## Context

The product already imports locked packages, isolates executable JavaScript,
brokers controlled services, persists derived Operations and Receipts, and applies
approved file plans. These are reusable authorities, not proof that existing
capabilities are independently installable plugins. The product still links MCP,
Skills, provider adapters, LSP/DAP and compiled first-party extensions. Its
`ProductExtensionOperationHost` executes workspace, AST and web-search business
operations. A directory move or registration wrapper cannot remove that coupling.

## Decision

### Package, instance and contribution

A package is the immutable source/version/content/dependency installation unit.
An instance is the supervised execution unit bound to that package version,
workspace, Thread and authorization domain. A contribution is a typed, versioned
Tool, Command/View, ContextProvider, ResourceProvider, ModelProvider,
ManagedService or finite event/policy declaration. Package installation,
component enablement, granted authority, activation and health are separate facts.
Zero tools is valid; an unsupported required contribution fails with a diagnostic.
Namespace collisions, required dependency cycles and incompatible protocol major
versions fail before publishing any registration.

The native path is an independent executable over bounded, versioned process IPC.
JS/TS ecosystem adapters use the same supervisor, contribution ownership and
controlled service rules. Evolve the existing extension runtime and JS host
facilities rather than introducing another registry or model loop. The initial
native implementation can share the existing tool/command wire subset; that
does not establish support for the other contribution types. Cangjie object
layout, exceptions and generics are not a cross-process ABI.
The implemented subset is documented separately in the
[process plugin protocol](../plugin-process-protocol.md).

### Execution and controlled services

Plugin endpoints own algorithms and protocol clients. Host code owns call-source
validation, normalized input/schema checking, preparation, policy/approval,
durable execution handoff, cancellation, resource settlement, and canonical
Operation/Receipt/result commit. New endpoints using existing services must not
require a new product operation-name branch or recompiling the host.

Services expose bounded file reads, validated atomic changes, controlled process
and network operations, destination/purpose-scoped credential references,
artifacts, namespace-local state, interaction and admitted child execution.
They never expose a database connection, raw capability object or unrestricted
service locator. Existing scheduling and parent budgets remain authoritative,
including when the concurrency limit is one. Preparation receives only its
explicit read allowance; it cannot acquire execution authority by declaring an
operation read-only.

Connection identity binds package/version/instance/generation. Payload fields do
not establish Run, epoch or Operation ownership. Authorization binds invocation,
normalized arguments, resources, phase, expiry and generation; terminal states,
cancellation and revocation invalidate it. Background services need separately
admitted, revocable service authority. Calls from model decisions, external
principals, user commands, maintenance and admitted children retain their true
origins. Never synthesize a ModelDecision or CommittedToolCallRef for maintenance.

Bounded progress, interaction and suspended tasks need host-owned durable
correlation and recovery. Process memory and remote task IDs are not recovery
proof. Crashes after possible external effects preserve an unknown outcome;
restarting a process must not blindly replay effects. The existing canonical
state and receipt owners remain the only authorities.

### Isolation and package trust

Independent processes must also be isolated during initialization, preparation,
callbacks, timers and background work. The existing fail-closed sandbox launcher
is the starting boundary. Missing isolation blocks activation. A checksum proves
identity, not permission; enabling a package does not grant file, process,
network or secret access. Signatures are an independent authenticity policy:
if a signature is declared it must be verified by a configured trusted verifier;
an unsigned package may be admitted by explicit local enablement and the same
isolation rules. Neither signed nor first-party packages gain ambient authority.

### Dynamic state and model authority

An admitted call pins package content, contribution schema, instance generation,
catalog/context version and granted plan. Publication stages a complete catalog
transaction before commit. Ordinary upgrades affect the defined next boundary;
they do not retarget in-flight calls. Security revocation invalidates authority
immediately, independently of catalog visibility. Old versions referenced by
Attempts, prepared Operations or retained history remain available for inspection
and cannot be overwritten or collected. Missing executable content blocks resume
without preventing supported history inspection. Fork shares immutable facts,
not mutable plugin processes or permissions.

Context contributions enter the existing trust/budget/version/final-assembly
pipeline. ModelProvider plugins own wire adaptation and model discovery; the
host retains Attempt ownership, frozen input, actual request counting, retries,
fallback, cancellation and usage validation. Plugins cannot hide their own agent
loop or retry policy behind a provider call.

### Bootstrap, data and distributions

Plugin maintenance must be available without Shell, MCP, JavaScript runtimes,
model plugins, credentials or network access for local operations. Remote
acquisition uses admitted generic maintenance services, exact source locks,
staging, integrity checks and atomic activation; package scripts do not run by
default. Rollback does not resurrect revoked grants. User/admin explicit denials
cannot be replaced by workspace configuration.

Minimal, Coding and Full are manifests selecting independently delivered plugin
artifacts. Bundled, enabled-by-default and core-required are separate fields.
Minimal can start, show static help, manage plugins and inspect history with no
optional capabilities. Missing model capability is reported when inference is
requested. Coding bundles removable Workspace, Shell and model implementations;
Full adds the tested optional set. First-party plugins use the public contract.

SDK/configuration/storage breaking changes are permitted. Each migration records
its source/target version, backup, interrupt/recovery behavior and write refusal
for unsupported data. No implicit destructive reset, indefinite dual state store
or old privileged HostOperationIntent bridge is permitted. Database rollback,
plugin rollback and binary rollback are distinct operations with separately
tested compatibility. This ADR does not change the existing schema itself.

## Relationship to previous decisions

- #34/#35/#36/#43: reuse package inspection/acquisition, isolation, controlled
  services, derived admission, plan application and evidence. Their completed
  results are not reset; first-party implementation externalization is additional
  work. ADR 0001's use of the built-in MCP runtime is a migration baseline,
  superseded by the target here, not a permanent compatibility requirement.
- #39: one context-event/version/catalog authority remains. Safe dynamic
  visibility changes and ordinary package upgrades are different boundaries.
- #44: one model loop/Attempt/retry authority remains. Do not duplicate it in
  provider plugins.
- #31: independent artifacts declare supported platform/toolchain profiles.
  Development machine paths are not release requirements.
- ADR 0002 and ADR 0003 continue to own derived admission and exact file-plan
  authority; this design does not broaden writable PTC or replace those owners.

## Enforcement and rollout

The [migration baseline](../plugin-first-migration.md) records existing paths,
phase evidence and gaps. The dependency gate examines manifest edges, local
path aliases, target-specific dependencies, production imports and transitive
reachability. Its default mode prevents additional known capability coupling;
its strict Minimal mode permits no such dependency. A passing ratchet is not a
passing Minimal gate. Source inspection cannot prove an artifact omits copied or
renamed business code: release additionally requires a clean isolated build with
optional source trees absent, artifact/link inventory and execution from the
installed package without a checkout.

Each phase must remove the replaced production path and demonstrate its real
success/failure entrypoints. Interface definitions, mocks, manifests and this
decision alone cannot complete a migration phase or close the Epic.
