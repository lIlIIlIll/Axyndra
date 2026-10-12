package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import std.collection.*
import yjson.*
import yjson_support.*

// Called only inside the existing Thread transition transaction. All witnesses
// are reread here; the caller's in-memory safe-cut assertion is insufficient.
func commitModelLaneSafeCut(transaction: SqliteTransaction, transition: ThreadTransition): Unit {
    let change = transition.modelLaneChange.getOrThrow()
    let before = transition.before
    let run = before.activeRunId.getOrThrow()
    let turn = before.thread.activeTurnId.getOrThrow()
    validateModelLaneChange(change, before.thread.id)
    let previous = encodeStoredValue(modelLaneSnapshotValue(change.previousLane()))
    let next = encodeStoredValue(modelLaneSnapshotValue(change.nextLane()))
    let ownership = transaction.query("SELECT r.lane_snapshot,r.skill_snapshot FROM runs r " +
        "JOIN turns turn ON turn.id=r.turn_id JOIN threads t ON t.id=r.thread_id " +
        "JOIN items initiator ON initiator.id=turn.user_item_id " +
        "WHERE r.id=? AND r.thread_id=? AND r.turn_id=? AND r.epoch=? AND r.state='running' " +
        "AND r.finished_at_millis IS NULL AND turn.state='active' AND turn.active_run_id=r.id " +
        "AND t.active_turn_id=turn.id",
        [SqlParameter.Text(run.value), SqlParameter.Text(before.thread.id.value),
            SqlParameter.Text(turn.value), SqlParameter.Int64Value(before.activeEpoch)])
    if (ownership.size != 1 || ownership[0].required(0) != previous) {
        throw IllegalStateException("model lane safe cut lost active ownership or expected snapshot")
    }
    requireUserOrConsumedContinuation(transaction, before.thread.id, turn, run, before.activeEpoch)
    let contextChange = change.nextContext().isSome()
    let previousContext = if (contextChange) { encodeStoredValue(contextSnapshotValue(change.previousContext().getOrThrow())) } else { "" }
    let nextContext = if (contextChange) { encodeStoredValue(contextSnapshotValue(change.nextContext().getOrThrow())) } else { "" }
    if (contextChange && ownership[0].required(1) != previousContext) {
        throw IllegalStateException("context safe cut lost its expected canonical projection") }
    if (contextChange) {
        match (validateContextSnapshotUse(change.nextContext().getOrThrow())) {
            case Result.Err(error) => throw IllegalStateException(error.code); case Result.Ok(_) => () }
        for (link in change.contextFacts()) {
            let actual = requireContextReadFact(transaction, link.operationId, run)
            if (link.runId.value != run.value || actual.origin.parentCallItemId != "" ||
                actual.origin.parentKind != "" || actual.origin.parentOperationId != "" ||
                actual.origin.projectionDigest != contextReadProjectionDigest(change.previousContext().getOrThrow()) ||
                canonicalAgentValue(actual.link().toValue()) != canonicalAgentValue(link.toValue())) {
                throw IllegalStateException("context update cannot borrow another Run, parent or projection's read fact") }
            // The historical fact loader intentionally supports inspection;
            // new consumption additionally requires its current Run enclosure.
            requireContextReadOriginBinding(transaction, link.operationId, run, link.sourceItemId, false)
        }
    }
    // The operation table independently fences the cut even when a malformed
    // or stale continuation omitted its operation debt.
    if (!transaction.query("SELECT o.id FROM operations o LEFT JOIN operation_receipts receipt " +
        "ON receipt.operation_id=o.id WHERE o.run_id=? AND (o.state!='committed' OR receipt.id IS NULL)",
        [SqlParameter.Text(run.value)]).isEmpty()) {
        throw IllegalStateException("model lane safe cut has an unsettled Operation")
    }
    if (!transaction.query("SELECT id FROM model_attempts WHERE run_id=? " +
        "AND (lifecycle IN ('created','streaming') OR completed_at_millis IS NULL)",
        [SqlParameter.Text(run.value)]).isEmpty() ||
        !transaction.query("SELECT d.id FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id " +
            "WHERE a.run_id=? AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NULL",
            [SqlParameter.Text(run.value)]).isEmpty()) {
        throw IllegalStateException("model lane safe cut cannot replace a pending model request or Decision")
    }
    // SQL payloads use the canonical store codec; do not infer call identities
    // from user JSON fields or merely count ToolCall and ToolResult rows.
    let pending = HashSet<String>()
    for (row in transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? " +
        "AND kind IN ('tool_call','tool_result') ORDER BY ordinal",
        [SqlParameter.Text(before.thread.id.value), SqlParameter.Text(turn.value)])) {
        match (decodeStoredThreadContent(row.required(0))) {
            case ThreadItemContent.ToolCall(id, _, _) =>
                if (pending.contains(id.value)) { throw IllegalStateException("duplicate canonical call at safe cut") }
                pending.add(id.value)
            case ThreadItemContent.ToolResult(id, _, _, _, _) => pending.remove(id.value)
            case _ => throw IllegalStateException("invalid canonical tool round at safe cut")
        }
    }
    if (!pending.isEmpty()) { throw IllegalStateException("model lane safe cut requires terminal canonical ToolResults") }
    let rows = transaction.query("SELECT revision,payload,digest FROM run_continuations WHERE run_id=?",
        [SqlParameter.Text(run.value)])
    if (rows.size != 1) { throw IllegalStateException("safe cut requires one canonical continuation") }
    let current = decodeDurableRunContinuation(rows[0].required(1))
    if (current.digest != rows[0].required(2) || current.runId.value != run.value ||
        current.turnId.value != turn.value) { throw IllegalStateException("safe cut continuation is inconsistent") }
    let debt = current.workDebt
    if (!debt.activeAttempts.isEmpty() || !debt.uncommittedDecisions.isEmpty() ||
        !debt.unsettledOperations.isEmpty() || !debt.pendingApprovals.isEmpty() ||
        !debt.waitingExternal.isEmpty() || current.pendingOperationId.isSome() ||
        current.pendingApprovalId.isSome() || current.waitingExternal.isSome()) {
        throw IllegalStateException("model lane safe cut cannot discard active execution debt")
    }
    match (current.toolBatch) {
        case Some(batch) => if (batch.nextOperationOrdinal != batch.operationIds.size) {
            throw IllegalStateException("model lane safe cut cannot discard a pending tool batch")
        } else {
            for (operation in batch.operationIds) {
                if (transaction.query("SELECT o.id FROM operations o JOIN operation_receipts r ON r.operation_id=o.id " +
                    "WHERE o.id=? AND o.run_id=? AND o.state='committed'",
                    [SqlParameter.Text(operation.value), SqlParameter.Text(run.value)]).size != 1) {
                    throw IllegalStateException("model lane safe cut tool batch lacks its own terminal Receipts")
                }
            }
        }
        case None => ()
    }
    match (current.attemptId) {
        case Some(attempt) => if (transaction.query("SELECT a.id FROM model_attempts a JOIN model_decisions d ON d.attempt_id=a.id " +
            "WHERE a.id=? AND a.run_id=? AND a.lifecycle='completed' AND d.canonical_committed_at_millis IS NOT NULL",
            [SqlParameter.Text(attempt.value), SqlParameter.Text(run.value)]).size != 1) {
            throw IllegalStateException("model lane safe cut has an unproved model Attempt reference")
        }
        case None => ()
    }
    let compositions = transaction.query("SELECT s.payload FROM run_composition_bindings b " +
        "JOIN composition_snapshots s ON s.id=b.snapshot_id WHERE b.run_id=? AND b.snapshot_id=?",
        [SqlParameter.Text(run.value), SqlParameter.Text(current.compositionSnapshotId.value)])
    if (compositions.size != 1) { throw IllegalStateException("safe cut composition binding changed") }
    let oldComposition = decodeCompositionSnapshot(compositions[0].required(0))
    let suffix = modelPolicySha256Text(next + nextContext)
    let composition = if (contextChange) { compositionForContextCut(oldComposition,
        CompositionSnapshotId("composition-" + run.value + "-" + suffix),
        contextReadProjectionDigest(change.nextContext().getOrThrow())) }
        else { compositionForToolSetCut(oldComposition,
            CompositionSnapshotId("composition-" + run.value + "-" + suffix), suffix) }
    let payload = encodeCompositionSnapshot(composition)
    let existing = transaction.query("SELECT payload FROM composition_snapshots WHERE id=?",
        [SqlParameter.Text(composition.id.value)])
    if (existing.isEmpty()) {
        transaction.execute("INSERT INTO composition_snapshots(id,digest,payload,created_at_millis) VALUES (?,?,?,?)",
            [SqlParameter.Text(composition.id.value), SqlParameter.Text(composition.digest),
                SqlParameter.Text(payload), SqlParameter.Int64Value(change.observedAtMillis)])
    } else if (existing.size != 1 || existing[0].required(0) != payload) {
        throw IllegalStateException("safe cut composition identity collision")
    }
    transaction.execute("UPDATE run_composition_bindings SET snapshot_id=? WHERE run_id=? AND snapshot_id=?",
        [SqlParameter.Text(composition.id.value), SqlParameter.Text(run.value),
            SqlParameter.Text(current.compositionSnapshotId.value)])
    requireStoreChanged(transaction, "safe cut composition CAS failed")
    transaction.execute("UPDATE runs SET lane_snapshot=? WHERE id=? AND lane_snapshot=? AND state='running' AND epoch=?",
        [SqlParameter.Text(next), SqlParameter.Text(run.value), SqlParameter.Text(previous),
            SqlParameter.Int64Value(before.activeEpoch)])
    requireStoreChanged(transaction, "safe cut lane CAS failed")
    if (contextChange) {
        transaction.execute("UPDATE runs SET skill_snapshot=? WHERE id=? AND skill_snapshot=? AND state='running' AND epoch=?",
            [SqlParameter.Text(nextContext), SqlParameter.Text(run.value), SqlParameter.Text(previousContext),
                SqlParameter.Int64Value(before.activeEpoch)])
        requireStoreChanged(transaction, "context snapshot CAS failed")
    }
    var continuation = sealDurableRunContinuation(DurableRunContinuationV1(
        current.runId, current.laneId, current.turnId, current.stepOrdinal,
        RunExecutionPhase.ContextCompiling(DurablePhaseState(objectValue([
            ValueField("reason", textValue(if (contextChange) { "context_snapshot_changed" } else { "tool_catalog_changed" })),
            ValueField("previous_tool_set_id", textValue(change.previousLane().toolSet.id)),
            ValueField("tool_set_id", textValue(change.nextLane().toolSet.id))]))),
        composition.id, ModelLaneSnapshotId("model-lane-" + run.value + "-" + suffix),
        // Child Runs, owned tasks, deferred contexts and unclaimed inputs are
        // still obligations of this same Run, never erased by a directory cut.
        workDebt: current.workDebt,
        recoveryPolicyVersion: current.recoveryPolicyVersion))
    if (contextChange) {
        // Preserve the committed data in diagnostic/history projections. A
        // settled phase does not authorize replay of its old model Attempt.
        let request = optionalRunRequestSnapshotFromDurableContinuation(current).getOrThrow()
        let fields = ArrayList<ValueField>()
        var found = false
        for (field in request.fields) {
            if (field.name == "skill_stack") {
                found = true
                if (canonicalAgentValue(field.value) != canonicalAgentValue(contextSnapshotValue(change.previousContext().getOrThrow()))) {
                    throw IllegalStateException("context cut cannot rewrite a divergent historical request projection") }
                fields.add(ValueField(field.name, contextSnapshotValue(change.nextContext().getOrThrow())))
            } else { fields.add(field) }
        }
        if (!found) { throw IllegalStateException("context cut requires an existing canonical Run request projection") }
        continuation = withRunRequestSnapshotProjection(continuation, objectValue(fields.toArray()))
    }
    match (change.coreBoundary()) { case Some(data) =>
        continuation = bindCoreContextBoundaryAtCut(transaction, continuation, data, before.thread.id,
            before.activeEpoch, if (contextChange) { change.nextContext().getOrThrow() } else {
                contextSnapshotFromValue(decodeStoredValue(ownership[0].required(1))) }, change.nextLane())
        case None => () }
    // Check the complete new durable value before publication; transaction
    // rollback preserves the old version if the existing codec rejects it.
    if (contextChange) { let _ = decodeDurableRunContinuation(encodeDurableRunContinuation(continuation)) }
    if (contextChange) {
        match (validateContextSnapshotUse(change.nextContext().getOrThrow())) {
            case Result.Err(error) => throw IllegalStateException(error.code); case Result.Ok(_) => () }
    }
    putClaimContinuation(transaction, before.thread.id, continuation,
        Int64.parse(rows[0].required(0)), change.observedAtMillis)
    // Both complete immutable lane versions remain explainable after restart.
    let sequence = Int64.parse(transaction.query("SELECT last_sequence FROM thread_commit_heads WHERE thread_id=?",
        [SqlParameter.Text(before.thread.id.value)])[0].required(0))
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) " +
        "VALUES (?,?,NULL,?,?,?,?)",
        [SqlParameter.Text(before.thread.id.value), SqlParameter.Text(run.value),
            SqlParameter.Text(if (contextChange) { "context_snapshot_safe_cut" } else { "model_lane_safe_cut" }),
            SqlParameter.Text(encodeStoredValue(objectValue([
                ValueField("context_read_facts", contextReadFactLinksValue(change.contextFacts())),
                ValueField("previous_context_digest", if (contextChange) { textValue(contextReadProjectionDigest(change.previousContext().getOrThrow())) } else { nullValue() }),
                ValueField("next_context_digest", if (contextChange) { textValue(contextReadProjectionDigest(change.nextContext().getOrThrow())) } else { nullValue() }),
                ValueField("previous_continuation_revision", textValue(rows[0].required(0))),
                ValueField("previous_continuation_digest", textValue(current.digest)),
                ValueField("previous", if (contextChange) { nullValue() } else { modelLaneSnapshotValue(change.previousLane()) }),
                ValueField("next", if (contextChange) { nullValue() } else { modelLaneSnapshotValue(change.nextLane()) }),
                ValueField("previous_composition", textValue(current.compositionSnapshotId.value)),
                ValueField("composition", textValue(composition.id.value)),
                ValueField("epoch", integerValue(before.activeEpoch)),
                ValueField("thread_revision", integerValue(transition.after.thread.revision))]))),
            SqlParameter.Int64Value(change.observedAtMillis), SqlParameter.Int64Value(sequence)])
}

