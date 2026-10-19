package tool_runtime_contract

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func runPreparedSourceContract(): Unit {
    runDirectSourceAndHostServiceContract("host.process.readonly")
    runDirectSourceAndHostServiceContract("host.file.plan.propose")
    let catalog = ToolCatalog()
    register(catalog, "run_program", CapabilityKind.WorkspaceRead, false)
    let observations = SourceObservingExecutor()
    expect(catalog.register(ToolDescriptor(
        ModelToolDefinition("source_read", "read fixture", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead)
    ), observations).isOk(), "register source-observing executor")
    for (name in ["host.process.readonly", "host.file.plan.propose"]) {
        expect(catalog.register(ToolDescriptor(
            ModelToolDefinition(name, "internal fixture", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true
        ), observations).isOk(), "register hidden plugin service fixture")
    }
    let operations = MemoryOperations()
    let ids = FixedIds()
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), ids)
    let confirmPipeline = ToolPipeline(catalog, operations, MemoryAudit(), ids,
        policy: ConfirmSourcePolicy())
    let context = ToolInvocationContext(
        RunId("source-run"), SessionId("source-session"),
        CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]), epoch: 1
    )
    let childCall = ToolCall("source-child", "source_read", objectValue([]))
    let direct = sourceReady(pipeline.prepare(context, childCall))
    expect(direct.source.kind == PreparedInvocationSourceKind.Direct &&
        direct.committedToolCall.isNone() && !context.trustedControl,
        "direct preparation labels host origin without a model or control grant")
    expect(sourceError(pipeline.prepareDerived(context, childCall, direct, "child")) ==
        "tool.derived_source_invalid", "direct plans cannot impersonate committed parents")
    expect(match (pipeline.admitDerived(context, direct)) {
        case Result.Err(error) => error.code == "tool.derived_source_invalid"
        case _ => false
    }, "admission consumes the sealed derived source")

    // Canonical Thread attestation is required even in this in-memory fixture.
    // The Product broker contract additionally traverses the durable Decision store.
    let threadId = ThreadId(context.sessionId.value)
    let turnId = SemanticTurnId("source-turn")
    let coordinator = ThreadCoordinator(threadId, "/workspace", InMemoryThreadCommitSink())
    coordinator.startTurn(turnId, context.runId, ItemId("source-user"),
        ThreadItemContent.UserMessage(textMessageParts("read"))).value().getOrThrow()
    let itemId = ItemId("source-root-item")
    let block = ModelBlock(ModelBlockKind.ToolCall, callId: "source-root-call",
        name: "run_program", arguments: objectValue([]))
    expect(match (coordinator.commit(ResultEnvelope(
        threadId, turnId, context.runId, 1, 1,
        ThreadItemDraft(itemId,
            ThreadItemContent.ToolCall(CanonicalToolCallId(block.callId), block.name, block.arguments),
            ItemProvenance("model", runId: Some(context.runId)))
    ))) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }, "source fixture commits the root ToolCall before attesting it")
    let committed = coordinator.attestCommittedToolCalls([CommittedToolCallSource(
        ModelDecisionId("source-decision"), ScopedToolCallId("source-scoped-call"), itemId, block
    )]).value().getOrThrow()[0]
    let parent = sourceReady(pipeline.prepareCommitted(context, committed))
    expect(parent.source.kind == PreparedInvocationSourceKind.Committed &&
        parent.committedToolCall.getOrThrow().canonicalItemId.value == itemId.value,
        "committed preparation retains the canonical source attestation")
    operations.prepare(parent.operationId, context.runId, committed, parent.operationPlan)
        .value().getOrThrow()
    expect(operations.operationRunId(parent.operationId).value().getOrThrow().value == context.runId.value &&
        operations.prepare(parent.operationId, RunId("another-owner"), committed, parent.operationPlan).isError() &&
        operations.operationRunId(parent.operationId).value().getOrThrow().value == context.runId.value,
        "read-only owner lookup reports the stored Run and conflicting preparation cannot retarget it")
    expect(match (operations.operationRunId(OperationId("missing-owner"))) {
        case Result.Err(error) => error.kind == AgentErrorKind.InvalidInput && error.code == "operation.not_found"
        case _ => false
    }, "unknown Operation owner lookup returns a typed absence without creating an Operation")
    let pendingParent = sourcePending(confirmPipeline.prepareCommitted(context, committed))
    let approvedParent = match (confirmPipeline.authorize(context, pendingParent, ApprovalDecision.Approve)) {
        case Result.Ok(ToolAuthorization.Ready(value)) => value
        case _ => throw IllegalStateException("source fixture root approval failed")
    }
    expect(approvedParent.source.kind == PreparedInvocationSourceKind.Committed &&
        approvedParent.committedToolCall.getOrThrow().canonicalItemId.value == itemId.value,
        "approval preserves the committed root attestation")
    for (name in ["host.process.readonly", "host.file.plan.propose"]) {
        expect(sourceNotFound(pipeline.prepareDerived(context,
            ToolCall("program-guess", name, objectValue([])), parent,
            "javascript-service:" + block.callId + ":program-guess")),
            "a committed Program cannot acquire a plugin-only host service by guessing its request key")
    }
    let child = sourceReady(pipeline.prepareDerived(context, childCall, parent, "child-key"))
    expect(child.source.kind == PreparedInvocationSourceKind.Derived &&
        child.source.parentOperationId.getOrThrow().value == parent.operationId.value &&
        child.source.rootToolCall.getOrThrow().canonicalItemId.value == itemId.value &&
        child.source.requestKey == "child-key" && child.committedToolCall.isNone(),
        "derived source freezes the parent and request key without becoming a committed root")
    expect(!operations.loadPlan(child.operationId, context.runId).isOk(),
        "derived preparation remains plan-only")
    expect(!pipeline.executePrepared(context, child).isOk() && observations.calls == 0,
        "execution cannot create a missing derived admission")
    expect(match (pipeline.admitDerived(context, child)) {
        case Result.Err(error) => error.code == "operation.derived_parent_invalid"
        case _ => false
    }, "durable admission still rejects a parent without execution handoff")
    operations.markExecuting(parent.operationId, context.runId, parent.operationPlan, 0, false)
        .value().getOrThrow()
    operations.markExecutionHandoff(parent.operationId, context.runId, threadId, 0)
        .value().getOrThrow()
    expect(pipeline.admitDerived(context, child).value().getOrThrow().value == child.operationId.value,
        "active root admits the source-bound child through the existing authority")
    expect(operations.operationRunId(child.operationId).value().getOrThrow().value == context.runId.value,
        "derived Operation owner lookup retains the actual shared Run")
    let pendingChild = sourcePending(confirmPipeline.prepareDerived(context,
        ToolCall("source-approved-child", "source_read", objectValue([])), parent, "approved-child-key"))
    confirmPipeline.admitDerived(context, pendingChild).value().getOrThrow()
    let approvedChild = match (confirmPipeline.authorize(context, pendingChild, ApprovalDecision.Approve)) {
        case Result.Ok(ToolAuthorization.Ready(value)) => value
        case _ => throw IllegalStateException("source fixture child approval failed")
    }
    expect(approvedChild.source.kind == PreparedInvocationSourceKind.Derived &&
        approvedChild.source.parentOperationId.getOrThrow().value == parent.operationId.value &&
        approvedChild.source.requestKey == "approved-child-key" &&
        approvedChild.committedToolCall.isNone() && observations.calls == 0,
        "approval retains derived ancestry and does not cross the execution barrier")
    let staleContext = ToolInvocationContext(context.runId, context.sessionId,
        context.capabilities, epoch: context.epoch + 1)
    expect(sourceError(pipeline.prepareDerived(staleContext, childCall, parent, "stale")) ==
        "tool.prepared_source_context_changed", "derived source cannot cross a run epoch")
    expect(match (pipeline.executePrepared(staleContext, child)) {
        case Result.Err(error) => error.code == "tool.prepared_source_context_changed"
        case _ => false
    }, "executor rejects a source reused with another epoch")
    expect(sourceError(pipeline.prepareDerived(context, childCall, child, "grandchild")) ==
        "tool.derived_source_invalid", "a derived child cannot become a new committed root")
    expect(pipeline.executePrepared(context, child).isOk() && observations.calls == 1 &&
        observations.kind == PreparedInvocationSourceKind.Derived &&
        observations.requestKey == "child-key",
        "executor receives the exact admitted typed source")
    let replay = sourceReady(pipeline.prepareDerived(context, childCall, parent, "child-key"))
    expect(pipeline.admitDerived(context, replay).value().getOrThrow().value == child.operationId.value &&
        observations.calls == 1,
        "repeated request retains the original child operation without another execution")
}

