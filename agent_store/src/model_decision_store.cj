package agent_store

import std.collection.*
import std.convert.*
import agent_domain.*
import agent_runtime.*

public class DurableModelDecisionSnapshot {
    public let decision: ModelDecision
    public let usage: ?ModelUsage
    public let canonicalCommittedAtMillis: ?Int64

    public init(
        decision: ModelDecision,
        usage: ?ModelUsage,
        canonicalCommittedAtMillis: ?Int64
    ) {
        this.decision = decision
        this.usage = usage
        this.canonicalCommittedAtMillis = canonicalCommittedAtMillis
    }
}

// Durable owner for Model Attempt and Model Decision state. Streaming deltas
// never enter these tables. A validated decision and all of its stable blocks
// are inserted in one SQLite transaction.
public class SqliteModelDecisionStore <: ModelDecisionRuntimePort {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func abandonOpenAttempts(runId: RunId, abandonedAtMillis: Int64): Result<Unit> {
        if (abandonedAtMillis < 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.attempt_abandon_timestamp_invalid",
                "Attempt abandonment timestamp must not be negative"
            ))
        }
        try {
            database.execute(
                "UPDATE model_attempts SET lifecycle='abandoned'," +
                    "failure_kind='process_restart_or_retry',completed_at_millis=" +
                    abandonedAtMillis.toString() + ",last_activity_at_millis=" +
                    abandonedAtMillis.toString() + " WHERE run_id=" +
                    sqliteText(runId.value) + " AND lifecycle IN ('created','streaming')"
            )
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.attempt_abandon_failed",
                error.message,
                fields: [ErrorField("run_id", runId.value)]
            ))
        }
    }

    public func createAttempt(attempt: DurableModelAttempt): Result<Unit> {
        try {
            database.transaction { transaction =>
                persistModelAttemptInTransaction(transaction, attempt)
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.attempt_persist_failed",
                error.message,
                fields: [ErrorField("attempt_id", attempt.id.value)]
            ))
        }
    }

    public func terminalizeAttempt(
        attemptId: ModelAttemptId,
        lifecycle: ModelAttemptLifecycle,
        failureKind: String,
        completedAtMillis: Int64
    ): Result<Unit> {
        let terminal = match (lifecycle) {
            case ModelAttemptLifecycle.Failed | ModelAttemptLifecycle.Cancelled |
                 ModelAttemptLifecycle.Abandoned => true
            case _ => false
        }
        if (!terminal || completedAtMillis < 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.attempt_terminal_invalid",
                "attempt terminalization requires a failure/cancel/abandon state"
            ))
        }
        try {
            database.transaction { transaction =>
                transaction.execute(
                    "UPDATE model_attempts SET lifecycle=" +
                        sqliteText(modelAttemptLifecycleName(lifecycle)) +
                        ",failure_kind=" + sqliteText(failureKind) +
                        ",completed_at_millis=" + completedAtMillis.toString() +
                        ",last_activity_at_millis=" + completedAtMillis.toString() +
                        " WHERE id=" + sqliteText(attemptId.value) +
                        " AND lifecycle IN ('created','streaming')"
                )
                if (transaction.query("SELECT changes()")[0].required(0) == "0") {
                    requireStoreRow(
                        transaction,
                        "SELECT lifecycle,failure_kind,completed_at_millis FROM model_attempts WHERE id=" +
                            sqliteText(attemptId.value),
                        [modelAttemptLifecycleName(lifecycle), failureKind, completedAtMillis.toString()],
                        "Model Attempt terminal state drift"
                    )
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.attempt_terminalize_failed",
                error.message,
                fields: [ErrorField("attempt_id", attemptId.value)]
            ))
        }
    }

    public func persistValidatedDecision(decision: ModelDecision): Result<Unit> {
        let validated = match (decision.validationStatus) {
            case DecisionValidationStatus.Validated => true
            case _ => false
        }
        if (!validated || !decision.terminalEvidence.messageTerminalObserved) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.decision_not_validated",
                "only a validated provider-terminal decision can become durable"
            ))
        }
        try {
            database.transaction { transaction =>
                let attempt = transaction.query(
                    "SELECT semantic_request_id,lifecycle FROM model_attempts WHERE id=" +
                        sqliteText(decision.attemptId.value)
                )
                if (attempt.size != 1 ||
                    attempt[0].required(0) != decision.semanticRequestId.value) {
                    throw IllegalStateException("Model Decision does not belong to its Attempt")
                }
                let existing = transaction.query(
                    "SELECT attempt_id,semantic_request_id,validation_status," +
                        "completion_disposition,decision_outcome,content_hash,replay_hash," +
                        "provider_id,provider_response_id,terminal_evidence," +
                        "validator_version,created_at_millis FROM model_decisions WHERE id=" +
                        sqliteText(decision.id.value)
                )
                let expected = decisionRow(decision)
                if (existing.isEmpty()) {
                    if (attempt[0].required(1) == "completed") {
                        throw IllegalStateException(
                            "completed Model Attempt is missing its durable Decision"
                        )
                    }
                    transaction.execute(
                        "INSERT INTO model_decisions " +
                            "(id,attempt_id,semantic_request_id,validation_status," +
                            "completion_disposition,decision_outcome,content_hash,replay_hash," +
                            "provider_id,provider_response_id,terminal_evidence," +
                            "validator_version,created_at_millis,canonical_committed_at_millis) " +
                            "VALUES (" + sqliteText(decision.id.value) + "," +
                            decisionInsertValues(decision) + ",NULL)"
                    )
                    for (block in decision.blocks) {
                        transaction.execute(
                            "INSERT INTO model_decision_blocks " +
                                "(id,decision_id,ordinal,kind,payload,scoped_tool_call_id) VALUES (" +
                                sqliteText(block.id.value) + "," +
                                sqliteText(decision.id.value) + "," +
                                block.ordinal.toString() + "," +
                                sqliteText(modelBlockKindName(block.block.kind)) + "," +
                                sqliteText(encodeStoredModelBlock(block.block)) + "," +
                                match (block.scopedToolCallId) {
                                    case Some(value) => sqliteText(value.value)
                                    case None => "NULL"
                                } + ")"
                        )
                    }
                    transaction.execute(
                        "UPDATE model_attempts SET lifecycle='completed'," +
                            "provider_response_id=" + sqliteText(decision.providerResponseId) +
                            ",completed_at_millis=" + decision.createdAtMillis.toString() +
                            ",last_activity_at_millis=" + decision.createdAtMillis.toString() +
                            " WHERE id=" + sqliteText(decision.attemptId.value) +
                            " AND lifecycle IN ('created','streaming')"
                    )
                    requireStoreChanged(transaction, "Model Decision lost its active Attempt")
                } else {
                    requireExactModelRow(existing, expected, "Model Decision identity drift")
                    requireDecisionBlocks(transaction, decision)
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.decision_persist_failed",
                error.message,
                fields: [
                    ErrorField("attempt_id", decision.attemptId.value),
                    ErrorField("decision_id", decision.id.value)
                ]
            ))
        }
    }

    public func finalizeUsage(
        decisionId: ModelDecisionId,
        usage: ModelUsage,
        finalizedAtMillis: Int64
    ): Result<Unit> {
        if (finalizedAtMillis < 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.decision_usage_timestamp_invalid",
                "decision usage timestamp must not be negative"
            ))
        }
        try {
            let payload = encodeStoredModelUsage(usage)
            database.transaction { transaction =>
                let existing = transaction.query(
                    "SELECT payload,finalized_at_millis FROM model_decision_usage WHERE decision_id=" +
                        sqliteText(decisionId.value)
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO model_decision_usage " +
                            "(decision_id,payload,finalized_at_millis) VALUES (" +
                            sqliteText(decisionId.value) + "," + sqliteText(payload) + "," +
                            finalizedAtMillis.toString() + ")"
                    )
                } else {
                    requireExactModelRow(
                        existing,
                        [payload, finalizedAtMillis.toString()],
                        "Model Decision usage identity drift"
                    )
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.decision_usage_persist_failed",
                error.message,
                fields: [ErrorField("decision_id", decisionId.value)]
            ))
        }
    }

    public func loadDecision(decisionId: ModelDecisionId): DurableModelDecisionSnapshot {
        let rows = database.query(
            "SELECT attempt_id,semantic_request_id,validation_status," +
                "completion_disposition,decision_outcome,content_hash,replay_hash," +
                "provider_id,provider_response_id,terminal_evidence,validator_version," +
                "created_at_millis,canonical_committed_at_millis FROM model_decisions WHERE id=" +
                sqliteText(decisionId.value)
        )
        if (rows.size != 1) {
            throw IllegalStateException("durable Model Decision does not exist")
        }
        let row = rows[0]
        let blockRows = database.query(
            "SELECT id,ordinal,payload,scoped_tool_call_id FROM model_decision_blocks " +
                "WHERE decision_id=" + sqliteText(decisionId.value) + " ORDER BY ordinal"
        )
        let blocks = ArrayList<DurableDecisionBlock>()
        for (blockRow in blockRows) {
            let block = decodeStoredModelBlock(blockRow.required(2))
            blocks.add(DurableDecisionBlock(
                DecisionBlockId(blockRow.required(0)),
                parseModelDecisionInt(blockRow.required(1), "Decision block ordinal"),
                block,
                scopedToolCallId: match (blockRow[3]) {
                    case Some(value) => Some(ScopedToolCallId(value))
                    case None => None
                }
            ))
        }
        let usageRows = database.query(
            "SELECT payload FROM model_decision_usage WHERE decision_id=" +
                sqliteText(decisionId.value)
        )
        DurableModelDecisionSnapshot(
            ModelDecision(
                decisionId,
                ModelAttemptId(row.required(0)),
                SemanticModelRequestId(row.required(1)),
                blocks.toArray(),
                decodeStoredTerminalEvidence(row.required(9)),
                decisionValidationStatusFromName(row.required(2)),
                completionDispositionFromName(row.required(3)),
                decisionOutcomeFromName(row.required(4)),
                row.required(5),
                row.required(6),
                parseModelDecisionInt(row.required(10), "Decision validator version"),
                providerId: row.required(7),
                providerResponseId: row.required(8),
                createdAtMillis: parseModelDecisionInt(row.required(11), "Decision timestamp")
            ),
            if (usageRows.isEmpty()) {
                None
            } else if (usageRows.size == 1) {
                Some(decodeStoredModelUsage(usageRows[0].required(0)))
            } else {
                throw IllegalStateException("durable Model Decision has ambiguous usage")
            },
            match (row[12]) {
                case Some(value) => Some(parseModelDecisionInt(value, "canonical commit timestamp"))
                case None => None
            }
        )
    }

    public func uncommittedDecision(runId: RunId): Result<?ModelDecision> {
        try {
            let rows = database.query(
                "SELECT d.id FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id " +
                    "WHERE a.run_id=" + sqliteText(runId.value) +
                    " AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NULL " +
                    "ORDER BY d.created_at_millis,d.id"
            )
            if (rows.isEmpty()) { return Result.Ok(None) }
            if (rows.size != 1) {
                throw IllegalStateException("Run has multiple uncommitted Model Decisions")
            }
            Result.Ok(Some(loadDecision(ModelDecisionId(rows[0].required(0))).decision))
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.uncommitted_decision_load_failed",
                error.message,
                fields: [ErrorField("run_id", runId.value)]
            ))
        }
    }


    public func committedToolCallSources(
        runId: RunId
    ): Result<Array<CommittedToolCallSource>> {
        try {
            let rows = database.query(
                "SELECT d.id,b.scoped_tool_call_id,c.item_id,b.payload " +
                    "FROM model_decisions d JOIN model_attempts a ON a.id=d.attempt_id " +
                    "JOIN model_decision_blocks b ON b.decision_id=d.id " +
                    "JOIN canonical_decision_items c ON c.decision_id=d.id AND c.decision_block_id=b.id " +
                    "WHERE a.run_id=" + sqliteText(runId.value) +
                    " AND d.validation_status='validated' AND d.canonical_committed_at_millis IS NOT NULL " +
                    "AND b.scoped_tool_call_id IS NOT NULL ORDER BY d.created_at_millis,b.ordinal"
            )
            let output = ArrayList<CommittedToolCallSource>()
            for (row in rows) {
                output.add(CommittedToolCallSource(
                    ModelDecisionId(row.required(0)), ScopedToolCallId(row.required(1)),
                    ItemId(row.required(2)), decodeStoredModelBlock(row.required(3))
                ))
            }
            Result.Ok(output.toArray())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.committed_tool_calls_load_failed",
                error.message,
                fields: [ErrorField("run_id", runId.value)]
            ))
        }
    }

    public func recordCanonicalProjection(
        decisionId: ModelDecisionId,
        sources: Array<CommittedToolCallSource>
    ): Result<Unit> {
        try {
            let decisionRows = database.query(
                "SELECT validation_status,canonical_committed_at_millis FROM model_decisions WHERE id=" +
                    sqliteText(decisionId.value)
            )
            if (decisionRows.size != 1 || decisionRows[0].required(0) != "validated" ||
                decisionRows[0][1].isNone()) {
                throw IllegalStateException("Model Decision canonical projection is not committed")
            }
            let rows = database.query(
                "SELECT b.scoped_tool_call_id,c.item_id,b.payload FROM model_decision_blocks b " +
                    "JOIN canonical_decision_items c ON c.decision_id=b.decision_id " +
                    "AND c.decision_block_id=b.id WHERE b.decision_id=" +
                    sqliteText(decisionId.value) +
                    " AND b.scoped_tool_call_id IS NOT NULL ORDER BY b.ordinal"
            )
            if (rows.size != sources.size) {
                throw IllegalStateException("Committed ToolCall source count drift")
            }
            for (index in 0..rows.size) {
                let source = sources[index]
                if (source.decisionId.value != decisionId.value ||
                    rows[index].required(0) != source.scopedToolCallId.value ||
                    rows[index].required(1) != source.canonicalItemId.value ||
                    encodeStoredModelBlock(source.block) != rows[index].required(2)) {
                    throw IllegalStateException("Committed ToolCall source identity drift")
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "model.canonical_projection_attestation_failed",
                error.message,
                fields: [ErrorField("decision_id", decisionId.value)]
            ))
        }
    }

}

