package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Pure comparisons exercise the original public snapshot codecs. These data
// fixtures cannot establish a Root, current Run or post-canonical Receipt;
// the separate ApplicationSession tests enter the actual canonical pipeline.
@Test
class PostCanonicalCheckpointSnapshot113Tests {
    @TestCase
    func completeOriginalContextWriterOracleIncludesReferencesExpiryAndUtf8(): Unit {
        let reference = ContextResourceReference("ref113", "file://actual-data113", content: Some("\u{0000}\n雪\\\""))
        let projection = InvocationContextProjection(contributions: [InvocationContextContribution(
            "owner113", "entry113", "data:113", "\u{0001}\t雪\\\"", ContextContentTrust.UntrustedData,
            references: [reference], validUntilMillis: 42)])
        let original = contextSnapshotValue(projection)
        @Expect(postCanonicalCheckpointContextMatches(original, projection))
        @Expect(postCanonicalCheckpointContextMatches(decodeStoredValue(encodeStoredValue(original)), projection))
        let changed = decodeStoredValue(encodeStoredValue(original))
        changed.field("contributions").getOrThrow().items[0].field("references").getOrThrow().items[0].put("locator", textValue("file://another"))
        @Expect(!postCanonicalCheckpointContextMatches(changed, projection))
    }

    @TestCase
    func wrongKindCannotMasqueradeAsTheOriginalEmptyTextOrDigest(): Unit {
        let projection = InvocationContextProjection()
        let original = contextSnapshotValue(projection)
        @Expect(postCanonicalCheckpointContextMatches(original, projection))
        original.put("source_digest", nullValue())
        var rejected = false
        try { rejected = !postCanonicalCheckpointContextMatches(original, projection) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected)
    }

    @TestCase
    func sameToolSetIdCannotSubstituteSchemaCapabilitiesIdentityOrHooks(): Unit {
        let toolSet = checkpointComparisonToolSet113()
        let lane = checkpointComparisonLane113(toolSet)
        let original = modelLaneSnapshotValue(lane)
        @Expect(postCanonicalCheckpointToolSetMatches(original, toolSet))
        for (field in ["name", "description", "executor_version", "implementation_fingerprint", "schema_digest"]) {
            let changed = decodeStoredValue(encodeStoredValue(original))
            changed.field("tools").getOrThrow().items[0].put(field, textValue("substituted113"))
            @Expect(!postCanonicalCheckpointToolSetMatches(changed, toolSet))
        }
        let schemaChanged = decodeStoredValue(encodeStoredValue(original))
        schemaChanged.field("tools").getOrThrow().items[0].field("input_schema").getOrThrow().put("changed", boolValue(true))
        @Expect(!postCanonicalCheckpointToolSetMatches(schemaChanged, toolSet))
        let capChanged = decodeStoredValue(encodeStoredValue(original))
        capChanged.field("tools").getOrThrow().items[0].field("capabilities").getOrThrow().items[0].put("resource", textValue("foreign113"))
        @Expect(!postCanonicalCheckpointToolSetMatches(capChanged, toolSet))
        let hookChanged = decodeStoredValue(encodeStoredValue(original))
        hookChanged.field("hooks").getOrThrow().items[0].put("command", textValue("different hook113"))
        @Expect(!postCanonicalCheckpointToolSetMatches(hookChanged, toolSet))
        @Expect(original.field("tool_set_id").getOrThrow().text, toolSet.id)
    }

    @TestCase
    func originalOldOptionalToolFieldsAndAbsentHooksKeepDecoderMeaning(): Unit {
        let toolSet = ToolSetSnapshot("old113", [ToolSnapshotEntry("read113", "old description", objectValue([]),
            "version113", [Capability(CapabilityKind.WorkspaceRead)])])
        let original = modelLaneSnapshotValue(checkpointComparisonLane113(toolSet))
        let tool = original.field("tools").getOrThrow().items[0]
        let fields: Array<ValueField> = [
            ValueField("name", tool.field("name").getOrThrow()),
            ValueField("description", tool.field("description").getOrThrow()),
            ValueField("input_schema", tool.field("input_schema").getOrThrow()),
            ValueField("executor_version", tool.field("executor_version").getOrThrow()),
            ValueField("capabilities", tool.field("capabilities").getOrThrow())]
        original.put("tools", listValue([objectValue(fields)]))
        // No hook field is required in old snapshots. Construct a new object
        // without changing the original decoder or introducing a new format.
        let withoutHooks = ArrayList<ValueField>()
        for (field in original.fields where field.name != "hooks") { withoutHooks.add(field) }
        let old = objectValue(withoutHooks.toArray())
        let decoded = modelLaneFromSnapshotValue(old)
        @Expect(postCanonicalCheckpointToolSetMatches(old, decoded.toolSet))
        @Expect(postCanonicalCheckpointToolSetMatches(old, toolSet))
    }
}

private func checkpointComparisonToolSet113(): ToolSetSnapshot {
    ToolSetSnapshot("same-id113", [ToolSnapshotEntry("read113", "description113", objectValue([]), "version113",
        [Capability(CapabilityKind.WorkspaceRead, resource: "original113")], implementationFingerprint: "implementation113")],
        hookHandlers: [ToolHookHandlerSnapshot("PostToolUse", "plugin113", "version113", "digest113", "root113", "*", "echo original113", 1)],
        threadId: Some(ThreadId("thread113")))
}
private func checkpointComparisonLane113(tools: ToolSetSnapshot): ModelLane {
    ModelLane(ModelLaneRole.Main, "provider113", "model113", "protocol113", ModelLaneCapabilitiesSnapshot(),
        1000, 10, 0, "estimator113", "retry113", "cache113", tools, "system113")
}
