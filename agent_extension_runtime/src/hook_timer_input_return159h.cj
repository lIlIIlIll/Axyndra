package agent_extension_runtime

import agent_domain.{LogicalJsonOwnerReservation, LogicalJsonPayloadError}
import std.sync.*

private let hookTimerHeaders159h = HookTimerHeaders159h()

// One reusable header per real extension worker. Its fixed payment remains
// with that worker until the separate cache retirement protocol is connected.
// Each invocation's identity and callback captures use an independent phase.
class JavaScriptHookTimer159h {
    private let header: LogicalJsonOwnerReservation
    // SDK execute/get do not clear Future.fn. Charge every newly allocated
    // Future/closure separately and retain that scalar metadata until a real
    // scheduler retirement witness exists. Dynamic input phases are separate.
    private var residentInvoice159h: Int64 = 32768
    private var phase: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var invoice: Int64 = 0
    private var timerAction: ?() -> Unit = None<() -> Unit>
    private var timerFuture: ?Future<Unit> = None<Future<Unit>>
    private var cancelAction: ?() -> Unit = None<() -> Unit>
    private var cancelFuture: ?Future<Unit> = None<Future<Unit>>
    private var timerStarted = false
    private var cancelStarted = false
    var next159h: ?JavaScriptHookTimer159h = None<JavaScriptHookTimer159h>

    init(paid: LogicalJsonOwnerReservation) {
        header = paid
        hookTimerHeaders159h.add159h(this)
    }
    func begin159h(identity: JavaScriptHostInvocationIdentity,
        invocationId: String, toolName: String): Unit {
        if (phase.isSome() || timerAction.isSome() || timerFuture.isSome() ||
            cancelAction.isSome() || cancelFuture.isSome()) {
            throw IllegalStateException("prior hook timer input is still retained")
        }
        // All inputs are already live caller data. This arithmetic allocates
        // no array/DOM/String and precedes construction of either action.
        var bytes: Int64 = 0
        bytes = addHookTimerBytes159h(bytes, identity.kind.size)
        bytes = addHookTimerBytes159h(bytes, identity.threadId.size)
        bytes = addHookTimerBytes159h(bytes, identity.runId.size)
        bytes = addHookTimerBytes159h(bytes, identity.operationId.size)
        bytes = addHookTimerBytes159h(bytes, identity.callId.size)
        bytes = addHookTimerBytes159h(bytes, identity.commandId.size)
        bytes = addHookTimerBytes159h(bytes, invocationId.size)
        bytes = addHookTimerBytes159h(bytes, toolName.size)
        invoice = 131072 + bytes * 32
        let paid = header.deriveRetainedLease()
        try { paid.ensureRetainedPeak(invoice) }
        catch (error: Exception) { paid.close(); throw error }
        phase = Some(paid)
        timerStarted = false; cancelStarted = false
    }
    func installTimer159h(action: () -> Unit): Unit {
        if (phase.isNone() || timerStarted || timerAction.isSome()) {
            throw IllegalStateException("hook timer phase is unavailable")
        }
        timerAction = Some(action)
    }
    private func fundSchedulerMetadata159h(): Unit {
        if (residentInvoice159h > 134217728 - 8192) {
            throw LogicalJsonPayloadError("hook scheduler metadata exceeds original aggregate")
        }
        header.ensureRetainedPeak(residentInvoice159h + 8192)
        residentInvoice159h += 8192
    }
    func startTimer159h(): Unit {
        if (timerStarted || timerAction.isNone()) { throw IllegalStateException("hook timer is unavailable") }
        fundSchedulerMetadata159h()
        timerStarted = true
        // A scheduler retains only the fixed header. The complete dynamic
        // input action is removed after its actual get helper returns.
        timerFuture = Some(spawn { runTimerFrame159h() })
    }
    private func runTimerFrame159h(): Unit { timerAction.getOrThrow()() }
    func fundCancel159h(code: String): Unit {
        if (phase.isNone() || cancelAction.isSome() || cancelStarted) {
            throw IllegalStateException("hook cancel writer is unavailable")
        }
        let size = addHookTimerBytes159h(0, code.size)
        let extra = 16384 + size * 32
        if (invoice > 134217728 - extra) { throw IllegalStateException("hook timer input exceeds the original bank") }
        phase.getOrThrow().ensureRetainedPeak(invoice + extra)
        invoice += extra
    }
    func installCancel159h(action: () -> Unit): Unit {
        if (phase.isNone() || cancelAction.isSome() || cancelStarted) {
            throw IllegalStateException("hook cancel writer is already installed")
        }
        cancelAction = Some(action)
    }
    func startCancel159h(): Unit {
        if (cancelStarted || cancelAction.isNone()) { throw IllegalStateException("hook cancel writer is unavailable") }
        fundSchedulerMetadata159h()
        cancelStarted = true
        cancelFuture = Some(spawn { runCancelFrame159h() })
    }
    func runCancelFrame159h(): Unit { cancelAction.getOrThrow()() }
    func joinCancel159h(): Unit {
        if (cancelStarted) { joinHookTimerFuture159h(cancelFuture.getOrThrow()) }
        cancelFuture = None<Future<Unit>>
        clearCancelActionFrame159h()
    }
    private func clearCancelActionFrame159h(): Unit { cancelAction = None<() -> Unit> }
    func joinTimer159h(): Unit {
        joinHookTimerFuture159h(timerFuture.getOrThrow())
        timerFuture = None<Future<Unit>>
        clearTimerActionFrame159h()
        if (cancelFuture.isSome() || cancelAction.isSome()) {
            throw IllegalStateException("hook cancel writer input is still retained")
        }
        let paid = detachInputPhaseFrame159h()
        paid.close()
    }
    private func clearTimerActionFrame159h(): Unit { timerAction = None<() -> Unit> }
    private func detachInputPhaseFrame159h(): LogicalJsonOwnerReservation {
        let paid = phase.getOrThrow()
        phase = None<LogicalJsonOwnerReservation>; invoice = 0
        paid
    }
}
private func addHookTimerBytes159h(total: Int64, bytes: Int64): Int64 {
    if (bytes < 0 || total < 0 || total > (134217728 - 131072) / 32 - bytes) {
        throw IllegalStateException("hook timer identity exceeds the original bank")
    }
    total + bytes
}
private func joinHookTimerFuture159h(value: Future<Unit>): Unit { value.get() }
private class HookTimerHeaders159h {
    private let lock = Mutex()
    private var first: ?JavaScriptHookTimer159h = None<JavaScriptHookTimer159h>
    func add159h(value: JavaScriptHookTimer159h): Unit {
        lock.lock(); try { value.next159h = first; first = Some(value) }
        finally { lock.unlock() }
    }
}
