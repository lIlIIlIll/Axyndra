package agent_product

import agent_domain.*
import agent_store.*
import agent_runtime.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func policyReferenceRejected(action: () -> Unit): Bool {
    try { action(); false } catch (_: Exception) { true }
}
func capacityCheckpointPayload(text: String): AgentValue {
    objectValue([ValueField("structured_summary", objectValue([ValueField("deterministic_summary", textValue(text))])), ValueField("active_state", objectValue([])),
        ValueField("active_goal", textValue("")), ValueField("durable_notes", listValue([])), ValueField("artifact_references", listValue([]))])
}
@Test
class PolicyDataReferenceTests {
    @TestCase
    func frozenSourcesAndStreamingCanonicalDigestMatchOriginalCodec(): Unit {
        let owner = ProductPolicyDataReferences("data-owner")
        try {
            let mutable = objectValue([ValueField("z", listValue([textValue("snow 雪\u{0}"), integerValue(7)])),
                ValueField("a", objectValue([ValueField("q", boolValue(true)), ValueField("nil", nullValue())]))])
            let frozen = owner.freeze(mutable)
            let expected = modelPolicySha256Text(canonicalAgentValue(frozen))
            @Expect(ProductPolicyDataDigest().digest(frozen), expected)
            mutable.put("z", textValue("mutated"))
            @Expect(ProductPolicyDataDigest().digest(frozen), expected)
            @Expect(ProductPolicyDataDigest().digest(mutable) != expected)
            for (value in [textValue(""), numberValue("-0.0"), boolValue(false), listValue([]), objectValue([])]) {
                @Expect(ProductPolicyDataDigest().digest(value), modelPolicySha256Text(canonicalAgentValue(value)))
            }
        } finally { owner.close() }
    }
    @TestCase
    func foreignAlteredRangesAndRepeatedExpansionCannotEscapeDestinationBudget(): Unit {
        let owner = ProductPolicyDataReferences("first"); let other = ProductPolicyDataReferences("second")
        try {
            let ref = owner.intern("雪/source")
            @Expect(policyReferenceRejected({ => let _ = other.value(ref) }))
            let changed = freezeProductPolicyData(ref); changed.put("bytes", integerValue(1))
            @Expect(policyReferenceRejected({ => let _ = owner.value(changed) }))
            let part = objectValue([ValueField("source", ref), ValueField("offset", integerValue(0)), ValueField("bytes", integerValue(10))])
            @Expect(owner.compose(listValue([part]), 10), "雪/source")
            @Expect(policyReferenceRejected({ => let _ = owner.compose(listValue([part, part]), 19) }))
            part.put("offset", integerValue(Int64.Max))
            @Expect(policyReferenceRejected({ => let _ = owner.compose(listValue([part]), 8388608) }))
            @Expect(policyReferenceRejected({ => let _ = owner.slice(ref, 1, 2) }))
            owner.close(); owner.close()
            @Expect(policyReferenceRejected({ => let _ = owner.value(ref) }))
        } finally { owner.close(); other.close() }
    }
    @TestCase
    func completeCheckpointAtEightMiBReopensAndOneExtraByteNeverWrites(): Unit {
        let f = CompactionPolicyFixture(hybrid: false)
        try {
            let thread = SqliteThreadCommitSink(f.database).loadThread(ThreadId(f.session.value))
            let overhead = encodeStoredValue(capacityCheckpointPayload("")).size
            // The empty text frame has one size digit; the full frame has seven.
            let text = String.fromUtf8(Array<Byte>(8388608 - overhead - 6, repeat: 65))
            @Expect(encodeStoredValue(capacityCheckpointPayload(text)).size, 8388608)
            let checkpoint = ContextCheckpoint("exact-capacity", thread.thread.id, 2, objectValue([ValueField("deterministic_summary", textValue(text))]),
                contextSourceDigest(thread, 2), "capacity-test", "agent-core", activeState: objectValue([]))
            @Expect(validateStoredContextCheckpoint(checkpoint).isOk())
            let store = SqliteContextCheckpointStore(f.database)
            @Expect(store.save(checkpoint, thread, agentUtcMillis()).isOk())
            @Expect(store.loadLatest(thread, "capacity-test", "agent-core").getOrThrow().structuredSummary.field("deterministic_summary").getOrThrow().text, text)
            let before = f.database.query("SELECT payload FROM context_checkpoints WHERE id='exact-capacity'")[0].required(0)
            let oversized = ContextCheckpoint("one-too-many", thread.thread.id, 2, objectValue([ValueField("deterministic_summary", textValue(text + "!"))]),
                contextSourceDigest(thread, 2), "capacity-test", "agent-core", activeState: objectValue([]))
            @Expect(validateStoredContextCheckpoint(oversized).error().getOrThrow().code, "context.checkpoint_capacity")
            @Expect(store.save(oversized, thread, agentUtcMillis()).error().getOrThrow().code, "context.checkpoint_capacity")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM context_checkpoints"), 1)
            @Expect(f.database.query("SELECT payload FROM context_checkpoints WHERE id='exact-capacity'")[0].required(0), before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
        } finally { f.close() }
    }
    @TestCase
    func responseLeasesSurviveTransportCloseButDoNotAccumulateAcrossPhases(): Unit {
        let owner = ProductPolicyDataReferences("state-owner")
        let raw = objectValue([ValueField("state", textValue(String.fromUtf8(Array<Byte>(16384, repeat: 65))))])
        try {
            var current = owner.copy(raw)
            for (_ in 0..4097) {
                let next = owner.copy(current.value)
                current.close(); current = next
            }
            @Expect(current.value.field("state").getOrThrow().text.size, 16384)
            raw.put("state", textValue("mutable caller"))
            @Expect(current.value.field("state").getOrThrow().text.size, 16384)
            current.close(); current.close()
            let retained = ArrayList<ProductPolicyValueLease>()
            try {
                let large = textValue(String.fromUtf8(Array<Byte>(4000000, repeat: 66)))
                var rejected = false
                for (_ in 0..8) {
                    try { retained.add(owner.copy(large)) } catch (_: Exception) { rejected = true; break }
                }
                @Expect(rejected)
            } finally { for (lease in retained) { lease.close() } }
            let fresh = owner.copy(textValue("all previous phases released"))
            @Expect(fresh.value.text, "all previous phases released"); fresh.close()
        } finally { owner.close() }
    }

    @TestCase
    func finalProposalRetainsOnlyItsOwnDataUntilExplicitConsumerClose(): Unit {
        let sources = ProductPolicyDataReferences("temporary-source")
        let raw = sources.freeze(textValue(String.fromUtf8(Array<Byte>(5000000, repeat: 67))))
        let proposal = ProductCompactionStructure(raw.text, objectValue([]), { => Result.Ok(()) })
        sources.close()
        try {
            @Expect(proposal.text.size, 5000000); @Expect(proposal.validate().isOk())
            // The source is gone, but this final result still consumes the same
            // process pool; enough simultaneous final results must be refused.
            let held = ArrayList<ProductCompactionStructure>()
            var denied = false
            try {
                for (_ in 0..8) {
                    try { held.add(ProductCompactionStructure(raw.text, objectValue([]), { => Result.Ok(()) })) }
                    catch (_: Exception) { denied = true; break }
                }
                @Expect(denied)
            } finally { for (item in held) { item.close() } }
        } finally { proposal.close() }
        @Expect(proposal.validate().error().getOrThrow().code, "compaction.result_released")
        let fresh = ProductCompactionStructure(raw.text, objectValue([]), { => Result.Ok(()) })
        try { @Expect(fresh.validate().isOk()) } finally { fresh.close() }
    }

}
