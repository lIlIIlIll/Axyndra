package agent_plugin_registry

import agent_domain.*
import std.collection.*
import std.sync.*

// One startup pass only. The private constructor adopts a fully inspected
// installed state and its actual metadata snapshot generation. It cannot be
// restored from records, digests or caller-provided validation flags.
public class PluginRegistryStartupTransaction {
    private let lock = Mutex()
    private var state: ?PluginRegistryStartupState
    private var inUse = false
    private var closed = false

    init(state: PluginRegistryStartupState) { this.state = Some(state) }

    func withState<T>(custody: PluginRegistryMetadataCustody,
        action: (PluginRegistryStartupState) -> T): T {
        lock.lock()
        try {
            if (closed || inUse || !refEq(state.getOrThrow().custody, custody)) {
                throw PluginRegistryWriteError("plugin.registry_execution_stale",
                    "startup verification is closed, foreign or already in use")
            }
            inUse = true
        } finally { lock.unlock() }
        // All borrowed state and callback locals end in this complete frame.
        try { invokeStateFrame(action) }
        finally { returnedStateFrame() }
    }

    private func invokeStateFrame<T>(action: (PluginRegistryStartupState) -> T): T {
        let current = synchronized(lock) { state.getOrThrow() }
        action(current)
    }

    private func returnedStateFrame(): Unit {
        lock.lock()
        try { inUse = false } finally { lock.unlock() }
        collect()
    }

    public func close(): Unit {
        lock.lock()
        try { closed = true } finally { lock.unlock() }
        collect()
    }

    private func collect(): Unit {
        let retired = detachState()
        match (retired) { case Some(value) => value.retire(); case None => () }
    }

    private func detachState(): ?PluginRegistryStartupState {
        lock.lock()
        try {
            if (!closed || inUse) { return None }
            let retired = state; state = None; retired
        } finally { lock.unlock() }
    }
}

class PluginRegistryStartupState {
    let custody: PluginRegistryMetadataCustody
    let generation: PluginRegistryMetadataGeneration
    private var initial: ?PluginRegistryInitialState
    private var payment: ?PluginRegistryMetadataPayment
    private let consumed = HashSet<String>()

    init(custody: PluginRegistryMetadataCustody, generation: PluginRegistryMetadataGeneration,
        initial: PluginRegistryInitialState, payment: PluginRegistryMetadataPayment) {
        this.custody = custody; this.generation = generation
        this.initial = Some(initial); this.payment = Some(payment)
    }

    func inspectedState(): PluginRegistryInitialState { initial.getOrThrow() }

    // Registry's ordinary mutex serializes capture. Only an actual effective
    // record selected from this inspected state reaches this method.
    func consume(record: RawProductPluginRecord): Unit {
        let namespace = record.descriptor.namespace
        if (consumed.contains(namespace)) {
            throw PluginRegistryWriteError("plugin.registry_execution_stale",
                "startup verification cannot be reused for another activation")
        }
        consumed.add(namespace)
    }

    func retire(): Unit {
        let retained = clearStateFrame()
        generation.release(0)
        match (retained) { case Some(value) => value.close(); case None => () }
    }

    private func clearStateFrame(): ?PluginRegistryMetadataPayment {
        initial = None; consumed.clear()
        let retained = payment; payment = None; retained
    }
}

class PluginRegistryStartupOwnedPhase {
    var generation: ?PluginRegistryMetadataGeneration = None
    var payment: ?PluginRegistryMetadataPayment = None
    var transferred = false
}
