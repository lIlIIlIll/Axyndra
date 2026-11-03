package persistence_runtime

import agent_domain.*
import agent_store.*
import std.sync.*
import std.convert.*
import yjson.*
import yjson_support.*

private let catalogPersistenceCopies204 = CatalogPersistenceCopies204()

// A registered receiving copy, not an acknowledgement of a caller's Catalog,
// Prepared operation, permission decision, event or Source. Only independent
// copied DATA belongs to this phase; original public methods remain unchanged.
class CatalogPersistenceCopy204 {
    private var payment: ?LogicalJsonOwnerReservation
    private var bytes: ?Array<UInt8> = None<Array<UInt8>>
    private var text: ?String = None<String>
    private var decoded: ?AgentValue = None<AgentValue>
    private var encoded: ?String = None<String>
    private var grantScope: ?ApprovalGrantScope = None<ApprovalGrantScope>
    private var storedRows: ?Array<SqliteRow> = None<Array<SqliteRow>>
    private var storedValue: ?AgentValue = None<AgentValue>
    private var sessionPeak: Int64 = 0
    private var failure: ?AgentError = None<AgentError>
    private var exception: ?Exception = None<Exception>
    private var copyPeak: Int64 = 131072
    private var cleared = false
    var next204: ?CatalogPersistenceCopy204 = None<CatalogPersistenceCopy204>
    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }

    private func copyFrame204(value: PreparedPlanUtf8Owner204): Unit {
        let size = value.byteCount
        if (size < 0 || size > 8388608) { throw IllegalStateException("stored value exceeds 8 MiB") }
        payment.getOrThrow().ensureRetainedPeak(131072 + size * 4)
        let buffer = Array<UInt8>(size, { _ => UInt8(0) })
        bytes = Some(buffer)
        for (index in 0..size) { buffer[index] = value.byteAt(index) }
        if (value.byteCount != size) { throw IllegalStateException("copied DATA byte count changed") }
        // The existing scalar scanner pays every copied text byte at64 and
        // each node at2048 before decoder/JSON/SQL/CString allocations exist.
        copyPeak = preparedFramedValueCopyPeak204(buffer)
        payment.getOrThrow().ensureRetainedPeak(copyPeak)
        text = Some(String.fromUtf8(buffer))
        decoded = Some(decodeStoredValue(text.getOrThrow()))
    }
    private func fundSession204(sessionId: SessionId): Unit {
        let size = sessionId.value.size
        if (size < 0 || size > (Int64.Max - copyPeak) / 64) {
            throw LogicalJsonPayloadError("permission DATA copy invoice overflow") }
        sessionPeak = size * 64
        payment.getOrThrow().ensureRetainedPeak(copyPeak + sessionPeak)
    }
    private func decodeGrantFrame204(): Unit {
        let value = decoded.getOrThrow()
        if (value.unifiedKind != ValueKind.Object || value.fields.size != 5) {
            throw IllegalStateException("complete permission DATA fields are invalid") }
        for (name in ["capability", "path_prefix", "tool_name", "host"]) {
            if (value.field(name).getOrThrow().unifiedKind != ValueKind.Text) {
                throw IllegalStateException("permission DATA text is invalid") }
        }
        let sessionOnly = value.field("session_only").getOrThrow()
        if (sessionOnly.unifiedKind != ValueKind.Boolean) {
            throw IllegalStateException("permission DATA session flag is invalid") }
        grantScope = Some(ApprovalGrantScope(value.field("capability").getOrThrow().text,
            pathPrefix: value.field("path_prefix").getOrThrow().text,
            toolName: value.field("tool_name").getOrThrow().text,
            host: value.field("host").getOrThrow().text, sessionOnly: sessionOnly.asBool()))
    }
    func allowsFrame204(database: SqliteDatabase, sessionId: SessionId,
        value: PreparedPlanUtf8Owner204): Result<Bool> {
        try {
            copyFrame204(value); fundSession204(sessionId); decodeGrantFrame204()
            // Only the original Bool or error leaves this concrete read TX.
            // All rows are measured in its same SQLite snapshot before copying.
            database.readTransaction<Result<Bool>>({ transaction =>
                allowsTransactionFrame204(transaction, sessionId) })
        } catch (error: Exception) {
            exception = Some(error)
            sqliteToolError("persistence.sqlite_permission_read", error.message)
        }
    }
    private func allowsTransactionFrame204(transaction: SqliteTransaction, sessionId: SessionId): Result<Bool> {
        let suffix = " FROM session_permission_grants WHERE thread_id=" + sqliteText(sessionId.value)
        let sizes = transaction.query("SELECT COUNT(*),COALESCE(SUM(length(CAST(payload AS BLOB))),0)" + suffix)
        if (sizes.size != 1) { throw IllegalStateException("permission stored DATA measurement is invalid") }
        let count = Int64.parse(sizes[0].required(0)); let size = Int64.parse(sizes[0].required(1))
        let rawPeak = catalogPersistenceAdd204(catalogPersistenceMultiply204(count, 1024),
            catalogPersistenceMultiply204(size, 4))
        var peak = catalogPersistenceAdd204(catalogPersistenceAdd204(copyPeak, sessionPeak), rawPeak)
        payment.getOrThrow().ensureRetainedPeak(peak)
        storedRows = Some(transaction.query(
            "SELECT payload FROM session_permission_grants WHERE thread_id=" + sqliteText(sessionId.value)))
        let rows = storedRows.getOrThrow()
        if (rows.size != count) { throw IllegalStateException("permission stored DATA count changed") }
        var actual: Int64 = 0
        for (row in rows) {
            let payload = row.required(0)
            actual = catalogPersistenceAdd204(actual, payload.size)
            peak = catalogPersistenceAdd204(peak, catalogPersistenceJsonCopyPeak204(payload))
        }
        if (actual != size) { throw IllegalStateException("permission stored DATA extent changed") }
        payment.getOrThrow().ensureRetainedPeak(peak)
        // Original payload order, 64 MiB decoder and stored matching remain.
        for (row in rows) {
            let value = match (decodeAgentValue(row.required(0), maxBytes: 67108864)) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            storedValue = Some(value)
            if (storedApprovalGrantAllows(value, grantScope.getOrThrow())) { return Result.Ok(true) }
        }
        Result.Ok(false)
    }
    private func readAuditThreadFrame204(database: SqliteDatabase, run: String): Unit {
        database.readTransaction<Unit>({ transaction =>
            let suffix = " FROM runs WHERE id=" + sqliteText(run)
            let sizes = transaction.query("SELECT COUNT(*),COALESCE(SUM(length(CAST(thread_id AS BLOB))),0)" + suffix)
            if (sizes.size != 1) { throw IllegalStateException("Audit stored thread measurement is invalid") }
            let count = Int64.parse(sizes[0].required(0)); let size = Int64.parse(sizes[0].required(1))
            let peak = catalogPersistenceAdd204(copyPeak, catalogPersistenceAdd204(
                catalogPersistenceMultiply204(count, 1024), catalogPersistenceMultiply204(size, 64)))
            payment.getOrThrow().ensureRetainedPeak(peak)
            storedRows = Some(transaction.query("SELECT thread_id FROM runs WHERE id=" + sqliteText(run)))
            let rows = storedRows.getOrThrow()
            if (rows.size != count) { throw IllegalStateException("Audit stored thread count changed") }
            var actual: Int64 = 0
            for (row in rows) { actual = catalogPersistenceAdd204(actual, row.required(0).size) }
            if (actual != size) { throw IllegalStateException("Audit stored thread extent changed") }
        })
    }
    func grantFrame204(repository: SqlitePermissionRepository, sessionId: SessionId,
        value: PreparedPlanUtf8Owner204): Result<Unit> {
        try {
            copyFrame204(value); fundSession204(sessionId); decodeGrantFrame204()
            // The original method deliberately persists session_only=true;
            // copying the requested flag never changes that existing rule.
            repository.grant(sessionId, grantScope.getOrThrow())
        } catch (error: Exception) {
            exception = Some(error)
            sqliteToolError("persistence.sqlite_permission_grant", error.message)
        }
    }
    func appendAuditFrame204(database: SqliteDatabase,
        value: PreparedPlanUtf8Owner204): Result<Unit> {
        try {
            copyFrame204(value)
            let root = decoded.getOrThrow()
            let run = root.field("run_id").getOrThrow()
            let event = root.field("event204").getOrThrow()
            if (run.unifiedKind != ValueKind.Text || event.unifiedKind != ValueKind.Object ||
                event.fields.size != 13) { throw IllegalStateException("complete Audit DATA envelope is invalid") }
            for (name in ["run_id", "kind", "trace_id", "payload_type"]) {
                if (event.field(name).getOrThrow().unifiedKind != ValueKind.Text) {
                    throw IllegalStateException("complete Audit DATA text is invalid") }
            }
            for (name in ["format_version", "sequence", "timestamp_ms"]) {
                let number = event.field(name).getOrThrow()
                if (number.unifiedKind != ValueKind.Number) {
                    throw IllegalStateException("complete Audit DATA number is invalid") }
                let _ = Int64.parse(number.asNumberText())
            }
            for (name in ["turn_id", "request_id", "tool_batch_id", "tool_call_id", "operation_id"]) {
                let optionalId = event.field(name).getOrThrow()
                if (optionalId.unifiedKind != ValueKind.Text && optionalId.unifiedKind != ValueKind.Null) {
                    throw IllegalStateException("complete Audit DATA optional identity is invalid") }
            }
            let _ = event.field("detail").getOrThrow()
            if (event.field("run_id").getOrThrow().text != run.text ||
                Int64.parse(event.field("format_version").getOrThrow().asNumberText()) != RUN_EVENT_FORMAT_VERSION) {
                throw IllegalStateException("complete Audit DATA identity is invalid") }
            // Identical SELECT/NULL choice, tool_audit kind and current UTC
            // timestamp as SqliteAuditRepository.append. SqliteDatabase is
            // concrete: its complete execute/query helpers finalize and free
            // their CString/statement inputs before returning here.
            readAuditThreadFrame204(database, run.text)
            let threadRows = storedRows.getOrThrow()
            let thread = if (threadRows.size == 1) {
                sqliteText(threadRows[0].required(0))
            } else {
                "NULL"
            }
            encoded = Some(encodeAgentValue(event))
            database.execute(
                "INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(" +
                    thread + "," + sqliteText(run.text) + ",NULL,'tool_audit'," +
                    sqliteText(encoded.getOrThrow()) + "," + agentUtcMillis().toString() + ")"
            )
            Result.Ok(())
        } catch (error: Exception) {
            exception = Some(error)
            sqliteToolError("persistence.sqlite_audit_append", error.message)
        }
    }
    func holdError204(error: AgentError): Unit { failure = Some(error) }
    func clearWholeReturnedFrame204(): Unit {
        if (failure.isSome() || exception.isSome()) {
            throw IllegalStateException("failed persistence DATA still owns its copies") }
        grantScope = None<ApprovalGrantScope>; encoded = None<String>
        storedRows = None<Array<SqliteRow>>; storedValue = None<AgentValue>
        decoded = None<AgentValue>; text = None<String>; bytes = None<Array<UInt8>>
        cleared = true
    }
    func retirementPayment204(): LogicalJsonOwnerReservation {
        if (!cleared || grantScope.isSome() || encoded.isSome() || storedRows.isSome() || storedValue.isSome() || decoded.isSome() || text.isSome() || bytes.isSome()) {
            throw IllegalStateException("persistence DATA consumer has not returned") }
        payment.getOrThrow()
    }
    func detachPaymentFrame204(): Unit { payment = None<LogicalJsonOwnerReservation> }
}