// Shared by the run repository's pre-HTTP atomic policy boundary. Keeping the
// exact-row check here ensures recovery reuses the persisted resolution and
// rejects identity drift instead of invoking a newer resolver.
public func persistModelAttemptInTransaction(
    transaction: SqliteTransaction,
    attempt: DurableModelAttempt
): Unit {
    let expected = attemptRow(attempt)
    let existing = transaction.query(
        "SELECT semantic_request_id,run_id,COALESCE(parent_attempt_id,'')," +
            "attempt_no,lifecycle,policy,policy_reason,started_at_millis," +
            "last_activity_at_millis,COALESCE(completed_at_millis,-1)," +
            "provider_request_id,provider_response_id,failure_kind," +
            "semantic_request_digest,wire_policy_digest,dispatch_state,replay_barrier," +
            "COALESCE(dispatch_started_at_millis,-1),COALESCE(provider_terminal_at_millis,-1) " +
            "FROM model_attempts WHERE id=" + sqliteText(attempt.id.value)
    )
    if (existing.isEmpty()) {
        transaction.execute(
            "INSERT INTO model_attempts " +
                "(id,semantic_request_id,run_id,parent_attempt_id,attempt_no," +
                "lifecycle,policy,policy_reason,started_at_millis," +
                "last_activity_at_millis,completed_at_millis,provider_request_id," +
                "provider_response_id,failure_kind,semantic_request_digest,wire_policy_digest," +
                "dispatch_state,replay_barrier,dispatch_started_at_millis," +
                "provider_terminal_at_millis) VALUES (" +
                sqliteText(attempt.id.value) + "," +
                attemptInsertValues(attempt) + ")"
        )
    } else {
        requireExactModelRow(existing, expected, "Model Attempt identity drift")
    }
}

