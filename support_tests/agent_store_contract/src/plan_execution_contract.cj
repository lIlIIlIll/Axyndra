package agent_store_contract

import yjson.*
import yjson_support.*
import std.fs.*
import std.env.*
import std.convert.*
import std.collection.*
import agent_domain.*
import agent_runtime.*
import agent_store.*

func planExecutionPersistenceContract(): Unit {
    beginPlanTestReadFrame204()
    try { planExecutionPersistenceContractFrame204() } finally { finishPlanTestReadFrame204() }
}
func planExecutionPersistenceContractFrame204(): Unit {
    println("Plan store contract phase: historical migration")
    let root = Directory.createTemp(getVariable("TMPDIR").getOrDefault({ => "/tmp" })).toString()
    planExecutionMigrationContract(root)
    let path = root + "/plan-contract.db"
    let database = SqliteDatabase(path)
    println("Plan store contract phase: canonical fixtures and shared delegation")
    let delegation = planStoreFixture(database, "delegation", "task")
    let probe = planStoreFixture(database, "probe", "command_probe")
    let fallback = planStoreFixture(database, "fallback", "write")
    let independent = planStoreFixture(database, "independent", "write")
    let blocked = planStoreFixture(database, "blocked", "write")
    let retry = planStoreFixture(database, "retry", "command_probe")
    let child = planStoreFixture(database, "child", "command_probe")
    let ownerSession = delegation.threadId.value
    let contract = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("acquire"), [], true,
            [planStoreAction("acquire-package", "command_probe")], fallbackStepId: Some("cdn")),
        PlanExecutionStep(PlanStepId("cdn"), [], false, [planStoreAction("write-cdn", "write")]),
        PlanExecutionStep(PlanStepId("source"), [], true, [planStoreAction("write-source", "write")]),
        PlanExecutionStep(PlanStepId("verify"), ["acquire", "source"], true,
            [planStoreAction("verify-source", "write")]),
        PlanExecutionStep(PlanStepId("delegation"), [], false, [planStoreAction("delegate", "task",
            delegatedActionIds: ["acquire-package", "write-cdn", "write-source", "verify-source"])])
    ])
    let plans = paidPlanTestStore204(database)
    expect(plans.activate("execution", ownerSession, contract).isOk(), "approval persists an immutable executable contract")
    expect(plans.bindRun("execution", "other-session", probe.runId).isError(), "execution cannot be borrowed by another session")
    expect(plans.bindRun("execution", ownerSession, delegation.runId).isOk() &&
        plans.admit(delegation.runId, delegation.operationId, "delegation", "delegate", delegation.plan).isOk(),
        "delegating task is admitted under the owning approved plan")
    planStoreHandoff(database, delegation)
    for (fixture in [probe, fallback, independent, blocked, retry]) {
        expect(plans.inherit(delegation.runId, fixture.threadId.value, delegation.operationId).isOk(), "canonical child session inherits admitted delegation")
        expect(plans.bindRun("execution", fixture.threadId.value, fixture.runId).isOk(), "all Runs of one execution share its budget")
    }
    expect(plans.inherit(delegation.runId, child.threadId.value, delegation.operationId).isOk() &&
        plans.bindRun("execution", child.threadId.value, child.runId).isOk() &&
        !plans.isPlanOwner(child.runId).value().getOrThrow() && plans.isPlanOwner(delegation.runId).value().getOrThrow(),
        "child session inherits the same execution without taking global completion ownership")
    planTestChildProjection204(plans, child.runId)
    planStoreSettle(database, delegation, OperationOutcome.Completed, objectValue([]))
    expect(plans.activate("child-execution", child.threadId.value, contract).isError(),
        "inherited child cannot replace the execution to reset the shared action budget")
    expect(plans.admit(blocked.runId, blocked.operationId, "verify", "verify-source", blocked.plan).isError(),
        "dependent work cannot run before canonical verification of prerequisites")
    expect(plans.admit(fallback.runId, fallback.operationId, "cdn", "write-cdn", fallback.plan).isError(),
        "fallback is dormant before a failure selects it")
    expect(plans.admit(probe.runId, probe.operationId, "acquire", "acquire-package", probe.plan).isOk(),
        "approved dependency probe reserves its single attempt")
    expect(plans.admit(probe.runId, probe.operationId, "", "", probe.plan).isOk(),
        "recovery reuses the immutable existing Operation binding without another attempt")
    let broadened = NormalizedOperationPlan("command_probe", probe.plan.canonicalArguments,
        probe.plan.requiredCapabilities, probe.plan.effectClass, probe.plan.retryDisposition, probe.plan.bindingDigest,
        cwd: probe.plan.cwd, approvedWriteRoots: ["/"], toolVersion: "1",
        implementationFingerprint: "implementation", schemaDigest: "schema")
    expect(paidPlanOperationStore204(database).markExecuting(probe.operationId, probe.runId, broadened, 3, false).isError() &&
        paidPlanOperationStore204(database).loadPlan(probe.operationId, probe.runId).value().getOrThrow().approvedWriteRoots[0] == "/workspace",
        "pre-effect preparation rejects a broadened write mount even when the caller reuses the old binding digest")
    expect(plans.admit(retry.runId, retry.operationId, "acquire", "acquire-package", retry.plan).isError() &&
        plans.admit(child.runId, child.operationId, "acquire", "acquire-package", child.plan).isError(),
        "concurrent, child, or restarted probe cannot replenish the shared action budget")
    let backupPath = root + "/approved-plan-backup.db"
    println("Plan store contract phase: full database backup")
    database.backupTo(backupPath)
    let archived = SqliteDatabase(backupPath)
    try {
        let restoredPlan = paidPlanTestStore204(archived)
        expect(planTestHasScope204(restoredPlan, ownerSession) &&
            planTestObserve204(restoredPlan, probe.runId, probe.operationId).decision == "pending" &&
            restoredPlan.admit(retry.runId, retry.operationId, "acquire", "acquire-package", retry.plan).isError(),
            "full database archive restores immutable approval, task delegation, and spent pending budget")
    } finally { archived.close() }
    println("Plan store contract phase: reconnect pending reservation")
    let reconnected = SqliteDatabase(path)
    try {
        let recoveredPending = paidPlanTestStore204(reconnected)
        expect(recoveredPending.admit(retry.runId, retry.operationId, "acquire", "acquire-package", retry.plan).isError() &&
            planTestObserve204(recoveredPending, probe.runId, probe.operationId).decision == "pending",
            "fresh connection reconstructs a spent unresolved reservation without replay")
    } finally { reconnected.close() }
    expect(planTestObserve204(plans, probe.runId, probe.operationId).decision == "pending" &&
        plans.requireComplete(probe.runId).isError(), "unsettled reservation is pending and cannot complete the plan")
    println("Plan store contract phase: canonical fallback and independent evidence")
    planStoreSettle(database, probe, OperationOutcome.Rejected, objectValue([
        ValueField("failure_class", textValue("infrastructure_unavailable")),
        ValueField("started", boolValue(false)), ValueField("fallback_allowed", boolValue(false)), ValueField("retryable", boolValue(false))]))
    let observed = planTestObserve204(plans, probe.runId, probe.operationId)
    expect(observed.decision == "fallback" && observed.fallbackStepId.getOrThrow() == "cdn",
        "committed infrastructure failure selects only the approved fallback")
    expect(planTestObserve204(plans, probe.runId, probe.operationId).receiptId == observed.receiptId,
        "receipt observation is idempotent")
    expect(plans.admit(retry.runId, retry.operationId, "acquire", "acquire-package", retry.plan).isError(),
        "switching Run or operation identity does not reset the probe limit")
    database.execute("CREATE TRIGGER reject_plan_admission BEFORE INSERT ON plan_action_admissions BEGIN SELECT RAISE(ABORT,'reservation fault'); END")
    expect(plans.admit(independent.runId, independent.operationId, "source", "write-source", independent.plan).isError(),
        "reservation failure rolls back atomically before effects")
    database.execute("DROP TRIGGER reject_plan_admission")
    expect(plans.admit(independent.runId, independent.operationId, "source", "write-source", independent.plan).isOk(),
        "independent source work can continue after dependency failure")
    planStoreSettle(database, independent, OperationOutcome.Completed, objectValue([]))
    expect(plans.admit(fallback.runId, fallback.operationId, "cdn", "write-cdn", fallback.plan).isOk(),
        "selected approved fallback can execute")
    planStoreSettle(database, fallback, OperationOutcome.Completed, objectValue([]))
    expect(plans.requireComplete(probe.runId).isError(), "fallback success alone cannot skip required downstream verification")
    expect(plans.admit(blocked.runId, blocked.operationId, "verify", "verify-source", blocked.plan).isOk(),
        "dependent step becomes runnable after fallback and independent source evidence")
    planStoreSettle(database, blocked, OperationOutcome.Completed, objectValue([]))
    expect(plans.requireComplete(probe.runId).isOk(), "required steps complete only after all canonical receipts satisfy the contract")
    let oldContract = PlanContract(["/elsewhere"], contract.steps)
    expect(plans.activate("execution", ownerSession, oldContract).isError(), "approved execution contract cannot be rewritten in place")
    println("Plan store contract phase: terminal failure classes")
    planExecutionStopsContract(database)
    println("Plan store contract phase: stale evidence")
    planExecutionStaleEvidenceContract(database)
    println("Plan store contract phase: independent verification receipts")
    planExecutionReadOnlyEvidenceContract(database)
    println("Plan store contract phase: ancestor cancellation")
    planExecutionAncestorCancellationContract(database)
    println("Plan store contract phase: pending optional completion barrier")
    planExecutionOptionalPendingSealContract(database)
    println("Plan store contract phase: shared Unknown barrier")
    planExecutionSharedUnknownStopContract(database)
    println("Plan store contract phase: recoverable error envelopes")
    planExecutionRecoverableEnvelopeContract(database)
    println("Plan store contract phase: trusted read-only review")
    planExecutionReadOnlyReviewContract(database)
    println("Plan store contract phase: sealed initialization scope")
    planInitializationReadScopeContract()
    planUnstartedChildRevocationContract204(database)
    println("Plan store contract phase: certified mutating fallback")
    planExecutionCertifiedMutationFallbackContract(database)
    println("Plan store contract phase: probe certificate rejection boundaries")
    planExecutionProbeCertificateBoundaries(database)
    database.close()
    println("Plan store contract phase: restart and atomic owner completion")
    let reopened = SqliteDatabase(path)
    try {
        let recovered = paidPlanTestStore204(reopened)
        expect(recovered.executionForSession(ownerSession).value().getOrThrow().getOrThrow() == "execution" &&
            recovered.requireComplete(probe.runId).isOk(), "restart reconstructs approved plan completion from canonical facts")
        expect(recovered.admit(retry.runId, retry.operationId, "acquire", "acquire-package", retry.plan).isError(),
            "restart preserves spent budget and fallback decision")
        expect(planTestObserve204(recovered, probe.runId, probe.operationId).decision == "fallback",
            "re-observation returns the decision captured for that receipt, without reinterpreting history")
        expect(recovered.finish(delegation.runId).isError(),
            "complete evidence alone cannot seal before canonical owned-work settlement")
        let attempts = SqliteModelDecisionStore(reopened)
        let unsettled = DurableModelAttempt(ModelAttemptId("plan-seal-open-attempt"),
            SemanticModelRequestId("plan-seal-open-semantic"), delegation.runId, 1,
            ModelAttemptLifecycle.Created, objectValue([]), "completion barrier", 8, 8)
        expect(attempts.createAttempt(unsettled).isOk() && planStoreComplete(reopened, delegation).isError() &&
            !planTestInspectBool204(recovered, delegation.runId, "sealed") &&
            recovered.executionForSession(ownerSession).value().getOrThrow().isSome(),
            "an unsettled original model Attempt refuses canonical completion without prematurely sealing approval")
        expect(attempts.terminalizeAttempt(unsettled.id, ModelAttemptLifecycle.Abandoned, "test_settled", 9).isOk(),
            "the original model-attempt API settles the blocking work before completion")
        expect(planStoreComplete(reopened, delegation).isOk(),
            "canonical owner completion atomically seals verified plan after its original work barrier")
        expect(recovered.finish(child.runId).isError() && recovered.finish(delegation.runId).isOk() &&
            recovered.finish(delegation.runId).isOk(),
            "only the owner can atomically seal a globally verified plan and repeat finish idempotently")
        expect(planTestInspectBool204(recovered, delegation.runId, "sealed") &&
            recovered.activate("execution", ownerSession, contract).isError() &&
            recovered.inherit(delegation.runId, "new-child", delegation.operationId).isError(),
            "sealed execution cannot reactivate or delegate new work through its original binding")
        expect(recovered.executionForSession(ownerSession).value().getOrThrow().isNone() &&
            recovered.executionForSession(child.threadId.value).value().getOrThrow().isNone() &&
            !planTestHasScope204(recovered, ownerSession) &&
            planTestSessionComplete204(recovered, ownerSession),
            "finished plan releases active scope for new tasks while retaining inspectable history")
    } finally { reopened.close() }
    println("Plan store contract passed: migration, shared budgets, failure decisions, scope, restart, and atomic completion")
}