private class CatalogPersistenceCopies204 {
    private let lock = Mutex()
    private var first: ?CatalogPersistenceCopy204 = None<CatalogPersistenceCopy204>
    private var pending: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var retiring: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func register204(payment: LogicalJsonOwnerReservation): ?CatalogPersistenceCopy204 {
        lock.lock()
        try {
            if (pending.isSome()) { return None<CatalogPersistenceCopy204> }
            pending = Some(payment)
            let value = CatalogPersistenceCopy204(payment)
            value.next204 = first; first = Some(value)
            pending = None<LogicalJsonOwnerReservation>
            Some(value)
        } finally { lock.unlock() }
    }
    func retire204(value: CatalogPersistenceCopy204): Unit {
        lock.lock()
        try {
            if (retiring.isSome()) { return }
            retiring = Some(value.retirementPayment204())
            unlinkFrame204(value)
            value.detachPaymentFrame204()
            closeRetirementFrame204()
            retiring = None<LogicalJsonOwnerReservation>
        } finally { lock.unlock() }
    }
    private func unlinkFrame204(value: CatalogPersistenceCopy204): Unit {
        var previous: ?CatalogPersistenceCopy204 = None<CatalogPersistenceCopy204>
        var cursor = first
        while (cursor.isSome()) {
            let current = cursor.getOrThrow()
            if (refEq(current, value)) {
                match (previous) { case Some(parent) => parent.next204 = current.next204
                    case None => first = current.next204 }
                current.next204 = None<CatalogPersistenceCopy204>; return
            }
            previous = cursor; cursor = current.next204
        }
        throw IllegalStateException("persistence DATA copy is not registered")
    }
    private func closeRetirementFrame204(): Unit { retiring.getOrThrow().close() }
}