func attemptRow(value: DurableModelAttempt): Array<String> {
    [
        value.semanticRequestId.value,
        value.runId.value,
        match (value.parentAttemptId) { case Some(parent) => parent.value; case None => "" },
        value.attemptNo.toString(),
        modelAttemptLifecycleName(value.lifecycle),
        encodeStoredValue(value.policy),
        value.policyReason,
        value.startedAtMillis.toString(),
        value.lastActivityAtMillis.toString(),
        match (value.completedAtMillis) { case Some(time) => time.toString(); case None => "-1" },
        value.providerRequestId,
        value.providerResponseId,
        value.failureKind,
        value.semanticRequestDigest,
        value.wirePolicyDigest,
        modelAttemptDispatchStateName(value.dispatchState),
        modelAttemptReplayBarrierName(value.replayBarrier),
        match (value.dispatchStartedAtMillis) { case Some(time) => time.toString(); case None => "-1" },
        match (value.providerTerminalAtMillis) { case Some(time) => time.toString(); case None => "-1" }
    ]
}

func attemptInsertValues(value: DurableModelAttempt): String {
    sqliteText(value.semanticRequestId.value) + "," + sqliteText(value.runId.value) + "," +
        match (value.parentAttemptId) { case Some(parent) => sqliteText(parent.value); case None => "NULL" } + "," +
        value.attemptNo.toString() + "," + sqliteText(modelAttemptLifecycleName(value.lifecycle)) + "," +
        sqliteText(encodeStoredValue(value.policy)) + "," + sqliteText(value.policyReason) + "," +
        value.startedAtMillis.toString() + "," + value.lastActivityAtMillis.toString() + "," +
        match (value.completedAtMillis) { case Some(time) => time.toString(); case None => "NULL" } + "," +
        sqliteText(value.providerRequestId) + "," + sqliteText(value.providerResponseId) + "," +
        sqliteText(value.failureKind) + "," + sqliteText(value.semanticRequestDigest) + "," +
        sqliteText(value.wirePolicyDigest) + "," +
        sqliteText(modelAttemptDispatchStateName(value.dispatchState)) + "," +
        sqliteText(modelAttemptReplayBarrierName(value.replayBarrier)) + "," +
        match (value.dispatchStartedAtMillis) { case Some(time) => time.toString(); case None => "NULL" } + "," +
        match (value.providerTerminalAtMillis) { case Some(time) => time.toString(); case None => "NULL" }
}

