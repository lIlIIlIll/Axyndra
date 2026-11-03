package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.fs.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

class CancellationSettlementFixture {
    let root: String
    let database: SqliteDatabase
    let coordinator: ThreadCoordinator
    let runtime: AgentThreadRuntime
    let source: CommittedToolCallRef
    let store: DurableOperationStore
    let active: ActiveRunSnapshot
    let thread = ThreadId("cancel-unprepared-thread")
    let turn = SemanticTurnId("cancel-unprepared-turn")
    let run = RunId("cancel-unprepared-run")
    let operation = OperationId("cancel-unprepared-operation")
    init(parentCancellation!: ?CancellationToken = None) {
        root = Directory.createTemp("/tmp").toString()
        database = SqliteDatabase(root + "/state.db")
        let sink = SqliteThreadCommitSink(database)
        coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("cancel-unprepared", StoreEstimator()), { => agentUtcMillis() })
        active = runtime.startTurn(turn, run, ItemId("cancel-user"),
            ThreadItemContent.UserMessage(textMessageParts("cancel while preparing")), recoveryLane(), InvocationContextProjection(), parentCancellation: parentCancellation)
            .value().getOrThrow()
        source = commitDurableToolCall(database, coordinator, thread, turn, run, active.epoch, 1,
            ItemId("cancel-pending-call"), "cancel-pending", "fixture.write", objectValue([ValueField("value", textValue("original"))]), 10)
        store = DurableOperationStore(database)
    }
    func outcome(output: AgentValue, isError: Bool,
        outcome: OperationOutcome): SemanticCommitDecision {
        let snapshot = runtime.threadSnapshot()
        let receipt = VNextOperationReceipt("receipt-cancel", operation, outcome, output,
            objectValue([ValueField("known_completion", boolValue(true)), ValueField("stage", textValue("prepared"))]), 30)
        coordinator.commitOperationResult(ResultEnvelope(thread, turn, run, active.epoch, snapshot.nextResultSequence,
            ThreadItemDraft(ItemId("cancel-result"), ThreadItemContent.ToolResult(CanonicalToolCallId(source.block.callId),
                operation, receipt.receiptId, output, isError), ItemProvenance("operation", runId: Some(run), operationId: Some(operation)),
                createdAtMillis: 30)), receipt, "cancelling")
    }
    func close(): Unit { database.close(); remove(root, recursive: true) }
}

