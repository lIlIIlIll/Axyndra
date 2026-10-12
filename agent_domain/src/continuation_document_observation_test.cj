package agent_domain

import yjson.*
import yjson_support.*

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

func continuationObservationFixture(): AgentValue {
    let digest = String.fromUtf8(Array<Byte>(64, repeat: b'a'))
    let fields = ArrayList<ValueField>([
        ValueField("schema", textValue("axyndra.continuation-document-observation/v1")),
        ValueField("package_digest", textValue("sha256:" + digest)), ValueField("provider_generation", textValue("1")),
        ValueField("anchor_run_id", textValue("")), ValueField("anchor_claim_sha256", textValue("")),
        ValueField("observed_at_millis", integerValue(0)), ValueField("total_tokens", integerValue(0))])
    for (name in ["owner_digest", "original_document_sha256", "document_sha256", "selector_sha256", "query_sha256",
        "reply_sha256", "configuration_digest", "anchor_document_sha256"]) { fields.add(ValueField(name, textValue(digest))) }
    for (name in ["original_operation_id", "document_operation_id", "anchor_operation_id"]) { fields.add(ValueField(name, textValue("actual-operation"))) }
    for (name in ["original_receipt_id", "document_receipt_id"]) { fields.add(ValueField(name, textValue("actual-receipt"))) }
    for (name in ["original_run_id", "document_run_id"]) { fields.add(ValueField(name, textValue("actual-run"))) }
    fields.add(ValueField("provider", textValue("propose"))); fields.add(ValueField("parent_tool", textValue("plugin.axyndra:workflow.goal")))
    for (name in ["original_epoch", "original_revision", "document_epoch", "document_revision", "anchor_revision"]) {
        fields.add(ValueField(name, integerValue(1))) }
    let mutation = objectValue([ValueField("operation_id", textValue("actual-operation")), ValueField("receipt_id", textValue("actual-receipt")),
        ValueField("run_id", textValue("actual-run")), ValueField("epoch", integerValue(1)), ValueField("revision", integerValue(1)),
        ValueField("expected_sha256", textValue(digest)), ValueField("document_sha256", textValue(digest)),
        ValueField("plan_sha256", textValue(digest)), ValueField("result_sha256", textValue(digest))])
    fields.add(ValueField("chain", listValue([objectValue([ValueField("mutation", mutation),
        ValueField("query_sha256", textValue(digest)), ValueField("reply_sha256", textValue(digest))])])))
    objectValue(fields.toArray())
}

func continuationObservationRejected(value: AgentValue): Bool {
    try { let _ = ContinuationDocumentObservation(value); false } catch (_: Exception) { true }
}

@Test
class ContinuationDocumentObservationTests {
    @TestCase
    func observationDefensivelyFreezesNestedMutationArrays(): Unit {
        let source = continuationObservationFixture()
        let frozen = ContinuationDocumentObservation(source)
        let expected = canonicalAgentValue(frozen.value())
        source.field("chain").getOrThrow().items[0].field("mutation").getOrThrow().put("revision", integerValue(8))
        @Expect(canonicalAgentValue(frozen.value()), expected)
        let returned = frozen.value(); returned.put("owner_digest", textValue("changed"))
        @Expect(canonicalAgentValue(frozen.value()), expected)
    }

    @TestCase
    func truncatedReorderedOrUnanchoredChainsAreNotDescriptors(): Unit {
        for (mode in ["gap", "duplicate", "anchor", "type", "future", "unknown"]) {
            let value = continuationObservationFixture()
            if (mode == "gap") { value.put("document_revision", integerValue(2)) }
            else if (mode == "duplicate") { let item = value.field("chain").getOrThrow().items[0]; value.put("chain", listValue([item, item])) }
            else if (mode == "anchor") { value.put("anchor_operation_id", textValue("another-operation")) }
            else if (mode == "type") { value.field("chain").getOrThrow().items[0].field("mutation").getOrThrow().put("revision", textValue("1")) }
            else if (mode == "future") { value.put("schema", textValue("axyndra.continuation-document-observation/future")) }
            else { value.put("authority", boolValue(true)) }
            @Expect(continuationObservationRejected(value))
        }
    }

    @TestCase
    func priorClaimAnchorRequiresAnExactDigestAndRetainsOriginalIdentity(): Unit {
        let value = continuationObservationFixture()
        value.put("anchor_run_id", textValue("completed-prior-continuation"))
        @Expect(continuationObservationRejected(value))
        value.put("anchor_claim_sha256", value.field("owner_digest").getOrThrow())
        @Expect(!continuationObservationRejected(value))
        // This remains a data description. Only the actual Sqlite admission
        // transaction checks that this claimed old anchor exists and completed.
        @Expect(httpIntentText(ContinuationDocumentObservation(value).value(), "original_operation_id"), "actual-operation")
    }

    @TestCase
    func optionalObservationKeepsOldOriginShapeAndNewVersionRoundTripsExactly(): Unit {
        let digest = String.fromUtf8(Array<Byte>(64, repeat: b'a'))
        let old = ContinuationRunOrigin("thread", "main", "axyndra:workflow", "goal", "allowance", digest, digest,
            "prior", "next", "turn-next", "continuation-next", digest, digest, 1, 1, 0, 2)
        let value = continuationRunOriginValue(old)
        @Expect(httpIntentText(value, "schema"), "axyndra.continuation-run/v1")
        @Expect(value.field("document_observation").isNone())
        @Expect(sameContinuationRunOrigin(old, continuationRunOriginFromValue(value)))
        let newer = ContinuationRunOrigin("thread", "main", "axyndra:workflow", "goal", "allowance", digest, digest,
            "prior", "next", "turn-next", "continuation-next", digest, digest, 1, 1, 0, 2,
            documentObservation: Some(ContinuationDocumentObservation(continuationObservationFixture())))
        @Expect(httpIntentText(continuationRunOriginValue(newer), "schema"), "axyndra.continuation-run/v2")
        @Expect(sameContinuationRunOrigin(newer, continuationRunOriginFromValue(continuationRunOriginValue(newer))))
        @Expect(!sameContinuationRunOrigin(old, newer))
    }
}
