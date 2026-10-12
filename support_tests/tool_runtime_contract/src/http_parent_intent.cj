package tool_runtime_contract

import agent_domain.*
import agent_runtime.*
import std.collection.*
import tool_runtime.*
import yjson.*
import yjson_support.*

func runHttpParentIntentPreparationContract(): Unit {
    httpParentIntentPreparationFor("GET")
    httpParentIntentPreparationFor("POST")
    httpCommittedApprovalSourceContract()
    println("HTTP ParentIntent preparation contract passed: GET and POST")
}

func httpPreparationNetwork(): NetworkPolicy {
    NetworkPolicy(NetworkPolicyMode.Mediated, egress: [NetworkEgressRule("fixture.example", 443u16)])
}

func httpPreparationInput(): AgentValue {
    objectValue([ValueField("query", textValue("original"))])
}

func httpPreparationArguments(method: String, query!: String = "original"): AgentValue {
    objectValue([
        ValueField("input", httpPreparationInput()),
        ValueField("configuration", objectValue([])),
        ValueField("host_plan", objectValue([
            ValueField("version", textValue(HOST_HTTP_INTENT_VERSION)),
            ValueField("plugin", textValue("axyndra:http-prepare")),
            ValueField("package_digest", textValue("sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
            ValueField("generation", textValue("1")),
            ValueField("configuration_digest", textValue("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")),
            ValueField("intents", listValue([objectValue([
                ValueField("id", textValue("request-1")),
                ValueField("network", networkPolicyCanonicalValue(httpPreparationNetwork())),
                ValueField("request", objectValue([
                    ValueField("method", textValue(method)),
                    ValueField("url", textValue("https://fixture.example/search")),
                    ValueField("query", objectValue([ValueField("q", textValue(query))])),
                    ValueField("headers", objectValue([])),
                    ValueField("json_body", if (method == "GET") { nullValue() }
                        else { objectValue([ValueField("query", textValue(query))]) }),
                    ValueField("credential_refs", listValue([])),
                    ValueField("timeout_ms", integerValue(1000))
                ]))
            ])]))
        ]))
    ])
}

class HttpPreparationCanonicalizer {
    let method: String
    var calls: Int64 = 0
    var query = "original"
    init(method: String) { this.method = method }

    func prepare(_: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        calls += 1
        if (canonicalAgentValue(call.arguments) != canonicalAgentValue(httpPreparationInput())) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "fixture.raw_input_required",
                "HTTP prepare must receive the original input on every approval pass"))
        }
        Result.Ok(httpPreparationArguments(method, query: query))
    }
}

class HttpPreparationPolicy <: CapabilityPolicy {
    let denyHttp: Bool
    init(denyHttp!: Bool = false) { this.denyHttp = denyHttp }

    public func evaluate(_: ToolInvocationContext, plan: NormalizedOperationPlan): PolicyDecision {
        PolicyDecision(if (denyHttp && plan.toolName == HOST_HTTP_SERVICE_TOOL) {
            PermissionRequirement.Deny
        } else { PermissionRequirement.Confirm }, reason: "HTTP fixture policy")
    }
}

func httpPreparationCommitted(
    coordinator: ThreadCoordinator,
    context: ToolInvocationContext,
    sequence: Int64,
    suffix: String,
    call: ToolCall
): CommittedToolCallRef {
    let item = ItemId("http-prepare-item-" + suffix)
    let block = ModelBlock(ModelBlockKind.ToolCall, callId: call.callId, name: call.name, arguments: call.arguments)
    expect(match (coordinator.commit(ResultEnvelope(ThreadId(context.sessionId.value),
        SemanticTurnId("http-prepare-turn"), context.runId, 1, sequence,
        ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
            ItemProvenance("model", runId: Some(context.runId)))))) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }, "HTTP fixture commits the canonical ToolCall before requesting attestation")
    coordinator.attestCommittedToolCalls([CommittedToolCallSource(ModelDecisionId("http-decision-" + suffix),
        ScopedToolCallId("http-scoped-" + suffix), item, block)]).value().getOrThrow()[0]
}