func planStoreAction(id: String, tool: String, delegatedActionIds!: Array<String> = []): PlanAction {
    PlanAction(id, [tool], ["denied"], OperationEffectClass.ReadOnly, objectValue([]), 1,
        exactArguments: !delegatedActionIds.isEmpty(), toolIdentities: objectValue([ValueField(tool, objectValue([
            ValueField("version", textValue("1")), ValueField("fingerprint", textValue("implementation")),
            ValueField("schema_digest", textValue("schema"))]))]), delegatedActionIds: delegatedActionIds)
}
class PlanStoreFixture {
    let runId: RunId
    let operationId: OperationId
    let plan: NormalizedOperationPlan
    let threadId: ThreadId
    let turnId: SemanticTurnId
    let callId: String
    var handedOff: Bool = false
    init(runId: RunId, operationId: OperationId, plan: NormalizedOperationPlan,
        threadId: ThreadId, turnId: SemanticTurnId, callId: String) {
        this.runId = runId
        this.operationId = operationId
        this.plan = plan
        this.threadId = threadId
        this.turnId = turnId
        this.callId = callId
    }
}
func planStoreFixture(database: SqliteDatabase, name: String, tool: String,
    effect!: OperationEffectClass = OperationEffectClass.ReadOnly,
    networkMode!: NetworkPolicyMode = NetworkPolicyMode.Denied,
    retryDisposition!: OperationRetryDisposition = OperationRetryDisposition.Safe): PlanStoreFixture {
    println("Plan store canonical fixture: " + name)
    let threadId = ThreadId("plan-thread-" + name)
    let turnId = SemanticTurnId("plan-turn-" + name)
    let runId = RunId("plan-run-" + name)
    let operationId = OperationId("plan-operation-" + name)
    let sink = paidPlanSink204(database)
    let coordinator = ThreadCoordinator(sink.createThread(threadId, "workspace"), sink)
    let active = coordinator.startTurn(turnId, runId, ItemId("plan-user-" + name),
        ThreadItemContent.UserMessage(textMessageParts("test approved plan")), createdAtMillis: 1).value().getOrThrow()
    let callId = "plan-call-" + name
    let call = commitDurableToolCall(database, coordinator, threadId, turnId, runId,
        active.activeEpoch, 1, ItemId("plan-item-" + name), callId, tool, objectValue([]), 2)
    let capabilities = ArrayList<Capability>()
    if (tool == "task" || tool == "plugin.axyndra:workflow.task") { capabilities.add(Capability(CapabilityKind.Delegate)) }
    capabilities.add(Capability(if (effect == OperationEffectClass.ReadOnly) { CapabilityKind.WorkspaceRead } else { CapabilityKind.WorkspaceWrite }))
    if (networkMode != NetworkPolicyMode.Denied) { capabilities.add(Capability(CapabilityKind.NetworkAccess)) }
    let plan = NormalizedOperationPlan(tool, objectValue([]), capabilities.toArray(),
        effect, retryDisposition, "binding-" + name, networkPolicy: Some(NetworkPolicy(networkMode)),
        resolvedPaths: if (effect == OperationEffectClass.ReadOnly) { [] } else { ["/workspace/source"] },
        cwd: "/workspace", approvedWriteRoots: if (tool == "command_probe" || tool == "bash") { ["/workspace"] } else { [] },
        toolVersion: "1", implementationFingerprint: "implementation", schemaDigest: "schema")
    expect(paidPlanOperationStore204(database).prepare(operationId, runId, call, plan).isOk(),
        "plan fixture uses a committed canonical ToolCall and Operation")
    println("Plan store canonical fixture prepared: " + name)
    PlanStoreFixture(runId, operationId, plan, threadId, turnId, callId)
}
func planStoreSettle(database: SqliteDatabase, fixture: PlanStoreFixture,
    outcome: OperationOutcome, detail: AgentValue): Unit {
    if (!fixture.handedOff) { planStoreHandoff(database, fixture) }
    let receiptId = "plan-receipt-" + fixture.operationId.value
    let result = ThreadItemContent.ToolResult(CanonicalToolCallId(fixture.callId), fixture.operationId,
        receiptId, detail, outcome != OperationOutcome.Completed)
    let thread = database.query("SELECT revision,next_item_ordinal FROM threads WHERE id=" + sqliteText(fixture.threadId.value))[0]
    AgentStore(database).commitOperationResult(OperationSemanticCommit(fixture.operationId.value,
        fixture.runId.value, receiptId, outcome, encodeStoredValue(detail), encodeStoredValue(objectValue([])),
        "plan-result-" + fixture.operationId.value, fixture.threadId.value, fixture.turnId.value,
        Int64.parse(thread.required(1)), encodeStoredThreadContent(result),
        encodeStoredProvenance(ItemProvenance("operation", runId: Some(fixture.runId), operationId: Some(fixture.operationId))),
        5, Int64.parse(thread.required(0)), "running"))
}

