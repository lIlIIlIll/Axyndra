package agent_store

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// Auxiliary model effects use the existing Attempt table and audit stream.
// The original continuation is read and compared, never replaced by a model
// checkpoint; a pending Tool approval and all unrelated debt remain byte exact.
func internalModelOwner(transaction: SqliteTransaction, input: AgentValue): AgentValue {
    let run = httpIntentText(input, "run_id")
    let rows = transaction.query("SELECT r.thread_id,r.turn_id,r.epoch,r.state,c.payload,c.digest,c.revision," +
        "initial.kind,initial.provenance,initial.payload,r.lane_snapshot,r.skill_snapshot " +
        "FROM runs r JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id " +
        "JOIN items initial ON initial.id=turn.user_item_id JOIN run_continuations c ON c.run_id=r.id " +
        "WHERE r.id=? AND t.active_turn_id=r.turn_id AND turn.active_run_id=r.id AND turn.state='active'",
        [SqlParameter.Text(run)])
    if (rows.size != 1) { throw IllegalStateException("internal model has no current Run enclosure") }
    let row = rows[0]
    if (row.required(0) != httpIntentText(input, "thread_id") ||
        Int64.parse(row.required(2)) != Int64.parse(input.field("epoch").getOrThrow().asNumberText())) {
        throw IllegalStateException("internal model Run or epoch changed")
    }
    let current = decodeDurableRunContinuation(row.required(4))
    if (current.runId.value != run || current.turnId.value != row.required(1) || current.digest != row.required(5)) {
        throw IllegalStateException("internal model continuation is inconsistent")
    }
    let purpose = httpIntentText(input, "purpose")
    if (purpose == "approval_review") {
        if (row.required(3) != "waiting_approval" || current.pendingApprovalId.isNone() ||
            current.pendingOperationId.isNone() ||
            match (current.phase) { case RunExecutionPhase.WaitingApproval(_) => false; case _ => true }) {
            throw IllegalStateException("approval review requires its real pending approval")
        }
        let decisions = transaction.query("SELECT operation_id FROM approval_decisions WHERE operation_id=?",
            [SqlParameter.Text(current.pendingOperationId.getOrThrow().value)])
        if (!decisions.isEmpty()) { throw IllegalStateException("approval review cannot follow a consumed decision") }
    } else if (purpose == "context_compaction") {
        let initial = decodeStoredProvenance(row.required(8))
        if (row.required(3) != "running" || row.required(7) != "system_note" ||
            initial.source != "model_maintenance" || initial.runId.isNone() ||
            initial.runId.getOrThrow().value != run || initial.operationId.isSome() || initial.directOrigin.isSome() ||
            match (decodeStoredThreadContent(row.required(9))) {
                case ThreadItemContent.SystemNote(text) => text != "Model maintenance: context_compaction"
                case _ => true } ||
            current.pendingApprovalId.isSome() || current.pendingOperationId.isSome() || current.toolBatch.isSome() ||
            !current.workDebt.activeAttempts.isEmpty() || !current.workDebt.unsettledOperations.isEmpty() ||
            !current.workDebt.uncommittedDecisions.isEmpty()) {
            throw IllegalStateException("compaction requires its actual zero-Tool maintenance Run")
        }
    } else { throw IllegalStateException("unknown internal model purpose") }
    objectValue([ValueField("thread_id", textValue(row.required(0))), ValueField("turn_id", textValue(row.required(1))),
        ValueField("epoch", integerValue(Int64.parse(row.required(2)))), ValueField("state", textValue(row.required(3))),
        ValueField("continuation_digest", textValue(row.required(5))),
        ValueField("continuation_payload_digest", textValue(modelPolicySha256Text(row.required(4)))),
        ValueField("continuation_revision", integerValue(Int64.parse(row.required(6)))),
        ValueField("lane_digest", textValue(modelPolicySha256Text(row.required(10)))),
        ValueField("context_digest", textValue(modelPolicySha256Text(row.required(11))))])
}

