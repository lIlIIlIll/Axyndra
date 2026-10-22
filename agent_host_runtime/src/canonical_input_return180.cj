package agent_host_runtime

import agent_runtime.*
import agent_domain.*
import std.sync.*
import tool_runtime

// DATA custody only. The existing gateway binds its actual frame and original
// Runtime scope; neither this receiver nor its allocation authorizes execution.
public class HostCanonicalInputReturn180 {
    private let lock = Mutex()
    private var startEntered = false
    private var gatewayFrame: ?HostDirectGatewayFrame159e = None<HostDirectGatewayFrame159e>
    private var originalScope: ?OwnedTaskReturnWitness113 = None<OwnedTaskReturnWitness113>
    private var originalFailure: ?Exception = None<Exception>
    private var originalInputPayment180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var contextPayment180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var actualContext180: ?tool_runtime.ToolInvocationContext = None<tool_runtime.ToolInvocationContext>
    func bindOriginalInputPayment180(paid: LogicalJsonOwnerReservation): Unit {
        lock.lock(); try {
            if (originalInputPayment180.isSome()) { throw IllegalStateException("original input DATA is already installed") }
            originalInputPayment180 = Some(paid)
        } finally { lock.unlock() }
    }
    func reserveContextBeforeConstruction180(): LogicalJsonOwnerReservation {
        lock.lock(); try {
            if (contextPayment180.isSome()) { throw IllegalStateException("canonical Context is already installed") }
            let paid = originalInputPayment180.getOrThrow().deriveRetainedLease()
            contextPayment180 = Some(paid); paid.ensureRetainedPeak(131072); paid
        } finally { lock.unlock() }
    }
    func bindActualContext180(context: tool_runtime.ToolInvocationContext): Unit {
        lock.lock(); try { actualContext180 = Some(context) } finally { lock.unlock() }
    }
    private func detachContextAfterHelpers180(): (?tool_runtime.ToolInvocationContext, ?LogicalJsonOwnerReservation) {
        lock.lock(); try {
            let context = actualContext180; actualContext180 = None<tool_runtime.ToolInvocationContext>
            let failedConstruction = if (context.isNone()) { contextPayment180 } else { None<LogicalJsonOwnerReservation> }
            contextPayment180 = None<LogicalJsonOwnerReservation>; originalInputPayment180 = None<LogicalJsonOwnerReservation>
            gatewayFrame = None<HostDirectGatewayFrame159e>; originalScope = None<OwnedTaskReturnWitness113>
            (context, failedConstruction)
        } finally { lock.unlock() }
    }
    func retireAfterOriginalInputHelpers180(): Unit {
        if (!originalInputConsumersReturned180()) { throw IllegalStateException("original canonical input has not returned") }
        let returned = detachContextAfterHelpers180()
        match (returned[0]) { case Some(context) => context.returnOwnedToolSetFrame159(); case None => () }
        match (returned[1]) { case Some(paid) => paid.close(); case None => () }
    }


    func bindGatewayFrame180(frame: ?HostDirectGatewayFrame159e): Unit {
        lock.lock(); try { gatewayFrame = frame } finally { lock.unlock() }
    }
    func enterOriginalStartHelper180(): Unit {
        lock.lock(); try { startEntered = true } finally { lock.unlock() }
    }
    func bindOriginalScope180(scope: ?OwnedTaskReturnWitness113): Unit {
        lock.lock(); try {
            if (originalScope.isSome()) { throw IllegalStateException("original canonical scope already bound") }
            originalScope = scope
        } finally { lock.unlock() }
    }
    func retainOriginalException180(error: Exception): Unit {
        lock.lock(); try { if (originalFailure.isNone()) { originalFailure = Some(error) } } finally { lock.unlock() }
    }
    func originalInputConsumersReturned180(): Bool {
        lock.lock(); try {
            if (originalFailure.isSome()) { return false }
            match (gatewayFrame) { case Some(frame) => if (!frame.originalInputConsumersDetached180()) { return false }; case None => () }
            if (!startEntered) { return true }
            match (originalScope) { case Some(scope) => scope.allOwnedProducersReturned113(); case None => false }
        } finally { lock.unlock() }
    }
}
