package agent_product

import agent_domain.*
import agent_runtime.*
import agent_plugin_registry.PluginRegistry
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func copiedHookSnapshotProducer159k(probe: LogicalJsonOwnerReservation): OwnedToolSetSnapshot159 {
    let data = probe.deriveRetainedLease(); data.ensureRetainedPeak(1048576)
    let owner = OwnedToolSetSnapshot159(data)
    let schema = objectValue([ValueField("type", textValue("object")),
        ValueField("properties", objectValue([ValueField("text", objectValue([ValueField("type", textValue("string"))]))]))])
    let entry = ToolSnapshotEntry("plugin.pi:hookcopy159k.inspect", "nonempty schema 雪",
        schema, "hook-copy159k", [], implementationFingerprint: "hook-copy159k:frozen",
        schemaDigest: modelPolicySha256Text(canonicalAgentValue(schema)))
    let hooks = [
        ToolHookHandlerSnapshot("PreToolUse", "pi:hookcopy159k", "1.0.0", "digest-雪", "/fixture/雪", "*", "printf first", 7000),
        ToolHookHandlerSnapshot("PostToolUse", "pi:hookcopy159k", "1.0.0", "digest-雪", "/fixture/雪", "inspect", "must-not-select", 9000),
        ToolHookHandlerSnapshot("PreToolUse", "pi:hookcopy159k", "1.0.0", "digest-雪", "/fixture/雪", "inspect", "printf second", 11000),
        ToolHookHandlerSnapshot("PreToolUse", "pi:hookcopy159k", "1.0.0", "digest-雪", "/fixture/雪", "different", "must-not-select", 13000)
    ]
    owner.installSnapshot159(ToolSetSnapshot("actual-copied-hooks159k", [entry], hookHandlers: hooks))
    owner
}
private func copyFromReturnedSourceFrame159k(probe: LogicalJsonOwnerReservation): OwnedToolHookSelection159f {
    var produced = Some(copiedHookSnapshotProducer159k(probe))
    produced.getOrThrow().returnedSnapshotProducer159()
    var shared = Some(produced.getOrThrow().transferSharedSnapshot159())
    produced = None<OwnedToolSetSnapshot159>
    var context = Some(ToolInvocationContext(RunId("hook-copy159k"), SessionId("hook-session159k"),
        CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke, resource: "pi:hookcopy159k")]),
        ownedToolSetSnapshot159: Some(shared.getOrThrow().fork159())))
    let copied = context.getOrThrow().copyOwnedMatchingHooks159f("PreToolUse", "inspect").getOrThrow()
    // This is the genuine producer/share retirement path. No historical
    // snapshot getter, raw catalog export, fabricated Source or Root close.
    shared.getOrThrow().close159(); shared = None<SharedToolSetSnapshot159>
    context.getOrThrow().returnOwnedToolSetFrame159(); context = None<ToolInvocationContext>
    copied
}
private func copiedHookConsumerFrame159k(selection: OwnedToolHookSelection159f,
    probe: LogicalJsonOwnerReservation, earlyReturn: Bool): Unit {
    let handlers = selection.handlersForPrivateHookFrame159f()
    @Expect(handlers.size, 2)
    for (index in 0..handlers.size) {
        let value = handlers[index]
        @Expect(value.event, "PreToolUse"); @Expect(value.pluginId, "pi:hookcopy159k")
        @Expect(value.pluginVersion, "1.0.0"); @Expect(value.contentDigest, "digest-雪")
        @Expect(value.packageRoot, "/fixture/雪")
        @Expect(value.matcher, if (index == 0) { "*" } else { "inspect" })
        @Expect(value.command, if (index == 0) { "printf first" } else { "printf second" })
        @Expect(value.timeoutMillis, if (index == 0) { 7000 } else { 11000 })
    }
    if (earlyReturn) {
        let before = probe.retainedCustodyUsage113()
        @Expect(!selection.returnPrivateHookFrame159f())
        let after = probe.retainedCustodyUsage113()
        @Expect(after[0], before[0]); @Expect(after[2], before[2])
        // The actual entered DATA consumer remains usable after rejected
        // early retirement, including the ordered independently copied fields.
        @Expect(selection.handlersForPrivateHookFrame159f()[1].command, "printf second")
    }
}
private func copiedHookCyclesFrame159k(probe: LogicalJsonOwnerReservation, earlyReturn: Bool): Unit {
    let baseline = probe.retainedCustodyUsage113()
    for (_ in 0..16) {
        let selection = copyFromReturnedSourceFrame159k(probe)
        let copied = probe.retainedCustodyUsage113()
        @Expect(copied[0] > baseline[0]); @Expect(copied[2], baseline[2] + 1)
        selection.beginPrivateHookFrame159k()
        copiedHookConsumerFrame159k(selection, probe, earlyReturn)
        selection.endReturnedPrivateHookFrame159k()
        @Expect(selection.returnPrivateHookFrame159f())
        let current = probe.retainedCustodyUsage113()
        @Expect(current[0], baseline[0]); @Expect(current[2], baseline[2])
    }
}
private func copiedHookRegistryFrame159k(earlyReturn: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"hookcopy159k\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('NOT_EXECUTED');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("actual copied hook fixture import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try { copiedHookCyclesFrame159k(probe, earlyReturn); returned = true }
                finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}
@Test
class ActualCopiedHookSelection159kTests {
    @TestCase
    func actualNonemptySelectionKeepsAllFieldsAndOrderAfterOriginalSourceReturns159k(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { copiedHookRegistryFrame159k(false) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualEnteredHookConsumerPreventsEarlyRefundUntilWholeHelperReturns159k(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { copiedHookRegistryFrame159k(true) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