public func modelAttemptDispatchStateName(value: ModelAttemptDispatchState): String {
    match (value) {
        case ModelAttemptDispatchState.Prepared => "prepared"
        case ModelAttemptDispatchState.DispatchClaimed => "dispatch_claimed"
    }
}

public func modelAttemptReplayBarrierName(value: ModelAttemptReplayBarrier): String {
    match (value) {
        case ModelAttemptReplayBarrier.NoBarrier => "none"
        case ModelAttemptReplayBarrier.ToolEvidence => "tool_evidence"
        case ModelAttemptReplayBarrier.ProviderTerminal => "provider_terminal"
        case ModelAttemptReplayBarrier.Cancelled => "cancelled"
        case ModelAttemptReplayBarrier.RunDeadline => "run_deadline"
    }
}

func decisionRow(value: ModelDecision): Array<String> {
    [
        value.attemptId.value, value.semanticRequestId.value, "validated",
        completionDispositionName(value.completionDisposition),
        decisionOutcomeName(value.outcome), value.contentHash, value.replayHash,
        value.providerId, value.providerResponseId,
        encodeStoredTerminalEvidence(value.terminalEvidence),
        value.validatorVersion.toString(), value.createdAtMillis.toString()
    ]
}

func decisionInsertValues(value: ModelDecision): String {
    let row = decisionRow(value)
    var output = ""
    for (index in 0..row.size) {
        if (index > 0) { output += "," }
        output += if (index == 10 || index == 11) { row[index] } else { sqliteText(row[index]) }
    }
    output
}

