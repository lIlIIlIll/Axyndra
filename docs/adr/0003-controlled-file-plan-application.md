# ADR 0003: Controlled file-plan application contract

- Status: Accepted

A read-only Tool Program must be able to propose workspace changes without
receiving write authority. E5 therefore separates an immutable host-stored plan,
an explicit canonical apply request, and ToolPipeline authorization. This ADR
fixes the implemented v1 contract. Executable evidence lives in
`product_thread_runtime_contract`, `product_contract`, the real frontend
coverage runner, and the issue-36 fault matrix.

## Decision

1. **Separate proposal, intent, and authorization.** Plan generation runs under
the existing read-only Program boundary and has no workspace-write, Shell, or
network-write authority. It may persist a validated plan and patch artifact,
but it does not mutate the workspace or admit `apply_file_plan` as a derived
Program call. After plan generation, a user action or model may request
application only through a separate direct/root canonical `apply_file_plan`
ToolCall naming one immutable plan and its digest. This records intent, not
permission. The call must pass the existing prepared-only ToolPipeline, current
capability policy, and any required approval. The front end, model, artifact
reference, and digest are not execution authorities.

2. **Limit v1 effects to text-file creation and replacement.** The only
operations are `create` of an absent regular-file path and `replace` of an
existing regular UTF-8 text file. Both write the complete resulting file
content. Hunks, deletes, renames, directory creation, symlink changes,
permission/ownership/ACL changes, binary content, and arbitrary paths are
unsupported. Parent directories must already exist. Paths are canonical
workspace-relative paths using `/`; reject POSIX or foreign-platform absolute
paths, URI paths, empty paths, `.` or `..` components, non-canonical spellings,
and NUL. Resolution must remain under the bound workspace without traversing
symlinks. Reject sensitive or non-regular targets. A new file uses the host's
normal file-creation policy; a plan cannot request file metadata. Existing direct
tools keep their own contracts; this ADR does not expand their authority or admit
arbitrary Shell, process, or network writes into plan application.

3. **Persist an immutable, versioned plan and exact payload artifact.** The host
creates the plan from validated read-only Program output and stores both plan
and payload through the existing content-addressed artifact store. They are
evidence, not a second Operation/Receipt or approval ledger. The logical
schema is:

   ```text
   FileApplicationPlanV1 {
     schema: "axyndra.file-application-plan/v1"
     workspace_id: HostWorkspaceId
     source: {
       root_operation_id: OperationId
       program_id: String
       program_digest: SHA256
     }
     patch_artifact: { ref: ArtifactReference, sha256: SHA256, bytes: Int64 }
     operations: Array<{
       ordinal: UInt32
       kind: "create" | "replace"
       path: WorkspaceRelativePath
       precondition:
         { state: "absent" }
         | { state: "regular_file", sha256: SHA256, bytes: Int64 }
       content: { encoding: "utf-8", sha256: SHA256, bytes: Int64 }
     }>
     preview: { format: "unified_diff", text: String, truncated: Bool }
   }

   FilePatchArtifactV1 {
     schema: "axyndra.file-patch/v1"
     operations: Array<{ ordinal: UInt32, utf8_content: String }>
   }
   ```

The host stores the plan itself as an immutable artifact and returns its
`plan_ref` and `plan_digest` separately; the digest is SHA-256 of the exact
serialized plan bytes, not a self-referential field. Payload entries contain
one complete after-content per operation ordinal. Ordinals are unique, ordered,
and map one-to-one to plan operations. Reject empty plans, duplicate or
ancestor-conflicting targets, unknown schema versions/operations, missing or
duplicate payloads, malformed paths, inconsistent byte counts/digests, and
host-limit violations. File digests cover exact UTF-8 bytes; the plan digest
commits to the patch reference and every target, precondition, and output
digest. The preview is display-only, generated from the bound before/after
contents, bounded by host limits, and explicitly marks truncation. The
operation table remains complete and gives every target, action, before state,
output digest, and byte count. A truncated preview must never be presented as
a complete diff review.

