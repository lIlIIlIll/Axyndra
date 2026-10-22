package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*

public func withContextBoundaryProjection(value: DurableRunContinuationV1, data: AgentValue): DurableRunContinuationV1 {
    let fields = ArrayList<ValueField>()
    for (field in runExecutionPhasePayload(value.phase).fields where field.name != "core_context_boundary") { fields.add(field) }
    fields.add(ValueField("core_context_boundary", data))
    let result = continuationWithPhaseFields(value, fields)
    let _ = RunContextBoundary(result)
    result
}

// Only prompt compilation phases inherit this marker. A newly prepared model
// Attempt replaces it atomically; old RunningModel projections are unchanged.
func preserveContextBoundaryProjection(tx: SqliteTransaction, value: DurableRunContinuationV1): DurableRunContinuationV1 {
    match (value.phase) { case RunExecutionPhase.ContextCompiling(_) | RunExecutionPhase.ContextReady(_) => ()
        case _ => return value }
    if (contextBoundaryData(value).isSome()) { return value }
    let rows = tx.query("SELECT payload FROM run_continuations WHERE run_id=?", [SqlParameter.Text(value.runId.value)])
    if (rows.size != 1) { return value }
    let previous = decodeDurableRunContinuation(rows[0].required(0))
    match (contextBoundaryData(previous)) {
        case None => value
        case Some(data) =>
            if (value.runId.value != previous.runId.value || value.turnId.value != previous.turnId.value ||
                value.laneId.value != previous.laneId.value || value.compositionSnapshotId.value != previous.compositionSnapshotId.value ||
                value.modelLaneSnapshotId.value != previous.modelLaneSnapshotId.value) {
                throw IllegalStateException("context boundary enclosure changed during compilation") }
            withContextBoundaryProjection(value, data)
    }
}

// Re-read canonical SQL inside the caller's transaction. This data check is
// never a Source or permission to replay unknown execution/cleanup obligations.
public func requireContextBoundaryCurrent(tx: SqliteTransaction, expected: RunContextBoundary): RunContextBoundary {
    let v = expected.continuation
    let rows = tx.query("SELECT c.payload,c.digest,r.thread_id,r.epoch,r.lane_snapshot,r.skill_snapshot,b.snapshot_id " +
        "FROM run_continuations c JOIN runs r ON r.id=c.run_id JOIN turns turn ON turn.id=r.turn_id " +
        "JOIN threads t ON t.id=r.thread_id JOIN run_composition_bindings b ON b.run_id=r.id " +
        "WHERE r.id=? AND r.turn_id=? AND r.state='running' AND r.finished_at_millis IS NULL " +
        "AND turn.state='active' AND turn.active_run_id=r.id AND t.active_turn_id=turn.id " +
        "AND EXISTS (SELECT 1 FROM run_continuation_facts f WHERE f.run_id=c.run_id AND f.thread_id=r.thread_id " +
        "AND f.revision=c.revision AND f.commit_sequence=c.updated_commit_sequence AND f.payload=c.payload AND f.digest=c.digest)",
        [SqlParameter.Text(v.runId.value), SqlParameter.Text(v.turnId.value)])
    if (rows.size != 1 || rows[0].required(1) != v.digest || rows[0].required(0) != encodeDurableRunContinuation(v)) {
        throw IllegalStateException("context boundary current revision changed") }
    let actual = RunContextBoundary(decodeDurableRunContinuation(rows[0].required(0)))
    let data = actual.data()
    if (rows[0].required(2) != contextBoundaryText(data, "thread_id") ||
        rows[0].required(3) != contextBoundaryInteger(data, "epoch").toString() ||
        rows[0].required(6) != v.compositionSnapshotId.value ||
        contextReadProjectionDigest(contextSnapshotFromValue(decodeStoredValue(rows[0].required(5)))) != contextBoundaryText(data, "context_digest") ||
        modelPolicySha256Text(canonicalAgentValue(decodeStoredValue(rows[0].required(4)))) != contextBoundaryText(data, "lane_digest")) {
        throw IllegalStateException("context boundary owner, lane, composition or context changed") }
    requireUserOrConsumedContinuation(tx, ThreadId(rows[0].required(2)), v.turnId, v.runId, contextBoundaryInteger(data, "epoch"))
    let debt = v.workDebt
    if (!debt.activeAttempts.isEmpty() || !debt.uncommittedDecisions.isEmpty() || !debt.unsettledOperations.isEmpty() ||
        !debt.pendingApprovals.isEmpty() || !debt.waitingExternal.isEmpty() || !debt.activeChildRuns.isEmpty() ||
        !debt.ownedTasks.isEmpty() || !debt.deferredContexts.isEmpty() || v.pendingOperationId.isSome() ||
        v.pendingApprovalId.isSome() || v.waitingExternal.isSome() || v.attemptId.isSome()) {
        throw IllegalStateException("context.boundary_durable_resource_owner_unavailable") }
    if (!tx.query("SELECT o.id FROM operations o LEFT JOIN operation_receipts receipt ON receipt.operation_id=o.id WHERE o.run_id=? AND (o.state!='committed' OR receipt.id IS NULL)",
        [SqlParameter.Text(v.runId.value)]).isEmpty() ||
        !tx.query("SELECT id FROM model_attempts WHERE run_id=? AND (lifecycle IN ('created','streaming') OR completed_at_millis IS NULL)",
            [SqlParameter.Text(v.runId.value)]).isEmpty() ||
        !tx.query("SELECT d.id FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id " +
            "WHERE a.run_id=? AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NULL",
            [SqlParameter.Text(v.runId.value)]).isEmpty()) {
        throw IllegalStateException("context boundary cannot restart unknown effects") }
    let pending = HashSet<String>()
    for (row in tx.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? " +
        "AND kind IN ('tool_call','tool_result') ORDER BY ordinal", [SqlParameter.Text(contextBoundaryText(data, "thread_id")), SqlParameter.Text(v.turnId.value)])) {
        match (decodeStoredThreadContent(row.required(0))) {
            case ThreadItemContent.ToolCall(id, _, _) =>
                if (pending.contains(id.value)) { throw IllegalStateException("duplicate canonical call at context recovery") }
                pending.add(id.value)
            case ThreadItemContent.ToolResult(id, _, _, _, _) => pending.remove(id.value)
            case _ => throw IllegalStateException("invalid canonical tool round at context recovery") }
    }
    if (!pending.isEmpty()) { throw IllegalStateException("context recovery requires terminal canonical ToolResults") }
    requireContextBoundaryBudget(tx, v.runId, contextBoundaryField(data, "usage"))
    actual
}