func compositionForToolSetCut(previous: ResolvedAgentCompositionSnapshot,
    id: CompositionSnapshotId, visibilityDigest: String): ResolvedAgentCompositionSnapshot {
    let value = ResolvedAgentCompositionSnapshot(id, previous.profileId, previous.profileVersion,
        previous.componentInstances, previous.serviceBindings, previous.capabilityCeiling,
        visibilityDigest, previous.promptGraphDigest, previous.resolverVersion)
    ResolvedAgentCompositionSnapshot(id, value.profileId, value.profileVersion,
        value.componentInstances, value.serviceBindings, value.capabilityCeiling,
        value.toolVisibilityDigest, value.promptGraphDigest, value.resolverVersion,
        digest: compositionDigest(value))
}

func currentModelLaneContinuation(transaction: SqliteTransaction, run: RunId): DurableRunContinuationV1 {
    let rows = transaction.query("SELECT payload,digest FROM run_continuations WHERE run_id=?",
        [SqlParameter.Text(run.value)])
    if (rows.size != 1) { throw IllegalStateException("Context Manifest requires its current Run continuation") }
    let value = decodeDurableRunContinuation(rows[0].required(0))
    if (value.runId.value != run.value || value.digest != rows[0].required(1)) {
        throw IllegalStateException("Context Manifest Run continuation changed")
    }
    value
}

func compositionForContextCut(previous: ResolvedAgentCompositionSnapshot,
    id: CompositionSnapshotId, contextDigest: String): ResolvedAgentCompositionSnapshot {
    let value = ResolvedAgentCompositionSnapshot(id, previous.profileId, previous.profileVersion,
        previous.componentInstances, previous.serviceBindings, previous.capabilityCeiling,
        previous.toolVisibilityDigest, contextDigest, previous.resolverVersion)
    ResolvedAgentCompositionSnapshot(id, value.profileId, value.profileVersion,
        value.componentInstances, value.serviceBindings, value.capabilityCeiling,
        value.toolVisibilityDigest, value.promptGraphDigest, value.resolverVersion,
        digest: compositionDigest(value))
}
