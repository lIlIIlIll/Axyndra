package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

// Real canonical startup, approved parent and handoff precede every warmup.
// Fresh Store instances serve as the non-memoized original-validator oracle.
func channelInvocationReadMemoContracts(): Unit {
    let changes = [
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
        "UPDATE audit_events SET payload='broken' WHERE kind='operation_execution_handoff' AND operation_id='channel-parent'"
    ]
    var cases: Int64 = 0
    for (committed in [false, true]) {
        for (sql in changes) {
            let f = ServiceEffectStoreFixture(false, committed)
            try {
                f.activate()
                httpContractRequire(f.verifyRoot(), "root memo original proof")
                httpContractRequire(f.verifyRoot(), "root memo warm repeat")
                f.database.execute(sql)
                let uncached = DurableOperationStore(f.database).verifyChannelInvocationRoot(f.parent, f.run,
                    f.thread, f.epoch, f.source, f.rootPlan, f.binding())
                expect(uncached.isError() && f.verifyRoot().isError() && f.verifyRoot().isError(),
                    "changed root proof rejects identically in original and warmed validators")
                expect(f.countChild("operations") == 0 && f.countChild("operation_receipts") == 0,
                    "read memo creates no effect or Receipt")
                cases += 1
            } finally { f.close() }
        }
    }
    let f = ServiceEffectStoreFixture(false, false)
    try {
        f.activate()
        httpContractRequire(f.verifyRoot(), "mutable input initial proof")
        httpContractRequire(f.verifyRoot(), "mutable input warm proof")
        let source = match (f.source) { case OperationRootSource.Direct(value) => value
            case _ => throw IllegalStateException("fixture must use actual Direct source") }
        let original = source.call.arguments.field("query").getOrThrow()
        source.call.arguments.put("query", textValue("changed after warmup"))
        expect(f.verifyRoot().isError(), "source arguments cannot borrow an old transcript key")
        source.call.arguments.put("query", original)
        httpContractRequire(f.verifyRoot(), "restored exact source revalidates")
        httpContractRequire(f.verifyRoot(), "restored source repeat")
        cases += 1
    } finally { f.close() }
    let large = ChannelIntentStoreFixture(false, bytesHex: String.fromUtf8(Array<Byte>(50000, repeat: b'a')))
    try {
        large.activateParent()
        let binding = large.rootPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        for (_ in 0..2) {
            httpContractRequire(large.store.verifyChannelInvocationRoot(large.parent, large.run, large.thread,
                large.epoch, large.source, large.rootPlan, binding), "oversized transcript uses original validator")
        }
        large.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='channel-target-run'")
        expect(large.store.verifyChannelInvocationRoot(large.parent, large.run, large.thread,
            large.epoch, large.source, large.rootPlan, binding).isError(), "oversized bypass still validates current epoch")
        cases += 1
    } finally { large.close() }
    expect(cases == 24, "all full-root memo corruption and oversized bypass scenarios execute")
    println("Channel invocation read memo contract passed: 24 actual SQLite scenarios")
}
