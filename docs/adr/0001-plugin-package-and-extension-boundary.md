# ADR 0001: Plugin package and extension boundary

- Status: Accepted
- Date: 2026-09-17

## Context

Axyndra imports pi and Codex packages containing declarative resources and executable extensions. Importing a package must not run its code, and compatibility must not create a second authority for tools, approvals, networking, execution, or durable state. Package installation, component discovery, activation, and a successful extension call are separate outcomes.

The package descriptor/lock, versioned Node host protocol, and product sandbox launcher are implemented. Product activation builds a fail-closed Linux WorkspaceSandbox plan with a read-only package root, isolated process and network namespaces, filtered environment, and resource limits. A product contract test disables Node permission flags and verifies that package-root writes and connection to a host-loopback listener are denied by the OS boundary. This is Linux execution evidence, not proof of other platforms or per-Thread isolation.

## Decision

1. Normalize each imported package into a host-owned record containing stable identity, ecosystem, source and exact version, content digest, compatibility profile, component declarations, and diagnostics. A package declaration is descriptive only; it cannot grant capabilities, approval, trust, or a sandbox exception.
2. Inspect/import is static and bounded. It does not evaluate modules, run hooks, or invoke package lifecycle scripts. Normal local installation stages an immutable content snapshot, validates its tree and digest, then atomically activates the new record. A failed update leaves the previous active snapshot intact. Explicit live-development sources are a separate mode and are fingerprinted before each new activation; active runs retain their selected snapshot.
3. Component state is independent: installation, enablement, host authorization, compatibility, and runtime health are distinct. Disabled or unsupported components remain visible in diagnostics and cannot start merely because another component is enabled.
4. Skills and prompt resources use the existing Skill and prompt lifecycles; MCP declarations use the existing MCP runtime and ToolPipeline. Contributions retain package/version identity. Existing policy, prepared execution, approval, receipts, cancellation, and network decisions remain authoritative.
5. Executable JavaScript is an optional, long-lived process boundary, not the product kernel. Its initial compatibility profile is a declared pi tool-extension subset on a tested Node runtime. The product must launch initialization and callbacks only inside a fail-closed `WorkspaceSandbox` profile: read-only fixed package snapshot, denied network, isolated process namespace, controlled environment and resource limits. Node permission flags are defense in depth, not the OS boundary. If that profile is unavailable, activation fails with a diagnostic; there is no direct-launch fallback.
6. The extension process receives only versioned, bounded IPC and a narrow host API. Host services are mediated by the product and existing authorization path. Process generations and package snapshots are fixed for each active registration. An unsupported API is rejected or reported; it is not represented by a successful no-op.
7. Hooks, commands, UI interactions, writable execution, and arbitrary pi/Codex APIs are unsupported until each has a typed contract, an explicit compatibility profile, lifecycle semantics, and black-box acceptance evidence.

## Consequences

- Skills-only and MCP-only use does not require Node, start an extension process, or initiate network access for package management.
- Package import can succeed while one or more components are unsupported or disabled; reports must preserve those distinctions.
- Immutable managed snapshots, per-component state, and fixed remote source resolution remain unmet release requirements. The sandboxed product launcher is implemented and tested on Linux, but that result does not imply cross-platform support, per-Thread process isolation, or package snapshot integrity.
- Product activation uses the sandboxed launcher and fails closed when the configured boundary is unavailable. The runtime requires an injected process launcher; only support fixtures inject an unconfined test launcher.
- pi/Codex compatibility is reported per package version, component, profile, and tested platform; it is never inferred from installation or module loading alone.

## Compatibility reference

The pinned Pi and Codex source baselines, field precedence, API matrix, and current support status are recorded in [the compatibility matrix](../compatibility.md#pi-and-codex-package-compatibility).
