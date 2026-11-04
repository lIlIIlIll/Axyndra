package agent_runtime

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class PlanReviewSnapshotTests {
    @TestCase
    func HistoricalCatalogsRemainUnsafeAndTrustedReviewFlagSurvivesRoundtrip(): Unit {
        let schema = objectValue([])
        let digest = modelPolicySha256Text(canonicalAgentValue(schema))
        let ordinary = ToolSnapshotEntry("fixture.read", "read metadata", schema, "1", [],
            implementationFingerprint: "fixture", schemaDigest: digest)
        let trusted = ToolSnapshotEntry("fixture.read", "read metadata", schema, "1", [],
            implementationFingerprint: "fixture", schemaDigest: digest, planReviewSafe: true)
        let old = ToolSetSnapshot("fixture", [ordinary])
        let current = ToolSetSnapshot("fixture", [trusted])
        @Expect(toolSetSnapshotContentDigest(old) != toolSetSnapshotContentDigest(current), true)
        let oldLane = ModelLane(ModelLaneRole.Main, "fixture", "fixture", "fixture", ModelLaneCapabilitiesSnapshot(),
            8192, 1024, 256, "fixture", "fixture", "fixture", old, "fixture")
        let oldValue = modelLaneSnapshotValue(oldLane)
        @Expect(oldValue.field("tools").getOrThrow().items[0].field("plan_review_safe").isNone(), true)
        @Expect(modelLaneFromSnapshotValue(oldValue).toolSet.entries[0].planReviewSafe, false)
        let currentValue = modelLaneSnapshotValue(modelLaneReplacingToolSet(oldLane, current))
        @Expect(modelLaneFromSnapshotValue(currentValue).toolSet.entries[0].planReviewSafe, true)
        @Expect(toolCatalogSnapshotValue(current).field("entries").getOrThrow().items[0]
            .field("plan_review_safe").getOrThrow().asBool(), true)
    }
}
