package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_plugin_registry.*
import process4cj as process
import std.sync.*

private let hostRegistryMountDataDebt159 = HostRegistryMountDataDebt159()

// Private DATA custody for the real launch/dispatch adapters. This is derived
// from the descriptor's original Registry allocation; it grants no authority.
// The full descriptor/request/catalog graph is a separate, still-live owner.
// Removing its aliases from these adapters does not retire that larger graph.
class HostRegistryMountData159 {
    private let lock = Mutex()
    private var payment: ?LogicalJsonOwnerReservation
    private var launchReturned = false
    private var dispatchRetired = false
    private var opaqueFailure = false
    var nextRetained159: ?HostRegistryMountData159 = None

    init(payment: LogicalJsonOwnerReservation) { this.payment = Some(payment) }

    func deriveError159(invoice: Int64): LogicalJsonOwnerReservation {
        lock.lock()
        try {
            let original = match (payment) {
                case Some(value) => value
                case None => throw LogicalJsonPayloadError("registry dispatch data is retired")
            }
            let child = original.deriveRetainedLease()
            try { child.ensureRetainedPeak(invoice); child }
            catch (error: Exception) { child.close(); throw error }
        } finally { lock.unlock() }
    }

    func returnedLaunch159(opaque!: Bool = false): Unit {
        lock.lock()
        try { launchReturned = true; opaqueFailure = opaqueFailure || opaque }
        finally { lock.unlock() }
        collect159()
    }

    func retiredDispatch159(): Unit {
        lock.lock(); try { dispatchRetired = true } finally { lock.unlock() }
        collect159()
    }

    private func collect159(): Unit {
        let retired = detach159()
        match (retired) {
            case None => ()
            case Some(value) =>
                // detach159 returned after clearing our actual payment field.
                // The list helper clears its private node link before return.
                hostRegistryMountDataDebt159.remove159(this)
                value.close()
        }
    }

    private func detach159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            if (!launchReturned || !dispatchRetired || opaqueFailure) { return None }
            let original = payment
            payment = None
            original
        } finally { lock.unlock() }
    }
}

// Intrusive nodes are inside the prepaid holder. No growing uncharged vector
// is left behind after successful retirement. Unknown launch failure stays
// held; neither an exception nor a process signal is a DATA acknowledgment.
private class HostRegistryMountDataDebt159 {
    private let lock = Mutex()
    private var head: ?HostRegistryMountData159 = None
    func retain159(value: HostRegistryMountData159): Unit {
        lock.lock()
        try { value.nextRetained159 = head; head = Some(value) }
        finally { lock.unlock() }
    }
    func remove159(value: HostRegistryMountData159): Unit {
        lock.lock()
        try {
            var current = head
            var previous: ?HostRegistryMountData159 = None
            while (current.isSome()) {
                let selected = current.getOrThrow()
                if (refEq(selected, value)) {
                    match (previous) {
                        case None => head = selected.nextRetained159
                        case Some(parent) => parent.nextRetained159 = selected.nextRetained159
                    }
                    selected.nextRetained159 = None
                    return
                }
                previous = current
                current = selected.nextRetained159
            }
        } finally { lock.unlock() }
    }
}

func hostRegistryMountData159(descriptor: PluginPackageDescriptor): HostRegistryMountData159 {
    // Payment precedes holder, adapter and list-node construction. The fixed
    // amount covers only these fixed cells, never descriptor/string copies.
    let payment = hostRegistryDeriveCopiedData159(descriptor, 16384)
    hostRetainRegistryMountData159(payment)
}
func hostRetainRegistryMountData159(payment: LogicalJsonOwnerReservation): HostRegistryMountData159 {
    // Shared by the production Registry-derived payment and the real-bank
    // DATA controls. This does not accept a Source or an execution pin.
    try { payment.ensureRetainedPeak(16384) }
    catch (error: Exception) { payment.close(); throw error }
    let value = HostRegistryMountData159(payment)
    hostRegistryMountDataDebt159.retain159(value)
    value
}

func hostStartRegistryJavaScriptHost159(
    descriptor: PluginPackageDescriptor,
    generation: UInt64,
    launcher: JavaScriptHostProcessLauncher,
    pin: PluginRegistryExecutionPin,
    timeoutMillis!: Int64 = 30000,
    cancellation!: ?process.CancellationToken = None,
    serviceLimits!: ?ServiceProtocolLimits = None,
    payloadLimits!: ?ServicePayloadLimits = None,
    ordinaryToolPayload!: Bool = false,
    providerSequence!: Bool = false,
    contextSequence!: Bool = false
): JavaScriptHostResult<JavaScriptExtensionHost> {
    let data = try { hostRegistryMountData159(descriptor) }
    catch (_: LogicalJsonPayloadError) {
        return JavaScriptHostResult.Err(JavaScriptHostError("plugin.registry_metadata_capacity",
            "registry dispatch metadata cannot fit the original shared capacity"))
    }
    // All temporary adapter references live in a separate real call frame.
    let result = try {
        hostStartRegistryJavaScriptFrame159(descriptor, generation, launcher, pin, data,
            timeoutMillis, cancellation, serviceLimits, payloadLimits,
            ordinaryToolPayload, providerSequence, contextSequence)
    } catch (error: Exception) {
        data.returnedLaunch159(opaque: true)
        throw error
    }
    match (result) {
        case JavaScriptHostResult.Err(error) =>
            if (error.cleanupHost.isNone()) { data.retiredDispatch159() }
        case JavaScriptHostResult.Ok(_) => ()
    }
    data.returnedLaunch159()
    result
}

private func hostStartRegistryJavaScriptFrame159(
    descriptor: PluginPackageDescriptor, generation: UInt64,
    launcher: JavaScriptHostProcessLauncher, pin: PluginRegistryExecutionPin,
    data: HostRegistryMountData159, timeoutMillis: Int64,
    cancellation: ?process.CancellationToken, serviceLimits: ?ServiceProtocolLimits,
    payloadLimits: ?ServicePayloadLimits, ordinaryToolPayload: Bool,
    providerSequence: Bool, contextSequence: Bool
): JavaScriptHostResult<JavaScriptExtensionHost> {
    hostStartJavaScriptHost(descriptor, generation, HostRegistryProcessLauncher(launcher, pin, data),
        dispatchFence: Some(HostRegistryDispatchFence(pin, data)), timeoutMillis: timeoutMillis,
        cancellation: cancellation, serviceLimits: serviceLimits, payloadLimits: payloadLimits,
        ordinaryToolPayload: ordinaryToolPayload, providerSequence: providerSequence,
        contextSequence: contextSequence)
}
