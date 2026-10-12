package persistence_runtime

import yjson_support.*

import yjson.*

import agent_domain.*
import agent_runtime.*
import std.sync.*
import agent_ports.*
import agent_store.*
import std.collection.*
import std.convert.*

public class SqliteRunRecord {
    public let snapshot: RunSnapshot
    public let startedAtMillis: Int64
    public let archived: Bool

    public init(snapshot: RunSnapshot, startedAtMillis: Int64, archived: Bool) {
        this.snapshot = snapshot
        this.startedAtMillis = startedAtMillis
        this.archived = archived
    }
}

// Product-facing Run snapshots and bounded diagnostic events share the same
// SQLite transaction domain as the canonical Thread/Turn/Run lifecycle. The
// canonical run row is created by ThreadCoordinator; this adapter may enrich
// it, but can never create an ownerless Run.
public class SqliteRunRepository <: RunRepository & OwnedRunEventRepository & OwnedOuterErrorRunRepository333 & OwnedFailureRunRepository113 & ReturningModelAttemptRepository159 {
    private let database: SqliteDatabase
    private let eventCapacity: Int64
    private let ownedEventSpoolRoot: ?String
    private let ownedSpoolLock = Mutex()
    private let ownedSpools = ArrayList<OwnedSqliteRunEventWrite>()

    public init(database: SqliteDatabase, eventCapacity!: Int64 = 4096,
        ownedEventSpoolRoot!: ?String = None) {
        if (eventCapacity < 1) {
            throw IllegalArgumentException("event capacity must be positive")
        }
        this.database = database
        this.eventCapacity = eventCapacity
        this.ownedEventSpoolRoot = ownedEventSpoolRoot
    }

    public func saveOwnedOuterError333(value:OwnedOuterErrorFailure333):Result<Unit>{
        saveSqliteOwnedOuterError333(database,value)
    }
    public func appendOwnedOuterError333(value:OwnedOuterErrorFailure333):Result<Unit>{
        appendSqliteOwnedOuterError333(database,eventCapacity,value)
    }

