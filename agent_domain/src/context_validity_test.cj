package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func contextValidityTestSnapshot(deadline!: Int64 = 0): InvocationContextProjection {
    InvocationContextProjection(contributions: [InvocationContextContribution("provider", "content", "frozen:content",
        "Immutable content", ContextContentTrust.UntrustedData, validUntilMillis: deadline)])
}

@Test
class ContextValidityTests {
    @TestCase
    func originalShapeRemainsExactAndHistoryPreservesAnExpiredDeadline(): Unit {
        let original = contextSnapshotValue(contextValidityTestSnapshot())
        @Expect(original.field("contributions").getOrThrow().items[0].fields.size, 7)
        @Expect(original.field("contributions").getOrThrow().items[0].field("valid_until_millis").isNone())
        @Expect(canonicalAgentValue(contextSnapshotValue(contextSnapshotFromValue(original))), canonicalAgentValue(original))
        let expired = contextSnapshotValue(contextValidityTestSnapshot(deadline: 1))
        let restored = contextSnapshotFromValue(expired)
        @Expect(restored.contributions()[0].validUntilMillis, 1)
        @Expect(canonicalAgentValue(contextSnapshotValue(restored)), canonicalAgentValue(expired))
        @Expect(validateContextSnapshotUse(restored).error().getOrThrow().code, "context.contribution_expired")
        @Expect(validateContextSnapshotUse(contextValidityTestSnapshot()).isOk())
        @Expect(validateContextSnapshotUse(contextValidityTestSnapshot(deadline: Int64.Max)).isOk())
    }
    @TestCase
    func optionalDeadlineRejectsWrongTypesNoncanonicalValuesAndUnknownFields(): Unit {
        for (invalid in [integerValue(0), integerValue(-1), numberValue("1.0"), numberValue("1e3"),
            numberValue("9223372036854775808"), textValue("1"), boolValue(true), nullValue()]) {
            let value = contextSnapshotValue(contextValidityTestSnapshot())
            value.field("contributions").getOrThrow().items[0].put("valid_until_millis", invalid)
            var rejected = false
            try { let _ = contextSnapshotFromValue(value) } catch (_: Exception) { rejected = true }
            @Expect(rejected)
        }
        let value = contextSnapshotValue(contextValidityTestSnapshot(deadline: Int64.Max))
        value.field("contributions").getOrThrow().items[0].put("authority", boolValue(true))
        var rejected = false
        try { let _ = contextSnapshotFromValue(value) } catch (_: Exception) { rejected = true }
        @Expect(rejected)
    }
    @TestCase
    func anyExpiredContributionRejectsUseWithoutRewritingAnyFrozenData(): Unit {
        let snapshot = InvocationContextProjection(contributions: [contextValidityTestSnapshot().contributions()[0],
            InvocationContextContribution("other", "deadline", "frozen:other", "Second content",
                ContextContentTrust.UserSelected, validUntilMillis: 1)])
        let before = canonicalAgentValue(contextSnapshotValue(snapshot))
        @Expect(validateContextSnapshotUse(snapshot).isError())
        @Expect(canonicalAgentValue(contextSnapshotValue(snapshot)), before)
        @Expect(systemWithContextSnapshot("System", snapshot).contains("Second content"))
    }
}
