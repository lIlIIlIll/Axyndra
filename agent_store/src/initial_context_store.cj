package agent_store

import agent_domain.*
import agent_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

public func isInitialContextRequest(value: AgentValue): Bool {
    if (!httpIntentExactFields(value, ["schema", "run_id", "session_id", "epoch", "model", "prompt", "system",
        "skill_stack", "lane_id", "budget", "tool_context", "capabilities"]) ||
        httpIntentText(value, "schema") != "axyndra.accepted-context-request/v1") { return false }
    for (key in ["run_id", "session_id", "model", "prompt", "system", "lane_id"]) {
        if (value.field(key).getOrThrow().unifiedKind != ValueKind.Text) { return false } }
    for (key in ["run_id", "session_id", "model", "lane_id"]) {
        if (httpIntentText(value, key) == "") { return false } }
    if (value.field("epoch").getOrThrow().unifiedKind != ValueKind.Number ||
        value.field("budget").getOrThrow().unifiedKind != ValueKind.Object ||
        value.field("tool_context").getOrThrow().unifiedKind != ValueKind.Object ||
        value.field("capabilities").getOrThrow().unifiedKind != ValueKind.List) { return false }
    for (capability in value.field("capabilities").getOrThrow().items) {
        if (!httpIntentExactFields(capability, ["kind", "resource"]) ||
            capability.field("kind").getOrThrow().unifiedKind != ValueKind.Text ||
            capability.field("resource").getOrThrow().unifiedKind != ValueKind.Text) { return false } }
    try { let _ = contextSnapshotFromValue(value.field("skill_stack").getOrThrow()); true }
        catch (_: Exception) { false }
}

