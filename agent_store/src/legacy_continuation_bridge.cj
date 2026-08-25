package agent_store

import std.convert.*
import std.collection.*
import agent_domain.*

// Bounded adapter for the only two legacy AgentCore continuation variants.
// The legacy projection is sealed into the canonical fact/register transaction;
// no new write is made to the retired runs.continuation column.
public func writeLegacyRunContinuationProjection(
    transaction: SqliteTransaction,
    value: RunContinuation,
    encodedLegacy: String
): Unit {
    let runRows = transaction.query(
        "SELECT thread_id,turn_id FROM runs WHERE id=?",
        [SqlParameter.Text(value.runId.value)]
    )
    if (runRows.size != 1 || runRows[0].required(0) != value.sessionId.value) {
        throw IllegalStateException("legacy continuation Run binding is corrupt")
    }
    let phasePayload = DurablePhaseState(objectValue([
        ValueField("adapter", textValue("legacy-continuation-v4")),
        ValueField("legacy_payload", textValue(encodedLegacy))
    ]))
    let pendingApproval = ApprovalId("legacy-approval-" + value.approval.operationId.value)
    let previousRows = transaction.query(
        "SELECT payload FROM run_continuations WHERE run_id=?",
        [SqlParameter.Text(value.runId.value)]
    )
    let previous: ?DurableRunContinuationV1 = if (previousRows.size == 1) {
        try { Some(decodeDurableRunContinuation(previousRows[0].required(0))) }
        catch (_: Exception) { None }
    } else { None }
    let laneId = match (previous) {
        case Some(item) => item.laneId
        case None => LaneId("main")
    }
    let stepOrdinal = match (previous) {
        case Some(item) => item.stepOrdinal
        case None => 0
    }
    let compositionId = match (previous) {
        case Some(item) => item.compositionSnapshotId
        case None => CompositionSnapshotId("legacy-composition")
    }
    let modelLaneId = match (previous) {
        case Some(item) => item.modelLaneSnapshotId
        case None => ModelLaneSnapshotId("legacy-model-lane")
    }
    let contextManifestId = match (previous) {
        case Some(item) => item.contextManifestId
        case None => Option<ContextManifestId>.None
    }
    let continuation = match (value.kind) {
        case RunContinuationKind.WaitingApproval => DurableRunContinuationV1(
            value.runId, laneId, SemanticTurnId(runRows[0].required(1)), stepOrdinal,
            RunExecutionPhase.WaitingApproval(phasePayload),
            compositionId,
            modelLaneId,
            contextManifestId: contextManifestId,
            pendingOperationId: Some(value.approval.operationId),
            pendingApprovalId: Some(pendingApproval),
            workDebt: WorkDebtSnapshot(
                unsettledOperations: [value.approval.operationId],
                pendingApprovals: [pendingApproval]
            )
        )
        case RunContinuationKind.RunningModel =>
            let checkpoint = value.runningModel.getOrThrow()
            DurableRunContinuationV1(
                value.runId, laneId, SemanticTurnId(runRows[0].required(1)), stepOrdinal,
                RunExecutionPhase.ModelEffectPending(phasePayload),
                compositionId,
                modelLaneId,
                contextManifestId: contextManifestId,
                semanticRequestId: Some(checkpoint.semanticRequestId),
                attemptId: Some(checkpoint.activeAttemptId),
                reservedDecisionId: Some(ModelDecisionId(
                    "legacy-decision-" + checkpoint.activeAttemptId.value
                )),
                reservedUsageId: Some(UsageRecordId(
                    "legacy-usage-" + checkpoint.activeAttemptId.value
                )),
                workDebt: WorkDebtSnapshot(activeAttempts: [checkpoint.activeAttemptId])
            )
    }
    putLegacyCompatibleContinuation(
        transaction,
        ThreadId(value.sessionId.value),
        withLegacyRunContinuationProjection(continuation, encodedLegacy),
        legacyContinuationTimestamp(value)
    )
}