4. **Bind authorization to the complete prepared application.**
`apply_file_plan` accepts only `plan_ref` and expected `plan_digest`; callers
cannot supply replacement paths or content. Preparation loads the immutable
plan and payload, verifies their digests and source/workspace binding, validates
every target, and compares current file state with the frozen preconditions
before requesting approval. It freezes the expanded operation list, preconditions,
payload digests, tool identity, and exact per-target `workspace.write`
requirements in the normalized invocation plan. Capability evaluation and any
approval use that same plan. Immediately before handoff, compare the current
immutable tool descriptor, specification, and implementation identity with the
stored plan and enforce the current capability ceiling without refilling defaults
or adapting the plan. Approval is bound to the canonical apply Operation and plan
digest, covers the complete target/content summary, and cannot add capabilities.
A stale precondition is a conflict, not a rebase or a new authorization for the
old plan. A changed plan or workspace requires a new canonical call and applicable
authorization; any tool-identity mismatch invalidates the prepared application.
An identical canonical reissue follows existing Operation/Receipt and
approval-reuse rules and must not launch a second executor. Plan identity or
user/model intent alone never authorizes a write.

5. **Treat stale resources as conflicts; expose partial effects.** Before the
first write, validate the entire plan and all targets. If any precondition is
stale, return a conflict with no changes. Immediately before each publish,
re-resolve the path and enforce its expected state; do not rebase, merge, or
overwrite a changed target. The executor must guard the check-to-publish
interval against concurrent replacement; if it cannot do so safely, it fails
closed. Each file publish must be atomic or safely equivalent, but a multi-file
plan is not a filesystem transaction. Apply in ordinal order and stop on the
first conflict, failure, or cancellation. Persist per-operation outcomes
`applied`, `conflict`, `not_started`, `failed_no_effect`, or `unknown` in the
canonical Operation result. The result separates effect from stop reason:
`complete` means all items were applied and verified; `no_effect` means no item
changed; `partial` means at least one item changed and another did not;
`unknown` means an attempted effect lacks a durable, verified outcome. Record
whether processing stopped for completion, conflict, failure, cancellation, or
an unknown effect. Never automatically roll back, retry an unknown effect, or
continue after a failure. Recovery reconciles actual file state; compensation
or continuation is a new plan and a new authorized Operation. A conditional
exchange whose post-publication identity or content check fails is `unknown`.
Retain the displaced file at the staging path and report its recovery path;
do not exchange pathnames again or delete potentially displaced editor data.

## Consequences

- Plan generation, intent confirmation, and security authorization are distinct
  observable stages. User confirmation does not replace host policy or approval.
- Stale plans fail rather than silently adapting to workspace state. Multi-file
  outcomes are explicit but are not all-or-nothing.
- The implementation reuses workspace mutation primitives only behind this
  contract; no Shell, LSP edit, or direct frontend path substitutes for the
  canonical apply ToolCall. The artifact, application call, race-safe executor,
  recovery projection, and user workflow are part of the supported v1 boundary.

## Related scope decisions

**Writable nested PTC is deferred.** A Program remains read-only and may only
propose the immutable plan described above. A separate root `apply_file_plan`
Operation owns every write. The current scheduler does not persist an
interpreter stack or arbitrary write-step checkpoints, and arbitrary nested
writes do not have the idempotency, compensation, approval reconciliation, and
crash-recovery contract required for safe resume. This scope may be reconsidered
only after typed durable steps, a resumable scheduler, exact child approval
reconciliation, compensation semantics, and process-crash fault coverage exist.

**External Agent execution is deferred.** The product has no versioned external
Agent protocol for delegated identity, allowed tools, process-tree cancellation,
usage attribution, recovery, or inspection. Therefore an external Agent answer
cannot be represented as an internal canonical Receipt. A future design must
define and test that protocol and preserve the same Operation, capability,
approval, cancellation, budget, and inspection invariants. This decision does
not replace or relax the existing extension and embedded-SDK contracts.
