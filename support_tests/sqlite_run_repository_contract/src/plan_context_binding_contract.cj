package sqlite_run_repository_contract

import yjson.*
import yjson_support.*
import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_store.*
import persistence_runtime.*

// A decision receipt authorizes advancing the pending approval, but must not
// authorize replacing its trusted review mode or immutable approval scope.
func planContextBindingContract(database: SqliteDatabase): Unit {
    let bank = LogicalJsonOwnerBudget()
    let original = bank.acquire(131072)
    try { planContextBindingFrame204(database, original) } finally { original.close() }
    expect(bank.usage()[0] == 0 && bank.usage()[1] == 0, "whole canonical binding fixture returns its original paid bank")
}
func planContextBindingFrame204(database: SqliteDatabase, original: LogicalJsonOwnerReservation): Unit {
    let allocate = { bytes: Int64 =>
        let child = original.deriveRetainedLease()
        try { child.ensureRetainedPeak(bytes); child }
        catch (error: Exception) { child.close(); throw error }
    }
    let threadId = ThreadId("plan-binding-thread")
    let turnId = SemanticTurnId("plan-binding-turn")
    let runId = RunId("plan-binding-run")
    let sessionId = SessionId(threadId.value)
    let operationId = OperationId("plan-binding-operation")
    let sink = SqliteThreadCommitSink(database, knownParentAllocation: Some(allocate))
    let coordinator = ThreadCoordinator(sink.createThread(threadId, "workspace"), sink)
    let runtime = AgentThreadRuntime(coordinator,
        ContextProjector("plan-binding-fixture", RepositoryApprovalEstimator()), { => 30 })
    let lane = ModelLane(ModelLaneRole.Main, "provider", "fixture", "responses", ModelLaneCapabilitiesSnapshot(),
        100, 10, 5, "estimator", "retry", "cache", ToolSetSnapshot("tools", []), "system-v1")
    runtime.startTurn(turnId, runId, ItemId("plan-binding-user"),
        ThreadItemContent.UserMessage(textMessageParts("verify pending plan binding")), lane,
        InvocationContextProjection(), createdAtMillis: 1).value().getOrThrow()
    let arguments = objectValue([ValueField("path", textValue("/workspace/source"))])
    let nextArguments = objectValue([ValueField("path", textValue("/workspace/next-source"))])
    let plan = planBindingOperationPlan(arguments, "/workspace/source", "plan-binding-digest")
    let nextPlan = planBindingOperationPlan(nextArguments, "/workspace/next-source", "next-arguments")
    let operations = DurableOperationStore(database, documentPayloadAllocation: Some(allocate))
    let supervisor = DurablePlanExecutionStore(database, knownParentAllocation: Some(allocate))
    expect(supervisor.bind("plan-binding-execution", sessionId.value, runId,
        PlanContract(["/workspace"], [PlanExecutionStep(PlanStepId("inspect"), [], true,
            [planBindingAction("inspect-source", arguments), planBindingAction("inspect-next-source", nextArguments)])])).isOk(),
        "pending binding fixture binds the immutable two-action contract")
    planBindingPrepare(runtime, operations, supervisor, operationId, "plan-binding-call", "inspect-source", plan)
    let repository = SqliteRunRepository(database)
    expect(repository.save(RunSnapshot(runId, sessionId, RunState.WaitingApproval,
        summary: "pending approved plan action")).isOk(), "pending binding fixture stores its Run")
    let initialApproval = ApprovalRequest(operationId, "plan-binding-call", "read",
        Capability(CapabilityKind.WorkspaceRead), preview: arguments, sessionId: sessionId.value,
        argumentHash: plan.bindingDigest)
    let originalContext = planBindingContext(false, "approved-hash", "/workspace")
    let initial = planBindingWaiting(runId, sessionId, initialApproval, originalContext)
    expect(repository.saveContinuation(initial).isOk() && repository.recordDecision(ApprovalDecisionReceipt(
        operationId, runId, sessionId, initialApproval.callId, plan.bindingDigest, ApprovalDecision.Approve)).isOk(),
        "real pending continuation and matching canonical approval decision exist before transition tests")
    // A decision alone cannot replace foreground ownership. Commit its real
    // ToolResult and Receipt before isolating the request-binding transition.
    planBindingSettle(runtime, operations, operationId, "plan-binding-call", plan)
    let nextOperationId = OperationId("plan-binding-next-operation")
    planBindingPrepare(runtime, operations, supervisor, nextOperationId,
        "plan-binding-next-call", "inspect-next-source", nextPlan)
    let baseline = planBindingStorage(database, runId, operationId)
    let nextApproval = ApprovalRequest(nextOperationId, "plan-binding-next-call", "read",
        Capability(CapabilityKind.WorkspaceRead), preview: nextArguments, sessionId: sessionId.value, argumentHash: nextPlan.bindingDigest)
    let changedContexts = [
        planBindingContext(true, "approved-hash", "/workspace"),
        planBindingContext(false, "different-approved-hash", "/workspace"),
        planBindingContext(false, "approved-hash", "/")
    ]
    for (context in changedContexts) {
        expect(repository.saveContinuation(planBindingWaiting(runId, sessionId, nextApproval, context)).isError(),
            "a durable approval receipt cannot authorize review-mode, approval-hash, or root drift in the next pending approval")
        expect(planBindingStorage(database, runId, operationId) == baseline,
            "rejected approved pending transition preserves canonical pending facts, spent budget, Operation, and receipt")
    }
    // Different approval identities prevent this from succeeding via the
    // same-approval or byte-equivalent continuation idempotency branches.
    let next = planBindingWaiting(runId, sessionId, nextApproval, originalContext)
    match (repository.saveContinuation(next)) {
        case Result.Err(error) => throw IllegalStateException("same-context pending transition: " + error.describe())
        case Result.Ok(_) => ()
    }
    expect(repository.continuation(runId).value().getOrThrow().approval.operationId.value == nextApproval.operationId.value,
        "the existing decision receipt authorizes a same-context next approval transition")
    expect(repository.recordDecision(ApprovalDecisionReceipt(nextApproval.operationId, runId, sessionId,
        nextApproval.callId, nextApproval.argumentHash, ApprovalDecision.Approve)).isOk(),
        "the next pending approval also has its exact durable decision receipt")
    planBindingSettle(runtime, operations, nextOperationId, "plan-binding-next-call", nextPlan)
    let runningBaseline = planBindingStorage(database, runId, operationId)
    let semanticId = SemanticModelRequestId("plan-binding-semantic")
    let attemptId = ModelAttemptId("plan-binding-attempt")
    let checkpoint = RunningModelCheckpoint(semanticId,
        objectValue([ValueField("model", textValue("fixture"))]), "plan-binding-semantic-digest",
        "plan-binding-wire-digest", attemptId, attemptId, turnId.value, "plan-binding-request", 0)
    let attempt = DurableModelAttempt(attemptId, semanticId, runId, 1, ModelAttemptLifecycle.Created,
        objectValue([]), "initial", 0, 0, providerRequestId: "plan-binding-request",
        semanticRequestDigest: "plan-binding-semantic-digest", wirePolicyDigest: "plan-binding-wire-digest")
    let event = scopedEvent(1, runId, semanticId, attemptId,
        AgentEventPayload.Extension(AgentEventKind.Audit, objectValue([])))
    for (context in changedContexts) {
        expect(repository.prepareModelAttempt(attempt, event,
            planBindingRunning(runId, sessionId, checkpoint, context)).isError(),
            "the approved model-dispatch transition rejects trusted plan context drift")
        expect(planBindingStorage(database, runId, operationId) == runningBaseline &&
            repository.modelAttempt(attemptId).isError(),
            "rejected approved dispatch inserts no Attempt or event and preserves all pending execution facts")
    }
    match (repository.prepareModelAttempt(attempt, event,
        planBindingRunning(runId, sessionId, checkpoint, originalContext))) {
        case Result.Err(error) => throw IllegalStateException("same-context model transition: " + error.describe())
        case Result.Ok(_) => ()
    }
    expect(repository.continuation(runId).value().getOrThrow().kind == RunContinuationKind.RunningModel &&
        repository.modelAttempt(attemptId).isOk(),
        "a matching decision authorizes actual model Attempt preparation with the original trusted plan context")
    expect(database.query("SELECT state FROM operations WHERE id=" + sqliteText(operationId.value))[0].required(0) ==
        "committed" && database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions WHERE operation_id=" +
            sqliteText(operationId.value)) == 1 && database.query(
                "SELECT attempt_no FROM plan_action_admissions WHERE operation_id=" + sqliteText(operationId.value)
            )[0].required(0) == "1",
        "legal continuation advancement does not replay the Operation or replenish the admitted action budget")
}

