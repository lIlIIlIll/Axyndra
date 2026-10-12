package agent_domain

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Immutable restart data only. Possession never supplies a Thread owner,
// Source, cancellation token, executor, or permission to replay an Attempt.
public class RunContextBoundary {
    private let frozenContinuation: DurableRunContinuationV1
    private let encoded: String
    public init(continuation: DurableRunContinuationV1) {
        let value = contextBoundaryData(continuation).getOrThrow()
        this.encoded = stringifyUnifiedJson(value)
        let _ = parseUnifiedJson(encoded, maxBytes: 8388608)
        this.frozenContinuation = copyContextBoundaryContinuation(continuation)
    }
    public prop continuation: DurableRunContinuationV1 { get() { copyContextBoundaryContinuation(frozenContinuation) } }
    public func data(): AgentValue { parseUnifiedJson(encoded, maxBytes: 8388608) }
}

func copyContextBoundaryContinuation(value: DurableRunContinuationV1): DurableRunContinuationV1 {
    if (value.toolBatch.isSome()) { throw IllegalArgumentException("context boundary cannot retain a tool batch cursor") }
    let debt = value.workDebt
    let phase = runExecutionPhaseWithState(value.phase, DurablePhaseState(parseUnifiedJson(
        stringifyUnifiedJson(runExecutionPhasePayload(value.phase)), maxBytes: 8388608)))
    DurableRunContinuationV1(value.runId, value.laneId, value.turnId, value.stepOrdinal, phase,
        value.compositionSnapshotId, value.modelLaneSnapshotId, contextManifestId: value.contextManifestId,
        semanticRequestId: value.semanticRequestId, attemptId: value.attemptId,
        reservedDecisionId: value.reservedDecisionId, reservedUsageId: value.reservedUsageId,
        reservedItemIds: value.reservedItemIds.clone(), pendingOperationId: value.pendingOperationId,
        pendingApprovalId: value.pendingApprovalId, waitingExternal: value.waitingExternal,
        workDebt: WorkDebtSnapshot(unclaimedInputs: debt.unclaimedInputs.clone(), activeAttempts: debt.activeAttempts.clone(),
            uncommittedDecisions: debt.uncommittedDecisions.clone(), unsettledOperations: debt.unsettledOperations.clone(),
            pendingApprovals: debt.pendingApprovals.clone(), waitingExternal: debt.waitingExternal.clone(),
            activeChildRuns: debt.activeChildRuns.clone(), ownedTasks: debt.ownedTasks.clone(), deferredContexts: debt.deferredContexts.clone()),
        recoveryPolicyVersion: value.recoveryPolicyVersion, digest: value.digest)
}

