package agent_product

import agent_domain.*
import agent_plugin_registry.PluginRegistry
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func hookInputRecord159j(value: PluginRegistryResult<ProductPluginRecord>): ProductPluginRecord {
    match (value) {
        case PluginRegistryResult.Ok(record) => record
        case PluginRegistryResult.Err(error) =>
            try { throw IllegalStateException("actual hook input registry fixture is unavailable") }
            finally { error.close() }
    }
}
private func hookInputUsage159j(probe: LogicalJsonOwnerReservation, bytes: Int64, leases: Int64): Unit {
    let value = probe.retainedCustodyUsage113()
    @Expect(value[0], bytes); @Expect(value[2], leases)
}
private func hookInputLocalRefusalFrame159j(custody: ProductHookProcessCustody159f,
    root: String, cancelled: Bool): Unit {
    let parent = CancellationSource(deadlineMillis: agentUtcMillis() + 60000)
    let original = CancellationSource(parent: Some(parent.token))
    let processes = LocalProcessPort(LocalWorkspace(root), sandboxEnabled: false)
    try {
        if (cancelled) {
            let _ = parent.cancel(reason: Some(CancellationReason(CancellationReasonKind.User,
                "original.parent.reason", "原始取消 🙂", cancelledAtMillis: 12345)))
        }
        let source = custody.installParent159j(parent.token)
        @Expect(source.token.deadlineMillis, original.token.deadlineMillis)
        @Expect(source.token.isCancelled(), original.token.isCancelled())
        if (cancelled) {
            let expected = original.token.reason().getOrThrow()
            let actual = source.token.reason().getOrThrow()
            @Expect(actual.code, expected.code); @Expect(actual.message, expected.message)
            @Expect(actual.cancelledAtMillis, expected.cancelledAtMillis)
            @Expect(match (actual.kind) { case CancellationReasonKind.Parent => true; case _ => false })
        }
        custody.fundEventEncoding159j(objectValue([ValueField("text", textValue("输入 🙂\u{0}")),
            ValueField("numbers", listValue([integerValue(17), textValue("\\\"\n")]))]))
        // The real concrete LocalProcessPort must enforce its existing gate;
        // this control grants no process execution or sandbox-success credit.
        match (processes.executeCodexHook(OperationId("actual-hook-input-159j"), root,
            "printf SHOULD_NOT_RUN", "非空 stdin 🙂\n", 1000, source.token, custody159f: Some(custody))) {
            case Result.Ok(_) => @Expect(false)
            case Result.Err(error) => @Expect(error.code, "sandbox.hook_required")
        }
        custody.disposeParent159j()
        // Even the process helper and returning parent registration are not
        // the whole outer Hook consumer's return. This call must refuse.
        @Expect(!custody.returnPrivateHookProcessFrame159f())
    } finally { original.close(); parent.close(); let _ = processes.close() }
}
private func hookInputGenerationFrame159j(record: ProductPluginRecord, root: String,
    probe: LogicalJsonOwnerReservation, cancelled: Bool): Unit {
    let baseline = probe.retainedCustodyUsage113()
    let generation = createHookGeneration159g(record)
    try {
        for (_ in 0..16) {
            let custody = generation.acquireHookProcessResident159j()
            let resident = probe.retainedCustodyUsage113()
            custody.prepareCaller159j("pi:input159j", "1.0.0", "fixture-digest", root)
            let held = probe.retainedCustodyUsage113()
            @Expect(held[0] > resident[0]); @Expect(held[2], resident[2] + 1)
            hookInputLocalRefusalFrame159j(custody, root, cancelled)
            // Complete original Source/local-result/private argument frames
            // have returned; the concrete caller now supplies its last ACK.
            @Expect(!custody.privateInputsReturned159f())
            custody.wholeCallerReturned159j()
            @Expect(custody.privateInputsReturned159f())
            @Expect(custody.returnPrivateHookProcessFrame159f())
            hookInputUsage159j(probe, resident[0], resident[2])
        }
    } finally { generation.returnUnlinkedData159g() }
    // This resident never spawned a Future. Its actual generation link and
    // empty callback/input cell can therefore retire; spawned residents stay
    // paid under the separate explicit SDK metadata contract.
    hookInputUsage159j(probe, baseline[0], baseline[2])
}
private func hookInputRegistryFixture159j(cancelled: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"input159j\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('NOT_EXECUTED');".toArray())
        let record = hookInputRecord159j(registry.importLocal(root + "/source"))
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4194304)
            try { hookInputGenerationFrame159j(record, root, probe, cancelled) }
            finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}

@Test
class ActualHookInputResident159jTests {
    @TestCase
    func actualRegistryInputPhaseWaitsForWholeCallerAfterLocalSandboxRefusal159j(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { hookInputRegistryFixture159j(false) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualParentReturningRegistrationPreservesImmediateCancellationAndPrivatePhase159j(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { hookInputRegistryFixture159j(true) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
