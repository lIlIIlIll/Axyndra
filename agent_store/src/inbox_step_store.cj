package agent_store

import std.convert.*
import std.collection.*
import agent_domain.*

public class InboxClaimRequest {
    public let entryId: InboxEntryId
    public let stepId: StepId
    public let runId: RunId
    public let turnId: SemanticTurnId
    public let acceptedItemId: ItemId
    public let expectedThreadRevision: Int64
    public let expectedContinuationRevision: Int64
    public let continuation: DurableRunContinuationV1
    public let claimedAtMillis: Int64

    public init(
        entryId: InboxEntryId,
        stepId: StepId,
        runId: RunId,
        turnId: SemanticTurnId,
        acceptedItemId: ItemId,
        expectedThreadRevision: Int64,
        expectedContinuationRevision: Int64,
        continuation: DurableRunContinuationV1,
        claimedAtMillis: Int64
    ) {
        if (expectedThreadRevision < 0 || expectedContinuationRevision < 0 ||
            claimedAtMillis < 0) {
            throw IllegalArgumentException("Inbox claim boundary is invalid")
        }
        this.entryId = entryId
        this.stepId = stepId
        this.runId = runId
        this.turnId = turnId
        this.acceptedItemId = acceptedItemId
        this.expectedThreadRevision = expectedThreadRevision
        this.expectedContinuationRevision = expectedContinuationRevision
        this.continuation = continuation
        this.claimedAtMillis = claimedAtMillis
    }
}

