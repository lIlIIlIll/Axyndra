# Independent Skills provider

This native package owns SKILL.md discovery, frontmatter parsing, deterministic
metadata routing, explicit marker matching and declared reference loading. Its
only contributions are ContextProvider `skills` and ResourceProvider `reference`.
It declares no tools or host service permissions. The existing supervisor supplies
the package-only, network-denied sandbox; all returned text is untrusted data.

Build with `./build-package.sh --output NEW_PACKAGE --content-root SKILL_DIRECTORY`.
The content root is copied into the immutable package, accepts only regular UTF-8
files, and has finite file, byte and depth limits. Omit it for an empty provider.
Runtime dependencies and notices are bundled using the same checked closure as
the other independent Cangjie plugins. Python/patchelf are packaging dependencies,
not runtime interpreters. No SDK path is part of the package contract.

Resolve query: `{"schema":"axyndra.skills-query/v1","action":"resolve","prompt":"$review"}`.
An optional `selected` array overrides routing, including an explicit empty list.
Catalog query: `{"schema":"axyndra.skills-query/v1","action":"catalog"}`.
Resource queries use the generic resource schema and only accept exact reference
IDs declared by a packaged Skill. No query field opens a filesystem root.

The generic host can supply `_axyndra_context_read` data observed by a real
canonical read in the existing Run. `resource_roots` contains logical paths in
that immutable snapshot, in precedence order; later roots override earlier
roots and packaged content on the existing Skill id/name collision rules.
For example, a host can select user roots followed by workspace roots. Runtime
and Store validate the actual read Item, handoff, successful Receipt and output
digest before a Context update consumes it. Optional absent roots are explicit
verified absence records, never permission errors silently treated as empty.

References from observed data are returned as `{id,content}` and frozen into the
same untrusted Context snapshot. They remain inspectable after the source file
changes or the plugin is disabled. Packaged references keep the existing lazy,
version-bound ResourceProvider locator.

The host assigns trust and ownership, freezes the InvocationContextProjection,
escapes markup and commits context versions. This package cannot alter authority,
activate itself, create model decisions or run Skill instructions as commands.
Independent package versions pin instruction and reference bytes in locators.

Current increment: package content and explicit canonical resource snapshots.
Without a negotiated `content_payload_limits` offer, the existing 64 KiB query /
192 KiB response remain unchanged. A recognized offer is echoed exactly in
`ready`; the pure Context/Resource routes then reuse the shared logical JSON
protocol with a 4,456,448-byte query ceiling and a 4 MiB result ceiling. These
bounds derive from one existing 4 MiB canonical ContextRead fact, the existing
192 KiB query, and 64 KiB of envelope space. The resulting Context projection
still has to fit its existing 4 MiB durable codec; per-Skill file limits remain.
The profile grants no services, filesystem access, Run or Operation authority.
Every query keeps its original 5-second pure deadline, full invocation identity
and fixed transfer window, including the result sender. Physical and logical
JSON allocations share one finite 128 MiB pool and lexical node bound.
The generic same-Run read continuation, safe cut and logical profile are
implemented as candidates; actual Product validation is pending. Automatic
startup selection/Application controls plus old Skill dependency removal remain open.
The old production Skill path remains until those parity checks pass.
Protocol tests prove a real package process; separate Product tests are required
for registry, sandbox, durable context and disable behavior. This candidate is
uncompiled until evidence is recorded by the build owner.

Managed Skill policy accepts `axyndra.managed-skill-policy/v1` through the pure
ContextProvider. `normalize` returns bounded names and canonical input;
`evaluate` consumes copied existence observations and proposes unchanged YAML
bytes or directory removal. The package has no mutation capability or Tool.
The result is advisory data, never a grant, file identity, approval or Receipt.
The real Host file-operation adapter and retirement of the old manage_skill /
learn(skill) writers remain pending; this query alone is not A5-01 completion.
Eight additional protocol cases are authored for name/path rejection, conflict
precedence, legacy update/delete behavior, exact UTF-8/YAML capacity and a
64,000-byte NUL result above the physical frame limit. They have not run yet.
