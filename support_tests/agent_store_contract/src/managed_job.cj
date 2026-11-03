package agent_store_contract

import agent_domain.*
import agent_runtime.*
import agent_store.*
import yjson.*
import yjson_support.*

func managedJobFixtureDeclaration(): ManagedJobDeclaration {
    ManagedJobDeclaration("managed-test-job", ThreadId("managed-task-thread"), RunId("managed-task-run"), agentUtcMillis() + 60000, 4)
}

func managedJobReserve(fixture: ChannelIntentStoreFixture): Result<ManagedJobReservation> {
    fixture.runtime.reserveManagedJob(fixture.source, fixture.parent, fixture.rootPlan, fixture.store, fixture.run, fixture.epoch)
}

func managedJobCommitLaunch(fixture: ChannelIntentStoreFixture, reservation: ManagedJobReservation,
    wrongResult!: Bool = false, unknown!: Bool = false): Unit {
    let result = if (wrongResult) { ToolResult(fixture.call.callId, objectValue([ValueField("status", textValue("completed"))])) }
        else { reservation.launchResult() }
    let attempt: Result<ToolInvocationResult> = if (unknown) {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "fixture.launch_unknown", "unknown launch"))
    } else { Result.Ok(ToolInvocationResult.Completed(result)) }
    let resolved = httpContractRequire(fixture.runtime.resolveOperation(ItemId("managed-launch-result"), fixture.parent,
        CanonicalToolCallId(fixture.call.callId), fixture.rootPlan, OperationAttemptStage.Executing,
        attempt, "managed-launch-receipt", agentUtcMillis(), expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch)),
        "managed launch commits its actual Receipt and ToolResult")
    expect(resolved.semanticCommit.isSome() && isStoreCommitted(resolved.semanticCommit.getOrThrow()), "managed launch canonical settlement succeeds")
}

func managedJobFoundationContract(): Unit {
    var count: Int64 = 0
    for (committed in [false, true]) {
        for (scenario in ["completed", "pending", "approval-needed", "no-handoff", "already-wrote", "cancel-before-claim",
            "cancel-after-claim", "mutated-result", "mutated-plan", "epoch", "recovery", "unknown", "mutable-input", "parent-cancel"]) {
            managedJobFoundationScenario(committed, scenario)
            count += 1
        }
    }
    expect(count == 28, "all 28 managed launch scenarios execute for real Direct and Committed SQLite facts")
    println("Managed job launch foundation contract passed: 28 scenarios; no background executor is registered")
}

