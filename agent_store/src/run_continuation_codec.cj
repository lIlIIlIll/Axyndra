package agent_store

import yjson_support.*

import yjson.*

import std.collection.*
import std.convert.*
import agent_domain.*

public func sealDurableRunContinuation(
    value: DurableRunContinuationV1
): DurableRunContinuationV1 {
    copyDurableRunContinuation(
        value,
        modelPolicySha256Text(encodeStoredValue(durableContinuationValue(value, false)))
    )
}

public func encodeDurableRunContinuation(value: DurableRunContinuationV1): String {
    if (!value.isSealed()) {
        throw IllegalArgumentException("durable Run continuation must be sealed")
    }
    let expected = modelPolicySha256Text(
        encodeStoredValue(durableContinuationValue(value, false))
    )
    if (expected != value.digest) {
        throw IllegalArgumentException("durable Run continuation digest does not match payload")
    }
    encodeStoredValue(durableContinuationValue(value, true))
}

public func decodeDurableRunContinuation(source: String): DurableRunContinuationV1 {
    let root = decodeStoredValue(source)
    if (continuationInt(root, "schema_version") != 1) {
        throw IllegalStateException("unsupported durable Run continuation schema")
    }
    let phaseName = continuationText(root, "phase")
    let phasePayload = DurablePhaseState(continuationField(root, "phase_payload"))
    let phase = decodeRunExecutionPhase(phaseName, phasePayload)
    let toolBatchValue = continuationField(root, "tool_batch")
    let toolBatch: ?ToolBatchContinuation = if (toolBatchValue.unifiedKind == ValueKind.Null) {
        None
    } else {
        let operationIds = ArrayList<OperationId>()
        for (item in continuationList(toolBatchValue, "operation_ids")) {
            operationIds.add(OperationId(continuationTextValue(item, "tool batch operation id")))
        }
        Some(ToolBatchContinuation(
            ToolBatchId(continuationText(toolBatchValue, "batch_id")),
            continuationInt(toolBatchValue, "next_operation_ordinal"),
            operationIds.toArray()
        ))
    }
    let externalValue = continuationField(root, "waiting_external")
    let waitingExternal: ?ExternalWaitState = if (externalValue.unifiedKind == ValueKind.Null) {
        None
    } else {
        Some(ExternalWaitState(
            ExternalHandleId(continuationText(externalValue, "handle_id")),
            continuationText(externalValue, "kind"),
            continuationField(externalValue, "payload")
        ))
    }
    let debt = continuationField(root, "work_debt")
    let decoded = DurableRunContinuationV1(
        RunId(continuationText(root, "run_id")),
        LaneId(continuationText(root, "lane_id")),
        SemanticTurnId(continuationText(root, "turn_id")),
        continuationInt(root, "step_ordinal"),
        phase,
        CompositionSnapshotId(continuationText(root, "composition_snapshot_id")),
        ModelLaneSnapshotId(continuationText(root, "model_lane_snapshot_id")),
        contextManifestId: optionalText(root, "context_manifest_id", { text => ContextManifestId(text) }),
        semanticRequestId: optionalText(root, "semantic_request_id", { text => SemanticModelRequestId(text) }),
        attemptId: optionalText(root, "attempt_id", { text => ModelAttemptId(text) }),
        reservedDecisionId: optionalText(root, "reserved_decision_id", { text => ModelDecisionId(text) }),
        reservedUsageId: optionalText(root, "reserved_usage_id", { text => UsageRecordId(text) }),
        reservedItemIds: decodeTextList(root, "reserved_item_ids", { text => ItemId(text) }),
        toolBatch: toolBatch,
        pendingOperationId: optionalText(root, "pending_operation_id", { text => OperationId(text) }),
        pendingApprovalId: optionalText(root, "pending_approval_id", { text => ApprovalId(text) }),
        waitingExternal: waitingExternal,
        workDebt: WorkDebtSnapshot(
            unclaimedInputs: decodeTextList(debt, "unclaimed_inputs", { text => InboxEntryId(text) }),
            activeAttempts: decodeTextList(debt, "active_attempts", { text => ModelAttemptId(text) }),
            uncommittedDecisions: decodeTextList(debt, "uncommitted_decisions", { text => ModelDecisionId(text) }),
            unsettledOperations: decodeTextList(debt, "unsettled_operations", { text => OperationId(text) }),
            pendingApprovals: decodeTextList(debt, "pending_approvals", { text => ApprovalId(text) }),
            waitingExternal: decodeTextList(debt, "waiting_external", { text => ExternalHandleId(text) }),
            activeChildRuns: decodeTextList(debt, "active_child_runs", { text => RunId(text) }),
            ownedTasks: decodeTextList(debt, "owned_tasks", { text => OwnedTaskId(text) }),
            deferredContexts: decodeTextList(debt, "deferred_contexts", { text => DeferredContextId(text) })
        ),
        recoveryPolicyVersion: 1u32,
        digest: continuationText(root, "digest")
    )
    let expectedDigest = modelPolicySha256Text(
        encodeStoredValue(durableContinuationValue(decoded, false))
    )
    if (expectedDigest != decoded.digest) {
        throw IllegalStateException("durable Run continuation digest does not match payload")
    }
    if (encodeDurableRunContinuation(decoded) != source) {
        throw IllegalStateException("durable Run continuation is not canonical")
    }
    decoded
}

