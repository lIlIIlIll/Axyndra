package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import tool_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// This is DATA custody only. The actual ready Registry descriptor pays the
// header before the transport/response can exist. An unknown producer keeps
// its exact response registered; neither Product.close nor physical exit is ACK.
private class HostReadViewPreparationDebts204 {
    private let lock = Mutex()
    private var head: ?HostReadViewPreparationFrame204 = None
    func add(value: HostReadViewPreparationFrame204): Unit {
        lock.lock(); try { value.next = head; head = Some(value) } finally { lock.unlock() }
    }
    func remove(value: HostReadViewPreparationFrame204): Unit {
        lock.lock(); try {
            var previous: ?HostReadViewPreparationFrame204 = None
            var cursor = head
            while (cursor.isSome()) {
                let actual = cursor.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(prior) => prior.next = actual.next; case None => head = actual.next }
                    actual.next = None; return
                }
                previous = cursor; cursor = actual.next
            }
            throw IllegalStateException("actual preparation DATA debt is missing")
        } finally { lock.unlock() }
    }
}
private let hostReadViewPreparationDebts204 = HostReadViewPreparationDebts204()
class HostReadViewPreparationFrame204 {
    var next: ?HostReadViewPreparationFrame204 = None
    private var response: ?HostJavaScriptPluginInvocationResult = None
    init() { hostReadViewPreparationDebts204.add(this) }
    func capture(value: HostJavaScriptPluginInvocationResult): Unit {
        if (response.isSome()) { throw IllegalStateException("preparation already owns its actual response") }
        response = Some(value)
    }
    func releaseAfterProducerFrame204(): Unit {
        // The whole builder has returned. Its original proposal and errors
        // were copied into the independently prepaid canonical owner first.
        match (response) { case Some(value) => releaseWholePayloadHelper204(value); case None => () }
        response = None
        hostReadViewPreparationDebts204.remove(this)
    }
    private func releaseWholePayloadHelper204(value: HostJavaScriptPluginInvocationResult): Unit { value.releasePayload() }
}

func hostReadViewCanonicalData204(value: AgentValue, owner: ?ToolCanonicalArgumentsOwner204): Result<AgentValue> {
    match (owner) {
        case Some(actual) => actual.installProducerData204(value); Result.Ok(nullValue())
        case None => Result.Ok(value) }
}

func hostPrepareReadViewOwned204(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, tool: String, generation: UInt64, context: ToolInvocationContext,
    call: ToolCall): Result<ToolCanonicalArgumentsOwner204> {
    let descriptor = match (host.servicePackage(namespace, generation)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
    let paid = try { descriptor.deriveCopiedDataPayment(131072) } finally { descriptor.close() }
    let owner = try { ToolCanonicalArgumentsOwner204(paid) }
        catch (error: Exception) { paid.close(); throw error }
    let frame = HostReadViewPreparationFrame204()
    try {
        buildOwnedReadViewFrame204(host, settingsRoot, namespace, tool, generation, context, call, owner, frame)
        frame.releaseAfterProducerFrame204()
        owner.producerFrameReturned204()
        Result.Ok(owner)
    } catch (error: Exception) {
        // Unknown copy/producer/cleanup failure retains the original DATA.
        owner.holdUnknownConsumer204(); throw error
    }
}
private func buildOwnedReadViewFrame204(host: HostJavaScriptPluginHost, settingsRoot: String,
    namespace: String, tool: String, generation: UInt64, context: ToolInvocationContext,
    call: ToolCall, owner: ToolCanonicalArgumentsOwner204, frame: HostReadViewPreparationFrame204): Unit {
    match (hostPrepareReadViewFrame204(host, settingsRoot, namespace, tool, generation, context, call,
        Some(owner), Some(frame))) {
        case Result.Err(error) => owner.installProducerError204(error)
        case Result.Ok(_) => () }
}