func requireDecisionBlocks(
    transaction: SqliteTransaction,
    decision: ModelDecision
): Unit {
    let rows = transaction.query(
        "SELECT id,ordinal,kind,payload,COALESCE(scoped_tool_call_id,'') " +
            "FROM model_decision_blocks WHERE decision_id=" +
            sqliteText(decision.id.value) + " ORDER BY ordinal"
    )
    if (rows.size != decision.blocks.size) {
        throw IllegalStateException("Model Decision block count drift")
    }
    for (index in 0..rows.size) {
        let block = decision.blocks[index]
        requireExactModelSqliteRow(rows[index], [
            block.id.value,
            block.ordinal.toString(),
            modelBlockKindName(block.block.kind),
            encodeStoredModelBlock(block.block),
            match (block.scopedToolCallId) { case Some(value) => value.value; case None => "" }
        ], "Model Decision block identity drift")
    }
}

func requireExactModelRow(
    rows: Array<SqliteRow>,
    expected: Array<String>,
    message: String
): Unit {
    if (rows.size != 1) {
        throw IllegalStateException(message)
    }
    requireExactModelSqliteRow(rows[0], expected, message)
}

func requireExactModelSqliteRow(
    row: SqliteRow,
    expected: Array<String>,
    message: String
): Unit {
    if (row.size != expected.size) {
        throw IllegalStateException(message)
    }
    for (index in 0..expected.size where row.required(index) != expected[index]) {
        throw IllegalStateException(message)
    }
}

