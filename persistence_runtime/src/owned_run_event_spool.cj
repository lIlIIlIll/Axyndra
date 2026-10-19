package persistence_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.convert.*
import std.sync.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

foreign func axyndra_run_event_spool_open(root: CString, owned: CPointer<Int32>): Int32
foreign func axyndra_run_event_spool_write(fd: Int32, offset: Int64, raw: CPointer<Byte>, length: Int64): Int32
foreign func axyndra_run_event_spool_freeze(fd: Int32, bytes: Int64): Int32
foreign func axyndra_run_event_spool_read(fd: Int32, bytes: Int64, offset: Int64, raw: CPointer<Byte>, capacity: Int64): Int64
foreign func axyndra_run_event_spool_close(fd: Int32): Int32

// Concrete retained IO, not a logical execution/Known witness. The private
// retirement witness only attests that the old complete item aliases retired.
// SQL admission/order still comes from the actual original Run transaction.
class OwnedSqliteRunEventWrite <: OwnedRunEventWrite {
    private let lock = Mutex()
    private let database: SqliteDatabase
    private let capacity: Int64
    private let retirement: OwnedCanonicalThreadItemRetirementWitness
    private var payment: ?LogicalJsonOwnerReservation
    private var event: ?OwnedAgentEvent
    private var runId: ?RunId = None
    private var sequence: Int64 = 0
    private var fd: Int32 = -1
    private var bytes: Int64 = 0
    private var digest = ""
    private let hash = SHA256()
    private var staged = false
    private var appended = false
    private var acknowledged = false

    init(database: SqliteDatabase, capacity: Int64, event: OwnedAgentEvent,
        payment: LogicalJsonOwnerReservation, retirement: OwnedCanonicalThreadItemRetirementWitness) {
        this.database = database; this.capacity = capacity; this.event = Some(event)
        this.payment = Some(payment); this.retirement = retirement
    }