// This is the existing continuation register, not an effect admission. A
// primitive ID cannot replace a model/approval checkpoint or another epoch.
public func bindAcceptedContextRequestInTransaction(tx: SqliteTransaction, run: RunId, thread: SessionId,
    epoch: Int64, initiator: ThreadItemContent, request: AgentValue, observedAtMillis: Int64): Unit {
    if (!isInitialContextRequest(request) || epoch < 1 ||
        httpIntentText(request, "run_id") != run.value || httpIntentText(request, "session_id") != thread.value ||
        request.field("epoch").getOrThrow().unifiedKind != ValueKind.Number ||
        request.field("epoch").getOrThrow().asNumberText() != epoch.toString()) {
        throw IllegalStateException("initial context request identity is invalid") }
    match (initiator) { case ThreadItemContent.UserMessage(parts) =>
        if (parts.isEmpty()) { throw IllegalStateException("initial context has no user input") }
        match (parts[0]) { case ThreadMessagePart.Text(value) =>
            if (value != httpIntentText(request, "prompt")) { throw IllegalStateException("initial prompt differs from user Item") }
            case _ => throw IllegalStateException("initial context requires the canonical user prompt") }
        case ThreadItemContent.SystemNote(text) =>
            if (text != "Host continuation") { throw IllegalStateException("unsupported initial context initiator") }
        case _ => throw IllegalStateException("initial context cannot invent another initiator kind") }
    let encoded = encodeStoredValue(request)
    let frozen = decodeStoredValue(encoded) // Enforce the actual durable decoder limit before mutation.
    let rows = tx.query("SELECT r.turn_id,r.skill_snapshot,r.budget,i.payload,c.revision,c.payload,c.digest,r.started_at_millis,r.lane_snapshot " +
        "FROM runs r JOIN turns t ON t.id=r.turn_id JOIN threads th ON th.id=r.thread_id " +
        "JOIN items i ON i.id=t.user_item_id JOIN run_continuations c ON c.run_id=r.id " +
        "WHERE r.id=? AND r.thread_id=? AND r.epoch=? AND r.state='running' AND r.finished_at_millis IS NULL " +
        "AND t.state='active' AND t.active_run_id=r.id AND th.active_turn_id=t.id " +
        "AND i.thread_id=r.thread_id AND i.turn_id=t.id",
        [SqlParameter.Text(run.value), SqlParameter.Text(thread.value), SqlParameter.Int64Value(epoch)])
    if (rows.size != 1 || rows[0].required(1) != encodeStoredValue(frozen.field("skill_stack").getOrThrow()) ||
        rows[0].required(2) != encodeStoredValue(frozen.field("budget").getOrThrow()) ||
        rows[0].required(3) != encodeStoredThreadContent(initiator) || observedAtMillis < Int64.parse(rows[0].required(7))) {
        throw IllegalStateException("initial context request lost actual Run, user Item, budget or context") }
    if (modelLaneFromSnapshotValue(decodeStoredValue(rows[0].required(8))).modelId != httpIntentText(frozen, "model")) {
        throw IllegalStateException("initial context model differs from actual model lane") }
    if (threadItemKind(initiator) == ItemKind.SystemNote) {
        requireConsumedContinuationRun(tx, ThreadId(thread.value), SemanticTurnId(rows[0].required(0)), run, epoch)
        let claim = tx.query("SELECT payload FROM audit_events WHERE run_id=? AND thread_id=? AND kind='host_continuation_claim_consumed_v1'",
            [SqlParameter.Text(run.value), SqlParameter.Text(thread.value)])
        let original = decodeStoredValue(claim[0].required(0)).field("request").getOrThrow()
        let model = modelRequestFromSnapshotValue(original.field("model_input").getOrThrow(), "").value().getOrThrow()
        if (model.messages.size != 1 || model.messages[0].blocks.isEmpty() || model.messages[0].blocks[0].text != httpIntentText(frozen, "prompt") ||
            model.system != httpIntentText(frozen, "system") || model.model != httpIntentText(frozen, "model") ||
            encodeStoredValue(original.field("context").getOrThrow()) != encodeStoredValue(frozen.field("skill_stack").getOrThrow()) ||
            encodeStoredValue(original.field("tool_context").getOrThrow()) != encodeStoredValue(frozen.field("tool_context").getOrThrow()) ||
            encodeStoredValue(original.field("capabilities").getOrThrow()) != encodeStoredValue(frozen.field("capabilities").getOrThrow())) {
            throw IllegalStateException("continuation context request differs from its consumed frozen input") }
    }
    let current = decodeDurableRunContinuation(rows[0].required(5))
    if (current.digest != rows[0].required(6) || current.runId.value != run.value || current.turnId.value != rows[0].required(0) ||
        current.laneId.value != httpIntentText(frozen, "lane_id")) { throw IllegalStateException("initial continuation identity changed") }
    match (current.phase) { case RunExecutionPhase.Accepted(_) => (); case _ => throw IllegalStateException("initial context requires Accepted phase") }
    if (!tx.query("SELECT id FROM operations WHERE run_id=?", [SqlParameter.Text(run.value)]).isEmpty() ||
        !tx.query("SELECT id FROM model_attempts WHERE run_id=?", [SqlParameter.Text(run.value)]).isEmpty() ||
        !tx.query("SELECT id FROM items WHERE thread_id=? AND turn_id=? AND id!=(SELECT user_item_id FROM turns WHERE id=?)",
            [SqlParameter.Text(thread.value), SqlParameter.Text(current.turnId.value), SqlParameter.Text(current.turnId.value)]).isEmpty() ||
        current.attemptId.isSome() || current.pendingOperationId.isSome() || current.pendingApprovalId.isSome() ||
        current.toolBatch.isSome() || current.waitingExternal.isSome()) {
        throw IllegalStateException("initial context cannot replace already admitted work") }
    let debt = current.workDebt
    if (!debt.activeAttempts.isEmpty() || !debt.uncommittedDecisions.isEmpty() || !debt.unsettledOperations.isEmpty() ||
        !debt.pendingApprovals.isEmpty() || !debt.waitingExternal.isEmpty() || !debt.activeChildRuns.isEmpty() ||
        !debt.ownedTasks.isEmpty() || !debt.deferredContexts.isEmpty() || !debt.unclaimedInputs.isEmpty()) {
        throw IllegalStateException("initial context cannot overwrite work debt") }
    match (optionalRunRequestSnapshotFromDurableContinuation(current)) {
        case Some(old) =>
            if (encodeStoredValue(old) != encoded) { throw IllegalStateException("initial context request is immutable") }
            return
        case None => () }
    let next = withRunRequestSnapshotProjection(current, frozen)
    let _ = decodeDurableRunContinuation(encodeDurableRunContinuation(next))
    putClaimContinuation(tx, ThreadId(thread.value), next, Int64.parse(rows[0].required(4)), observedAtMillis)
    let sequence = Int64.parse(tx.query("SELECT last_sequence FROM thread_commit_heads WHERE thread_id=?",
        [SqlParameter.Text(thread.value)])[0].required(0))
    tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) VALUES (?,?,NULL,?,?,?,?)",
        [SqlParameter.Text(thread.value), SqlParameter.Text(run.value), SqlParameter.Text("initial_context_request_bound"),
            SqlParameter.Text(encodeStoredValue(objectValue([ValueField("epoch", integerValue(epoch)),
                ValueField("request_digest", textValue(modelPolicySha256Text(encoded))),
                ValueField("continuation_digest", textValue(next.digest))]))),
            SqlParameter.Int64Value(observedAtMillis), SqlParameter.Int64Value(sequence)])
}
