# Execute an approved plan

Plan review approves both the proposed work and its execution contract. The
runtime checks each controlled action against that contract before dispatch and
uses canonical Operation receipts to determine progress.

## Review the contract

Enter Plan mode and ask the agent to record its plan with the published Native
workflow plan tool. Open
`/plan-review` to inspect the prose, the structured contract, tool implementation
pins, and review advisories. Approval hashes cover the complete reviewed document.
Editing prose or contract requires renewed approval. A prose-only edit retains
the existing contract so you can review the new document together.

To revise an unfinished plan, enter `/plan` again. This creates a read-only
review request with discovery tools and `plan_write`. The previous execution and
spent attempts remain intact until you explicitly approve the replacement.

An action declares its tool names, network modes, side-effect ceiling, argument
constraints, attempt budget, and evidence requirement. Attempts are shared across
Runs; changing a URL, tool-call ID, or child session does not restore them.
Fallback steps are explicit. Independent steps may continue after a known safe
failure; unknown effects require reconciliation.

For example, a minimal offline discovery contract can contain:

```json
{
  "schema_version": 1,
  "target_roots": ["/workspace/project"],
  "participating_repositories": [],
  "steps": [{
    "id": "discover",
    "dependencies": [],
    "required": true,
    "actions": [{
      "id": "list-files",
      "tools": ["command_probe"],
      "network_modes": ["denied"],
      "effect_ceiling": "read_only",
      "argument_constraints": {
        "executable": "/usr/bin/ls",
        "argv": ["-1"],
        "cwd": "/workspace/project",
        "readonly_workspace": true
      },
      "exact_arguments": true,
      "max_attempts": 1,
      "evidence": "exit_zero",
      "artifact_digest": ""
    }],
    "fallback_step_id": null
  }]
}
```

Replace the example target with the actual project root. The host adds
`tool_identities` before displaying and hashing the contract. Existing pins cannot
silently change when a tool implementation changes.

`target_roots` bound mutations. `participating_repositories` allow declared
read-only repository participation and its instructions; they do not grant write
access. These context choices do not grant filesystem or network capabilities.
The normal authorization checks still apply.

## Execute controlled actions

The controlled host `command_probe` includes `_plan` with its approved
`step_id` and `action_id`. This transport metadata is removed from canonical
arguments. Verified Native tools retain their original schema and identity;
the runtime selects an action only when the fully canonicalized call matches
exactly one runnable approved action. Zero or multiple matches are rejected.
Both paths enforce pinned descriptors, dependencies, capabilities, argument
constraints, and the same shared attempt budget.

The existing Native Shell uses a persistent channel whose broad startup scope
cannot prove per-action write limits. It remains unavailable to supervised
plans. Ordinary Native Shell behavior is unchanged. Use the owned one-shot
`command_probe` for approved process actions, including offline source writes
and verification, or a supported network action. It accepts an executable, argument list, optional
working directory, integer timeout in seconds, and network policy. Networked
probes require exact approved arguments and the restricted supported command
forms; arbitrary networked shell wrappers are rejected.

The runtime carries approved write roots into the process sandbox. The workspace
is read-only outside those roots; changing `cwd` does not expand them. These
roots must still fit within the existing workspace and capability limits.
Supervised probes cannot detach work with asynchronous or PTY options.

The supported network adapters suppress ambient curl and npm configuration.
An npm install requires an empty approved directory as its explicit `cwd`;
declare that directory as the installation prefix in the reviewed action.
Registry package specifications exclude Git, local paths, and tarballs.

For offline verification, set `readonly_workspace: true`. The runtime enforces
read-only workspace mounts. This lets multiple successful checks remain current
without treating each verifier as a new source mutation. A writable process may
change source and invalidates earlier verification evidence conservatively.

Probe results distinguish target startup, target completion, exit status, and
runtime timeout. Target stdout cannot assert these facts. In particular, a target
that exits with status 124 has not necessarily timed out. Missing or malformed
trusted probe receipts require recovery.

A `task` action also declares `delegated_action_ids`. Child and nested child
Runs inherit the same execution and budgets, restricted to the permitted action
subset. Tools without a trusted execution descriptor cannot enter this flow.
Supervised task calls wait for their child work, including when ordinary tasks
are configured for asynchronous execution. Accepting background work is not
completion evidence.

## Inspect and recover

Use `/inspect` to see the approved execution, step states, action attempts,
remaining budgets, and decisions backed by receipts. Inspection also shows the
request-visible tool set and instruction selection evidence. A reconstructed
request dump is separate from a historical sealed ContextManifest.

For in-process integrations, use
`withPlanExecutionInspectionForSession204(sessionId, consume)` to inspect a plan
within the borrowing callback. Do not retain the borrowed graph after that
callback; retained copies require their own allocation from the original DATA
bank. The legacy graph-returning inspection method refuses supervised reads.
A `runInspection` page retains its plan projection until the consumer calls
`returnPlanProjectionAfterConsumption204()` after its complete rendering or
serialization frame returns. The application and minimal CLI perform this
acknowledgement themselves. Reading the plan projection after retirement fails.

Required evidence must pass before the owning plan can complete. Model text,
an exhausted Run budget, or an old successful test does not satisfy that guard.
Cancellation, policy denial, revoked capabilities, and unknown effects retain
their existing stop and recovery semantics.

After restart, the runtime reads existing Operations and receipts before deriving
step progress. It does not repeat tools to rebuild the projection. A text-only
historical plan or conversation import does not recreate approval authority;
record a structured contract and review it first.

Review advisories identify known risks, including rotation units and stale async
callbacks. They are not executed evidence or a proof of arbitrary mathematics.
Required executable checks run after approval through normal Operation admission.

Back up the database and referenced artifact blobs before upgrading. See
[schema evolution and rollback](architecture.md#schema-v29-evolution-and-rollback-boundary)
and the [implementation evidence record](implementation/plan-execution-reliability.md).