func httpPreparationDenied(result: Result<ToolPreparation>): Bool {
    match (result) {
        case Result.Ok(ToolPreparation.Denied(value)) => value.reason.code == "tool.capability_denied"
        case _ => false
    }
}

func httpParentIntentPreparationFor(method: String): Unit {
    let catalog = ToolCatalog()
    let observations = SourceObservingExecutor()
    let canonicalizer = HttpPreparationCanonicalizer(method)
    let network = httpPreparationNetwork()
    let networkCapability = Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(network.egress[0]))
    let rootName = "plugin.axyndra:http-prepare.search"
    catalog.register(ToolDescriptor(ModelToolDefinition(rootName, "HTTP root fixture", objectValue([])),
        Capability(CapabilityKind.ExtensionInvoke), sideEffecting: true, neverReplay: true,
        additionalCapabilities: [networkCapability],
        implementationFingerprint: "axyndra:http-prepare:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        canonicalArgumentsResolver: Some({ context, call => canonicalizer.prepare(context, call) }),
        networkPolicyResolver: Some({ _ => Result.Ok(network) })), observations).value().getOrThrow()
    catalog.register(ToolDescriptor(ModelToolDefinition(HOST_HTTP_SERVICE_TOOL, "hidden HTTP fixture", objectValue([])),
        networkCapability, sideEffecting: method == "POST", hostServiceOnly: true, neverReplay: true,
        implementationFingerprint: "host-http-intent-v1",
        networkPolicyResolver: Some({ _ => Result.Ok(network) })), observations).value().getOrThrow()
    register(catalog, "run_program", CapabilityKind.WorkspaceRead, false)
    let operations = MemoryOperations()
    let audit = MemoryAudit()
    let ids = FixedIds()
    let pipeline = ToolPipeline(catalog, operations, audit, ids, policy: HttpPreparationPolicy())
    let caps = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), networkCapability,
        Capability(CapabilityKind.WorkspaceRead)])
    let snapshot = catalog.toolSetSnapshot("http-preparation-tools", caps)
    expect(catalog.definitions().size == 2 && catalog.definitionsFor(caps).size == 2 && snapshot.entries.size == 2,
        method + " hidden HTTP port stays absent from model schemas and frozen run tools")
    let context = ToolInvocationContext(RunId("http-prepare-run"), SessionId("http-prepare-session"), caps,
        epoch: 1, toolSetSnapshot: Some(snapshot))
    let coordinator = ThreadCoordinator(ThreadId(context.sessionId.value), "/workspace", InMemoryThreadCommitSink())
    coordinator.startTurn(SemanticTurnId("http-prepare-turn"), context.runId, ItemId("http-prepare-user"),
        ThreadItemContent.UserMessage(textMessageParts("HTTP preparation"))).value().getOrThrow()
    let rootCall = ToolCall("http-root-call", rootName, httpPreparationInput())
    let committed = httpPreparationCommitted(coordinator, context, 1, "root", rootCall)
    let pending = sourcePending(pipeline.prepareCommitted(context, committed))
    expect(pending.authorization == PreparedAuthorization.ApprovalRequired && pending.approval.isSome() &&
        canonicalAgentValue(pending.call.arguments) == canonicalAgentValue(rootCall.arguments) &&
        canonicalAgentValue(pending.operationPlan.canonicalArguments) == canonicalAgentValue(httpPreparationArguments(method)) &&
        pending.operationPlan.effectClass == OperationEffectClass.ExternalMutation &&
        pending.operationPlan.retryDisposition == OperationRetryDisposition.Never,
        method + " root approval freezes expanded HTTP intent while retaining the original call")
    let childArgs = httpServiceChildArguments(pending.operationPlan.canonicalArguments, "request-1")
        .value().getOrThrow()
    let childCall = ToolCall("http-child-call", HOST_HTTP_SERVICE_TOOL, childArgs)
    let requestKey = "javascript-service:" + rootCall.callId + ":request-1"
    expect(sourceNotFound(pipeline.prepareDerived(context, childCall, pending,
        "channel-service:" + rootCall.callId + ":request-1")),
        method + " channel service keys cannot resolve the HTTP-only hidden port")
    let pendingChild = sourcePending(pipeline.prepareDerived(context, childCall, pending, requestKey))
    expect(pendingChild.authorization == PreparedAuthorization.ApprovalRequired,
        method + " a pending parent does not preauthorize a child")
    operations.prepare(pending.operationId, context.runId, committed, pending.operationPlan).value().getOrThrow()
    let approved = match (pipeline.authorize(context, pending, ApprovalDecision.Approve,
        decisionSource: ApprovalDecisionSource.User)) {
        case Result.Ok(ToolAuthorization.Ready(value)) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("HTTP fixture root was not approved")
    }
    expect(approved.authorization == PreparedAuthorization.Approved && canonicalizer.calls >= 2,
        method + " root consumes real User approval after rerunning pure preparation")
    let beforeChildAudit = audit.events.size
    let child = sourceReady(pipeline.prepareDerived(context, childCall, approved, requestKey))
    expect(child.authorization == PreparedAuthorization.ParentIntent && child.approval.isNone() &&
        child.source.kind == PreparedInvocationSourceKind.Derived &&
        child.source.parentOperationId.getOrThrow().value == approved.operationId.value &&
        audit.events.size == beforeChildAudit && !operations.loadPlan(child.operationId, context.runId).isOk(),
        method + " Confirm narrows to ParentIntent without pending approval, fake User grant or durable admission")
    expect(match (pipeline.authorize(context, child, ApprovalDecision.Approve)) {
        case Result.Err(error) => error.code == "tool.approval_not_required"
        case _ => false
    }, method + " ParentIntent cannot be relabeled as an approved User decision")
    expect(child.operationPlan.retryDisposition == OperationRetryDisposition.Never &&
        (match (child.operationPlan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }) &&
        child.operationPlan.effectClass == (if (method == "GET") {
            OperationEffectClass.ReadOnly
        } else { OperationEffectClass.ExternalMutation }),
        method + " HTTP descriptor preserves Never replay including read-only GET")
    let denying = ToolPipeline(catalog, operations, MemoryAudit(), ids,
        policy: HttpPreparationPolicy(denyHttp: true))
    expect(httpPreparationDenied(denying.prepareDerived(context, childCall, approved, requestKey)),
        method + " an exact parent intent cannot override explicit child policy Deny")
    let noNetwork = ToolInvocationContext(context.runId, context.sessionId,
        CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke)]), epoch: 1,
        toolSetSnapshot: Some(snapshot))
    expect(httpPreparationDenied(pipeline.prepareDerived(noNetwork, childCall, approved, requestKey)),
        method + " parent intent cannot replace missing Run capabilities")
    let changedArgs = httpServiceChildArguments(httpPreparationArguments(method, query: "changed"), "request-1")
        .value().getOrThrow()
    expect(sourcePending(pipeline.prepareDerived(context, ToolCall("http-changed", HOST_HTTP_SERVICE_TOOL,
        changedArgs), approved, requestKey)).authorization == PreparedAuthorization.ApprovalRequired,
        method + " changed request bytes do not inherit the original parent intent")
    expect(sourcePending(pipeline.prepareDerived(context, childCall, approved, requestKey + "-other"))
        .authorization == PreparedAuthorization.ApprovalRequired,
        method + " another transport key cannot claim the frozen intent authorization")
    expect(sourceNotFound(pipeline.prepare(context, childCall)), method + " raw calls cannot discover hidden HTTP")
    let trusted = ToolInvocationContext(context.runId, context.sessionId, caps, epoch: 1, trustedControl: true)
    expect(sourceNotFound(pipeline.prepare(trusted, childCall)), method + " trusted control cannot guess hidden HTTP")
    let guessed = httpPreparationCommitted(coordinator, context, 2, "guess", childCall)
    expect(sourceNotFound(pipeline.prepareCommitted(context, guessed)),
        method + " a committed model call cannot expose the hidden HTTP port")
    let programRef = httpPreparationCommitted(coordinator, context, 3, "program",
        ToolCall("http-program", "run_program", objectValue([])))
    let program = sourcePending(pipeline.prepareCommitted(context, programRef))
    expect(sourceNotFound(pipeline.prepareDerived(context, childCall, program,
        "javascript-service:http-program:request-1")), method + " Program cannot acquire the plugin-only HTTP port")
    // This fixture exercises preparation only. Its in-memory Operation port
    // cannot supply SQLite HTTP ParentIntent proof and no executor is invoked.
    expect(observations.calls == 0, method + " all preparation and approval checks stay before HTTP execution")
}