public func contextBoundaryField(value: AgentValue, name: String): AgentValue {
    match (value.field(name)) { case Some(field) => field
        case None => throw IllegalArgumentException("context boundary field missing: " + name) }
}
public func contextBoundaryText(value: AgentValue, name: String): String {
    let field = contextBoundaryField(value, name)
    if (field.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("context boundary text invalid") }
    field.text
}
public func contextBoundaryInteger(value: AgentValue, name: String): Int64 {
    let field = contextBoundaryField(value, name)
    if (field.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("context boundary integer invalid") }
    let result = Int64.parse(field.asNumberText())
    if (result < 0 || result.toString() != field.asNumberText()) { throw IllegalArgumentException("context boundary integer noncanonical") }
    result
}
public func contextBoundaryShape(value: AgentValue, names: Array<String>): Unit {
    if (value.unifiedKind != ValueKind.Object || value.fields.size != names.size) {
        throw IllegalArgumentException("context boundary object shape invalid") }
    let seen = HashSet<String>()
    for (field in value.fields) {
        if (!names.contains(field.name) || seen.contains(field.name)) {
            throw IllegalArgumentException("context boundary object field invalid") }
        seen.add(field.name)
    }
}
public func contextBoundaryUsage(value: AgentValue): ExecutionUsage {
    contextBoundaryShape(value, ["turns", "model_requests", "drain_model_requests", "tool_calls",
        "active_tools", "input_tokens", "output_tokens", "cost_micros"])
    ExecutionUsage(turns: contextBoundaryInteger(value, "turns"),
        modelRequests: contextBoundaryInteger(value, "model_requests"),
        drainModelRequests: contextBoundaryInteger(value, "drain_model_requests"),
        toolCalls: contextBoundaryInteger(value, "tool_calls"), activeTools: contextBoundaryInteger(value, "active_tools"),
        inputTokens: contextBoundaryInteger(value, "input_tokens"), outputTokens: contextBoundaryInteger(value, "output_tokens"),
        costMicros: contextBoundaryInteger(value, "cost_micros"))
}
public func contextBoundaryUsageValue(value: ExecutionUsage): AgentValue {
    objectValue([ValueField("turns", integerValue(value.turns)), ValueField("model_requests", integerValue(value.modelRequests)),
        ValueField("drain_model_requests", integerValue(value.drainModelRequests)), ValueField("tool_calls", integerValue(value.toolCalls)),
        ValueField("active_tools", integerValue(value.activeTools)), ValueField("input_tokens", integerValue(value.inputTokens)),
        ValueField("output_tokens", integerValue(value.outputTokens)), ValueField("cost_micros", integerValue(value.costMicros))])
}
public func contextBoundaryData(value: DurableRunContinuationV1): ?AgentValue {
    let data = runExecutionPhasePayload(value.phase).field("core_context_boundary")
    if (data.isNone()) { return None }
    match (value.phase) { case RunExecutionPhase.ContextCompiling(_) | RunExecutionPhase.ContextReady(_) => ()
        case _ => throw IllegalArgumentException("context boundary phase invalid") }
    let item = data.getOrThrow()
    contextBoundaryShape(item, ["schema", "point", "request", "counter", "control", "usage", "tool_loop_state",
        "thread_id", "epoch", "context_digest", "lane_digest", "wall_start_millis"])
    if (contextBoundaryText(item, "schema") != "axyndra.core-context-boundary/v1" ||
        !["after_safe_cut", "turn_reserved"].contains(contextBoundaryText(item, "point"))) {
        throw IllegalArgumentException("context boundary version or point unsupported") }
    let _ = contextBoundaryInteger(item, "epoch")
    let _ = contextBoundaryInteger(item, "wall_start_millis")
    let usage = contextBoundaryUsage(contextBoundaryField(item, "usage"))
    let counter = contextBoundaryField(item, "counter")
    contextBoundaryShape(counter, ["model_requests", "work_model_requests", "drain_model_requests", "input_tokens", "output_tokens",
        "reasoning_tokens", "cache_read_tokens", "cache_write_tokens", "cost_micros", "last_input_tokens", "last_output_tokens",
        "last_duration_millis", "tool_calls", "turns"])
    for (field in counter.fields where field.name != "cost_micros") { let _ = contextBoundaryInteger(counter, field.name) }
    if (contextBoundaryField(counter, "cost_micros").unifiedKind != ValueKind.Null) { let _ = contextBoundaryInteger(counter, "cost_micros") }
    let work = contextBoundaryInteger(counter, "work_model_requests")
    let drain = contextBoundaryInteger(counter, "drain_model_requests")
    if (work > Int64.Max - drain || contextBoundaryInteger(counter, "model_requests") != work + drain ||
        usage.turns != contextBoundaryInteger(counter, "turns") || usage.modelRequests != work || usage.drainModelRequests != drain ||
        usage.toolCalls != contextBoundaryInteger(counter, "tool_calls") || usage.activeTools != 0 ||
        usage.inputTokens != contextBoundaryInteger(counter, "input_tokens") || usage.outputTokens != contextBoundaryInteger(counter, "output_tokens")) {
        throw IllegalArgumentException("context boundary ledger and counter differ") }
    let control = contextBoundaryField(item, "control")
    contextBoundaryShape(control, ["request_serial", "turn_serial", "batch_serial", "context_read_serial", "active_turn_id",
        "budget_mode", "drain_attempts", "deadline_millis"])
    for (name in ["request_serial", "turn_serial", "batch_serial", "context_read_serial", "drain_attempts", "deadline_millis"]) {
        let _ = contextBoundaryInteger(control, name) }
    if (!["normal", "pressure", "draining", "exhausted"].contains(contextBoundaryText(control, "budget_mode"))) {
        throw IllegalArgumentException("context boundary budget mode is invalid") }
    let toolState = contextBoundaryField(item, "tool_loop_state")
    contextBoundaryShape(toolState, ["consecutive_capability_denials", "last_capability_denied_tool"])
    let _ = contextBoundaryInteger(toolState, "consecutive_capability_denials")
    let _ = contextBoundaryText(toolState, "last_capability_denied_tool")
    let _ = parseUnifiedJson(stringifyUnifiedJson(item), maxBytes: 8388608)
    Some(item)
}
