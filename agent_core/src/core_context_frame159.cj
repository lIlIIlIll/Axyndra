package agent_core

import agent_domain.*
import tool_runtime.*
import std.sync.*

// Actual private Core Context DATA, never a Source/Receipt. The control keeps
// this node through the complete producer helper and real Run-task witness.
class CoreContextFrame159 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var context: ?ToolInvocationContext = None<ToolInvocationContext>
    private var producerReturned = false
    private var held = false
    var next159: ?CoreContextFrame159 = None<CoreContextFrame159>
    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }
    func capture159(value: ToolInvocationContext): Unit {
        lock.lock()
        try {
            if (context.isSome() || producerReturned || payment.isNone()) {
                throw IllegalStateException("Core Context producer is unavailable") }
            context = Some(value)
        } finally { lock.unlock() }
    }
    func returnedPrivateHelper159(): Unit { lock.lock(); try { producerReturned = true } finally { lock.unlock() } }
    func holdUnknown159(): Unit { lock.lock(); try { held = true } finally { lock.unlock() } }
    func returnAfterActualTasks159(): Bool {
        let paid = try { clearReturnedContextFrame159() }
            catch (_: Exception) { holdUnknown159(); return false }
        match (paid) { case Some(value) => value.close(); case None => () }
        lock.lock(); try { payment.isNone() } finally { lock.unlock() }
    }
    private func clearReturnedContextFrame159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (!producerReturned || held || payment.isNone()) { return None<LogicalJsonOwnerReservation> }
            match (context) { case Some(value) => value.returnOwnedToolSetFrame159(); case None => () }
            context = None<ToolInvocationContext>
            let paid = payment; payment = None<LogicalJsonOwnerReservation>; paid
        } finally { lock.unlock() }
    }
}
