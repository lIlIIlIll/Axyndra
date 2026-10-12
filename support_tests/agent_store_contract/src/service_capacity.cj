package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

func capacityStoreProfile(): AgentValue {
    objectValue([ValueField("max_frame_bytes", integerValue(4194304)), ValueField("max_input_bytes", integerValue(1048576)),
        ValueField("max_prepare_bytes", integerValue(2097152)), ValueField("max_result_bytes", integerValue(4128768)),
        ValueField("max_directory_bytes", integerValue(2097152)), ValueField("max_tools", integerValue(8192)),
        ValueField("call_timeout_ms", integerValue(120000))])
}
func serviceCapacityDurableContract(): Unit {
    for (committed in [false, true]) {
        for (mode in ["exact", "missing", "changed", "dropped"]) {
            let expected = capacityStoreProfile()
            let other = capacityStoreProfile(); other.put("max_tools", integerValue(72))
            let fixture = ChannelIntentStoreFixture(committed,
                grantProfile: if (mode == "missing") { None } else { Some(expected) },
                bindingProfile: if (mode == "dropped") { None } else { Some(if (mode == "changed") { other } else { expected }) },
                bytesHex: if (mode == "exact") { String.fromUtf8(Array<Byte>(196608, repeat: b'6')) } else { "68690a" })
            try {
                fixture.activateParent()
                let admitted = fixture.admit()
                if (mode == "exact") {
                    httpContractRequire(admitted, "large child authorized by exact completed startup profile")
                    fixture.execute(); fixture.handoff()
                    httpContractRequire(fixture.store.settleDerivedOperation(fixture.run, fixture.parent,
                        fixture.receipt(OperationOutcome.Unknown)), "large handed-off write remains Unknown when effect cannot be determined")
                    expect(fixture.database.query("SELECT id FROM operation_receipts WHERE operation_id=? AND outcome='unknown'",
                        [SqlParameter.Text(fixture.child.value)]).size == 1, "one large-child Unknown receipt")
                } else {
                    expect(admitted.isError(), "plugin binding cannot raise, remove or substitute startup profile")
                    expect(fixture.database.query("SELECT id FROM operations WHERE id=?", [SqlParameter.Text(fixture.child.value)]).isEmpty(),
                        "rejected profile creates no child Operation")
                    expect(fixture.database.query("SELECT id FROM audit_events WHERE kind='operation_execution_handoff' AND operation_id=?",
                        [SqlParameter.Text(fixture.child.value)]).isEmpty(), "rejected profile creates no child handoff")
                }
            } finally { fixture.close() }
        }
    }
    let fixture = ChannelIntentStoreFixture(false)
    try {
        let id = OperationId("capacity-full-plan")
        let item = ItemId("capacity-full-plan-call")
        let call = ToolCall("capacity-full-plan-call", fixture.call.name, objectValue([]))
        expect(isStoreCommitted(fixture.runtime.commitResult(ResultEnvelope(fixture.thread, fixture.turn, fixture.run,
            fixture.epoch, 2, ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                ItemProvenance("direct_tool", runId: Some(fixture.run), operationId: Some(id)))))), "large-plan probe has actual canonical Direct call")
        let source = httpContractRequire(fixture.runtime.attestDirectToolCall(item, id, fixture.run, fixture.epoch), "large-plan sealed source")
        let plan = NormalizedOperationPlan(call.name, call.arguments, [Capability(CapabilityKind.ExtensionInvoke)],
            OperationEffectClass.ExternalMutation, OperationRetryDisposition.Never, "capacity-plan",
            relevantEnvironment: [ValueField("LARGE_EXPLICIT_CONTEXT", textValue(String.fromUtf8(Array<Byte>(8388608, repeat: b'x'))))])
        let rejected = fixture.store.prepareDirectOperation(source, plan)
        expect(rejected.isError() && rejected.error().getOrThrow().code == "operation.plan_codec_limit",
            "complete plan codec is checked even when tool input itself is small")
        expect(fixture.database.query("SELECT id FROM operations WHERE id=?", [SqlParameter.Text(id.value)]).isEmpty(),
            "full plan overflow rejected before persistence or handoff")
    } finally { fixture.close() }
    println("Service capacity durable contract passed: 9 scenarios, exact startup profiles and complete plan codec")
}
