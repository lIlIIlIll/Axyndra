package agent_product

import agent_domain.*
import agent_runtime.*
import agent_plugin_registry.PluginRegistry
import tool_runtime.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*

private func emptyHookSnapshotProducer159f(probe: LogicalJsonOwnerReservation,
    nonmatching: Bool): OwnedToolSetSnapshot159 {
    let data = probe.deriveRetainedLease(); data.ensureRetainedPeak(1048576)
    let owner = OwnedToolSetSnapshot159(data)
    let schema = objectValue([ValueField("type", textValue("object")),
        ValueField("properties", objectValue([ValueField("text", objectValue([ValueField("type", textValue("string"))]))]))])
    let entry = ToolSnapshotEntry("plugin.pi:hookmatching159f.inspect", "nonempty matching 雪",
        schema, "hook-matching159f", [], implementationFingerprint: "hook-matching159f:frozen",
        schemaDigest: modelPolicySha256Text(canonicalAgentValue(schema)))
    let hooks: Array<ToolHookHandlerSnapshot> = if (nonmatching) { [ToolHookHandlerSnapshot(
        "PostToolUse", "pi:hookmatching159f", "1.0.0", "fixture-digest159f",
        "/fixture-hook-root159f", "other-tool159f", "must-not-execute", 5000)] } else { [] }
    owner.installSnapshot159(ToolSetSnapshot("actual-hook-matching159f", [entry], hookHandlers: hooks))
    owner
}

private func emptyHookSnapshotFrame159f(record: ProductPluginRecord,
    probe: LogicalJsonOwnerReservation, nonmatching: Bool): Unit {
    // Actual Registry invoice, original typed snapshot producer/transfer and
    // actual Product matcher. These private DATA fields grant no Tool Source.
    var produced = Some(emptyHookSnapshotProducer159f(probe, nonmatching))
    produced.getOrThrow().returnedSnapshotProducer159()
    var shared = Some(produced.getOrThrow().transferSharedSnapshot159())
    produced = None<OwnedToolSetSnapshot159>
    let capabilities = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke,
        resource: "pi:hookmatching159f"), Capability(CapabilityKind.WorkspaceWrite)])
    @Expect(shared.getOrThrow().hasAvailableTools159())
    var context = Some(ToolInvocationContext(RunId("hook-matching159f"), SessionId("hook-session159f"),
        capabilities, ownedToolSetSnapshot159: Some(shared.getOrThrow().fork159())))
    @Expect(context.getOrThrow().hasMatchingToolHook159f("PostToolUse", "other-tool159f"), nonmatching)
    @Expect(!context.getOrThrow().hasMatchingToolHook159f("PreToolUse", "other-tool159f"))
    let before = probe.retainedCustodyUsage113()
    for (_ in 0..32) {
        // Actual Product matching path, with a real nonempty paid snapshot. None
        // of these three lookups may export its complete historical graph.
        @Expect(matchingCodexHooks(context.getOrThrow(), "PreToolUse", "inspect").isEmpty())
        @Expect(matchingCodexHooks(context.getOrThrow(), "PostToolUse", "inspect").isEmpty())
        @Expect(matchingCodexHooks(context.getOrThrow(), "PostToolUse", "unregistered").isEmpty())
        let current = probe.retainedCustodyUsage113()
        @Expect(current[0], before[0]); @Expect(current[2], before[2])
    }
    shared.getOrThrow().close159(); shared = None<SharedToolSetSnapshot159>
    context.getOrThrow().returnOwnedToolSetFrame159(); context = None<ToolInvocationContext>
}

private func emptyHookRegistryFrame159f(nonmatching: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"hookmatching159f\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('MUST_NOT_EXECUTE');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("actual hook fixture import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try {
                    let before = probe.retainedCustodyUsage113()
                    emptyHookSnapshotFrame159f(record, probe, nonmatching)
                    let after = probe.retainedCustodyUsage113()
                    @Expect(after[0], before[0]); @Expect(after[2], before[2]); @Expect(after[1] >= before[1])
                    returned = true
                } finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}

@Test
class ActualEmptyHookMatching159fTests {
    @TestCase
    func actualNonemptyPaidSnapshotWithoutHooksRetiresAfterProductMatching159f(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { emptyHookRegistryFrame159f(false) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actualNonmatchingHookDoesNotExportSnapshotAndPreservesExactPredicate159f(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { emptyHookRegistryFrame159f(true) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
