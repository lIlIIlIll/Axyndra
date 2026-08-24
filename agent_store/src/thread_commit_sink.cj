package agent_store

import std.collection.*
import std.convert.*
import agent_domain.*
import agent_runtime.*

// SQLite is the canonical durable owner; ThreadCoordinator is its in-process
// serialized cache. Every accepted transition is committed under the expected
// Thread revision before the coordinator publishes its new snapshot.
public class SqliteThreadCommitSink <: ThreadCommitSink {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func createThread(threadId: ThreadId, workspaceId: String): AgentThreadSnapshot {
        let record = ThreadRecord(threadId, 0, workspaceId, ThreadStatus.Open, 1)
        database.execute(
            "INSERT INTO threads (id,revision,workspace_id,status,next_item_ordinal,active_turn_id) VALUES (" +
                sqliteText(threadId.value) + ",0," + sqliteText(record.workspaceId) + ",'open',1,NULL)"
        )
        AgentThreadSnapshot(record, [], [])
    }

    public func loadThread(threadId: ThreadId): AgentThreadSnapshot {
        let threadRows = database.query(
            "SELECT revision,workspace_id,status,next_item_ordinal,COALESCE(active_turn_id,'') " +
                "FROM threads WHERE id=" + sqliteText(threadId.value)
        )
        if (threadRows.size != 1) { throw IllegalStateException("durable Thread does not exist") }
        let row = threadRows[0]
        let activeTurnText = row.required(4)
        let activeTurnId: ?SemanticTurnId = if (activeTurnText == "") {
            None
        } else {
            Some(SemanticTurnId(activeTurnText))
        }
        let thread = ThreadRecord(
            threadId,
            parseStoreInt(row.required(0), "Thread revision"),
            row.required(1),
            parseThreadStatus(row.required(2)),
            parseStoreInt(row.required(3), "Thread item ordinal"),
            activeTurnId: activeTurnId
        )
        let turns = loadTurns(threadId)
        let items = loadItems(threadId)
        var activeRunId: ?RunId = None
        var activeEpoch: Int64 = 0
        var nextResultSequence: Int64 = 1
        match (activeTurnId) {
            case Some(turnId) =>
                var selected: ?TurnRecord = None
                for (turn in turns where turn.id.value == turnId.value) { selected = Some(turn) }
                let activeTurn = selected.getOrThrow()
                activeRunId = activeTurn.activeRunId
                let runId = activeTurn.activeRunId.getOrThrow()
                let runRows = database.query(
                    "SELECT epoch FROM runs WHERE id=" + sqliteText(runId.value) +
                        " AND thread_id=" + sqliteText(threadId.value) +
                        " AND turn_id=" + sqliteText(turnId.value)
                )
                if (runRows.size != 1) {
                    throw IllegalStateException("active durable Run is missing")
                }
                activeEpoch = parseStoreInt(runRows[0].required(0), "Run epoch")
                for (item in items where item.turnId.value == turnId.value) {
                    nextResultSequence += 1
                }
                // The user Item is not a worker result.
                nextResultSequence -= 1
            case None => ()
        }
        AgentThreadSnapshot(
            thread, turns, items,
            activeRunId: activeRunId,
            activeEpoch: activeEpoch,
            nextResultSequence: nextResultSequence
        )
    }