    func stage(root: String): Result<Unit> {
        lock.lock()
        try {
            if (acknowledged || staged || fd >= 0) { return ownedRunEventDataError("event.spool_stage_closed") }
            // The real derived allocation pays native path/control storage and
            // fixed chunks before the anonymous descriptor or buffers exist.
            payment.getOrThrow().ensureRetainedPeak(262144 + root.size * 4)
            let opened = unsafe {
                let path = LibC.mallocCString(root)
                try {
                    let output = LibC.malloc<Int32>()
                    try {
                        if (output.isNull()) { throw IllegalStateException("event spool descriptor allocation failed") }
                        output.write(-1)
                        let result = axyndra_run_event_spool_open(path, output)
                        fd = output.read(); result
                    } finally { LibC.free(output) }
                } finally { LibC.free(path) }
            }
            if (opened < 0) { return ownedRunEventDataError("event.spool_open_failed") }
            if (fd < 0) { return ownedRunEventDataError("event.spool_open_failed") }
            match (event.getOrThrow().withEvent(262144, { actual =>
                if (runEventTelemetry(actual).isSome() || actual.kind != AgentEventKind.Tool) {
                    return ownedRunEventDataError<Unit>("event.spool_non_lifecycle") }
                // Metadata and JSON envelope are measured before a retained
                // projection is created. Output is borrowed, never copied here.
                let metadata = actual.runId.value.size + actual.meta.traceId.value.size +
                    eventOptionalIdBytes(actual.meta)
                payment.getOrThrow().ensureRetainedPeak(262144 + metadata * 4 + root.size * 4)
                runId = Some(actual.runId); sequence = actual.sequence
                writeOwnedAgentValue(ownedRunEventValue(actual), { chunk => writeChunk(chunk) }, { => stageCurrent() })
            })) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => () }
            if (unsafe { axyndra_run_event_spool_freeze(fd, bytes) } != 0) {
                return ownedRunEventDataError("event.spool_freeze_failed") }
            digest = logicalJsonEncodeHex(hash.finish())
            // withEvent and every envelope/stream callback frame have ended.
            // This real alias has no retained result/event DOM reference.
            match (event.getOrThrow().closeAfterEventRetirement()) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(_) => event = None }
            staged = true; Result.Ok(())
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_owned_event_stage", error.message)
        } finally { lock.unlock() }
    }

    private func stageCurrent(): Result<Unit> {
        if (fd < 0 || acknowledged || staged) { return ownedRunEventDataError("event.spool_stage_closed") }
        Result.Ok(())
    }
    private func writeChunk(value: String): Result<Unit> {
        if (value.size < 1 || value.size > 16384 || value.size > 67108864 - bytes) {
            return ownedRunEventDataError("event.spool_extent_invalid") }
        var raw: ?Array<Byte> = Some(value.toArray())
        try {
            let result = unsafe {
                let held = acquireArrayRawData(raw.getOrThrow())
                try { axyndra_run_event_spool_write(fd, bytes, held.pointer, value.size) }
                finally { releaseArrayRawData(held) }
            }
            if (result != 0) { return ownedRunEventDataError("event.spool_write_failed") }
            hash.write(raw.getOrThrow()); bytes += value.size; Result.Ok(())
        } finally { raw = None }
    }

    public func appendAfterSourceAliasRetirement(): Result<Unit> {
        lock.lock()
        var sqlPayment: ?LogicalJsonOwnerReservation = None
        try {
            if (!staged || acknowledged || fd < 0 || runId.isNone()) {
                return ownedRunEventDataError("event.spool_append_closed") }
            if (appended) { return Result.Ok(()) }
            if (!retirement.isItemRetired()) { return ownedRunEventDataError("event.spool_source_alias_pending") }
            // Pay the real full SQLite input+record buffers before the FIRST
            // mutation. This is a child of the SAME original row ledger.
            sqlPayment = Some(payment.getOrThrow().deriveRetainedLease())
            sqlPayment.getOrThrow().ensureRetainedPeak(bytes * 2 + 4194304)
            let sql = OwnedRunEventSqlPayment(sqlPayment.getOrThrow())
            let result = database.transaction<Result<Unit>>({ tx =>
                match (ownedRunEventDisposition(tx, runId.getOrThrow(), sequence)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => () }
                tx.execute("INSERT INTO app_run_events(run_id,sequence,sequence_start,sequence_end,payload," +
                    "accounting,event_class,stream_key,delta_count,char_count,created_at_millis) VALUES(?,?,?,?,?,0,'lifecycle','',1,0,?)",
                    [SqlParameter.Text(runId.getOrThrow().value), SqlParameter.Int64Value(sequence),
                        SqlParameter.Int64Value(sequence), SqlParameter.Int64Value(sequence),
                        SqlParameter.Text(""), SqlParameter.Int64Value(agentUtcMillis())])
                let rows = tx.query("SELECT rowid FROM app_run_events WHERE run_id=? AND sequence=?",
                    [SqlParameter.Text(runId.getOrThrow().value), SqlParameter.Int64Value(sequence)])
                if (rows.size != 1) { throw IllegalStateException("actual inserted Run event row is absent") }
                tx.writeFixedRunEventText(Int64.parse(rows[0].required(0)), bytes, digest,
                    { => appendCurrent() }, { _ => sql.take() }, { consume => produce(consume) })
                updateRunEventHeadAndPrune(tx, runId.getOrThrow(), sequence, capacity)
                Result<Unit>.Ok(())
            })
            match (result) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => appended = true; Result.Ok(()) }
        } catch (error: Exception) {
            sqliteRunStorageError("persistence.sqlite_owned_event_append", error.message)
        } finally {
            // Actual synchronous TX and every native statement/blob frame have
            // ended. Failure remains semantic debt; no Known is manufactured.
            match (sqlPayment) { case Some(value) => value.close(); case None => () }
            sqlPayment = None; lock.unlock()
        }
    }

    private func appendCurrent(): Result<Unit> {
        if (fd < 0 || acknowledged || !staged || !retirement.isItemRetired()) {
            return ownedRunEventDataError("event.spool_source_alias_pending") }
        Result.Ok(())
    }
    private func produce(consume: (Int64, Array<Byte>) -> Unit): Unit {
        let buffer = Array<Byte>(16384, repeat: 0)
        var offset: Int64 = 0
        while (true) {
            match (appendCurrent()) { case Result.Err(error) => throw OwnedRunEventIoFailure(error); case Result.Ok(_) => () }
            let count = unsafe {
                let raw = acquireArrayRawData(buffer)
                try { axyndra_run_event_spool_read(fd, bytes, offset, raw.pointer, buffer.size) }
                finally { releaseArrayRawData(raw) }
            }
            if (count < 0 || count > buffer.size || count > bytes - offset) {
                throw IllegalStateException("complete original event spool read failed") }
            if (count == 0) {
                if (offset != bytes) { throw IllegalStateException("complete original event spool EOF differs") }
                break
            }
            consume(offset, buffer[..count]); offset += count
        }
        // Complete EOF/hash/UTF8 and blob close are checked by the actual
        // database writer before it returns to this same transaction.
    }

    public func closeAfterStorageRetirement(): Result<Unit> {
        lock.lock()
        try {
            if (acknowledged) { return Result.Ok(()) }
            if (fd >= 0) {
                let result = unsafe { axyndra_run_event_spool_close(fd) }
                if (result < 0) {
                    return ownedRunEventDataError("event.spool_cleanup_pending") }
                fd = -1
                if (result > 0) {
                    // The original Linux descriptor has physically retired.
                    // Report its actual close error and retain this allocation
                    // until the owning caller explicitly retries retirement.
                    return ownedRunEventDataError("event.spool_close_failed") }
            }
            match (event) {
                case Some(actual) => match (actual.closeAfterEventRetirement()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => event = None }
                case None => () }
            runId = None; digest = ""
            payment.getOrThrow().close(); payment = None; acknowledged = true
            Result.Ok(())
        } finally { lock.unlock() }
    }
    public func isAcknowledged(): Bool { lock.lock(); try { acknowledged } finally { lock.unlock() } }
}