func removePlanExecutionSchema(database: SqliteDatabase): Unit {
    database.execute("DROP TABLE plan_step_decisions")
    database.execute("DROP TABLE plan_action_admissions")
    database.execute("DROP TABLE plan_execution_runs")
    database.execute("DROP TABLE plan_execution_sessions")
    database.execute("DROP TABLE plan_execution_members")
    database.execute("DROP TABLE plan_executions")
}

func planExecutionMigrationContract(root: String): Unit {
    let path = root + "/v28-plans.db"
    let seed = SqliteDatabase(path)
    let old = planStoreFixture(seed, "legacy-v28", "command_probe")
    removePlanExecutionSchema(seed)
    seed.execute("PRAGMA user_version=28")
    seed.close()
    let migrated = SqliteDatabase(path)
    try {
        let plans = paidPlanTestStore204(migrated)
        expect(migrated.scalarInt("PRAGMA user_version") == 29 &&
            plans.executionForRun(old.runId).value().getOrThrow().isNone() &&
            paidPlanOperationStore204(migrated).loadPlan(old.operationId, old.runId).isOk(),
            "v28 migration preserves historical Operations without inventing an approved execution")
    } finally { migrated.close() }
}

func planExecutionStopsContract(database: SqliteDatabase): Unit {
    for (name in ["denied", "cancelled", "unknown"]) {
        let fixture = planStoreFixture(database, "stop-" + name, "command_probe")
        let fallback = planStoreFixture(database, "stop-fallback-" + name, "write")
        let delegation = planStoreFixture(database, "stop-delegation-" + name, "task")
        let contract = PlanContract(["/workspace"], [
            PlanExecutionStep(PlanStepId("request"), [], true,
                [planStoreAction("request", "command_probe")], fallbackStepId: Some("fallback")),
            PlanExecutionStep(PlanStepId("fallback"), [], false, [planStoreAction("fallback", "write")]),
            PlanExecutionStep(PlanStepId("delegation"), [], false, [planStoreAction("delegate", "task", delegatedActionIds: ["request", "fallback"])])])
        let plans = paidPlanTestStore204(database)
        expect(plans.bind("stop-execution-" + name, delegation.threadId.value, delegation.runId, contract).isOk() &&
            plans.admit(delegation.runId, delegation.operationId, "delegation", "delegate", delegation.plan).isOk(),
            "stop fixture admits its delegating task")
        planStoreHandoff(database, delegation)
        expect(plans.inherit(delegation.runId, fixture.threadId.value, delegation.operationId).isOk() &&
            plans.inherit(delegation.runId, fallback.threadId.value, delegation.operationId).isOk() &&
            plans.bindRun("stop-execution-" + name, fixture.threadId.value, fixture.runId).isOk() &&
            plans.bindRun("stop-execution-" + name, fallback.threadId.value, fallback.runId).isOk() &&
            plans.admit(fixture.runId, fixture.operationId, "request", "request", fixture.plan).isOk(),
            "stop fixture uses approved canonical admission")
        planStoreSettle(database, delegation, OperationOutcome.Completed, objectValue([]))
        let outcome = if (name == "denied") { OperationOutcome.Rejected }
            else if (name == "cancelled") { OperationOutcome.Cancelled } else { OperationOutcome.Unknown }
        planStoreSettle(database, fixture, outcome, objectValue([
            ValueField("failure_class", textValue(if (name == "denied") { "policy_denied" } else { name })),
            ValueField("fallback_allowed", boolValue(true)), ValueField("retryable", boolValue(true))]))
        expect(planTestObserve204(plans, fixture.runId, fixture.operationId).decision ==
            (if (name == "denied") { "policy_denied" } else if (name == "unknown") { "recovery_required" } else { "cancelled" }) &&
            plans.admit(fallback.runId, fallback.operationId, "fallback", "fallback", fallback.plan).isError() &&
            plans.requireComplete(fixture.runId).isError(),
            "permission, cancellation, and unknown effects cannot be retried or bypassed by fallback")
    }
}

