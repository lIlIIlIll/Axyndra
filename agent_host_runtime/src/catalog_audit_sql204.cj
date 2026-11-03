package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.sync.*
import yjson.*
import yjson_support.*

private let hostCatalogAuditCopies204 = HostCatalogAuditCopies204()

// The caller already holds its actual SQLite owner. This helper introduces
// only a prepaid DATA copy; it does not acquire a Run, Source, DB or admission.
public func hostAppendCatalogAuditSql204(database: SqliteDatabase,
    value: PreparedPlanUtf8Owner204, threadId: String, kind: String,
    observedAtMillis: Int64): Result<Unit> {
    let phase = hostCatalogAuditCopies204.create204(value)
    let answer = phase.appendSqlFrame204(database, value, threadId, kind, observedAtMillis)
    match (answer) { case Result.Ok(_) => phase.returnWholeSqlFrame204(); case Result.Err(_) => () }
    answer
}

private class HostCatalogAuditCopy204 {
    private var payment: ?LogicalJsonOwnerReservation
    private var copied: ?Array<UInt8> = None<Array<UInt8>>
    private var text: ?String = None<String>
    private var decoded: ?AgentValue = None<AgentValue>
    private var encoded: ?String = None<String>
    var next204: ?HostCatalogAuditCopy204 = None<HostCatalogAuditCopy204>
    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }

    func appendSqlFrame204(database: SqliteDatabase, value: PreparedPlanUtf8Owner204,
        threadId: String, kind: String, observedAtMillis: Int64): Result<Unit> {
        try {
            let count = value.byteCount
            if (count < 0 || count > 8388608) {
                throw IllegalStateException("stored value exceeds its original 8 MiB bound") }
            // The separate Array and String are paid before either exists.
            payment.getOrThrow().ensureRetainedPeak(131072 + count * 4)
            copied = Some(Array<UInt8>(count, { _ => UInt8(0) }))
            for (index in 0..count) { copied.getOrThrow()[index] = value.byteAt(index) }
            let invoice = preparedFramedValueCopyPeak204(copied.getOrThrow())
            payment.getOrThrow().ensureRetainedPeak(invoice)
            text = Some(String.fromUtf8(copied.getOrThrow()))
            decoded = Some(decodeStoredValue(text.getOrThrow()))
            let run = decoded.getOrThrow().field("run_id").getOrThrow()
            let detail = decoded.getOrThrow().field("detail").getOrThrow()
            if (run.unifiedKind != ValueKind.Text || detail.unifiedKind != ValueKind.Object) {
                throw IllegalStateException("complete original Audit DATA envelope is invalid") }
            let meter = HubProcessPlanInvoice180({ minimum => payment.getOrThrow().ensureRetainedPeak(minimum) })
            meter.includeRequest180(detail)
            payment.getOrThrow().ensureRetainedPeak(meter.retainedPeak())
            encoded = Some(encodeStoredValue(detail))
            // SqliteDatabase.execute returns only after the full statement
            // helper finalized its SQLITE_STATIC input references and buffers.
            database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) " +
                "VALUES(?, ?, NULL, ?, ?, ?)", [SqlParameter.Text(threadId), SqlParameter.Text(run.text),
                    SqlParameter.Text(kind), SqlParameter.Text(encoded.getOrThrow()), SqlParameter.Int64Value(observedAtMillis)])
            Result.Ok(())
        } catch (_: Exception) {
            // The registered phase still owns every partial copy and payment.
            Result.Err(AgentError(AgentErrorKind.Internal, "fixture.gateway_audit",
                "actual gateway SQLite audit failed"))
        }
    }
    func returnWholeSqlFrame204(): Unit {
        clearReturnedCopiesFrame204()
        hostCatalogAuditCopies204.retire204(this)
    }
    private func clearReturnedCopiesFrame204(): Unit {
        encoded = None<String>; decoded = None<AgentValue>
        text = None<String>; copied = None<Array<UInt8>>
    }
    func retirementPayment204(): LogicalJsonOwnerReservation {
        if (encoded.isSome() || decoded.isSome() || text.isSome() || copied.isSome()) {
            throw IllegalStateException("Audit copy helpers have not returned") }
        payment.getOrThrow()
    }
    func detachPaymentFrame204(): Unit { payment = None<LogicalJsonOwnerReservation> }
}

private class HostCatalogAuditCopies204 {
    private let lock = Mutex()
    private var first: ?HostCatalogAuditCopy204 = None<HostCatalogAuditCopy204>
    private var pending: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var retiring: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func create204(value: PreparedPlanUtf8Owner204): HostCatalogAuditCopy204 {
        // Never invoke an externally implementable numeric interface while
        // holding the private registry mutex. No DATA is captured yet.
        let paid = value.deriveCopiedPlanPayment204(131072)
        match (registerPaymentFrame204(paid)) {
            case Some(phase) => phase
            case None =>
                // The rejecting helper fully returned without installing a
                // phase or reading any input byte. This exact child is unused.
                paid.close()
                throw IllegalStateException("Audit copy construction retains unresolved DATA")
        }
    }
    private func registerPaymentFrame204(paid: LogicalJsonOwnerReservation): ?HostCatalogAuditCopy204 {
        lock.lock()
        try {
            if (pending.isSome()) { return None<HostCatalogAuditCopy204> }
            pending = Some(paid)
            // An interrupted constructor cannot lose the actual reservation.
            // The complete object is registered before reading any dynamic byte.
            let phase = HostCatalogAuditCopy204(paid)
            phase.next204 = first; first = Some(phase)
            pending = None<LogicalJsonOwnerReservation>
            Some(phase)
        } finally { lock.unlock() }
    }
    func retire204(value: HostCatalogAuditCopy204): Unit {
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
    private func closeRetirementFrame204(): Unit { retiring.getOrThrow().close() }
    private func unlinkFrame204(value: HostCatalogAuditCopy204): Unit {
            var previous: ?HostCatalogAuditCopy204 = None<HostCatalogAuditCopy204>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (previous) { case Some(parent) => parent.next204 = current.next204
                        case None => first = current.next204 }
                    current.next204 = None<HostCatalogAuditCopy204>; return
                }
                previous = cursor; cursor = current.next204
            }
            throw IllegalStateException("actual Audit copy phase is not registered")
    }
}