public class SqliteInboxStepStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func enqueue(entry: DurableInboxEntry): Result<InboxEnqueueOutcome> {
        if (entry.status != InboxEntryStatus.Queued || entry.claimedStepId.isSome()) {
            return inboxConflict<InboxEnqueueOutcome>(
                "only a queued Inbox entry may be enqueued"
            )
        }
        let payload = encodeStoredValue(entry.payload)
        try {
            database.transaction { transaction =>
                if (transaction.query(
                    "SELECT 1 FROM lanes WHERE thread_id=? AND lane_id=?",
                    [SqlParameter.Text(entry.threadId.value),
                        SqlParameter.Text(entry.laneId.value)]
                ).size != 1) {
                    return inboxConflict<InboxEnqueueOutcome>(
                        "Inbox entry references an unknown Lane"
                    )
                }
                let existing = transaction.query(
                    "SELECT thread_id,lane_id,kind,payload,status FROM lane_inbox_entries WHERE id=?",
                    [SqlParameter.Text(entry.id.value)]
                )
                if (existing.isEmpty()) {
                    transaction.execute(
                        "INSERT INTO lane_inbox_entries(" +
                            "id,thread_id,lane_id,kind,payload,status,created_at_millis,claimed_step_id,revision" +
                            ") VALUES (?,?,?,?,?,'queued',?,NULL,1)",
                        [
                            SqlParameter.Text(entry.id.value),
                            SqlParameter.Text(entry.threadId.value),
                            SqlParameter.Text(entry.laneId.value),
                            SqlParameter.Text(inboxEntryKindName(entry.kind)),
                            SqlParameter.Text(payload),
                            SqlParameter.Int64Value(entry.createdAtMillis)
                        ]
                    )
                    Result.Ok(InboxEnqueueOutcome.Inserted)
                } else if (existing.size == 1 &&
                    existing[0].required(0) == entry.threadId.value &&
                    existing[0].required(1) == entry.laneId.value &&
                    existing[0].required(2) == inboxEntryKindName(entry.kind) &&
                    existing[0].required(3) == payload) {
                    Result.Ok(inboxEnqueueOutcome(existing[0].required(4)))
                } else {
                    inboxConflict<InboxEnqueueOutcome>(
                        "Inbox entry id already owns different content"
                    )
                }
            }
        } catch (error: Exception) {
            inboxRecovery<InboxEnqueueOutcome>(
                "inbox.enqueue_failed", error.message, entry.id
            )
        }
    }

    public func rejectQueued(entryId: InboxEntryId): Result<Unit> {
        try {
            database.transaction { transaction =>
                let rows = transaction.query(
                    "SELECT status FROM lane_inbox_entries WHERE id=?",
                    [SqlParameter.Text(entryId.value)]
                )
                if (rows.size != 1) {
                    return inboxConflict<Unit>("Inbox entry does not exist")
                }
                if (rows[0].required(0) == "rejected") { return Result.Ok(()) }
                if (rows[0].required(0) != "queued") {
                    return inboxConflict<Unit>("Inbox entry was already delivered")
                }
                transaction.execute(
                    "UPDATE lane_inbox_entries SET status='rejected',revision=revision+1 " +
                        "WHERE id=? AND status='queued'",
                    [SqlParameter.Text(entryId.value)]
                )
                Result.Ok(())
            }
        } catch (error: Exception) {
            inboxRecovery<Unit>("inbox.reject_failed", error.message, entryId)
        }
    }

    public func pendingQueued(
        threadId: ThreadId,
        laneId: LaneId
    ): Result<Array<DurableInboxEntry>> {
        try {
            let rows = database.query(
                "SELECT id,kind,payload,created_at_millis FROM lane_inbox_entries " +
                    "WHERE thread_id=? AND lane_id=? AND status='queued' " +
                    "ORDER BY created_at_millis,id",
                [SqlParameter.Text(threadId.value), SqlParameter.Text(laneId.value)]
            )
            let output = ArrayList<DurableInboxEntry>()
            for (row in rows) {
                output.add(DurableInboxEntry(
                    InboxEntryId(row.required(0)), threadId, laneId,
                    parseInboxEntryKind(row.required(1)),
                    decodeStoredValue(row.required(2)),
                    createdAtMillis: inboxInt(row.required(3), "Inbox timestamp")
                ))
            }
            Result.Ok(output.toArray())
        } catch (error: Exception) {
            inboxRecovery<Array<DurableInboxEntry>>(
                "inbox.pending_read_failed", error.message, InboxEntryId("pending")
            )
        }
    }

    public func claim(request: InboxClaimRequest): Result<StepRecord> {
        if (!request.continuation.isSealed() ||
            request.continuation.runId.value != request.runId.value ||
            request.continuation.turnId.value != request.turnId.value ||
            containsInboxDebt(request.continuation.workDebt, request.entryId)) {
            return inboxConflict<StepRecord>(
                "claimed continuation must be sealed and remove the claimed input debt"
            )
        }
        try {
            database.transaction { transaction => claimLocked(transaction, request) }
        } catch (error: Exception) {
            inboxRecovery<StepRecord>(
                "inbox.claim_failed", error.message, request.entryId
            )
        }
    }

    public func settle(
        stepId: StepId,
        expectedRevision: Int64,
        status: StepStatus,
        settledAtMillis: Int64
    ): Result<Unit> {
        if (status == StepStatus.Open || expectedRevision < 1 || settledAtMillis < 0) {
            return inboxConflict<Unit>("Step settlement is invalid")
        }
        try {
            database.transaction { transaction =>
                let rows = transaction.query(
                    "SELECT input_entry_id,status,revision FROM step_records WHERE id=?",
                    [SqlParameter.Text(stepId.value)]
                )
                if (rows.size != 1 || rows[0].required(1) != "open" ||
                    inboxInt(rows[0].required(2), "Step revision") != expectedRevision) {
                    return inboxConflict<Unit>("Step settlement changed concurrently")
                }
                transaction.execute(
                    "UPDATE step_records SET status=?,settled_at_millis=?,revision=revision+1 " +
                        "WHERE id=? AND status='open' AND revision=?",
                    [
                        SqlParameter.Text(stepStatusName(status)),
                        SqlParameter.Int64Value(settledAtMillis), SqlParameter.Text(stepId.value),
                        SqlParameter.Int64Value(expectedRevision)
                    ]
                )
                transaction.execute(
                    "UPDATE lane_inbox_entries SET status='applied',revision=revision+1 " +
                        "WHERE id=? AND status='claimed' AND claimed_step_id=?",
                    [SqlParameter.Text(rows[0].required(0)), SqlParameter.Text(stepId.value)]
                )
                Result.Ok(())
            }
        } catch (error: Exception) {
            inboxRecovery<Unit>(
                "inbox.step_settle_failed", error.message, InboxEntryId("unknown")
            )
        }
    }

    private func claimLocked(
        transaction: SqliteTransaction,
        request: InboxClaimRequest
    ): Result<StepRecord> {
        let entryRows = transaction.query(
            "SELECT thread_id,lane_id,kind,payload,status,created_at_millis," +
                "COALESCE(claimed_step_id,'') FROM lane_inbox_entries WHERE id=?",
            [SqlParameter.Text(request.entryId.value)]
        )
        if (entryRows.size != 1) {
            return inboxConflict<StepRecord>("Inbox entry does not exist")
        }
        let entry = entryRows[0]
        if (entry.required(4) == "claimed" && entry.required(6) == request.stepId.value) {
            return loadStepLocked(transaction, request.stepId)
        }
        if (entry.required(4) != "queued") {
            return inboxConflict<StepRecord>("Inbox entry is no longer queued")
        }
        let threadId = ThreadId(entry.required(0))
        let threadRows = transaction.query(
            "SELECT revision,next_item_ordinal FROM threads WHERE id=?",
            [SqlParameter.Text(threadId.value)]
        )
        if (threadRows.size != 1 ||
            inboxInt(threadRows[0].required(0), "Thread revision") !=
                request.expectedThreadRevision) {
            return inboxConflict<StepRecord>("Inbox claim Thread revision changed")
        }
        let runRows = transaction.query(
            "SELECT runs.thread_id,runs.turn_id,binding.lane_id FROM runs " +
                "JOIN run_lane_bindings binding ON binding.run_id=runs.id WHERE runs.id=?",
            [SqlParameter.Text(request.runId.value)]
        )
        if (runRows.size != 1 || runRows[0].required(0) != threadId.value ||
            runRows[0].required(1) != request.turnId.value ||
            runRows[0].required(2) != entry.required(1) ||
            request.continuation.laneId.value != entry.required(1)) {
            return inboxConflict<StepRecord>("Inbox claim Run enclosure changed")
        }
        let revisionRows = transaction.query(
            "SELECT COALESCE(MAX(revision),0) FROM run_continuation_facts WHERE run_id=?",
            [SqlParameter.Text(request.runId.value)]
        )
        if (inboxInt(revisionRows[0].required(0), "continuation revision") !=
            request.expectedContinuationRevision) {
            return inboxConflict<StepRecord>("Inbox claim continuation revision changed")
        }
        let stepOrdinal = inboxInt(transaction.query(
            "SELECT COALESCE(MAX(ordinal),-1)+1 FROM step_records WHERE run_id=?",
            [SqlParameter.Text(request.runId.value)]
        )[0].required(0), "Step ordinal")
        let itemOrdinal = inboxInt(threadRows[0].required(1), "Thread Item ordinal")
        transaction.execute(
            "INSERT INTO items(id,thread_id,turn_id,ordinal,kind,payload,provenance,created_at_millis) " +
                "VALUES (?,?,?,?,'system_note',?,?,?)",
            [
                SqlParameter.Text(request.acceptedItemId.value),
                SqlParameter.Text(threadId.value), SqlParameter.Text(request.turnId.value),
                SqlParameter.Int64Value(itemOrdinal),
                SqlParameter.Text(encodeStoredThreadContent(ThreadItemContent.SystemNote(
                    encodeStoredValue(decodeStoredValue(entry.required(3)))
                ))),
                SqlParameter.Text(encodeStoredProvenance(ItemProvenance(
                    "inbox", runId: Some(request.runId)
                ))),
                SqlParameter.Int64Value(request.claimedAtMillis)
            ]
        )
        transaction.execute(
            "INSERT INTO step_records(id,thread_id,lane_id,turn_id,run_id,ordinal," +
                "input_entry_id,accepted_item_id,status,opened_at_millis,settled_at_millis,revision) " +
                "VALUES (?,?,?,?,?,?,?,?,'open',?,NULL,1)",
            [
                SqlParameter.Text(request.stepId.value), SqlParameter.Text(threadId.value),
                SqlParameter.Text(entry.required(1)), SqlParameter.Text(request.turnId.value),
                SqlParameter.Text(request.runId.value), SqlParameter.Int64Value(stepOrdinal),
                SqlParameter.Text(request.entryId.value),
                SqlParameter.Text(request.acceptedItemId.value),
                SqlParameter.Int64Value(request.claimedAtMillis)
            ]
        )
        transaction.execute(
            "UPDATE lane_inbox_entries SET status='claimed',claimed_step_id=?,revision=revision+1 " +
                "WHERE id=? AND status='queued'",
            [SqlParameter.Text(request.stepId.value), SqlParameter.Text(request.entryId.value)]
        )
        putClaimContinuation(
            transaction, threadId, request.continuation,
            request.expectedContinuationRevision, request.claimedAtMillis
        )
        transaction.execute(
            "UPDATE threads SET revision=revision+1,next_item_ordinal=next_item_ordinal+1 WHERE id=?",
            [SqlParameter.Text(threadId.value)]
        )
        Result.Ok(StepRecord(
            request.stepId, threadId, LaneId(entry.required(1)), request.turnId,
            request.runId, stepOrdinal, inputEntryId: Some(request.entryId),
            acceptedItemId: Some(request.acceptedItemId),
            openedAtMillis: request.claimedAtMillis
        ))
    }
}

