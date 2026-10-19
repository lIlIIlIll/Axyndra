package agent_product

import agent_domain.*
import agent_runtime.*
import agent_plugin_registry.PluginRegistry
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func hookDiagnosticSelectionProducer159m(probe: LogicalJsonOwnerReservation): OwnedToolSetSnapshot159 {
    let paid = probe.deriveRetainedLease(); paid.ensureRetainedPeak(1048576)
    let owner = OwnedToolSetSnapshot159(paid)
    let schema = objectValue([ValueField("type", textValue("object"))])
    let entry = ToolSnapshotEntry("inspect", "original diagnostic source 雪", schema, "diag159m", [],
        implementationFingerprint: "diag159m:frozen", schemaDigest: modelPolicySha256Text(canonicalAgentValue(schema)))
    let hooks = [ToolHookHandlerSnapshot("PreToolUse", "pi:diag159m", "1.0.0", "digest", "/fixture", "*", "printf hook", 7000)]
    owner.installSnapshot159(ToolSetSnapshot("diagnostics-source159m", [entry], hookHandlers: hooks))
    owner
}
private func hookDiagnosticBufferSourceFrame159m(probe: LogicalJsonOwnerReservation): OwnedHookDiagnosticBuffer159m {
    var produced = Some(hookDiagnosticSelectionProducer159m(probe))
    produced.getOrThrow().returnedSnapshotProducer159()
    var shared = Some(produced.getOrThrow().transferSharedSnapshot159()); produced = None<OwnedToolSetSnapshot159>
    var context = Some(ToolInvocationContext(RunId("diag159m"), SessionId("diag-session159m"), CapabilitySet(values: []),
        ownedToolSetSnapshot159: Some(shared.getOrThrow().fork159())))
    let selection = context.getOrThrow().copyOwnedMatchingHooks159f("PreToolUse", "inspect").getOrThrow()
    shared.getOrThrow().close159(); shared = None<SharedToolSetSnapshot159>
    context.getOrThrow().returnOwnedToolSetFrame159(); context = None<ToolInvocationContext>
    selection.beginPrivateHookFrame159k()
    let actual = hookDiagnosticIndependentCopyFrame159m(selection)
    selection.endReturnedPrivateHookFrame159k()
    @Expect(selection.returnPrivateHookFrame159f())
    actual
}
private func hookDiagnosticIndependentCopyFrame159m(selection: OwnedToolHookSelection159f): OwnedHookDiagnosticBuffer159m {
    let original = ArrayList<String>()
    original.add("历史 🙂\u{0} first"); original.add("历史 \"quoted\" second")
    let actual = selection.createPrivateDiagnosticBuffer159m(original)
    original[0] = "replaced input backing"
    original.remove(at: 1)
    @Expect(actual.count159m(), 2)
    @Expect(actual.textEquals159m(0, "历史 🙂\u{0} first"))
    @Expect(actual.textEquals159m(1, "历史 \"quoted\" second"))
    actual
}
private func hookDiagnosticTurnoverFrame159m(value: OwnedHookDiagnosticBuffer159m,
    probe: LogicalJsonOwnerReservation, many: Bool): Unit {
    @Expect(value.count159m(), 2)
    @Expect(value.textEquals159m(0, "历史 🙂\u{0} first"))
    if (!many) {
        value.appendDiagnostic159m("PreToolUse", "pi:diag159m", "执行失败 🙂\u{0}")
        @Expect(value.count159m(), 3)
        @Expect(value.textEquals159m(2, "PreToolUse plugin pi:diag159m: 执行失败 🙂\u{0}"))
        return
    }
    var steadyBytes: Int64 = 0; var steadyLeases: Int64 = 0
    for (index in 0..512) {
        value.appendDiagnostic159m("PreToolUse", "pi:diag159m", "code-" + index.toString())
        @Expect(value.count159m(), min(128, index + 3))
        if (index == 255) {
            let actual = probe.retainedCustodyUsage113()
            steadyBytes = actual[0]; steadyLeases = actual[2]
        }
    }
    @Expect(value.count159m(), 128)
    @Expect(value.textEquals159m(0, "PreToolUse plugin pi:diag159m: code-384"))
    @Expect(value.textEquals159m(127, "PreToolUse plugin pi:diag159m: code-511"))
    let after = probe.retainedCustodyUsage113()
    // All retained codes in both windows have exactly three digits. Old
    // private rows truly retire instead of accumulating hidden caller debt.
    @Expect(after[0], steadyBytes); @Expect(after[2], steadyLeases)
}
private func hookDiagnosticCycles159m(probe: LogicalJsonOwnerReservation, many: Bool): Unit {
    let baseline = probe.retainedCustodyUsage113()
    for (_ in 0..4) {
        let value = hookDiagnosticBufferSourceFrame159m(probe)
        let copied = probe.retainedCustodyUsage113()
        @Expect(copied[2], baseline[2] + 3)
        hookDiagnosticTurnoverFrame159m(value, probe, many)
        let active = probe.retainedCustodyUsage113()
        @Expect(active[2], baseline[2] + 1 + (if (many) { 128 } else { 3 }))
        @Expect(value.returnPrivateBuffer159m())
        let returned = probe.retainedCustodyUsage113()
        @Expect(returned[0], baseline[0]); @Expect(returned[2], baseline[2])
    }
}
private func hookDiagnosticRegistryFixture159m(many: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json",
            "{\"name\":\"diag159m\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('NOT_EXECUTED');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(actual) => actual
            case PluginRegistryResult.Err(error) =>
                try { throw IllegalStateException("actual Hook diagnostic Registry is unavailable") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4194304)
            try { hookDiagnosticCycles159m(probe, many) } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}

@Test
class ActualHookDiagnostics159mTests {
    @TestCase
    func actualIndependentDiagnosticCopiesSurviveOriginalSelectionAndMutableInputReturn159m(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { hookDiagnosticRegistryFixture159m(false) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func actual512DiagnosticRowsKeepOriginal128OrderAndReclaimEveryPrivateEviction159m(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { hookDiagnosticRegistryFixture159m(true) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