    public func commit(transition: ThreadTransition): Result<Unit> {
        try {
            database.transaction { transaction => commitTransition(transaction, transition) }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "thread.durable_commit_failed",
                error.message,
                fields: [
                    ErrorField("thread_id", transition.before.thread.id.value),
                    ErrorField("expected_revision", transition.before.thread.revision.toString())
                ]
            ))
        }
    }

    public func recordOperationReceipt(
        runId: RunId,
        receipt: VNextOperationReceipt
    ): Result<Unit> {
        try {
            database.transaction { transaction =>
                requireStoreRow(
                    transaction,
                    "SELECT run_id,state FROM operations WHERE id=" +
                        sqliteText(receipt.operationId.value),
                    [runId.value, "executing"],
                    "Operation is not the expected executing operation"
                )
                insertOperationReceipt(transaction, receipt)
                let state = if (receipt.outcome == OperationOutcome.Unknown) {
                    "recovery_required"
                } else {
                    "failed"
                }
                transaction.execute(
                    "UPDATE operations SET state=" + sqliteText(state) +
                        ",revision=revision+1 WHERE id=" + sqliteText(receipt.operationId.value) +
                        " AND state='executing'"
                )
                requireStoreChanged(transaction, "Operation receipt lost its executing owner")
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "operation.receipt_commit_failed",
                error.message,
                fields: [
                    ErrorField("operation_id", receipt.operationId.value),
                    ErrorField("run_id", runId.value)
                ]
            ))
        }
    }

    public func recordRunTransition(
        threadId: ThreadId,
        turnId: SemanticTurnId,
        runId: RunId,
        epoch: Int64,
        transition: RunTransition,
        observedAtMillis: Int64
    ): Result<Unit> {
        if (epoch < 1 || observedAtMillis < 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "run.transition_metadata_invalid",
                "durable Run transition metadata is invalid"
            ))
        }
        try {
            database.transaction { transaction =>
                let rows = transaction.query(
                    "SELECT state FROM runs WHERE id=" + sqliteText(runId.value) +
                        " AND thread_id=" + sqliteText(threadId.value) +
                        " AND turn_id=" + sqliteText(turnId.value) +
                        " AND epoch=" + epoch.toString()
                )
                if (rows.size != 1) {
                    throw IllegalStateException("durable Run ownership does not match transition")
                }
                let from = runStateName(transition.from)
                let to = runStateName(transition.to)
                let current = rows[0].required(0)
                if (current == from) {
                    transaction.execute(
                        "UPDATE runs SET state=" + sqliteText(to) + " WHERE id=" +
                            sqliteText(runId.value) + " AND state=" + sqliteText(from)
                    )
                    requireStoreChanged(transaction, "Run transition lost its owner")
                } else if (current != to) {
                    throw IllegalStateException("durable Run state does not match transition")
                }
                let existing = transaction.query(
                    "SELECT kind,payload FROM run_journal WHERE run_id=" +
                        sqliteText(runId.value) + " AND sequence=" + transition.sequence.toString()
                )
                let payload = encodeStoredValue(objectValue([
                    ValueField("from", textValue(from)),
                    ValueField("to", textValue(to)),
                    ValueField("reason", textValue(transition.reason))
                ]))
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO run_journal " +
                            "(run_id,sequence,kind,payload,created_at_millis) VALUES (" +
                            sqliteText(runId.value) + "," + transition.sequence.toString() +
                            ",'state_transition'," + sqliteText(payload) + "," +
                            observedAtMillis.toString() + ")"
                    )
                } else if (existing.size != 1 || existing[0].required(0) != "state_transition" ||
                    existing[0].required(1) != payload) {
                    throw IllegalStateException("Run transition sequence already has different evidence")
                }
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.transition_commit_failed",
                error.message,
                fields: [ErrorField("run_id", runId.value)]
            ))
        }
    }

    public func recordModelUsage(sample: RunModelUsageSample): Result<Unit> {
        try {
            database.transaction { transaction =>
                requireStoreRow(
                    transaction,
                    "SELECT thread_id,turn_id,epoch FROM runs WHERE id=" +
                        sqliteText(sample.runId.value),
                    [
                        sample.threadId.value, sample.turnId.value, sample.epoch.toString()
                    ],
                    "model usage does not belong to the durable Run"
                )
                let cost = match (sample.actual.costMicros) {
                    case Some(value) => value.toString()
                    case None => "NULL"
                }
                let existing = transaction.query(
                    "SELECT role,estimated_input_tokens,actual_input_tokens,output_tokens," +
                        "reasoning_tokens,cache_read_tokens,cache_write_tokens," +
                        "COALESCE(cost_micros,-1),created_at_millis FROM run_model_usage WHERE run_id=" +
                        sqliteText(sample.runId.value) + " AND request_sequence=" +
                        sample.requestSequence.toString()
                )
                let expected = [
                    modelLaneRoleName(sample.role), sample.estimatedInputTokens.toString(),
                    sample.actual.inputTokens.toString(), sample.actual.outputTokens.toString(),
                    sample.actual.reasoningTokens.toString(),
                    sample.actual.cacheReadTokens.toString(),
                    sample.actual.cacheWriteTokens.toString(),
                    match (sample.actual.costMicros) {
                        case Some(value) => value.toString()
                        case None => "-1"
                    },
                    sample.observedAtMillis.toString()
                ]
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO run_model_usage " +
                            "(run_id,request_sequence,role,estimated_input_tokens," +
                            "actual_input_tokens,output_tokens,reasoning_tokens,cache_read_tokens," +
                            "cache_write_tokens,cost_micros,created_at_millis) VALUES (" +
                            sqliteText(sample.runId.value) + "," +
                            sample.requestSequence.toString() + "," +
                            sqliteText(modelLaneRoleName(sample.role)) + "," +
                            sample.estimatedInputTokens.toString() + "," +
                            sample.actual.inputTokens.toString() + "," +
                            sample.actual.outputTokens.toString() + "," +
                            sample.actual.reasoningTokens.toString() + "," +
                            sample.actual.cacheReadTokens.toString() + "," +
                            sample.actual.cacheWriteTokens.toString() + "," + cost + "," +
                            sample.observedAtMillis.toString() + ")"
                    )
                } else {
                    if (existing.size != 1 || existing[0].size != expected.size) {
                        throw IllegalStateException("model usage sample identity is ambiguous")
                    }
                    for (index in 0..expected.size where
                        existing[0].required(index) != expected[index]) {
                        throw IllegalStateException("model usage sequence already has different evidence")
                    }
                }
                let aggregate = transaction.query(
                    "SELECT COALESCE(SUM(actual_input_tokens),0)," +
                        "COALESCE(SUM(output_tokens),0),COALESCE(SUM(reasoning_tokens),0)," +
                        "COALESCE(SUM(cache_read_tokens),0),COALESCE(SUM(cache_write_tokens),0)," +
                        "CASE WHEN COUNT(cost_micros)=COUNT(*) THEN SUM(cost_micros) ELSE NULL END " +
                        "FROM run_model_usage WHERE run_id=" + sqliteText(sample.runId.value)
                )[0]
                let usage = objectValue([
                    ValueField("input_tokens", integerValue(parseStoreInt(
                        aggregate.required(0), "aggregate input tokens"
                    ))),
                    ValueField("output_tokens", integerValue(parseStoreInt(
                        aggregate.required(1), "aggregate output tokens"
                    ))),
                    ValueField("reasoning_tokens", integerValue(parseStoreInt(
                        aggregate.required(2), "aggregate reasoning tokens"
                    ))),
                    ValueField("cache_read_tokens", integerValue(parseStoreInt(
                        aggregate.required(3), "aggregate cache read tokens"
                    ))),
                    ValueField("cache_write_tokens", integerValue(parseStoreInt(
                        aggregate.required(4), "aggregate cache write tokens"
                    ))),
                    ValueField("cost_micros", match (aggregate[5]) {
                        case Some(value) => integerValue(parseStoreInt(value, "aggregate cost"))
                        case None => nullValue()
                    })
                ])
                transaction.execute(
                    "UPDATE runs SET usage=" + sqliteText(encodeStoredValue(usage)) +
                        " WHERE id=" + sqliteText(sample.runId.value)
                )
                requireStoreChanged(transaction, "model usage lost its Run owner")
            }
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.usage_commit_failed",
                error.message,
                fields: [ErrorField("run_id", sample.runId.value)]
            ))
        }
    }

    private func commitTransition(transaction: SqliteTransaction, transition: ThreadTransition): Unit {
        requireThreadRevision(transaction, transition.before)
        match (transition.kind) {
            case ThreadTransitionKind.TurnStarted => commitTurnStart(transaction, transition)
            case ThreadTransitionKind.ExternalInputCommitted =>
                commitExternalInput(transaction, transition)
            case ThreadTransitionKind.ItemCommitted =>
                for (item in transition.committedItems) {
                    insertThreadItem(transaction, item)
                }
                commitCanonicalDecisionProjection(transaction, transition)
                updateThreadRecord(transaction, transition.before, transition.after)
            case ThreadTransitionKind.OperationResultCommitted =>
                commitOperationTransition(transaction, transition)
            case ThreadTransitionKind.TurnCompleted =>
                commitSettlement(transaction, transition, "completed", "completed")
            case ThreadTransitionKind.TurnFailed =>
                commitSettlement(transaction, transition, "failed", "failed")
            case ThreadTransitionKind.TurnRecoveryRequired =>
                commitSettlement(transaction, transition, "failed", "recovery_required")
            case ThreadTransitionKind.RunCancelled =>
                commitSettlement(transaction, transition, "cancelled", "cancelled")
        }
    }

    private func commitExternalInput(
        transaction: SqliteTransaction,
        transition: ThreadTransition
    ): Unit {
        let turn = transition.committedTurn.getOrThrow()
        let item = transition.committedItems[0]
        let runId = item.provenance.runId.getOrThrow()
        transaction.execute(
            "INSERT INTO turns (id,thread_id,ordinal,state,user_item_id,active_run_id) VALUES (" +
                sqliteText(turn.id.value) + "," + sqliteText(turn.threadId.value) + "," +
                turn.ordinal.toString() + ",'completed'," + sqliteText(item.id.value) + ",NULL)"
        )
        insertThreadItem(transaction, item)
        let empty = encodeStoredValue(objectValue([]))
        let finished = transition.finishedAtMillis.getOrThrow()
        transaction.execute(
            "INSERT INTO runs (id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                "started_at_millis,finished_at_millis,cancellation_reason) VALUES (" +
                sqliteText(runId.value) + "," + sqliteText(turn.threadId.value) + "," +
                sqliteText(turn.id.value) + "," + transition.after.activeEpoch.toString() +
                ",'completed'," + sqliteText(empty) + "," + sqliteText(empty) + "," +
                sqliteText(empty) + "," + sqliteText(empty) + "," +
                item.createdAtMillis.toString() + "," + finished.toString() + ",NULL)"
        )
        updateThreadRecord(transaction, transition.before, transition.after)
    }

    private func commitTurnStart(transaction: SqliteTransaction, transition: ThreadTransition): Unit {
        let turn = transition.committedTurn.getOrThrow()
        let item = transition.committedItems[0]
        let runId = turn.activeRunId.getOrThrow()
        transaction.execute(
            "INSERT INTO turns (id,thread_id,ordinal,state,user_item_id,active_run_id) VALUES (" +
                sqliteText(turn.id.value) + "," + sqliteText(turn.threadId.value) + "," +
                turn.ordinal.toString() + ",'active'," + sqliteText(turn.userItemId.value) + "," +
                sqliteText(runId.value) + ")"
        )
        insertThreadItem(transaction, item)
        let empty = encodeStoredValue(objectValue([]))
        transaction.execute(
            "INSERT INTO runs (id,thread_id,turn_id,epoch,state,lane_snapshot,skill_snapshot,budget,usage," +
                "started_at_millis,finished_at_millis,cancellation_reason) VALUES (" +
                sqliteText(runId.value) + "," + sqliteText(turn.threadId.value) + "," +
                sqliteText(turn.id.value) + "," + transition.after.activeEpoch.toString() +
                ",'running'," + sqliteText(encodeStoredValue(transition.runLaneSnapshot)) + "," +
                sqliteText(encodeStoredValue(transition.runSkillSnapshot)) + "," +
                sqliteText(encodeStoredValue(transition.runBudgetSnapshot)) + "," +
                sqliteText(empty) + "," + item.createdAtMillis.toString() + ",NULL,NULL)"
        )
        updateThreadRecord(transaction, transition.before, transition.after)
    }

    private func commitOperationTransition(
        transaction: SqliteTransaction,
        transition: ThreadTransition
    ): Unit {
        let item = transition.committedItems[0]
        let receipt = transition.operationReceipt.getOrThrow()
        let runId = item.provenance.runId.getOrThrow()
        let rows = transaction.query(
            "SELECT run_id,state FROM operations WHERE id=" +
                sqliteText(receipt.operationId.value)
        )
        if (rows.size != 1 || rows[0].required(0) != runId.value) {
            throw IllegalStateException("Operation is not owned by the expected Run")
        }
        let observedState = rows[0].required(1)
        if (!operationStateMayCommitOutcome(observedState, receipt.outcome)) {
            throw IllegalStateException(
                "Operation state cannot commit the observed execution outcome"
            )
        }
        insertOperationReceipt(transaction, receipt)
        transaction.execute(
            "UPDATE operations SET state=" + sqliteText(
                if (receipt.outcome == OperationOutcome.Unknown) {
                    "recovery_required"
                } else {
                    "committed"
                }
            ) + ",revision=revision+1 WHERE id=" +
                sqliteText(receipt.operationId.value) + " AND state=" +
                sqliteText(observedState)
        )
        requireStoreChanged(transaction, "Operation commit lost its owner")
        insertThreadItem(transaction, item)
        transaction.execute(
            "UPDATE runs SET state=" + sqliteText(transition.nextRunState) +
                " WHERE id=" + sqliteText(runId.value) + " AND thread_id=" +
                sqliteText(item.threadId.value) + " AND turn_id=" + sqliteText(item.turnId.value)
        )
        requireStoreChanged(transaction, "Run transition lost its owner")
        updateThreadRecord(transaction, transition.before, transition.after)
    }

    private func insertOperationReceipt(
        transaction: SqliteTransaction,
        receipt: VNextOperationReceipt
    ): Unit {
        transaction.execute(
            "INSERT INTO operation_receipts " +
                "(id,operation_id,outcome,detail,verification,created_at_millis) VALUES (" +
                sqliteText(receipt.receiptId) + "," + sqliteText(receipt.operationId.value) + "," +
                sqliteText(operationOutcomeName(receipt.outcome)) + "," +
                sqliteText(encodeStoredValue(receipt.detail)) + "," +
                sqliteText(encodeStoredValue(receipt.verification)) + "," +
                receipt.observedAtMillis.toString() + ")"
        )
    }

    private func commitSettlement(
        transaction: SqliteTransaction,
        transition: ThreadTransition,
        turnState: String,
        runState: String
    ): Unit {
        let turnId = transition.before.thread.activeTurnId.getOrThrow()
        let runId = transition.before.activeRunId.getOrThrow()
        transaction.execute(
            "UPDATE turns SET state=" + sqliteText(turnState) + ",active_run_id=NULL WHERE id=" +
                sqliteText(turnId.value) + " AND thread_id=" +
                sqliteText(transition.before.thread.id.value) + " AND active_run_id=" +
                sqliteText(runId.value)
        )
        requireStoreChanged(transaction, "Turn settlement lost its owner")
        transaction.execute(
            "UPDATE runs SET state=" + sqliteText(runState) +
                ",finished_at_millis=COALESCE(finished_at_millis," +
                match (transition.finishedAtMillis) {
                    case Some(value) => value.toString()
                    case None => "started_at_millis"
                } + "),cancellation_reason=" + match (transition.cancellationReason) {
                    case Some(value) => sqliteText(value)
                    case None => "cancellation_reason"
                } + " WHERE id=" +
                sqliteText(runId.value) + " AND thread_id=" +
                sqliteText(transition.before.thread.id.value) + " AND turn_id=" +
                sqliteText(turnId.value)
        )
        requireStoreChanged(transaction, "Run settlement lost its owner")
        updateThreadRecord(transaction, transition.before, transition.after)
    }

    private func insertThreadItem(transaction: SqliteTransaction, item: ThreadItem): Unit {
        transaction.execute(
            "INSERT INTO items (id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) VALUES (" +
                sqliteText(item.id.value) + "," + sqliteText(item.threadId.value) + "," +
                sqliteText(item.turnId.value) + "," + item.ordinal.toString() + "," +
                sqliteText(storedItemKind(item.kind)) + "," +
                sqliteText(encodeStoredThreadContent(item.content)) + "," +
                sqliteText(encodeStoredProvenance(item.provenance)) + "," +
                item.createdAtMillis.toString() + ")"
        )
    }

    private func commitCanonicalDecisionProjection(
        transaction: SqliteTransaction,
        transition: ThreadTransition
    ): Unit {
        let bindings = transition.canonicalDecisionBindings
        if (bindings.isEmpty()) { return }
        let decisionId = bindings[0].decisionId.value
        for (binding in bindings where binding.decisionId.value != decisionId) {
            throw IllegalStateException(
                "one canonical Item batch cannot project multiple Model Decisions"
            )
        }
        requireStoreRow(
            transaction,
            "SELECT validation_status,COALESCE(canonical_committed_at_millis,-1) " +
                "FROM model_decisions WHERE id=" + sqliteText(decisionId),
            ["validated", "-1"],
            "canonical projection requires one uncommitted validated Model Decision"
        )
        let blockCount = transaction.query(
            "SELECT COUNT(*) FROM model_decision_blocks WHERE decision_id=" +
                sqliteText(decisionId)
        )[0].required(0)
        if (blockCount != bindings.size.toString()) {
            throw IllegalStateException(
                "canonical projection must atomically cover every Decision block"
            )
        }
        var committedAtMillis: Int64 = 0
        for (index in 0..bindings.size) {
            let binding = bindings[index]
            let item = transition.committedItems[index]
            requireStoreRow(
                transaction,
                "SELECT decision_id FROM model_decision_blocks WHERE id=" +
                    sqliteText(binding.decisionBlockId.value),
                [decisionId],
                "canonical Item does not belong to the projected Decision block"
            )
            transaction.execute(
                "INSERT INTO canonical_decision_items " +
                    "(decision_id,decision_block_id,item_id) VALUES (" +
                    sqliteText(decisionId) + "," +
                    sqliteText(binding.decisionBlockId.value) + "," +
                    sqliteText(binding.itemId.value) + ")"
            )
            if (item.createdAtMillis > committedAtMillis) {
                committedAtMillis = item.createdAtMillis
            }
        }
        transaction.execute(
            "UPDATE model_decisions SET canonical_committed_at_millis=" +
                committedAtMillis.toString() + " WHERE id=" + sqliteText(decisionId) +
                " AND canonical_committed_at_millis IS NULL"
        )
        requireStoreChanged(transaction, "canonical Decision projection lost its owner")
    }

    private func updateThreadRecord(
        transaction: SqliteTransaction,
        before: AgentThreadSnapshot,
        after: AgentThreadSnapshot
    ): Unit {
        let active = match (after.thread.activeTurnId) {
            case Some(value) => sqliteText(value.value)
            case None => "NULL"
        }
        transaction.execute(
            "UPDATE threads SET revision=" + after.thread.revision.toString() +
                ",status=" + sqliteText(storedThreadStatus(after.thread.status)) +
                ",next_item_ordinal=" + after.thread.nextItemOrdinal.toString() +
                ",active_turn_id=" + active + " WHERE id=" + sqliteText(before.thread.id.value) +
                " AND revision=" + before.thread.revision.toString() +
                " AND next_item_ordinal=" + before.thread.nextItemOrdinal.toString() +
                " AND COALESCE(active_turn_id,'')=" + sqliteText(match (before.thread.activeTurnId) {
                    case Some(value) => value.value
                    case None => ""
                })
        )
        requireStoreChanged(transaction, "Thread revision lost its semantic owner")
    }

    private func requireThreadRevision(
        transaction: SqliteTransaction,
        snapshot: AgentThreadSnapshot
    ): Unit {
        requireStoreRow(
            transaction,
            "SELECT revision,workspace_id,status,next_item_ordinal,COALESCE(active_turn_id,'') " +
                "FROM threads WHERE id=" + sqliteText(snapshot.thread.id.value),
            [
                snapshot.thread.revision.toString(), snapshot.thread.workspaceId,
                storedThreadStatus(snapshot.thread.status), snapshot.thread.nextItemOrdinal.toString(),
                match (snapshot.thread.activeTurnId) {
                    case Some(value) => value.value
                    case None => ""
                }
            ],
            "durable Thread revision does not match coordinator state"
        )
    }

    private func loadTurns(threadId: ThreadId): Array<TurnRecord> {
        let records = ArrayList<TurnRecord>()
        for (row in database.query(
            "SELECT id,ordinal,state,user_item_id,COALESCE(active_run_id,'') FROM turns WHERE thread_id=" +
                sqliteText(threadId.value) + " ORDER BY ordinal"
        )) {
            let active = row.required(4)
            records.add(TurnRecord(
                SemanticTurnId(row.required(0)), threadId,
                parseStoreInt(row.required(1), "Turn ordinal"),
                parseTurnState(row.required(2)), ItemId(row.required(3)),
                activeRunId: if (active == "") { None } else { Some(RunId(active)) }
            ))
        }
        records.toArray()
    }

    private func loadItems(threadId: ThreadId): Array<ThreadItem> {
        let records = ArrayList<ThreadItem>()
        for (row in database.query(
            "SELECT id,turn_id,ordinal,kind,payload,provenance,created_at_millis FROM items WHERE thread_id=" +
                sqliteText(threadId.value) + " ORDER BY ordinal"
        )) {
            let content = decodeStoredThreadContent(row.required(4))
            if (storedItemKind(threadItemKind(content)) != row.required(3)) {
                throw IllegalStateException("durable Item kind and payload disagree")
            }
            records.add(ThreadItem(
                ItemId(row.required(0)), threadId, SemanticTurnId(row.required(1)),
                parseStoreInt(row.required(2), "Item ordinal"), content,
                decodeStoredProvenance(row.required(5)),
                createdAtMillis: parseStoreInt(row.required(6), "Item timestamp")
            ))
        }
        records.toArray()
    }
}

