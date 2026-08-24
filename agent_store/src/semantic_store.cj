package agent_store

import std.collection.*
import std.convert.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*

public class SqliteSemanticStore <: SemanticStore {
    private let database: SqliteDatabase

    public init(database: SqliteDatabase) { this.database = database }

    public func transact(
        expected: TransactionPreconditions,
        writes: DurableWriteSet
    ): Result<CommitReceipt> {
        if (writes.isEmpty()) {
            return semanticConflict<CommitReceipt>(
                "semantic transaction write set must not be empty"
            )
        }
        if (hasDuplicateOutboxIds(writes.appEvents)) {
            return semanticConflict<CommitReceipt>("semantic transaction repeats an App event id")
        }
        try {
            database.transaction { transaction =>
                transactLocked(transaction, expected, writes)
            }
        } catch (error: Exception) {
            semanticRecovery<CommitReceipt>(
                "semantic_store.transaction_failed", error.message,
                expected.threadId, expected.runId
            )
        }
    }

    public func continuation(runId: RunId): Result<DurableRunContinuationV1> {
        try {
            let rows = database.query(
                "SELECT payload,digest FROM run_continuations WHERE run_id=?",
                [SqlParameter.Text(runId.value)]
            )
            if (rows.size != 1) {
                return semanticRecovery<DurableRunContinuationV1>(
                    "semantic_store.continuation_missing",
                    "durable Run continuation does not exist", None, runId
                )
            }
            let decoded = decodeDurableRunContinuation(rows[0].required(0))
            if (decoded.runId.value != runId.value || decoded.digest != rows[0].required(1)) {
                return semanticRecovery<DurableRunContinuationV1>(
                    "semantic_store.continuation_corrupt",
                    "durable Run continuation identity or digest is corrupt", None, runId
                )
            }
            Result.Ok(decoded)
        } catch (error: Exception) {
            semanticRecovery<DurableRunContinuationV1>(
                "semantic_store.continuation_corrupt", error.message, None, runId
            )
        }
    }

    public func pendingOutbox(
        threadId: ThreadId,
        afterCommitSequence: Int64
    ): Result<Array<AppOutboxRecord>> {
        if (afterCommitSequence < 0) {
            return semanticConflict<Array<AppOutboxRecord>>(
                "outbox cursor must not be negative"
            )
        }
        try {
            let rows = database.query(
                "SELECT event_id,commit_sequence,ordinal,kind,payload,created_at_millis " +
                    "FROM app_event_outbox WHERE thread_id=? AND published=0 " +
                    "AND commit_sequence>? ORDER BY commit_sequence,ordinal",
                [SqlParameter.Text(threadId.value), SqlParameter.Int64Value(afterCommitSequence)]
            )
            let records = ArrayList<AppOutboxRecord>()
            for (row in rows) {
                records.add(AppOutboxRecord(
                    SemanticAppEvent(
                        row.required(0), row.required(3), decodeStoredValue(row.required(4)),
                        semanticInt(row.required(5), "outbox timestamp")
                    ),
                    threadId,
                    semanticInt(row.required(1), "outbox commit sequence"),
                    semanticInt(row.required(2), "outbox ordinal")
                ))
            }
            Result.Ok(records.toArray())
        } catch (error: Exception) {
            semanticRecovery<Array<AppOutboxRecord>>(
                "semantic_store.outbox_corrupt", error.message, Some(threadId), None
            )
        }
    }

    public func acknowledgeOutbox(
        threadId: ThreadId,
        throughCommitSequence: Int64
    ): Result<Unit> {
        if (throughCommitSequence < 0) {
            return semanticConflict<Unit>("outbox acknowledgement must not be negative")
        }
        try {
            database.execute(
                "UPDATE app_event_outbox SET published=1 WHERE thread_id=? " +
                    "AND commit_sequence<=? AND published=0",
                [SqlParameter.Text(threadId.value), SqlParameter.Int64Value(throughCommitSequence)]
            )
            Result.Ok(())
        } catch (error: Exception) {
            semanticRecovery<Unit>(
                "semantic_store.outbox_ack_failed", error.message, Some(threadId), None
            )
        }
    }

