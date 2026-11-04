package agent_core

import agent_domain.*
import agent_runtime.*
import yjson.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

private func planRequestCopiesFrame204(owner: PlanExecutionReadOwner204,
    consumer: PlanExecutionReadConsumer204): PreparedModelRequest {
    let source = AgentRunRequest(RunId("paid-plan-run"), SessionId("paid-plan-session"), "fixture-model", "fixture prompt")
    let data = CorePlanRequestData204(owner.deriveRetainedAllocation204(131072))
    let state = consumer.value204()
    data.fundBeforeRendering204(source, state)
    let request = ModelRequest("fixture-model", [], system: corePlanInstructions(Some(state)))
    PreparedModelRequest(RequestId("paid-plan-request"), request, 1, planData204: Some(data))
}

@Test
class CorePlanRequestData204Test {
    @TestCase
    func independentRequestDataOutlivesTheCompleteInspectionFrame(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let paid = bank.acquire(131072)
        let owner = PlanExecutionReadOwner204(paid)
        owner.installProducerData204(objectValue([ValueField("allowed_tools", listValue([])),
            ValueField("runnable_actions", listValue([objectValue([
                ValueField("action_id", textValue("paid-request-action-canary"))])]))]))
        let consumer = owner.beginConsumer204()
        let prepared = planRequestCopiesFrame204(owner, consumer)
        consumer.returnConsumerFrame204(); owner.closeAfterCaller204()
        @Expect(prepared.request.system.contains("APPROVED PLAN EXECUTION"), true)
        // This input is ALREADY the Store's paid request graph. Reapplying
        // the public-inspection projector would silently drop this action.
        @Expect(prepared.request.system.contains("paid-request-action-canary"), true)
        // Closing the producer cannot refund its independently retained copy.
        @Expect(bank.usage()[1] > 0, true)
        prepared.returnPreparedFrame159()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
}

private func selectedSnapshotProducerFrame204(owner: OwnedToolSetSnapshot159): Unit {
    let small = objectValue([ValueField("type", textValue("object"))])
    let large = objectValue([ValueField("unselected_schema_canary", textValue(
        String.fromUtf8(Array<Byte>(65536, repeat: b'x'))))])
    owner.installSnapshot159(ToolSetSnapshot("selected-source", [
        ToolSnapshotEntry("small", "selected tool", small, "v1", [],
            implementationFingerprint: "small-fingerprint", schemaDigest: modelPolicySha256Text(canonicalAgentValue(small))),
        ToolSnapshotEntry("large", "unselected tool", large, "v1", [],
            implementationFingerprint: "large-fingerprint", schemaDigest: modelPolicySha256Text(canonicalAgentValue(large)))
    ]))
}
private func selectedCopiesConsumerFrame204(source: SharedToolSetSnapshot159): (OwnedModelTools159, Bool) {
    let copied = source.copySelectedOwnedModelTools204(["small"])
    let definitions = copied.definitionsForPreparedRequest159()
    let correct = definitions.size == 1 && definitions[0].name == "small" &&
        definitions[0].inputSchema.field("unselected_schema_canary").isNone()
    // The outer owner cannot retire until this complete concrete helper,
    // including its definitions/schema references, has actually returned.
    (copied, correct)
}
private func selectedCopiesPressureFrame204(root: LogicalJsonOwnerReservation): (Bool, Bool, Bool) {
    let sourcePayment = root.deriveRetainedLease(); sourcePayment.ensureRetainedPeak(2097152)
    let producer = OwnedToolSetSnapshot159(sourcePayment)
    selectedSnapshotProducerFrame204(producer)
    producer.returnedSnapshotProducer159()
    let source = producer.transferSharedSnapshot159()
    let pressure = root.deriveRetainedLease(); pressure.ensureRetainedPeak(4096)
    let used = root.retainedCustodyUsage113()[0]
    pressure.ensureRetainedPeak(16777216 - used - 1048576 + 4096)
    let selected = selectedCopiesConsumerFrame204(source)
    let subset = selected[1]
    selected[0].closeAfterPreparedFrame159()
    var refused = false
    try { let copied = source.copySelectedOwnedModelTools204(["small", "large"])
        copied.closeAfterPreparedFrame159() }
    catch (_: ModelToolCopyInvoiceRefused204) { refused = true }
    let intact = source.identityEqualsValue159("selected-source") && source.hasExportName159("large") &&
        source.availableCompleteExport159("large") && source.hasCompleteIdentities159()
    source.close159(); pressure.close()
    (subset, refused, intact)
}

@Test
class CoreSelectedModelTools204Test {
    @TestCase
    func selectedCopiesFitOriginalPressureWithoutCopyingUnselectedSchema(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        // acquire() applies its original x8 declaration. Keep metadata
        // headroom before deriving; the explicit fixture graph peak is 2MiB.
        let root = bank.acquire(131072)
        root.ensureRetainedPeak(2097152)
        let actual = selectedCopiesPressureFrame204(root)
        @Expect(actual[0], true); @Expect(actual[1], true); @Expect(actual[2], true)
        root.close()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
}