class HttpApprovalSourceExecutor <: ToolExecutor {
    var captured: ?PreparedToolInvocation = None
    var calls: Int64 = 0
    public func execute(_: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        captured = Some(prepared)
        calls += 1
        Result.Ok(ToolResult(prepared.call.callId, objectValue([])))
    }
}

// Keep the actual in-memory plan/handoff implementation; observe approval at
// the port boundary and require its exact operation before executor admission.
class HttpApprovalRecordingOperations <: OperationRuntimePort {
    let inner = InMemoryOperationRuntimePort()
    var approvals: Int64 = 0
    var approvedOperation = ""
    var approvedSource = ""
    var approved = false
    public func prepare(id: OperationId, run: RunId, source: CommittedToolCallRef,
        plan: NormalizedOperationPlan): Result<Unit> { inner.prepare(id, run, source, plan) }
    public func prepareTrustedControlOperation(id: OperationId, run: RunId, item: ItemId,
        plan: NormalizedOperationPlan): Result<Unit> { inner.prepareTrustedControlOperation(id, run, item, plan) }
    public func prepareDerivedInvocation(operation: OperationId, parent: OperationId, run: RunId,
        source: OperationRootSource, key: String, call: ToolCall, plan: NormalizedOperationPlan): Result<OperationId> {
        inner.prepareDerivedInvocation(operation, parent, run, source, key, call, plan)
    }
    public func prepareDerivedOperation(id: OperationId, parent: OperationId, run: RunId,
        source: CommittedToolCallRef, key: String, plan: NormalizedOperationPlan): Result<OperationId> {
        inner.prepareDerivedOperation(id, parent, run, source, key, plan)
    }
    public func waitForApproval(id: OperationId, run: RunId): Result<Unit> { inner.waitForApproval(id, run) }
    public func recordApproval(id: String, operation: OperationId, run: RunId, plan: NormalizedOperationPlan,
        ceiling: CapabilitySet, approved: Bool, source: String, expiry: ?Int64): Result<Unit> {
        match (inner.recordApproval(id, operation, run, plan, ceiling, approved, source, expiry)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        approvals += 1
        approvedOperation = operation.value
        approvedSource = source
        this.approved = approved
        Result.Ok(())
    }
    public func markExecuting(id: OperationId, run: RunId, plan: NormalizedOperationPlan,
        now: Int64, required: Bool): Result<Unit> {
        if (!required || !approved || approvedOperation != id.value || approvedSource != "user") {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "fixture.approval_missing",
                "approval continuation did not record the real User decision before execution"))
        }
        inner.markExecuting(id, run, plan, now, required)
    }
    public func markExecutionHandoff(id: OperationId, run: RunId, thread: ThreadId, now: Int64): Result<Unit> {
        inner.markExecutionHandoff(id, run, thread, now)
    }
    public func loadPlan(id: OperationId, run: RunId): Result<NormalizedOperationPlan> { inner.loadPlan(id, run) }
    public func loadCall(id: OperationId, run: RunId): Result<ToolCall> { inner.loadCall(id, run) }
    public func loadCommittedToolResult(id: OperationId, run: RunId): Result<?ToolResult> {
        inner.loadCommittedToolResult(id, run)
    }
}