func inboxEnqueueOutcome(status: String): InboxEnqueueOutcome {
    match (status) {
        case "queued" => InboxEnqueueOutcome.AlreadyQueued
        case "claimed" => InboxEnqueueOutcome.AlreadyClaimed
        case "applied" => InboxEnqueueOutcome.AlreadyApplied
        case "rejected" => InboxEnqueueOutcome.AlreadyRejected
        case "superseded" => InboxEnqueueOutcome.AlreadySuperseded
        case _ => throw IllegalStateException("invalid Inbox status")
    }
}

func putClaimContinuation(
    transaction: SqliteTransaction,
    threadId: ThreadId,
    value: DurableRunContinuationV1,
    expectedRevision: Int64,
    observedAtMillis: Int64
): Unit {
    let payload = encodeDurableRunContinuation(value)
    let head = transaction.query(
        "SELECT last_sequence FROM thread_commit_heads WHERE thread_id=?",
        [SqlParameter.Text(threadId.value)]
    )
    let sequence = if (head.isEmpty()) {
        transaction.execute(
            "INSERT INTO thread_commit_heads(thread_id,last_sequence) VALUES (?,1)",
            [SqlParameter.Text(threadId.value)]
        )
        1
    } else {
        let next = inboxInt(head[0].required(0), "commit sequence") + 1
        transaction.execute(
            "UPDATE thread_commit_heads SET last_sequence=? WHERE thread_id=?",
            [SqlParameter.Int64Value(next), SqlParameter.Text(threadId.value)]
        )
        next
    }
    let revision = expectedRevision + 1
    transaction.execute(
        "INSERT INTO run_continuation_facts(" +
            "run_id,thread_id,revision,commit_sequence,phase,payload,digest,created_at_millis" +
            ") VALUES (?,?,?,?,?,?,?,?)",
        [
            SqlParameter.Text(value.runId.value), SqlParameter.Text(threadId.value),
            SqlParameter.Int64Value(revision), SqlParameter.Int64Value(sequence),
            SqlParameter.Text(runExecutionPhaseName(value.phase)), SqlParameter.Text(payload),
            SqlParameter.Text(value.digest), SqlParameter.Int64Value(observedAtMillis)
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
            SqlParameter.Text(value.runId.value), SqlParameter.Int64Value(1),
            SqlParameter.Int64Value(revision),
            SqlParameter.Text(runExecutionPhaseName(value.phase)), SqlParameter.Text(payload),
            SqlParameter.Text(value.digest), SqlParameter.Int64Value(sequence)
        ]
    )
}

