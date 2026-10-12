package agent_host_runtime

import tool_runtime.*
import std.sync.*

private let hostLiveInvocationContexts159 = HostLiveInvocationContexts159()

// Registered before a producer receives this independent paid Context. A
// failed output/physical cleanup keeps the precise carrier reachable here.
private class HostLiveInvocationContexts159 {
    private let lock = Mutex()
    private var first: ?HostLiveInvocationContext159 = None<HostLiveInvocationContext159>
    func add159(value: HostLiveInvocationContext159): Unit {
        lock.lock(); try { value.next159 = first; first = Some(value) } finally { lock.unlock() }
    }
    func remove159(value: HostLiveInvocationContext159): Unit {
        lock.lock(); try {
            var previous: ?HostLiveInvocationContext159 = None<HostLiveInvocationContext159>
            var current = first
            while (current.isSome()) {
                let actual = current.getOrThrow()
                if (refEq(actual, value)) {
                    match (previous) {
                        case Some(parent) => parent.next159 = actual.next159
                        case None => first = actual.next159
                    }
                    actual.next159 = None<HostLiveInvocationContext159>
                    return
                }
                previous = current; current = actual.next159
            }
            throw IllegalStateException("actual live Context debt was not registered")
        } finally { lock.unlock() }
    }
}

class HostLiveInvocationContext159 {
    // One prepaid intrusive slot. Returning a node leaves no overallocated
    // global array capacity whose funding could outlive the remaining nodes.
    var next159: ?HostLiveInvocationContext159 = None<HostLiveInvocationContext159>
    private let lock = Mutex()
    private var actual: ?ToolInvocationContext
    private var transferred = false
    private var producerReturned = false
    private var consumerReturned = false
    init(actual: ToolInvocationContext) { this.actual = Some(actual) }
    func context159(): ToolInvocationContext {
        lock.lock(); try { actual.getOrThrow() } finally { lock.unlock() }
    }
    func transfer159(): Unit {
        lock.lock(); try {
            if (actual.isNone() || transferred || producerReturned) {
                throw IllegalStateException("live guard Context transfer changed") }
            transferred = true
        } finally { lock.unlock() }
    }
    func producerReturned159(): Unit { finish159(false) }
    func consumerReturned159(): Unit { finish159(true) }
    private func finish159(consumer: Bool): Unit {
        let returned = detachReturned159(consumer)
        match (returned) {
            case Some(value) =>
                hostLiveInvocationContexts159.remove159(this)
                value.returnOwnedToolSetFrame159()
            case None => ()
        }
    }
    private func detachReturned159(consumer: Bool): ?ToolInvocationContext {
        lock.lock(); try {
            if (consumer) { consumerReturned = true } else { producerReturned = true }
            if (!producerReturned || (transferred && !consumerReturned)) {
                return None<ToolInvocationContext> }
            let returned = actual
            actual = None<ToolInvocationContext>
            returned
        } finally { lock.unlock() }
    }
}

func hostRetainLiveInvocationContext159(context: ToolInvocationContext): ?HostLiveInvocationContext159 {
    if (!context.hasOwnedToolSetSnapshot159()) { return None<HostLiveInvocationContext159> }
    // Original bank pays the Context and this fixed carrier/registry slot
    // before either allocation. No independent pool, Source or budget exists.
    let retained = context.retainInvocationContext159()
    try {
        let value = HostLiveInvocationContext159(retained)
        hostLiveInvocationContexts159.add159(value)
        Some(value)
    } catch (error: Exception) { retained.returnOwnedToolSetFrame159(); throw error }
}
func hostLiveInvocationContext159(frame: ?HostLiveInvocationContext159,
    original: ToolInvocationContext): ToolInvocationContext {
    match (frame) { case Some(value) => value.context159(); case None => original }
}
func hostLiveInvocationProducerReturned159(frame: ?HostLiveInvocationContext159): Unit {
    match (frame) { case Some(value) => value.producerReturned159(); case None => () }
}