func managedJobFoundationScenario(committed: Bool, scenario: String): Unit {
    let fixture = ChannelIntentStoreFixture(committed, managedJob: Some(managedJobFixtureDeclaration()))
    try {
        if (scenario == "approval-needed") {
            expect(managedJobReserve(fixture).isError() && fixture.database.scalarInt(
                "SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_reserved'") == 0,
                "unapproved prepared parent cannot reserve a job or bypass its frozen approval")
            return
        }
        fixture.activateParent(handoff: scenario != "no-handoff")
        if (scenario == "no-handoff") {
            expect(managedJobReserve(fixture).isError(), "executing without actual handoff is not a delegated launch")
            return
        }
        if (scenario == "already-wrote") {
            httpContractRequire(fixture.admit(), "real child admission")
            expect(managedJobReserve(fixture).isError(), "a partially admitted intent batch cannot also delegate its writes")
            return
        }
        let reservation = httpContractRequire(managedJobReserve(fixture), "current Runtime reserves exact approved launch")
        expect(managedJobReserve(fixture).isError() && fixture.database.scalarInt(
            "SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_reserved'") == 1,
            "one parent can reserve only one immutable job, including after retries")
        expect(reservation.claim().isError() && fixture.database.scalarInt(
            "SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'") == 0,
            "reservation alone is powerless before parent Receipt and ToolResult commit")
        if (scenario == "pending") { return }
        if (scenario == "cancel-before-claim") {
            reservation.cancel()
            managedJobCommitLaunch(fixture, reservation)
            expect(reservation.claim().isError() && fixture.database.scalarInt(
                "SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'") == 0,
                "caller cancellation before claim creates no child admission")
            return
        }
        if (scenario == "recovery") {
            let active = fixture.runtime.activeRun().getOrThrow()
            let recovered = AgentThreadRuntime(ThreadCoordinator(fixture.sink.loadThread(fixture.thread), fixture.sink),
                ContextProjector("managed-recovery", StoreEstimator()), RecoveredRunSpec(fixture.turn, fixture.run,
                    active.epoch, RunState.Running, active.transitionSequence, recoveryLane(), InvocationContextProjection()), { => agentUtcMillis() })
            expect(recovered.reserveManagedJob(fixture.source, fixture.parent, fixture.rootPlan, fixture.store,
                fixture.run, fixture.epoch).isError(), "recovery can inspect original job evidence but cannot mint a reservation")
            return
        }
        managedJobCommitLaunch(fixture, reservation, wrongResult: scenario == "mutated-result", unknown: scenario == "unknown")
        if (scenario == "mutated-result" || scenario == "unknown") {
            expect(reservation.claim().isError(), "wrong or Unknown launch result never starts a background command")
            return
        }
        if (scenario == "epoch") {
            fixture.database.execute("UPDATE runs SET epoch=epoch+1 WHERE id=?", [SqlParameter.Text(fixture.run.value)])
            expect(reservation.claim().isError(), "changed parent epoch cannot validate an old delegation")
            return
        }
        if (scenario == "mutated-plan") {
            let original = fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(fixture.parent.value)])[0].required(0)
            let altered = decodeStoredValue(original)
            altered.field("arguments").getOrThrow().field("host_plan").getOrThrow().field("intents").getOrThrow().items[0].put("bytes_hex", textValue("6576696c0a"))
            let changed = encodeStoredValue(altered)
            expect(changed != original, "plan mutation really changes valid durable encoded command bytes")
            fixture.database.execute("UPDATE operations SET normalized_plan=? WHERE id=?", [SqlParameter.Text(changed), SqlParameter.Text(fixture.parent.value)])
            fixture.database.execute("UPDATE operation_effect_records SET normalized_plan=? WHERE operation_id=?", [SqlParameter.Text(changed), SqlParameter.Text(fixture.parent.value)])
            expect(fixture.database.query("SELECT normalized_plan FROM operations WHERE id=?", [SqlParameter.Text(fixture.parent.value)])[0].required(0) == changed,
                "actual stored plan is the precisely mutated framed value")
            let reloaded = httpContractRequire(fixture.store.loadPlan(fixture.parent, fixture.run), "mutated stored plan still uses the valid complete plan codec")
            expect(reloaded.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items[0].field("bytes_hex").getOrThrow().text == "6576696c0a",
                "public plan loader observes the intended command mutation")
            expect(reservation.claim().isError(), "complete plan digest refuses command drift even when mutable plan/effect records agree")
            return
        }
        if (scenario == "mutable-input") {
            let original = managedJobLaunchDigest(reservation.binding)
            fixture.rootPlan.canonicalArguments.field("host_plan").getOrThrow().field("managed_job").getOrThrow().put("job_id", textValue("changed"))
            expect(managedJobLaunchDigest(reservation.binding) == original, "caller mutation cannot alter frozen launch binding")
        }
        if (scenario == "completed") {
            httpContractRequire(fixture.runtime.finish(RunState.Completed, 1000), "foreground Run can complete after delegation")
        }
        let admission = httpContractRequire(reservation.claim(), "completed exact launch admits only the original job")
        expect(admission.validateLaunch().isOk() && reservation.claim().isError() && fixture.store.claimManagedJobLaunch(admission.binding).isError() &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='managed_job_claimed'") == 1,
            "one live admission corresponds to one durable claim and cannot be replayed through primitive Store entry")
        expect(fixture.database.scalarInt("SELECT COUNT(*) FROM runs WHERE id='managed-task-run'") == 0 &&
            fixture.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions WHERE parent_operation_id='channel-parent'") == 0,
            "launch authority does not fabricate child execution, ToolResult or receipt")
        if (scenario == "parent-cancel") {
            httpContractRequire(fixture.runtime.cancel(1000, expectedRunId: Some(fixture.run), expectedEpoch: Some(fixture.epoch)),
                "actual parent Run cancellation")
            expect(admission.cancellationToken.isCancelled() && admission.validateLaunch().isError(),
                "actual parent cancellation propagates through the retained launch subscription")
        }
        if (scenario == "cancel-after-claim") {
            reservation.cancel()
            expect(admission.cancellationToken.isCancelled() && admission.validateLaunch().isError(),
                "explicit Task cancellation remains live after the launch has been claimed")
        }
        admission.detachParentAfterCleanup()
        expect(fixture.database.query("PRAGMA foreign_key_check").isEmpty(), "job witness preserves existing relational invariants")
    } finally { fixture.close() }
}