    private func transactLocked(
        transaction: SqliteTransaction,
        expected: TransactionPreconditions,
        writes: DurableWriteSet
    ): Result<CommitReceipt> {
        let threadRows = transaction.query(
            "SELECT revision FROM threads WHERE id=?",
            [SqlParameter.Text(expected.threadId.value)]
        )
        if (threadRows.size != 1) {
            return semanticConflict<CommitReceipt>("semantic transaction Thread does not exist")
        }
        let threadRevision = semanticInt(threadRows[0].required(0), "Thread revision")
        if (threadRevision != expected.expectedThreadRevision) {
            return semanticConflict<CommitReceipt>("semantic transaction Thread revision changed")
        }
        let runRows = transaction.query(
            "SELECT thread_id FROM runs WHERE id=?",
            [SqlParameter.Text(expected.runId.value)]
        )
        if (runRows.size != 1 || runRows[0].required(0) != expected.threadId.value) {
            return semanticConflict<CommitReceipt>("semantic transaction Run binding changed")
        }
        let factRows = transaction.query(
            "SELECT COALESCE(MAX(revision),0) FROM run_continuation_facts WHERE run_id=?",
            [SqlParameter.Text(expected.runId.value)]
        )
        let currentRevision = semanticInt(factRows[0].required(0), "continuation revision")
        if (currentRevision != expected.expectedContinuationRevision) {
            return semanticConflict<CommitReceipt>("durable continuation revision changed")
        }
        match (writes.continuation) {
            case Some(value) =>
                if (value.runId.value != expected.runId.value) {
                    return semanticConflict<CommitReceipt>(
                        "durable continuation Run binding does not match transaction"
                    )
                }
                try { let _ = encodeDurableRunContinuation(value) } catch (_: Exception) {
                    return semanticConflict<CommitReceipt>(
                        "durable continuation must have a valid sealed digest"
                    )
                }
                if (interpretRunContinuation(value).isError()) {
                    return semanticConflict<CommitReceipt>(
                        "durable continuation phase is not recoverable from its own payload"
                    )
                }
            case None => ()
        }
        for (event in writes.appEvents) {
            let existing = transaction.query(
                "SELECT 1 FROM app_event_outbox WHERE event_id=?",
                [SqlParameter.Text(event.eventId)]
            )
            if (!existing.isEmpty()) {
                return semanticConflict<CommitReceipt>("App event id is already committed")
            }
        }

        let headRows = transaction.query(
            "SELECT last_sequence FROM thread_commit_heads WHERE thread_id=?",
            [SqlParameter.Text(expected.threadId.value)]
        )
        let commitSequence = if (headRows.isEmpty()) {
            transaction.execute(
                "INSERT INTO thread_commit_heads(thread_id,last_sequence) VALUES (?,1)",
                [SqlParameter.Text(expected.threadId.value)]
            )
            1
        } else {
            let next = semanticInt(headRows[0].required(0), "commit sequence") + 1
            transaction.execute(
                "UPDATE thread_commit_heads SET last_sequence=? WHERE thread_id=?",
                [SqlParameter.Int64Value(next), SqlParameter.Text(expected.threadId.value)]
            )
            next
        }
        let nextRevision = currentRevision + if (
            writes.continuation.isSome() || writes.removeContinuation
        ) { 1 } else { 0 }
        match (writes.continuation) {
            case Some(value) =>
                let payload = encodeDurableRunContinuation(value)
                transaction.execute(
                    "INSERT INTO run_continuation_facts(" +
                        "run_id,thread_id,revision,commit_sequence,phase,payload,digest,created_at_millis" +
                        ") VALUES (?,?,?,?,?,?,?,?)",
                    [
                        SqlParameter.Text(expected.runId.value),
                        SqlParameter.Text(expected.threadId.value),
                        SqlParameter.Int64Value(nextRevision),
                        SqlParameter.Int64Value(commitSequence),
                        SqlParameter.Text(runExecutionPhaseName(value.phase)),
                        SqlParameter.Text(payload),
                        SqlParameter.Text(value.digest),
                        SqlParameter.Int64Value(semanticCommitTimestamp(writes))
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
                        SqlParameter.Text(expected.runId.value), SqlParameter.Int64Value(1),
                        SqlParameter.Int64Value(nextRevision),
                        SqlParameter.Text(runExecutionPhaseName(value.phase)),
                        SqlParameter.Text(payload), SqlParameter.Text(value.digest),
                        SqlParameter.Int64Value(commitSequence)
                    ]
                )
            case None =>
                if (writes.removeContinuation) {
                    let tombstonePayload = encodeStoredValue(objectValue([
                        ValueField("run_id", textValue(expected.runId.value)),
                        ValueField("removed", boolValue(true))
                    ]))
                    transaction.execute(
                        "INSERT INTO run_continuation_facts(" +
                            "run_id,thread_id,revision,commit_sequence,phase,payload,digest,created_at_millis" +
                            ") VALUES (?,?,?,?,?,?,?,?)",
                        [
                            SqlParameter.Text(expected.runId.value),
                            SqlParameter.Text(expected.threadId.value),
                            SqlParameter.Int64Value(nextRevision),
                            SqlParameter.Int64Value(commitSequence), SqlParameter.Text("removed"),
                            SqlParameter.Text(tombstonePayload),
                            SqlParameter.Text(modelPolicySha256Text(tombstonePayload)),
                            SqlParameter.Int64Value(semanticCommitTimestamp(writes))
                        ]
                    )
                    transaction.execute(
                        "DELETE FROM run_continuations WHERE run_id=?",
                        [SqlParameter.Text(expected.runId.value)]
                    )
                }
        }
        for (entry in writes.auditEntries) {
            transaction.execute(
                "INSERT INTO audit_events(" +
                    "thread_id,run_id,operation_id,kind,payload,created_at_millis,commit_sequence" +
                    ") VALUES (?,?,NULL,?,?,?,?)",
                [
                    SqlParameter.Text(expected.threadId.value),
                    SqlParameter.Text(expected.runId.value), SqlParameter.Text(entry.kind),
                    SqlParameter.Text(encodeStoredValue(entry.payload)),
                    SqlParameter.Int64Value(entry.observedAtMillis),
                    SqlParameter.Int64Value(commitSequence)
                ]
            )
        }
        let eventIds = ArrayList<String>()
        var ordinal: Int64 = 0
        for (event in writes.appEvents) {
            transaction.execute(
                "INSERT INTO app_event_outbox(" +
                    "event_id,thread_id,commit_sequence,ordinal,kind,payload,created_at_millis,published" +
                    ") VALUES (?,?,?,?,?,?,?,0)",
                [
                    SqlParameter.Text(event.eventId), SqlParameter.Text(expected.threadId.value),
                    SqlParameter.Int64Value(commitSequence), SqlParameter.Int64Value(ordinal),
                    SqlParameter.Text(event.kind),
                    SqlParameter.Text(encodeStoredValue(event.payload)),
                    SqlParameter.Int64Value(event.createdAtMillis)
                ]
            )
            eventIds.add(event.eventId)
            ordinal += 1
        }
        transaction.execute(
            "UPDATE threads SET revision=revision+1 WHERE id=?",
            [SqlParameter.Text(expected.threadId.value)]
        )
        Result.Ok(CommitReceipt(
            expected.threadId, commitSequence, nextRevision, eventIds.toArray()
        ))
    }
}

func semanticCommitTimestamp(writes: DurableWriteSet): Int64 {
    if (!writes.auditEntries.isEmpty()) { return writes.auditEntries[0].observedAtMillis }
    if (!writes.appEvents.isEmpty()) { return writes.appEvents[0].createdAtMillis }
    0
}

func hasDuplicateOutboxIds(values: Array<SemanticAppEvent>): Bool {
    let seen = HashSet<String>()
    for (value in values) {
        if (seen.contains(value.eventId)) { return true }
        seen.add(value.eventId)
    }
    false
}

func semanticInt(value: String, name: String): Int64 {
    try { Int64.parse(value) } catch (_: Exception) {
        throw IllegalStateException("invalid " + name + " in semantic store")
    }
}

func semanticConflict<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, "semantic_store.conflict", message))
}

func semanticRecovery<T>(
    code: String,
    message: String,
    threadId: ?ThreadId,
    runId: ?RunId
): Result<T> {
    let fields = ArrayList<ErrorField>()
    match (threadId) { case Some(value) => fields.add(ErrorField("thread_id", value.value)); case None => () }
    match (runId) { case Some(value) => fields.add(ErrorField("run_id", value.value)); case None => () }
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code, message, fields: fields.toArray()))
}