func planExecutionStaleEvidenceContract(database: SqliteDatabase): Unit {
    let delegation = planStoreFixture(database, "stale-delegation", "task")
    let first = planStoreFixture(database, "stale-first", "command_probe")
    let mutation = planStoreFixture(database, "stale-mutation", "write", effect: OperationEffectClass.WorkspaceMutation)
    let second = planStoreFixture(database, "stale-second", "command_probe")
    let testAction = PlanAction("test", ["command_probe"], ["denied"], OperationEffectClass.ReadOnly,
        objectValue([]), 2, evidence: "exit_zero", toolIdentities: planStoreAction("pins", "command_probe").toolIdentities)
    let writeAction = PlanAction("mutate", ["write"], ["denied"], OperationEffectClass.WorkspaceMutation,
        objectValue([]), 1, toolIdentities: planStoreAction("pins", "write").toolIdentities)
    let contract = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("verify"), [], true, [testAction]),
        PlanExecutionStep(PlanStepId("source"), [], false, [writeAction]),
        PlanExecutionStep(PlanStepId("delegation"), [], false, [planStoreAction("delegate", "task", delegatedActionIds: ["test", "mutate"])])])
    let plans = paidPlanTestStore204(database)
    expect(plans.bind("stale-execution", delegation.threadId.value, delegation.runId, contract).isOk() &&
        plans.admit(delegation.runId, delegation.operationId, "delegation", "delegate", delegation.plan).isOk(),
        "stale-evidence fixture admits its parent task")
    planStoreHandoff(database, delegation)
    for (fixture in [first, mutation, second]) {
        expect(plans.inherit(delegation.runId, fixture.threadId.value, delegation.operationId).isOk() &&
            plans.bindRun("stale-execution", fixture.threadId.value, fixture.runId).isOk(), "verification fixtures share immutable task delegation")
    }
    planStoreSettle(database, delegation, OperationOutcome.Completed, objectValue([]))
    expect(plans.admit(first.runId, first.operationId, "verify", "test", first.plan).isOk(), "first verification is admitted")
    let success = objectValue([ValueField("exit_code", integerValue(0)), ValueField("timed_out", boolValue(false))])
    planStoreSettle(database, first, OperationOutcome.Completed, success)
    expect(plans.requireComplete(first.runId).isOk(), "verification initially proves the current source")
    let mutationAdmission = plans.admit(mutation.runId, mutation.operationId, "source", "mutate", mutation.plan)
    match (mutationAdmission) {
        case Result.Err(error) => throw IllegalStateException("approved source admission failed: " + error.describe())
        case Result.Ok(_) => ()
    }
    expect(mutationAdmission.isOk(), "approved subsequent source action executes")
    planStoreSettle(database, mutation, OperationOutcome.Completed, objectValue([]))
    expect(plans.requireComplete(first.runId).isError(), "later source mutation invalidates earlier exit-zero evidence")
    expect(plans.admit(second.runId, second.operationId, "verify", "test", second.plan).isOk(),
        "rerun consumes another approved attempt rather than reviving stale success")
    planStoreSettle(database, second, OperationOutcome.Completed, success)
    expect(plans.requireComplete(first.runId).isOk(), "new canonical verification closes evidence after the mutation")
}

func planStoreHandoff(database: SqliteDatabase, fixture: PlanStoreFixture): Unit {
    let operations = paidPlanOperationStore204(database)
    let execution = operations.markExecuting(fixture.operationId, fixture.runId, fixture.plan, 3, false)
    match (execution) {
        case Result.Err(error) => throw IllegalStateException("fixture execution admission failed: " + error.describe())
        case Result.Ok(_) => ()
    }
    let handoff = operations.markExecutionHandoff(fixture.operationId, fixture.runId, fixture.threadId, 4)
    match (handoff) {
        case Result.Err(error) => throw IllegalStateException("fixture execution handoff failed: " + error.describe())
        case Result.Ok(_) => ()
    }
    fixture.handedOff = true
    expect(execution.isOk() && handoff.isOk(), "fixture reaches the canonical execution handoff")
}

func planExecutionReadOnlyEvidenceContract(database: SqliteDatabase): Unit {
    let task = planStoreFixture(database, "readonly-delegate", "task")
    let first = planStoreFixture(database, "readonly-first", "command_probe")
    let second = planStoreFixture(database, "readonly-second", "command_probe")
    let firstAction = PlanAction("verify-a", ["command_probe"], ["denied"], OperationEffectClass.ReadOnly,
        objectValue([]), 1, evidence: "exit_zero", toolIdentities: planStoreAction("pins", "command_probe").toolIdentities)
    let secondAction = PlanAction("verify-b", ["command_probe"], ["denied"], OperationEffectClass.ReadOnly,
        objectValue([]), 1, evidence: "exit_zero", toolIdentities: firstAction.toolIdentities)
    let contract = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("verify-a"), [], true, [firstAction]),
        PlanExecutionStep(PlanStepId("verify-b"), [], true, [secondAction]),
        PlanExecutionStep(PlanStepId("delegate"), [], false, [planStoreAction("delegate", "task", delegatedActionIds: ["verify-a", "verify-b"])])])
    let plans = paidPlanTestStore204(database)
    expect(plans.bind("readonly-execution", task.threadId.value, task.runId, contract).isOk() &&
        plans.admit(task.runId, task.operationId, "delegate", "delegate", task.plan).isOk(), "readonly-verification parent task admitted")
    planStoreHandoff(database, task)
    for (fixture in [first, second]) {
        expect(plans.inherit(task.runId, fixture.threadId.value, task.operationId).isOk() &&
            plans.bindRun("readonly-execution", fixture.threadId.value, fixture.runId).isOk(), "readonly verifiers inherit the approved task")
    }
    planStoreSettle(database, task, OperationOutcome.Completed, objectValue([]))
    let success = objectValue([ValueField("exit_code", integerValue(0)), ValueField("timed_out", boolValue(false))])
    expect(plans.admit(first.runId, first.operationId, "verify-a", "verify-a", first.plan).isOk(), "first read-only verification admitted")
    planStoreSettle(database, first, OperationOutcome.Completed, success)
    expect(plans.admit(second.runId, second.operationId, "verify-b", "verify-b", second.plan).isOk(), "second read-only verification admitted")
    planStoreSettle(database, second, OperationOutcome.Completed, success)
    expect(plans.requireComplete(task.runId).isOk(), "two read-only required verification receipts coexist without invalidating each other")
}

func planExecutionAncestorCancellationContract(database: SqliteDatabase): Unit {
    let task = planStoreFixture(database, "cancel-ancestor-task", "task")
    let child = planStoreFixture(database, "cancel-ancestor-child", "write")
    let contract = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("child-work"), [], true, [planStoreAction("child-work", "write")]),
        PlanExecutionStep(PlanStepId("delegate"), [], false,
            [planStoreAction("delegate", "task", delegatedActionIds: ["child-work"])])])
    let plans = paidPlanTestStore204(database)
    expect(plans.bind("cancel-ancestor-execution", task.threadId.value, task.runId, contract).isOk() &&
        plans.admit(task.runId, task.operationId, "delegate", "delegate", task.plan).isOk(), "cancellation parent task admitted")
    planStoreHandoff(database, task)
    expect(plans.inherit(task.runId, child.threadId.value, task.operationId).isOk() &&
        plans.bindRun("cancel-ancestor-execution", child.threadId.value, child.runId).isOk(),
        "child binds while its exact ancestor task is live")
    expect(plans.admit(child.runId, child.operationId, "child-work", "child-work", child.plan).isOk(),
        "child reserves an action while ancestor delegation is live")
    planStoreSettle(database, task, OperationOutcome.Cancelled, objectValue([ValueField("failure_class", textValue("cancelled"))]))
    expect(plans.admit(child.runId, child.operationId, "", "", child.plan).isError() &&
        paidPlanOperationStore204(database).markExecuting(child.operationId, child.runId, child.plan, 8, false).isError(),
        "cancelled ancestor prevents reserved child dispatch after token races and restart")
}