func openCatalogPersistenceCopy204(value: PreparedPlanUtf8Owner204): CatalogPersistenceCopy204 {
    // No externally implemented numeric method runs while the ledger is locked.
    let paid = value.deriveCopiedPlanPayment204(131072)
    match (catalogPersistenceCopies204.register204(paid)) {
        case Some(phase) => phase
        case None =>
            paid.close()
            throw IllegalStateException("persistence DATA copy allocation is pending")
    }
}
func returnCatalogPersistenceCopy204(phase: CatalogPersistenceCopy204): Unit {
    phase.clearWholeReturnedFrame204()
    catalogPersistenceCopies204.retire204(phase)
}

private func catalogPersistenceAdd204(left: Int64, right: Int64): Int64 {
    if (left < 0 || right < 0 || left > Int64.Max - right) {
        throw LogicalJsonPayloadError("persistence DATA copy invoice overflow") }
    left + right
}
private func catalogPersistenceMultiply204(value: Int64, factor: Int64): Int64 {
    if (value < 0 || value > Int64.Max / factor) {
        throw LogicalJsonPayloadError("persistence DATA copy invoice overflow") }
    value * factor
}
// Allocation-free, conservative JSON shape invoice. Structural punctuation
// outside quoted strings bounds all container, value and field nodes; the
// original parser still makes every grammar, UTF8, duplicate and size decision.
private func catalogPersistenceJsonCopyPeak204(value: String): Int64 {
    var structures: Int64 = 1
    var quoted = false; var escaped = false
    let raw = unsafe { value.rawData() }
    for (index in 0..raw.size) {
        let byte = raw[index]
        if (quoted) {
            if (escaped) { escaped = false }
            else if (byte == UInt8(92)) { escaped = true }
            else if (byte == b'"') { quoted = false }
        } else if (byte == b'"') { quoted = true }
        else if (byte == b'[' || byte == b']' || byte == b'{' || byte == b'}' || byte == b',' || byte == b':') {
            structures = catalogPersistenceAdd204(structures, 1)
        }
    }
    catalogPersistenceAdd204(catalogPersistenceMultiply204(value.size, 64),
        catalogPersistenceMultiply204(structures, 4096))
}