func sourceReady(result: Result<ToolPreparation>): PreparedToolInvocation {
    match (result) {
        case Result.Ok(ToolPreparation.Ready(value)) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("source fixture expected a ready plan")
    }
}

func sourceError(result: Result<ToolPreparation>): String {
    match (result) {
        case Result.Err(error) => error.code
        case _ => ""
    }
}

func sourcePending(result: Result<ToolPreparation>): PreparedToolInvocation {
    match (result) {
        case Result.Ok(ToolPreparation.NeedsApproval(value, _)) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("source fixture expected approval")
    }
}

class ConfirmSourcePolicy <: CapabilityPolicy {
    public func evaluate(context: ToolInvocationContext, plan: NormalizedOperationPlan): PolicyDecision {
        PolicyDecision(PermissionRequirement.Confirm)
    }
}

class SourceObservingExecutor <: ToolExecutor {
    var calls: Int64 = 0
    var kind = PreparedInvocationSourceKind.Direct
    var requestKey = ""

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        calls += 1
        kind = prepared.source.kind
        requestKey = prepared.source.requestKey
        Result.Ok(ToolResult(prepared.call.callId, objectValue([]), receiptId: prepared.operationId.value))
    }
}

func runDirectSourceAndHostServiceContract(serviceName: String): Unit {
    let catalog = ToolCatalog()
    let observed = SourceObservingExecutor()
    catalog.register(ToolDescriptor(
        ModelToolDefinition("plugin.source.echo", "plugin fixture", objectValue([])),
        Capability(CapabilityKind.WorkspaceRead)), observed).value().getOrThrow()
    for (name in ["host.process.readonly", "host.file.plan.propose", "host.fake.readonly"]) {
        catalog.register(ToolDescriptor(
            ModelToolDefinition(name, "host fixture", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true), observed).value().getOrThrow()
    }
    let operations = MemoryOperations()
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds())
    let caps = CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
    let snapshot = catalog.toolSetSnapshot("direct-source-tools", caps)
    expect(catalog.definitions().size == 1 && catalog.definitionsFor(caps).size == 1 &&
        snapshot.entries.size == 1 && snapshot.entries[0].name == "plugin.source.echo",
        "host-only services are absent from every model schema and run snapshot")
    let run = RunId("direct-source-run")
    let session = SessionId("direct-source-session")
    let thread = ThreadId(session.value)
    let turn = SemanticTurnId("direct-source-turn")
    let context = ToolInvocationContext(run, session, caps, epoch: 1, toolSetSnapshot: Some(snapshot))
    let hostCall = ToolCall("guessed-host", serviceName, objectValue([]))
    expect(sourceNotFound(pipeline.prepare(context, hostCall)), "raw callers cannot guess an internal service name")
    let trusted = ToolInvocationContext(run, session, caps, epoch: 1, trustedControl: true)
    expect(sourceNotFound(pipeline.prepare(trusted, hostCall)),
        "trusted control is not host-service derived authority")
    let rootCall = ToolCall("direct-source-root", "plugin.source.echo", objectValue([]))
    let raw = sourceReady(pipeline.prepare(context, rootCall))
    expect(sourceError(pipeline.prepareDerived(context, hostCall, raw,
        "javascript-service:" + rootCall.callId + ":unsealed")) == "tool.derived_source_invalid",
        "an unsealed Direct plan cannot obtain a hidden service by naming a plugin root")
    let coordinator = ThreadCoordinator(thread, "/workspace", InMemoryThreadCommitSink())
    let projector = ContextProjector("direct-source", SourceEstimator())
    let runtime = AgentThreadRuntime(coordinator, projector, { => 10 })
    let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses",
        ModelLaneCapabilitiesSnapshot(), 1000, 100, 20, "estimator", "retry", "cache", snapshot, "system")
    runtime.startTurn(turn, run, ItemId("direct-source-user"),
        ThreadItemContent.UserMessage(textMessageParts("direct")), lane, InvocationContextProjection())
        .value().getOrThrow()
    let item = ItemId("direct-source-item")
    expect(runtime.attestDirectToolCall(item, raw.operationId, run, 1).isError(),
        "a prepared plan alone does not attest a canonical Direct source")
    expect(match (runtime.commitResult(ResultEnvelope(thread, turn, run, 1, 1,
        ThreadItemDraft(ItemId("model-operation-spoof"), ThreadItemContent.ToolCall(
            CanonicalToolCallId(rootCall.callId), rootCall.name, rootCall.arguments),
            ItemProvenance("model", runId: Some(run), operationId: Some(raw.operationId)))))) {
        case SemanticCommitDecision.Rejected(error) => error.code == "thread.provenance_operation_unexpected"
        case _ => false
    }, "model ToolCall cannot acquire Direct operation provenance")
    expect(match (runtime.commitResult(ResultEnvelope(thread, turn, run, 1, 1,
        ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(rootCall.callId),
            rootCall.name, rootCall.arguments), ItemProvenance("direct_tool", runId: Some(run),
                operationId: Some(raw.operationId)))))) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }, "Direct source commits the actual host Item and exact operation binding")
    expect(runtime.attestDirectToolCall(item, OperationId("wrong-operation"), run, 1).isError() &&
        runtime.attestDirectToolCall(item, raw.operationId, RunId("wrong-run"), 1).isError() &&
        runtime.attestDirectToolCall(item, raw.operationId, run, 2).isError(),
        "Direct source rejects wrong operation, run and epoch")
    expect(runtime.cancel(0, expectedRunId: Some(RunId("old-direct-run")), expectedEpoch: Some(1)).isError() &&
        runtime.cancel(0, expectedRunId: Some(run), expectedEpoch: Some(2)).isError() &&
        runtime.activeRun().getOrThrow().state == RunState.Running,
        "late cancellation cannot cancel a different Direct run or epoch")
    let reference = runtime.attestDirectToolCall(item, raw.operationId, run, 1).value().getOrThrow()
    let bound = pipeline.bindDirectRoot(context, raw, reference).value().getOrThrow()
    expect(bound.source.kind == PreparedInvocationSourceKind.Direct && bound.committedToolCall.isNone() &&
        bound.source.operationRoot.isSome(), "binding Direct preserves its distinct non-model identity")
    expect(pipeline.bindDirectRoot(context, bound, reference).isError(),
        "an already bound source cannot be rebound")
    let wrongPrepared = sourceReady(pipeline.prepare(context,
        ToolCall("another-call", rootCall.name, objectValue([]))))
    expect(pipeline.bindDirectRoot(context, wrongPrepared, reference).isError(),
        "sealed Direct source cannot authorize another prepared operation")
    let child = sourceReady(pipeline.prepareDerived(context, hostCall, bound,
        "javascript-service:" + rootCall.callId + ":child"))
    expect(child.source.kind == PreparedInvocationSourceKind.Derived && child.source.rootToolCall.isNone() &&
        child.source.operationRoot.isSome(), "Direct-derived internal service resolves outside the model snapshot")
    expect(!pipeline.executePrepared(context, child).isOk() && observed.calls == 0,
        "a host-only name with a sealed source still cannot execute without durable admission")
    expect(sourceNotFound(pipeline.prepareDerived(context,
        ToolCall("fake", "host.fake.readonly", objectValue([])), bound,
        "javascript-service:" + rootCall.callId + ":fake")),
        "Derived snapshot fallback is restricted to the fixed generic host ports")
    // A separately constructed recovery owner may inspect the Item but never
    // restore a fresh process's Direct authority from serialized state.
    let recovered = AgentThreadRuntime(coordinator, projector,
        RecoveredRunSpec(turn, run, 1, RunState.Running, 1, lane, InvocationContextProjection()), { => 10 })
    expect(match (recovered.attestDirectToolCall(item, raw.operationId, run, 1)) {
        case Result.Err(error) => error.code == "operation.direct_recovery_forbidden"
        case _ => false
    }, "recovery cannot remint Direct process authority")
    // Even a canonical model guess cannot discover a host service.
    let guessedCoordinator = ThreadCoordinator(ThreadId("guessed-host-thread"), "/workspace", InMemoryThreadCommitSink())
    guessedCoordinator.startTurn(SemanticTurnId("guessed-turn"), run, ItemId("guessed-user"),
        ThreadItemContent.UserMessage(textMessageParts("guess"))).value().getOrThrow()
    let guessedBlock = ModelBlock(ModelBlockKind.ToolCall, callId: hostCall.callId,
        name: hostCall.name, arguments: hostCall.arguments)
    let _ = guessedCoordinator.commit(ResultEnvelope(ThreadId("guessed-host-thread"),
        SemanticTurnId("guessed-turn"), run, 1, 1, ThreadItemDraft(ItemId("guessed-item"),
            ThreadItemContent.ToolCall(CanonicalToolCallId(hostCall.callId), hostCall.name, hostCall.arguments),
            ItemProvenance("model", runId: Some(run)))))
    let guessedRef = guessedCoordinator.attestCommittedToolCalls([CommittedToolCallSource(
        ModelDecisionId("guessed-decision"), ScopedToolCallId("guessed-scoped"), ItemId("guessed-item"), guessedBlock
    )]).value().getOrThrow()[0]
    expect(sourceNotFound(pipeline.prepareCommitted(context, guessedRef)),
        "canonical model commitment cannot turn an internal port into a model tool")
}

func sourceNotFound(result: Result<ToolPreparation>): Bool {
    match (result) {
        case Result.Ok(ToolPreparation.Completed(value)) => value.isError &&
            canonicalAgentValue(value.output).contains("tool.not_found")
        case _ => false
    }
}

class SourceEstimator <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}
