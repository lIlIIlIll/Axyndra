package tool_runtime_contract

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// This port isolates ToolPipeline policy/scope tests. It is deliberately not
// durable evidence: the separate Store contract exercises 38 real SQL paths.
class ManagedJobToolOperations <: OperationRuntimePort {
    let inner = MemoryOperations()
    var completed = false
    var claimed = false
    var original: ?NormalizedOperationPlan = None
    var originalArguments = ""
    var originalOperation = ""
    var originalRun = ""
    var originalCallId = ""
    var originalToolName = ""
    var originalInput = ""
    public func reserveManagedJobLaunch(source: OperationRootSource, operation: OperationId, run: RunId,
        thread: ThreadId, epoch: Int64, plan: NormalizedOperationPlan): Result<ManagedJobLaunchBinding> {
        if (original.isSome()) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.job_already_reserved", "original invocation is immutable"))
        }
        let input = match (source) {
            case OperationRootSource.Direct(value) => value.call.arguments
            case OperationRootSource.Committed(value) => value.block.arguments
        }
        originalOperation = operation.value; originalRun = run.value
        originalCallId = source.callId(); originalToolName = source.toolName()
        originalInput = stringifyUnifiedJson(input)
        original = Some(plan); originalArguments = canonicalAgentValue(plan.canonicalArguments)
        let host = plan.canonicalArguments.field("host_plan").getOrThrow()
        Result.Ok(ManagedJobLaunchBinding(managedJobDeclarationFromValue(host.field("managed_job").getOrThrow()),
            thread, run, epoch, operation, source.itemId(), source.callId(), CHANNEL_PREPARATION_DIGEST,
            httpIntentText(host.field("binding").getOrThrow(), "permission_domain"),
            modelPolicySha256Text(canonicalAgentValue(host.field("binding").getOrThrow()))))
    }
    public func claimManagedJobLaunch(_: ManagedJobLaunchBinding): Result<Unit> {
        if (!completed || claimed) { return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.job_not_complete", "test completion fence")) }
        claimed = true; Result.Ok(())
    }
    public func verifyManagedJobLaunch(_: ManagedJobLaunchBinding): Result<Unit> {
        if (completed && claimed) { Result.Ok(()) } else { Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.job_not_complete", "test completion fence")) }
    }
    public func verifyManagedJobPlan(binding: ManagedJobLaunchBinding, plan: NormalizedOperationPlan): Result<Unit> {
        match (verifyManagedJobLaunch(binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (original.isSome() && sameNormalizedOperationPlan(original.getOrThrow(), plan) && canonicalAgentValue(plan.canonicalArguments) == originalArguments) { Result.Ok(()) }
        else { Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.job_plan_changed", "exact original plan required")) }
    }
    public func prepare(operation: OperationId, run: RunId, call: CommittedToolCallRef, plan: NormalizedOperationPlan): Result<Unit> { inner.prepare(operation, run, call, plan) }
    public func prepareTrustedControlOperation(operation: OperationId, run: RunId, item: ItemId, plan: NormalizedOperationPlan): Result<Unit> { inner.prepareTrustedControlOperation(operation, run, item, plan) }
    public func prepareDirectOperation(source: DirectToolCallRef, plan: NormalizedOperationPlan): Result<Unit> {
        match (source.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (source.validateExternalPlan(plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        inner.prepareTrustedControlOperation(source.operationId, source.runId, source.canonicalItemId, plan)
    }
    public func prepareDerivedInvocation(operation: OperationId, parent: OperationId, run: RunId,
        source: OperationRootSource, key: String, call: ToolCall, plan: NormalizedOperationPlan): Result<OperationId> {
        inner.prepareDerivedInvocation(operation, parent, run, source, key, call, plan)
    }
    public func prepareDerivedOperation(operation: OperationId, parent: OperationId, run: RunId, call: CommittedToolCallRef,
        key: String, plan: NormalizedOperationPlan): Result<OperationId> { inner.prepareDerivedOperation(operation, parent, run, call, key, plan) }
    public func waitForApproval(operation: OperationId, run: RunId): Result<Unit> { inner.waitForApproval(operation, run) }
    public func recordApproval(id: String, operation: OperationId, run: RunId, plan: NormalizedOperationPlan,
        ceiling: CapabilitySet, approved: Bool, source: String, expiry: ?Int64): Result<Unit> {
        inner.recordApproval(id, operation, run, plan, ceiling, approved, source, expiry)
    }
    public func markExecuting(operation: OperationId, run: RunId, plan: NormalizedOperationPlan, now: Int64, approved: Bool): Result<Unit> {
        inner.markExecuting(operation, run, plan, now, approved)
    }
    public func markExecutingWithSource(source: ?OperationRootSource, operation: OperationId, run: RunId,
        plan: NormalizedOperationPlan, now: Int64, approved: Bool): Result<Unit> {
        match (source) { case Some(OperationRootSource.Direct(root)) =>
            match (root.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case _ => () }
        inner.markExecuting(operation, run, plan, now, approved)
    }
    public func markExecutionHandoff(operation: OperationId, run: RunId, thread: ThreadId, now: Int64): Result<Unit> { inner.markExecutionHandoff(operation, run, thread, now) }
    public func markExecutionHandoffWithSource(source: ?OperationRootSource, operation: OperationId, run: RunId,
        thread: ThreadId, now: Int64): Result<Unit> {
        match (source) { case Some(OperationRootSource.Direct(root)) =>
            match (root.validateLiveSource()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case _ => () }
        inner.markExecutionHandoff(operation, run, thread, now)
    }
    public func loadPlan(operation: OperationId, run: RunId): Result<NormalizedOperationPlan> { inner.loadPlan(operation, run) }
    public func loadCall(operation: OperationId, run: RunId): Result<ToolCall> {
        // The Memory trusted-control adapter records normalized arguments and an
        // operation-derived call ID. Only this exact sealed reservation supplies
        // the original input; unrelated operations retain the Memory behavior.
        if (original.isSome() && operation.value == originalOperation && run.value == originalRun) {
            return Result.Ok(ToolCall(originalCallId, originalToolName, parseUnifiedJson(originalInput)))
        }
        inner.loadCall(operation, run)
    }
    public func loadCommittedToolResult(operation: OperationId, run: RunId): Result<?ToolResult> { inner.loadCommittedToolResult(operation, run) }
}

class ManagedJobToolCanonicalizer {
    let base = ChannelPreparationCanonicalizer()
    let job = ManagedJobDeclaration("tool-job", ThreadId("tool-job-thread"), RunId("tool-job-run"), agentUtcMillis() + 60000, 4)
    var fingerprint = ""
    func prepare(context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        let value = base.prepare(context, call).value().getOrThrow()
        let host = value.field("host_plan").getOrThrow()
        let binding = host.field("binding").getOrThrow()
        binding.put("permission_domain", textValue(managedInvocationAuthorityScope(context)))
        binding.put("implementation_fingerprint", textValue(fingerprint))
        host.put("managed_job", managedJobDeclarationValue(job))
        Result.Ok(value)
    }
}

func runManagedJobToolContract(): Unit {
    var count: Int64 = 0
    for (scenario in ["success", "ordinary", "snapshot", "wrong-thread", "wrong-epoch", "low-capability", "revoke", "cancel", "plan-drift",
        "child-intent", "child-wrong-parent", "child-binding-drift", "child-stale", "child-forged-origin"]) {
        managedJobToolScenario(scenario); count += 1
    }
    expect(count == 14, "all fourteen managed Task ToolPipeline scope/authority cases executed")
    println("Managed job ToolPipeline contract passed: 14 cases; Memory port, real Runtime seals and scoped catalog")
}

func managedJobToolScenario(scenario: String): Unit {
    let catalog = ToolCatalog()
    let name = "plugin.axyndra:channel-prepare.echo"
    let thread = ThreadId("channel-preparation-thread")
    let owner = ownedCatalogValue(catalog.createContributionOwner("managed-original", "plugin.axyndra:channel-prepare.", threadId: Some(thread)))
    let observation = SourceObservingExecutor()
    let canonicalizer = ManagedJobToolCanonicalizer()
    let caps = CapabilitySet(values: [Capability(CapabilityKind.ProcessSpawn), Capability(CapabilityKind.ExtensionInvoke),
        Capability(CapabilityKind.WorkspaceRead), Capability(CapabilityKind.Delegate, resource: "managed-job")])
    let descriptor = ToolDescriptor(ModelToolDefinition(name, "managed source", objectValue([])),
        Capability(CapabilityKind.ProcessSpawn), additionalCapabilities: [Capability(CapabilityKind.ExtensionInvoke),
            Capability(CapabilityKind.WorkspaceRead, resource: "/workspace"), Capability(CapabilityKind.Delegate, resource: "managed-job")],
        sideEffecting: true, neverReplay: true, implementationVersion: "1.0.0",
        canonicalArgumentsResolver: Some({ context, call => canonicalizer.prepare(context, call) }))
    let published = ownedCatalogValue(catalog.replaceOwnedBatch(owner, 0, ownedCatalogBinding(1), [ToolCatalogRegistration(descriptor, observation)]))
    canonicalizer.fingerprint = published.descriptors[0].implementationFingerprint
    catalog.register(ToolDescriptor(ModelToolDefinition(HOST_CHANNEL_WRITE_TOOL, "exact managed write", objectValue([])),
        Capability(CapabilityKind.ProcessSpawn), additionalCapabilities: [Capability(CapabilityKind.ExtensionInvoke),
            Capability(CapabilityKind.WorkspaceRead, resource: "/workspace")], sideEffecting: true, neverReplay: true,
        hostServiceOnly: true, implementationFingerprint: HOST_CHANNEL_WRITE_FINGERPRINT), observation).value().getOrThrow()
    let port = ManagedJobToolOperations()
    let pipeline = ToolPipeline(catalog, port, MemoryAudit(), FixedIds(), policy: ConfirmSourcePolicy())
    let parent = AgentThreadRuntime(ThreadCoordinator(thread, "/workspace", InMemoryThreadCommitSink()),
        ContextProjector("managed-tool", SourceEstimator()), { => agentUtcMillis() })
    let parentRun = RunId("managed-parent-run")
    let lane = threadCatalogLane(catalog.toolSetSnapshot("parent-tools", caps, threadId: Some(thread)))
    let started = parent.startTurn(SemanticTurnId("managed-parent-turn"), parentRun, ItemId("managed-user"),
        ThreadItemContent.UserMessage(textMessageParts("delegate exact bytes")), lane, InvocationContextProjection()).value().getOrThrow()
    let context = ToolInvocationContext(parentRun, SessionId(thread.value), caps, epoch: started.epoch,
        toolContext: ToolContextDescriptor(workspaceRoot: "/workspace"))
    let call = ToolCall("managed-original-call", name, channelPreparationInput())
    let pending = sourcePending(pipeline.prepare(context, call))
    expect(isManagedJobLaunchPlan(pending.operationPlan), "fixture has a valid exact managed launch plan")
    let item = ItemId("managed-parent-call")
    parent.commitResult(ResultEnvelope(thread, started.turnId, parentRun, started.epoch, 1,
        ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), name, call.arguments),
            ItemProvenance("direct_tool", runId: Some(parentRun), operationId: Some(pending.operationId)))))
    let parentSource = parent.attestDirectToolCall(item, pending.operationId, parentRun, started.epoch).value().getOrThrow()
    port.prepareTrustedControlOperation(pending.operationId, parentRun, item, pending.operationPlan).value().getOrThrow()
    port.waitForApproval(pending.operationId, parentRun).value().getOrThrow()
    let approved = match (pipeline.authorize(context, pending, ApprovalDecision.Approve)) {
        case Result.Ok(ToolAuthorization.Ready(value)) => value; case _ => throw IllegalStateException("managed original approval failed") }
    port.markExecuting(approved.operationId, parentRun, approved.operationPlan, agentUtcMillis(), true).value().getOrThrow()
    port.markExecutionHandoff(approved.operationId, parentRun, thread, agentUtcMillis()).value().getOrThrow()
    let reservation = parent.reserveManagedJob(OperationRootSource.Direct(parentSource), approved.operationId,
        approved.operationPlan, port, parentRun, started.epoch).value().getOrThrow()
    let memoryCall = ownedCatalogValue(port.inner.loadCall(approved.operationId, parentRun))
    expect(memoryCall.callId == approved.operationId.value && memoryCall.callId != call.callId &&
        canonicalAgentValue(memoryCall.arguments) == canonicalAgentValue(approved.operationPlan.canonicalArguments) &&
        canonicalAgentValue(memoryCall.arguments) != canonicalAgentValue(call.arguments),
        "the underlying Memory port retains its different normalized trusted-control call")
    let frozenCall = ownedCatalogValue(port.loadCall(approved.operationId, parentRun))
    expect(frozenCall.callId == call.callId && frozenCall.name == call.name &&
        canonicalAgentValue(frozenCall.arguments) == canonicalAgentValue(call.arguments),
        "only the reserved original operation and Run return the sealed original input")
    frozenCall.arguments.put("fixture_mutation", textValue("does not escape"))
    expect(canonicalAgentValue(ownedCatalogValue(port.loadCall(approved.operationId, parentRun)).arguments) == canonicalAgentValue(call.arguments) &&
        port.loadCall(OperationId("unreserved-operation"), parentRun).isError() &&
        port.loadCall(approved.operationId, RunId("unreserved-run")).isError(),
        "loadCall returns an isolated clone and does not grant arbitrary operation or Run access")
    expect(reservation.claim().isError(), "test port does not claim before actual launch completion")
    parent.resolveOperation(ItemId("managed-launch-result"), approved.operationId, CanonicalToolCallId(call.callId), approved.operationPlan,
        OperationAttemptStage.Executing, Result.Ok(ToolInvocationResult.Completed(reservation.launchResult())),
        "managed-launch-receipt", agentUtcMillis()).value().getOrThrow()
    parent.finish(RunState.Completed, agentUtcMillis()).value().getOrThrow()
    port.completed = true
    let admission = reservation.claim().value().getOrThrow()
    let task = AgentThreadRuntime(ThreadCoordinator(admission.binding.declaration.threadId, "/workspace", InMemoryThreadCommitSink()),
        ContextProjector("managed-task", SourceEstimator()), { => agentUtcMillis() })
    let taskRun = task.startManagedJobTurn(admission, SemanticTurnId("task-turn"), ItemId("task-initiator"), lane,
        InvocationContextProjection()).value().getOrThrow()
    let root = ownedCatalogValue(task.commitManagedJobToolCall(admission, ItemId("task-call"), OperationId("task-op"), call,
        taskRun.runId, taskRun.epoch))
    let taskContext = ToolInvocationContext(taskRun.runId,
        SessionId(if (scenario == "wrong-thread") { "wrong" } else { taskRun.threadId.value }),
        if (scenario == "low-capability") { CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]) } else { caps },
        epoch: if (scenario == "wrong-epoch") { taskRun.epoch + 1 } else { taskRun.epoch },
        cancellation: root.externalCancellationToken.getOrThrow(), toolContext: ToolContextDescriptor(workspaceRoot: "/workspace"),
        toolSetSnapshot: if (scenario == "snapshot") { Some(lane.toolSet) } else { None })
    if (scenario == "ordinary") {
        expect(sourceNotFound(pipeline.prepare(taskContext, call)) && observation.calls == 0,
            "ordinary Task Thread preparation cannot see the parent's scoped directory")
        return
    }
    let callsBefore = canonicalizer.base.calls
    let prepared = pipeline.prepareManagedJob(taskContext, root)
    if (["snapshot", "wrong-thread", "wrong-epoch", "low-capability"].contains(scenario)) {
        expect(prepared.isError() && observation.calls == 0, "Task scope/capability changes fail before execution")
        return
    }
    let invocation = prepared.value().getOrThrow()
    expect(invocation.authorization == PreparedAuthorization.ManagedJob && sameNormalizedOperationPlan(invocation.operationPlan, approved.operationPlan) &&
        canonicalizer.base.calls == callsBefore, "Task retains the original exact plan without second prepare or second approval")
    if (scenario.startsWith("child-")) {
        if (scenario == "child-forged-origin") {
            let fake = AgentThreadRuntime(ThreadCoordinator(taskRun.threadId, "/workspace", InMemoryThreadCommitSink()),
                ContextProjector("descriptive-only", SourceEstimator()), { => agentUtcMillis() })
            let fakeLane = threadCatalogLane(catalog.toolSetSnapshot("fake-tools", caps, threadId: Some(taskRun.threadId)))
            let fakeRun = fake.startTurn(SemanticTurnId("fake-turn"), RunId("fake-run"), ItemId("fake-user"),
                ThreadItemContent.UserMessage(textMessageParts("ordinary owner")), fakeLane, InvocationContextProjection()).value().getOrThrow()
            let fakeItem = ItemId("fake-managed-call"); let fakeOperation = OperationId("fake-managed-operation")
            let commit = fake.commitResult(ResultEnvelope(taskRun.threadId, fakeRun.turnId, fakeRun.runId, fakeRun.epoch, 1,
                ThreadItemDraft(fakeItem, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
                    ItemProvenance("direct_tool", runId: Some(fakeRun.runId), operationId: Some(fakeOperation),
                        directOrigin: Some(DirectCallOrigin.ManagedJob(admission.binding))))))
            expect(match (commit) { case SemanticCommitDecision.Rejected(error) => error.code == "thread.host_origin_requires_owner"; case _ => false },
                "ordinary canonical commit rejects descriptive ManagedJob origin before storing an Item")
            for (actual in fake.threadSnapshot().items) {
                expect(actual.id.value != fakeItem.value, "forged ManagedJob source creates no canonical ToolCall")
            }
            expect(fake.attestDirectToolCall(fakeItem, fakeOperation, fakeRun.runId, fakeRun.epoch).isError(),
                "ordinary Runtime cannot mint Task authority from a copied ManagedJob DTO")
            return
        }
        let frozen = invocation.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        expect(httpIntentText(frozen, "target_thread_id") == thread.value && thread.value != taskContext.sessionId.value,
            "the live Task Thread is distinct from the frozen service target")
        // Mutate both parent and proposed child, so byte equality alone cannot
        // authorize a different target or resource without the sealed digest.
        if (scenario == "child-wrong-parent") { frozen.put("target_thread_id", textValue("other-original-thread")) }
        if (scenario == "child-binding-drift") { frozen.put("lease_id", textValue("another-lease")) }
        let child = ToolCall("task-write", HOST_CHANNEL_WRITE_TOOL,
            channelServiceChildArguments(invocation.operationPlan.canonicalArguments, "write-1").value().getOrThrow())
        if (scenario == "child-stale") { reservation.cancel() }
        let result = pipeline.prepareDerived(taskContext, child, invocation, "channel-service:" + call.callId + ":write-1")
        if (scenario == "child-intent") {
            let value = sourceReady(result)
            expect(value.authorization == PreparedAuthorization.ParentIntent && value.approval.isNone() &&
                value.source.kind == PreparedInvocationSourceKind.Derived && observation.calls == 0,
                "live sealed Task retains exact parent intent without a fabricated second approval")
        } else if (scenario == "child-stale") {
            expect(result.isError() && observation.calls == 0, "a cancelled Task cannot regain intent authorization")
        } else {
            expect(channelPreparationPending(result).authorization == PreparedAuthorization.ApprovalRequired && observation.calls == 0,
                "changed target or binding does not inherit authorization even when child and parent bytes agree")
        }
        return
    }
    if (scenario == "revoke") { catalog.revokeOwned(owner).value().getOrThrow() }
    if (scenario == "cancel") { reservation.cancel() }
    if (scenario == "plan-drift") { invocation.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("intents").getOrThrow().items[0].put("bytes_hex", textValue("00")) }
    let result = pipeline.executePrepared(taskContext, invocation)
    if (scenario == "success") {
        expect(result.isOk() && observation.calls == 1 && canonicalizer.base.calls == callsBefore,
            "exact current Task executes original contribution once with child identity and frozen bytes")
    } else { expect(result.isError() && observation.calls == 0, "revocation/cancellation/drift denies task dispatch") }
}