func modelAttemptLifecycleName(value: ModelAttemptLifecycle): String {
    match (value) {
        case ModelAttemptLifecycle.Created => "created"
        case ModelAttemptLifecycle.Streaming => "streaming"
        case ModelAttemptLifecycle.Completed => "completed"
        case ModelAttemptLifecycle.Failed => "failed"
        case ModelAttemptLifecycle.Cancelled => "cancelled"
        case ModelAttemptLifecycle.Abandoned => "abandoned"
    }
}

func completionDispositionName(value: CompletionDisposition): String {
    match (value) {
        case CompletionDisposition.Complete => "complete"
        case CompletionDisposition.ToolUse => "tool_use"
        case CompletionDisposition.OutputLimited => "output_limited"
        case CompletionDisposition.Filtered => "filtered"
        case CompletionDisposition.ProtocolIncomplete => "protocol_incomplete"
        case CompletionDisposition.Unknown => "unknown"
    }
}

func completionDispositionFromName(value: String): CompletionDisposition {
    match (value) {
        case "complete" => CompletionDisposition.Complete
        case "tool_use" => CompletionDisposition.ToolUse
        case "output_limited" => CompletionDisposition.OutputLimited
        case "filtered" => CompletionDisposition.Filtered
        case "protocol_incomplete" => CompletionDisposition.ProtocolIncomplete
        case "unknown" => CompletionDisposition.Unknown
        case _ => throw IllegalStateException("unknown Decision completion disposition")
    }
}

func decisionOutcomeName(value: DecisionOutcome): String {
    match (value) {
        case DecisionOutcome.Response => "response"
        case DecisionOutcome.ToolCalls => "tool_calls"
        case DecisionOutcome.Refusal => "refusal"
        case DecisionOutcome.Unknown => "unknown"
    }
}

func decisionOutcomeFromName(value: String): DecisionOutcome {
    match (value) {
        case "response" => DecisionOutcome.Response
        case "tool_calls" => DecisionOutcome.ToolCalls
        case "refusal" => DecisionOutcome.Refusal
        case "unknown" => DecisionOutcome.Unknown
        case _ => throw IllegalStateException("unknown Decision outcome")
    }
}

func decisionValidationStatusFromName(value: String): DecisionValidationStatus {
    match (value) {
        case "candidate" => DecisionValidationStatus.Candidate
        case "validated" => DecisionValidationStatus.Validated
        case "rejected" => DecisionValidationStatus.Rejected
        case _ => throw IllegalStateException("unknown Decision validation status")
    }
}

func modelBlockKindName(value: ModelBlockKind): String {
    match (value) {
        case ModelBlockKind.Text => "text"
        case ModelBlockKind.Image => "image"
        case ModelBlockKind.Reasoning => "reasoning"
        case ModelBlockKind.ToolCall => "tool_call"
        case ModelBlockKind.ToolResult => "tool_result"
        case ModelBlockKind.Refusal => "refusal"
        case ModelBlockKind.Error => "error"
        case ModelBlockKind.Unknown => "unknown"
    }
}

