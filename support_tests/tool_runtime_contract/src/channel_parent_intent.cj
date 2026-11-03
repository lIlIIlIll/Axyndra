package tool_runtime_contract

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*

let CHANNEL_PREPARATION_DIGEST = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func channelPreparationInput(): AgentValue { objectValue([ValueField("query", textValue("original channel request"))]) }

class ChannelPreparationCanonicalizer {
    var calls: Int64 = 0
    var changed = ""
    func prepare(_: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        calls += 1
        if (canonicalAgentValue(call.arguments) != canonicalAgentValue(channelPreparationInput())) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "fixture.channel_raw_input_required",
                "channel approval must reprepare original input"))
        }
        let binding = objectValue([
            ValueField("plugin", textValue("axyndra:channel-prepare")),
            ValueField("package_digest", textValue("sha256:" + CHANNEL_PREPARATION_DIGEST)),
            ValueField("configuration_digest", textValue(CHANNEL_PREPARATION_DIGEST)),
            ValueField("instance_identity", textValue("channel-instance")),
            ValueField("endpoint_identity", textValue(CHANNEL_PREPARATION_DIGEST)),
            ValueField("lease_id", textValue("channel-lease")), ValueField("launch_digest", textValue(CHANNEL_PREPARATION_DIGEST)),
            ValueField("startup_operation_id", textValue("startup-operation")),
            ValueField("target_thread_id", textValue("channel-preparation-thread")),
            ValueField("permission_domain", textValue(CHANNEL_PREPARATION_DIGEST)),
            ValueField("directory_revision", integerValue(1)), ValueField("directory_digest", textValue(CHANNEL_PREPARATION_DIGEST)),
            ValueField("implementation_version", textValue("1.0.0")),
            ValueField("implementation_fingerprint", textValue("owned-v1:" + CHANNEL_PREPARATION_DIGEST)),
            ValueField("schema_digest", textValue(modelPolicySha256Text(canonicalAgentValue(objectValue([]))))),
            ValueField("workspace_root", textValue("/workspace")), ValueField("workspace_mode", textValue("workspace_readonly")),
            ValueField("network", networkPolicyCanonicalValue(NetworkPolicy(NetworkPolicyMode.Denied)))
        ])
        let intent = objectValue([ValueField("id", textValue("write-1")), ValueField("bytes_hex", textValue("68690a"))])
        if (changed != "") { channelPreparationChange(binding, intent, changed) }
        Result.Ok(objectValue([
            ValueField("input", channelPreparationInput()), ValueField("configuration", objectValue([])),
            ValueField("host_plan", objectValue([ValueField("version", textValue(HOST_CHANNEL_INTENT_VERSION)),
                ValueField("binding", binding), ValueField("intents", listValue([intent]))]))
        ]))
    }
}

