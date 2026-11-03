package agent_product

import agent_domain.*
import agent_plugin_registry.PluginRegistry
import std.fs.*
import std.sync.AtomicBool
import std.unittest.*
import std.unittest.testmacro.*

private func hookCancellationRecord159l(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) {
        case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual cancellation Registry fixture is unavailable") }
            finally { error.close() }
    }
}
private func hookCancellationUsage159l(probe: LogicalJsonOwnerReservation, bytes: Int64, leases: Int64): Unit {
    let value = probe.retainedCustodyUsage113()
    @Expect(value[0], bytes); @Expect(value[2], leases)
}
// This complete helper is the only local Source/token/callback consumer.
// On return the two actual registered batches retain the remaining references.
private func hookCancellationSourceFrame159l(custody: ProductHookProcessCustody159f,
    first: ProductHookCancellationBatch159g, second: ?ProductHookCancellationBatch159g): Unit {
    let parent = CancellationSource(deadlineMillis: agentUtcMillis() + 60000)
    let source = custody.installParent159j(parent.token)
    let observed = AtomicBool(false)
    let registration = source.token.onCancelReturning159({ reason =>
        @Expect(reason.code, "plugin.hook_snapshot_revoked")
        @Expect(reason.message, "plugin hook generation was disabled or replaced")
        @Expect(match (reason.kind) { case CancellationReasonKind.Failure => true; case _ => false })
        observed.store(true)
    })
    try {
        first.addOwnedSource159l(source, Some(custody))
        match (second) { case Some(value) => value.addOwnedSource159l(source, Some(custody)); case None => () }
        first.cancelSources159g()
        @Expect(observed.load())
        let original = source.token.reason().getOrThrow()
        @Expect(original.cancelledAtMillis > 0)
        match (second) { case Some(value) => value.cancelSources159g(); case None => () }
        let repeated = source.token.reason().getOrThrow()
        @Expect(repeated.code, original.code); @Expect(repeated.message, original.message)
        @Expect(repeated.cancelledAtMillis, original.cancelledAtMillis)
        @Expect(!custody.returnPrivateHookProcessFrame159f())
    } finally {
        registration.dispose()
        @Expect(registration.callbacksReturned159())
        custody.disposeParent159j()
        source.close(); parent.close()
    }
}
private func hookCancellationTwoBatches159l(record: ProductPluginRecord, root: String,
    probe: LogicalJsonOwnerReservation): Unit {
    let baseline = probe.retainedCustodyUsage113()
    let generation = createHookGeneration159g(record)
    try {
        let custody = generation.acquireHookProcessResident159j()
        let resident = probe.retainedCustodyUsage113()
        custody.prepareCaller159j("pi:cancel159l", "1.0.0", "digest", root)
        let phase = probe.retainedCustodyUsage113()
        @Expect(phase[0] > resident[0]); @Expect(phase[2], resident[2] + 1)
        let first = ProductHookCancellationBatch159g(generation.reserveCancellationFrame159g(1))
        let second = ProductHookCancellationBatch159g(generation.reserveCancellationFrame159g(1))
        let both = probe.retainedCustodyUsage113()
        @Expect(both[0], phase[0] + 2 * (1024 + 8192 + 512)); @Expect(both[2], phase[2] + 2)
        hookCancellationSourceFrame159l(custody, first, Some(second))
        custody.wholeCallerReturned159j()
        @Expect(!custody.privateInputsReturned159f())
        @Expect(!custody.returnPrivateHookProcessFrame159f())
        hookCancellationUsage159l(probe, both[0], both[2])
        first.returnComparisonFrame159g()
        hookCancellationUsage159l(probe, phase[0] + 1024 + 8192 + 512, phase[2] + 1)
        @Expect(!custody.privateInputsReturned159f())
        @Expect(!custody.returnPrivateHookProcessFrame159f())
        second.returnComparisonFrame159g()
        hookCancellationUsage159l(probe, phase[0], phase[2])
        @Expect(custody.privateInputsReturned159f())
        @Expect(custody.returnPrivateHookProcessFrame159f())
        hookCancellationUsage159l(probe, resident[0], resident[2])
    } finally { generation.returnUnlinkedData159g() }
    hookCancellationUsage159l(probe, baseline[0], baseline[2])
}
private func hookCancellationTwoPhases159l(record: ProductPluginRecord, root: String,
    probe: LogicalJsonOwnerReservation): Unit {
    let baseline = probe.retainedCustodyUsage113()
    let generation = createHookGeneration159g(record)
    try {
        let first = generation.acquireHookProcessResident159j()
        let second = generation.acquireHookProcessResident159j()
        let residents = probe.retainedCustodyUsage113()
        first.prepareCaller159j("pi:cancel159l", "1.0.0", "digest", root)
        let one = probe.retainedCustodyUsage113()
        second.prepareCaller159j("pi:cancel159l", "1.0.0", "digest", root)
        let two = probe.retainedCustodyUsage113()
        @Expect(two[0] - one[0], one[0] - residents[0]); @Expect(two[2], residents[2] + 2)
        let firstBatch = ProductHookCancellationBatch159g(generation.reserveCancellationFrame159g(1))
        let secondBatch = ProductHookCancellationBatch159g(generation.reserveCancellationFrame159g(1))
        hookCancellationSourceFrame159l(first, firstBatch, None<ProductHookCancellationBatch159g>)
        hookCancellationSourceFrame159l(second, secondBatch, None<ProductHookCancellationBatch159g>)
        first.wholeCallerReturned159j()
        firstBatch.returnComparisonFrame159g()
        @Expect(first.returnPrivateHookProcessFrame159f())
        hookCancellationUsage159l(probe, one[0] + 1024 + 8192 + 512, one[2] + 1)
        secondBatch.returnComparisonFrame159g()
        hookCancellationUsage159l(probe, one[0], one[2])
        // Returning the generation batch cannot replace this caller's ACK.
        @Expect(!second.privateInputsReturned159f())
        @Expect(!second.returnPrivateHookProcessFrame159f())
        second.wholeCallerReturned159j()
        @Expect(second.returnPrivateHookProcessFrame159f())
        hookCancellationUsage159l(probe, residents[0], residents[2])
    } finally { generation.returnUnlinkedData159g() }
    hookCancellationUsage159l(probe, baseline[0], baseline[2])
}
private func hookCancellationRegistryFixture159l(twoPhases: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"cancel159l\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('NOT_EXECUTED');".toArray())
        let record = hookCancellationRecord159l(registry.importLocal(root + "/source"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4194304)
            try {
                if (twoPhases) { hookCancellationTwoPhases159l(record, root, probe) }
                else { hookCancellationTwoBatches159l(record, root, probe) }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}

@Test
class ActualHookCancellationReturn159lTests {
    @TestCase
    func actualTwoBatchesHoldSameSourceUntilBothWholeArraysReturn159l(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { hookCancellationRegistryFixture159l(false) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualTwoInputPhasesRetireOnlyTheirOwnReturnedCaller159l(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { hookCancellationRegistryFixture159l(true) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