func planExecutionOptionalPendingSealContract(database: SqliteDatabase): Unit {
    let task = planStoreFixture(database, "optional-pending-task", "task")
    let required = planStoreFixture(database, "optional-pending-required", "write")
    let optional = planStoreFixture(database, "optional-pending-effect", "write")
    let contract = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("required"), [], true, [planStoreAction("required", "write")]),
        PlanExecutionStep(PlanStepId("optional"), [], false, [planStoreAction("optional", "write")]),
        PlanExecutionStep(PlanStepId("delegate"), [], false,
            [planStoreAction("delegate", "task", delegatedActionIds: ["required", "optional"])])])
    let plans = paidPlanTestStore204(database)
    expect(plans.bind("optional-pending-execution", task.threadId.value, task.runId, contract).isOk() &&
        plans.admit(task.runId, task.operationId, "delegate", "delegate", task.plan).isOk(), "optional-effect parent admitted")
    planStoreHandoff(database, task)
    for (fixture in [required, optional]) {
        expect(plans.inherit(task.runId, fixture.threadId.value, task.operationId).isOk() &&
            plans.bindRun("optional-pending-execution", fixture.threadId.value, fixture.runId).isOk(),
            "optional-effect fixture receives immutable delegated membership")
    }
    planStoreSettle(database, task, OperationOutcome.Completed, objectValue([]))
    expect(plans.admit(required.runId, required.operationId, "required", "required", required.plan).isOk(), "required action admitted")
    planStoreSettle(database, required, OperationOutcome.Completed, objectValue([]))
    expect(plans.requireComplete(task.runId).isOk(), "unstarted optional work does not prevent completion")
    expect(plans.admit(optional.runId, optional.operationId, "optional", "optional", optional.plan).isOk() &&
        plans.finish(task.runId).isError() && planStoreComplete(database, task).isError() &&
        !planTestInspectBool204(plans, task.runId, "sealed"),
        "pending optional admission prevents canonical owner completion and leaves the plan unsealed")
    planStoreSettle(database, optional, OperationOutcome.Unknown, objectValue([]))
    expect(plans.requireComplete(task.runId).isError() && plans.finish(task.runId).isError() &&
        planStoreComplete(database, task).isError() &&
        !planTestInspectBool204(plans, task.runId, "sealed"),
        "unknown optional side effects cannot be hidden by successful required evidence")
}

func planExecutionSharedUnknownStopContract(database: SqliteDatabase): Unit {
    let task = planStoreFixture(database, "shared-unknown-task", "task")
    let failed = planStoreFixture(database, "shared-unknown-failed", "write")
    let reserved = planStoreFixture(database, "shared-unknown-reserved", "write")
    let independent = planStoreFixture(database, "shared-unknown-independent", "write")
    let owner = planStoreSiblingFixture(database, task, "shared-unknown-owner", "write")
    let contract = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("failed"), [], true, [planStoreAction("failed", "write")]),
        PlanExecutionStep(PlanStepId("reserved"), [], true, [planStoreAction("reserved", "write")]),
        PlanExecutionStep(PlanStepId("independent"), [], false, [planStoreAction("independent", "write")]),
        PlanExecutionStep(PlanStepId("owner"), [], false, [planStoreAction("owner", "write")]),
        PlanExecutionStep(PlanStepId("delegate"), [], false, [planStoreAction("delegate", "task",
            delegatedActionIds: ["failed", "reserved", "independent"])])])
    let plans = paidPlanTestStore204(database)
    expect(plans.bind("shared-unknown-execution", task.threadId.value, task.runId, contract).isOk() &&
        plans.admit(task.runId, task.operationId, "delegate", "delegate", task.plan).isOk(), "shared-stop parent admitted")
    planStoreHandoff(database, task)
    for (fixture in [failed, reserved, independent]) {
        expect(plans.inherit(task.runId, fixture.threadId.value, task.operationId).isOk() &&
            plans.bindRun("shared-unknown-execution", fixture.threadId.value, fixture.runId).isOk(), "shared-stop child inherits exact task authority")
    }
    planStoreSettle(database, task, OperationOutcome.Completed, objectValue([]))
    expect(planTestObserve204(plans, task.runId, task.operationId).decision == "verified",
        "a successful parent receipt has a historical verified decision before the shared failure")
    expect(plans.admit(reserved.runId, reserved.operationId, "reserved", "reserved", reserved.plan).isOk() &&
        plans.admit(failed.runId, failed.operationId, "failed", "failed", failed.plan).isOk(), "independent child actions reserve before unknown outcome")
    planStoreSettle(database, failed, OperationOutcome.Unknown, objectValue([]))
    expect(plans.admit(independent.runId, independent.operationId, "independent", "independent", independent.plan).isError() &&
        plans.admit(owner.runId, owner.operationId, "owner", "owner", owner.plan).isError() &&
        plans.admit(reserved.runId, reserved.operationId, "", "", reserved.plan).isError(),
        "an unknown outcome blocks independent child and owner admissions across the shared execution")
    expect(planTestObserve204(plans, task.runId, task.operationId).decision == "recovery_required",
        "shared Unknown overrides an earlier receipt continuation without rewriting its canonical facts")
    expect(paidPlanOperationStore204(database).markExecuting(reserved.operationId, reserved.runId, reserved.plan, 8, false).isError(),
        "a sibling reservation admitted earlier cannot dispatch after a cross-Run unknown effect")
    for (run in [task.runId, independent.runId]) {
        expect(planTestInspectBool204(plans, run, "stopped_tools"),
            "owner and child model views advertise no tool dispatch until canonical reconciliation")
    }
}

func planStoreSiblingFixture(database: SqliteDatabase, sibling: PlanStoreFixture, name: String, tool: String): PlanStoreFixture {
    let sink = paidPlanSink204(database)
    let snapshot = sink.loadThread(sibling.threadId)
    let coordinator = ThreadCoordinator(snapshot, sink)
    let callId = "plan-call-" + name
    let call = commitDurableToolCall(database, coordinator, sibling.threadId, sibling.turnId, sibling.runId,
        snapshot.activeEpoch, snapshot.nextResultSequence, ItemId("plan-item-" + name), callId, tool, objectValue([]), 2)
    let plan = NormalizedOperationPlan(tool, objectValue([]), [Capability(CapabilityKind.WorkspaceRead)],
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, "binding-" + name,
        cwd: "/workspace", approvedWriteRoots: if (tool == "command_probe" || tool == "bash") { ["/workspace"] } else { [] },
        toolVersion: "1", implementationFingerprint: "implementation", schemaDigest: "schema")
    let operationId = OperationId("plan-operation-" + name)
    expect(paidPlanOperationStore204(database).prepare(operationId, sibling.runId, call, plan).isOk(), "owner independent tool call is committed canonically")
    PlanStoreFixture(sibling.runId, operationId, plan, sibling.threadId, sibling.turnId, callId)
}