func channelPreparationChange(binding: AgentValue, intent: AgentValue, field: String): Unit {
    if (field == "bytes") { intent.put("bytes_hex", textValue("686921")) }
    else if (field == "directory_revision") { binding.put(field, integerValue(2)) }
    else if (field == "directory_digest") {
        binding.put(field, textValue("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
    } else if (field == "implementation_fingerprint") {
        binding.put(field, textValue("owned-v1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
    } else { binding.put(field, textValue("changed-identity")) }
}

class ChannelPreparationPolicy <: CapabilityPolicy {
    let denyChannel: Bool
    init(denyChannel!: Bool = false) { this.denyChannel = denyChannel }
    public func evaluate(_: ToolInvocationContext, plan: NormalizedOperationPlan): PolicyDecision {
        PolicyDecision(if (denyChannel && plan.toolName == HOST_CHANNEL_WRITE_TOOL) {
            PermissionRequirement.Deny
        } else { PermissionRequirement.Confirm }, reason: "channel preparation fixture policy")
    }
}

func runChannelParentIntentPreparationContract(): Unit {
    channelParentIntentPreparationFor(false)
    channelParentIntentPreparationFor(true)
    println("Channel ParentIntent preparation contract passed: Direct and Committed, exact bytes and policy fences")
}

func channelPreparationPending(result: Result<ToolPreparation>): PreparedToolInvocation {
    match (result) {
        case Result.Ok(ToolPreparation.NeedsApproval(value, _)) => value
        case Result.Ok(ToolPreparation.Completed(value)) =>
            throw IllegalStateException("channel fixture expected approval, completed: " + stringifyUnifiedJson(value.output))
        case Result.Ok(ToolPreparation.Denied(value)) =>
            throw IllegalStateException("channel fixture expected approval, denied: " + value.reason.describe())
        case Result.Ok(ToolPreparation.Ready(_)) =>
            throw IllegalStateException("channel fixture expected approval, unexpectedly ready")
        case Result.Err(error) => throw IllegalStateException(error.describe())
    }
}

func channelParentIntentPreparationFor(committed: Bool): Unit {
    let label = if (committed) { "Committed channel" } else { "Direct channel" }
    let catalog = ToolCatalog()
    let observed = SourceObservingExecutor()
    let canonicalizer = ChannelPreparationCanonicalizer()
    let process = Capability(CapabilityKind.ProcessSpawn)
    let invoke = Capability(CapabilityKind.ExtensionInvoke)
    let read = Capability(CapabilityKind.WorkspaceRead, resource: "/workspace")
    let rootName = "plugin.axyndra:channel-prepare.echo"
    catalog.register(ToolDescriptor(ModelToolDefinition(rootName, "frozen channel root", objectValue([])),
        process, additionalCapabilities: [invoke, read], sideEffecting: true, neverReplay: true,
        implementationVersion: "1.0.0", implementationFingerprint: "owned-v1:" + CHANNEL_PREPARATION_DIGEST,
        canonicalArgumentsResolver: Some({ context, call => canonicalizer.prepare(context, call) })), observed).value().getOrThrow()
    catalog.register(ToolDescriptor(ModelToolDefinition(HOST_CHANNEL_WRITE_TOOL, "internal exact channel write", objectValue([])),
        process, additionalCapabilities: [invoke, read], sideEffecting: true, neverReplay: true, hostServiceOnly: true,
        implementationFingerprint: HOST_CHANNEL_WRITE_FINGERPRINT), observed).value().getOrThrow()
    register(catalog, "run_program", CapabilityKind.WorkspaceRead, false)
    register(catalog, "channel_plain_read", CapabilityKind.WorkspaceRead, false)
    let caps = CapabilitySet(values: [process, invoke, Capability(CapabilityKind.WorkspaceRead)])
    let snapshot = catalog.toolSetSnapshot("channel-preparation-tools", caps)
    expect(catalog.definitions().size == 3 && snapshot.entries.size == 3 && catalog.definitionsFor(caps).size == 3,
        label + " internal channel write is absent from every public tool view")
    let context = ToolInvocationContext(RunId("channel-preparation-run"), SessionId("channel-preparation-thread"),
        caps, epoch: 1, toolSetSnapshot: Some(snapshot), toolContext: ToolContextDescriptor(workspaceRoot: "/workspace"))
    let coordinator = ThreadCoordinator(ThreadId(context.sessionId.value), "/workspace", InMemoryThreadCommitSink())
    let runtime = AgentThreadRuntime(coordinator, ContextProjector("channel-prepare", SourceEstimator()), { => 10 })
    let lane = ModelLane(ModelLaneRole.Main, "provider", "model", "responses", ModelLaneCapabilitiesSnapshot(),
        1000, 100, 20, "estimator", "retry", "cache", snapshot, "system")
    runtime.startTurn(SemanticTurnId("http-prepare-turn"), context.runId, ItemId("channel-prepare-user"),
        ThreadItemContent.UserMessage(textMessageParts("channel prepare")), lane, InvocationContextProjection()).value().getOrThrow()
    let operations = MemoryOperations()
    let audit = MemoryAudit()
    let pipeline = ToolPipeline(catalog, operations, audit, FixedIds(), policy: ChannelPreparationPolicy())
    let rootCall = ToolCall("channel-root-call", rootName, channelPreparationInput())
    let pending: PreparedToolInvocation
    if (committed) {
        let reference = httpPreparationCommitted(coordinator, context, 1, "channel-root", rootCall)
        pending = channelPreparationPending(pipeline.prepareCommitted(context, reference))
        operations.prepare(pending.operationId, context.runId, reference, pending.operationPlan).value().getOrThrow()
    } else {
        let unsealed = channelPreparationPending(pipeline.prepare(context, rootCall))
        let item = ItemId("channel-prepare-root-item")
        expect(match (runtime.commitResult(ResultEnvelope(ThreadId(context.sessionId.value), SemanticTurnId("http-prepare-turn"),
            context.runId, context.epoch, 1, ThreadItemDraft(item, ThreadItemContent.ToolCall(
                CanonicalToolCallId(rootCall.callId), rootCall.name, rootCall.arguments),
                ItemProvenance("direct_tool", runId: Some(context.runId), operationId: Some(unsealed.operationId)))))) {
            case SemanticCommitDecision.Committed(_, _) => true
            case _ => false
        }, "channel Direct preparation commits its actual operation-bound canonical Item")
        let reference = runtime.attestDirectToolCall(item, unsealed.operationId, context.runId, context.epoch).value().getOrThrow()
        pending = pipeline.bindDirectRoot(context, unsealed, reference).value().getOrThrow()
        operations.prepareTrustedControlOperation(pending.operationId, context.runId, item, pending.operationPlan).value().getOrThrow()
    }
    expect(isFrozenChannelParentPlan(pending.operationPlan) && pending.authorization == PreparedAuthorization.ApprovalRequired &&
        canonicalAgentValue(pending.call.arguments) == canonicalAgentValue(rootCall.arguments),
        label + " freezes a valid channel envelope while retaining original input")
    let childArgs = channelServiceChildArguments(pending.operationPlan.canonicalArguments, "write-1").value().getOrThrow()
    let childCall = ToolCall("channel-child-call", HOST_CHANNEL_WRITE_TOOL, childArgs)
    let key = "channel-service:" + rootCall.callId + ":write-1"
    expect(sourceNotFound(pipeline.prepareDerived(context, childCall, pending,
        "javascript-service:" + rootCall.callId + ":write-1")),
        label + " JavaScript service keys cannot resolve the channel-only hidden port")
    expect(channelPreparationPending(pipeline.prepareDerived(context, childCall, pending, key)).authorization == PreparedAuthorization.ApprovalRequired,
        label + " a parent still awaiting approval cannot authorize child bytes")
    for (change in ["bytes", "lease_id", "directory_revision", "directory_digest", "implementation_version", "implementation_fingerprint"]) {
        canonicalizer.changed = change
        expect(match (pipeline.authorize(context, pending, ApprovalDecision.Approve, decisionSource: ApprovalDecisionSource.User)) {
            case Result.Err(error) => error.code == "tool.approval_context_changed"
            case _ => false
        }, label + " changed " + change + " invalidates the pending approval before any grant")
    }
    canonicalizer.changed = ""
    let approved = match (pipeline.authorize(context, pending, ApprovalDecision.Approve, decisionSource: ApprovalDecisionSource.User)) {
        case Result.Ok(ToolAuthorization.Ready(value)) => value
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("channel root approval did not return Ready")
    }
    let auditBefore = audit.events.size
    let child = sourceReady(pipeline.prepareDerived(context, childCall, approved, key))
    expect(child.authorization == PreparedAuthorization.ParentIntent && child.approval.isNone() &&
        child.source.kind == PreparedInvocationSourceKind.Derived && audit.events.size == auditBefore &&
        child.source.parentOperationId.getOrThrow().value == approved.operationId.value &&
        child.operationPlan.effectClass == OperationEffectClass.ExternalMutation &&
        child.operationPlan.retryDisposition == OperationRetryDisposition.Never &&
        (match (child.operationPlan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }),
        label + " exact frozen bytes narrow Confirm to ParentIntent without fake approval or replay")
    expect(match (pipeline.authorize(context, child, ApprovalDecision.Approve)) {
        case Result.Err(error) => error.code == "tool.approval_not_required"
        case _ => false
    }, label + " ParentIntent cannot be relabeled as User approval")
    let denying = ToolPipeline(catalog, operations, MemoryAudit(), FixedIds(), policy: ChannelPreparationPolicy(denyChannel: true))
    expect(httpPreparationDenied(denying.prepareDerived(context, childCall, approved, key)), label + " parent cannot override explicit Deny")
    for (lowCaps in [CapabilitySet(values: [invoke, read]), CapabilitySet(values: [process, read]),
        CapabilitySet(values: [process, invoke])]) {
        let reduced = ToolInvocationContext(context.runId, context.sessionId, lowCaps, epoch: 1,
            toolSetSnapshot: Some(snapshot), toolContext: ToolContextDescriptor(workspaceRoot: "/workspace"))
        expect(httpPreparationDenied(pipeline.prepareDerived(reduced, childCall, approved, key)),
            label + " parent cannot replace missing process, invocation or workspace authority")
    }
    for (change in ["bytes", "lease_id", "directory_revision", "directory_digest", "implementation_version", "implementation_fingerprint", "target_thread_id"]) {
        let changed = parseUnifiedJson(stringifyUnifiedJson(childArgs))
        channelPreparationChange(changed.field("binding").getOrThrow(), changed.field("intent").getOrThrow(), change)
        expect(channelPreparationPending(pipeline.prepareDerived(context, ToolCall("changed-channel", HOST_CHANNEL_WRITE_TOOL, changed), approved, key))
            .authorization == PreparedAuthorization.ApprovalRequired,
            label + " changed child " + change + " receives no parent authorization")
    }
    expect(channelPreparationPending(pipeline.prepareDerived(context, childCall, approved, key + "-retry"))
        .authorization == PreparedAuthorization.ApprovalRequired, label + " fresh transport ID does not replay an intent")
    let otherThread = ToolInvocationContext(context.runId, SessionId("other-thread"), caps, epoch: 1,
        toolSetSnapshot: Some(snapshot), toolContext: ToolContextDescriptor(workspaceRoot: "/workspace"))
    expect(pipeline.prepareDerived(otherThread, childCall, approved, key).isError() &&
        pipeline.admitDerived(otherThread, child).isError() && !operations.loadPlan(child.operationId, context.runId).isOk(),
        label + " mismatched target Thread cannot reach preparation or admission")
    expect(sourceNotFound(pipeline.prepare(context, childCall)), label + " raw direct cannot discover host-only channel port")
    let trusted = ToolInvocationContext(context.runId, context.sessionId, caps, epoch: 1, trustedControl: true)
    expect(sourceNotFound(pipeline.prepare(trusted, childCall)), label + " trusted control is not a channel lease")
    let guessed = httpPreparationCommitted(coordinator, context, 2, "channel-guess", childCall)
    expect(sourceNotFound(pipeline.prepareCommitted(context, guessed)), label + " model commitment does not expose hidden channel")
    let program = channelPreparationPending(pipeline.prepareCommitted(context, httpPreparationCommitted(coordinator, context, 3,
        "channel-program", ToolCall("channel-program", "run_program", objectValue([])))))
    expect(sourceNotFound(pipeline.prepareDerived(context, childCall, program, "channel-service:channel-program:write-1")),
        label + " Program cannot guess the hidden channel service")
    let ordinary = channelPreparationPending(pipeline.prepareDerived(context, ToolCall("plain-child", "channel_plain_read", objectValue([])),
        approved, "channel-service:channel-root-call:plain"))
    expect(ordinary.authorization == PreparedAuthorization.ApprovalRequired && ordinary.operationPlan.effectClass == OperationEffectClass.ReadOnly,
        label + " channel parent does not grant unrelated ordinary read-only children")
    // InMemoryOperations is intentionally not an adapter for durable startup
    // proof. This suite stops at policy preparation; Store tests own that proof.
    expect(!pipeline.executePrepared(context, child).isOk() && observed.calls == 0 && canonicalizer.calls >= 8,
        label + " every preparation and approval check remains before byte IO or durable admission")
}