    public func saveOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        let saved = saveSqlitePaidFailure113(database, value)
        match (saved) { case Result.Err(error) => Result<Unit>.Err(error)
            case Result.Ok(_) => value.acknowledgeAfterConsumption() }
    }
    public func appendOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        let appended = appendSqlitePaidFailure113(database, eventCapacity, value)
        match (appended) { case Result.Err(error) => Result<Unit>.Err(error)
            case Result.Ok(_) => value.acknowledgeAfterConsumption() }
    }
    public func saveOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        acknowledgePaidFailurePort113(value,saveSqlitePaidFailureOutcome113(database,value))
    }
    public func appendOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        acknowledgePaidFailurePort113(value,appendSqlitePaidFailureOutcome113(database,eventCapacity,value))
    }
    public func withOwnedFailureSnapshot113(run: RunId, event: EventMeta,
        allocate: (Int64) -> LogicalJsonOwnerReservation,
        consume: (OwnedFailureRunPublication113) -> Unit): OwnedFailureDataOutcome113<Unit> {
        readSqlitePaidFailureSnapshot113(database, run, event, allocate, consume)
    }

    // Trusted actual assembly opts into private spool storage. The ordinary
    // Run repository and its existing event/telemetry paths are unchanged.
    public func stageOwned(event: OwnedAgentEvent): Result<OwnedRunEventWrite> {
        ownedSpoolLock.lock()
        try {
            var index: Int64 = 0
            while (index < ownedSpools.size) {
                if (ownedSpools[index].isAcknowledged()) { ownedSpools.remove(at: index) }
                else { index++ }
            }
            if (ownedEventSpoolRoot.isNone()) { return ownedRunEventDataError("event.spool_not_configured") }
            if (!ownedSpools.isEmpty()) { return ownedRunEventDataError("event.spool_previous_cleanup_pending") }
            let retirement = match (event.retirementWitness()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) => value }
            let root = ownedEventSpoolRoot.getOrThrow()
            let payment = match (event.deriveRetainedAllocation(262144 + root.size * 4)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) => value }
            let write = OwnedSqliteRunEventWrite(database, eventCapacity, event, payment, retirement)
            // Adopt before native open/write. A failed physical close keeps the
            // actual owner/payment here even when stage returns an error.
            ownedSpools.add(write)
            match (write.stage(root)) {
                case Result.Ok(_) => Result<OwnedRunEventWrite>.Ok(write)
                case Result.Err(error) =>
                    let _ = write.closeAfterStorageRetirement()
                    if (write.isAcknowledged()) { ownedSpools.remove(at: ownedSpools.size - 1) }
                    Result<OwnedRunEventWrite>.Err(error) }
        } finally { ownedSpoolLock.unlock() }
    }

    private func consumeLegacyContinuationImports(): Result<Unit> {
        try {
            database.transaction<Result<Unit>>({ transaction =>
                let rows = transaction.query(
                    "SELECT run_id,payload FROM legacy_run_continuation_imports"
                )
                for (row in rows) {
                    let runId = RunId(row.required(0))
                    let source = row.required(1)
                    let legacy = match (decodeContinuation(source)) {
                        case Result.Ok(value) => value
                        case Result.Err(error) => return sqliteRunRecovery<Unit>(
                            runId,
                            "legacy continuation migration source is corrupt: " + error.message
                        )
                    }
                    if (legacy.runId.value != runId.value) {
                        return sqliteRunRecovery<Unit>(
                            runId, "legacy continuation migration identity is corrupt"
                        )
                    }
                    try {
                        consumeLegacyRunContinuationSource(
                            transaction, legacy, source, runContinuationSnapshotValue(legacy)
                        )
                    } catch (error: Exception) {
                        return sqliteRunRecovery<Unit>(
                            runId, "legacy continuation migration failed: " + error.message
                        )
                    }
                }
                Result.Ok(())
            })
        } catch (error: Exception) {
            sqliteRunStorageError(
                "persistence.sqlite_continuation_migration", error.message
            )
        }
    }

    public func save(snapshot: RunSnapshot): Result<Unit> {
        try {
            let rows = database.query(
                "SELECT thread_id FROM runs WHERE id=" + sqliteText(snapshot.runId.value)
            )
            if (rows.size != 1) {
                return sqliteRunMissing<Unit>(snapshot.runId, "canonical Run row is missing")
            }
            if (rows[0].required(0) != snapshot.sessionId.value) {
                return sqliteRunRecovery<Unit>(snapshot.runId, "Run session binding does not match its Thread")
            }
            database.execute(
                "UPDATE runs SET app_snapshot=" + sqliteText(encodeSnapshot(snapshot)) +
                    " WHERE id=" + sqliteText(snapshot.runId.value)
            )
            Result.Ok(())
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_run_save", error.message)
        }
    }

    public func find(runId: RunId): Result<RunSnapshot> {
        try {
            let rows = database.query(
                "SELECT app_snapshot FROM runs WHERE id=" + sqliteText(runId.value)
            )
            if (rows.size != 1) {
                return sqliteRunMissing<RunSnapshot>(runId, "Run was not found")
            }
            match (rows[0][0]) {
                case Some(source) => match (decodeSnapshot(source)) {
                    case Result.Ok(value) =>
                        if (value.runId.value != runId.value) {
                            sqliteRunRecovery<RunSnapshot>(runId, "Run snapshot identity is corrupt")
                        } else {
                            Result.Ok(value)
                        }
                    case Result.Err(_) => sqliteRunRecovery<RunSnapshot>(runId, "Run snapshot is corrupt")
                }
                case None => sqliteRunRecovery<RunSnapshot>(runId, "Run has no product snapshot")
            }
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_run_read", error.message)
        }
    }

    public func events(runId: RunId, after: Int64): Result<EventPage> {
        try {
            if (database.scalarInt(
                "SELECT COUNT(*) FROM runs WHERE id=" + sqliteText(runId.value)
            ) != 1) {
                return sqliteRunMissing<EventPage>(runId, "Run was not found")
            }
            let rows = database.query(
                "SELECT sequence_start,sequence_end,payload,delta_count FROM app_run_events WHERE run_id=" +
                    sqliteText(runId.value) + " ORDER BY sequence"
            )
            let decoded = ArrayList<AgentEvent>()
            let starts = ArrayList<Int64>()
            let ends = ArrayList<Int64>()
            for (row in rows) {
                match (decodeEventLines(row.required(2) + "\n")) {
                    case Result.Ok(values) =>
                        if (values.size != 1 || values[0].runId.value != runId.value) {
                            return sqliteRunRecovery<EventPage>(runId, "Run event binding is corrupt")
                        }
                        decoded.add(values[0])
                        starts.add(Int64.parse(row.required(0)))
                        ends.add(Int64.parse(row.required(1)))
                    case Result.Err(_) => return sqliteRunRecovery<EventPage>(runId, "Run event is corrupt")
                }
            }
            let selected = ArrayList<AgentEvent>()
            var resyncRequired = false
            var retainedCount: Int64 = 0
            for (index in 0..decoded.size) {
                if (ends[index] > after) {
                    selected.add(decoded[index])
                    // Each row counts its original events, including interleaved
                    // streams whose start/end envelope is not continuous coverage.
                    retainedCount += Int64.parse(rows[index].required(3))
                }
                if (after > 0 && starts[index] <= after && after < ends[index]) {
                    resyncRequired = true
                }
            }
            let next = database.scalarInt(
                "SELECT COALESCE((SELECT last_sequence FROM app_run_event_heads WHERE run_id=" +
                    sqliteText(runId.value) + "),0)+1"
            )
            if (after > 0 && after < next - 1 && retainedCount != next - 1 - after) { resyncRequired = true }
            Result.Ok(EventPage(selected.toArray(), next, resyncRequired: resyncRequired))
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_run_events", error.message)
        }
    }

    public func append(event: AgentEvent): Result<Unit> {
        try {
            database.transaction<Result<Unit>>({ transaction =>
                appendRunEventInTransaction(transaction, event, eventCapacity, false)
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_run_event_append", error.message)
        }
    }

    public func persistAttemptPolicy(
        attempt: DurableModelAttempt,
        event: AgentEvent
    ): Result<Unit> {
        try {
            database.transaction<Result<Unit>>({ transaction =>
                let disposition = runEventDisposition(transaction, event)
                if (disposition < 0) {
                    return runEventConflict<Unit>(event)
                }
                persistModelAttemptInTransaction(transaction, attempt)
                if (disposition > 0) {
                    appendRunEventInTransaction(transaction, event, eventCapacity, true)
                } else { Result.Ok(()) }
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_attempt_policy", error.message)
        }
    }

    public func bindAcceptedContextRequest(run: RunId, thread: SessionId, epoch: Int64,
        initiator: ThreadItemContent, request: AgentValue, observedAtMillis: Int64): Result<Unit> {
        try {
            database.transaction { tx =>
                bindAcceptedContextRequestInTransaction(tx, run, thread, epoch, initiator, request, observedAtMillis)
            }
            Result.Ok(())
        } catch (_: Exception) { sqliteRunConflict<Unit>("initial context request lost its canonical Accepted binding") }
    }

    public func saveContinuation(value: RunContinuation): Result<Unit> {
        match (consumeLegacyContinuationImports()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (value.approval.sessionId != value.sessionId.value || value.approval.callId == "" ||
            value.approval.argumentHash == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "run.continuation_binding_invalid",
                "pending approval continuation binding is incomplete"
            ))
        }
        try {
            database.transaction<Result<Unit>>({ transaction =>
                let rows = transaction.query(
                    "SELECT runs.thread_id,run_continuations.payload FROM runs " +
                        "LEFT JOIN run_continuations ON run_continuations.run_id=runs.id WHERE runs.id=" +
                        sqliteText(value.runId.value)
                )
                if (rows.size != 1) {
                    return sqliteRunMissing<Unit>(value.runId, "pending approval Run is missing")
                }
                if (rows[0].required(0) != value.sessionId.value) {
                    return sqliteRunRecovery<Unit>(value.runId, "pending approval session binding is corrupt")
                }
                match (canonicalContinuationFromRow(rows[0], value.runId, 1)) {
                    case Result.Ok(Some(existing)) =>
                            let sameApprovalBinding =
                                existing.kind == RunContinuationKind.WaitingApproval &&
                                value.kind == RunContinuationKind.WaitingApproval &&
                                existing.approval.operationId.value == value.approval.operationId.value &&
                                existing.approval.sessionId == value.approval.sessionId &&
                                existing.approval.callId == value.approval.callId &&
                                existing.approval.argumentHash == value.approval.argumentHash
                            if (sameApprovalBinding && sameContinuationBinding(existing, value)) {
                                return Result.Ok(())
                            }
                            let priorDecision = transaction.query(
                                "SELECT payload FROM approval_decisions WHERE operation_id=" +
                                    sqliteText(existing.approval.operationId.value)
                            )
                            let approvedTransition =
                                existing.kind == RunContinuationKind.WaitingApproval &&
                                value.kind == RunContinuationKind.WaitingApproval &&
                                sameContinuationRequestBinding(existing, value) &&
                                priorDecision.size == 1 && match (decodeDecisionReceipt(
                                    priorDecision[0].required(0)
                                )) {
                                    case Result.Ok(receipt) =>
                                        continuationAcceptsDecision(existing, receipt)
                                    case Result.Err(_) => false
                                }
                            if (!sameContinuationBinding(existing, value) && !approvedTransition) {
                                return operationConflict<Unit>("pending approval continuation binding cannot be changed")
                            }
                            if (encodeContinuation(existing) == encodeContinuation(value)) {
                                return Result.Ok(())
                            }
                    case Result.Ok(None) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                writeRunContinuationSnapshotProjection(
                    transaction, value, runContinuationSnapshotValue(value)
                )
                Result.Ok(())
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_run_continuation_save", error.message)
        }
    }

    public func continuation(runId: RunId): Result<RunContinuation> {
        match (consumeLegacyContinuationImports()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            let rows = database.query(
                "SELECT run_continuations.payload FROM runs " +
                    "LEFT JOIN run_continuations ON run_continuations.run_id=runs.id " +
                    "WHERE runs.id=" + sqliteText(runId.value)
            )
            if (rows.size != 1) { return sqliteRunMissing<RunContinuation>(runId, "Run was not found") }
            match (canonicalContinuationFromRow(rows[0], runId, 0)) {
                case Result.Ok(Some(value)) =>
                    if (value.runId.value == runId.value) { Result.Ok(value) } else {
                        sqliteRunRecovery<RunContinuation>(runId, "pending approval Run binding is corrupt")
                    }
                case Result.Ok(None) => sqliteRunRecovery<RunContinuation>(
                    runId, "awaiting approval Run has no continuation"
                )
                case Result.Err(error) => Result.Err(error)
            }
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_run_continuation_read", error.message)
        }
    }

    public func pendingContinuation(sessionId: SessionId): Result<?RunContinuation> {
        match (consumeLegacyContinuationImports()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            let rows = database.query(
                "SELECT runs.app_snapshot,run_continuations.payload FROM runs " +
                    "LEFT JOIN run_continuations ON run_continuations.run_id=runs.id WHERE runs.thread_id=" +
                    sqliteText(sessionId.value) +
                    " AND run_continuations.payload IS NOT NULL"
            )
            var pending: ?RunContinuation = None
            for (row in rows) {
                let snapshot = match (row[0]) {
                    case Some(source) => match (decodeSnapshot(source)) {
                        case Result.Ok(value) => value
                        case Result.Err(_) => return sqliteRunRecovery<?RunContinuation>(RunId("unknown"), "pending approval snapshot is corrupt")
                    }
                    case None => continue
                }
                if (snapshot.status != RunState.WaitingApproval) { continue }
                if (pending.isSome()) {
                    return Result.Err(AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "run.multiple_pending_approvals",
                        "session has multiple pending approval runs",
                        fields: [ErrorField("session_id", sessionId.value)]
                    ))
                }
                let value = match (canonicalContinuationFromRow(row, snapshot.runId, 1)) {
                    case Result.Ok(Some(item)) => item
                    case Result.Ok(None) => return sqliteRunRecovery<?RunContinuation>(
                        snapshot.runId, "pending approval continuation is missing"
                    )
                    case Result.Err(error) => return Result.Err(error)
                }
                pending = Some(value)
            }
            Result.Ok(pending)
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_pending_scan", error.message)
        }
    }

    public func contextBoundaryPressureItem(runId: RunId): Result<Bool> {
        try { database.transaction<Result<Bool>>({ tx =>
            let rows = tx.query("SELECT payload FROM run_continuations WHERE run_id=?", [SqlParameter.Text(runId.value)])
            if (rows.size != 1) { throw IllegalStateException("pressure recovery has no context boundary") }
            let boundary = requireContextBoundaryCurrent(tx, RunContextBoundary(decodeDurableRunContinuation(rows[0].required(0))))
            let items = tx.query("SELECT payload,provenance FROM items WHERE id=? AND thread_id=? AND turn_id=? AND kind='user_message'",
                [SqlParameter.Text("budget-pressure-" + runId.value), SqlParameter.Text(contextBoundaryText(boundary.data(), "thread_id")),
                    SqlParameter.Text(boundary.continuation.turnId.value)])
            if (items.isEmpty()) { return Result.Ok(false) }
            let expected = encodeStoredThreadContent(ThreadItemContent.UserMessage(textMessageParts(
                "[budget pressure] The work-turn budget is nearly exhausted. " +
                    "Finish the current goal now, avoid starting optional " +
                    "exploration, and converge the current work into a " +
                    "deliverable state.")))
            if (items.size != 1 || items[0].required(0) != expected || items[0].required(1) !=
                encodeStoredProvenance(ItemProvenance("budget", runId: Some(runId)))) {
                throw IllegalStateException("canonical budget pressure item changed") }
            Result.Ok(true)
        }) } catch (error: Exception) { Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "context.boundary_pressure_item_invalid", error.message)) }
    }

    public func contextBoundary(runId: RunId): Result<?RunContextBoundary> {
        try { database.transaction<Result<?RunContextBoundary>>({ tx =>
            let rows = tx.query("SELECT payload FROM run_continuations WHERE run_id=?", [SqlParameter.Text(runId.value)])
            if (rows.isEmpty()) { return Result.Ok(None) }
            if (rows.size != 1) { throw IllegalStateException("multiple context boundaries") }
            let value = decodeDurableRunContinuation(rows[0].required(0))
            if (contextBoundaryData(value).isNone()) { return Result.Ok(None) }
            Result.Ok(Some(requireContextBoundaryCurrent(tx, RunContextBoundary(value))))
        }) } catch (error: Exception) { Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "context.boundary_recovery_required", error.message)) }
    }
    public func pendingContextBoundary(sessionId: SessionId): Result<?RunContextBoundary> {
        try { database.transaction<Result<?RunContextBoundary>>({ tx =>
            let rows = tx.query("SELECT c.payload FROM run_continuations c JOIN runs r ON r.id=c.run_id " +
                "WHERE r.thread_id=? AND r.state IN ('running','waiting_approval','cancelling','recovery_required')",
                [SqlParameter.Text(sessionId.value)])
            var pending: ?RunContextBoundary = None
            for (row in rows) {
                let value = decodeDurableRunContinuation(row.required(0))
                if (contextBoundaryData(value).isNone()) { continue }
                if (pending.isSome()) { throw IllegalStateException("multiple pending context boundaries") }
                pending = Some(requireContextBoundaryCurrent(tx, RunContextBoundary(value)))
            }
            Result.Ok(pending)
        }) } catch (error: Exception) { Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "context.boundary_recovery_required", error.message)) }
    }
    public func reserveContextBoundaryTurn(expected: RunContextBoundary, event: AgentEvent,
        replacement: AgentValue): Result<Unit> {
        try { database.transaction { tx =>
            if (event.runId.value != expected.continuation.runId.value || runEventDisposition(tx, event) != 1) {
                throw IllegalStateException("context boundary accounting event is not fresh") }
            let charged = match (event.payload) { case AgentEventPayload.BudgetUpdated(value) => value
                case _ => throw IllegalArgumentException("context boundary reservation requires original BudgetUpdated") }
            if (canonicalAgentValue(contextBoundaryUsageValue(charged)) !=
                canonicalAgentValue(contextBoundaryField(replacement, "usage"))) {
                throw IllegalStateException("context boundary event and paid snapshot disagree") }
            let next = advanceContextBoundaryTurn(tx, expected, replacement, event.meta.occurredAtMillis)
            match (appendRunEventInTransaction(tx, event, eventCapacity, false)) {
                case Result.Err(error) => throw IllegalStateException(error.describe()); case Result.Ok(_) => () }
            let _ = requireContextBoundaryCurrent(tx, next)
        }; Result.Ok(()) } catch (error: Exception) { Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "context.boundary_reservation_conflict", error.message)) }
    }
    public func prepareContextBoundaryModelAttempt(expected: RunContextBoundary, attempt: DurableModelAttempt,
        event: AgentEvent, continuation: RunContinuation): Result<Unit> {
        prepareModelAttemptWithBoundary(attempt, event, continuation, Some(expected))
    }

    public func pendingRecoveryContinuation(sessionId: SessionId): Result<?RunContinuation> {
        match (consumeLegacyContinuationImports()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            let rows = database.query(
                "SELECT runs.id,run_continuations.payload FROM runs " +
                    "LEFT JOIN run_continuations ON run_continuations.run_id=runs.id WHERE runs.thread_id=" +
                    sqliteText(sessionId.value) +
                    " AND run_continuations.payload IS NOT NULL"
            )
            var pending: ?RunContinuation = None
            for (row in rows) {
                let rowRunId = RunId(row.required(0))
                let durable = decodeDurableRunContinuation(row.required(1))
                match (optionalRunRequestSnapshotFromDurableContinuation(durable)) {
                    case Some(initial) => if (isInitialContextRequest(initial) && contextBoundaryData(durable).isNone() &&
                        database.query("SELECT id FROM runs WHERE id=? AND state IN ('running','waiting_approval','cancelling','recovery_required')",
                            [SqlParameter.Text(rowRunId.value)]).size == 1) {
                        return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                            "context.initial_preparation_interrupted",
                            "initial context data is retained; its live host preparation cannot be replayed after restart",
                            retryable: false, fields: [ErrorField("run_id", rowRunId.value)])) }
                    case None => () }
                let value = match (canonicalContinuationFromRow(row, rowRunId, 1)) {
                    case Result.Ok(Some(item)) => item
                    case Result.Ok(None) => continue
                    case Result.Err(error) => return Result.Err(error)
                }
                if (value.kind != RunContinuationKind.RunningModel) { continue }
                if (pending.isSome()) {
                    return Result.Err(AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "run.multiple_pending_model_executions",
                        "session has multiple pending model executions",
                        fields: [ErrorField("session_id", sessionId.value)]
                    ))
                }
                pending = Some(value)
            }
            Result.Ok(pending)
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_recovery_scan", error.message)
        }
    }

    public func compareAndSwapContinuation(
        expected: ?RunContinuation,
        next: RunContinuation
    ): Result<RunContinuation> {
        match (consumeLegacyContinuationImports()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            database.transaction<Result<RunContinuation>>({ transaction =>
                let rows = transaction.query(
                    "SELECT run_continuations.payload FROM runs " +
                        "LEFT JOIN run_continuations ON run_continuations.run_id=runs.id WHERE runs.id=" +
                        sqliteText(next.runId.value)
                )
                if (rows.size != 1) {
                    return sqliteRunMissing<RunContinuation>(next.runId, "Run was not found")
                }
                let current = match (canonicalContinuationFromRow(rows[0], next.runId, 0)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                if (!sameOptionalRunContinuation(current, expected)) {
                    return match (current) {
                        case Some(winner) => if (sameContinuationBinding(winner, next)) {
                            Result.Ok(winner)
                        } else { sqliteRunConflict<RunContinuation>("Run continuation changed concurrently") }
                        case None => sqliteRunConflict<RunContinuation>("Run continuation changed concurrently")
                    }
                }
                writeRunContinuationSnapshotProjection(
                    transaction, next, runContinuationSnapshotValue(next)
                )
                Result.Ok(next)
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_continuation_cas", error.message)
        }
    }

    public func prepareInternalModelAttempt(attempt: DurableModelAttempt, event: AgentEvent,
        input: InternalModelAttemptInput): Result<Unit> {
        try {
            database.transaction<Result<Unit>>({ transaction =>
                if (event.runId.value != input.runId.value || event.meta.attemptId.isNone() ||
                    event.meta.attemptId.getOrThrow().value != attempt.id.value || runEventDisposition(transaction, event) != 1) {
                    return sqliteRunConflict<Unit>("internal model prepare event binding changed")
                }
                prepareInternalModelAttemptInTransaction(transaction, attempt, input)
                appendRunEventInTransaction(transaction, event, eventCapacity, true)
            })
        } catch (_: Exception) { sqliteRunConflict<Unit>("internal model Attempt preparation rejected") }
    }

    public func settleInternalModelAttempt(attempt: ModelAttemptId, input: InternalModelAttemptInput,
        outcome: Result<ModelReply>, completedAtMillis: Int64): Result<Unit> {
        try {
            database.transaction { transaction =>
                settleInternalModelAttemptInTransaction(transaction, attempt, input, outcome, completedAtMillis)
            }
            Result.Ok(())
        } catch (_: Exception) { sqliteRunConflict<Unit>("internal model Attempt settlement rejected") }
    }

    public func prepareModelAttemptReturning159(loan: ModelInputToolsBorrow159,
        attempt: DurableModelAttempt, event: AgentEvent, continuation: RunContinuation): Result<Unit> {
        // The actual original SQL method, transaction closure, codecs and
        // statements all returned. No input continuation is cached here.
        let result = prepareModelAttempt(attempt, event, continuation)
        match (result) { case Result.Ok(_) => loan.returnModelToolsFrame159(); case Result.Err(_) => () }
        result
    }

    public func prepareContextBoundaryModelAttemptReturning159(loan: ModelInputToolsBorrow159,
        expected: RunContextBoundary, attempt: DurableModelAttempt, event: AgentEvent, continuation: RunContinuation): Result<Unit> {
        // The actual original SQL method, transaction closure, codecs and
        // statements all returned. No input continuation is cached here.
        let result = prepareContextBoundaryModelAttempt(expected, attempt, event, continuation)
        match (result) { case Result.Ok(_) => loan.returnModelToolsFrame159(); case Result.Err(_) => () }
        result
    }

    public func prepareRestartModelAttemptReturning159(loan: ModelInputToolsBorrow159,
        parent: DurableModelAttempt, attempt: DurableModelAttempt, policyEvent: AgentEvent, duplicateEvent: AgentEvent, continuation: RunContinuation): Result<Unit> {
        // The actual original SQL method, transaction closure, codecs and
        // statements all returned. No input continuation is cached here.
        let result = prepareRestartModelAttempt(parent, attempt, policyEvent, duplicateEvent, continuation)
        match (result) { case Result.Ok(_) => loan.returnModelToolsFrame159(); case Result.Err(_) => () }
        result
    }

    public func prepareModelAttempt(attempt: DurableModelAttempt, event: AgentEvent,
        continuation: RunContinuation): Result<Unit> {
        prepareModelAttemptWithBoundary(attempt, event, continuation, None)
    }

    private func prepareModelAttemptWithBoundary(
        attempt: DurableModelAttempt,
        event: AgentEvent,
        continuation: RunContinuation,
        expectedBoundary: ?RunContextBoundary
    ): Result<Unit> {
        match (consumeLegacyContinuationImports()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (!modelContinuationMatchesAttempt(continuation, attempt)) {
            return sqliteRunConflict<Unit>("model continuation does not match its Attempt")
        }
        try {
            database.transaction<Result<Unit>>({ transaction =>
                let rows = transaction.query(
                    "SELECT run_continuations.payload FROM runs " +
                        "LEFT JOIN run_continuations ON run_continuations.run_id=runs.id WHERE runs.id=" +
                        sqliteText(attempt.runId.value)
                )
                if (rows.size != 1) { return sqliteRunMissing<Unit>(attempt.runId, "Run was not found") }
                match (expectedBoundary) { case Some(expected) =>
                    let actual = requireContextBoundaryCurrent(transaction, expected)
                    let data = actual.data()
                    requireBoundaryFreshModelRequest(data, continuation)
                    let checkpoint = continuation.runningModel.getOrThrow()
                    let count = contextBoundaryField(data, "counter")
                    if (contextBoundaryText(data, "point") != "turn_reserved" || attempt.attemptNo != 1 || attempt.parentAttemptId.isSome() ||
                        contextBoundaryText(contextBoundaryField(data, "request"), "run_id") != continuation.runId.value ||
                        contextBoundaryText(data, "thread_id") != continuation.sessionId.value ||
                        contextBoundaryInteger(count, "turns") != checkpoint.turns ||
                        contextBoundaryInteger(count, "model_requests") == Int64.Max ||
                        attempt.semanticRequestId.value != "semantic-" + attempt.runId.value + "-model-" +
                            (contextBoundaryInteger(count, "model_requests") + 1).toString() ||
                        checkpoint.modelRequests != contextBoundaryInteger(count, "model_requests") ||
                        checkpoint.workModelRequests != contextBoundaryInteger(count, "work_model_requests") ||
                        checkpoint.drainModelRequests != contextBoundaryInteger(count, "drain_model_requests") ||
                        checkpoint.inputTokens != contextBoundaryInteger(count, "input_tokens") ||
                        checkpoint.outputTokens != contextBoundaryInteger(count, "output_tokens") ||
                        checkpoint.reasoningTokens != contextBoundaryInteger(count, "reasoning_tokens") ||
                        checkpoint.cacheReadTokens != contextBoundaryInteger(count, "cache_read_tokens") ||
                        checkpoint.cacheWriteTokens != contextBoundaryInteger(count, "cache_write_tokens") ||
                        checkpoint.lastInputTokens != contextBoundaryInteger(count, "last_input_tokens") ||
                        checkpoint.lastOutputTokens != contextBoundaryInteger(count, "last_output_tokens") ||
                        checkpoint.lastRequestDurationMillis != contextBoundaryInteger(count, "last_duration_millis") ||
                        checkpoint.toolCalls != contextBoundaryInteger(count, "tool_calls") ||
                        canonicalAgentValue(match (checkpoint.costMicros) { case Some(cost) => integerValue(cost); case None => nullValue() }) !=
                            canonicalAgentValue(contextBoundaryField(count, "cost_micros")) ||
                        checkpoint.consecutiveCapabilityDenials != contextBoundaryInteger(contextBoundaryField(data, "tool_loop_state"), "consecutive_capability_denials") ||
                        checkpoint.lastCapabilityDeniedTool != contextBoundaryText(contextBoundaryField(data, "tool_loop_state"), "last_capability_denied_tool") ||
                        checkpoint.stableTurnId != contextBoundaryText(contextBoundaryField(data, "control"), "active_turn_id") ||
                        contextBoundaryInteger(contextBoundaryField(data, "control"), "request_serial") == Int64.Max ||
                        checkpoint.stableRequestId != attempt.runId.value + "-request-" +
                            (contextBoundaryInteger(contextBoundaryField(data, "control"), "request_serial") + 1).toString()) {
                        throw IllegalStateException("fresh model Attempt does not match the paid context boundary") }
                    case None => if (rows[0][0].isSome() && contextBoundaryData(
                        decodeDurableRunContinuation(rows[0].required(0))).isSome()) {
                        throw IllegalStateException("context boundary requires its exact fresh Attempt prepare") } }
                match (canonicalContinuationFromRow(rows[0], attempt.runId, 0)) {
                    case Result.Ok(Some(existing)) =>
                            let exactMatch = sameContinuationBinding(existing, continuation)
                            let priorDecision = transaction.query(
                                "SELECT payload FROM approval_decisions WHERE operation_id=" +
                                    sqliteText(existing.approval.operationId.value)
                            )
                            let approvedTransition =
                                existing.kind == RunContinuationKind.WaitingApproval &&
                                continuation.kind == RunContinuationKind.RunningModel &&
                                sameContinuationRequestBinding(existing, continuation) &&
                                priorDecision.size == 1 && match (decodeDecisionReceipt(
                                    priorDecision[0].required(0)
                                )) {
                                    case Result.Ok(receipt) =>
                                        continuationAcceptsDecision(existing, receipt)
                                    case Result.Err(_) => false
                                }
                            let retryRequestMatch =
                                sameContinuationRequestBinding(existing, continuation)
                            let retryTransition =
                                existing.kind == RunContinuationKind.RunningModel &&
                                continuation.kind == RunContinuationKind.RunningModel &&
                                retryRequestMatch &&
                                match ((existing.runningModel, continuation.runningModel,
                                    attempt.parentAttemptId)) {
                                    case (Some(previous), Some(next), Some(parentId)) =>
                                        parentId.value == previous.activeAttemptId.value &&
                                        next.originalAttemptId.value == previous.originalAttemptId.value &&
                                        next.semanticRequestId.value == previous.semanticRequestId.value &&
                                        next.semanticRequestDigest == previous.semanticRequestDigest &&
                                        next.wirePolicyDigest == previous.wirePolicyDigest &&
                                        match (readModelAttempt(transaction, parentId)) {
                                            case Result.Ok(parent) =>
                                                parent.lifecycle == ModelAttemptLifecycle.Abandoned &&
                                                parent.attemptNo + 1 == attempt.attemptNo &&
                                                parent.semanticRequestId.value == attempt.semanticRequestId.value
                                            case Result.Err(_) => false
                                        }
                                    case _ => false
                                }
                            if (!exactMatch && !approvedTransition && !retryTransition) {
                                return sqliteRunConflict<Unit>("model continuation changed concurrently")
                            }
                    case Result.Ok(None) => ()
                    case Result.Err(error) => return Result<Unit>.Err(error)
                }
                let disposition = runEventDisposition(transaction, event)
                if (disposition < 0) { return runEventConflict<Unit>(event) }
                if (!transaction.query("SELECT id FROM model_attempts WHERE run_id=? AND lifecycle IN ('created','streaming') " +
                    "AND policy_reason IN ('internal_approval_review','internal_context_compaction')",
                    [SqlParameter.Text(attempt.runId.value)]).isEmpty()) {
                    return sqliteRunConflict<Unit>("ordinary model prepare cannot replace an unsettled internal Attempt")
                }
                persistModelAttemptInTransaction(transaction, attempt)
                if (disposition > 0) {
                    match (appendRunEventInTransaction(transaction, event, eventCapacity, true)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return Result<Unit>.Err(error)
                    }
                }
                writeRunContinuationSnapshotProjection(
                    transaction, continuation, runContinuationSnapshotValue(continuation)
                )
                Result.Ok(())
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_model_attempt_prepare", error.message)
        }
    }

    public func prepareRestartModelAttempt(
        parent: DurableModelAttempt,
        attempt: DurableModelAttempt,
        policyEvent: AgentEvent,
        duplicateEvent: AgentEvent,
        continuation: RunContinuation
    ): Result<Unit> {
        match (consumeLegacyContinuationImports()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        if (attempt.parentAttemptId.isNone() ||
            attempt.parentAttemptId.getOrThrow().value != parent.id.value ||
            attempt.attemptNo != parent.attemptNo + 1 ||
            attempt.lifecycle != ModelAttemptLifecycle.Created ||
            attempt.dispatchState != ModelAttemptDispatchState.Prepared ||
            attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier ||
            attempt.semanticRequestId.value != parent.semanticRequestId.value ||
            attempt.semanticRequestDigest != parent.semanticRequestDigest ||
            attempt.wirePolicyDigest != parent.wirePolicyDigest ||
            duplicateEvent.sequence != policyEvent.sequence + 1 ||
            !modelContinuationMatchesAttempt(continuation, attempt)) {
            return sqliteRunConflict<Unit>("restart model boundary identity drift")
        }
        try {
            database.transaction<Result<Unit>>({ transaction =>
                let stored = readModelAttempt(transaction, parent.id)
                let current = match (stored) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                if (!sameDurableAttempt(current, parent) ||
                    current.dispatchState != ModelAttemptDispatchState.DispatchClaimed ||
                    current.replayBarrier != ModelAttemptReplayBarrier.NoBarrier) {
                    return sqliteRunRecovery<Unit>(parent.runId, "restart parent Attempt is not recoverable")
                }
                let continuationRows = transaction.query(
                    "SELECT run_continuations.payload FROM runs " +
                        "LEFT JOIN run_continuations ON run_continuations.run_id=runs.id WHERE runs.id=" +
                        sqliteText(parent.runId.value)
                )
                if (continuationRows.size != 1) {
                    return sqliteRunRecovery<Unit>(parent.runId, "restart continuation is missing")
                }
                let previous = match (canonicalContinuationFromRow(
                    continuationRows[0], parent.runId, 0
                )) {
                    case Result.Ok(Some(value)) => value
                    case Result.Ok(None) => return sqliteRunRecovery<Unit>(
                        parent.runId, "restart continuation is missing"
                    )
                    case Result.Err(error) => return Result.Err(error)
                }
                if (previous.runningModel.isNone() ||
                    previous.runningModel.getOrThrow().activeAttemptId.value != parent.id.value ||
                    runEventDisposition(transaction, policyEvent) != 1 ||
                    runEventDispositionAfter(transaction, duplicateEvent, policyEvent.sequence) != 1) {
                    return sqliteRunConflict<Unit>("restart model boundary changed concurrently")
                }
                transaction.execute(
                    "UPDATE model_attempts SET lifecycle='abandoned',failure_kind=" +
                        sqliteText("process_restart_possible_duplicate") +
                        ",completed_at_millis=" + duplicateEvent.meta.occurredAtMillis.toString() +
                        ",last_activity_at_millis=" + duplicateEvent.meta.occurredAtMillis.toString() +
                        " WHERE id=" + sqliteText(parent.id.value) +
                        " AND lifecycle IN ('created','streaming')"
                )
                persistModelAttemptInTransaction(transaction, attempt)
                match (appendRunEventInTransaction(transaction, policyEvent, eventCapacity, true)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                match (appendRunEventInTransaction(transaction, duplicateEvent, eventCapacity, true)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                writeRunContinuationSnapshotProjection(
                    transaction, continuation, runContinuationSnapshotValue(continuation)
                )
                Result.Ok(())
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_restart_attempt_prepare", error.message)
        }
    }

    public func modelAttempt(attemptId: ModelAttemptId): Result<DurableModelAttempt> {
        try {
            let rows = database.query(modelAttemptSelect() + " WHERE id=" + sqliteText(attemptId.value))
            if (rows.size != 1) {
                return sqliteRunRecovery<DurableModelAttempt>(
                    RunId("unknown"), "durable model Attempt is missing"
                )
            }
            decodeModelAttemptRow(rows[0])
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_model_attempt_read", error.message)
        }
    }

    public func claimModelAttemptDispatch(
        attemptId: ModelAttemptId,
        event: AgentEvent
    ): Result<Bool> {
        try {
            database.transaction<Result<Bool>>({ transaction =>
                let attempt = match (readModelAttempt(transaction, attemptId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                if (attempt.runId.value != event.runId.value) {
                    return sqliteRunConflict<Bool>("model dispatch event Run binding drift")
                }
                if (attempt.policyReason == "internal_approval_review" || attempt.policyReason == "internal_context_compaction") {
                    if (event.meta.attemptId.isNone() || event.meta.attemptId.getOrThrow().value != attempt.id.value ||
                        event.meta.requestId.isNone() || event.meta.requestId.getOrThrow().value != attempt.providerRequestId ||
                        event.meta.semanticRequestId.isNone() || event.meta.semanticRequestId.getOrThrow().value != attempt.semanticRequestId.value) {
                        return sqliteRunConflict<Bool>("internal model claim event identity differs")
                    }
                    let _ = verifyInternalModelAttemptCurrent(transaction, attemptId, attempt.runId)
                }
                if (attempt.dispatchState == ModelAttemptDispatchState.DispatchClaimed) {
                    return Result.Ok(false)
                }
                if ((attempt.policyReason == "internal_approval_review" || attempt.policyReason == "internal_context_compaction") &&
                    attempt.lifecycle != ModelAttemptLifecycle.Created) {
                    return sqliteRunRecovery<Bool>(attempt.runId, "terminal internal Attempt cannot be reclaimed")
                }
                if (attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier ||
                    runEventDisposition(transaction, event) != 1) {
                    return sqliteRunRecovery<Bool>(attempt.runId, "model Attempt is not dispatchable")
                }
                transaction.execute(
                    "UPDATE model_attempts SET lifecycle='streaming',dispatch_state='dispatch_claimed'," +
                        "dispatch_started_at_millis=" + event.meta.occurredAtMillis.toString() +
                        ",last_activity_at_millis=" + event.meta.occurredAtMillis.toString() +
                        " WHERE id=" + sqliteText(attemptId.value) + " AND dispatch_state='prepared'"
                )
                match (appendRunEventInTransaction(transaction, event, eventCapacity, true)) {
                    case Result.Ok(_) => Result.Ok(true)
                    case Result.Err(error) => Result.Err(error)
                }
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_model_dispatch_claim", error.message)
        }
    }

    public func markModelAttemptReplayBarrier(
        attemptId: ModelAttemptId,
        barrier: ModelAttemptReplayBarrier,
        event: AgentEvent
    ): Result<Unit> {
        if (barrier == ModelAttemptReplayBarrier.NoBarrier) {
            return sqliteRunConflict<Unit>("model replay barrier cannot be cleared")
        }
        try {
            database.transaction<Result<Unit>>({ transaction =>
                let attempt = match (readModelAttempt(transaction, attemptId)) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                let disposition = runEventDisposition(transaction, event)
                if (attempt.replayBarrier == barrier) {
                    return if (disposition == 0) { Result.Ok(()) } else {
                        sqliteRunConflict<Unit>("model replay barrier event identity drift")
                    }
                }
                if (attempt.replayBarrier != ModelAttemptReplayBarrier.NoBarrier || disposition != 1) {
                    return sqliteRunConflict<Unit>("model replay barrier changed concurrently")
                }
                transaction.execute(
                    "UPDATE model_attempts SET replay_barrier=" +
                        sqliteText(modelAttemptReplayBarrierName(barrier)) +
                        if (barrier == ModelAttemptReplayBarrier.ProviderTerminal) {
                            ",provider_terminal_at_millis=" + event.meta.occurredAtMillis.toString()
                        } else { "" } +
                        " WHERE id=" + sqliteText(attemptId.value) + " AND replay_barrier='none'"
                )
                appendRunEventInTransaction(transaction, event, eventCapacity, true)
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_model_replay_barrier", error.message)
        }
    }

    public func clearModelExecutionContinuation(
        runId: RunId, activeAttemptId: ModelAttemptId
    ): Result<Unit> {
        match (consumeLegacyContinuationImports()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            database.transaction<Result<Unit>>({ transaction =>
                settleModelExecutionContinuation(transaction, runId, activeAttemptId)
                Result.Ok(())
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_model_continuation_clear", error.message)
        }
    }

    public func saveDecision(receipt: ApprovalDecisionReceipt): Result<Unit> {
        try {
            database.transaction<Result<Unit>>({ transaction =>
                saveSqliteDecision(transaction, receipt)
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_decision_save", error.message)
        }
    }

    public func decision(operationId: OperationId): Result<ApprovalDecisionReceipt> {
        try {
            let rows = database.query(
                "SELECT payload FROM approval_decisions WHERE operation_id=" + sqliteText(operationId.value)
            )
            if (rows.size != 1) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "persistence.not_found",
                    "approval decision receipt was not found",
                    fields: [ErrorField("operation_id", operationId.value)]
                ))
            }
            decodeDecisionReceipt(rows[0].required(0))
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_decision_read", error.message)
        }
    }

    public func recordDecision(receipt: ApprovalDecisionReceipt): Result<RunSnapshot> {
        try {
            database.transaction<Result<RunSnapshot>>({ transaction =>
                let rows = transaction.query(
                    "SELECT thread_id,app_snapshot FROM runs WHERE id=" + sqliteText(receipt.runId.value)
                )
                if (rows.size != 1) {
                    return sqliteRunRecovery<RunSnapshot>(receipt.runId, "approval decision Run is missing")
                }
                if (rows[0].required(0) != receipt.sessionId.value) {
                    return sqliteRunRecovery<RunSnapshot>(receipt.runId, "approval decision session binding is corrupt")
                }
                let snapshot = match (rows[0][1]) {
                    case Some(source) => match (decodeSnapshot(source)) {
                        case Result.Ok(value) => value
                        case Result.Err(_) => return sqliteRunRecovery<RunSnapshot>(receipt.runId, "approval decision Run snapshot is corrupt")
                    }
                    case None => return sqliteRunRecovery<RunSnapshot>(receipt.runId, "approval decision Run snapshot is missing")
                }
                if (snapshot.status != RunState.WaitingApproval && snapshot.status != RunState.Completed) {
                    return operationConflict<RunSnapshot>("run is not waiting for an approval decision")
                }
                let saved = saveSqliteDecision(transaction, receipt)
                match (saved) {
                    case Result.Ok(_) => Result.Ok(snapshot)
                    case Result.Err(error) => Result.Err(error)
                }
            })
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_atomic_decision", error.message)
        }
    }

    public func continuationModelInput(item: ThreadItem): Result<ModelMessage> {
        try {
            database.readTransaction<Result<ModelMessage>>({ transaction =>
                let value = if (isContinuationHistoryDescription(item)) { continuationHistoryRequest(transaction, item) }
                    else { consumedContinuationRequest(transaction, item) }
                let model = match (modelRequestFromSnapshotValue(value.field("model_input").getOrThrow(), "")) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(result) => result }
                if (model.messages.size != 1 || model.messages[0].role != ModelRole.User) {
                    return sqliteRunRecovery<ModelMessage>(item.provenance.runId.getOrThrow(), "continuation model input is malformed") }
                Result.Ok(model.messages[0])
            })
        } catch (_: Exception) { sqliteRunRecovery<ModelMessage>(item.provenance.runId.getOrThrow(), "continuation claim or frozen input changed") }
    }

    public func stats(sessionId: SessionId): Result<SessionRunStats> {
        try {
            database.transaction<Result<SessionRunStats>>({ transaction => statsInTransaction(transaction, sessionId) })
        } catch (error: Exception) { sqliteRunStorageError("persistence.sqlite_run_list", error.message) }
    }

    // Read the same canonical product snapshots while an existing caller owns
    // the transaction. Never re-enter database.transaction from a document CAS
    // callback. This returns accounting facts, not a continuation grant.
    public func statsInTransaction(transaction: SqliteTransaction, sessionId: SessionId): Result<SessionRunStats> {
        let rows = transaction.query(
            "SELECT app_snapshot FROM runs WHERE thread_id=? AND app_snapshot IS NOT NULL ORDER BY started_at_millis,id",
            [SqlParameter.Text(sessionId.value)])
        let snapshots = ArrayList<RunSnapshot>()
        for (row in rows) {
            match (decodeSnapshot(row.required(0))) {
                case Result.Ok(value) => snapshots.add(value)
                case Result.Err(_) => return sqliteRunRecovery<SessionRunStats>(RunId("unknown"), "Run snapshot is corrupt")
            }
        }
        var modelRequests: Int64 = 0
        var inputTokens: Int64 = 0
        var outputTokens: Int64 = 0
        var reasoningTokens: Int64 = 0
        var cacheReadTokens: Int64 = 0
        var cacheWriteTokens: Int64 = 0
        var totalCostMicros: Int64 = 0
        var costKnown = true
        var toolCalls: Int64 = 0
        var turns: Int64 = 0
        var lastInputTokens: Int64 = 0
        var lastOutputTokens: Int64 = 0
        var lastRequestDurationMillis: Int64 = 0
        for (snapshot in snapshots) {
            modelRequests += snapshot.modelRequests
            inputTokens += snapshot.inputTokens
            outputTokens += snapshot.outputTokens
            reasoningTokens += snapshot.reasoningTokens
            cacheReadTokens += snapshot.cacheReadTokens
            cacheWriteTokens += snapshot.cacheWriteTokens
            if (snapshot.modelRequests > 0) {
                match (snapshot.costMicros) {
                    case Some(value) => totalCostMicros += value
                    case None => costKnown = false
                }
                // Maintenance remains included in every total above. Its
                // prompt is not the user's conversational context window.
                if (snapshot.kind == RunKind.Agent || snapshot.kind == RunKind.Chat) {
                    lastInputTokens = snapshot.lastInputTokens
                    lastOutputTokens = snapshot.lastOutputTokens
                    lastRequestDurationMillis = snapshot.lastRequestDurationMillis
                }
            }
            toolCalls += snapshot.toolCalls
            turns += snapshot.turns
        }
        Result.Ok(SessionRunStats(
            snapshots.size, modelRequests, inputTokens, outputTokens, toolCalls, turns,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            costMicros: if (modelRequests > 0 && costKnown) { Some(totalCostMicros) } else { None },
            lastInputTokens: lastInputTokens,
            lastOutputTokens: lastOutputTokens,
            lastRequestDurationMillis: lastRequestDurationMillis
        ))
    }

    public func snapshots(sessionId: SessionId): Result<Array<RunSnapshot>> {
        try {
            let rows = database.query(
                "SELECT app_snapshot FROM runs WHERE thread_id=" + sqliteText(sessionId.value) +
                    " AND app_snapshot IS NOT NULL ORDER BY started_at_millis,id"
            )
            let values = ArrayList<RunSnapshot>()
            for (row in rows) {
                match (decodeSnapshot(row.required(0))) {
                    case Result.Ok(value) => values.add(value)
                    case Result.Err(_) => return sqliteRunRecovery<Array<RunSnapshot>>(RunId("unknown"), "Run snapshot is corrupt")
                }
            }
            Result.Ok(values.toArray())
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_run_list", error.message)
        }
    }

    public func records(): Result<Array<SqliteRunRecord>> {
        try {
            let rows = database.query(
                "SELECT runs.thread_id,runs.app_snapshot,runs.started_at_millis,threads.status " +
                    "FROM runs JOIN threads ON threads.id=runs.thread_id " +
                    "WHERE runs.app_snapshot IS NOT NULL ORDER BY runs.started_at_millis,runs.id"
            )
            let values = ArrayList<SqliteRunRecord>()
            for (row in rows) {
                let snapshot = match (decodeSnapshot(row.required(1))) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => return sqliteRunRecovery<Array<SqliteRunRecord>>(
                        RunId("unknown"), "Run snapshot is corrupt"
                    )
                }
                if (snapshot.sessionId.value != row.required(0)) {
                    return sqliteRunRecovery<Array<SqliteRunRecord>>(
                        snapshot.runId, "Run snapshot Thread binding is corrupt"
                    )
                }
                let started = try { Int64.parse(row.required(2)) } catch (_: Exception) {
                    return sqliteRunRecovery<Array<SqliteRunRecord>>(
                        snapshot.runId, "Run start timestamp is corrupt"
                    )
                }
                values.add(SqliteRunRecord(snapshot, started, row.required(3) == "closed"))
            }
            Result.Ok(values.toArray())
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_run_records", error.message)
        }
    }
}

func appendRunEventInTransaction(
    transaction: SqliteTransaction,
    event: AgentEvent,
    eventCapacity: Int64,
    allowExisting: Bool
): Result<Unit> {
    let disposition = runEventDisposition(transaction, event)
    if (disposition == 0) {
        return if (allowExisting) { Result.Ok(()) } else { runEventConflict<Unit>(event) }
    }
    if (disposition < 0) { return runEventConflict<Unit>(event) }
    let telemetry = runEventTelemetry(event)
    match (telemetry) {
        case Some(info) =>
            let rows = transaction.query(
                "SELECT sequence,sequence_start,payload,delta_count,char_count FROM app_run_events " +
                    "WHERE run_id=" + sqliteText(event.runId.value) +
                    " AND event_class='telemetry' AND stream_key=" + sqliteText(info.streamKey) +
                    " ORDER BY sequence DESC LIMIT 1"
            )
            if (!rows.isEmpty()) {
                let previousChars = Int64.parse(rows[0].required(4))
                if (previousChars + info.text.size <= 8192) {
                    let previous = match (decodeEventLines(rows[0].required(2) + "\n")) {
                        case Result.Ok(values) => if (values.size == 1) { values[0] } else {
                            return sqliteRunRecovery<Unit>(event.runId, "aggregated Run event is corrupt")
                        }
                        case Result.Err(_) => return sqliteRunRecovery<Unit>(
                            event.runId, "aggregated Run event is corrupt"
                        )
                    }
                    let merged = match (mergeRunTelemetry(previous, event)) {
                        case Some(value) => value
                        case None => return sqliteRunConflict<Unit>("telemetry stream shape drift")
                    }
                    transaction.execute(
                        "UPDATE app_run_events SET sequence=" + event.sequence.toString() +
                            ",sequence_end=" + event.sequence.toString() +
                            ",payload=" + sqliteText(encodeEvent(merged)) +
                            ",delta_count=" + (Int64.parse(rows[0].required(3)) + 1).toString() +
                            ",char_count=" + (previousChars + info.text.size).toString() +
                            ",created_at_millis=" + agentUtcMillis().toString() +
                            " WHERE run_id=" + sqliteText(event.runId.value) +
                            " AND sequence=" + rows[0].required(0)
                    )
                    updateRunEventHeadAndPrune(
                        transaction, event.runId, event.sequence, eventCapacity
                    )
                    return Result.Ok(())
                }
            }
        case None => ()
    }
    let eventClass = if (telemetry.isSome()) { "telemetry" } else { "lifecycle" }
    let streamKey = match (telemetry) { case Some(info) => info.streamKey; case None => "" }
    let charCount = match (telemetry) { case Some(info) => info.text.size; case None => 0 }
    transaction.execute(
        "INSERT INTO app_run_events(run_id,sequence,sequence_start,sequence_end,payload," +
            "accounting,event_class,stream_key,delta_count,char_count,created_at_millis) VALUES(" +
            sqliteText(event.runId.value) + "," + event.sequence.toString() + "," +
            event.sequence.toString() + "," + event.sequence.toString() + "," +
            sqliteText(encodeEvent(event)) + "," +
            if (isRunAccountingEvent(event)) { "1" } else { "0" } + "," +
            sqliteText(eventClass) + "," + sqliteText(streamKey) + ",1," +
            charCount.toString() + "," + agentUtcMillis().toString() + ")"
    )
    updateRunEventHeadAndPrune(transaction, event.runId, event.sequence, eventCapacity)
    Result.Ok(())
}

class RunEventTelemetry {
    let streamKey: String
    let text: String

    init(streamKey: String, text: String) {
        this.streamKey = streamKey
        this.text = text
    }
}

func runEventTelemetry(event: AgentEvent): ?RunEventTelemetry {
    let scope = ":" + match (event.meta.semanticRequestId) {
        case Some(value) => value.value
        case None => ""
    } + ":" + match (event.meta.attemptId) {
        case Some(value) => value.value
        case None => ""
    }
    match (event.payload) {
        case AgentEventPayload.TextDelta(text) => Some(RunEventTelemetry("text" + scope, text))
        case AgentEventPayload.ReasoningDelta(text) => Some(RunEventTelemetry("reasoning" + scope, text))
        case AgentEventPayload.ToolOutput(callId, channel, text) => Some(RunEventTelemetry(
            "tool_output:" + callId.value + ":" + toolOutputChannelKey(channel) + scope,
            text
        ))
        case AgentEventPayload.Extension(AgentEventKind.Model, detail) =>
            if (runEventFieldText(detail, "code") == "model.tool_arguments" &&
                runEventFieldText(detail, "call_id") != "") {
                Some(RunEventTelemetry(
                    "tool_arguments:" + runEventFieldText(detail, "call_id") + scope,
                    runEventFieldText(detail, "text")
                ))
            } else { None }
        case _ => None
    }
}

func mergeRunTelemetry(previous: AgentEvent, next: AgentEvent): ?AgentEvent {
    let payload: ?AgentEventPayload = match ((previous.payload, next.payload)) {
        case (AgentEventPayload.TextDelta(left), AgentEventPayload.TextDelta(right)) =>
            Some(AgentEventPayload.TextDelta(left + right))
        case (AgentEventPayload.ReasoningDelta(left), AgentEventPayload.ReasoningDelta(right)) =>
            Some(AgentEventPayload.ReasoningDelta(left + right))
        case (AgentEventPayload.ToolOutput(leftId, leftChannel, left),
              AgentEventPayload.ToolOutput(rightId, rightChannel, right)) =>
            if (leftId.value == rightId.value && leftChannel == rightChannel) {
                Some(AgentEventPayload.ToolOutput(leftId, leftChannel, left + right))
            } else { None }
        case (AgentEventPayload.Extension(AgentEventKind.Model, left),
              AgentEventPayload.Extension(AgentEventKind.Model, right)) =>
            if (runEventFieldText(left, "code") == "model.tool_arguments" &&
                runEventFieldText(right, "code") == "model.tool_arguments" &&
                runEventFieldText(left, "call_id") == runEventFieldText(right, "call_id")) {
                Some(AgentEventPayload.Extension(AgentEventKind.Model, objectValue([
                    ValueField("code", textValue("model.tool_arguments")),
                    ValueField("call_id", textValue(runEventFieldText(right, "call_id"))),
                    ValueField("text", textValue(
                        runEventFieldText(left, "text") + runEventFieldText(right, "text")
                    ))
                ])))
            } else { None }
        case _ => None
    }
    match (payload) {
        case Some(value) => Some(AgentEvent(EventMeta(
            next.meta.sequence,
            next.meta.traceId,
            next.meta.runId,
            occurredAtMillis: next.meta.occurredAtMillis,
            turnId: next.meta.turnId,
            requestId: next.meta.requestId,
            semanticRequestId: next.meta.semanticRequestId,
            attemptId: next.meta.attemptId,
            toolBatchId: next.meta.toolBatchId,
            toolCallId: next.meta.toolCallId,
            operationId: next.meta.operationId
        ), value))
        case None => None
    }
}

func updateRunEventHeadAndPrune(
    transaction: SqliteTransaction,
    runId: RunId,
    sequence: Int64,
    eventCapacity: Int64
): Unit {
    transaction.execute(
        "INSERT INTO app_run_event_heads(run_id,last_sequence) VALUES(" +
            sqliteText(runId.value) + "," + sequence.toString() + ") " +
            "ON CONFLICT(run_id) DO UPDATE SET last_sequence=excluded.last_sequence"
    )
    transaction.execute(
        "DELETE FROM app_run_events WHERE run_id=" + sqliteText(runId.value) +
            " AND event_class='telemetry' AND sequence NOT IN (SELECT sequence FROM " +
            "app_run_events WHERE run_id=" + sqliteText(runId.value) +
            " AND event_class='telemetry' ORDER BY sequence DESC LIMIT " +
            eventCapacity.toString() + ")"
    )
}

func runEventFieldText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func toolOutputChannelKey(value: ToolOutputChannel): String {
    match (value) {
        case ToolOutputChannel.Stdout => "stdout"
        case ToolOutputChannel.Stderr => "stderr"
        case ToolOutputChannel.Progress => "progress"
        case ToolOutputChannel.Artifact => "artifact"
        case ToolOutputChannel.Summary => "summary"
    }
}

func runEventDisposition(transaction: SqliteTransaction, event: AgentEvent): Int64 {
    if (transaction.query(
        "SELECT id FROM runs WHERE id=" + sqliteText(event.runId.value)
    ).size != 1) { return -1 }
    let exact = transaction.query(
        "SELECT payload FROM app_run_events WHERE run_id=" + sqliteText(event.runId.value) +
            " AND sequence=" + event.sequence.toString()
    )
    if (!exact.isEmpty()) {
        return if (exact.size == 1 && exact[0].required(0) == encodeEvent(event)) { 0 } else { -1 }
    }
    let rows = transaction.query(
        "SELECT COALESCE((SELECT last_sequence FROM app_run_event_heads WHERE run_id=" +
            sqliteText(event.runId.value) + "),0)"
    )
    let previous = try { Int64.parse(rows[0].required(0)) } catch (_: Exception) { return -1 }
    if (event.sequence == previous + 1) { 1 } else { -1 }
}

func runEventDispositionAfter(
    transaction: SqliteTransaction,
    event: AgentEvent,
    predecessorSequence: Int64
): Int64 {
    if (event.sequence != predecessorSequence + 1) { return -1 }
    let exact = transaction.query(
        "SELECT payload FROM app_run_events WHERE run_id=" + sqliteText(event.runId.value) +
            " AND sequence=" + event.sequence.toString()
    )
    if (!exact.isEmpty()) {
        return if (exact.size == 1 && exact[0].required(0) == encodeEvent(event)) { 0 } else { -1 }
    }
    let rows = transaction.query(
        "SELECT COALESCE((SELECT last_sequence FROM app_run_event_heads WHERE run_id=" +
            sqliteText(event.runId.value) + "),0)"
    )
    let previous = try { Int64.parse(rows[0].required(0)) } catch (_: Exception) { return -1 }
    if (predecessorSequence == previous + 1) { 1 } else { -1 }
}

func runEventConflict<T>(event: AgentEvent): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Conflict,
        "run.event_sequence_conflict",
        "Run event sequence or identity changed concurrently",
        fields: [
            ErrorField("run_id", event.runId.value),
            ErrorField("sequence", event.sequence.toString())
        ]
    ))
}

func sameOptionalRunContinuation(
    left: ?RunContinuation,
    right: ?RunContinuation
): Bool {
    match ((left, right)) {
        case (None, None) => true
        case (Some(a), Some(b)) => sameContinuationBinding(a, b)
        case _ => false
    }
}

func modelContinuationMatchesAttempt(
    continuation: RunContinuation,
    attempt: DurableModelAttempt
): Bool {
    if (continuation.kind != RunContinuationKind.RunningModel ||
        continuation.runId.value != attempt.runId.value || continuation.runningModel.isNone()) {
        return false
    }
    let checkpoint = continuation.runningModel.getOrThrow()
    checkpoint.semanticRequestId.value == attempt.semanticRequestId.value &&
        checkpoint.activeAttemptId.value == attempt.id.value &&
        checkpoint.semanticRequestDigest == attempt.semanticRequestDigest &&
        checkpoint.wirePolicyDigest == attempt.wirePolicyDigest
}

func modelAttemptSelect(): String {
    "SELECT id,semantic_request_id,run_id,COALESCE(parent_attempt_id,'')," +
        "attempt_no,lifecycle,policy,policy_reason,started_at_millis,last_activity_at_millis," +
        "COALESCE(completed_at_millis,-1),provider_request_id,provider_response_id,failure_kind," +
        "semantic_request_digest,wire_policy_digest,dispatch_state,replay_barrier," +
        "COALESCE(dispatch_started_at_millis,-1),COALESCE(provider_terminal_at_millis,-1)," +
        "transcript_snapshot " +
        "FROM model_attempts"
}

func readModelAttempt(
    transaction: SqliteTransaction,
    attemptId: ModelAttemptId
): Result<DurableModelAttempt> {
    let rows = transaction.query(modelAttemptSelect() + " WHERE id=" + sqliteText(attemptId.value))
    if (rows.size != 1) {
        return sqliteRunRecovery<DurableModelAttempt>(RunId("unknown"), "durable model Attempt is missing")
    }
    decodeModelAttemptRow(rows[0])
}

func decodeModelAttemptRow(row: SqliteRow): Result<DurableModelAttempt> {
    try {
        Result.Ok(DurableModelAttempt(
            ModelAttemptId(row.required(0)),
            SemanticModelRequestId(row.required(1)),
            RunId(row.required(2)),
            Int64.parse(row.required(4)),
            modelAttemptLifecycleFromName(row.required(5)),
            decodeStoredValue(row.required(6)),
            row.required(7),
            Int64.parse(row.required(8)),
            Int64.parse(row.required(9)),
            parentAttemptId: if (row.required(3) == "") { None } else {
                Some(ModelAttemptId(row.required(3)))
            },
            completedAtMillis: sqliteOptionalMillis(row.required(10)),
            providerRequestId: row.required(11),
            providerResponseId: row.required(12),
            failureKind: row.required(13),
            semanticRequestDigest: row.required(14),
            wirePolicyDigest: row.required(15),
            dispatchState: modelAttemptDispatchStateFromName(row.required(16)),
            replayBarrier: modelAttemptReplayBarrierFromName(row.required(17)),
            dispatchStartedAtMillis: sqliteOptionalMillis(row.required(18)),
            providerTerminalAtMillis: sqliteOptionalMillis(row.required(19)),
            transcriptSnapshot: row.required(20)
        ))
    } catch (error: Exception) {
        sqliteRunStorageError("persistence.sqlite_model_attempt_decode", error.message)
    }
}

func sqliteOptionalMillis(value: String): ?Int64 {
    let parsed = Int64.parse(value)
    if (parsed < 0) { None } else { Some(parsed) }
}

func modelAttemptLifecycleFromName(value: String): ModelAttemptLifecycle {
    match (value) {
        case "created" => ModelAttemptLifecycle.Created
        case "streaming" => ModelAttemptLifecycle.Streaming
        case "completed" => ModelAttemptLifecycle.Completed
        case "failed" => ModelAttemptLifecycle.Failed
        case "cancelled" => ModelAttemptLifecycle.Cancelled
        case "abandoned" => ModelAttemptLifecycle.Abandoned
        case _ => throw IllegalStateException("unknown model Attempt lifecycle")
    }
}

func modelAttemptDispatchStateFromName(value: String): ModelAttemptDispatchState {
    match (value) {
        case "prepared" => ModelAttemptDispatchState.Prepared
        case "dispatch_claimed" => ModelAttemptDispatchState.DispatchClaimed
        case _ => throw IllegalStateException("unknown model Attempt dispatch state")
    }
}

func modelAttemptReplayBarrierFromName(value: String): ModelAttemptReplayBarrier {
    match (value) {
        case "none" => ModelAttemptReplayBarrier.NoBarrier
        case "tool_evidence" => ModelAttemptReplayBarrier.ToolEvidence
        case "provider_terminal" => ModelAttemptReplayBarrier.ProviderTerminal
        case "cancelled" => ModelAttemptReplayBarrier.Cancelled
        case "run_deadline" => ModelAttemptReplayBarrier.RunDeadline
        case _ => throw IllegalStateException("unknown model Attempt replay barrier")
    }
}

func sameDurableAttempt(left: DurableModelAttempt, right: DurableModelAttempt): Bool {
    left.id.value == right.id.value &&
        left.semanticRequestId.value == right.semanticRequestId.value &&
        left.runId.value == right.runId.value && left.attemptNo == right.attemptNo &&
        left.lifecycle == right.lifecycle && left.providerRequestId == right.providerRequestId &&
        left.semanticRequestDigest == right.semanticRequestDigest &&
        left.wirePolicyDigest == right.wirePolicyDigest &&
        left.dispatchState == right.dispatchState && left.replayBarrier == right.replayBarrier &&
        encodeStoredValue(left.policy) == encodeStoredValue(right.policy)
}

func sqliteRunConflict<T>(message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, "run.sqlite_conflict", message))
}

// run_continuations is the only production continuation register. New writes
// carry a structured, digest-verified Run request snapshot in the sealed phase
// payload. The opaque v4 projection remains a read-only migration format.
// Current durable request equality, not a source grant. All properties below
// come from the real RunContinuation about to enter the original prepare path.
func requireBoundaryFreshModelRequest(data: AgentValue, value: RunContinuation): Unit {
    let request = contextBoundaryField(data, "request")
    let blocks = ArrayList<ModelBlock>()
    blocks.add(ModelBlock(ModelBlockKind.Text, text: value.prompt))
    for (image in value.imageInputs) { blocks.add(ModelBlock(ModelBlockKind.Image, image: Some(image))) }
    let model = modelRequestSnapshotValue(ModelRequest(value.model, [ModelMessage(ModelRole.User, blocks.toArray())],
        system: value.system, thinking: value.thinking, maxOutputTokens: value.budget.maxOutputTokens,
        streaming: true, parallelToolCalls: value.parallelToolCalls, serviceTier: value.serviceTier,
        cachePolicy: value.cachePolicy, structuredOutput: value.structuredOutput, cacheKey: value.cacheKey))
    if (contextBoundaryText(request, "run_id") != value.runId.value || contextBoundaryText(request, "thread_id") != value.sessionId.value ||
        contextBoundaryText(request, "lane_id") != value.executionLaneId.value ||
        canonicalAgentValue(contextBoundaryField(request, "model_input")) != canonicalAgentValue(model) ||
        canonicalAgentValue(contextBoundaryField(request, "tool_context")) != canonicalAgentValue(value.toolContextPayload) ||
        canonicalAgentValue(contextBoundaryField(request, "context_snapshot")) != canonicalAgentValue(value.contextSnapshotPayload) ||
        contextBoundaryText(request, "approval_mode") != value.approvalMode ||
        canonicalAgentValue(contextBoundaryField(request, "auto_retry")) != canonicalAgentValue(boolValue(value.autoRetry)) ||
        contextBoundaryInteger(request, "resolver_version") != Int64(value.resolverVersion) ||
        contextBoundaryInteger(request, "context_window") != value.contextWindow ||
        contextBoundaryInteger(request, "provider_margin") != value.providerSafetyMargin) {
        throw IllegalStateException("context boundary full request changed before fresh prepare") }
    let capabilities = listValue(value.capabilities.values.map { c => objectValue([ValueField("kind", textValue(capabilityDisplayName(c.kind))), ValueField("resource", textValue(c.resource))]) })
    if (canonicalAgentValue(contextBoundaryField(request, "capabilities")) != canonicalAgentValue(capabilities)) {
        throw IllegalStateException("context boundary capabilities changed") }
    let budget = contextBoundaryField(request, "budget")
    for (field in budgetValue(value.budget).fields) {
        if (canonicalAgentValue(field.value) != canonicalAgentValue(contextBoundaryField(budget, field.name))) {
            throw IllegalStateException("context boundary budget ceiling changed") } }
    let output = contextBoundaryField(budget, "request_output_budget")
    if (contextBoundaryInteger(budget, "max_concurrent_tools") != value.budget.maxConcurrentTools ||
        contextBoundaryInteger(output, "hard_limit") != value.budget.requestOutputBudget.hardLimit ||
        contextBoundaryInteger(output, "min_visible_response_tokens") != value.budget.requestOutputBudget.minVisibleResponseTokens) {
        throw IllegalStateException("context boundary concurrency or response reserve changed") }
    let policy = value.requestedPolicy.getOrThrow()
    let frozenPolicy = contextBoundaryField(request, "requested_policy")
    if (contextBoundaryText(frozenPolicy, "policy_requested_thinking") != thinkingName(policy.policyRequestedThinking) ||
        contextBoundaryText(frozenPolicy, "thinking_source") != thinkingPreferenceSourceName(policy.thinkingSource) ||
        canonicalAgentValue(contextBoundaryField(frozenPolicy, "user_requested_thinking")) != canonicalAgentValue(match (policy.userRequestedThinking) {
            case Some(level) => textValue(thinkingName(level)); case None => nullValue() }) ||
        contextBoundaryInteger(contextBoundaryField(frozenPolicy, "request_output_budget"), "hard_limit") != policy.requestOutputBudget.hardLimit ||
        contextBoundaryInteger(contextBoundaryField(frozenPolicy, "request_output_budget"), "min_visible_response_tokens") != policy.requestOutputBudget.minVisibleResponseTokens) {
        throw IllegalStateException("context boundary requested policy changed") }
    let caps = value.modelCapabilitiesSnapshot.getOrThrow()
    let frozenCaps = contextBoundaryField(request, "model_capabilities")
    let encodedCaps = modelCapabilitiesSnapshotValue(caps)
    if (contextBoundaryInteger(frozenCaps, "schema_version") != Int64(caps.snapshotSchemaVersion) ||
        contextBoundaryText(frozenCaps, "configuration_digest") != caps.configurationDigest) {
        throw IllegalStateException("context boundary capability version or configuration changed") }
    for (name in ["model_id", "model_max_output_tokens", "endpoint_max_output_tokens", "capability_fingerprint"]) {
        if (canonicalAgentValue(contextBoundaryField(frozenCaps, name)) != canonicalAgentValue(contextBoundaryField(encodedCaps, name))) {
            throw IllegalStateException("context boundary model capabilities changed") } }
    let frozenThinking = contextBoundaryField(frozenCaps, "thinking")
    if (contextBoundaryText(frozenThinking, "mode") != contextBoundaryText(encodedCaps, "thinking_mode")) {
        throw IllegalStateException("context boundary thinking mode changed") }
    for (name in ["supported_levels", "budget_tiers"]) {
        if (canonicalAgentValue(contextBoundaryField(frozenThinking, name)) != canonicalAgentValue(contextBoundaryField(encodedCaps, name))) {
            throw IllegalStateException("context boundary full thinking capabilities changed") } }
    let pricing = match (value.pricing) { case None => nullValue(); case Some(p) => objectValue([
        ValueField("input", optionalIntegerValue(p.inputMicrosPerMillion)), ValueField("output", optionalIntegerValue(p.outputMicrosPerMillion)),
        ValueField("cache_read", optionalIntegerValue(p.cacheReadMicrosPerMillion)), ValueField("cache_write", optionalIntegerValue(p.cacheWriteMicrosPerMillion))]) }
    if (canonicalAgentValue(contextBoundaryField(request, "pricing")) != canonicalAgentValue(pricing)) {
        throw IllegalStateException("context boundary pricing changed") }
}

func canonicalContinuationFromRow(
    row: SqliteRow,
    runId: RunId,
    durableIndex: Int64
): Result<?RunContinuation> {
    match (row[durableIndex]) {
        case Some(source) =>
            let durable = try { decodeDurableRunContinuation(source) }
            catch (error: Exception) {
                return sqliteRunRecovery<?RunContinuation>(
                    runId, "canonical continuation is corrupt: " + error.message
                )
            }
            if (durable.runId.value != runId.value) {
                return sqliteRunRecovery<?RunContinuation>(
                    runId, "canonical continuation Run binding is corrupt"
                )
            }
            // Settled model checkpoints retain request data for diagnosis and
            // canonical context compilation, not permission to replay the old
            // RunningModel projection. Only its actual effect phase owns it.
            match (durable.phase) {
                case RunExecutionPhase.Checkpoint(_) | RunExecutionPhase.ContextCompiling(_) |
                    RunExecutionPhase.ContextReady(_) => if (durable.attemptId.isNone() &&
                        durable.pendingOperationId.isNone() && durable.pendingApprovalId.isNone()) {
                        return Result.Ok(None)
                    }
                case _ => ()
            }
            match (optionalRunRequestSnapshotFromDurableContinuation(durable)) {
                case Some(snapshot) =>
                    if (isInitialContextRequest(snapshot)) {
                        if (httpIntentText(snapshot, "run_id") != durable.runId.value) {
                            return sqliteRunRecovery<?RunContinuation>(runId, "initial request Run binding is corrupt") }
                        return Result.Ok(None)
                    }
                    match (decodeContinuation(encodeAgentValue(snapshot))) {
                    case Result.Ok(value) => if (value.runId.value == runId.value) {
                        Result.Ok(Some(value))
                    } else {
                        sqliteRunRecovery<?RunContinuation>(
                            runId, "canonical request snapshot Run binding is corrupt"
                        )
                    }
                    case Result.Err(error) => return sqliteRunRecovery<?RunContinuation>(
                        runId, "canonical request snapshot is corrupt: " + error.message
                    )
                    }
                case None => match (optionalLegacyPayloadFromDurableContinuation(durable)) {
                    case Some(payload) => match (decodeContinuation(payload)) {
                        case Result.Ok(value) => if (value.runId.value == runId.value) {
                            Result.Ok(Some(value))
                        } else {
                            sqliteRunRecovery<?RunContinuation>(
                                runId, "legacy projection Run binding is corrupt"
                            )
                        }
                        case Result.Err(error) => sqliteRunRecovery<?RunContinuation>(
                            runId, "legacy projection is corrupt: " + error.message
                        )
                    }
                    case None => Result.Ok(None)
                }
            }
        case None => Result.Ok(None)
    }
}

func runContinuationSnapshotValue(value: RunContinuation): AgentValue {
    continuationValue(value, approvalRequestValue(value.approval))
}

func saveSqliteDecision(
    transaction: SqliteTransaction,
    receipt: ApprovalDecisionReceipt
): Result<Unit> {
    // This check shares the decision transaction with Attempt preparation.
    // A concurrent UI approval cannot consume the original wait while its
    // reviewer owns an unsettled effect, even before resumeAfterApproval.
    if (!transaction.query("SELECT id FROM model_attempts WHERE run_id=? AND lifecycle IN ('created','streaming') " +
        "AND policy_reason IN ('internal_approval_review','internal_context_compaction')",
        [SqlParameter.Text(receipt.runId.value)]).isEmpty()) {
        return operationConflict<Unit>("approval has an unsettled internal model Attempt")
    }
    let existing = transaction.query(
        "SELECT payload FROM approval_decisions WHERE operation_id=" + sqliteText(receipt.operationId.value)
    )
    if (existing.size == 1) {
        return match (decodeDecisionReceipt(existing[0].required(0))) {
            case Result.Ok(value) => if (sameDecisionReceipt(value, receipt)) {
                Result.Ok(())
            } else {
                operationConflict<Unit>("approval decision receipt cannot be changed")
            }
            case Result.Err(_) => sqliteRunRecovery<Unit>(receipt.runId, "durable approval decision receipt is corrupt")
        }
    }
    transaction.execute(
        "INSERT INTO approval_decisions(operation_id,run_id,payload,created_at_millis) VALUES(" +
            sqliteText(receipt.operationId.value) + "," + sqliteText(receipt.runId.value) + "," +
            sqliteText(encodeDecisionReceipt(receipt)) + "," + agentUtcMillis().toString() + ")"
    )
    Result.Ok(())
}

func sqliteRunMissing<T>(runId: RunId, message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "persistence.not_found",
        message,
        fields: [ErrorField("run_id", runId.value)]
    ))
}

func sqliteRunRecovery<T>(runId: RunId, message: String): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.RecoveryRequired,
        "run.sqlite_recovery_required",
        message,
        fields: [ErrorField("run_id", runId.value)]
    ))
}

func sqliteRunStorageError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Internal, code, message))
}