func httpApprovalCommittedSource(runtime: AgentThreadRuntime, context: ToolInvocationContext,
    sequence: Int64, suffix: String, call: ToolCall,
    decisionSuffix!: String = ""): CommittedToolCallRef {
    let item = ItemId("http-approval-item-" + suffix)
    let block = ModelBlock(ModelBlockKind.ToolCall, callId: call.callId, name: call.name, arguments: call.arguments)
    expect(match (runtime.commitResult(ResultEnvelope(ThreadId(context.sessionId.value),
        SemanticTurnId("http-approval-turn"), context.runId, context.epoch, sequence,
        ThreadItemDraft(item, ThreadItemContent.ToolCall(CanonicalToolCallId(call.callId), call.name, call.arguments),
            ItemProvenance("model", runId: Some(context.runId)))))) {
        case SemanticCommitDecision.Committed(_, _) => true
        case _ => false
    }, "approval fixture commits each canonical call through the live ThreadRuntime")
    let binding = if (decisionSuffix == "") { suffix } else { decisionSuffix }
    runtime.attestCommittedToolCalls([CommittedToolCallSource(ModelDecisionId("http-approval-decision-" + binding),
        ScopedToolCallId("http-approval-scoped-" + binding), item, block)]).value().getOrThrow()[0]
}

