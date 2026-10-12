package agent_product

import agent_host_runtime.*
import agent_core.*
import agent_runtime.*
import agent_domain.*
import tool_runtime.*
import yjson.*
import yjson_support.*

// Generic frozen child data. Role selection, prompt construction, Task/Yield
// grammar and output interpretation live in the selected Native contribution.
class ProductPluginChildRequest111 {
    let label: String
    let description: String
    let prompt: String
    let systemPrompt: String
    let modelAlias: String
    let thinking: ThinkingLevel
    let cacheKey: String
    let background: Bool
    let admissionOnly: Bool
    let ceiling: CapabilitySet
    let limits: ResourceBudget
    init(value:AgentValue,resumedThinking:ThinkingLevel) {
        workflowRequireFields(value,["prompt","system_prompt","cache_key","capability_ceiling","requested_limits"])
        prompt=workflowRoleText(value,"prompt",nonempty:true)
        systemPrompt=workflowRoleText(value,"system_prompt");cacheKey=workflowRoleText(value,"cache_key")
        // A resumed member already owns its original label/description and
        // uses the current Root model/thinking prepared by Product below.
        label="";description="";modelAlias="";thinking=resumedThinking;background=false;admissionOnly=true
        ceiling=workflowRoleCapabilities(value.field("capability_ceiling").getOrThrow())
        let requested=value.field("requested_limits").getOrThrow()
        workflowRequireFields(requested,["max_output_tokens","max_model_requests","max_turns","max_tool_calls",
            "max_wall_millis","max_idle_millis","max_children","max_depth","max_concurrent_children"])
        limits=ResourceBudget(maxOutputTokens:workflowRoleLimit(requested,"max_output_tokens"),
            maxModelRequests:workflowRoleLimit(requested,"max_model_requests"),maxTurns:workflowRoleLimit(requested,"max_turns"),
            maxToolCalls:workflowRoleLimit(requested,"max_tool_calls"),maxWallMillis:workflowRoleLimit(requested,"max_wall_millis"),
            maxIdleMillis:workflowRoleLimit(requested,"max_idle_millis"),maxChildren:workflowRoleLimit(requested,"max_children"),
            maxDepth:workflowRoleLimit(requested,"max_depth"),maxConcurrentChildren:workflowRoleLimit(requested,"max_concurrent_children"))
    }
    init(value: AgentValue) {
        if (value.field("admission_only").isSome()) {
            workflowRequireFields(value,["label","description","prompt","system_prompt","model_alias","thinking",
                "cache_key","capability_ceiling","requested_limits","background","admission_only"])
        } else { workflowRequireFields(value,["label","description","prompt","system_prompt","model_alias","thinking",
                "cache_key","capability_ceiling","requested_limits","background"]) }
        admissionOnly = match (value.field("admission_only")) { case Some(_) => workflowRoleBoolean(value,"admission_only"); case None => false }
        label = workflowRoleText(value, "label"); description = workflowRoleText(value, "description")
        prompt = workflowRoleText(value, "prompt", nonempty: true)
        systemPrompt = workflowRoleText(value, "system_prompt"); modelAlias = workflowRoleText(value, "model_alias")
        cacheKey = workflowRoleText(value, "cache_key")
        thinking = match (workflowRoleText(value, "thinking")) {
            case "off" => ThinkingLevel.Off; case "low" => ThinkingLevel.Low
            case "medium" => ThinkingLevel.Medium; case "high" => ThinkingLevel.High
            case _ => throw IllegalArgumentException("invalid frozen child thinking level") }
        background = workflowRoleBoolean(value, "background")
        ceiling = workflowRoleCapabilities(value.field("capability_ceiling").getOrThrow())
        let requested = value.field("requested_limits").getOrThrow()
        workflowRequireFields(requested, ["max_output_tokens", "max_model_requests", "max_turns", "max_tool_calls",
            "max_wall_millis", "max_idle_millis", "max_children", "max_depth", "max_concurrent_children"])
        limits = ResourceBudget(maxOutputTokens: workflowRoleLimit(requested, "max_output_tokens"),
            maxModelRequests: workflowRoleLimit(requested, "max_model_requests"), maxTurns: workflowRoleLimit(requested, "max_turns"),
            maxToolCalls: workflowRoleLimit(requested, "max_tool_calls"), maxWallMillis: workflowRoleLimit(requested, "max_wall_millis"),
            maxIdleMillis: workflowRoleLimit(requested, "max_idle_millis"), maxChildren: workflowRoleLimit(requested, "max_children"),
            maxDepth: workflowRoleLimit(requested, "max_depth"), maxConcurrentChildren: workflowRoleLimit(requested, "max_concurrent_children"))
    }
}

