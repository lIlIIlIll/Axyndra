package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

func sharedPayloadRootVerify(f: ChannelIntentStoreFixture, store: DurableOperationStore): Result<Unit> {
    store.verifyChannelInvocationRoot(f.parent, f.run, f.thread, f.epoch, f.source,
        f.rootPlan, f.rootPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow())
}
func sharedPayloadRootActivate(f: ChannelIntentStoreFixture): Unit {
    payloadStorePin(f, payloadStoreWitness(f))
    httpContractRequire(payloadStorePrepare(f), "shared root actual prepared payload")
    f.activateParent()
    httpContractRequire(sharedPayloadRootVerify(f, f.store), "shared root cold full proof")
    httpContractRequire(sharedPayloadRootVerify(f, f.store), "shared root warm exact SQL proof")
}

// Real canonical startup, approved parent and execution handoff precede every
// warmup. A fresh Store is the full-validator oracle after each mutation.
func channelPayloadRootSharedSlotContracts(): Unit {
    let mutations = [
        "UPDATE operations SET normalized_plan='broken' WHERE id='channel-parent'",
        "UPDATE operation_effect_records SET normalized_plan='broken' WHERE operation_id='channel-parent'",
        "UPDATE operation_state_registers SET state='failed' WHERE operation_id='channel-parent'",
        "UPDATE runs SET state='completed' WHERE id='channel-target-run'",
        "UPDATE runs SET epoch=epoch+1 WHERE id='channel-target-run'",
        "UPDATE threads SET active_turn_id=NULL WHERE id='channel-target-thread'",
        "UPDATE turns SET active_run_id=NULL WHERE id='channel-target-turn'",
        "UPDATE items SET payload='broken' WHERE id='channel-parent-item'",
        "UPDATE items SET provenance='broken' WHERE id='channel-parent-item'",
        "DELETE FROM audit_events WHERE kind='operation_execution_handoff' AND operation_id='channel-parent'",
        "UPDATE audit_events SET payload='broken' WHERE kind='operation_execution_handoff' AND operation_id='channel-parent'",
        "DELETE FROM audit_events WHERE kind='service_payload_prepared'",
        "UPDATE audit_events SET payload='broken' WHERE kind='service_payload_prepared'",
        "UPDATE artifacts SET mime='application/octet-stream'",
        "UPDATE artifacts SET size=size+2",
        "UPDATE artifacts SET relative_path='blobs/changed.txt'",
        "UPDATE artifacts SET metadata='{}'",
        "UPDATE operations SET state='failed' WHERE id='channel-startup-operation'",
        "DELETE FROM audit_events WHERE kind='operation_execution_handoff' AND operation_id='channel-startup-operation'",
        "UPDATE operation_receipts SET outcome='unknown' WHERE operation_id='channel-startup-operation'",
        "UPDATE operation_receipts SET detail='broken' WHERE operation_id='channel-startup-operation'"
    ]
    var cases: Int64 = 0
    for (committed in [false, true]) {
        for (sql in mutations) {
            let f = payloadStoreFixture(committed)
            try {
                sharedPayloadRootActivate(f)
                f.database.execute(sql)
                expect(sharedPayloadRootVerify(f, DurableOperationStore(f.database)).isError() &&
                    sharedPayloadRootVerify(f, f.store).isError() && sharedPayloadRootVerify(f, f.store).isError(),
                    "changed payload root rejects identically after full and warm proofs")
                expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='channel-child'") == 0 &&
                    f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='channel-parent'") == 0,
                    "read proof creates neither child nor parent receipt")
                cases += 1
            } finally { f.close() }
        }
    }
    for (field in ["source", "plan", "binding"]) {
        let f = payloadStoreFixture(false)
        try {
            sharedPayloadRootActivate(f)
            let direct = match (f.source) { case OperationRootSource.Direct(v) => v
                case _ => throw IllegalStateException("actual Direct source required") }
            if (field == "source") { direct.call.arguments.put("query", textValue("changed after warmup")) }
            if (field == "plan") { f.rootPlan.canonicalArguments.field("input").getOrThrow().put("query", textValue("changed after warmup")) }
            if (field == "binding") { f.rootPlan.canonicalArguments.field("host_plan").getOrThrow()
                .field("binding").getOrThrow().put("lease_id", textValue("changed-after-warmup")) }
            expect(sharedPayloadRootVerify(f, DurableOperationStore(f.database)).isError() &&
                sharedPayloadRootVerify(f, f.store).isError(), "mutable input cannot reuse an old exact proof")
            cases += 1
        } finally { f.close() }
    }
    let f = payloadStoreFixture(false)
    try {
        sharedPayloadRootActivate(f)
        let binding = f.rootPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        expect(f.store.verifyChannelWriteExecution(f.parent, f.parent, f.run, f.thread, f.epoch,
            f.source, "", f.rootPlan, binding).isError(), "root proof cannot be reused by a write validator with identical key fields")
        httpContractRequire(sharedPayloadRootVerify(f, f.store), "root revalidates after failed write role")
        httpContractRequire(f.admit(), "actual child admitted after root proof")
        f.execute(); f.handoff()
        for (_ in 0..2) {
            httpContractRequire(f.store.verifyChannelWriteExecution(f.child, f.parent, f.run, f.thread, f.epoch,
                f.source, f.key, f.childPlan, binding), "actual child retains full write proof")
            httpContractRequire(sharedPayloadRootVerify(f, f.store), "root and child may alternate the single slot")
        }
        expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id IN ('channel-child','channel-parent')") == 0,
            "memo alternation performs no I/O or settlement")
        cases += 1
    } finally { f.close() }
    expect(cases == 46, "all original-source payload root and role-isolation scenarios execute")
    println("Channel payload root read shared-slot contract passed: 46 actual SQLite scenarios")
}