func encodeStoredTerminalEvidence(value: TerminalEvidence): String {
    encodeStoredValue(objectValue([
        ValueField("protocol", textValue(value.protocol)),
        ValueField("terminal_event_kind", textValue(value.terminalEventKind)),
        ValueField("raw_stop_reason", textValue(value.rawStopReason)),
        ValueField("message_terminal_observed", boolValue(value.messageTerminalObserved)),
        ValueField("stream_eof_observed", boolValue(value.streamEofObserved)),
        ValueField("adapter_version", textValue(value.adapterVersion))
    ]))
}

func decodeStoredTerminalEvidence(source: String): TerminalEvidence {
    let value = decodeStoredValue(source)
    TerminalEvidence(
        storedTextField(value, "protocol"),
        storedTextField(value, "terminal_event_kind"),
        rawStopReason: storedTextField(value, "raw_stop_reason"),
        messageTerminalObserved: storedBoolField(value, "message_terminal_observed"),
        streamEofObserved: storedBoolField(value, "stream_eof_observed"),
        adapterVersion: storedTextField(value, "adapter_version")
    )
}

func encodeStoredModelBlock(value: ModelBlock): String {
    encodeStoredValue(objectValue([
        ValueField("kind", textValue(modelBlockKindName(value.kind))),
        ValueField("text", textValue(value.text)),
        ValueField("call_id", textValue(value.callId)),
        ValueField("name", textValue(value.name)),
        ValueField("arguments", value.arguments),
        ValueField("is_error", boolValue(value.isError)),
        ValueField("receipt_id", textValue(value.receiptId)),
        ValueField("opaque_state", match (value.opaqueState) {
            case Some(state) => objectValue([
                ValueField("provider_id", textValue(state.providerId)),
                ValueField("protocol", textValue(state.protocol)),
                ValueField("item_id", textValue(state.itemId)),
                ValueField("payload", textValue(state.payload)),
                ValueField("replay_required", boolValue(state.replayRequired))
            ])
            case None => nullValue()
        }),
        ValueField("image", match (value.image) {
            case Some(image) => objectValue([
                ValueField("source_kind", textValue(match (image.sourceKind) {
                    case ModelImageSourceKind.Url => "url"
                    case ModelImageSourceKind.Base64 => "base64"
                })),
                ValueField("data", textValue(image.data)),
                ValueField("media_type", textValue(image.mediaType)),
                ValueField("detail", textValue(match (image.detail) {
                    case ModelImageDetail.Auto => "auto"
                    case ModelImageDetail.Low => "low"
                    case ModelImageDetail.High => "high"
                }))
            ])
            case None => nullValue()
        })
    ]))
}

func decodeStoredModelBlock(source: String): ModelBlock {
    let value = decodeStoredValue(source)
    let opaqueValue = storedField(value, "opaque_state")
    let imageValue = storedField(value, "image")
    ModelBlock(
        modelBlockKindFromName(storedTextField(value, "kind")),
        text: storedTextField(value, "text"),
        callId: storedTextField(value, "call_id"),
        name: storedTextField(value, "name"),
        arguments: storedField(value, "arguments"),
        isError: storedBoolField(value, "is_error"),
        receiptId: storedTextField(value, "receipt_id"),
        opaqueState: if (opaqueValue.kind == ValueKind.Null) {
            None
        } else {
            Some(OpaqueProviderState(
                storedTextField(opaqueValue, "provider_id"),
                storedTextField(opaqueValue, "protocol"),
                storedTextField(opaqueValue, "payload"),
                itemId: storedTextField(opaqueValue, "item_id"),
                replayRequired: storedBoolField(opaqueValue, "replay_required")
            ))
        },
        image: if (imageValue.kind == ValueKind.Null) {
            None
        } else {
            Some(ModelImage(
                match (storedTextField(imageValue, "source_kind")) {
                    case "url" => ModelImageSourceKind.Url
                    case "base64" => ModelImageSourceKind.Base64
                    case _ => throw IllegalStateException("unknown stored model image source")
                },
                storedTextField(imageValue, "data"),
                mediaType: storedTextField(imageValue, "media_type"),
                detail: match (storedTextField(imageValue, "detail")) {
                    case "auto" => ModelImageDetail.Auto
                    case "low" => ModelImageDetail.Low
                    case "high" => ModelImageDetail.High
                    case _ => throw IllegalStateException("unknown stored model image detail")
                }
            ))
        }
    )
}

