package agent_product

import agent_domain.*
import agent_runtime.*
import agent_plugin_registry.PluginRegistry
import yjson.JsonNode
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func checkpointSnapshot185(): ToolSetSnapshot {
    let schema = objectValue([ValueField("type", textValue("object")),
        ValueField("properties", objectValue([ValueField("雪", objectValue([ValueField("type", textValue("string"))]))]))])
    ToolSetSnapshot("same-checkpoint185", [ToolSnapshotEntry("read185", "complete description 雪", schema, "version185",
        [Capability(CapabilityKind.WorkspaceRead, resource: "actual185"), Capability(CapabilityKind.PeerMessage, resource: "peer185")],
        implementationFingerprint: "fingerprint185", schemaDigest: modelPolicySha256Text(canonicalAgentValue(schema)))],
        threadId: Some(ThreadId("thread185")), hookHandlers: [
            ToolHookHandlerSnapshot("PreToolUse", "plugin185", "1", "digest185", "/original185", "*", "echo first185", 42),
            ToolHookHandlerSnapshot("PostToolUse", "plugin185", "2", "digest186", "/original186", "read185", "echo second185", 43)])
}
private func checkpointLane185(tools: ToolSetSnapshot): ModelLane {
    ModelLane(ModelLaneRole.Main, "provider185", "model185", "protocol185", ModelLaneCapabilitiesSnapshot(),
        1000, 10, 0, "estimator185", "retry185", "cache185", tools, "system185")
}
private func checkpointSourceProducer185(probe: LogicalJsonOwnerReservation, oldCodec: Bool): OwnedToolSetSnapshot159 {
    let data = probe.deriveRetainedLease(); data.ensureRetainedPeak(1048576)
    let owner = OwnedToolSetSnapshot159(data)
    owner.installSnapshot159(if (oldCodec) { ToolSetSnapshot("old-checkpoint185", [
        ToolSnapshotEntry("read185", "old complete description", objectValue([]), "version185", [Capability(CapabilityKind.WorkspaceRead)])])
    } else { checkpointSnapshot185() })
    owner
}
private func checkpointOwnedCompareFrame185(shared: SharedToolSetSnapshot159, oldCodec: Bool): Unit {
    let raw = if (oldCodec) { ToolSetSnapshot("old-checkpoint185", [
        ToolSnapshotEntry("read185", "old complete description", objectValue([]), "version185", [Capability(CapabilityKind.WorkspaceRead)])])
    } else { checkpointSnapshot185() }
    let lane = modelLaneSnapshotValue(checkpointLane185(raw))
    @Expect(shared.matchesStoredModelLane185(lane))
    if (oldCodec) {
        let tool = lane.field("tools").getOrThrow().items[0]
        lane.put("tools", listValue([objectValue([
            ValueField("name", tool.field("name").getOrThrow()), ValueField("description", tool.field("description").getOrThrow()),
            ValueField("input_schema", tool.field("input_schema").getOrThrow()), ValueField("executor_version", tool.field("executor_version").getOrThrow()),
            ValueField("capabilities", tool.field("capabilities").getOrThrow())])]))
        let oldFields = ArrayList<ValueField>()
        for (field in lane.fields where field.name != "hooks") { oldFields.add(field) }
        @Expect(shared.matchesStoredModelLane185(objectValue(oldFields.toArray())))
    } else {
        for (name in ["name", "description", "executor_version", "implementation_fingerprint", "schema_digest"]) {
            let changed = modelLaneSnapshotValue(checkpointLane185(checkpointSnapshot185()))
            changed.field("tools").getOrThrow().items[0].put(name, textValue("same-id-substitution185"))
            @Expect(!shared.matchesStoredModelLane185(changed))
        }
        let schema = modelLaneSnapshotValue(checkpointLane185(checkpointSnapshot185()))
        schema.field("tools").getOrThrow().items[0].field("input_schema").getOrThrow().put("changed", boolValue(true))
        @Expect(!shared.matchesStoredModelLane185(schema))
        let caps = modelLaneSnapshotValue(checkpointLane185(checkpointSnapshot185()))
        caps.field("tools").getOrThrow().items[0].field("capabilities").getOrThrow().items[1].put("resource", textValue("foreign185"))
        @Expect(!shared.matchesStoredModelLane185(caps))
        let hooks = modelLaneSnapshotValue(checkpointLane185(checkpointSnapshot185()))
        hooks.field("hooks").getOrThrow().items[1].put("command", textValue("foreign185"))
        @Expect(!shared.matchesStoredModelLane185(hooks))
        let thread = modelLaneSnapshotValue(checkpointLane185(checkpointSnapshot185()))
        thread.put("tool_set_thread_id", textValue("foreign185"))
        @Expect(!shared.matchesStoredModelLane185(thread))
        let available = modelLaneSnapshotValue(checkpointLane185(checkpointSnapshot185()))
        available.field("tools").getOrThrow().items[0].put("available_at_snapshot", boolValue(false))
        @Expect(!shared.matchesStoredModelLane185(available))
    }
}
private func checkpointOwnedCycles185(probe: LogicalJsonOwnerReservation, oldCodec: Bool): Unit {
    let baseline = probe.retainedCustodyUsage113()
    for (_ in 0..16) {
        var produced = Some(checkpointSourceProducer185(probe, oldCodec))
        produced.getOrThrow().returnedSnapshotProducer159()
        var shared = Some(produced.getOrThrow().transferSharedSnapshot159())
        produced = None<OwnedToolSetSnapshot159>
        var independent = Some(shared.getOrThrow().fork159())
        shared.getOrThrow().close159(); shared = None<SharedToolSetSnapshot159>
        // The original source share is genuinely closed; the synchronous
        // independent closed comparison still verifies all original fields.
        for (_ in 0..8) {
            let held = probe.retainedCustodyUsage113()
            checkpointOwnedCompareFrame185(independent.getOrThrow(), oldCodec)
            let returned = probe.retainedCustodyUsage113()
            @Expect(returned[0], held[0]); @Expect(returned[2], held[2])
        }
        independent.getOrThrow().close159(); independent = None<SharedToolSetSnapshot159>
        let returned = probe.retainedCustodyUsage113()
        @Expect(returned[0], baseline[0]); @Expect(returned[2], baseline[2])
    }
}
private func checkpointActualRegistry185(oldCodec: Bool): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let registry = PluginRegistry(root + "/settings", root)
    try {
        Directory.create(root + "/source/extensions", recursive: true)
        File.writeTo(root + "/source/package.json", "{\"name\":\"checkpoint185\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"extensions/index.js\"]}}".toArray())
        File.writeTo(root + "/source/extensions/index.js", "throw new Error('NOT_EXECUTED');".toArray())
        let record = match (registry.importLocal(root + "/source")) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => try { throw IllegalStateException("actual checkpoint fixture import failed") } finally { error.close() }
        }
        try {
            let probe = record.descriptor.deriveCopiedDataPayment(4096)
            try {
                let fixture = probe.deriveRetainedLease(); fixture.ensureRetainedPeak(4194304)
                var returned = false
                try { checkpointOwnedCycles185(probe, oldCodec); returned = true }
                finally { if (returned) { fixture.close() } }
            } finally { probe.close() }
        } finally { record.close() }
    } finally { try { registry.close() } finally { remove(root, recursive: true) } }
}
@Test
class ActualOwnedCheckpointSnapshot185Tests {
    @TestCase
    func realRegistryIndependentShareChecksAllStoredFieldsAndReturnsSameBank185(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { checkpointActualRegistry185(false) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
    @TestCase
    func realRegistryClosedLoanKeepsOriginalOptionalFieldAndAbsentHookSemantics185(): Unit {
        let before = productControlMetadataUsage113()
        let fixture = reserveProductControlMetadata113(65536)
        try { checkpointActualRegistry185(true) } finally { fixture.close() }
        let after = productControlMetadataUsage113()
        @Expect(after[0], before[0]); @Expect(after[1], before[1])
    }
}