func planBindingContext(review: Bool, approvalHash: String, root: String): AgentValue {
    objectValue([
        ValueField("workspace_root", textValue("/workspace")), ValueField("cwd", textValue("/workspace")),
        ValueField("environment", listValue([])), ValueField("services", listValue([])),
        ValueField("plan_review_control", boolValue(review)),
        ValueField("plan_context_facts", objectValue([
            ValueField("approval_hash", textValue(approvalHash)),
            ValueField("target_roots", listValue([textValue(root)]))
        ]))
    ])
}

func planBindingPolicy(): RequestedModelPolicy {
    RequestedModelPolicy(ThinkingLevel.High, RequestOutputBudget(8192, minVisibleResponseTokens: 1024))
}

func planBindingCapabilities(): ModelExecutionCapabilitiesSnapshot {
    ModelExecutionCapabilitiesSnapshot("fixture", ThinkingCapabilities(ThinkingControlMode.Effort,
        supportedLevels: canonicalNonOffThinkingLevels()), 8192)
}

func planBindingWaiting(runId: RunId, sessionId: SessionId, approval: ApprovalRequest,
    context: AgentValue): RunContinuation {
    RunContinuation(runId, sessionId, "fixture", "continue approved plan", approval,
        thinking: ThinkingLevel.High, budget: ResourceBudget(maxOutputTokens: 8192, maxToolCalls: 3),
        requestedPolicy: planBindingPolicy(), modelCapabilitiesSnapshot: planBindingCapabilities(),
        contextSnapshotPayload: contextSnapshotValue(InvocationContextProjection()), toolContextPayload: context)
}