func durableContinuationValue(
    value: DurableRunContinuationV1,
    includeDigest: Bool
): AgentValue {
    let fields = ArrayList<ValueField>([
        ValueField("schema_version", integerValue(1)),
        ValueField("run_id", textValue(value.runId.value)),
        ValueField("lane_id", textValue(value.laneId.value)),
        ValueField("turn_id", textValue(value.turnId.value)),
        ValueField("step_ordinal", integerValue(value.stepOrdinal)),
        ValueField("phase", textValue(runExecutionPhaseName(value.phase))),
        ValueField("phase_payload", runExecutionPhasePayload(value.phase)),
        ValueField("composition_snapshot_id", textValue(value.compositionSnapshotId.value)),
        ValueField("model_lane_snapshot_id", textValue(value.modelLaneSnapshotId.value)),
        ValueField("context_manifest_id", optionalIdValue(value.contextManifestId, { item => item.value })),
        ValueField("semantic_request_id", optionalIdValue(value.semanticRequestId, { item => item.value })),
        ValueField("attempt_id", optionalIdValue(value.attemptId, { item => item.value })),
        ValueField("reserved_decision_id", optionalIdValue(value.reservedDecisionId, { item => item.value })),
        ValueField("reserved_usage_id", optionalIdValue(value.reservedUsageId, { item => item.value })),
        ValueField("reserved_item_ids", idListValue(value.reservedItemIds, { item => item.value })),
        ValueField("tool_batch", toolBatchValue(value.toolBatch)),
        ValueField("pending_operation_id", optionalIdValue(value.pendingOperationId, { item => item.value })),
        ValueField("pending_approval_id", optionalIdValue(value.pendingApprovalId, { item => item.value })),
        ValueField("waiting_external", externalWaitValue(value.waitingExternal)),
        ValueField("work_debt", workDebtValue(value.workDebt)),
        ValueField("recovery_policy_version", integerValue(Int64(value.recoveryPolicyVersion)))
    ])
    if (includeDigest) { fields.add(ValueField("digest", textValue(value.digest))) }
    objectValue(fields.toArray())
}

func copyDurableRunContinuation(
    value: DurableRunContinuationV1,
    digest: String
): DurableRunContinuationV1 {
    DurableRunContinuationV1(
        value.runId, value.laneId, value.turnId, value.stepOrdinal, value.phase,
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
        recoveryPolicyVersion: value.recoveryPolicyVersion,
        digest: digest
    )
}

func decodeRunExecutionPhase(name: String, state: DurablePhaseState): RunExecutionPhase {
    match (name) {
        case "accepted" => RunExecutionPhase.Accepted(state)
        case "context_compiling" => RunExecutionPhase.ContextCompiling(state)
        case "context_ready" => RunExecutionPhase.ContextReady(state)
        case "model_ready" => RunExecutionPhase.ModelReady(state)
        case "model_effect_pending" => RunExecutionPhase.ModelEffectPending(state)
        case "model_settling" => RunExecutionPhase.ModelSettling(state)
        case "decision_ready" => RunExecutionPhase.DecisionReady(state)
        case "tool_batch_ready" => RunExecutionPhase.ToolBatchReady(state)
        case "waiting_approval" => RunExecutionPhase.WaitingApproval(state)
        case "tool_effect_pending" => RunExecutionPhase.ToolEffectPending(state)
        case "tool_settling" => RunExecutionPhase.ToolSettling(state)
        case "waiting_external" => RunExecutionPhase.WaitingExternal(state)
        case "checkpoint" => RunExecutionPhase.Checkpoint(state)
        case "terminalizing" => RunExecutionPhase.Terminalizing(state)
        case _ => throw IllegalStateException("unknown durable Run execution phase " + name)
    }
}