func planExecutionRecoverableEnvelopeContract(database: SqliteDatabase): Unit {
    let typed = objectValue([ValueField("failure_class", textValue("timeout")),
        ValueField("kind", textValue("timeout")), ValueField("retryable", boolValue(true))])
    let envelopes = [
        objectValue([ValueField("error", textValue("probe timed out")), ValueField("error_kind", textValue("timeout")),
            ValueField("failure_class", textValue("timeout")), ValueField("retryable", boolValue(true))]),
        objectValue([ValueField("error", textValue("probe timed out")), ValueField("error_detail", typed)]),
        objectValue([ValueField("error", typed)]),
        objectValue([ValueField("failure_class", textValue("timeout")), ValueField("exit_code", integerValue(124)),
            ValueField("timed_out", boolValue(true)), ValueField("completed", boolValue(false))])
    ]
    for (index in 0..envelopes.size) {
        let suffix = index.toString()
        let task = planStoreFixture(database, "envelope-task-" + suffix, "task")
        let probe = planStoreFixture(database, "envelope-probe-" + suffix, "command_probe")
        let fallback = planStoreFixture(database, "envelope-fallback-" + suffix, "write")
        let contract = PlanContract(["/workspace"], [
            PlanExecutionStep(PlanStepId("acquire"), [], true,
                [planStoreAction("acquire", "command_probe")], fallbackStepId: Some("fallback")),
            PlanExecutionStep(PlanStepId("fallback"), [], false, [planStoreAction("fallback", "write")]),
            PlanExecutionStep(PlanStepId("delegate"), [], false,
                [planStoreAction("delegate", "task", delegatedActionIds: ["acquire", "fallback"])])])
        let plans = paidPlanTestStore204(database)
        let executionId = "envelope-execution-" + suffix
        expect(plans.bind(executionId, task.threadId.value, task.runId, contract).isOk() &&
            plans.admit(task.runId, task.operationId, "delegate", "delegate", task.plan).isOk(), "envelope task is admitted")
        planStoreHandoff(database, task)
        for (fixture in [probe, fallback]) {
            expect(plans.inherit(task.runId, fixture.threadId.value, task.operationId).isOk() &&
                plans.bindRun(executionId, fixture.threadId.value, fixture.runId).isOk(), "envelope child inherits canonical task")
        }
        planStoreSettle(database, task, OperationOutcome.Completed, objectValue([]))
        expect(plans.admit(probe.runId, probe.operationId, "acquire", "acquire", probe.plan).isOk(), "envelope dependency probe admitted")
        planStoreSettle(database, probe, OperationOutcome.Failed, envelopes[index])
        let decision = planTestObserve204(plans, probe.runId, probe.operationId)
        expect(decision.decision == "fallback" && decision.fallbackStepId.getOrThrow() == "fallback" &&
            plans.admit(fallback.runId, fallback.operationId, "fallback", "fallback", fallback.plan).isOk(),
            "flat recoverable string errors, typed error details, nested errors, and timed-out probes select the approved fallback")
        planStoreSettle(database, fallback, OperationOutcome.Completed, objectValue([]))
        expect(plans.requireComplete(task.runId).isOk(), "canonical fallback evidence completes envelope contract")
    }
}

func planExecutionReadOnlyReviewContract(database: SqliteDatabase): Unit {
    let old = planStoreFixture(database, "review-old", "write")
    let contract = PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("old"), [], true,
        [planStoreAction("old", "write")])])
    let plans = paidPlanTestStore204(database)
    expect(plans.bind("review-old-execution", old.threadId.value, old.runId, contract).isOk() &&
        plans.admit(old.runId, old.operationId, "old", "old", old.plan).isOk(), "old approved action consumes its budget")
    planStoreSettle(database, old, OperationOutcome.Failed, objectValue([
        ValueField("failure_class", textValue("command_failed")), ValueField("exit_code", integerValue(1))]))
    expect(plans.requireComplete(old.runId).isError(), "old failed contract remains incomplete")
    let sink = paidPlanSink204(database)
    let previous = sink.loadThread(old.threadId)
    let coordinator = ThreadCoordinator(previous, sink)
    expect(coordinator.failTurn(old.turnId, old.runId, previous.activeEpoch).isOk(), "failed execution Run closes before explicit user plan review")
    let reviewRun = RunId("review-control-run")
    let reviewTurn = SemanticTurnId("review-control-turn")
    expect(coordinator.startTurn(reviewTurn, reviewRun, ItemId("review-control-user"),
        ThreadItemContent.UserMessage(textMessageParts("/plan")), createdAtMillis: 10,
        runLaneSnapshot: modelLaneSnapshotValue(planReviewFixtureLane())).isOk(), "user explicitly opens another read-only review Run in the same session")
    let read = planStoreControlFixture(database, old.threadId, reviewTurn, reviewRun, "review-read", "read")
    let planWrite = planStoreControlFixture(database, old.threadId, reviewTurn, reviewRun, "review-write-plan", "plan_write")
    let write = planStoreControlFixture(database, old.threadId, reviewTurn, reviewRun, "review-forged-write", "write",
        effect: OperationEffectClass.WorkspaceMutation, capabilities: [Capability(CapabilityKind.WorkspaceWrite)])
    let host = planStoreControlFixture(database, old.threadId, reviewTurn, reviewRun, "review-forged-host", "read",
        networkMode: NetworkPolicyMode.HostNetwork)
    let delegate = planStoreControlFixture(database, old.threadId, reviewTurn, reviewRun, "review-forged-delegate", "read",
        capabilities: [Capability(CapabilityKind.Delegate)])
    let custom = planStoreControlFixture(database, old.threadId, reviewTurn, reviewRun, "review-forged-custom", "custom_read")
    let wrongMarker = planStoreControlFixture(database, old.threadId, reviewTurn, reviewRun, "review-custom-marker", "read",
        policyVersion: "tool-policy-plan-review-v1-custom")
    expect(paidPlanOperationStore204(database).loadPlan(read.operationId, read.runId).value().getOrThrow().policyVersion ==
        "tool-policy-plan-review-v1", "canonical review marker survives Operation serialization")
    planStoreSettle(database, read, OperationOutcome.Completed, objectValue([]))
    planStoreSettle(database, planWrite, OperationOutcome.Completed, objectValue([]))
    for (forged in [write, host, delegate, custom, wrongMarker]) {
        expect(paidPlanOperationStore204(database).markExecuting(forged.operationId, forged.runId, forged.plan, 11, false).isError(),
            "review marker cannot authorize writes, network, delegation, custom tools, or lookalike policies")
    }
    expect(plans.executionForRun(reviewRun).value().getOrThrow().isNone() &&
        plans.executionForSession(old.threadId.value).value().getOrThrow().getOrThrow() == "review-old-execution" &&
        plans.admit(old.runId, old.operationId, "", "", old.plan).isOk(),
        "read-only review never unbinds the old approved contract or replenishes its spent attempt")
    expect(planTestInspectBool204(plans, old.runId, "exhausted"), "review preserves old budget exhaustion")
}

func planStoreControlFixture(database: SqliteDatabase, threadId: ThreadId, turnId: SemanticTurnId,
    runId: RunId, name: String, tool: String,
    effect!: OperationEffectClass = OperationEffectClass.ReadOnly,
    capabilities!: Array<Capability> = [Capability(CapabilityKind.WorkspaceRead)],
    networkMode!: NetworkPolicyMode = NetworkPolicyMode.Denied,
    policyVersion!: String = "tool-policy-plan-review-v1"): PlanStoreFixture {
    let sink = paidPlanSink204(database)
    let snapshot = sink.loadThread(threadId)
    let coordinator = ThreadCoordinator(snapshot, sink)
    let callId = "plan-call-" + name
    let call = commitDurableToolCall(database, coordinator, threadId, turnId, runId,
        snapshot.activeEpoch, snapshot.nextResultSequence, ItemId("plan-item-" + name), callId, tool, objectValue([]), 10)
    let plan = NormalizedOperationPlan(tool, objectValue([]), capabilities, effect, OperationRetryDisposition.Safe,
        "binding-" + name, cwd: "/workspace", networkPolicy: Some(NetworkPolicy(networkMode)), policyVersion: policyVersion,
        toolVersion: "1", implementationFingerprint: "implementation",
        schemaDigest: modelPolicySha256Text(canonicalAgentValue(objectValue([]))))
    let operationId = OperationId("plan-operation-" + name)
    expect(paidPlanOperationStore204(database).prepare(operationId, runId, call, plan).isOk(), "review tool is prepared from a canonical ToolCall")
    PlanStoreFixture(runId, operationId, plan, threadId, turnId, callId)
}

