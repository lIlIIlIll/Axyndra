package agent_store_contract

import agent_domain.*
import agent_store.*
import yjson.*
import yjson_support.*

// Each case first completes real canonical HostService startup and activates
// a separately approved root, then warms repeated reads on the same Store.
// SQL below is deliberate corruption after the successful proof, never the
// source of a positive authorization.
func channelStartupReadMemoContracts(): Unit {
    let changes = [
        "DELETE FROM audit_events WHERE kind='operation_execution_handoff' AND operation_id='channel-startup-operation'",
        "UPDATE audit_events SET payload='broken' WHERE kind='operation_host_origin_bound' AND operation_id='channel-startup-operation'",
        "UPDATE items SET payload='broken' WHERE id='channel-startup-result'",
        "UPDATE items SET payload='broken' WHERE id='channel-startup-item'",
        "UPDATE items SET provenance='broken' WHERE id='channel-startup-initiator'",
        "UPDATE runs SET state='running' WHERE id='channel-startup-run'",
        "UPDATE turns SET state='running' WHERE id='channel-startup-turn'",
        "UPDATE operation_state_registers SET state='executing' WHERE operation_id='channel-startup-operation'",
        "UPDATE runs SET epoch=epoch+1 WHERE id='channel-target-run'",
        "UPDATE operations SET state='failed' WHERE id='channel-parent'"
    ]
    var cases: Int64 = 0
    for (committed in [false, true]) {
        for (sql in changes) {
            let fixture = ServiceEffectStoreFixture(false, committed)
            try {
                fixture.activate()
                httpContractRequire(fixture.verifyRoot(), "startup memo original proof")
                httpContractRequire(fixture.verifyRoot(), "startup memo exact repeat")
                fixture.database.execute(sql)
                expect(fixture.verifyRoot().isError() && fixture.verifyRoot().isError(),
                    "changed durable startup or active root is rejected after memo warmup")
                expect(fixture.countChild("operations") == 0 && fixture.countChild("operation_receipts") == 0,
                    "read validation never invents an execution or Receipt")
                cases += 1
            } finally { fixture.close() }
        }
        for (kind in ["plan", "receipt"]) {
            let fixture = ServiceEffectStoreFixture(false, committed)
            try {
                fixture.activate()
                httpContractRequire(fixture.verifyRoot(), "startup memo plan and receipt proof")
                httpContractRequire(fixture.verifyRoot(), "startup memo plan and receipt exact repeat")
                let mutation = ServiceEffectStartupMutation(fixture, kind)
                expect(fixture.verifyRoot().isError(), "changed full plan or Receipt is never authorized by memo")
                mutation.restore()
                httpContractRequire(fixture.verifyRoot(), "restored actual proof must pass original validation")
                httpContractRequire(fixture.verifyRoot(), "restored actual proof can be repeated")
                cases += 1
            } finally { fixture.close() }
        }
        let fixture = ServiceEffectStoreFixture(false, committed)
        try {
            fixture.activate()
            httpContractRequire(fixture.verifyRoot(), "startup memo binding original proof")
            httpContractRequire(fixture.verifyRoot(), "startup memo binding exact repeat")
            let wrongBinding = channelContractClone(fixture.binding())
            wrongBinding.put("configuration_digest", textValue(
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
            expect(fixture.store.verifyChannelInvocationRoot(fixture.parent, fixture.run, fixture.thread,
                fixture.epoch, fixture.source, fixture.rootPlan, wrongBinding).isError(),
                "different current invocation binding cannot borrow an earlier proof")
            httpContractRequire(fixture.verifyRoot(), "unchanged actual binding remains valid")
            cases += 1
        } finally { fixture.close() }
    }
    expect(cases == 26, "all startup memo corruption scenarios execute")
    println("Channel startup read memo contract passed: 26 actual SQLite scenarios, Direct and Committed")
}
