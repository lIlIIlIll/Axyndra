package agent_host_runtime

import agent_domain.*
import agent_store.*
import model_provider_runtime.*
import yjson.*
import yjson_support.*

// Concrete model/Attempt authority remains in this trusted Product adapter.
// It borrows a fixed-purpose pin transaction from the sole artifact owner;
// Runtime gate checks stay outside that transaction, before and after I/O.
public func stageHostModelPayload(artifacts: HostArtifactStore, dispatch: ModelProviderDispatch,
    gate: HostModelProviderDispatchGate, hexadecimal: String, maximum: Int64): Result<AgentValue> {
    match (gate.verifyProcessOwner(dispatch, ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "model-http"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let result = artifacts.stagePreparedPayload("inference", hexadecimal, maximum, HostModelArtifactPayloadPin(dispatch))
    if (result.isError()) { return result }
    match (gate.verifyProcessOwner(dispatch, ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "model-http"))) {
        case Result.Err(error) => Result.Err(error); case Result.Ok(_) => result }
}

public func readHostModelPayload(artifacts: HostArtifactStore, dispatch: ModelProviderDispatch,
    gate: HostModelProviderDispatchGate, payload: AgentValue, maximum: Int64): Result<Array<Byte>> {
    match (gate.verifyProcessOwner(dispatch, ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "model-http"))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let result = artifacts.readPreparedPayload(payload, maximum, HostModelArtifactPayloadPin(dispatch))
    // The former method returned a missing Store before its final gate check.
    if (result.isError() && result.error().getOrThrow().code == "artifact.model_store_required") { return result }
    match (gate.verifyProcessOwner(dispatch, ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "model-http"))) {
        case Result.Err(error) => Result.Err(error); case Result.Ok(_) => result }
}

class HostModelArtifactPayloadPin <: HostArtifactPayloadPin {
    private let dispatch: ModelProviderDispatch
    init(dispatch: ModelProviderDispatch) { this.dispatch = dispatch }
    public func requireCurrent(transaction: SqliteTransaction): Unit { requireModelPayloadOwner(transaction, dispatch) }
    public func retain(transaction: SqliteTransaction, payload: AgentValue): Unit {
        let evidence = modelPayloadEvidence(dispatch, payload)
        let prior = transaction.query("SELECT payload FROM audit_events WHERE kind='model_payload_prepared' " +
            "AND run_id=? AND operation_id IS NULL", [SqlParameter.Text(dispatch.runId.value)])
        var same: Int64 = 0
        for (row in prior) {
            let existing = decodeStoredValue(row.required(0))
            if (existing.field("identity").getOrThrow().field("attempt_id").getOrThrow().text == dispatch.attemptId.value) {
                if (row.required(0) != encodeStoredValue(evidence)) { throw IllegalStateException("model Attempt payload changed") }
                same += 1
            }
        }
        if (same > 1 || (same == 0 && prior.size >= 256)) { throw IllegalStateException("model payload pin history is exhausted or ambiguous") }
        if (same == 0) {
            transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                "VALUES(?,?,NULL,'model_payload_prepared',?,?)", [SqlParameter.Text(dispatch.threadId.value),
                    SqlParameter.Text(dispatch.runId.value), SqlParameter.Text(encodeStoredValue(evidence)),
                    SqlParameter.Int64Value(agentUtcMillis())])
        }
    }
    public func requireRetained(transaction: SqliteTransaction, payload: AgentValue): Unit {
        let witness = transaction.query("SELECT id FROM audit_events WHERE kind='model_payload_prepared' " +
            "AND thread_id=? AND run_id=? AND operation_id IS NULL AND payload=?", [
                SqlParameter.Text(dispatch.threadId.value), SqlParameter.Text(dispatch.runId.value),
                SqlParameter.Text(encodeStoredValue(modelPayloadEvidence(dispatch, payload)))])
        if (witness.size != 1) { throw IllegalStateException("model payload is not pinned to this actual Attempt") }
    }
    public func storageRequiredError(): AgentError {
        AgentError(AgentErrorKind.PermissionDenied, "artifact.model_store_required", "model payload requires its canonical Store",
            fields: [ErrorField("artifact", "")])
    }
    public func retentionError(reference: String): AgentError {
        AgentError(AgentErrorKind.Conflict, "artifact.model_payload_not_pinned",
            "model payload differs from its current claimed Attempt or immutable content", fields: [ErrorField("artifact", reference)])
    }
    public func readError(): AgentError {
        AgentError(AgentErrorKind.Conflict, "artifact.model_payload_invalid",
            "model payload content or its actual Attempt pin changed", fields: [ErrorField("artifact", "")])
    }
}

func modelPayloadEvidence(dispatch: ModelProviderDispatch, payload: AgentValue): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.model-payload-preparation/v1")),
        ValueField("identity", dispatch.identity()), ValueField("role", textValue("inference")), ValueField("payload", payload)])
}
func requireModelPayloadOwner(transaction: SqliteTransaction, dispatch: ModelProviderDispatch): Unit {
    // Do not call the Runtime gate while holding a Store transaction. The
    // host-held seal was checked outside; here only persisted facts and its
    // exact token are read, atomically with the Artifact witness. Poll the
    // already-cancelled bit with time0, then compare the deadline as data: do
    // not fire cancellation callbacks while owning this Store transaction.
    if (dispatch.cancellation.isCancelled(nowMillis: 0) ||
        (dispatch.cancellation.deadlineMillis > 0 && dispatch.cancellation.deadlineMillis <= agentUtcMillis())) {
        throw IllegalStateException("model payload owner cancelled")
    }
    let rows = transaction.query("SELECT a.id FROM model_attempts a JOIN runs r ON r.id=a.run_id " +
        "JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id AND turn.thread_id=r.thread_id " +
        "JOIN run_continuations c ON c.run_id=r.id WHERE a.id=? AND a.run_id=? AND r.thread_id=? " +
        "AND r.epoch=? AND a.provider_request_id=? AND a.semantic_request_digest=? " +
        "AND r.state='running' AND t.active_turn_id=r.turn_id AND turn.active_run_id=r.id " +
        "AND c.active_attempt_id=a.id AND a.lifecycle='streaming' AND a.dispatch_state='dispatch_claimed' " +
        "AND a.dispatch_started_at_millis IS NOT NULL AND a.completed_at_millis IS NULL " +
        "AND a.replay_barrier NOT IN ('cancelled','run_deadline') " +
        "AND NOT EXISTS(SELECT 1 FROM model_decisions d WHERE d.attempt_id=a.id)", [
            SqlParameter.Text(dispatch.attemptId.value), SqlParameter.Text(dispatch.runId.value),
            SqlParameter.Text(dispatch.threadId.value), SqlParameter.Int64Value(dispatch.epoch),
            SqlParameter.Text(dispatch.requestId), SqlParameter.Text(dispatch.inputDigest)])
    if (rows.size != 1) { throw IllegalStateException("model payload requires its exact current claimed Attempt") }
}