func internalModelAudit(transaction: SqliteTransaction, run: RunId, kind: String,
    payload: AgentValue, at: Int64): Unit {
    let encoded = encodeStoredValue(payload) // Existing 8 MiB durable bound.
    let row = transaction.query("SELECT r.thread_id,h.last_sequence FROM runs r " +
        "JOIN thread_commit_heads h ON h.thread_id=r.thread_id WHERE r.id=?", [SqlParameter.Text(run.value)])
    if (row.size != 1) { throw IllegalStateException("internal model audit owner is missing") }
    transaction.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence) " +
        "VALUES (?,?,NULL,?,?,?,?)", [SqlParameter.Text(row[0].required(0)), SqlParameter.Text(run.value),
        SqlParameter.Text(kind), SqlParameter.Text(encoded), SqlParameter.Int64Value(at),
        SqlParameter.Int64Value(Int64.parse(row[0].required(1)))])
}

public func internalModelWitness(transaction: SqliteTransaction, attempt: ModelAttemptId, run: RunId): AgentValue {
    let rows = transaction.query("SELECT payload FROM audit_events WHERE run_id=? AND kind='internal_model_prepared' ORDER BY id DESC LIMIT 4097",
        [SqlParameter.Text(run.value)])
    if (rows.size > 4096) { throw IllegalStateException("internal model audit bound exceeded") }
    var found: ?AgentValue = None
    for (row in rows) {
        let value = decodeStoredValue(row.required(0))
        if (httpIntentText(value, "attempt_id") == attempt.value) {
            if (found.isSome()) { throw IllegalStateException("duplicate internal model witness") }
            found = Some(value)
        }
    }
    found.getOrThrow()
}

public func verifyInternalModelAttemptCurrent(transaction: SqliteTransaction,
    attempt: ModelAttemptId, run: RunId): AgentValue {
    let witness = internalModelWitness(transaction, attempt, run)
    if (!httpIntentExactFields(witness, ["schema", "attempt_id", "input", "owner"]) ||
        httpIntentText(witness, "schema") != "axyndra.internal-model-witness/v1" ||
        httpIntentText(witness, "attempt_id") != attempt.value) {
        throw IllegalStateException("internal model witness schema is invalid")
    }
    let input = witness.field("input").getOrThrow()
    if (!httpIntentExactFields(input, ["schema", "purpose", "thread_id", "run_id", "epoch", "request_id",
        "semantic_digest", "wire_policy_digest", "request"]) ||
        httpIntentText(input, "schema") != "axyndra.internal-model-input/v1" || httpIntentText(input, "run_id") != run.value) {
        throw IllegalStateException("internal model input witness schema is invalid")
    }
    let owner = internalModelOwner(transaction, input)
    if (canonicalAgentValue(owner) != canonicalAgentValue(witness.field("owner").getOrThrow())) {
        throw IllegalStateException("internal model parent continuation changed")
    }
    let request = input.field("request").getOrThrow()
    let rows = transaction.query("SELECT semantic_request_digest,wire_policy_digest,provider_request_id,policy_reason " +
        "FROM model_attempts WHERE id=? AND run_id=?", [SqlParameter.Text(attempt.value), SqlParameter.Text(run.value)])
    if (rows.size != 1 || rows[0].required(0) != httpIntentText(input, "semantic_digest") ||
        rows[0].required(0) != modelPolicySha256Text(canonicalAgentValue(request)) ||
        rows[0].required(1) != httpIntentText(input, "wire_policy_digest") ||
        rows[0].required(2) != httpIntentText(input, "request_id") ||
        rows[0].required(3) != "internal_" + httpIntentText(input, "purpose")) {
        throw IllegalStateException("internal model Attempt differs from frozen neutral input")
    }
    witness
}

public func prepareInternalModelAttemptInTransaction(transaction: SqliteTransaction,
    attempt: DurableModelAttempt, input: InternalModelAttemptInput): Unit {
    if (attempt.runId.value != input.runId.value || attempt.providerRequestId != input.requestId ||
        attempt.policyReason != internalModelPolicyReason(input.purpose) ||
        attempt.semanticRequestDigest != input.semanticDigest || attempt.wirePolicyDigest != input.wirePolicyDigest ||
        attempt.lifecycle != ModelAttemptLifecycle.Created || attempt.dispatchState != ModelAttemptDispatchState.Prepared ||
        attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier || attempt.attemptNo < 1 ||
        attempt.completedAtMillis.isSome() || attempt.dispatchStartedAtMillis.isSome()) {
        throw IllegalStateException("invalid internal model Attempt prepare")
    }
    let owner = internalModelOwner(transaction, input.value())
    let active = transaction.query("SELECT id FROM model_attempts WHERE run_id=? AND lifecycle IN ('created','streaming')",
        [SqlParameter.Text(input.runId.value)])
    if (!active.isEmpty()) { throw IllegalStateException("another model Attempt still owns this Run") }
    if (!transaction.query("SELECT id FROM model_attempts WHERE provider_request_id=?",
        [SqlParameter.Text(input.requestId)]).isEmpty()) {
        throw IllegalStateException("internal model request identity was already used")
    }
    // Encode before inserting: oversize input cannot leave a half-prepared row.
    let witness = objectValue([ValueField("schema", textValue("axyndra.internal-model-witness/v1")),
        ValueField("attempt_id", textValue(attempt.id.value)), ValueField("input", input.value()), ValueField("owner", owner)])
    let _ = encodeStoredValue(witness)
    persistModelAttemptInTransaction(transaction, attempt)
    internalModelAudit(transaction, input.runId, "internal_model_prepared", witness, attempt.startedAtMillis)
}