func modelBlockKindFromName(value: String): ModelBlockKind {
    match (value) {
        case "text" => ModelBlockKind.Text
        case "image" => ModelBlockKind.Image
        case "reasoning" => ModelBlockKind.Reasoning
        case "tool_call" => ModelBlockKind.ToolCall
        case "tool_result" => ModelBlockKind.ToolResult
        case "refusal" => ModelBlockKind.Refusal
        case "error" => ModelBlockKind.Error
        case "unknown" => ModelBlockKind.Unknown
        case _ => throw IllegalStateException("unknown stored Model block kind")
    }
}

func encodeStoredModelUsage(value: ModelUsage): String {
    encodeStoredValue(objectValue([
        ValueField("input_tokens", integerValue(value.inputTokens)),
        ValueField("output_tokens", integerValue(value.outputTokens)),
        ValueField("reasoning_tokens", integerValue(value.reasoningTokens)),
        ValueField("cache_read_tokens", integerValue(value.cacheReadTokens)),
        ValueField("cache_write_tokens", integerValue(value.cacheWriteTokens)),
        ValueField("cost_micros", match (value.costMicros) {
            case Some(cost) => integerValue(cost)
            case None => nullValue()
        }),
        ValueField("source", textValue(modelUsageSourceName(value.source))),
        ValueField("evidence", match (value.evidence) {
            case Some(evidence) => objectValue([
                ValueField("protocol", textValue(evidence.protocol)),
                ValueField("event_kind", textValue(evidence.eventKind)),
                ValueField("provider_response_id", textValue(evidence.providerResponseId))
            ])
            case None => nullValue()
        })
    ]))
}

func decodeStoredModelUsage(source: String): ModelUsage {
    let value = decodeStoredValue(source)
    let cost = storedField(value, "cost_micros")
    let usageSource = match (value.field("source")) {
        case Some(item) =>
            if (item.kind != ValueKind.Text) {
                throw IllegalStateException("Decision usage source has invalid type")
            }
            modelUsageSourceFromName(item.text)
        case None => ModelUsageSource.Unknown
    }
    let usageEvidence: ?ModelUsageEvidence = match (value.field("evidence")) {
        case None => None
        case Some(item) =>
            if (item.kind == ValueKind.Null) {
                None
            } else if (item.kind == ValueKind.Object) {
                Some(ModelUsageEvidence(
                    storedTextField(item, "protocol"),
                    storedTextField(item, "event_kind"),
                    providerResponseId: storedTextField(item, "provider_response_id")
                ))
            } else {
                throw IllegalStateException("Decision usage evidence has invalid type")
            }
    }
    ModelUsage(
        inputTokens: storedIntField(value, "input_tokens"),
        outputTokens: storedIntField(value, "output_tokens"),
        reasoningTokens: storedIntField(value, "reasoning_tokens"),
        cacheReadTokens: storedIntField(value, "cache_read_tokens"),
        cacheWriteTokens: storedIntField(value, "cache_write_tokens"),
        costMicros: if (cost.kind == ValueKind.Null) {
            None
        } else if (cost.kind == ValueKind.Number) {
            Some(parseModelDecisionInt(cost.number, "Decision usage cost"))
        } else {
            throw IllegalStateException("Decision usage cost has invalid type")
        },
        source: usageSource,
        evidence: usageEvidence
    )
}

func parseModelDecisionInt(value: String, field: String): Int64 {
    try { Int64.parse(value) } catch (_: Exception) {
        throw IllegalStateException(field + " is not an integer")
    }
}