// Typed storage has eight usage fields; public event detail also carries its
// exact discriminator. Neither projection introduces execution authority.
func contextBoundaryBudgetEventUsage(detail: AgentValue): ExecutionUsage {
    if (detail.field("code").isNone()) { return contextBoundaryUsage(detail) }
    contextBoundaryShape(detail, ["code", "turns", "model_requests", "drain_model_requests", "tool_calls",
        "active_tools", "input_tokens", "output_tokens", "cost_micros"])
    if (contextBoundaryText(detail, "code") != "budget.updated") {
        throw IllegalStateException("context boundary accounting discriminator is invalid") }
    let fields = ArrayList<ValueField>(8)
    for (field in detail.fields where field.name != "code") { fields.add(field) }
    contextBoundaryUsage(objectValue(fields.toArray()))
}

public func requireContextBoundaryBudget(tx: SqliteTransaction, run: RunId, usage: AgentValue): Unit {
    let _ = contextBoundaryUsage(usage)
    let rows = tx.query("SELECT payload,sequence FROM app_run_events WHERE run_id=? AND json_valid(payload)=1 " +
        "AND json_extract(payload,'$.payload_type')='budget_updated' ORDER BY sequence DESC LIMIT 1", [SqlParameter.Text(run.value)])
    if (rows.size != 1 || rows[0].required(0).size > 8192) { throw IllegalStateException("context boundary accounting event missing") }
    // app_run_events uses original encodeEvent JSON, not StoredValue frames.
    // Decode through its actual JSON codec and validate the original event
    // envelope as well as the complete original ExecutionUsage.
    let event = match (decodeAgentValue(rows[0].required(0), maxBytes: 8192)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw IllegalStateException(error.describe()) }
    contextBoundaryShape(event, ["format_version", "sequence", "run_id", "kind", "timestamp_ms", "trace_id",
        "turn_id", "request_id", "tool_batch_id", "tool_call_id", "operation_id", "payload_type", "detail"])
    for (name in ["turn_id", "request_id", "tool_batch_id", "tool_call_id", "operation_id"]) {
        let value = contextBoundaryField(event, name)
        if (value.unifiedKind != ValueKind.Null && (value.unifiedKind != ValueKind.Text || value.text == "")) {
            throw IllegalStateException("context boundary accounting event metadata is invalid") } }
    if (contextBoundaryInteger(event, "format_version") != 1 || contextBoundaryInteger(event, "sequence") < 1 ||
        contextBoundaryInteger(event, "sequence").toString() != rows[0].required(1) ||
        contextBoundaryInteger(event, "timestamp_ms") < 0 || contextBoundaryText(event, "trace_id") == "" ||
        contextBoundaryText(event, "kind") != "budget" ||
        contextBoundaryText(event, "run_id") != run.value || contextBoundaryText(event, "payload_type") != "budget_updated" ||
        canonicalAgentValue(contextBoundaryUsageValue(contextBoundaryBudgetEventUsage(contextBoundaryField(event, "detail")))) != canonicalAgentValue(usage) ||
        contextBoundaryUsage(usage).activeTools != 0) { throw IllegalStateException("context boundary accounting mismatch") }
}

