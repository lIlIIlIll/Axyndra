# SDK, manifest, and extension compatibility

Local canonical verification is pinned to Cangjie daily
`1.3.0-alpha.20260831010012` with cjpm `1.3.0-alpha.03`. Hosted workflows resolve the
latest complete official nightly at the start of each run and install its
matching stdx component; the scheduled full release gate runs once per week.
The PR gate is capped at 60 minutes and runs policy checks, a clean type check,
the product build, and focused vNext contracts. Full-workspace tests, black-box
checks, TUI gates, and provider smoke remain release-gate responsibilities.
`scripts/check_sdk.sh` owns the exact compiler check, while package
`cjc-version = "1.1.0"` fields continue to describe language compatibility.
`scripts/pinned_cangjie` derives compiler, runtime, and dynamic stdx paths from
the validated SDK root and never consults a mutable `daily` symlink. Canonical
verification may set
`AXYNDRA_CANONICAL_TARGET_ROOT` to isolate cjpm artifacts by toolchain identity.
Older daily compilers remain unsupported because their test-macro code
generation can crash when enumerating a legal suite containing `@Bench`.

This is the compatibility contract for compile-time cooperative extensions. It
separates version identity, source shape, observable semantics, and security
invariants. A matching range is necessary, but never overrides authorization.

## Independent versions

| Dimension | Owner | Baseline | Meaning |
|---|---|---:|---|
| Manifest schema | `agent_extension_runtime.EXTENSION_MANIFEST_SCHEMA_VERSION` | `1` | JSON syntax and field semantics |
| Agent SDK API | `agent_sdk.AGENT_SDK_VERSION` | `1.1.0` | extension author source and semantic contract |
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
| `[1.0.0, 2.0.0)` | `1.0.0` | compatible |
| `[1.0.0, 2.0.0)` | `1.5.0` | compatible |
| `[1.0.0, 2.0.0)` | `2.0.0` | reject (`SdkTooNew`) |
| `[2.0.0, 3.0.0)` | `1.1.0` | reject (`SdkTooOld`) |

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

Machine-readable surfaces live in `compat/agent-sdk-v1.api.json` and
`compat/axyndra-agent-testkit-v1.api.json`. `scripts/check_sdk_compatibility.py`
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

Workspace Search/Write use stable API and `[1.0.0, 2.0.0)`. AST/Web Search use
experimental `HostOperationIntent`, so their lockstep built-in range is
`[1.1.0, 1.2.0)`.

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

## Compatibility scope

P2.5 supports source/API compatibility for frozen consumers, manifest
compatibility, and semantic/security compatibility. Extensions are rebuilt
against a compatible SDK. Precompiled binary ABI compatibility is **not yet
guaranteed** by the compile-time package model or these gates.
