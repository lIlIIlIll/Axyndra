# Installed workflow roles and Task proposals

The operator selects an installed `ResourceProvider` contribution in
`plugins/policies.json` under `bindings.workflow`, with its namespace, provider
name and package digest. The bundled Workflow package exposes `propose` and uses
`axyndra.workflow-policy/v1`. A missing, disabled, replaced or wrongly pinned
provider returns a diagnostic; the Host does not retain a named role catalogue
or substitute an implementation.

Role names, descriptions, prompts, requested capability ceilings, blocking
preferences and requested resource limits are plugin data. Task argument
normalization and its batch business rules are also plugin implementation.
Returned data never grants an operation, Run or capability. The Host intersects
capabilities with the actual parent, retains its cumulative budget and preserves
its model, context and lane snapshots. It checks the selected package generation
again before creating an actual child Run through the existing scheduler.

A running child uses its frozen admitted role data. Settling an existing
approval, reading its transcript or delivering a message to an active child does
not require the original provider to remain available. Starting a fresh Run for
a finished child resolves and pins the current provider; a lookup failure does
not rewrite the old child's status or discard a durable message.

Persisted `agentSource` records the selected package digest, contribution,
generation and operator configuration digest for inspection. It is descriptive
data, never a reconstructed authority or a live provider pin. Older task
snapshots omit this optional field and retain their historical `bundled` label.
The existing restart rule still marks unfinished children `recovery_required`.

Validation authored here includes native package tests and seven actual Product
cases. Compiler/runtime results must be recorded separately; these are not
claims of completed execution. The default fixture/release assembly and old
Task/Hub tool, Todo/Goal/Planning command and persistence migration remain
separate required parts of A5-03. This change alone does not complete A5-03.