func toolBatchValue(value: ?ToolBatchContinuation): AgentValue {
    match (value) {
        case Some(batch) => objectValue([
            ValueField("batch_id", textValue(batch.batchId.value)),
            ValueField("next_operation_ordinal", integerValue(batch.nextOperationOrdinal)),
            ValueField("operation_ids", idListValue(batch.operationIds, { item => item.value }))
        ])
        case None => nullValue()
    }
}

func externalWaitValue(value: ?ExternalWaitState): AgentValue {
    match (value) {
        case Some(wait) => objectValue([
            ValueField("handle_id", textValue(wait.handleId.value)),
            ValueField("kind", textValue(wait.kind)),
            ValueField("payload", wait.payload)
        ])
        case None => nullValue()
    }
}

func workDebtValue(value: WorkDebtSnapshot): AgentValue {
    objectValue([
        ValueField("unclaimed_inputs", idListValue(value.unclaimedInputs, { item => item.value })),
        ValueField("active_attempts", idListValue(value.activeAttempts, { item => item.value })),
        ValueField("uncommitted_decisions", idListValue(value.uncommittedDecisions, { item => item.value })),
        ValueField("unsettled_operations", idListValue(value.unsettledOperations, { item => item.value })),
        ValueField("pending_approvals", idListValue(value.pendingApprovals, { item => item.value })),
        ValueField("waiting_external", idListValue(value.waitingExternal, { item => item.value })),
        ValueField("active_child_runs", idListValue(value.activeChildRuns, { item => item.value })),
        ValueField("owned_tasks", idListValue(value.ownedTasks, { item => item.value })),
        ValueField("deferred_contexts", idListValue(value.deferredContexts, { item => item.value }))
    ])
}

func optionalIdValue<T>(value: ?T, id: (T) -> String): AgentValue {
    match (value) {
        case Some(item) => textValue(id(item))
        case None => nullValue()
    }
}

func idListValue<T>(values: Array<T>, id: (T) -> String): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) { result.add(textValue(id(value))) }
    listValue(result.toArray())
}

func optionalText<T>(value: AgentValue, name: String, factory: (String) -> T): ?T {
    let field = continuationField(value, name)
    if (field.unifiedKind == ValueKind.Null) { None } else {
        Some(factory(continuationTextValue(field, name)))
    }
}

func decodeTextList<T>(value: AgentValue, name: String, factory: (String) -> T): Array<T> {
    let result = ArrayList<T>()
    for (item in continuationList(value, name)) {
        result.add(factory(continuationTextValue(item, name)))
    }
    result.toArray()
}

func continuationField(value: AgentValue, name: String): AgentValue {
    if (value.unifiedKind != ValueKind.Object) {
        throw IllegalStateException("durable continuation object expected")
    }
    for (field in value.fields where field.name == name) { return field.value }
    throw IllegalStateException("durable continuation field is missing: " + name)
}

func continuationText(value: AgentValue, name: String): String {
    continuationTextValue(continuationField(value, name), name)
}

func continuationTextValue(value: AgentValue, name: String): String {
    if (value.unifiedKind != ValueKind.Text) {
        throw IllegalStateException("durable continuation text expected: " + name)
    }
    value.text
}

func continuationInt(value: AgentValue, name: String): Int64 {
    let field = continuationField(value, name)
    if (field.unifiedKind != ValueKind.Number) {
        throw IllegalStateException("durable continuation integer expected: " + name)
    }
    try { Int64.parse(field.number) } catch (_: Exception) {
        throw IllegalStateException("durable continuation integer is invalid: " + name)
    }
}

func continuationList(value: AgentValue, name: String): Array<AgentValue> {
    let field = continuationField(value, name)
    if (field.unifiedKind != ValueKind.List) {
        throw IllegalStateException("durable continuation list expected: " + name)
    }
    field.items.toArray()
}
