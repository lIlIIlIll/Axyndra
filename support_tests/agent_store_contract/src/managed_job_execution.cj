package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.time.*
import yjson.*
import yjson_support.*

func managedJobExecutionContract(): Unit {
    var count: Int64 = 0
    for (committed in [false, true]) {
        for (scenario in ["completed", "wrong-thread", "repeated-owner", "repeated-call", "wrong-call",
            "primitive-prepare", "primitive-execute", "primitive-handoff", "changed-plan", "cancel-before-prepare",
            "cancel-before-execute", "cancel-before-handoff", "cancel-after-handoff", "parent-cancel", "recovered-owner",
            "changed-origin", "changed-parent", "changed-epoch", "downgrade",
            "service-other-parent", "service-other-lease", "service-cancelled"]) {
            managedJobExecutionScenario(committed, scenario)
            count += 1
        }
    }
    expect(count == 44, "all 44 managed child Run source scenarios execute for real Direct and Committed launches")
    println("Managed job execution source contract passed: 44 scenarios; actual child Run/Operation/ParentIntent/Receipt, no OS executor")
}

func managedJobExecutionScenario(committed: Bool, scenario: String): Unit {
    let fixture = ChannelIntentStoreFixture(committed, managedJob: Some(managedJobFixtureDeclaration()))
    try {
        fixture.activateParent()
        let reservation = httpContractRequire(managedJobReserve(fixture), "reserve actual foreground launch")
        managedJobCommitLaunch(fixture, reservation)
        if (scenario != "parent-cancel") { httpContractRequire(fixture.runtime.finish(RunState.Completed, agentUtcMillis()), "foreground can end before task starts") }
        let admission = httpContractRequire(reservation.claim(), "one live Task admission")
        let binding = admission.binding
        let target = if (scenario == "wrong-thread") { ThreadId("another-task-thread") } else { binding.declaration.threadId }
        let coordinator = ThreadCoordinator(fixture.sink.createThread(target, "workspace"), fixture.sink)
        let task = AgentThreadRuntime(coordinator, ContextProjector("managed-task", StoreEstimator()), { => agentUtcMillis() })
        let started = task.startManagedJobTurn(admission, SemanticTurnId("managed-turn"), ItemId("managed-initiator"),
            recoveryLane(), InvocationContextProjection())
        if (scenario == "wrong-thread") {
            expect(started.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE id='managed-task-run'") == 0,
                "sealed Task admission cannot be moved to another Thread")
            return
        }
        let active = httpContractRequire(started, "actual child Task Run starts with canonical SystemNote")
        expect(task.projectContext().isError(), "zero-model Task owner cannot create a model context or Attempt")
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='managed-task-thread' AND kind='user_message'") == 0 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='managed-task-thread' AND kind='system_note'") == 1,
            "Task startup is not a fabricated user prompt or model Decision")
        if (scenario == "repeated-owner") {
            expect(task.startManagedJobTurn(admission, SemanticTurnId("another-turn"), ItemId("another-initiator"),
                recoveryLane(), InvocationContextProjection()).isError(), "one live launch cannot start a second child owner")
            return
        }
        let parentPlan = httpContractRequire(admission.frozenPlan(), "load exact reviewed parent plan")
        let operation = OperationId("managed-execution")
        let item = ItemId("managed-execution-call")
        let actualCall = if (scenario == "wrong-call") { ToolCall(fixture.call.callId, fixture.call.name, objectValue([ValueField("query", textValue("changed"))])) }
            else { fixture.call }
        let callResult = task.commitManagedJobToolCall(admission, item, operation, actualCall, active.runId, active.epoch)
        if (scenario == "wrong-call") {
            expect(callResult.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM items WHERE thread_id='managed-task-thread' AND kind='tool_call'") == 0,
                "Task cannot rewrite the original canonical call or argument bytes")
            return
        }
        let root = httpContractRequire(callResult, "Runtime mints actual current Task call source")
        let source = OperationRootSource.Direct(root)
        if (scenario == "repeated-call") {
            expect(task.commitManagedJobToolCall(admission, ItemId("second-task-call"), OperationId("second-task-op"),
                fixture.call, active.runId, active.epoch).isError(), "one claimed job cannot commit another call")
            return
        }
        if (scenario == "recovered-owner") {
            let recovered = AgentThreadRuntime(ThreadCoordinator(fixture.sink.loadThread(target), fixture.sink),
                ContextProjector("managed-recovered", StoreEstimator()), RecoveredRunSpec(active.turnId, active.runId,
                    active.epoch, RunState.Running, active.transitionSequence, recoveryLane(), InvocationContextProjection()), { => agentUtcMillis() })
            expect(recovered.attestDirectToolCall(item, operation, active.runId, active.epoch).isError(),
                "recovered Task provenance remains readable but cannot recreate its execution seal")
            return
        }
        if (scenario == "changed-origin") {
            let row = fixture.database.query("SELECT provenance FROM items WHERE id=?", [SqlParameter.Text(item.value)])[0].required(0)
            let changed = decodeStoredValue(row)
            changed.field("direct_origin").getOrThrow().field("launch").getOrThrow().put("parent_epoch", integerValue(binding.parentEpoch + 1))
            let encoded = encodeStoredValue(changed)
            expect(encoded != row && decodeStoredProvenance(encoded).directOrigin.isSome(), "valid framed origin mutation is real")
            fixture.database.execute("UPDATE items SET provenance=? WHERE id=?", [SqlParameter.Text(encoded), SqlParameter.Text(item.value)])
        }
        if (scenario == "changed-parent") {
            fixture.database.execute("UPDATE operation_receipts SET outcome='unknown' WHERE operation_id=?", [SqlParameter.Text(binding.parentOperationId.value)])
        }
        if (scenario == "changed-epoch") {
            fixture.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id=?", [SqlParameter.Text(active.runId.value)])
        }
        if (scenario == "cancel-before-prepare") { reservation.cancel() }
        if (scenario == "primitive-prepare") {
            expect(fixture.store.prepareTrustedControlOperation(operation, active.runId, item, parentPlan).isError() &&
                fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='managed-execution'") == 0,
                "primitive IDs plus descriptive Task origin cannot bypass the live Runtime seal")
            return
        }
        let plan = if (scenario == "changed-plan") {
            let originalArguments = canonicalAgentValue(parentPlan.canonicalArguments)
            let altered = httpContractRequire(fixture.store.loadPlan(fixture.parent, fixture.run), "reload independent original parent plan through the public Store API")
            altered.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items[0].put("bytes_hex", textValue("6576696c0a"))
            expect(canonicalAgentValue(parentPlan.canonicalArguments) == originalArguments &&
                canonicalAgentValue(altered.canonicalArguments) != originalArguments, "changed child plan never mutates the admitted parent plan")
            altered
        } else { parentPlan }
        let prepared = fixture.store.prepareDirectOperation(root, plan)
        if (["changed-plan", "cancel-before-prepare", "changed-origin", "changed-parent", "changed-epoch"].contains(scenario)) {
            expect(prepared.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='managed-execution'") == 0,
                "changed source, epoch, launch, bytes or cancellation is rejected before execution")
            return
        }
        httpContractRequire(prepared, "prepare Task operation with the immutable original plan")
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM approvals WHERE operation_id='managed-execution'") == 0,
            "Task does not fabricate a second user approval")
        if (scenario == "downgrade") {
            let initial = fixture.database.query("SELECT provenance FROM items WHERE id='managed-initiator'")[0].required(0)
            let rewrittenInitial = decodeStoredValue(initial)
            rewrittenInitial.put("source", textValue("user"))
            rewrittenInitial.put("direct_origin", directCallOriginValue(DirectCallOrigin.UserDirect))
            let callProvenance = fixture.database.query("SELECT provenance FROM items WHERE id=?", [SqlParameter.Text(item.value)])[0].required(0)
            let rewrittenCall = decodeStoredValue(callProvenance)
            rewrittenCall.put("direct_origin", directCallOriginValue(DirectCallOrigin.UserDirect))
            let changedCall = encodeStoredValue(rewrittenCall)
            let changedInitial = encodeStoredValue(rewrittenInitial)
            expect(changedCall != callProvenance && changedInitial != initial &&
                sameDirectCallOrigin(effectiveDirectCallOrigin(decodeStoredProvenance(changedCall)), DirectCallOrigin.UserDirect) &&
                sameDirectCallOrigin(effectiveDirectCallOrigin(decodeStoredProvenance(changedInitial)), DirectCallOrigin.UserDirect),
                "Task downgrade changes both actual framed records to decodable ordinary origins")
            fixture.database.execute("UPDATE items SET provenance=? WHERE id=?", [SqlParameter.Text(changedCall), SqlParameter.Text(item.value)])
            fixture.database.execute("UPDATE items SET provenance=? WHERE id='managed-initiator'", [SqlParameter.Text(changedInitial)])
            expect(fixture.store.markExecuting(operation, active.runId, plan, agentUtcMillis(), false).isError(),
                "Task origin audit prevents primitive-ID execution after attempted downgrade")
            return
        }
        if (scenario == "primitive-execute") {
            expect(fixture.store.markExecuting(operation, active.runId, plan, agentUtcMillis(), false).isError(),
                "old primitive execution API cannot advance a sealed Task operation")
            return
        }
        if (scenario == "cancel-before-execute") {
            reservation.cancel()
            expect(fixture.store.markExecutingWithSource(Some(source), operation, active.runId, plan, agentUtcMillis(), false).isError(),
                "Task cancellation closes the pre-execution source fence")
            return
        }
        httpContractRequire(fixture.store.markExecutingWithSource(Some(source), operation, active.runId, plan,
            agentUtcMillis(), false), "Task operation executes under exact completed launch proof")
        if (scenario == "primitive-handoff") {
            expect(fixture.store.markExecutionHandoff(operation, active.runId, target, agentUtcMillis()).isError(),
                "primitive handoff cannot launder Task source")
            return
        }
        if (scenario == "cancel-before-handoff") {
            reservation.cancel()
            expect(fixture.store.markExecutionHandoffWithSource(Some(source), operation, active.runId, target, agentUtcMillis()).isError(),
                "cancellation between execution and handoff prevents dispatch")
            return
        }
        httpContractRequire(fixture.store.markExecutionHandoffWithSource(Some(source), operation, active.runId,
            target, agentUtcMillis()), "Task handoff records its real child Run/epoch")
        let serviceBinding = plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        httpContractRequire(fixture.store.verifyChannelInvocationRoot(operation, active.runId, target, active.epoch,
            source, plan, serviceBinding), "actual Task source alone may retain its original lease target binding")
        if (scenario.startsWith("service-")) {
            let changed = channelContractClone(serviceBinding)
            if (scenario == "service-other-parent") { changed.put("target_thread_id", textValue("other-parent-thread")) }
            if (scenario == "service-other-lease") { changed.put("lease_id", textValue("other-lease")) }
            if (scenario == "service-cancelled") {
                reservation.cancel()
                expect(root.validateLiveSource().isError(), "actual cancelled Task loses its live execution seal")
                expect(fixture.store.prepareDerivedOperation(OperationId("cancelled-service-write"), operation,
                    active.runId, source, fixture.key, fixture.childPlan).isError(),
                    "cancelled live Task cannot admit a new write while durable facts still exist")
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE id='cancelled-service-write'") == 0,
                    "live cancellation refusal creates no write Operation")
                httpContractRequire(fixture.store.verifyChannelInvocationRoot(operation, active.runId, target, active.epoch,
                    source, plan, changed), "unchanged durable proof does not restore the cancelled live authority")
                // The root query reconstructs persisted facts; a token signal
                // does not alter those rows. Enter real Cancelling through the
                // exact live Runtime owner before asserting durable refusal.
                httpContractRequire(task.beginCancellationSettlement(active.runId, active.epoch),
                    "actual cancelled Task transitions its durable owner without authorizing new I/O")
                expect(fixture.database.query("SELECT state FROM runs WHERE id=?",
                    [SqlParameter.Text(active.runId.value)])[0].required(0) == "cancelling",
                    "durable root refusal is checked after the actual Runtime transition")
            }
            let verified = fixture.store.verifyChannelInvocationRoot(operation, active.runId, target, active.epoch,
                source, plan, changed)
            println("MANAGED_STORE_DIAGNOSTIC scenario=" + scenario + " committed=" + committed.toString() +
                " outcome=" + match (verified) { case Result.Ok(_) => "ok"; case Result.Err(error) => error.code })
            expect(verified.isError(), "actual SQLite Task proof rejects wrong service binding or revoked owner")
            expect(fixture.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id='managed-execution'") == 0,
                "rejected service proof creates no derived write or handoff")
            return
        }
        let child = OperationId("managed-write")
        httpContractRequire(fixture.store.prepareDerivedOperation(child, operation, active.runId, source,
            fixture.key, fixture.childPlan), "Task derives only the originally frozen write intent")
        httpContractRequire(fixture.store.markExecutingWithSource(Some(source), child, active.runId, fixture.childPlan,
            agentUtcMillis(), false), "Task's derived write has exact ParentIntent authority")
        httpContractRequire(fixture.store.markExecutionHandoffWithSource(Some(source), child, active.runId, target,
            agentUtcMillis()), "write handoff belongs to the Task, never the completed foreground Run")
        let cancelled = scenario == "cancel-after-handoff" || scenario == "parent-cancel"
        let settle = { =>
            let reservedReceipt = fixture.database.query("SELECT reserved_receipt_id FROM operation_effect_records WHERE operation_id=?",
                [SqlParameter.Text(child.value)])[0].required(0)
            expect(reservedReceipt == "receipt-" + child.value, "write receipt uses the immutable identity reserved at actual admission")
            let receipt = VNextOperationReceipt(reservedReceipt, child,
                if (cancelled) { OperationOutcome.Unknown } else { OperationOutcome.Completed },
                objectValue([ValueField("written_bytes", integerValue(6))]), objectValue([]), agentUtcMillis())
            httpContractRequire(fixture.store.settleDerivedOperation(active.runId, operation, receipt),
                "actual write receipt settles even after child or parent cancellation")
            let outcome: Result<ToolInvocationResult> = if (cancelled) {
                Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "fixture.managed_unknown", "actual Task write may have executed"))
            } else { Result.Ok(ToolInvocationResult.Completed(ToolResult(fixture.call.callId, objectValue([ValueField("done", boolValue(true))])))) }
            let settled = httpContractRequire(task.resolveOperation(ItemId("managed-execution-result"), operation,
                CanonicalToolCallId(fixture.call.callId), plan, OperationAttemptStage.Executing, outcome,
                "managed-execution-receipt", agentUtcMillis(), expectedRunId: Some(active.runId), expectedEpoch: Some(active.epoch)),
                "Task root records actual outcome without replacing the completed launch")
            expect(settled.semanticCommit.isSome() && isStoreCommitted(settled.semanticCommit.getOrThrow()), "Task root result is canonical")
        }
        if (cancelled) {
            let token = httpContractRequire(task.childCancellationToken(expectedRunId: Some(active.runId),
                expectedEpoch: Some(active.epoch)), "owned Task cleanup cancellation token")
            let cleanup = spawn {
                let deadline = agentUtcMillis() + 3000
                while ((!token.isCancelled() || fixture.database.query("SELECT state FROM runs WHERE id=?",
                    [SqlParameter.Text(active.runId.value)])[0].required(0) != "cancelling") && agentUtcMillis() < deadline) {
                    sleep(Duration.millisecond)
                }
                expect(token.isCancelled() && fixture.database.query("SELECT state FROM runs WHERE id=?",
                    [SqlParameter.Text(active.runId.value)])[0].required(0) == "cancelling",
                    "owned Task cleanup observes the actual cancelling Run before settlement")
                expect(fixture.store.verifyChannelInvocationRoot(operation, active.runId, target, active.epoch,
                    source, plan, serviceBinding).isError(), "cancelled Task can no longer perform channel I/O")
                settle()
            }
            httpContractRequire(task.ownTask("managed-write-settlement", cleanup), "Run owns the actual settlement worker")
            if (scenario == "parent-cancel") {
                httpContractRequire(fixture.runtime.cancel(5000, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch)),
                    "actual parent cancellation propagates into the child owner")
                expect(root.externalCancellationToken.getOrThrow().isCancelled(), "Task token is linked to original parent cancellation")
            }
            reservation.cancel()
            let cancellation = task.cancel(5000, expectedRunId: Some(active.runId), expectedEpoch: Some(active.epoch))
            cleanup.get()
            httpContractRequire(cancellation, "Task cancellation joins its actual receipt settlement worker")
            expect(fixture.database.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(active.runId.value)])[0].required(0) == "cancelled",
                "Task only reaches terminal cancellation after its actual canonical results settle")
        } else {
            settle()
            httpContractRequire(task.finish(RunState.Completed, 5000), "Task finishes after settlement")
        }
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id='channel-parent' AND outcome='completed'") == 1 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id IN ('managed-execution','managed-write')") == 2,
            "launch and actual task root/write outcomes remain separate canonical facts")
        expect(fixture.database.query("PRAGMA foreign_key_check").isEmpty(), "managed execution preserves all foreign keys")
        admission.detachParentAfterCleanup()
    } finally { fixture.close() }
}
