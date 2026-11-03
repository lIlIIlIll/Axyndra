package agent_store_contract

import std.collection.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

// Actual canonical Thread sources, User approvals, Root/Derived handoffs and
// SQLite facts precede warmup. A fresh Store is the full-validator oracle.
func channelWriteExecutionReadMemoContracts(): Unit {
    let changes = [
        "UPDATE operations SET normalized_plan='broken' WHERE id='channel-parent'",
        "UPDATE operation_effect_records SET normalized_plan='broken' WHERE operation_id='channel-parent'",
        "UPDATE operation_state_registers SET state='failed' WHERE operation_id='channel-parent'",
        "UPDATE operations SET state='failed' WHERE id='channel-child'",
        "UPDATE operations SET normalized_plan='broken' WHERE id='channel-child'",
        "UPDATE operation_effect_records SET normalized_plan='broken' WHERE operation_id='channel-child'",
        "UPDATE operation_state_registers SET state='failed' WHERE operation_id='channel-child'",
        "UPDATE derived_operation_admissions SET request_key='changed' WHERE operation_id='channel-child'",
        "UPDATE derived_operation_admissions SET request_digest='changed' WHERE operation_id='channel-child'",
        "DELETE FROM audit_events WHERE kind='operation_execution_handoff' AND operation_id='channel-child'",
        "UPDATE runs SET state='completed' WHERE id='channel-target-run'",
        "UPDATE runs SET epoch=epoch+1 WHERE id='channel-target-run'",
        "UPDATE threads SET active_turn_id=NULL WHERE id='channel-target-thread'",
        "UPDATE turns SET active_run_id=NULL WHERE id='channel-target-turn'",
        "UPDATE items SET payload='broken' WHERE id='channel-parent-item'",
        "UPDATE items SET provenance='broken' WHERE id='channel-parent-item'",
        "DELETE FROM audit_events WHERE kind='operation_execution_handoff' AND operation_id='channel-parent'",
        "UPDATE audit_events SET payload='broken' WHERE kind='operation_execution_handoff' AND operation_id='channel-parent'",
        "UPDATE operation_receipts SET outcome='unknown' WHERE operation_id='channel-startup-operation'",
        "DELETE FROM audit_events WHERE kind='operation_parent_intent_authorized' AND operation_id='channel-child'",
        "UPDATE audit_events SET payload='broken' WHERE kind='operation_parent_intent_authorized' AND operation_id='channel-child'",
        "UPDATE operation_receipts SET detail='broken' WHERE operation_id='channel-startup-operation'"
    ]
    var cases: Int64 = 0
    for (committed in [false, true]) {
        for (large in [false, true]) {
            for (sql in changes) {
                let bytes = if (large) { String.fromUtf8(Array<Byte>(50000, repeat: b'a')) } else { "68656c6c6f0a" }
                let f = ChannelIntentStoreFixture(committed, bytesHex: bytes)
                try {
                    f.activateParent(); let _ = httpContractRequire(f.admit(), "actual write child admitted")
                    f.execute(); f.handoff()
                    let binding = f.childPlan.canonicalArguments.field("binding").getOrThrow()
                    let verify = { store: DurableOperationStore => store.verifyChannelWriteExecution(f.child, f.parent,
                        f.run, f.thread, f.epoch, f.source, f.key, f.childPlan, binding) }
                    httpContractRequire(verify(f.store), "full write validation before warmup")
                    httpContractRequire(verify(f.store), "warm current SQL write proof")
                    let effects = f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records")
                    let receipts = f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
                    f.database.execute(sql)
                    expect(verify(DurableOperationStore(f.database)).isError() && verify(f.store).isError() &&
                        verify(f.store).isError(), "changed write proof rejects in full and warmed validators")
                    expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records") == effects &&
                        f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == receipts,
                        "proof validation creates no effect or Receipt")
                    cases += 1
                } finally { f.close() }
            }
        }
    }
    for (changed in ["source", "plan", "binding"]) {
        let f = ChannelIntentStoreFixture(false)
        try {
            f.activateParent(); let _ = httpContractRequire(f.admit(), "mutable-input actual child")
            f.execute(); f.handoff()
            let binding = channelContractClone(f.childPlan.canonicalArguments.field("binding").getOrThrow())
            let verify = { store: DurableOperationStore => store.verifyChannelWriteExecution(f.child, f.parent,
                f.run, f.thread, f.epoch, f.source, f.key, f.childPlan, binding) }
            httpContractRequire(verify(f.store), "mutable input original proof")
            httpContractRequire(verify(f.store), "mutable input warmed proof")
            if (changed == "source") {
                let direct = match (f.source) { case OperationRootSource.Direct(value) => value
                    case _ => throw IllegalStateException("actual Direct fixture required") }
                direct.call.arguments.put("query", textValue("changed after warmup"))
            } else if (changed == "plan") {
                f.childPlan.canonicalArguments.field("intent").getOrThrow().put("bytes_hex", textValue("0000"))
            } else { binding.put("configuration_digest", textValue("changed")) }
            expect(verify(DurableOperationStore(f.database)).isError() && verify(f.store).isError(),
                "mutable current inputs cannot alias a previous successful transcript")
            cases += 1
        } finally { f.close() }
    }
    expect(cases == 91, "all current-write proof corruption and mutable-input scenarios execute")
    println("Channel write execution read memo contract passed: 91 actual SQLite scenarios")
}