public func settleInternalModelAttemptInTransaction(transaction: SqliteTransaction,
    attempt: ModelAttemptId, input: InternalModelAttemptInput, outcome: Result<ModelReply>, completedAt: Int64): Unit {
    let witness = verifyInternalModelAttemptCurrent(transaction, attempt, input.runId)
    if (canonicalAgentValue(witness.field("input").getOrThrow()) != canonicalAgentValue(input.value()) || completedAt < 0) {
        throw IllegalStateException("internal model settlement input drift")
    }
    let rows = transaction.query("SELECT lifecycle,dispatch_state,dispatch_started_at_millis FROM model_attempts WHERE id=?",
        [SqlParameter.Text(attempt.value)])
    if (rows.size != 1 || rows[0].required(0) != "streaming" || rows[0].required(1) != "dispatch_claimed" || rows[0][2].isNone()) {
        throw IllegalStateException("internal model settlement requires its actual claimed dispatch")
    }
    let lifecycle: String
    let failure: String
    let value: AgentValue
    match (outcome) {
        case Result.Ok(reply) =>
            if (!reply.acceptedOutput || reply.terminalEvidence.isNone() || !reply.terminalEvidence.getOrThrow().messageTerminalObserved) {
                throw IllegalStateException("internal model success lacks provider terminal evidence")
            }
            for (block in reply.blocks) {
                if (block.kind != ModelBlockKind.Text && block.kind != ModelBlockKind.Reasoning) {
                    throw IllegalStateException("internal model reply cannot contain tool or replay instructions")
                }
            }
            lifecycle = "completed"; failure = ""
            // Persist output as neutral data; it is not a canonical conversation
            // Decision, a ToolCall, or an approval grant.
            value = objectValue([ValueField("ok", boolValue(true)),
                ValueField("reply", modelRequestSnapshotValue(ModelRequest("internal-result",
                    [ModelMessage(ModelRole.Assistant, reply.blocks)], tools: [], toolChoice: ModelToolChoice.NoTools))),
                ValueField("input_tokens", integerValue(reply.usage.inputTokens)),
                ValueField("output_tokens", integerValue(reply.usage.outputTokens)),
                ValueField("reasoning_tokens", integerValue(reply.usage.reasoningTokens))])
        case Result.Err(error) =>
            lifecycle = if (error.kind == AgentErrorKind.Cancelled) { "cancelled" } else { "failed" }
            failure = error.code
            value = objectValue([ValueField("ok", boolValue(false)), ValueField("code", textValue(error.code))])
    }
    let result = objectValue([ValueField("attempt_id", textValue(attempt.value)),
        ValueField("purpose", textValue(internalModelPurposeName(input.purpose))),
        ValueField("input_digest", textValue(input.semanticDigest)), ValueField("result", value)])
    let _ = encodeStoredValue(result)
    transaction.execute("UPDATE model_attempts SET lifecycle=?,failure_kind=?,completed_at_millis=?,last_activity_at_millis=? " +
        "WHERE id=? AND lifecycle='streaming' AND dispatch_state='dispatch_claimed'",
        [SqlParameter.Text(lifecycle), SqlParameter.Text(failure), SqlParameter.Int64Value(completedAt),
            SqlParameter.Int64Value(completedAt), SqlParameter.Text(attempt.value)])
    requireStoreChanged(transaction, "internal model settlement raced")
    internalModelAudit(transaction, input.runId, "internal_model_settled", result, completedAt)
}
