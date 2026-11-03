package agent_store_contract

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

class ContextReadApprovalRefusalFixture {
    let read = ContextReadStoreFixture()
    let source: DirectToolCallRef
    let request: AgentValue
    let decision: AgentValue
    init(choice!: String = "approve") {
        source = read.commit()
        read.store.prepareDirectOperation(source, read.plan).value().getOrThrow()
        read.store.waitForApproval(read.operation, read.run).value().getOrThrow()
        read.runtime.pauseForApproval().value().getOrThrow()
        let approval = ApprovalRequest(read.operation, read.call.callId, read.call.name, Capability(CapabilityKind.WorkspaceRead),
            preview: read.plan.canonicalArguments, sessionId: read.thread.value, argumentHash: "frozen-read-argument-hash")
        let requestSnapshot = objectValue([ValueField("kind", textValue("waiting_approval")), ValueField("run_id", textValue(read.run.value)),
            ValueField("session_id", textValue(read.thread.value)), ValueField("prompt", textValue("retained original request")),
            ValueField("skill_stack", contextSnapshotValue(InvocationContextProjection())),
            ValueField("approval", objectValue([ValueField("operation_id", textValue(read.operation.value)),
                ValueField("call_id", textValue(read.call.callId)), ValueField("tool_name", textValue(read.call.name)),
                ValueField("session_id", textValue(read.thread.value)), ValueField("preview", read.plan.canonicalArguments),
                ValueField("argument_hash", textValue(approval.argumentHash))]))])
        request = requestSnapshot
        let continuation = RunContinuation(read.run, SessionId(read.thread.value), "fixture", "read context", approval,
            contextSnapshotPayload: contextSnapshotValue(InvocationContextProjection()))
        read.database.transaction { tx => writeRunContinuationSnapshotProjection(tx, continuation, requestSnapshot) }
        expect(read.store.verifyContextReadApprovalPending(source, read.plan).isOk(),
            "actual waiting Run retains a sealed zero-handoff ContextRead approval")
        decision = objectValue([ValueField("version", integerValue(1)), ValueField("operation_id", textValue(read.operation.value)),
            ValueField("run_id", textValue(read.run.value)), ValueField("session_id", textValue(read.thread.value)),
            ValueField("call_id", textValue(read.call.callId)), ValueField("argument_hash", textValue(approval.argumentHash)),
            ValueField("decision", objectValue([ValueField("kind", textValue(choice))]))])
        // Exact existing public decision codec. Product/Core cases exercise
        // its production repository writer; this fixture never inserts a grant.
        read.database.execute("INSERT INTO approval_decisions(operation_id,run_id,payload,created_at_millis) VALUES (?,?,?,?)",
            [SqlParameter.Text(read.operation.value), SqlParameter.Text(read.run.value),
                SqlParameter.Text(stringifyUnifiedJson(decision)), SqlParameter.Int64Value(22)])
        read.runtime.resumeAfterApproval().value().getOrThrow()
    }
    func continuation(): DurableRunContinuationV1 {
        SqliteSemanticStore(read.database).continuation(read.run).value().getOrThrow()
    }
    func replaceProjection(value: AgentValue): Unit {
        let old = continuation(); let next = withRunRequestSnapshotProjection(old, value)
        read.database.execute("UPDATE run_continuations SET payload=?,digest=? WHERE run_id=? AND digest=?",
            [SqlParameter.Text(encodeDurableRunContinuation(next)), SqlParameter.Text(next.digest),
                SqlParameter.Text(read.run.value), SqlParameter.Text(old.digest)])
    }
    func retainOtherDebt(batch: Bool): Unit {
        let old = continuation()
        let next = withRunRequestSnapshotProjection(sealDurableRunContinuation(DurableRunContinuationV1(old.runId,
            old.laneId, old.turnId, old.stepOrdinal, old.phase, old.compositionSnapshotId, old.modelLaneSnapshotId,
            pendingOperationId: old.pendingOperationId, pendingApprovalId: old.pendingApprovalId,
            toolBatch: if (batch) { Some(ToolBatchContinuation(ToolBatchId("waiting-batch"), 0, [read.operation])) } else { None },
            workDebt: WorkDebtSnapshot(unsettledOperations: [read.operation, OperationId("other-operation")],
                pendingApprovals: [old.pendingApprovalId.getOrThrow(), ApprovalId("other-approval")],
                activeChildRuns: [RunId("other-child")], ownedTasks: [OwnedTaskId("other-task")],
                deferredContexts: [DeferredContextId("other-context")]))), request)
        // The fixture adds independent durable obligations, never a grant or
        // execution witness. Keep the live source owner; no recovery remint.
        read.database.execute("UPDATE run_continuations SET payload=?,digest=? WHERE run_id=? AND digest=?",
            [SqlParameter.Text(encodeDurableRunContinuation(next)), SqlParameter.Text(next.digest),
                SqlParameter.Text(read.run.value), SqlParameter.Text(old.digest)])
    }
    func resolve(unknown!: Bool = false): Result<RuntimeOperationResolution> {
        let result: Result<ToolInvocationResult> = if (unknown) {
            Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "fixture.read_unknown", "actual started read is uncertain"))
        } else {
            Result.Ok(ToolInvocationResult.Denied(ToolDenial(read.call.callId, read.call.name,
                AgentError(AgentErrorKind.Conflict, "context.read_source_stale", "original preparation was revoked before handoff"))))
        }
        read.runtime.resolveOperation(ItemId("result-" + read.operation.value), read.operation, CanonicalToolCallId(read.call.callId),
            read.plan, if (unknown) { OperationAttemptStage.Executing } else { OperationAttemptStage.Prepared },
            result, "receipt-" + read.operation.value, 30, expectedRunId: Some(read.run), expectedEpoch: Some(read.active.epoch))
    }
    func start(): Unit {
        read.store.recordApproval("approval-" + read.operation.value, read.operation, read.run, read.plan,
            CapabilitySet(values: read.plan.requiredCapabilities), true, "user").value().getOrThrow()
        read.store.markExecutingWithSource(Some(OperationRootSource.Direct(source)), read.operation, read.run, read.plan, 23, true).value().getOrThrow()
        read.store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)), read.operation, read.run, read.thread, 24).value().getOrThrow()
    }
    func close(): Unit { read.close() }
}