func cancellationUnpreparedSettlementContracts(): Unit {
    cancellationBeginSettlementContract()

    for (mode in ["normal", "reopen", "epoch", "run", "source-arguments", "marker", "success", "output", "already-prepared",
        "source-binding", "missing-marker", "reset-state"]) {
        let f = CancellationSettlementFixture()
        try {
            let original = NormalizedOperationPlan(f.source.block.name, f.source.block.arguments,
                [Capability(CapabilityKind.WorkspaceWrite)], OperationEffectClass.WorkspaceMutation,
                OperationRetryDisposition.Never, "original-write-plan")
            expect(f.store.prepareCancellationSettlement(f.operation, f.run, f.source, f.active.epoch).isError() &&
                f.database.scalarInt("SELECT COUNT(*) FROM operations") == 0,
                "settlement-only API rejects a running Run without creating any operation")
            let unsupported = InMemoryOperationRuntimePort().prepareCancellationSettlement(f.operation, f.run, f.source, f.active.epoch)
            expect(match (unsupported) { case Result.Err(error) => error.code == "operation.cancellation_settlement_unsupported"
                case _ => false }, "ports without durable source proof fail closed by default")
            if (mode == "already-prepared") { f.store.prepare(f.operation, f.run, f.source, original).value().getOrThrow() }
            let completed = AtomicBool(false)
            let token = f.runtime.childCancellationToken().value().getOrThrow()
            let task = spawn {
                let deadline = MonoTime.now() + Duration.second * 3
                while (MonoTime.now() < deadline && (!token.isCancelled() ||
                    f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='cancelling'") != 1)) {
                    sleep(Duration.millisecond * 1)
                }
                expect(token.isCancelled() && f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='cancelling'") == 1,
                    "real Runtime cancellation reaches the owned cleanup task and durable Run")
                expect(f.store.prepare(OperationId("ordinary"), f.run, f.source, original).isError(),
                    "ordinary prepare remains forbidden in Cancelling")
                if (mode == "already-prepared") {
                    expect(f.store.prepareCancellationSettlement(f.operation, f.run, f.source, f.active.epoch).isError() &&
                        f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_cancellation_settlement_only'") == 0 &&
                        f.store.loadPlan(f.operation, f.run).value().getOrThrow().bindingDigest == original.bindingDigest,
                        "cancellation-only API cannot replace a previously prepared write or its authority")
                    let resolved = f.runtime.resolveOperation(ItemId("cancel-result"), f.operation, CanonicalToolCallId(f.source.block.callId),
                        original, OperationAttemptStage.Prepared, Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.Cancelled,
                            "operation.cancelled_before_execution", "already prepared call cancelled")), "receipt-cancel", 30).value().getOrThrow()
                    expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()),
                        "the old prepared cancellation path still settles canonically")
                } else {
                    if (mode == "epoch") {
                        expect(f.store.prepareCancellationSettlement(f.operation, f.run, f.source, f.active.epoch + 1).isError(), "wrong epoch is rejected")
                    }
                    if (mode == "run") {
                        expect(f.store.prepareCancellationSettlement(f.operation, RunId("other-run"), f.source, f.active.epoch).isError(), "wrong Run is rejected")
                    }
                    if (mode == "source-arguments") {
                        f.source.block.arguments.put("value", textValue("changed"))
                        expect(f.store.prepareCancellationSettlement(f.operation, f.run, f.source, f.active.epoch).isError(), "mutable source arguments cannot change the stored canonical call")
                        f.source.block.arguments.put("value", textValue("original"))
                    }
                    let plan = f.store.prepareCancellationSettlement(f.operation, f.run, f.source, f.active.epoch).value().getOrThrow()
                    expect(plan.requiredCapabilities.isEmpty() && plan.effectClass == OperationEffectClass.ReadOnly &&
                        plan.implementation.implementationFingerprint == CANCELLATION_SETTLEMENT_IMPLEMENTATION,
                        "Store creates only its fixed zero-authority cancellation plan")
                    expect(f.store.prepareCancellationSettlement(f.operation, f.run, f.source, f.active.epoch).isOk() &&
                        f.database.scalarInt("SELECT COUNT(*) FROM operations") == 1 &&
                        f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_cancellation_settlement_only'") == 1,
                        "same unexecuted obligation is idempotent without a duplicate audit")
                    expect(f.store.waitForApproval(f.operation, f.run).isError() &&
                        f.store.markExecuting(f.operation, f.run, plan, 20, false).isError() &&
                        f.store.markExecutionHandoff(f.operation, f.run, f.thread, 21).isError(),
                        "cancellation-only record cannot acquire approval, executor, or handoff")
                    if (mode == "reopen") {
                        let reopened = SqliteDatabase(f.root + "/state.db")
                        try {
                            let port = DurableOperationStore(reopened)
                            expect(port.loadPlan(f.operation, f.run).value().getOrThrow().bindingDigest == plan.bindingDigest &&
                                port.loadCall(f.operation, f.run).value().getOrThrow().callId == f.source.block.callId &&
                                port.markExecuting(f.operation, f.run, plan, 22, false).isError(),
                                "reopen preserves actual call and the permanent no-execution fence")
                        } finally { reopened.close() }
                    }
                    if (mode == "reset-state") {
                        f.database.execute("UPDATE runs SET state='running' WHERE id=?", [SqlParameter.Text(f.run.value)])
                        expect(f.store.prepare(f.operation, f.run, f.source, plan).isError() &&
                            f.store.waitForApproval(f.operation, f.run).isError() &&
                            f.store.markExecuting(f.operation, f.run, plan, 22, false).isError() &&
                            f.store.markExecutionHandoff(f.operation, f.run, f.thread, 23).isError(),
                            "a Run state reset cannot upgrade a cancellation-only record into authority")
                        f.database.execute("UPDATE runs SET state='cancelling' WHERE id=?", [SqlParameter.Text(f.run.value)])
                    }
                    if (mode == "success" || mode == "output" || mode == "marker" || mode == "source-binding" || mode == "missing-marker") {
                        let before = f.database.query("SELECT payload FROM audit_events WHERE kind='operation_cancellation_settlement_only'")[0].required(0)
                        if (mode == "marker") {
                            let changed = decodeStoredValue(before); changed.put("epoch", textValue((f.active.epoch + 1).toString()))
                            f.database.execute("UPDATE audit_events SET payload=? WHERE kind='operation_cancellation_settlement_only'", [SqlParameter.Text(encodeStoredValue(changed))])
                        }
                        if (mode == "source-binding") {
                            f.database.execute("UPDATE decision_operations SET scoped_tool_call_id='changed-source' WHERE operation_id=?",
                                [SqlParameter.Text(f.operation.value)])
                        }
                        if (mode == "missing-marker") {
                            f.database.execute("DELETE FROM audit_events WHERE kind='operation_cancellation_settlement_only'")
                            expect(f.store.waitForApproval(f.operation, f.run).isError() &&
                                f.store.markExecuting(f.operation, f.run, plan, 22, false).isError(),
                                "the fixed cancellation plan independently denies execution after an audit is removed")
                        }
                        let output = if (mode == "output") { objectValue([ValueField("error", textValue("other"))]) } else { cancelledUnpreparedToolOutput() }
                        let invalid = f.outcome(output, mode != "success",
                            if (mode == "success") { OperationOutcome.Completed } else { OperationOutcome.Rejected })
                        expect(!isStoreCommitted(invalid) && f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 &&
                            f.database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") == 0,
                            "wrong result, success outcome, or epoch proof rolls back both canonical facts")
                        if (mode == "marker") { f.database.execute("UPDATE audit_events SET payload=? WHERE kind='operation_cancellation_settlement_only'", [SqlParameter.Text(before)]) }
                        if (mode == "source-binding") {
                            f.database.execute("UPDATE decision_operations SET scoped_tool_call_id=? WHERE operation_id=?",
                                [SqlParameter.Text(f.source.scopedToolCallId.value), SqlParameter.Text(f.operation.value)])
                        }
                        if (mode == "missing-marker") {
                            f.database.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES (?,?,?,'operation_cancellation_settlement_only',?,25)",
                                [SqlParameter.Text(f.thread.value), SqlParameter.Text(f.run.value), SqlParameter.Text(f.operation.value), SqlParameter.Text(before)])
                        }
                    }
                    expect(isStoreCommitted(f.outcome(cancelledUnpreparedToolOutput(), true, OperationOutcome.Rejected)),
                        "actual Cancelling canonical source accepts one exact unexecuted Rejected receipt and result")
                }
                expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 1 &&
                    f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'") == 1 &&
                    f.database.scalarInt("SELECT COUNT(*) FROM approvals") == 0 &&
                    f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0,
                    "cleanup closes canonical debt with zero executor or approval effects")
                completed.store(true)
            }
            f.runtime.ownTask("cancel-unprepared-cleanup", task).value().getOrThrow()
            try {
                let settled = f.runtime.cancel(5000).value().getOrThrow()
                task.get()
                expect(completed.load() && settled.run.state == RunState.Cancelled &&
                    f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='cancelled'") == 1,
                    "real Runtime waits for cleanup ACK and then commits Cancelled")
            } finally { let _ = f.runtime.cancel(1000); task.get() }
        } finally { f.close() }
    }
    println("Store cancellation-only unprepared settlement contract passed: 12 scenarios")
}

