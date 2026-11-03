package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*

private let hostDirectGatewayFrames159e = HostDirectGatewayFrames159e()

// A private DATA carrier. The original snapshot fork funds its intrusive
// header before allocation; it cannot create a Run or grant a capability.
class HostDirectGatewayFrame159e {
    private let lock = Mutex()
    private var started: ?ActiveRunSnapshot = None<ActiveRunSnapshot>
    private var context: ?ToolInvocationContext = None<ToolInvocationContext>
    private var payment: ?SharedToolSetSnapshot159
    private var catalogConsumer204: ?ToolCatalogHostConsumer204 = None<ToolCatalogHostConsumer204>
    private var gatewayReturned = false
    private var ownerReturned = true
    private var retiring = false
    private var returned = false
    var next159e: ?HostDirectGatewayFrame159e = None<HostDirectGatewayFrame159e>
    init(payment: SharedToolSetSnapshot159) {
        this.payment = Some(payment)
        hostDirectGatewayFrames159e.add159e(this)
    }
    func bindCatalogConsumer204(value: ?ToolCatalogHostConsumer204): Unit {
        lock.lock()
        try {
            if (returned || retiring || catalogConsumer204.isSome()) { throw IllegalStateException("Catalog consumer already bound") }
            catalogConsumer204 = value
        } finally { lock.unlock() }
    }
    func observeCatalogResult204(result: Result<ToolInvocationResult>): Unit {
        // Only the Pipeline private execute consumer observes its result.
        ()
    }
    private func takeReturnedCatalogConsumerFrame204(): ?ToolCatalogHostConsumer204 {
        lock.lock()
        try {
            let value = catalogConsumer204; catalogConsumer204 = None<ToolCatalogHostConsumer204>
            value
        } finally { lock.unlock() }
    }
    func bindStarted159e(value: ActiveRunSnapshot): Unit {
        lock.lock()
        try {
            if (returned || retiring || started.isSome()) { throw IllegalStateException("gateway Run already bound or returned") }
            started = Some(value)
        } finally { lock.unlock() }
    }
    func bindContext159e(value: ToolInvocationContext): Unit {
        lock.lock()
        try {
            if (returned || retiring || context.isSome()) { throw IllegalStateException("gateway Context already bound or returned") }
            context = Some(value)
        } finally { lock.unlock() }
    }
    func expectOwnerReturn159e(): Unit {
        lock.lock()
        try {
            if (gatewayReturned || returned || retiring) { throw IllegalStateException("gateway already returned") }
            ownerReturned = false
        } finally { lock.unlock() }
    }
    func gatewayReturned159e(): Unit {
        lock.lock(); try { gatewayReturned = true } finally { lock.unlock() }
        collectReturned159e()
    }
    func ownerReturned159e(): Unit {
        lock.lock(); try { ownerReturned = true } finally { lock.unlock() }
        collectReturned159e()
    }
    func originalInputConsumersDetached180(): Bool {
        lock.lock(); try { returned && context.isNone() && started.isNone() && payment.isNone() && catalogConsumer204.isNone() } finally { lock.unlock() }
    }
    private func collectReturned159e(): Unit {
        lock.lock()
        let claimed = try {
            if (returned || retiring || !gatewayReturned || !ownerReturned) { false }
            else { retiring = true; true }
        } finally { lock.unlock() }
        if (!claimed) { return }
        try {
            // These are independently owned DATA views. Source cleanup and
            // Runtime's own lane are governed by their original separate gates.
            clearReturnedConsumersFrame159e()
            let catalogConsumer = takeReturnedCatalogConsumerFrame204()
            match (catalogConsumer) { case Some(value) => value.wholeHostCallerReturned204(); case None => () }
            let paid = detachReturnedPayment159e()
            hostDirectGatewayFrames159e.remove159e(this)
            match (paid) { case Some(value) => value.close159(); case None => () }
        } catch (error: Exception) {
            lock.lock(); try { retiring = false } finally { lock.unlock() }; throw error
        }
    }
    private func clearReturnedConsumersFrame159e(): Unit {
        match (context) { case Some(value) => value.returnOwnedToolSetFrame159(); case None => () }
        match (started) { case Some(value) => value.returnOwnedLaneView159(); case None => () }
        context = None<ToolInvocationContext>; started = None<ActiveRunSnapshot>
    }
    private func detachReturnedPayment159e(): ?SharedToolSetSnapshot159 {
        lock.lock()
        try {
            if (context.isSome() || started.isSome()) { throw IllegalStateException("gateway consumer aliases still live") }
            let result = payment; payment = None<SharedToolSetSnapshot159>
            returned = true; result
        } finally { lock.unlock() }
    }
}
private class HostDirectGatewayFrames159e {
    private let lock = Mutex()
    private var first: ?HostDirectGatewayFrame159e = None<HostDirectGatewayFrame159e>
    func add159e(value: HostDirectGatewayFrame159e): Unit {
        lock.lock(); try { value.next159e = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159e(value: HostDirectGatewayFrame159e): Unit {
        lock.lock()
        try {
            var previous: ?HostDirectGatewayFrame159e = None<HostDirectGatewayFrame159e>
            var current = first
            while (current.isSome()) {
                let actual = current.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) { case Some(parent) => parent.next159e = actual.next159e; case None => first = actual.next159e }
                    actual.next159e = None<HostDirectGatewayFrame159e>; return
                }
                previous = current; current = actual.next159e
            }
            throw IllegalStateException("gateway DATA frame was not registered")
        } finally { lock.unlock() }
    }
}
func hostCreateDirectGatewayFrame159e(lane: ModelLane): ?HostDirectGatewayFrame159e {
    // fork159 reserves its 4096-byte original-bank header before this carrier,
    // mutex and intrusive node; all variable lane/context data owns other shares.
    let paid = lane.forkOwnedToolSetSnapshot159()
    match (paid) { case Some(value) => Some(HostDirectGatewayFrame159e(value)); case None => None<HostDirectGatewayFrame159e> }
}
func hostGatewayModelLane159e(catalog: ToolCatalog, run: RunId, capabilities: CapabilitySet,
    ordinary: Bool, thread: ThreadId): ModelLane {
    if (!ordinary) {
        return hostControlModelLane(run, capabilities, threadId: Some(thread)) }
    let snapshot = catalog.sharedDirectToolSetSnapshot159e(run, capabilities, threadId: Some(thread))
    match (snapshot) {
        case Some(value) =>
            // Prepay the fixed capabilities carrier before constructing it.
            let phase = value.forkInvocationView159()
            let lane = hostSharedControlLaneFrame159e(value)
            phase.close159(); value.close159(); lane
        case None => hostControlModelLane(run, capabilities, threadId: Some(thread),
            snapshot: Some(catalog.toolSetSnapshot("direct-delegation-" + run.value, capabilities, threadId: Some(thread))))
    }
}
private func hostSharedControlLaneFrame159e(snapshot: SharedToolSetSnapshot159): ModelLane {
    modelLaneWithSharedToolSet159(ModelLaneRole.Main, "direct-control", "none", "direct-control-v1",
        ModelLaneCapabilitiesSnapshot(streaming: false, tools: true, reasoning: false,
            structuredOutput: false, imageInput: false, promptCache: false, providerOpaqueState: false),
        4096, 1024, 128, "direct-control-v1", "never", "none", snapshot, "direct-control-v1")
}
