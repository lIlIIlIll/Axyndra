package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*

// Actual parser DATA and its original Runtime scope, installed before startup.
// Native transfer slots are released by the real caller, never queued as loans.
class HostIngressParserWindow180 {
    let return180 = HostCanonicalInputReturn180()
    var next180: ?HostIngressParserWindow180 = None<HostIngressParserWindow180>
    var runtime180: ?AgentThreadRuntime = None<AgentThreadRuntime>
    var started180: ?ActiveRunSnapshot = None<ActiveRunSnapshot>
    var context180: ?ToolInvocationContext = None<ToolInvocationContext>
    var settlement180: ?RuntimeSettlement = None<RuntimeSettlement>
    private var arguments180: ?AgentValue
    private var argumentData180: ?LogicalJsonOwnerReservation
    private var decodedData180: ?LogicalJsonOwnerReservation
    private var contextData180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    private var decoded180: ?AgentValue = None<AgentValue>
    private var originalException180: ?Exception = None<Exception>
    private var originalError180: ?AgentError = None<AgentError>
    private var settlementError180: ?AgentError = None<AgentError>
    init(arguments: AgentValue, argumentData: LogicalJsonOwnerReservation, decodedData: LogicalJsonOwnerReservation) {
        arguments180 = Some(arguments); argumentData180 = Some(argumentData); decodedData180 = Some(decodedData)
    }
    func argumentsForHelper180(): AgentValue { arguments180.getOrThrow() }
    func decodedPayment180(): LogicalJsonOwnerReservation { decodedData180.getOrThrow() }
    func reserveContextBeforeConstruction180(): LogicalJsonOwnerReservation {
        if (contextData180.isSome()) { throw IllegalStateException("parser Context is already registered") }
        let paid = decodedData180.getOrThrow().deriveRetainedLease()
        contextData180 = Some(paid); paid.ensureRetainedPeak(131072); paid
    }
    func retainDecoded180(value: AgentValue): Unit { decoded180 = Some(value) }
    func transferDecodedPayment180(): LogicalJsonOwnerReservation {
        let value = decodedData180.getOrThrow()
        decoded180 = None<AgentValue>; decodedData180 = None<LogicalJsonOwnerReservation>; value
    }
    func retainOriginalException180(error: Exception): Unit {
        if (originalException180.isNone()) { originalException180 = Some(error) }
        return180.retainOriginalException180(error)
    }
    func retainOriginalAgentError180(error: AgentError): Unit {
        if (originalError180.isNone()) { originalError180 = Some(error) }
    }
    func retainOriginalSettlementError180(error: AgentError): Unit { settlementError180 = Some(error) }
    func originalConsumersReturned180(): Bool {
        if (originalException180.isSome() || settlementError180.isSome()) { return false }
        return180.originalInputConsumersReturned180()
    }
    private func clearWholeParserNode180(): (?ToolInvocationContext, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation, ?LogicalJsonOwnerReservation) {
        let context = context180; context180 = None<ToolInvocationContext>
        // The installed Context owns its payment; failed construction leaves
        // the exact original payment on this already-rooted node.
        let contextData = if (context.isNone()) { contextData180 } else { None<LogicalJsonOwnerReservation> }
        contextData180 = None<LogicalJsonOwnerReservation>
        let decoded = decodedData180; decodedData180 = None<LogicalJsonOwnerReservation>
        let arguments = argumentData180; argumentData180 = None<LogicalJsonOwnerReservation>
        arguments180 = None<AgentValue>; decoded180 = None<AgentValue>
        runtime180 = None<AgentThreadRuntime>; started180 = None<ActiveRunSnapshot>
        settlement180 = None<RuntimeSettlement>; originalError180 = None<AgentError>
        (context, contextData, decoded, arguments)
    }
    func retireAfterActualParserHelpers180(): Unit {
        if (!originalConsumersReturned180()) { throw IllegalStateException("original parser consumers have not returned") }
        let returned = clearWholeParserNode180()
        match (returned[0]) { case Some(context) => context.returnOwnedToolSetFrame159(); case None => () }
        match (returned[1]) { case Some(paid) => paid.close(); case None => () }
        match (returned[2]) { case Some(paid) => paid.close(); case None => () }
        match (returned[3]) { case Some(paid) => paid.close(); case None => () }
    }
}

// The directive and call alias one actual DOM. Their same-bank DATA loan
// survives immediate Native result-wrapper release and all queued consumers.
class HostIngressInvocationData180 {
    private var response180: ?AgentValue
    private var call180: ?ToolCall
    private var payment180: ?LogicalJsonOwnerReservation
    init(response: AgentValue, call: ToolCall, payment: LogicalJsonOwnerReservation) {
        response180 = Some(response); call180 = Some(call); payment180 = Some(payment)
    }
    func borrowCall180(): ToolCall { call180.getOrThrow() }
    func originalPayment180(): LogicalJsonOwnerReservation { payment180.getOrThrow() }
    private func detachWholeInvocationData180(): ?LogicalJsonOwnerReservation {
        response180 = None<AgentValue>; call180 = None<ToolCall>
        let paid = payment180; payment180 = None<LogicalJsonOwnerReservation>; paid
    }
    func retireAfterActualConsumers180(): Unit {
        let paid = detachWholeInvocationData180()
        match (paid) { case Some(value) => value.close(); case None => () }
    }
}