public func consumeLegacyRunContinuationSource(
    transaction: SqliteTransaction,
    value: RunContinuation,
    encodedLegacy: String
): Unit {
    let rows = transaction.query(
        "SELECT thread_id FROM runs WHERE id=?",
        [SqlParameter.Text(value.runId.value)]
    )
    if (rows.size != 1 || rows[0].required(0) != value.sessionId.value) {
        throw IllegalStateException("legacy continuation Run binding is corrupt")
    }
    let current = transaction.query(
        "SELECT payload FROM run_continuations WHERE run_id=?",
        [SqlParameter.Text(value.runId.value)]
    )
    if (current.size == 1) {
        let durable = decodeDurableRunContinuation(current[0].required(0))
        match (optionalLegacyPayloadFromDurableContinuation(durable)) {
            case Some(existing) => if (existing != encodedLegacy) {
                throw IllegalStateException(
                    "canonical continuation and legacy migration source diverged"
                )
            }
            case None => putLegacyCompatibleContinuation(
                transaction,
                ThreadId(value.sessionId.value),
                withLegacyRunContinuationProjection(durable, encodedLegacy),
                legacyContinuationTimestamp(value)
            )
        }
    } else {
        writeLegacyRunContinuationProjection(transaction, value, encodedLegacy)
    }
    transaction.execute(
        "UPDATE runs SET continuation=NULL WHERE id=?",
        [SqlParameter.Text(value.runId.value)]
    )
}

public func preserveLegacyRunContinuationProjection(
    transaction: SqliteTransaction,
    value: DurableRunContinuationV1
): DurableRunContinuationV1 {
    if (optionalLegacyPayloadFromDurableContinuation(value).isSome()) {
        return value
    }
    let rows = transaction.query(
        "SELECT payload FROM run_continuations WHERE run_id=?",
        [SqlParameter.Text(value.runId.value)]
    )
    if (rows.size != 1) { return value }
    let previous = decodeDurableRunContinuation(rows[0].required(0))
    match (optionalLegacyPayloadFromDurableContinuation(previous)) {
        case Some(payload) => withLegacyRunContinuationProjection(value, payload)
        case None => value
    }
}

public func withLegacyRunContinuationProjection(
    value: DurableRunContinuationV1,
    encodedLegacy: String
): DurableRunContinuationV1 {
    let fields = ArrayList<ValueField>()
    for (field in runExecutionPhasePayload(value.phase).fields) {
        if (field.name != "adapter" && field.name != "legacy_payload") {
            fields.add(field)
        }
    }
    fields.add(ValueField("adapter", textValue("legacy-continuation-v4")))
    fields.add(ValueField("legacy_payload", textValue(encodedLegacy)))
    let phase = runExecutionPhaseWithState(
        value.phase,
        DurablePhaseState(objectValue(fields.toArray()))
    )
    sealDurableRunContinuation(DurableRunContinuationV1(
        value.runId, value.laneId, value.turnId, value.stepOrdinal, phase,
        value.compositionSnapshotId, value.modelLaneSnapshotId,
        contextManifestId: value.contextManifestId,
        semanticRequestId: value.semanticRequestId,
        attemptId: value.attemptId,
        reservedDecisionId: value.reservedDecisionId,
        reservedUsageId: value.reservedUsageId,
        reservedItemIds: value.reservedItemIds,
        toolBatch: value.toolBatch,
        pendingOperationId: value.pendingOperationId,
        pendingApprovalId: value.pendingApprovalId,
        waitingExternal: value.waitingExternal,
        workDebt: value.workDebt,
        recoveryPolicyVersion: value.recoveryPolicyVersion
    ))
}

func putLegacyCompatibleContinuation(
    transaction: SqliteTransaction,
    threadId: ThreadId,
    sealed: DurableRunContinuationV1,
    observedAtMillis: Int64
): Unit {
    let payload = encodeDurableRunContinuation(sealed)
    let current = transaction.query(
        "SELECT digest FROM run_continuations WHERE run_id=?",
        [SqlParameter.Text(sealed.runId.value)]
    )
    if (current.size == 1 && current[0].required(0) == sealed.digest) { return }
    let revisionRows = transaction.query(
        "SELECT COALESCE(MAX(revision),0) FROM run_continuation_facts WHERE run_id=?",
        [SqlParameter.Text(sealed.runId.value)]
    )
    let revision = legacyInt(revisionRows[0].required(0), "legacy continuation revision") + 1
    let commitSequence = nextLegacyCommitSequence(transaction, threadId)
    transaction.execute(
        "INSERT INTO run_continuation_facts(" +
            "run_id,thread_id,revision,commit_sequence,phase,payload,digest,created_at_millis" +
            ") VALUES (?,?,?,?,?,?,?,?)",
        [
            SqlParameter.Text(sealed.runId.value), SqlParameter.Text(threadId.value),
            SqlParameter.Int64Value(revision), SqlParameter.Int64Value(commitSequence),
            SqlParameter.Text(runExecutionPhaseName(sealed.phase)),
            SqlParameter.Text(payload), SqlParameter.Text(sealed.digest),
            SqlParameter.Int64Value(observedAtMillis)
        ]
    )
    transaction.execute(
        "INSERT INTO run_continuations(" +
            "run_id,schema_version,revision,phase,payload,digest,updated_commit_sequence" +
            ") VALUES (?,?,?,?,?,?,?) ON CONFLICT(run_id) DO UPDATE SET " +
            "schema_version=excluded.schema_version,revision=excluded.revision," +
            "phase=excluded.phase,payload=excluded.payload,digest=excluded.digest," +
            "updated_commit_sequence=excluded.updated_commit_sequence",
        [
            SqlParameter.Text(sealed.runId.value), SqlParameter.Int64Value(1),
            SqlParameter.Int64Value(revision),
            SqlParameter.Text(runExecutionPhaseName(sealed.phase)),
            SqlParameter.Text(payload), SqlParameter.Text(sealed.digest),
            SqlParameter.Int64Value(commitSequence)
        ]
    )
}

