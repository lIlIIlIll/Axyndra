package agent_core

import agent_domain.*
import agent_runtime.*
import yjson.*
import std.sync.*

private let corePlanRequestDebts204 = CorePlanRequestDebts204()

// Independent DATA copies for the concrete PreparedModelRequest. The source
// inspection loan can return once construction ends; this payment cannot.
class CorePlanRequestData204 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    var next204: ?CorePlanRequestData204 = None<CorePlanRequestData204>
    init(payment: LogicalJsonOwnerReservation) {
        this.payment = Some(payment); corePlanRequestDebts204.retain204(this)
    }
    func fundBeforeRendering204(request: AgentRunRequest, state: AgentValue): Unit {
        lock.lock()
        try {
            let paid = payment.getOrThrow()
            // Existing context codec limits bound its contribution/reference
            // traversal arrays. Pay these headers before calling clone getters.
            paid.ensureRetainedPeak(1179648)
            let meter = ToolSnapshotMeasure159(paid)
            meter.addSlots159(8192)
            meter.addValue159(state)
            meter.addText159(request.system)
            meter.addText159(request.contextSnapshot.sourceDigest)
            for (item in request.contextSnapshot.contributions()) {
                meter.addText159(item.owner); meter.addText159(item.id)
                meter.addText159(item.sourceRef); meter.addText159(item.content)
                for (reference in item.references()) {
                    meter.addText159(reference.id); meter.addText159(reference.locator)
                    match (reference.content) { case Some(value) => meter.addText159(value); case None => () }
                    match (reference.contentDigest) { case Some(value) => meter.addText159(value); case None => () }
                }
            }
            meter.fund159()
        } finally { lock.unlock() }
    }
    // Only after PreparedModelRequest's entire concrete consumer returned and
    // its request field was cleared. Unknown construction keeps this debt.
    func returnPreparedFrame204(): Unit {
        let returned = clearReturnedFrame204()
        match (returned) { case Some(value) => value.close(); case None => () }
    }
    private func clearReturnedFrame204(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            let returned = payment; payment = None<LogicalJsonOwnerReservation>
            corePlanRequestDebts204.remove204(this)
            returned
        } finally { lock.unlock() }
    }
}

private class CorePlanRequestDebts204 {
    private let lock = Mutex()
    private var first: ?CorePlanRequestData204 = None<CorePlanRequestData204>
    func retain204(value: CorePlanRequestData204): Unit {
        lock.lock(); try { value.next204 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove204(value: CorePlanRequestData204): Unit {
        lock.lock()
        try {
            var previous: ?CorePlanRequestData204 = None<CorePlanRequestData204>
            var cursor = first
            while (cursor.isSome()) {
                let current = cursor.getOrThrow()
                if (refEq(current, value)) {
                    match (previous) { case Some(parent) => parent.next204 = current.next204; case None => first = current.next204 }
                    current.next204 = None<CorePlanRequestData204>; return
                }
                previous = cursor; cursor = current.next204
            }
        } finally { lock.unlock() }
    }
}