func contextReadApprovalRefusalContracts(): Unit {
    for (mode in ["stale", "reject", "decision-missing", "decision-call", "decision-run", "decision-hash", "decision-choice",
        "request-preview", "request-call", "plan", "admission", "epoch", "pending", "handoff", "reset-handoff",
        "receipt-reservation", "result-reservation", "batch-pending", "background", "unknown", "rollback"]) {
        let f = ContextReadApprovalRefusalFixture(choice: if (mode == "reject") { "reject" } else { "approve" })
        try {
            let db = f.read.database
            if (mode == "decision-missing") { db.execute("DELETE FROM approval_decisions") }
            if (["decision-call", "decision-run", "decision-hash", "decision-choice"].contains(mode)) {
                let changed = parseUnifiedJson(stringifyUnifiedJson(f.decision))
                let key = if (mode == "decision-call") { "call_id" } else if (mode == "decision-run") { "run_id" } else { "argument_hash" }
                if (mode == "decision-choice") { changed.put("decision", objectValue([ValueField("kind", textValue("invented"))])) }
                else { changed.put(key, textValue("foreign")) }
                db.execute("UPDATE approval_decisions SET payload=?", [SqlParameter.Text(stringifyUnifiedJson(changed))])
            }
            if (mode == "request-preview" || mode == "request-call") {
                let changed = parseUnifiedJson(stringifyUnifiedJson(f.request))
                changed.field("approval").getOrThrow().put(if (mode == "request-preview") { "preview" } else { "call_id" }, textValue("foreign"))
                f.replaceProjection(changed)
            }
            if (mode == "plan") {
                db.execute("UPDATE operations SET normalized_plan=replace(normalized_plan,'read-plan-binding','fake-plan-binding')")
                db.execute("UPDATE operation_effect_records SET normalized_plan=replace(normalized_plan,'read-plan-binding','fake-plan-binding')")
                expect(f.read.store.verifyContextReadApprovalPending(f.source, f.read.plan).isError(), "changed complete plan fails pending proof")
            }
            if (mode == "admission") {
                db.execute("DELETE FROM audit_events WHERE kind='context_read_admitted'")
                expect(f.read.store.verifyContextReadApprovalPending(f.source, f.read.plan).isError(), "origin audit is mandatory")
            }
            if (mode == "epoch") {
                db.execute("UPDATE runs SET epoch=epoch+1")
                expect(f.read.store.verifyContextReadApprovalPending(f.source, f.read.plan).isError(), "old source cannot approve a new epoch")
            }
            if (mode == "pending") {
                db.execute("UPDATE operations SET state='prepared'"); db.execute("UPDATE operation_state_registers SET state='prepared'")
                expect(f.read.store.verifyContextReadApprovalPending(f.source, f.read.plan).isError(), "a nonwaiting operation cannot consume the choice")
            }
            if (mode == "handoff" || mode == "reset-handoff" || mode == "unknown") {
                f.start()
                expect(f.read.store.verifyContextReadApprovalPending(f.source, f.read.plan).isError(), "an executed read is never a pending refusal")
                // Corrupt the grant row after a real handoff to prove its absence
                // cannot route started work through the new zero-grant branch.
                db.execute("DELETE FROM approvals")
                if (mode == "reset-handoff") {
                    db.execute("UPDATE operations SET state='waiting_approval'")
                    db.execute("UPDATE operation_state_registers SET state='waiting_approval'")
                    expect(f.read.store.verifyContextReadApprovalPending(f.source, f.read.plan).isError(),
                        "resetting state cannot erase the actual handoff")
                }
            }
            if (mode == "receipt-reservation") { db.execute("UPDATE operation_effect_records SET reserved_receipt_id='foreign-receipt'") }
            if (mode == "result-reservation") { db.execute("UPDATE operation_effect_records SET reserved_result_item_id='foreign-result'") }
            if (mode == "batch-pending" || mode == "background") { f.retainOtherDebt(mode == "batch-pending") }
            if (mode == "rollback") { db.execute("CREATE TRIGGER reject_stale_read_checkpoint BEFORE INSERT ON audit_events " +
                "WHEN NEW.kind='approval_continuation_settled' BEGIN SELECT RAISE(ABORT,'checkpoint fault'); END") }
            let before = f.continuation(); let outcome = f.resolve(unknown: mode == "unknown")
            let after = f.continuation(); let settles = mode == "stale" || mode == "reject" || mode == "background"
            expect(db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='approval_continuation_settled'") == (if (settles) { 1 } else { 0 }),
                "only exact unexecuted canonical refusal clears approval debt: " + mode)
            if (settles) {
                expect(outcome.isOk() && outcome.value().getOrThrow().semanticCommit.isSome() && isStoreCommitted(outcome.value().getOrThrow().semanticCommit.getOrThrow()) &&
                    after.pendingOperationId.isNone() && after.pendingApprovalId.isNone() &&
                    after.workDebt.unsettledOperations.size == (if (mode == "background") { 1 } else { 0 }) &&
                    after.workDebt.pendingApprovals.size == (if (mode == "background") { 1 } else { 0 }) && after.modelLaneSnapshotId.value == before.modelLaneSnapshotId.value &&
                    after.compositionSnapshotId.value == before.compositionSnapshotId.value &&
                    encodeStoredValue(optionalRunRequestSnapshotFromDurableContinuation(after).getOrThrow()) == encodeStoredValue(f.request),
                    "canonical Rejected result and exact request/lane checkpoint commit together")
                if (mode == "background") {
                    expect(after.workDebt.unsettledOperations[0].value == "other-operation" &&
                        after.workDebt.pendingApprovals[0].value == "other-approval" &&
                        after.workDebt.activeChildRuns[0].value == "other-child" && after.workDebt.ownedTasks[0].value == "other-task" &&
                        after.workDebt.deferredContexts[0].value == "other-context", "refusal cannot discard another foreground or background owner")
                }
                expect(db.scalarInt("SELECT COUNT(*) FROM approvals") == 0 &&
                    db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
                    db.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='rejected'") == 1 &&
                    db.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'") == 1 &&
                    db.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") == 1,
                    "refusal has one real result/Receipt, zero grant and zero IO handoff")
                expect(f.read.store.verifyContextReadApprovalPending(f.source, f.read.plan).isError(), "the completed choice cannot be consumed twice")
                let digest = after.digest; let repeated = f.resolve()
                expect(f.continuation().digest == digest && db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='approval_continuation_settled'") == 1 &&
                    (repeated.isError() || repeated.value().getOrThrow().semanticCommit.isNone() || !isStoreCommitted(repeated.value().getOrThrow().semanticCommit.getOrThrow())),
                    "duplicate settlement cannot append a second checkpoint or result")
            } else {
                expect(after.digest == before.digest && after.pendingOperationId.getOrThrow().value == f.read.operation.value &&
                    !after.workDebt.pendingApprovals.isEmpty(), "negative evidence retains the exact original debt: " + mode)
                if (mode == "unknown") {
                    expect(db.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'") == 1 &&
                        db.scalarInt("SELECT COUNT(*) FROM operations WHERE state='recovery_required'") == 1,
                        "real started Unknown remains Unknown with its approval obligation")
                }
                if (mode == "rollback") {
                    expect((outcome.isError() || (outcome.value().getOrThrow().semanticCommit.isSome() &&
                        !isStoreCommitted(outcome.value().getOrThrow().semanticCommit.getOrThrow()))) &&
                        db.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'") == 0 &&
                        db.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='approval_continuation_settled'") == 0,
                        "failed canonical transaction cannot clear debt; a separately retained fallback Receipt is insufficient")
                }
            }
        } finally { f.close() }
    }
    println("Store stale ContextRead approval settlement contract passed: 21 scenarios")
}
