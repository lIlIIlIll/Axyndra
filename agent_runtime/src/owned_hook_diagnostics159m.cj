package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.collection.*
import std.sync.*

private let hookDiagnosticBuffers159m = HookDiagnosticBuffers159m()

// Private DATA only. The concrete Product transfers its private, bounded
// message array while holding its diagnostics lock. Historical public exports
// deliberately keep the buffer and every affected copied row paid.
public class OwnedHookDiagnosticBuffer159m {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var messages: ?ArrayList<String> = None<ArrayList<String>>
    private var rows: ?ArrayList<?OwnedHookDiagnosticRow159m> = None<ArrayList<?OwnedHookDiagnosticRow159m>>
    private var pending: ?OwnedHookDiagnosticRow159m = None<OwnedHookDiagnosticRow159m>
    // Registered before removing either paired row; failed mutation keeps
    // both the old and new DATA payments reachable in this original buffer.
    private var retiring: ?OwnedHookDiagnosticRow159m = None<OwnedHookDiagnosticRow159m>
    private var historicalRows: ?OwnedHookDiagnosticRow159m = None<OwnedHookDiagnosticRow159m>
    private var historical = false
    private var residentInvoice: Int64 = 65536
    var next159m: ?OwnedHookDiagnosticBuffer159m = None<OwnedHookDiagnosticBuffer159m>
    init(paid: LogicalJsonOwnerReservation) {
        payment = Some(paid); hookDiagnosticBuffers159m.add159m(this)
    }
    func installPrivateBuffer159m(actual: ArrayList<String>): Unit {
        lock.lock()
        try {
            if (messages.isSome() || payment.isNone() || actual.size > 128) {
                throw IllegalStateException("private Hook diagnostic buffer is unavailable")
            }
            // Own an independent backing and independent text copies; even a
            // historical caller retaining the input list owns no new alias.
            messages = Some(ArrayList<String>())
            rows = Some(ArrayList<?OwnedHookDiagnosticRow159m>())
            copyInitialDiagnosticFrame159m(actual)
        } finally { lock.unlock() }
    }
    private func copyInitialDiagnosticFrame159m(actual: ArrayList<String>): Unit {
        for (text in actual) {
            if (messages.getOrThrow().size >= 128) { throw IllegalStateException("Hook diagnostic input changed during copy") }
            let paid = payment.getOrThrow().deriveRetainedLease()
            try {
                let bytes = addHookDiagnosticBytes159m(0, text.size)
                paid.ensureRetainedPeak(8192 + bytes * 64)
            } catch (error: Exception) { paid.close(); throw error }
            let created = OwnedHookDiagnosticRow159m(paid)
            pending = Some(created)
            created.installCopiedText159m(text)
            messages.getOrThrow().add(created.privateText159m())
            rows.getOrThrow().add(Some(created))
            pending = None<OwnedHookDiagnosticRow159m>
        }
    }
    public func appendDiagnostic159m(event: String, pluginId: String, code: String): Unit {
        lock.lock()
        try { appendAndRetirePrivateFrame159m(event, pluginId, code) }
        finally { lock.unlock() }
    }
    private func appendAndRetirePrivateFrame159m(event: String, pluginId: String, code: String): Unit {
        appendDiagnosticFrame159m(event, pluginId, code)
        // The whole formatter/array helper returned. Keep the exact old row
        // registered even if its own clear/payment return now throws.
        match (retiring) {
            case Some(value) =>
                if (historical) { value.nextHistorical159m = historicalRows; historicalRows = Some(value) }
                else { value.returnPrivateText159m() }
                retiring = None<OwnedHookDiagnosticRow159m>
            case None => ()
        }
    }
    private func appendDiagnosticFrame159m(event: String, pluginId: String,
        code: String): Unit {
        if (payment.isNone() || messages.isNone() || rows.isNone() || pending.isSome() || retiring.isSome()) {
            throw IllegalStateException("Hook diagnostic producer has not returned")
        }
        let paid = payment.getOrThrow().deriveRetainedLease()
        var bytes: Int64 = 10
        try {
            bytes = addHookDiagnosticBytes159m(bytes, event.size)
            bytes = addHookDiagnosticBytes159m(bytes, pluginId.size)
            bytes = addHookDiagnosticBytes159m(bytes, code.size)
            paid.ensureRetainedPeak(8192 + bytes * 64)
        } catch (error: Exception) { paid.close(); throw error }
        let created = OwnedHookDiagnosticRow159m(paid)
        pending = Some(created)
        created.installOriginalFormat159m(event, pluginId, code)
        let actual = messages.getOrThrow(); let paired = rows.getOrThrow()
        if (actual.size >= 128) {
            // Same original oldest-first rule; remove clears the actual tail
            // slot in the installed SDK. Full backing stays resident-paid.
            retiring = paired[0]
            actual.remove(at: 0)
            let _ = paired.remove(at: 0)
        }
        actual.add(created.privateText159m())
        paired.add(Some(created))
        pending = None<OwnedHookDiagnosticRow159m>
    }
    public func exportHistorical159m(): Array<String> {
        lock.lock()
        try {
            if (payment.isNone() || messages.isNone() || pending.isSome() || retiring.isSome()) {
                throw IllegalStateException("Hook diagnostics are unavailable")
            }
            let extra = 8192 + messages.getOrThrow().size * 128
            if (residentInvoice > Int64.Max - extra) {
                throw LogicalJsonPayloadError("Hook diagnostic snapshot invoice overflow")
            }
            payment.getOrThrow().ensureRetainedPeak(residentInvoice + extra)
            residentInvoice += extra
            historical = true
            messages.getOrThrow().toArray()
        } finally { lock.unlock() }
    }
    // Closed DATA checks for typed consumers and controls; no raw String,
    // allocator, callback or Source is returned from these methods.
    public func count159m(): Int64 {
        lock.lock(); try { messages.getOrThrow().size } finally { lock.unlock() }
    }
    public func textEquals159m(index: Int64, expected: String): Bool {
        lock.lock(); try { messages.getOrThrow()[index] == expected } finally { lock.unlock() }
    }
    public func returnPrivateBuffer159m(): Bool {
        lock.lock()
        try {
            if (historical || pending.isSome() || retiring.isSome()) { return false }
            if (payment.isNone()) { return true }
            returnAllPrivateRowsFrame159m()
            // All message/paired-array/row locals from both complete helpers
            // are gone before the fixed resident metadata itself can retire.
            let paid = clearResidentFrame159m()
            match (paid) { case Some(value) => value.close(); case None => () }
            true
        } finally { lock.unlock() }
    }
    private func returnAllPrivateRowsFrame159m(): Unit {
        let paired = detachPrivateArraysFrame159m()
        for (row in paired) {
            match (row) { case Some(value) => value.returnPrivateText159m(); case None => () }
        }
    }
    private func detachPrivateArraysFrame159m(): ArrayList<?OwnedHookDiagnosticRow159m> {
        messages = None<ArrayList<String>>
        let paired = rows.getOrThrow(); rows = None<ArrayList<?OwnedHookDiagnosticRow159m>>
        paired
    }
    private func clearResidentFrame159m(): ?LogicalJsonOwnerReservation {
        if (messages.isSome() || rows.isSome() || pending.isSome() || retiring.isSome() || historicalRows.isSome()) {
            throw IllegalStateException("Hook diagnostic references are still retained")
        }
        let paid = payment; payment = None<LogicalJsonOwnerReservation>
        hookDiagnosticBuffers159m.remove159m(this); paid
    }
}
class OwnedHookDiagnosticRow159m {
    private var payment: ?LogicalJsonOwnerReservation
    private var text: ?String = None<String>
    var nextHistorical159m: ?OwnedHookDiagnosticRow159m = None<OwnedHookDiagnosticRow159m>
    init(paid: LogicalJsonOwnerReservation) { payment = Some(paid) }
    func installCopiedText159m(value: String): Unit {
        if (text.isSome() || payment.isNone()) { throw IllegalStateException("Hook diagnostic row is already installed") }
        text = Some(String.fromUtf8(value.toArray()))
    }
    func installOriginalFormat159m(event: String, pluginId: String, code: String): Unit {
        if (text.isSome() || payment.isNone()) { throw IllegalStateException("Hook diagnostic row is already installed") }
        text = Some("${event} plugin ${pluginId}: ${code}")
    }
    func privateText159m(): String { text.getOrThrow() }
    func returnPrivateText159m(): Unit {
        let paid = clearPrivateTextFrame159m()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
    private func clearPrivateTextFrame159m(): ?LogicalJsonOwnerReservation {
        if (nextHistorical159m.isSome()) { throw IllegalStateException("historical diagnostic remains retained") }
        text = None<String>
        let paid = payment; payment = None<LogicalJsonOwnerReservation>; paid
    }
}
private func addHookDiagnosticBytes159m(total: Int64, bytes: Int64): Int64 {
    if (bytes < 0 || total < 0 || bytes > (Int64.Max - 8192) / 64 - total) {
        throw LogicalJsonPayloadError("Hook diagnostic copy invoice overflow")
    }
    total + bytes
}
private class HookDiagnosticBuffers159m {
    private let lock = Mutex()
    private var first: ?OwnedHookDiagnosticBuffer159m = None<OwnedHookDiagnosticBuffer159m>
    func add159m(value: OwnedHookDiagnosticBuffer159m): Unit {
        lock.lock(); try { value.next159m = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159m(value: OwnedHookDiagnosticBuffer159m): Unit {
        lock.lock()
        try {
            var previous: ?OwnedHookDiagnosticBuffer159m = None<OwnedHookDiagnosticBuffer159m>
            var cursor = first
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(prior) => prior.next159m = actual.next159m; case None => first = actual.next159m }
                    actual.next159m = None<OwnedHookDiagnosticBuffer159m>; return
                }
                previous = cursor; cursor = actual.next159m
            }
            throw IllegalStateException("Hook diagnostic buffer was not registered")
        } finally { lock.unlock() }
    }
}