func planExecutionCertifiedMutationFallbackContract(database: SqliteDatabase): Unit {
    let task = planStoreFixture(database, "certified-task", "task")
    let attempt = planStoreFixture(database, "certified-install", "command_probe", effect: OperationEffectClass.ExternalMutation,
        networkMode: NetworkPolicyMode.Mediated, retryDisposition: OperationRetryDisposition.Never)
    let retry = planStoreFixture(database, "certified-retry", "command_probe", effect: OperationEffectClass.ExternalMutation,
        networkMode: NetworkPolicyMode.Mediated, retryDisposition: OperationRetryDisposition.Never)
    let fallback = planStoreFixture(database, "certified-fallback", "write")
    let action = PlanAction("install", ["command_probe"], ["proxy"], OperationEffectClass.ExternalMutation,
        objectValue([]), 2, exactArguments: true, toolIdentities: planStoreAction("pins", "command_probe").toolIdentities)
    let contract = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("install"), [], true, [action], fallbackStepId: Some("fallback")),
        PlanExecutionStep(PlanStepId("fallback"), [], false, [planStoreAction("fallback", "write")]),
        PlanExecutionStep(PlanStepId("delegate"), [], false,
            [planStoreAction("delegate", "task", delegatedActionIds: ["install", "fallback"])])])
    let plans = paidPlanTestStore204(database)
    expect(plans.bind("certified-execution", task.threadId.value, task.runId, contract).isOk() &&
        plans.admit(task.runId, task.operationId, "delegate", "delegate", task.plan).isOk(), "certified attempt parent is admitted")
    planStoreHandoff(database, task)
    for (fixture in [attempt, retry, fallback]) {
        expect(plans.inherit(task.runId, fixture.threadId.value, task.operationId).isOk() &&
            plans.bindRun("certified-execution", fixture.threadId.value, fixture.runId).isOk(), "certified attempt child inherits canonical delegation")
    }
    planStoreSettle(database, task, OperationOutcome.Completed, objectValue([]))
    expect(plans.admit(attempt.runId, attempt.operationId, "install", "install", attempt.plan).isOk(), "mutating dependency attempt is admitted")
    planStoreSettle(database, attempt, OperationOutcome.Failed, objectValue([
        ValueField("failure_class", textValue("command_failed")), ValueField("started", boolValue(true)),
        ValueField("completed", boolValue(true)), ValueField("target_stopped", boolValue(true)),
        ValueField("exit_code", integerValue(1)), ValueField("timed_out", boolValue(false)),
        ValueField("fallback_allowed", boolValue(true)), ValueField("retryable", boolValue(true))]))
    expect(planTestObserve204(plans, attempt.runId, attempt.operationId).decision == "fallback" &&
        plans.admit(retry.runId, retry.operationId, "install", "install", retry.plan).isError(),
        "known stopped controlled install selects only declared fallback; Never does not become retryable despite spare budget")
    expect(plans.admit(fallback.runId, fallback.operationId, "fallback", "fallback", fallback.plan).isOk(), "certified failure enables approved fallback")
    planStoreSettle(database, fallback, OperationOutcome.Completed, objectValue([]))
    expect(plans.requireComplete(task.runId).isOk(), "bounded partial dependency files do not prevent verified approved fallback")
}

func planExecutionProbeCertificateBoundaries(database: SqliteDatabase): Unit {
    for (profile in ["timeout", "opaque", "offline", "not_stopped", "unknown"]) {
        let tool = if (profile == "opaque") { "write" } else { "command_probe" }
        let networked = profile != "opaque" && profile != "offline"
        let mode = if (networked) { NetworkPolicyMode.Mediated } else { NetworkPolicyMode.Denied }
        let effect = if (networked) { OperationEffectClass.ExternalMutation } else { OperationEffectClass.WorkspaceMutation }
        let task = planStoreFixture(database, "certificate-" + profile + "-task", "task")
        let probe = planStoreFixture(database, "certificate-" + profile + "-probe", tool,
            effect: effect, networkMode: mode, retryDisposition: OperationRetryDisposition.Never)
        let fallback = planStoreFixture(database, "certificate-" + profile + "-fallback", "write")
        let action = PlanAction("attempt", [tool], [if (networked) { "proxy" } else { "denied" }], effect,
            objectValue([]), 2, exactArguments: true, toolIdentities: planStoreAction("pins", tool).toolIdentities)
        let contract = PlanContract(["/workspace"], [
            PlanExecutionStep(PlanStepId("attempt"), [], true, [action], fallbackStepId: Some("fallback")),
            PlanExecutionStep(PlanStepId("fallback"), [], false, [planStoreAction("fallback", "write")]),
            PlanExecutionStep(PlanStepId("delegate"), [], false,
                [planStoreAction("delegate", "task", delegatedActionIds: ["attempt", "fallback"])])])
        let plans = paidPlanTestStore204(database)
        let executionId = "certificate-boundary-" + profile
        expect(plans.bind(executionId, task.threadId.value, task.runId, contract).isOk() &&
            plans.admit(task.runId, task.operationId, "delegate", "delegate", task.plan).isOk(), "certificate boundary task admitted")
        planStoreHandoff(database, task)
        for (fixture in [probe, fallback]) {
            expect(plans.inherit(task.runId, fixture.threadId.value, task.operationId).isOk() &&
                plans.bindRun(executionId, fixture.threadId.value, fixture.runId).isOk(), "certificate boundary child receives exact delegation")
        }
        planStoreSettle(database, task, OperationOutcome.Completed, objectValue([]))
        expect(plans.admit(probe.runId, probe.operationId, "attempt", "attempt", probe.plan).isOk(), "certificate boundary attempt admitted")
        planStoreSettle(database, probe, if (profile == "unknown") { OperationOutcome.Unknown } else { OperationOutcome.Failed },
            objectValue([ValueField("failure_class", textValue(if (profile == "timeout") { "timeout" } else { "command_failed" })),
                ValueField("started", boolValue(true)), ValueField("completed", boolValue(profile != "timeout")),
                ValueField("target_stopped", boolValue(profile != "not_stopped")), ValueField("exit_code", integerValue(1)),
                ValueField("timed_out", boolValue(profile == "timeout")), ValueField("fallback_allowed", boolValue(true))]))
        let decision = planTestObserve204(plans, probe.runId, probe.operationId)
        if (profile == "timeout") {
            expect(decision.decision == "fallback" && plans.admit(fallback.runId, fallback.operationId, "fallback", "fallback", fallback.plan).isOk(),
                "trusted stopped timeout may fallback while completed remains false")
        } else {
            expect(decision.decision != "fallback" && plans.admit(fallback.runId, fallback.operationId, "fallback", "fallback", fallback.plan).isError(),
                "opaque/offline/unstopped/unknown receipts cannot turn a flag into a task fallback certificate")
        }
    }
}

func planStoreComplete(database: SqliteDatabase, fixture: PlanStoreFixture): Result<AgentThreadSnapshot> {
    let sink = paidPlanSink204(database)
    let snapshot = sink.loadThread(fixture.threadId)
    ThreadCoordinator(snapshot, sink).completeTurn(fixture.turnId, fixture.runId, snapshot.activeEpoch,
        finishedAtMillis: Some(10))
}

