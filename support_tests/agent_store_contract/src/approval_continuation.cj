package agent_store_contract

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import yjson.*
import yjson_support.*

class ApprovalContinuationFixture {
    let cut = ModelLaneCutFixture()
    let operation = OperationId("approval-operation")
    let call = ToolCall("approval-call", "fixture.approved", objectValue([ValueField("raw", textValue("input"))]))
    let laterOperation = OperationId("later-operation")
    let laterCall = ToolCall("later-call", "fixture.later", objectValue([]))
    let laterPlan: NormalizedOperationPlan
    let plan: NormalizedOperationPlan
    let store: DurableOperationStore
    let request: AgentValue
    let decision: AgentValue
    init(rejected!: Bool = false) {
        plan = NormalizedOperationPlan(call.name, objectValue([ValueField("normalized", textValue("input"))]),
            [Capability(CapabilityKind.WorkspaceRead)], OperationEffectClass.ReadOnly, OperationRetryDisposition.Never,
            "actual-plan-binding", toolVersion: "fixture-v1", implementationFingerprint: "fixture-v1")
        laterPlan = NormalizedOperationPlan(laterCall.name, laterCall.arguments, [Capability(CapabilityKind.WorkspaceRead)],
            OperationEffectClass.ReadOnly, OperationRetryDisposition.Never, "later-binding")
        store = DurableOperationStore(cut.database)
        let approval = ApprovalRequest(operation, call.callId, call.name, Capability(CapabilityKind.WorkspaceRead),
            preview: plan.canonicalArguments, sessionId: cut.thread.value, argumentHash: "original-call-and-capabilities-hash")
        let continuation = RunContinuation(cut.run, SessionId(cut.thread.value), "fixture", "refresh catalog", approval,
            contextSnapshotPayload: contextSnapshotValue(InvocationContextProjection()))
        request = objectValue([ValueField("kind", textValue("waiting_approval")), ValueField("run_id", textValue(cut.run.value)),
            ValueField("session_id", textValue(cut.thread.value)), ValueField("prompt", textValue("preserved request")),
            ValueField("skill_stack", contextSnapshotValue(InvocationContextProjection())),
            ValueField("approval", objectValue([ValueField("operation_id", textValue(operation.value)),
                ValueField("call_id", textValue(call.callId)), ValueField("tool_name", textValue(call.name)),
                ValueField("session_id", textValue(cut.thread.value)), ValueField("preview", plan.canonicalArguments),
                ValueField("argument_hash", textValue(approval.argumentHash))]))])
        decision = objectValue([ValueField("version", integerValue(1)), ValueField("operation_id", textValue(operation.value)),
            ValueField("run_id", textValue(cut.run.value)), ValueField("session_id", textValue(cut.thread.value)),
            ValueField("call_id", textValue(call.callId)), ValueField("argument_hash", textValue(approval.argumentHash)),
            ValueField("decision", objectValue([ValueField("kind", textValue(if (rejected) { "reject" } else { "approve" }))]))])
        let source = commitCall(operation, call)
        store.prepareDirectOperation(source, plan).value().getOrThrow()
        let laterSource = commitCall(laterOperation, laterCall)
        store.prepareDirectOperation(laterSource, laterPlan).value().getOrThrow()
        store.waitForApproval(operation, cut.run).value().getOrThrow()
        cut.runtime.pauseForApproval().value().getOrThrow()
        cut.database.transaction { tx => writeRunContinuationSnapshotProjection(tx, continuation, request) }
        // Real Store approval API performs the waiting-state -> prepared/rejected
        // transition. The UI adapter's independent durable decision uses its
        // exact existing JSON codec shape; Core tests exercise its real writer.
        store.recordApproval("approval-" + operation.value, operation, cut.run, plan,
            CapabilitySet(values: plan.requiredCapabilities), !rejected, "user").value().getOrThrow()
        cut.database.execute("INSERT INTO approval_decisions(operation_id,run_id,payload,created_at_millis) VALUES (?,?,?,?)",
            [SqlParameter.Text(operation.value), SqlParameter.Text(cut.run.value), SqlParameter.Text(stringifyUnifiedJson(decision)), SqlParameter.Int64Value(22)])
        cut.runtime.resumeAfterApproval().value().getOrThrow()
        if (!rejected) {
            store.markExecuting(operation, cut.run, plan, 23, true).value().getOrThrow()
            store.markExecutionHandoff(operation, cut.run, cut.thread, 24).value().getOrThrow()
        }
    }
    func commitCall(op: OperationId, value: ToolCall): DirectToolCallRef {
        let active = cut.runtime.activeRun().getOrThrow(); let snapshot = cut.runtime.threadSnapshot()
        let id = ItemId("call-" + op.value)
        expect(isStoreCommitted(cut.runtime.commitResult(ResultEnvelope(cut.thread, cut.turn, cut.run, active.epoch,
            snapshot.nextResultSequence, ThreadItemDraft(id, ThreadItemContent.ToolCall(CanonicalToolCallId(value.callId), value.name, value.arguments),
                ItemProvenance("direct_tool", runId: Some(cut.run), operationId: Some(op)))))), "fixture owns the actual canonical Direct call")
        cut.runtime.attestDirectToolCall(id, op, cut.run, active.epoch).value().getOrThrow()
    }
    func save(debt: WorkDebtSnapshot, batch!: ?ToolBatchContinuation = None, projection!: ?AgentValue = None): Unit {
        let current = cut.continuation()
        let next = withRunRequestSnapshotProjection(sealDurableRunContinuation(DurableRunContinuationV1(current.runId,
            current.laneId, current.turnId, current.stepOrdinal, current.phase, current.compositionSnapshotId,
            current.modelLaneSnapshotId, pendingOperationId: current.pendingOperationId, pendingApprovalId: current.pendingApprovalId,
            toolBatch: batch, workDebt: debt)), match (projection) { case Some(value) => value; case None => request })
        SqliteSemanticStore(cut.database).transact(TransactionPreconditions(cut.thread, cut.runtime.threadSnapshot().thread.revision,
            cut.run, cut.database.scalarInt("SELECT revision FROM run_continuations WHERE run_id='cut-run'")),
            DurableWriteSet(continuation: Some(next))).value().getOrThrow()
        // SemanticStore advances the Thread revision; reload the real runtime.
        // All source admissions happened above, so recovery never mints Direct.
        cut.reload()
    }
    func resolve(mode: String): RuntimeOperationResolution {
        let result: Result<ToolInvocationResult> = match (mode) {
            case "unknown" => Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "fixture.unknown", "observed uncertain effect"))
            case "failed" => Result.Err(AgentError(AgentErrorKind.InvalidInput, "fixture.failed", "known failure"))
            case "rejected" => Result.Ok(ToolInvocationResult.Denied(ToolDenial(call.callId, call.name,
                AgentError(AgentErrorKind.PermissionDenied, "fixture.rejected", "actual approval rejection"))))
            case _ => Result.Ok(ToolInvocationResult.Completed(ToolResult(call.callId, objectValue([ValueField("done", boolValue(true))]))))
        }
        cut.runtime.resolveOperation(ItemId("result-approval"), operation, CanonicalToolCallId(call.callId), plan,
            if (mode == "rejected") { OperationAttemptStage.Prepared } else { OperationAttemptStage.Executing },
            result, "receipt-approval", 25).value().getOrThrow()
    }
    func extra(): Unit {
        let op = laterOperation; let value = laterCall; let other = laterPlan
        store.markExecuting(op, cut.run, other, 30, false).value().getOrThrow()
        store.markExecutionHandoff(op, cut.run, cut.thread, 31).value().getOrThrow()
        let outcome = cut.runtime.resolveOperation(ItemId("result-later"), op, CanonicalToolCallId(value.callId), other,
            OperationAttemptStage.Executing, Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(value.callId, objectValue([])))),
            "receipt-later", 32).value().getOrThrow()
        expect(outcome.semanticCommit.isSome() && isStoreCommitted(outcome.semanticCommit.getOrThrow()), "later unrelated operation still commits")
    }
    func close(): Unit { cut.close() }
}

