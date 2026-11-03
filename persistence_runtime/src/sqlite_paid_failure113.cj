package persistence_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.convert.*

// A successful port returns only after its generated Snapshot/Event, encoder,
// parameter/SQLite frames have actually returned. The public adapter then ACKs
// its distinct publication. Failure leaves that exact consumer paid for Core
// to consume; neither an Err nor a SQL return is itself an alias-retirement ACK.
func failurePersistencePeak113(error: AgentError, metadata: Int64, occurrences: Int64): Int64 {
    let text = ownedOuterErrorAdd333(ownedOuterErrorScalarBytes333(error), metadata)
    var peak = ownedOuterErrorAdd333(262144, ownedOuterErrorMultiply333(text, occurrences))
    peak = ownedOuterErrorAdd333(peak, ownedOuterErrorMultiply333(error.fields.size, 8192))
    if (error.attemptFailure.isSome()) { peak = ownedOuterErrorAdd333(peak, 65536) }
    if (error.observation.isSome()) {
        // The original immutable encoded observation stays in the paid
        // error root. Invoice its ACTUAL bytes, the independent UTF8 slices,
        // wrapper, final String and SQL parameter copies; never decode a DOM.
        let bytes = error.observation.getOrThrow().frozenEncodedByteSize113()
        peak = ownedOuterErrorAdd333(peak, ownedOuterErrorAdd333(8192,
            ownedOuterErrorMultiply333(bytes, occurrences))) }
    peak
}
func saveSqlitePaidFailureBody113(database: SqliteDatabase, snapshot: RunSnapshot,
    fund: (Int64) -> Result<Unit>): Result<Unit> {
    let error = snapshot.error.getOrThrow()
    // Summary repeats the full error.message in the original snapshot.
    let metadata = ownedOuterErrorAdd333(snapshot.summary.size,
        ownedOuterErrorAdd333(snapshot.runId.value.size, snapshot.sessionId.value.size))
    match (fund(failurePersistencePeak113(error, metadata, 48))) {
        case Result.Err(failure) => return Result<Unit>.Err(failure); case Result.Ok(_) => () }
    try {
        database.transaction<Result<Unit>> { tx: SqliteTransaction =>
            let lengths = tx.query("SELECT length(CAST(thread_id AS BLOB)) FROM runs WHERE id=? LIMIT 2",
                [SqlParameter.Text(snapshot.runId.value)])
            if (lengths.size != 1) { return sqliteRunMissing<Unit>(snapshot.runId, "canonical Run row is missing") }
            let bytes = Int64.parse(lengths[0].required(0))
            if (bytes < 0) { return sqliteRunRecovery<Unit>(snapshot.runId, "Run Thread identity length is invalid") }
            // This is an increment in the same actual consumer's SUM, not
            // a repeat of the complete encoder invoice or a new pool.
            match (fund(ownedOuterErrorMultiply333(bytes, 8))) {
                case Result.Err(failure) => return Result<Unit>.Err(failure); case Result.Ok(_) => () }
            let rows = tx.query("SELECT thread_id FROM runs WHERE id=? LIMIT 2", [SqlParameter.Text(snapshot.runId.value)])
            if (rows.size != 1 || rows[0].required(0).size != bytes || rows[0].required(0) != snapshot.sessionId.value) {
                return sqliteRunRecovery<Unit>(snapshot.runId, "Run session binding does not match its Thread") }
            let encoded=match(encodeFailureSnapshot113(snapshot,fund)){
                case Result.Ok(value)=>value;case Result.Err(failure)=>return Result<Unit>.Err(failure)}
            tx.execute("UPDATE runs SET app_snapshot=? WHERE id=?",
                [SqlParameter.Text(encoded), SqlParameter.Text(snapshot.runId.value)])
            Result<Unit>.Ok(())
        }
    } catch (failure: Exception) {
        // Preserve a complete actual storage failure under this still-live
        // input consumer. The caller must capture it before ACKing this
        // publication; a failed port never performs that ACK itself.
        match (fund(ownedOuterErrorAdd333(8192, ownedOuterErrorMultiply333(failure.message.size, 8)))) {
            case Result.Err(error) => Result<Unit>.Err(error)
            case Result.Ok(_) => Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "persistence.sqlite_run_save", String.fromUtf8(failure.message.toArray()))) }
    }
}
func appendSqlitePaidFailureBody113(database: SqliteDatabase, capacity: Int64, event: AgentEvent,
    fund: (Int64) -> Result<Unit>): Result<Unit> {
    let error = match (event.payload) { case AgentEventPayload.Diagnostic(actual) => actual
        case _ => return Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired, "data.failure_diagnostic_changed", "typed failure requires its original complete Diagnostic")) }
    match (fund(failurePersistencePeak113(error, ownedOuterErrorEventMetadataBytes333(event.meta), 48))) {
        case Result.Err(failure) => return Result<Unit>.Err(failure); case Result.Ok(_) => () }
    try {
        database.transaction<Result<Unit>> { tx: SqliteTransaction =>
            // Preserve actual canonical Run presence and original ordered
            // event head. Diagnostic is lifecycle, never telemetry merge.
            if (tx.query("SELECT id FROM runs WHERE id=? LIMIT 2", [SqlParameter.Text(event.runId.value)]).size != 1) {
                return runEventConflict<Unit>(event) }
            let prior = tx.query("SELECT length(CAST(payload AS BLOB)) FROM app_run_events " +
                "WHERE run_id=? AND sequence=? LIMIT 2", [SqlParameter.Text(event.runId.value), SqlParameter.Int64Value(event.sequence)])
            // Original append disallows an existing event, even an equal
            // duplicate. No replay or second Diagnostic is synthesized.
            if (!prior.isEmpty()) { return runEventConflict<Unit>(event) }
            let head = tx.query("SELECT COALESCE((SELECT last_sequence FROM app_run_event_heads WHERE run_id=?),0)",
                [SqlParameter.Text(event.runId.value)])
            if (head.size != 1 || event.sequence != Int64.parse(head[0].required(0)) + 1) {
                return runEventConflict<Unit>(event) }
            let encoded=match(encodeFailureEvent113(event,fund)){
                case Result.Ok(value)=>value;case Result.Err(failure)=>return Result<Unit>.Err(failure)}
            tx.execute("INSERT INTO app_run_events(run_id,sequence,sequence_start,sequence_end,payload," +
                "accounting,event_class,stream_key,delta_count,char_count,created_at_millis) " +
                "VALUES(?,?,?,?,?,0,'lifecycle','',1,0,?)", [SqlParameter.Text(event.runId.value),
                    SqlParameter.Int64Value(event.sequence), SqlParameter.Int64Value(event.sequence),
                    SqlParameter.Int64Value(event.sequence), SqlParameter.Text(encoded),
                    SqlParameter.Int64Value(agentUtcMillis())])
            updateRunEventHeadAndPrune(tx, event.runId, event.sequence, capacity)
            Result<Unit>.Ok(())
        }
    } catch (failure: Exception) {
        match (fund(ownedOuterErrorAdd333(8192, ownedOuterErrorMultiply333(failure.message.size, 8)))) {
            case Result.Err(error) => Result<Unit>.Err(error)
            case Result.Ok(_) => Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "persistence.sqlite_run_event", String.fromUtf8(failure.message.toArray()))) }
    }
}
func saveSqlitePaidFailure113(database: SqliteDatabase, value: OwnedFailureRunPublication113): Result<Unit> {
    value.withSnapshot({ snapshot,fund => saveSqlitePaidFailureBody113(database,snapshot,fund) })
}
func appendSqlitePaidFailure113(database: SqliteDatabase, capacity: Int64,
    value: OwnedFailureRunPublication113): Result<Unit> {
    value.withDiagnostic({ event,fund => appendSqlitePaidFailureBody113(database,capacity,event,fund) })
}

