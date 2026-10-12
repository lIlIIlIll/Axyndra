package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*

func directPreparationRejectionStoreContract(): Unit {
    var count: Int64 = 0
    for (mode in ["settle", "raw-marker", "prepared-parent", "wait", "execute", "handoff", "wrong-epoch",
        "wrong-call", "wrong-origin", "success-wash", "audit-tamper", "rollback"]) {
        let fixture = ContextReadStoreFixture(mode: "direct-parent")
        try {
            let fact = fixture.completeRead()
            let source = match (fixture.parentSource.getOrThrow()) { case OperationRootSource.Direct(value) => value
                case _ => throw IllegalStateException("test requires actual Direct parent") }
            if (mode == "raw-marker") {
                expect(fixture.store.prepareDirectOperation(source, rejectedDirectPreparationPlan(source)).isError(),
                    "raw plan tag cannot mint a rejection admission")
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 1, "no raw marker row")
                count++; continue
            }
            if (mode == "prepared-parent") { fixture.prepareParent(contextReadParentPlan([fact.link()])).value().getOrThrow() }
            if (mode == "wrong-epoch") { fixture.database.execute("UPDATE runs SET epoch=epoch+1") }
            if (mode == "wrong-call") { fixture.database.execute("UPDATE items SET payload='invalid' WHERE id='pending-direct'") }
            if (mode == "wrong-origin") { fixture.database.execute("UPDATE items SET provenance='invalid' WHERE id='pending-direct'") }
            if (mode == "rollback") { fixture.database.execute("CREATE TRIGGER reject_direct_marker BEFORE INSERT ON audit_events " +
                "WHEN NEW.kind='operation_direct_preparation_rejection_only' BEGIN SELECT RAISE(ABORT,'fixture rollback'); END") }
            let prepared = fixture.store.prepareDirectRejection(source)
            if (["prepared-parent", "wrong-epoch", "wrong-call", "wrong-origin", "rollback"].contains(mode)) {
                expect(prepared.isError(), mode + ": rejection cannot replace effects or accept changed canonical owner")
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_direct_preparation_rejection_only'") == 0,
                    "failed rejection leaves no marker")
                if (mode == "rollback") { expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations") == 1,
                    "marker failure rolls back its Operation/effect/register without deleting the original call") }
                count++; continue
            }
            let plan = prepared.value().getOrThrow()
            expect(fixture.store.prepareDirectRejection(source).isError(), "single rejection preparation cannot be replayed")
            if (mode == "wait") {
                expect(fixture.store.waitForApproval(source.operationId, fixture.run).isError(), "rejection marker never enters approval")
            } else if (mode == "execute") {
                expect(fixture.store.markExecutingWithSource(Some(OperationRootSource.Direct(source)), source.operationId,
                    fixture.run, plan, 21, false).isError(), "rejection marker never enters execution")
            } else if (mode == "handoff") {
                expect(fixture.store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)), source.operationId,
                    fixture.run, fixture.thread, 21).isError(), "rejection marker never has a handoff")
            }
            if (mode == "audit-tamper") { fixture.database.execute("UPDATE audit_events SET payload='invalid' WHERE kind='operation_direct_preparation_rejection_only'") }
            let result = ToolResult(source.call.callId, rejectedDirectPreparationOutput(), isError: mode != "success-wash")
            let settled = fixture.runtime.resolveOperation(ItemId("direct-parent-result"), source.operationId,
                CanonicalToolCallId(source.call.callId), plan, OperationAttemptStage.Prepared,
                Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(result)), "receipt-" + source.operationId.value,
                22, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.active.epoch))
            if (mode == "success-wash" || mode == "audit-tamper") {
                expect(settled.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1,
                    "false success or damaged marker cannot publish a canonical result")
            } else {
                expect(settled.isOk(), "actual failed preparation settles its original parent as Rejected")
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'") == 1 &&
                    fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 1,
                    "only the earlier actual read executed, parent has no handoff")
                expect(fixture.runtime.finish(RunState.Failed, 1000).isOk(), "known rejection closes the real tool round")
            }
            count++
        } finally { fixture.close() }
    }
    expect(count == 12, "all Direct preparation rejection scenarios executed")
    println("Direct preparation rejection contract passed: 12 scenarios")
}