func httpApprovalSourceMismatch(result: Result<ToolInvocationResult>): Bool {
    match (result) { case Result.Err(error) => error.code == "tool.approval_source_mismatch"; case _ => false }
}

func httpCommittedApprovalSourceContract(): Unit {
    let rootName = "plugin.axyndra:http-prepare.search"
    let network = httpPreparationNetwork()
    let networkCapability = Capability(CapabilityKind.NetworkAccess, resource: networkEgressResource(network.egress[0]))
    let caps = CapabilitySet(values: [Capability(CapabilityKind.ExtensionInvoke), networkCapability])
    let catalog = ToolCatalog()
    let observed = HttpApprovalSourceExecutor()
    catalog.register(ToolDescriptor(ModelToolDefinition(rootName, "approval source root", objectValue([])),
        Capability(CapabilityKind.ExtensionInvoke), sideEffecting: true, neverReplay: true,
        additionalCapabilities: [networkCapability],
        implementationFingerprint: "axyndra:http-prepare:sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        networkPolicyResolver: Some({ _ => Result.Ok(network) })), observed).value().getOrThrow()
    catalog.register(ToolDescriptor(ModelToolDefinition(HOST_HTTP_SERVICE_TOOL, "hidden HTTP", objectValue([])),
        networkCapability, sideEffecting: true, hostServiceOnly: true, neverReplay: true,
        implementationFingerprint: "host-http-intent-v1",
        networkPolicyResolver: Some({ _ => Result.Ok(network) })), SourceObservingExecutor()).value().getOrThrow()
    let operations = HttpApprovalRecordingOperations()
    let pipeline = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds(), policy: HttpPreparationPolicy())
    let snapshot = catalog.toolSetSnapshot("http-approval-tools", caps)
    let context = ToolInvocationContext(RunId("http-approval-run"), SessionId("http-approval-thread"), caps,
        epoch: 1, toolSetSnapshot: Some(snapshot))
    let coordinator = ThreadCoordinator(ThreadId(context.sessionId.value), "/workspace", InMemoryThreadCommitSink())
    let runtime = AgentThreadRuntime(coordinator, ContextProjector("http-approval", SourceEstimator()), { => 10 })
    let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
        1000, 100, 20, "estimator", "retry", "cache", snapshot, "system")
    runtime.startTurn(SemanticTurnId("http-approval-turn"), context.runId, ItemId("http-approval-user"),
        ThreadItemContent.UserMessage(textMessageParts("approve HTTP")), lane, InvocationContextProjection())
        .value().getOrThrow()
    let rootCall = ToolCall("http-approval-root", rootName, httpPreparationInput())
    let rootRef = httpApprovalCommittedSource(runtime, context, 1, "root", rootCall)
    // Effective hook arguments differ from the model's original input. Source
    // restoration must bind call identity while rechecking the persisted plan.
    let pending = sourcePending(pipeline.prepareCommitted(context, rootRef,
        effectiveArguments: Some(httpPreparationArguments("POST"))))
    operations.prepare(pending.operationId, context.runId, rootRef, pending.operationPlan).value().getOrThrow()
    let otherCall = ToolCall("http-approval-other", rootName, httpPreparationInput())
    let otherRef = httpApprovalCommittedSource(runtime, context, 2, "other", otherCall)
    let wrongCallRef = httpApprovalCommittedSource(runtime, context, 3, "wrong-call",
        ToolCall("http-approval-wrong-call", rootName, httpPreparationInput()), decisionSuffix: "root")
    expect(httpApprovalSourceMismatch(pipeline.decideCommitted(context, pending.operationId, otherRef,
        ApprovalDecision.Approve, { _ => Result.Ok(()) })) &&
        httpApprovalSourceMismatch(pipeline.decideCommitted(context, pending.operationId, wrongCallRef,
            ApprovalDecision.Approve, { _ => Result.Ok(()) })) && operations.approvals == 0 && observed.calls == 0,
        "another Decision/Scoped operation or canonical call cannot consume approval or reach the executor")
    let wrongRun = ToolInvocationContext(RunId("http-approval-other-run"), context.sessionId, caps,
        epoch: 1, toolSetSnapshot: Some(snapshot))
    expect(pipeline.decideCommitted(wrongRun, pending.operationId, rootRef,
        ApprovalDecision.Approve, { _ => Result.Ok(()) }).isError() && operations.approvals == 0,
        "approval continuation cannot restore a sealed source across stored Run ownership")
    let handedOff = ArrayList<PreparedToolInvocation>()
    expect(pipeline.decideCommitted(context, pending.operationId, rootRef, ApprovalDecision.Approve,
        { prepared =>
            handedOff.add(prepared)
            Result.Ok(())
        }).isOk() && handedOff.size == 1 &&
        handedOff[0].source.kind == PreparedInvocationSourceKind.Committed &&
        handedOff[0].source.rootToolCall.getOrThrow().canonicalItemId.value == rootRef.canonicalItemId.value &&
        observed.calls == 1 && operations.approvals == 1 &&
        operations.approved && operations.approvedSource == "user" &&
        operations.approvedOperation == pending.operationId.value,
        "committed approval records a real User decision and hands off the exact ThreadRuntime attestation")
    let approved = observed.captured.getOrThrow()
    let childCall = ToolCall("http-approval-child", HOST_HTTP_SERVICE_TOOL,
        httpServiceChildArguments(approved.operationPlan.canonicalArguments, "request-1").value().getOrThrow())
    let child = sourceReady(pipeline.prepareDerived(context, childCall, approved,
        "javascript-service:" + rootCall.callId + ":request-1"))
    expect(child.authorization == PreparedAuthorization.ParentIntent &&
        child.source.rootToolCall.getOrThrow().canonicalItemId.value == rootRef.canonicalItemId.value &&
        child.source.parentOperationId.getOrThrow().value == approved.operationId.value,
        "approved committed root can derive only its exact frozen HTTP intent with the original source")
    let rawPending = sourcePending(pipeline.prepareCommitted(context, otherRef,
        effectiveArguments: Some(httpPreparationArguments("POST"))))
    operations.prepare(rawPending.operationId, context.runId, otherRef, rawPending.operationPlan).value().getOrThrow()
    expect(pipeline.decide(context, rawPending.operationId, ApprovalDecision.Approve).isOk() &&
        operations.approvals == 2 && observed.calls == 2,
        "legacy raw approval still records its decision and executes the ordinary root")
    let raw = observed.captured.getOrThrow()
    expect(raw.source.kind == PreparedInvocationSourceKind.Direct && raw.source.operationRoot.isNone() &&
        sourceError(pipeline.prepareDerived(context, childCall, raw,
            "javascript-service:" + otherCall.callId + ":request-1")) == "tool.derived_source_invalid",
        "raw decide never invents a sealed canonical source or gains derived-service authority")
    println("HTTP Committed approval recovery contract passed")
}