func loadStepLocked(transaction: SqliteTransaction, stepId: StepId): Result<StepRecord> {
    let rows = transaction.query(
        "SELECT thread_id,lane_id,turn_id,run_id,ordinal,input_entry_id,accepted_item_id," +
            "status,opened_at_millis,settled_at_millis FROM step_records WHERE id=?",
        [SqlParameter.Text(stepId.value)]
    )
    if (rows.size != 1) { return inboxConflict<StepRecord>("claimed Step is missing") }
    let row = rows[0]
    Result.Ok(StepRecord(
        stepId, ThreadId(row.required(0)), LaneId(row.required(1)),
        SemanticTurnId(row.required(2)), RunId(row.required(3)),
        inboxInt(row.required(4), "Step ordinal"),
        inputEntryId: match (row[5]) {
            case Some(value) => Some(InboxEntryId(value))
            case None => None
        },
        acceptedItemId: match (row[6]) {
            case Some(value) => Some(ItemId(value))
            case None => None
        }, status: parseStepStatus(row.required(7)),
        openedAtMillis: inboxInt(row.required(8), "Step open timestamp"),
        settledAtMillis: match (row[9]) {
            case Some(value) => Some(inboxInt(value, "Step settle timestamp"))
            case None => None
        }
    ))
}

func parseStepStatus(value: String): StepStatus {
    match (value) {
        case "open" => StepStatus.Open
        case "completed" => StepStatus.Completed
        case "cancelled" => StepStatus.Cancelled
        case "failed" => StepStatus.Failed
        case "quarantined" => StepStatus.Quarantined
        case "interrupted" => StepStatus.Interrupted
        case _ => throw IllegalStateException("unknown Step status")
    }
}

func parseInboxEntryKind(value: String): InboxEntryKind {
    match (value) {
        case "user_prompt" => InboxEntryKind.UserPrompt
        case "steering" => InboxEntryKind.Steering
        case "context_injection" => InboxEntryKind.ContextInjection
        case "approval_decision" => InboxEntryKind.ApprovalDecision
        case "external_completion" => InboxEntryKind.ExternalCompletion
        case "child_run_message" => InboxEntryKind.ChildRunMessage
        case "cancel" => InboxEntryKind.Cancel
        case "close" => InboxEntryKind.Close
        case _ => throw IllegalStateException("unknown Inbox entry kind")
    }
}

func containsInboxDebt(debt: WorkDebtSnapshot, id: InboxEntryId): Bool {
    for (value in debt.unclaimedInputs where value.value == id.value) { return true }
    false
}

func inboxInt(value: String, name: String): Int64 {
    try { Int64.parse(value) } catch (_: Exception) {
        throw IllegalStateException("invalid " + name)
    }
}

func inboxConflict<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, "inbox.conflict", message))
}

func inboxRecovery<T>(code: String, message: String, id: InboxEntryId): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.RecoveryRequired, code, message,
        fields: [ErrorField("inbox_entry_id", id.value)]
    ))
}