// This is the actual waiting-approval path missed by a token-only signal.
// The existing twelve cases below retain the concurrent runtime.cancel path.
func cancellationBeginSettlementContract(): Unit {
    for (waitingApproval in [true, false]) {
    for (lateBinding in [false, true]) {
    let source = CancellationSource()
    let f = CancellationSettlementFixture(parentCancellation: if (lateBinding) { None } else { Some(source.token) })
    var registration: ?CancellationRegistration = None
    try {
        if (lateBinding) {
            expect(f.runtime.bindCancellationParent(RunId("wrong-run"), f.active.epoch, source.token).isError() &&
                f.runtime.bindCancellationParent(f.run, f.active.epoch + 1, source.token).isError(),
                "a cancellation parent cannot bind the wrong actual Run or epoch")
            registration = Some(f.runtime.bindCancellationParent(f.run, f.active.epoch, source.token).value().getOrThrow())
        }
        if (waitingApproval) { f.runtime.pauseForApproval().value().getOrThrow() }
        let originalPhase = if (waitingApproval) { "waiting_approval" } else { "running" }
        expect(f.runtime.beginCancellationSettlement(f.run, f.active.epoch).isError() &&
            f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='" + originalPhase + "'") == 1 &&
            f.database.scalarInt("SELECT COUNT(*) FROM operations") == 0,
            "uncancelled actual owner cannot enter the cancellation settlement phase")
        let token = f.runtime.childCancellationToken().value().getOrThrow()
        let _ = source.cancel()
        expect(token.isCancelled(), "actual Run token observes its external parent cancellation")
        expect(f.runtime.beginCancellationSettlement(RunId("wrong-run"), f.active.epoch).isError() &&
            f.runtime.beginCancellationSettlement(f.run, f.active.epoch + 1).isError() &&
            f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='" + originalPhase + "'") == 1,
            "cancelled token cannot transition a different Run or epoch")
        f.runtime.beginCancellationSettlement(f.run, f.active.epoch).value().getOrThrow()
        let before = f.runtime.activeRun().getOrThrow().transitionSequence
        f.runtime.beginCancellationSettlement(f.run, f.active.epoch).value().getOrThrow()
        expect(f.runtime.activeRun().getOrThrow().transitionSequence == before &&
            f.database.scalarInt("SELECT COUNT(*) FROM runs WHERE state='cancelling'") == 1,
            "the exact repeated begin does not write another transition")
        let ordinary = NormalizedOperationPlan(f.source.block.name, f.source.block.arguments,
            [Capability(CapabilityKind.WorkspaceWrite)], OperationEffectClass.WorkspaceMutation,
            OperationRetryDisposition.Never, "ordinary-write")
        expect(f.store.prepare(OperationId("ordinary-cancelled"), f.run, f.source, ordinary).isError(),
            "early phase transition still cannot prepare executable work")
        let _ = f.store.prepareCancellationSettlement(f.operation, f.run, f.source, f.active.epoch).value().getOrThrow()
        expect(isStoreCommitted(f.outcome(cancelledUnpreparedToolOutput(), true, OperationOutcome.Rejected)),
            "exact unprepared canonical call settles before final Run join")
        let settled = f.runtime.cancel(1000, expectedRunId: Some(f.run), expectedEpoch: Some(f.active.epoch)).value().getOrThrow()
        expect(settled.run.state == RunState.Cancelled && settled.run.transitionSequence == before + 1 &&
            settled.joined.quarantinedCount() == 0 && settled.joined.failedCount() == 0 && f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'") == 1 &&
            f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
            f.database.scalarInt("SELECT COUNT(*) FROM operations") == 1,
            "final cancel joins and terminates without a repeated Cancelling transition or I/O")
    } finally {
        match (registration) { case Some(value) => value.dispose(); case None => () }
        source.close(); f.close()
    }
    }
    }
    println("Store cancellation parent linkage contract passed: admission and exact live-owner binding")
    println("Store cancellation settlement entry phases passed: running and waiting approval, admission and exact live-owner binding")
}