// This is called only from the existing legal cut transaction, after all its
// Root/Receipt, immutable old-Prepared, current context and lane checks passed.
func bindCoreContextBoundaryAtCut(tx: SqliteTransaction, continuation: DurableRunContinuationV1,
    input: AgentValue, thread: ThreadId, epoch: Int64, context: InvocationContextProjection, lane: ModelLane): DurableRunContinuationV1 {
    let request = contextBoundaryField(input, "request")
    if (contextBoundaryText(request, "run_id") != continuation.runId.value || contextBoundaryText(request, "thread_id") != thread.value ||
        contextBoundaryText(request, "lane_id") != continuation.laneId.value) { throw IllegalStateException("context boundary request ownership mismatch") }
    let requestFields = ArrayList<ValueField>()
    for (field in request.fields) { requestFields.add(if (field.name == "context_snapshot") {
        ValueField(field.name, contextSnapshotValue(context)) } else { field }) }
    let fields = ArrayList<ValueField>()
    for (field in input.fields where !["thread_id", "epoch", "context_digest", "lane_digest", "request"].contains(field.name)) { fields.add(field) }
    fields.add(ValueField("request", objectValue(requestFields.toArray())))
    fields.add(ValueField("thread_id", textValue(thread.value)))
    fields.add(ValueField("epoch", integerValue(epoch)))
    fields.add(ValueField("context_digest", textValue(contextReadProjectionDigest(context))))
    fields.add(ValueField("lane_digest", textValue(modelPolicySha256Text(canonicalAgentValue(modelLaneSnapshotValue(lane))))))
    requireContextBoundaryBudget(tx, continuation.runId, contextBoundaryField(input, "usage"))
    withContextBoundaryProjection(continuation, objectValue(fields.toArray()))
}

public func advanceContextBoundaryTurn(tx: SqliteTransaction, expected: RunContextBoundary,
    replacement: AgentValue, observedAt: Int64): RunContextBoundary {
    let actual = requireContextBoundaryCurrent(tx, expected)
    let before = actual.data()
    if (contextBoundaryText(before, "point") != "after_safe_cut" || contextBoundaryText(replacement, "point") != "turn_reserved") {
        throw IllegalStateException("context boundary turn reservation is not a single transition") }
    for (name in ["schema", "request", "tool_loop_state", "thread_id", "epoch", "context_digest", "lane_digest", "wall_start_millis"]) {
        if (canonicalAgentValue(contextBoundaryField(before, name)) != canonicalAgentValue(contextBoundaryField(replacement, name))) {
            throw IllegalStateException("turn reservation changed frozen boundary data") }
    }
    let oldUsage = contextBoundaryUsage(contextBoundaryField(before, "usage"))
    let newUsage = contextBoundaryUsage(contextBoundaryField(replacement, "usage"))
    if (oldUsage.turns == Int64.Max || newUsage.turns != oldUsage.turns + 1) { throw IllegalStateException("turn charge is not exactly one") }
    for (name in ["model_requests", "drain_model_requests", "tool_calls", "active_tools", "input_tokens", "output_tokens", "cost_micros"]) {
        if (contextBoundaryInteger(contextBoundaryField(before, "usage"), name) != contextBoundaryInteger(contextBoundaryField(replacement, "usage"), name)) {
            throw IllegalStateException("turn reservation changed another budget charge") }
    }
    let oldCounter = contextBoundaryField(before, "counter")
    let newCounter = contextBoundaryField(replacement, "counter")
    if (contextBoundaryInteger(oldCounter, "turns") == Int64.Max ||
        contextBoundaryInteger(newCounter, "turns") != contextBoundaryInteger(oldCounter, "turns") + 1) {
        throw IllegalStateException("context boundary counter did not advance exactly once") }
    for (field in oldCounter.fields where field.name != "turns") {
        if (canonicalAgentValue(field.value) != canonicalAgentValue(contextBoundaryField(newCounter, field.name))) {
            throw IllegalStateException("turn charge changed an unrelated counter") }
    }
    let oldControl = contextBoundaryField(before, "control")
    let newControl = contextBoundaryField(replacement, "control")
    if (contextBoundaryInteger(oldControl, "turn_serial") == Int64.Max ||
        contextBoundaryInteger(newControl, "turn_serial") != contextBoundaryInteger(oldControl, "turn_serial") + 1 ||
        contextBoundaryText(newControl, "active_turn_id") != actual.continuation.runId.value + "-turn-" +
            contextBoundaryInteger(newControl, "turn_serial").toString()) {
        throw IllegalStateException("context boundary turn identity was reused") }
    for (field in oldControl.fields where field.name != "turn_serial" && field.name != "active_turn_id") {
        if (canonicalAgentValue(field.value) != canonicalAgentValue(contextBoundaryField(newControl, field.name))) {
            throw IllegalStateException("turn charge changed an unrelated control serial") }
    }
    let next = withContextBoundaryProjection(actual.continuation, replacement)
    let revisions = tx.query("SELECT revision FROM run_continuations WHERE run_id=? AND digest=?",
        [SqlParameter.Text(next.runId.value), SqlParameter.Text(actual.continuation.digest)])
    if (revisions.size != 1) { throw IllegalStateException("context boundary turn CAS failed") }
    putClaimContinuation(tx, ThreadId(contextBoundaryText(before, "thread_id")), next,
        Int64.parse(revisions[0].required(0)), observedAt)
    RunContextBoundary(next)
}