public func removeLegacyRunContinuationProjection(
    transaction: SqliteTransaction,
    runId: RunId
): Unit {
    let rows = transaction.query(
        "SELECT runs.thread_id,run_continuations.revision FROM runs " +
            "LEFT JOIN run_continuations ON run_continuations.run_id=runs.id WHERE runs.id=?",
        [SqlParameter.Text(runId.value)]
    )
    if (rows.size != 1 || rows[0][1].isNone()) { return }
    let threadId = ThreadId(rows[0].required(0))
    let revision = legacyInt(rows[0].required(1), "legacy continuation revision") + 1
    let commitSequence = nextLegacyCommitSequence(transaction, threadId)
    let tombstone = encodeStoredValue(objectValue([
        ValueField("run_id", textValue(runId.value)),
        ValueField("adapter", textValue("legacy-continuation-v4")),
        ValueField("removed", boolValue(true))
    ]))
    transaction.execute(
        "INSERT INTO run_continuation_facts(" +
            "run_id,thread_id,revision,commit_sequence,phase,payload,digest,created_at_millis" +
            ") VALUES (?,?,?,?,?,?,?,0)",
        [
            SqlParameter.Text(runId.value), SqlParameter.Text(threadId.value),
            SqlParameter.Int64Value(revision), SqlParameter.Int64Value(commitSequence),
            SqlParameter.Text("removed"), SqlParameter.Text(tombstone),
            SqlParameter.Text(modelPolicySha256Text(tombstone))
        ]
    )
    transaction.execute(
        "DELETE FROM run_continuations WHERE run_id=?",
        [SqlParameter.Text(runId.value)]
    )
}

public func legacyPayloadFromDurableContinuation(
    value: DurableRunContinuationV1
): String {
    match (optionalLegacyPayloadFromDurableContinuation(value)) {
        case Some(payload) => payload
        case None => throw IllegalStateException(
            "durable continuation is not a supported legacy adapter"
        )
    }
}

public func optionalLegacyPayloadFromDurableContinuation(
    value: DurableRunContinuationV1
): ?String {
    let payload = runExecutionPhasePayload(value.phase)
    if (payload.kind != ValueKind.Object) {
        return None
    }
    var adapter: ?String = None
    var legacy: ?String = None
    for (field in payload.fields) {
        if (field.name == "adapter" && field.value.kind == ValueKind.Text) {
            adapter = Some(field.value.text)
        }
        if (field.name == "legacy_payload" && field.value.kind == ValueKind.Text) {
            legacy = Some(field.value.text)
        }
    }
    if (adapter != Some("legacy-continuation-v4") || legacy.isNone()) {
        None
    } else {
        legacy
    }
}

func nextLegacyCommitSequence(
    transaction: SqliteTransaction,
    threadId: ThreadId
): Int64 {
    let rows = transaction.query(
        "SELECT last_sequence FROM thread_commit_heads WHERE thread_id=?",
        [SqlParameter.Text(threadId.value)]
    )
    if (rows.isEmpty()) {
        transaction.execute(
            "INSERT INTO thread_commit_heads(thread_id,last_sequence) VALUES (?,1)",
            [SqlParameter.Text(threadId.value)]
        )
        1
    } else {
        let next = legacyInt(rows[0].required(0), "legacy commit sequence") + 1
        transaction.execute(
            "UPDATE thread_commit_heads SET last_sequence=? WHERE thread_id=?",
            [SqlParameter.Int64Value(next), SqlParameter.Text(threadId.value)]
        )
        next
    }
}

func legacyContinuationTimestamp(value: RunContinuation): Int64 {
    match (value.runningModel) {
        case Some(checkpoint) => checkpoint.requestStartedAtMillis
        case None => 0
    }
}

func legacyInt(source: String, name: String): Int64 {
    try { Int64.parse(source) } catch (_: Exception) {
        throw IllegalStateException("invalid " + name)
    }
}