// One actual pre-paid child is consumed exactly once by the fixed writer.
// No allocate shim, new pool, Root or Source is introduced.
private class OwnedRunEventSqlPayment {
    private var payment: ?LogicalJsonOwnerReservation
    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }
    func take(): LogicalJsonOwnerReservation {
        let actual = payment.getOrThrow(); payment = None; actual
    }
}
private class OwnedRunEventIoFailure <: Exception {
    let error: AgentError
    init(error: AgentError) { super(error.message); this.error = error }
}

private func eventOptionalIdBytes(meta: EventMeta): Int64 {
    var bytes: Int64 = 0
    match (meta.turnId) { case Some(value) => bytes += value.value.size; case None => () }
    match (meta.requestId) { case Some(value) => bytes += value.value.size; case None => () }
    match (meta.toolBatchId) { case Some(value) => bytes += value.value.size; case None => () }
    match (meta.toolCallId) { case Some(value) => bytes += value.value.size; case None => () }
    match (meta.operationId) { case Some(value) => bytes += value.value.size; case None => () }
    bytes
}

private func ownedRunEventValue(event: AgentEvent): AgentValue {
    objectValue([
        ValueField("format_version", integerValue(RUN_EVENT_FORMAT_VERSION)),
        ValueField("sequence", integerValue(event.sequence)),
        ValueField("run_id", textValue(event.runId.value)),
        ValueField("kind", textValue(eventKindName(event.kind))),
        ValueField("timestamp_ms", integerValue(event.meta.occurredAtMillis)),
        ValueField("trace_id", textValue(event.meta.traceId.value)),
        ValueField("turn_id", eventOptionalTurnIdValue(event.meta.turnId)),
        ValueField("request_id", eventOptionalRequestIdValue(event.meta.requestId)),
        ValueField("tool_batch_id", eventOptionalToolBatchIdValue(event.meta.toolBatchId)),
        ValueField("tool_call_id", eventOptionalToolCallIdValue(event.meta.toolCallId)),
        ValueField("operation_id", eventOptionalOperationIdValue(event.meta.operationId)),
        ValueField("payload_type", textValue(eventPayloadName(event.payload))),
        ValueField("detail", event.detail)])
}

private func ownedRunEventDisposition(tx: SqliteTransaction, run: RunId, sequence: Int64): Result<Unit> {
    if (sequence < 1 || tx.query("SELECT id FROM runs WHERE id=?", [SqlParameter.Text(run.value)]).size != 1 ||
        !tx.query("SELECT 1 FROM app_run_events WHERE run_id=? AND sequence=?",
            [SqlParameter.Text(run.value), SqlParameter.Int64Value(sequence)]).isEmpty()) {
        return ownedRunEventConflict<Unit>(run, sequence) }
    let rows = tx.query("SELECT COALESCE((SELECT last_sequence FROM app_run_event_heads WHERE run_id=?),0)",
        [SqlParameter.Text(run.value)])
    let previous = Int64.parse(rows[0].required(0))
    if (previous == Int64.Max || sequence != previous + 1) { return ownedRunEventConflict<Unit>(run, sequence) }
    Result.Ok(())
}
private func ownedRunEventConflict<T>(run: RunId, sequence: Int64): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, "run.event_sequence_conflict",
        "Run event sequence or identity changed concurrently",
        fields: [ErrorField("run_id", run.value), ErrorField("sequence", sequence.toString())]))
}

// Same data-retirement error, local to the concrete IO package. Runtime's
// package-internal helper is not an exported capability or imported here.
func ownedRunEventDataError<T>(code: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, code,
        "canonical data still requires its actual paid owner and alias retirement",
        retryable: false, fallbackAllowed: false))
}
