package agent_store_contract

import std.fs.*
import std.sync.*
import std.time.*
import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

// These are real Runtime.cancel transitions, not SQL changes to Run.state.
// An owned worker settles its existing obligation while cancellation joins it.
func hostServiceHttpCancellationContract(): Unit {
    for (stage in ["executing", "prepared", "waiting_approval"]) {
        hostServiceHttpCancellationScenario(stage)
    }
    println("Host service HTTP cancellation contract passed: real cancellation, late Unknown and unhanded Rejected, exact origin fences")
}

func hostServiceHttpCancellationScenario(stage: String): Unit {
    let root = Directory.createTemp("/tmp").toString()
    let database = SqliteDatabase(root + "/host-http-cancellation.db")
    try {
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("host-http-thread")
        let turn = SemanticTurnId("host-http-turn")
        let run = RunId("host-http-run")
        let parent = OperationId("host-http-parent")
        let child = OperationId("host-http-child")
        let item = ItemId("host-http-call-item")
        let coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        let runtime = AgentThreadRuntime(coordinator, ContextProjector("host-http", StoreEstimator()), { => 10 })
        let admission = httpContractRequire(runtime.startHostServiceTurn(turn, run,
            ItemId("host-http-initiator"), hostOriginValue(), recoveryLane(), InvocationContextProjection()),
            "host HTTP cancellation starts a real maintenance Run")
        let rootPlan = httpContractRootPlan("POST")
        let call = ToolCall("host-http-call", rootPlan.toolName, httpContractOriginalInput())
        let reference = httpContractRequire(runtime.commitHostServiceToolCall(admission, item, parent,
            call, run, admission.run.epoch), "host HTTP cancellation commits sealed root")
        let source = OperationRootSource.Direct(reference)
        let store = DurableOperationStore(database)
        httpContractRequire(store.prepareTrustedControlOperation(parent, run, item, rootPlan), "host HTTP root preparation")
        httpContractRequire(store.waitForApproval(parent, run), "host HTTP root waits for actual approval")
        httpContractRequire(store.recordApproval("host-http-approval", parent, run, rootPlan,
            CapabilitySet(values: rootPlan.requiredCapabilities), true, "user", None), "host HTTP real approval")
        httpContractRequire(store.markExecuting(parent, run, rootPlan, 11, true), "host HTTP root execution")
        httpContractRequire(store.markExecutionHandoff(parent, run, thread, 12), "host HTTP root handoff")
        let plan = httpContractChildPlan("POST")
        let key = "javascript-service:" + call.callId + ":request-1"
        httpContractRequire(store.prepareDerivedOperation(child, parent, run, source, key, plan), "host HTTP child admission")
        if (stage == "executing") {
            httpContractRequire(store.markExecuting(child, run, plan, 13, false), "host HTTP child executing")
            httpContractRequire(store.markExecutionHandoff(child, run, thread, 14), "host HTTP child handoff")
        } else if (stage == "waiting_approval") {
            httpContractRequire(store.waitForApproval(child, run), "host HTTP child waiting")
        }
        let outcome = if (stage == "executing") { OperationOutcome.Unknown } else { OperationOutcome.Rejected }
        let receipt = VNextOperationReceipt("receipt-host-http-child", child, outcome,
            objectValue([ValueField("retained", textValue("cancelled transport observation"))]),
            objectValue([ValueField("stage", textValue(stage))]), 15)
        let token = httpContractRequire(runtime.childCancellationToken(expectedRunId: Some(run),
            expectedEpoch: Some(admission.run.epoch)), "host HTTP child cancellation token")
        let task = spawn {
            let deadline = agentUtcMillis() + 3000
            while (!token.isCancelled() && agentUtcMillis() < deadline) { sleep(Duration.millisecond) }
            expect(token.isCancelled() && database.query("SELECT state FROM runs WHERE id='host-http-run'")[0]
                .required(0) == "cancelling", "owned HTTP worker observes the real cancelling Run before settlement")
            expect(store.prepareTrustedControlOperation(parent, run, item, rootPlan).isError() &&
                store.markExecuting(child, run, plan, 16, false).isError() &&
                store.markExecutionHandoff(child, run, thread, 16).isError(),
                "origin cleanup permission cannot reprepare, execute or hand off while cancelling")
            for (forbidden in [OperationOutcome.Completed, OperationOutcome.Failed]) {
                expect(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-host-http-child",
                    child, forbidden, objectValue([]), objectValue([]), 16)).isError(),
                    "cancelling HostService cannot assert a known HTTP success or failure")
            }
            if (stage == "executing") {
                expect(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-host-http-child",
                    child, OperationOutcome.Rejected, objectValue([]), objectValue([]), 16)).isError(),
                    "real HTTP handoff cannot become unexecuted rejection")
                database.execute("UPDATE operations SET state='prepared' WHERE id='host-http-child'")
                database.execute("UPDATE operation_state_registers SET state='prepared' WHERE operation_id='host-http-child'")
                expect(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-host-http-child",
                    child, OperationOutcome.Rejected, objectValue([]), objectValue([]), 16)).isError(),
                    "a stale prepared register cannot erase durable HTTP handoff")
                database.execute("UPDATE operations SET state='executing' WHERE id='host-http-child'")
                database.execute("UPDATE operation_state_registers SET state='executing' WHERE operation_id='host-http-child'")
            } else {
                expect(store.settleDerivedOperation(run, parent, VNextOperationReceipt("receipt-host-http-child",
                    child, OperationOutcome.Unknown, objectValue([]), objectValue([]), 16)).isError(),
                    "unexecuted child cannot invent in-flight HTTP effects")
            }
            database.execute("UPDATE runs SET epoch=epoch+1 WHERE id='host-http-run'")
            expect(store.settleDerivedOperation(run, parent, receipt).isError(),
                "late cancellation Receipt must still match the immutable handoff epoch")
            database.execute("UPDATE runs SET epoch=epoch-1 WHERE id='host-http-run'")
            let proof = database.query("SELECT payload FROM audit_events WHERE kind='operation_host_origin_bound'")[0].required(0)
            database.execute("UPDATE audit_events SET payload=? WHERE kind='operation_host_origin_bound'",
                [SqlParameter.Text(encodeStoredValue(objectValue([])))])
            expect(store.settleDerivedOperation(run, parent, receipt).isError(),
                "late cancellation Receipt cannot discard the exact host-origin proof")
            database.execute("UPDATE audit_events SET payload=? WHERE kind='operation_host_origin_bound'", [SqlParameter.Text(proof)])
            expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0,
                "all refused cancellation claims are transactional and create no Receipt")
            httpContractRequire(store.settleDerivedOperation(run, parent, receipt), "host HTTP obligation settles during cancellation")
            expect(store.settleDerivedOperation(run, parent, receipt).isError() &&
                database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='host-http-child'") == 1,
                "joined HTTP obligation has exactly one immutable Receipt")
            let parentResult = httpContractRequire(runtime.resolveOperation(ItemId("host-http-result"), parent,
                CanonicalToolCallId(call.callId), rootPlan, OperationAttemptStage.Executing,
                Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Cancelled,
                    "host.http_cancelled", "owned HTTP operation cancelled")), "receipt-host-http-parent", 18,
                expectedRunId: Some(run), expectedEpoch: Some(admission.run.epoch)),
                "host HTTP parent records its existing cancellation obligation")
            expect(parentResult.semanticCommit.isSome() && isStoreCommitted(parentResult.semanticCommit.getOrThrow()),
                "cancellation closes the actual canonical root ToolCall before Run settlement")
        }
        httpContractRequire(runtime.ownTask("host-http-settlement", task), "host HTTP worker belongs to its Run")
        let settlement = runtime.cancel(5000, expectedRunId: Some(run), expectedEpoch: Some(admission.run.epoch))
        task.get()
        httpContractRequire(settlement, "host HTTP runtime cancellation joins the settlement worker")
        expect(database.query("SELECT state FROM runs WHERE id='host-http-run'")[0].required(0) == "cancelled" &&
            database.query("SELECT state FROM operations WHERE id='host-http-child'")[0].required(0) ==
                (if (stage == "executing") { "recovery_required" } else { "rejected" }),
            "cancelled Run retains uncertain effects or known unexecuted rejection without replay")
        let retained = httpContractRequire(store.loadDerivedOperationReceipt(child, run), "load late HTTP Receipt").getOrThrow()
        expect(retained.outcome == outcome && canonicalAgentValue(retained.detail) == canonicalAgentValue(receipt.detail) &&
            canonicalAgentValue(retained.verification) == canonicalAgentValue(receipt.verification) &&
            store.markExecuting(child, run, plan, 20, false).isError() &&
            store.settleDerivedOperation(run, parent, receipt).isError(),
            "terminal cancellation retains exact evidence and cannot revive or replace the settled child")
        expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='host-http-child'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='host-http-parent' AND outcome='unknown'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE operation_id='host-http-child' AND kind='operation_execution_handoff'") ==
                (if (stage == "executing") { 1 } else { 0 }) && database.query("PRAGMA foreign_key_check").isEmpty(),
            "real cancellation retains one truthful child history without fake user, Decision or handoff")
    } finally {
        database.close()
        remove(root, recursive: true)
    }
}