func planReviewFixtureLane(): ModelLane {
    let tools = ToolSetSnapshot("plan-review-fixture", [
        ToolSnapshotEntry("read", "read sources", objectValue([]), "1", [Capability(CapabilityKind.WorkspaceRead)],
            implementationFingerprint: "implementation", schemaDigest: modelPolicySha256Text(canonicalAgentValue(objectValue([]))),
            planReviewSafe: true),
        ToolSnapshotEntry("plan_write", "write review data", objectValue([]), "1", [Capability(CapabilityKind.WorkspaceRead)],
            implementationFingerprint: "implementation", schemaDigest: modelPolicySha256Text(canonicalAgentValue(objectValue([]))),
            planReviewSafe: true),
        ToolSnapshotEntry("custom_read", "ordinary read", objectValue([]), "1", [Capability(CapabilityKind.WorkspaceRead)],
            implementationFingerprint: "implementation", schemaDigest: modelPolicySha256Text(canonicalAgentValue(objectValue([]))))
    ])
    ModelLane(ModelLaneRole.Main, "fixture", "fixture", "fixture", ModelLaneCapabilitiesSnapshot(),
        8192, 1024, 256, "fixture", "fixture", "fixture", tools, "fixture")
}

func planInitializationReadScopeContract(): Unit {
    for (scenario in ["initial", "committed", "direct-parent", "outside", "review-initial", "review-parent"]) {
        let fixture = ContextReadStoreFixture(mode: if (scenario == "review-parent") { "committed" } else if (scenario == "committed" || scenario == "direct-parent") { scenario } else { "" },
            paths: if (scenario == "outside" || scenario == "review-initial") { ["/outside/source"] } else { ["/workspace/source"] },
            policyVersion: if (scenario == "review-initial" || scenario == "review-parent") { "tool-policy-plan-review-v1" } else { "tool-policy-v1" },
            allocation: Some({ bytes => planTestAllocate204(bytes) }))
        try {
            let plans = paidPlanTestStore204(fixture.database)
            let contract = PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("source"), [], true,
                [planStoreAction("source", "read")])])
            expect(plans.bind("initial-read-plan", fixture.thread.value, fixture.run, contract).isOk(),
                "initialization fixture binds its real owned Run to an approved scope")
            let source = fixture.commit()
            expect(fixture.store.prepareDirectOperation(source, fixture.plan).isOk(),
                "metadata read has its real sealed canonical source and immutable read-plan digest")
            let executing = fixture.store.markExecutingWithSource(Some(OperationRootSource.Direct(source)),
                fixture.operation, fixture.run, fixture.plan, 11, false)
            if (scenario == "initial" || scenario == "review-initial") {
                expect(executing.isOk() && fixture.store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(source)),
                    fixture.operation, fixture.run, fixture.thread, 12).isOk(),
                    "only scoped parentless sealed Host initialization can execute without a model action binding")
            } else {
                expect(executing.isError() && fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE " +
                    "operation_id='context-read-operation' AND kind='operation_execution_handoff'") == 0,
                    "model-parent, direct-parent, and outside-scope ContextReads cannot borrow the initialization exception")
            }
            expect(fixture.database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions") == 0 &&
                plans.requireComplete(fixture.run).isError(),
                "infrastructure reads neither consume an action budget nor satisfy mandatory task evidence")
        } finally { fixture.close() }
    }
    let fixture = ContextReadStoreFixture(allocation: Some({ bytes => planTestAllocate204(bytes) }))
    try {
        let target = fixture.root + "/target"
        let repository = fixture.root + "/participating"
        Directory.create(target); Directory.create(repository)
        let plans = paidPlanTestStore204(fixture.database)
        let contract = PlanContract([canonicalize(Path(target)).toString()], [
            PlanExecutionStep(PlanStepId("source"), [], true, [planStoreAction("source", "read")])],
            participatingRepositories: [canonicalize(Path(repository)).toString()])
        expect(plans.bind("resource-scope-plan", fixture.thread.value, fixture.run, contract).isOk(),
            "actual context resources are checked against immutable approved roots")
        expect(plans.validateContextResource(fixture.run, target).isOk() &&
            plans.validateContextResource(fixture.run, repository).isOk() &&
            plans.validateContextResource(fixture.run, target + "/optional/not-present").isOk(),
            "target, participating repository, and scoped optional absence metadata are readable")
        expect(plans.validateContextResource(fixture.run, fixture.root).isError() &&
            plans.validateContextResource(fixture.run, fixture.root + "/unapproved/not-present").isError(),
            "unrelated existing or absent repository context is rejected before collection")
        expect(fixture.database.readTransaction { tx => planTestSnapshotPresent204(plans, tx, fixture.run) } &&
            !fixture.database.readTransaction { tx => planTestSnapshotPresent204(plans, tx, RunId("missing-snapshot-run")) },
            "inspection uses the caller's exact snapshot and distinguishes absent plan bindings")
    } finally { fixture.close() }
}

// This store fixture has no worker producer at all. Real Product cleanup must
// additionally establish its pre-registration fence before calling this API.
func planUnstartedChildRevocationContract204(database: SqliteDatabase): Unit {
    let parent = planStoreFixture(database, "cleanup-owner", "task")
    let started = planStoreFixture(database, "cleanup-started-child", "read")
    let plans = paidPlanTestStore204(database)
    let contract = PlanContract(["/workspace"], [
        PlanExecutionStep(PlanStepId("delegate"), [], true,
            [planStoreAction("cleanup-delegate", "task", delegatedActionIds: ["cleanup-leaf"])]),
        PlanExecutionStep(PlanStepId("leaf"), [], true, [planStoreAction("cleanup-leaf", "read")])])
    expect(plans.bind("cleanup-execution", parent.threadId.value, parent.runId, contract).isOk() &&
        plans.admit(parent.runId, parent.operationId, "delegate", "cleanup-delegate", parent.plan).isOk(),
        "fresh-child cleanup begins with its genuine canonical admitted parent")
    planStoreHandoff(database, parent)
    let fresh = "cleanup-unstarted-session"
    let sink = paidPlanSink204(database)
    let _ = sink.createThread(ThreadId(fresh), "workspace")
    expect(plans.inherit(parent.runId, fresh, parent.operationId).isOk(), "unstarted child receives immutable delegated membership")
    let before = database.query("SELECT execution_id,parent_run_id,parent_operation_id,allowed_actions FROM plan_execution_members WHERE session_id=" + sqliteText(fresh))[0]
    expect(plans.abandonUnstartedChild204(parent.runId, fresh, started.operationId).isError() &&
        plans.executionForSession(fresh).value().getOrThrow().isSome(),
        "another canonical Operation cannot revoke this child's exact grant")
    expect(plans.abandonUnstartedChild204(parent.runId, fresh, parent.operationId).isOk() &&
        plans.abandonUnstartedChild204(parent.runId, fresh, parent.operationId).isOk() &&
        plans.executionForSession(fresh).value().getOrThrow().isNone(),
        "a genuinely unstarted child loses only its active execution mapping idempotently")
    let after = database.query("SELECT execution_id,parent_run_id,parent_operation_id,allowed_actions FROM plan_execution_members WHERE session_id=" + sqliteText(fresh))[0]
    expect(before.required(0) == after.required(0) && before.required(1) == after.required(1) &&
        before.required(2) == after.required(2) && before.required(3) == after.required(3) &&
        database.scalarInt("SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(fresh)) == 1 &&
        database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions WHERE operation_id=" + sqliteText(parent.operationId.value)) == 1,
        "revocation preserves immutable lineage, Thread data and the parent's spent action budget")
    expect(plans.inherit(parent.runId, started.threadId.value, parent.operationId).isOk() &&
        plans.bindRun("cleanup-execution", started.threadId.value, started.runId).isOk() &&
        plans.abandonUnstartedChild204(parent.runId, started.threadId.value, parent.operationId).isError() &&
        plans.executionForSession(started.threadId.value).value().getOrThrow().isSome(),
        "accepted canonical child Runs retain their actual authorization and recovery history")
}