func approvalContinuationSettlementContracts(): Unit {
    for (mode in ["approved", "failed", "rejected", "unknown", "decision-call", "decision-run", "decision-hash",
        "decision-missing", "approval-digest", "request-preview", "batch-cursor", "batch-missing", "batch-complete", "missing-receipt", "background", "rollback"]) {
        let f = ApprovalContinuationFixture(rejected: mode == "rejected")
        try {
            if (mode == "background") {
                f.save(WorkDebtSnapshot(unclaimedInputs: [InboxEntryId("unclaimed")], activeAttempts: [ModelAttemptId("other-attempt")],
                    uncommittedDecisions: [ModelDecisionId("other-decision")], unsettledOperations: [f.operation, OperationId("other-operation")],
                    pendingApprovals: [ApprovalId("legacy-approval-" + f.operation.value), ApprovalId("other-approval")],
                    waitingExternal: [ExternalHandleId("other-external")], activeChildRuns: [RunId("child")],
                    ownedTasks: [OwnedTaskId("task")], deferredContexts: [DeferredContextId("deferred")]))
            }
            if (mode.startsWith("decision-") && mode != "decision-missing") {
                let key = if (mode == "decision-call") { "call_id" } else if (mode == "decision-run") { "run_id" } else { "argument_hash" }
                let changed = parseUnifiedJson(stringifyUnifiedJson(f.decision)); changed.put(key, textValue("foreign"))
                f.cut.database.execute("UPDATE approval_decisions SET payload=?", [SqlParameter.Text(stringifyUnifiedJson(changed))])
            }
            if (mode == "decision-missing") { f.cut.database.execute("DELETE FROM approval_decisions") }
            if (mode == "approval-digest") { f.cut.database.execute("UPDATE approvals SET operation_digest='other'") }
            if (mode == "request-preview") {
                let changed = parseUnifiedJson(stringifyUnifiedJson(f.request))
                changed.field("approval").getOrThrow().put("preview", objectValue([ValueField("changed", boolValue(true))]))
                f.save(f.cut.continuation().workDebt, projection: Some(changed))
            }
            if (mode == "batch-cursor" || mode == "batch-missing") {
                f.save(f.cut.continuation().workDebt, batch: Some(ToolBatchContinuation(ToolBatchId("actual-batch"),
                    if (mode == "batch-cursor") { 0 } else { 2 }, [f.operation, OperationId("missing-batch-operation")])))
            }
            if (mode == "batch-complete" || mode == "missing-receipt") {
                f.save(f.cut.continuation().workDebt, batch: Some(ToolBatchContinuation(ToolBatchId("single-batch"),
                    if (mode == "batch-complete") { 1 } else { 0 }, [f.operation])))
            }
            if (mode == "rollback") { f.cut.database.execute("CREATE TRIGGER reject_approval_checkpoint BEFORE INSERT ON audit_events " +
                "WHEN NEW.kind='approval_continuation_settled' BEGIN SELECT RAISE(ABORT,'approval checkpoint fault'); END") }
            var before = f.cut.continuation(); let original = optionalRunRequestSnapshotFromDurableContinuation(before).getOrThrow()
            let outcome = f.resolve(mode)
            if (mode == "missing-receipt") {
                // A completed-looking operation alone cannot settle a delayed
                // batch's approval debt after its Receipt disappears.
                expect(f.cut.continuation().digest == before.digest, "unfinished batch preserves its exact pending continuation")
                f.cut.database.execute("DELETE FROM operation_receipts WHERE id='receipt-approval'")
                f.save(f.cut.continuation().workDebt, batch: Some(ToolBatchContinuation(ToolBatchId("single-batch"), 1, [f.operation])))
                before = f.cut.continuation(); f.extra()
            }
            let after = f.cut.continuation()
            let settles = ["approved", "failed", "rejected", "batch-complete", "background"].contains(mode)
            expect(f.cut.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='approval_continuation_settled'") ==
                (if (settles) { 1 } else { 0 }), "only proved known approval completion settles its debt: " + mode)
            if (settles) {
                expect(outcome.semanticCommit.isSome() && isStoreCommitted(outcome.semanticCommit.getOrThrow()) &&
                    runExecutionPhaseName(after.phase) == "checkpoint" && after.pendingOperationId.isNone() && after.pendingApprovalId.isNone() &&
                    after.modelLaneSnapshotId.value == before.modelLaneSnapshotId.value && after.compositionSnapshotId.value == before.compositionSnapshotId.value &&
                    encodeStoredValue(optionalRunRequestSnapshotFromDurableContinuation(after).getOrThrow()) == encodeStoredValue(original),
                    "the same canonical result transaction preserves exact request and lane: " + mode)
                if (mode == "background") {
                    let debt = after.workDebt
                    expect(debt.unclaimedInputs.size == 1 && debt.activeAttempts.size == 1 && debt.uncommittedDecisions.size == 1 &&
                        debt.unsettledOperations.size == 1 && debt.unsettledOperations[0].value == "other-operation" &&
                        debt.pendingApprovals.size == 1 && debt.pendingApprovals[0].value == "other-approval" && debt.waitingExternal.size == 1 &&
                        debt.activeChildRuns.size == 1 && debt.ownedTasks.size == 1 && debt.deferredContexts.size == 1,
                        "settlement removes only its exact operation/approval debt, including all nine debt families")
                    expect(f.cut.cut().isError(), "other foreground obligations still block a safe cut")
                } else {
                    let revision = f.cut.database.scalarInt("SELECT revision FROM run_continuations")
                    f.extra()
                    expect(f.cut.continuation().digest == after.digest && f.cut.database.scalarInt("SELECT revision FROM run_continuations") == revision &&
                        f.cut.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='approval_continuation_settled'") == 1,
                        "later canonical results do not re-settle or erase a completed checkpoint")
                    expect(f.cut.cut().isOk(), "proved approval completion permits the unchanged strict catalog cut")
                }
            } else {
                expect(after.digest == before.digest && after.pendingOperationId.getOrThrow().value == f.operation.value &&
                    !after.workDebt.pendingApprovals.isEmpty(), "negative evidence never clears the actual approval continuation: " + mode)
                expect(f.cut.cut().isError(), "the original strict safe-cut fence remains active: " + mode)
                if (mode == "unknown") {
                    expect(f.cut.database.query("SELECT outcome FROM operation_receipts WHERE id='receipt-approval'")[0].required(0) == "unknown" &&
                        f.cut.database.query("SELECT state FROM operations WHERE id='approval-operation'")[0].required(0) == "recovery_required",
                        "Unknown physical effects remain durable and cannot be converted to settled known work")
                }
                if (mode == "rollback") {
                    expect(outcome.semanticCommit.isSome() && !isStoreCommitted(outcome.semanticCommit.getOrThrow()) &&
                        f.cut.database.scalarInt("SELECT COUNT(*) FROM items WHERE id='result-approval'") == 0,
                        "late checkpoint write failure cannot half-commit a canonical result without its continuation")
                }
            }
        } finally { f.close() }
    }
    println("Store canonical approval continuation settlement contract passed: 16 scenarios")
}