class FailurePersistenceOutcome113 {
    var value: ?OwnedFailureDataOutcome113<Unit> = None<OwnedFailureDataOutcome113<Unit>>
    func take(): OwnedFailureDataOutcome113<Unit> {
        let actual=value.getOrThrow();value=None<OwnedFailureDataOutcome113<Unit>>;actual
    }
}
// This raw Result frame finishes BEFORE the port can ACK the original input.
// A failed complete String/error is captured under a genuinely derived lease
// while the original publication's full Snapshot/Diagnostic loan is live.
func captureFailurePersistenceAnswer113(value: OwnedFailureRunPublication113,
    result: Result<Unit>): OwnedFailureDataOutcome113<Unit> {
    match(result){case Result.Ok(_)=>OwnedFailureDataOutcome113<Unit>.Value(())
        case Result.Err(error)=>value.captureFailure113<Unit>(error)}
}
func saveSqlitePaidFailureOutcome113(database: SqliteDatabase,
    value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
    match (value.withError({ _, fund => fund(4096) })) {
        case Result.Err(error) => return value.captureFailure113<Unit>(error)
        case Result.Ok(_) => () }
    let outcome=FailurePersistenceOutcome113()
    let loan=value.withSnapshot({ snapshot,fund =>
        outcome.value=Some(captureFailurePersistenceAnswer113(value,
            saveSqlitePaidFailureBody113(database,snapshot,fund)))
        Result<Unit>.Ok(())
    })
    match(loan){case Result.Err(error)=>value.captureFailure113<Unit>(error)
        case Result.Ok(_)=>outcome.take()}
}
func appendSqlitePaidFailureOutcome113(database: SqliteDatabase, capacity: Int64,
    value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
    match (value.withError({ _, fund => fund(4096) })) {
        case Result.Err(error) => return value.captureFailure113<Unit>(error)
        case Result.Ok(_) => () }
    let outcome=FailurePersistenceOutcome113()
    let loan=value.withDiagnostic({ event,fund =>
        outcome.value=Some(captureFailurePersistenceAnswer113(value,
            appendSqlitePaidFailureBody113(database,capacity,event,fund)))
        Result<Unit>.Ok(())
    })
    match(loan){case Result.Err(error)=>value.captureFailure113<Unit>(error)
        case Result.Ok(_)=>outcome.take()}
}

// All raw producer/SQL/Result frames above have now returned. The secondary
// Failure owns a distinct same-bank clone; refunding the input share cannot
// retire it. Pressure/throw during capture never reaches this ACK point.
func acknowledgePaidFailurePort113(value: OwnedFailureRunPublication113,
    outcome: OwnedFailureDataOutcome113<Unit>): OwnedFailureDataOutcome113<Unit> {
    let ack=value.acknowledgeAfterConsumption()
    match(ack){case Result.Ok(_)=>outcome
        case Result.Err(error)=>match(outcome){
            case OwnedFailureDataOutcome113.Value(_)=>value.captureFailure113<Unit>(error)
            // Keep the first real secondary failure; Core also retains/checks
            // this unacknowledged input and cannot call the IO step complete.
            case OwnedFailureDataOutcome113.Failure(_)=>outcome}}
}