func operationStateMayCommitOutcome(
    state: String,
    outcome: OperationOutcome
): Bool {
    match (outcome) {
        case OperationOutcome.Rejected =>
            state == "prepared" || state == "waiting_approval" ||
                state == "rejected" || state == "executing"
        case OperationOutcome.Cancelled =>
            state == "prepared" || state == "waiting_approval" || state == "executing"
        case OperationOutcome.Completed |
            OperationOutcome.TimedOut |
            OperationOutcome.Failed |
            OperationOutcome.Unknown => state == "executing"
    }
}

func requireStoreRow(
    transaction: SqliteTransaction,
    sql: String,
    expected: Array<String>,
    message: String
): Unit {
    let rows = transaction.query(sql)
    if (rows.size != 1 || rows[0].size != expected.size) { throw IllegalStateException(message) }
    for (index in 0..expected.size) {
        if (rows[0].required(index) != expected[index]) { throw IllegalStateException(message) }
    }
}

func requireStoreChanged(transaction: SqliteTransaction, message: String): Unit {
    if (transaction.query("SELECT changes()")[0].required(0) != "1") {
        throw IllegalStateException(message)
    }
}

func storedThreadStatus(status: ThreadStatus): String {
    match (status) {
        case ThreadStatus.Open => "open"
        case ThreadStatus.Closed => "closed"
    }
}