func planBindingRunning(runId: RunId, sessionId: SessionId, checkpoint: RunningModelCheckpoint,
    context: AgentValue): RunContinuation {
    RunContinuation(RunContinuationKind.RunningModel, runId, sessionId, "fixture", "continue approved plan",
        checkpoint, planBindingPolicy(), planBindingCapabilities(), thinking: ThinkingLevel.High,
        budget: ResourceBudget(maxOutputTokens: 8192, maxToolCalls: 3),
        contextSnapshotPayload: contextSnapshotValue(InvocationContextProjection()), toolContextPayload: context)
}

func planBindingStorage(database: SqliteDatabase, runId: RunId, operationId: OperationId): String {
    let run = database.query("SELECT state,budget,usage,app_snapshot FROM runs WHERE id=" + sqliteText(runId.value))[0]
    let pending = database.query("SELECT payload FROM run_continuations WHERE run_id=" + sqliteText(runId.value))[0]
    let operation = database.query("SELECT state,revision,normalized_plan FROM operations WHERE id=" + sqliteText(operationId.value))[0]
    let admission = database.query("SELECT attempt_no,binding_digest FROM plan_action_admissions WHERE operation_id=" +
        sqliteText(operationId.value))[0]
    let decisions = database.query("SELECT COALESCE(group_concat(payload,'|'),'') FROM " +
        "(SELECT payload FROM approval_decisions WHERE run_id=" + sqliteText(runId.value) + " ORDER BY operation_id)")[0]
    let facts = database.query("SELECT COALESCE(group_concat(payload||digest||revision,'|'),'') FROM " +
        "(SELECT payload,digest,revision FROM run_continuation_facts WHERE run_id=" + sqliteText(runId.value) +
        " ORDER BY revision)")[0]
    stringifyUnifiedJson(listValue([
        textValue(run.required(0)), textValue(run.required(1)), textValue(run.required(2)), textValue(run.required(3)),
        textValue(pending.required(0)), textValue(operation.required(0)), textValue(operation.required(1)),
        textValue(operation.required(2)), textValue(admission.required(0)), textValue(admission.required(1)),
        textValue(decisions.required(0)), textValue(facts.required(0)),
        integerValue(database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE run_id=" + sqliteText(runId.value))),
        integerValue(database.scalarInt("SELECT COUNT(*) FROM app_run_events WHERE run_id=" + sqliteText(runId.value))),
        integerValue(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE operation_id=" + sqliteText(operationId.value))),
        integerValue(database.scalarInt("SELECT COUNT(*) FROM run_continuation_facts WHERE run_id=" + sqliteText(runId.value)))
    ]))
}

func planBindingOperationPlan(arguments: AgentValue, path: String, digest: String): NormalizedOperationPlan {
    NormalizedOperationPlan("read", arguments, [Capability(CapabilityKind.WorkspaceRead)],
        OperationEffectClass.ReadOnly, OperationRetryDisposition.Safe, digest, cwd: "/workspace",
        resolvedPaths: [path], toolVersion: "1", implementationFingerprint: "implementation", schemaDigest: "schema")
}

func planBindingAction(id: String, arguments: AgentValue): PlanAction {
    PlanAction(id, ["read"], ["denied"], OperationEffectClass.ReadOnly, arguments, 1, exactArguments: true,
        toolIdentities: objectValue([ValueField("read", objectValue([
            ValueField("version", textValue("1")), ValueField("fingerprint", textValue("implementation")),
            ValueField("schema_digest", textValue("schema"))]))]))
}

func planBindingPrepare(runtime: AgentThreadRuntime, operations: DurableOperationStore,
    supervisor: DurablePlanExecutionStore, operation: OperationId, call: String, action: String,
    plan: NormalizedOperationPlan): Unit {
    let active = runtime.activeRun().getOrThrow()
    let item = ItemId(call + "-item")
    expect(repositoryFixtureCommitted(runtime.commitResult(ResultEnvelope(active.threadId, active.turnId,
        active.runId, active.epoch, runtime.threadSnapshot().nextResultSequence,
        ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call), plan.toolName, plan.canonicalArguments),
            ItemProvenance("direct_tool", runId: Some(active.runId), operationId: Some(operation)))))),
        "pending binding fixture commits its genuine owned Direct ToolCall")
    let source = runtime.attestDirectToolCall(item, operation, active.runId, active.epoch).value().getOrThrow()
    operations.prepareDirectOperation(source, plan).value().getOrThrow()
    supervisor.admit(active.runId, operation, "inspect", action, plan).value().getOrThrow()
    operations.waitForApproval(operation, active.runId).value().getOrThrow()
    runtime.pauseForApproval().value().getOrThrow()
}

func planBindingSettle(runtime: AgentThreadRuntime, operations: DurableOperationStore,
    operation: OperationId, call: String, plan: NormalizedOperationPlan): Unit {
    let active = runtime.activeRun().getOrThrow()
    operations.recordApproval("approval-" + operation.value, operation, active.runId, plan,
        CapabilitySet(values: plan.requiredCapabilities), true, "user").value().getOrThrow()
    runtime.resumeAfterApproval().value().getOrThrow()
    operations.markExecuting(operation, active.runId, plan, 23, true).value().getOrThrow()
    operations.markExecutionHandoff(operation, active.runId, active.threadId, 24).value().getOrThrow()
    let result = runtime.resolveOperation(ItemId(call + "-result"), operation, CanonicalToolCallId(call), plan,
        OperationAttemptStage.Executing,
        Result<ToolInvocationResult>.Ok(ToolInvocationResult.Completed(ToolResult(call, objectValue([])))),
        call + "-receipt", 25).value().getOrThrow()
    expect(result.semanticCommit.isSome() && repositoryFixtureCommitted(result.semanticCommit.getOrThrow()),
        "a genuine canonical ToolResult and Receipt discharge foreground approval debt")
}
