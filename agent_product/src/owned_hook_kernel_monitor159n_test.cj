package agent_product

import agent_domain.*
import agent_plugin_registry.PluginRegistry
import std.collection.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private func monitorCustody159n(probe: LogicalJsonOwnerReservation): ProductHookProcessCustody159f {
    let paid = probe.deriveRetainedLease()
    paid.ensureRetainedPeak(32768)
    let actual = ProductHookProcessCustody159f(paid)
    @Expect(actual.claimActualHook159j())
    actual.prepareCaller159j("pi:monitor159n", "1.0.0", "actual-registry-derived", "/fixture")
    actual.fundKernelMonitor159n()
    actual
}
private func monitorReturnedCaller159n(actual: ProductHookProcessCustody159f): Unit {
    actual.wholeCallerReturned159j()
    @Expect(actual.privateInputsReturned159f())
    @Expect(actual.returnPrivateHookProcessFrame159f())
    // This fixture has no generation link; the sole private caller above
    // returned, and no callback or SDK action retains the custody carrier.
    actual.returnedGenerationLink159j()
}
private func normalMonitorActionFrame159n(actual: ProductHookProcessCustody159f, polled: AtomicInt64): Unit {
    actual.startKernelMonitor159n({ => let _ = polled.fetchAdd(1); 1 },
        { => throw IllegalStateException("a completed monitor must not cancel") })
    actual.joinMonitor159f()
}
private func normalMonitorCycle159n(probe: LogicalJsonOwnerReservation, polled: AtomicInt64): Unit {
    let actual = monitorCustody159n(probe)
    normalMonitorActionFrame159n(actual, polled)
    monitorReturnedCaller159n(actual)
}
private func expectMonitorBaseline159n(probe: LogicalJsonOwnerReservation, bytes: Int64, leases: Int64): Unit {
    let actual = probe.retainedCustodyUsage113()
    @Expect(actual[0], bytes); @Expect(actual[2], leases)
}
private func normalMonitorCycles159n(probe: LogicalJsonOwnerReservation): Unit {
    let polled = AtomicInt64(0)
    // One real invocation starts the one fixed resident. The baseline below
    // includes that resident; it never claims the SDK Future.fn was cleared.
    normalMonitorCycle159n(probe, polled)
    let baseline = probe.retainedCustodyUsage113()
    for (_ in 0..64) {
        normalMonitorCycle159n(probe, polled)
        expectMonitorBaseline159n(probe, baseline[0], baseline[2])
    }
    @Expect(polled.load(), 65)
}
private func awaitEightMonitorFrames159n(entered: AtomicInt64): Unit {
    let deadline = agentUtcMillis() + 5000
    while (entered.load() < 8 && agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
    @Expect(entered.load(), 8)
}
private func blockedMonitorActionsFrame159n(values: ArrayList<ProductHookProcessCustody159f>,
    entered: AtomicInt64, returned: AtomicInt64, release: AtomicBool,
    probe: LogicalJsonOwnerReservation): Unit {
    try {
        for (_ in 0..8) {
            let actual = monitorCustody159n(probe)
            values.add(actual)
            actual.startKernelMonitor159n({ => 2 }, { =>
                let _ = entered.fetchAdd(1)
                while (!release.load()) { sleep(Duration.millisecond) }
                let _ = returned.fetchAdd(1)
            })
        }
        awaitEightMonitorFrames159n(entered)
        @Expect(returned.load(), 0)
        let held = probe.retainedCustodyUsage113()
        for (actual in values) { @Expect(!actual.privateInputsReturned159f()) }
        // All eight cancellation workers are physically inside their callback
        // helpers. A different completed monitor must still reach its caller.
        let ordinary = AtomicInt64(0)
        normalMonitorCycle159n(probe, ordinary)
        @Expect(ordinary.load(), 1)
        @Expect(returned.load(), 0)
        expectMonitorBaseline159n(probe, held[0], held[2])
    } finally {
        release.store(true)
        for (actual in values) { actual.joinMonitor159f() }
    }
}
private func eightBlockedMonitorFrames159n(probe: LogicalJsonOwnerReservation): Unit {
    let warmup = AtomicInt64(0)
    normalMonitorCycle159n(probe, warmup)
    let baseline = probe.retainedCustodyUsage113()
    let values = ArrayList<ProductHookProcessCustody159f>()
    let entered = AtomicInt64(0); let returned = AtomicInt64(0); let release = AtomicBool(false)
    blockedMonitorActionsFrame159n(values, entered, returned, release, probe)
    @Expect(entered.load(), 8); @Expect(returned.load(), 8)
    for (actual in values) { monitorReturnedCaller159n(actual) }
    expectMonitorBaseline159n(probe, baseline[0], baseline[2])
}
private func monitorRegistryFixture159n(blocked: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"monitor159n\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('NOT_EXECUTED');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(actual) => actual
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("actual Hook monitor Registry is unavailable") } finally { error.close() }
        }
        try {
            // Pays fixture arrays, atomics and callback carriers before they
            // are created; each real custody phase pays its own monitor node.
            let probe = record.descriptor.deriveCopiedDataPayment(4194304)
            try {
                if (blocked) { eightBlockedMonitorFrames159n(probe) }
                else { normalMonitorCycles159n(probe) }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}

@Test
class ActualHookKernelMonitor159nTests {
    @TestCase
    func actual64ReturnedMonitorPhasesRestoreSameRegistryLedgerAfterFixedResidentWarmup159n(): Unit {
        monitorRegistryFixture159n(false)
    }
    @TestCase
    func actualEightBlockedCancellationFramesKeepPaidInputsWhileIndependentPollReturns159n(): Unit {
        monitorRegistryFixture159n(true)
    }
}