func parseThreadStatus(value: String): ThreadStatus {
    match (value) {
        case "open" => ThreadStatus.Open
        case "closed" => ThreadStatus.Closed
        case _ => throw IllegalStateException("unknown durable Thread status: " + value)
    }
}

func parseTurnState(value: String): TurnState {
    match (value) {
        case "active" => TurnState.Active
        case "completed" => TurnState.Completed
        case "cancelled" => TurnState.Cancelled
        case "failed" => TurnState.Failed
        case "superseded" => TurnState.Superseded
        case _ => throw IllegalStateException("unknown durable Turn state: " + value)
    }
}

func storedItemKind(kind: ItemKind): String {
    match (kind) {
        case ItemKind.UserMessage => "user_message"
        case ItemKind.AssistantMessage => "assistant_message"
        case ItemKind.ToolCall => "tool_call"
        case ItemKind.ToolResult => "tool_result"
        case ItemKind.ReasoningReference => "reasoning_reference"
        case ItemKind.ProviderOpaqueItem => "provider_opaque"
        case ItemKind.ArtifactReference => "artifact_reference"
        case ItemKind.SystemNote => "system_note"
    }
}

func parseStoreInt(value: String, field: String): Int64 {
    try {
        Int64.parse(value)
    } catch (_: Exception) {
        throw IllegalStateException(field + " is not an integer")
    }
}