class ProductPluginChildBackend111 <: HostPluginChildBackend111 {
    private let tasks: ProductTaskRuntime
    init(tasks: ProductTaskRuntime) { this.tasks = tasks }
    public func start(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        tasks.startPluginChild111(context, request, admission)
    }
    public func wait(context: ToolInvocationContext, receipt: VNextOperationReceipt,
        admission: HostPluginChildAdmission111): Result<ToolResult> { tasks.waitPluginChild111(context,receipt,admission) }
    public func observeJobs165(context: ToolInvocationContext, admission: HostPluginChildAdmission111): Result<ToolResult> {
        tasks.observePluginJobs165(context, admission)
    }
    public func waitJobs166(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        tasks.waitPluginJobs166(context,request,admission)
    }
    public func cancelJobs172(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> { tasks.cancelPluginJobs172(context,request,admission) }
    public func waitPeer171(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> { tasks.waitPluginPeers171(context,request,admission) }
    public func peers(context: ToolInvocationContext, admission: HostPluginChildAdmission111): Result<ToolResult> {
        tasks.observePluginPeers111(context, admission)
    }
    public func receive(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        tasks.receivePluginPeers111(context,request,admission)
    }
    public func send(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        if(request.field("await_reply").isSome()) { tasks.sendPluginPeerReply178(context,request,admission) }
        else { tasks.sendPluginPeerMessage111(context,request,admission) }
    }
    public func observeMember(context:ToolInvocationContext,recipient:String,
        scope:HostPluginPeerPreparationSnapshot111):Result<AgentValue> {
        tasks.observePluginPeerPreparation111(context,recipient,scope)
    }
    public func readMember(context:ToolInvocationContext,request:AgentValue,
        read:HostPluginPeerReadCustody111):Result<AgentValue> {
        tasks.readPluginPeerMember111(context,request,read)
    }
    public func parentResultPersisted(context:ToolInvocationContext,result:ToolResult):Result<Unit> {
        tasks.pluginParentResultPersisted111(context,result)
    }
    public func observeResultSlot150(context: ToolInvocationContext, consume: (Bool, Int64, Bool) -> Unit): Result<Unit> {
        tasks.observePluginResultSlot150(context, consume)
    }
    public func writeResultSlot150(context: ToolInvocationContext, request: AgentValue,
        admission: HostPluginChildAdmission111): Result<ToolResult> {
        tasks.writePluginResultSlot150(context, request, admission)
    }
    public func processFacts180(meter:HostPaidValueProjection151):Result<AgentValue>{tasks.pluginProcessFacts180(meter)}
    public func observeProcessPreparation180(context:ToolInvocationContext,request:AgentValue,
        meter:HostPaidValueProjection151):Result<AgentValue>{tasks.observePluginProcessPreparation180(context,request,meter)}
    public func executeProcess180(context:ToolInvocationContext,input:AgentValue,
        admission:HostPluginChildAdmission111):Result<ToolResult>{tasks.executePluginProcess180(context,input,admission)}
    public func observeProcess197(context:ToolInvocationContext,input:AgentValue,
        admission:HostPluginChildAdmission111):Result<ToolResult>{tasks.observePluginProcess197(context,input,admission)}
    public func backgroundEnabled(): Bool { tasks.pluginBackgroundEnabled111() }
    public func cancel(parentRun: RunId): Result<Unit> { tasks.cancel(parentRun) }
}

// Holds no authorization beyond the actual hidden-child admission. Core can
// only use the exact request object created for the already reserved child.
class ProductPluginChildRestriction111 <: AgentRunStartRestriction111 {
    private let request: AgentRunRequest
    private let admission: HostPluginChildAdmission111
    private let retained: () -> Result<Unit>
    private let acknowledged: () -> Result<Unit>
    init(request: AgentRunRequest, admission: HostPluginChildAdmission111, retained: () -> Result<Unit>,
        acknowledged: () -> Result<Unit>) {
        this.request = request; this.admission = admission; this.retained = retained; this.acknowledged = acknowledged
    }
    public func admitted(value: AgentRunRequest): Result<Unit> {
        match (check(value)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        acknowledged()
    }
    public prop cancellation: CancellationToken { get() { admission.cancellation } }
    public func check(value: AgentRunRequest): Result<Unit> {
        if (!refEq(value, request)) { return taskError("child.request_changed", "child start changed its frozen actual request") }
        match (retained()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        admission.check()
    }
    public func acquire(value: AgentRunRequest): Result<ToolExecutionHandoffLease> {
        match (check(value)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        admission.acquireStartLease()
    }
}

func productPluginChildRequest111(
    base: AgentRunRequest,
    description: ProductPluginChildRequest111,
    capabilities: CapabilitySet,
    parentBudget: ExecutionBudget
): AgentRunRequest {
    let remaining = parentBudget.remainingCumulativeBudget()
    AgentRunRequest(
        base.runId,
        base.sessionId,
        base.model,
        base.prompt,
        system: description.systemPrompt,
        thinking: base.thinking,
        userRequestedThinking: base.requestedPolicy.userRequestedThinking,
        thinkingSource: base.requestedPolicy.thinkingSource,
        modelCapabilitiesSnapshot: Some(base.modelCapabilitiesSnapshot),
        resolverVersion: base.resolverVersion,
        interactions: base.interactions,
        ownedEvents: base.ownedEvents,
        capabilities: effectiveChildCapabilities(
            capabilities, description.ceiling, capabilities
        ),
        budget: ResourceBudget(
            maxInputTokens: base.budget.maxInputTokens,
            maxOutputTokens: min(description.limits.maxOutputTokens, base.budget.maxOutputTokens),
            requestOutputBudget: Some(RequestOutputBudget(min(description.limits.maxOutputTokens, base.budget.maxOutputTokens),
                minVisibleResponseTokens: base.budget.requestOutputBudget.minVisibleResponseTokens)),
            maxDrainModelRequests: base.budget.maxDrainModelRequests,
            maxDrainTurns: base.budget.maxDrainTurns,
            maxTotalInputTokens: productChildCumulativeLimit(
                base.budget.maxTotalInputTokens,
                parentBudget.maxTotalInputTokens,
                remaining.inputTokens
            ),
            maxTotalOutputTokens: productChildCumulativeLimit(
                base.budget.maxTotalOutputTokens,
                parentBudget.maxTotalOutputTokens,
                remaining.outputTokens
            ),
            maxModelRequests: min(description.limits.maxModelRequests, base.budget.maxModelRequests),
            maxTurns: min(description.limits.maxTurns, base.budget.maxTurns),
            maxToolCalls: min(description.limits.maxToolCalls, base.budget.maxToolCalls),
            maxWallMillis: productRequestedChildLimit(description.limits.maxWallMillis, base.budget.maxWallMillis),
            maxIdleMillis: min(description.limits.maxIdleMillis, base.budget.maxIdleMillis),
            maxChildren: min(description.limits.maxChildren, base.budget.maxChildren),
            maxDepth: min(description.limits.maxDepth, base.budget.maxDepth),
            maxConcurrentChildren: min(description.limits.maxConcurrentChildren, base.budget.maxConcurrentChildren),
            maxContextMessages: base.budget.maxContextMessages,
            maxConcurrentTools: base.budget.maxConcurrentTools,
            processLimits: base.budget.processLimits,
            maxCostMicros: productChildCumulativeLimit(
                base.budget.maxCostMicros,
                parentBudget.maxCostMicros,
                remaining.costMicros
            ),
            deadlineMillis: productChildDeadline(
                base.budget.deadlineMillis, parentBudget.deadlineMillis
            )
        ),
        approvalModeOverride: None<ApprovalMode>,
        autoRetry: base.autoRetry,
        serviceTier: base.serviceTier,
        pricing: base.pricing,
        imageInputs: base.imageInputs,
        structuredOutput: base.structuredOutput,
        cachePolicy: base.cachePolicy,
        cacheKey: match (base.cachePolicy) {
            case ModelCachePolicy.StablePrefix => description.cacheKey
            case ModelCachePolicy.Default => ""
        },
        parallelToolCalls: base.parallelToolCalls,
        toolContext: base.toolContext,
        contextSnapshot: base.contextSnapshot,
        initializeContext: base.initializeContext,
        contextWindow: base.contextWindow,
        providerSafetyMargin: base.providerSafetyMargin,
        executionLaneId: base.executionLaneId
    )
}

