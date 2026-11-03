package agent_runtime

import agent_domain.*
import logical_json_payload.LogicalJsonOwnerReservation as ImportedLogicalJsonOwnerReservation
import std.collection.*
import std.sync.*

private let ownedHookSelections159f = OwnedHookSelections159f()

// Independent DATA copies; no Run, capability or caller-supplied allocator.
// The source snapshot can return after the complete copying helper returned.
public class OwnedToolHookSelection159f {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var handlers: ?Array<ToolHookHandlerSnapshot> = None<Array<ToolHookHandlerSnapshot>>
    private var held = false
    private var returned = false
    private var activeFrames159k: Int64 = 0
    var next159f: ?OwnedToolHookSelection159f = None<OwnedToolHookSelection159f>
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment); ownedHookSelections159f.add159f(this)
    }
    func installMatchingCopies159f(snapshot: ToolSetSnapshot, event: String, name: String): Unit {
        lock.lock()
        try {
            if (handlers.isSome() || returned || payment.isNone()) { throw IllegalStateException("hook copies already installed") }
            handlers = Some(copyMatchingHookFrame159f(snapshot, event, name))
        } catch (error: Exception) { held = true; throw error }
        finally { lock.unlock() }
    }
    public func beginPrivateHookFrame159k(): Unit {
        lock.lock()
        try {
            if (returned || payment.isNone() || activeFrames159k == Int64.Max) {
                throw IllegalStateException("hook selection frame is unavailable")
            }
            activeFrames159k++
        } finally { lock.unlock() }
    }
    // Called by the concrete owner only after the complete consuming helper
    // returned. An arbitrary saved raw alias still requires holdUnknown.
    public func endReturnedPrivateHookFrame159k(): Unit {
        lock.lock()
        try {
            if (activeFrames159k < 1) { throw IllegalStateException("hook selection has no entered frame") }
            activeFrames159k--
        } finally { lock.unlock() }
    }
    // This named producer/consumer handoff does not ACK unknown process or
    // callback consumers. Product must preserve the owner for those aliases.
    public func handlersForPrivateHookFrame159f(): Array<ToolHookHandlerSnapshot> {
        lock.lock()
        try {
            if (returned || payment.isNone() || activeFrames159k < 1) { throw IllegalStateException("hook frame is not entered") }
            handlers.getOrThrow()
        } finally { lock.unlock() }
    }
    public func createPrivateDiagnosticBuffer159m(messages: ArrayList<String>): OwnedHookDiagnosticBuffer159m {
        lock.lock()
        try {
            if (returned || payment.isNone() || activeFrames159k < 1) {
                throw IllegalStateException("Hook diagnostic source frame is not entered")
            }
            let paid = payment.getOrThrow().deriveRetainedLease()
            try { paid.ensureRetainedPeak(65536) }
            catch (error: Exception) { paid.close(); throw error }
            let result = OwnedHookDiagnosticBuffer159m(paid)
            result.installPrivateBuffer159m(messages)
            result
        } finally { lock.unlock() }
    }
    public func holdUnknownHookConsumers159f(): Unit {
        lock.lock(); try { held = true } finally { lock.unlock() }
    }
    public func returnPrivateHookFrame159f(): Bool {
        let paid = clearPrivateHookFrame159f()
        match (paid) { case Some(value) => value.close(); true; case None => false }
    }
    private func clearPrivateHookFrame159f(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (held || activeFrames159k != 0 || payment.isNone()) { return None<LogicalJsonOwnerReservation> }
            returned = true
            handlers = None<Array<ToolHookHandlerSnapshot>>
            let paid = payment; payment = None<LogicalJsonOwnerReservation>
            ownedHookSelections159f.remove159f(this); paid
        } finally { lock.unlock() }
    }
}
private func copyMatchingHookFrame159f(snapshot: ToolSetSnapshot, event: String, name: String): Array<ToolHookHandlerSnapshot> {
    let result = ArrayList<ToolHookHandlerSnapshot>()
    for (value in snapshot.hookHandlers where value.event == event &&
        (value.matcher == "*" || value.matcher == name)) {
        result.add(ToolHookHandlerSnapshot(String.fromUtf8(value.event.toArray()),
            String.fromUtf8(value.pluginId.toArray()), String.fromUtf8(value.pluginVersion.toArray()),
            String.fromUtf8(value.contentDigest.toArray()), String.fromUtf8(value.packageRoot.toArray()),
            String.fromUtf8(value.matcher.toArray()), String.fromUtf8(value.command.toArray()), value.timeoutMillis))
    }
    result.toArray()
}
private class OwnedHookSelections159f {
    private let lock = Mutex()
    private var first: ?OwnedToolHookSelection159f = None<OwnedToolHookSelection159f>
    func add159f(value: OwnedToolHookSelection159f): Unit {
        lock.lock();try { value.next159f=first;first=Some(value) } finally { lock.unlock() }
    }
    func remove159f(value: OwnedToolHookSelection159f): Unit {
        lock.lock()
        try {
            var previous: ?OwnedToolHookSelection159f = None<OwnedToolHookSelection159f>
            var cursor=first
            while (cursor.isSome()) {
                let actual=cursor.getOrThrow()
                if (refEq(actual,value)) {
                    match(previous){case Some(p)=>p.next159f=actual.next159f;case None=>first=actual.next159f}
                    actual.next159f=None<OwnedToolHookSelection159f>;return
                }
                previous=cursor;cursor=actual.next159f
            }
            throw IllegalStateException("hook selection was not registered")
        } finally { lock.unlock() }
    }
}
