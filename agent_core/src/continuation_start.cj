package agent_core

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import yjson_support.*

public class CoreContinuationPreparation {
    let request: AgentRunRequest
    let lane: ModelLane
    private let snapshot: AgentValue
    public let requestDigest: String
    public let launchDigest: String
    init(request: AgentRunRequest, lane: ModelLane) {
        let frozen = freezeContinuationRequest(request)
        let frozenLane = modelLaneFromSnapshotValue(parseUnifiedJson(stringifyUnifiedJson(modelLaneSnapshotValue(lane)), maxBytes: 8388608))
        let value = continuationRequestSnapshot(frozen, frozenLane)
        this.request = frozen; this.lane = frozenLane; snapshot = value
        requestDigest = modelPolicySha256Text(canonicalAgentValue(value))
        launchDigest = continuationRunLaunchDigest(modelLaneSnapshotValue(frozenLane), contextSnapshotValue(frozen.contextSnapshot), coreBudgetSnapshot(frozen.budget))
    }
    public func requestCopy(): AgentRunRequest { freezeContinuationRequest(request) }
    public func requestSnapshot(): AgentValue { parseUnifiedJson(stringifyUnifiedJson(snapshot), maxBytes: 8388608) }
}

public class AgentContinuationStart {
    let preparation: CoreContinuationPreparation
    let admission: ContinuationRunAdmission
    public init(preparation: CoreContinuationPreparation, admission: ContinuationRunAdmission) {
        let request = preparation.request; let origin = admission.origin
        if (origin.threadId != request.sessionId.value || origin.runId != request.runId.value ||
            origin.laneId != request.executionLaneId.value || origin.turnId != "turn-" + request.runId.value ||
            origin.initiatorItemId != "continuation-" + request.runId.value ||
            origin.requestDigest != preparation.requestDigest || origin.launchDigest != preparation.launchDigest) {
            throw IllegalArgumentException("continuation admission differs from its frozen Core request") }
        this.preparation = preparation; this.admission = admission
    }
}

func freezeContinuationRequest(value: AgentRunRequest): AgentRunRequest {
    let blocks = ArrayList<ModelBlock>(); blocks.add(ModelBlock(ModelBlockKind.Text, text: value.prompt))
    for (image in value.imageInputs) { blocks.add(ModelBlock(ModelBlockKind.Image, image: Some(image))) }
    let modelValue = parseUnifiedJson(stringifyUnifiedJson(modelRequestSnapshotValue(ModelRequest(value.model,
        [ModelMessage(ModelRole.User, blocks.toArray())], structuredOutput: value.structuredOutput))), maxBytes: 8388608)
    let model = modelRequestFromSnapshotValue(modelValue, "").value().getOrThrow()
    let images = ArrayList<ModelImage>()
    for (block in model.messages[0].blocks where block.kind == ModelBlockKind.Image) { images.add(block.image.getOrThrow()) }
    let caps = value.modelCapabilitiesSnapshot
    let thinking = ThinkingCapabilities(caps.thinking.mode, supportedLevels: caps.thinking.supportedLevels.clone(), budgetTiers: caps.thinking.budgetTiers.clone())
    let frozenCaps = ModelExecutionCapabilitiesSnapshot(caps.modelId, thinking, caps.modelMaxOutputTokens,
        endpointMaxOutputTokens: caps.endpointMaxOutputTokens, capabilityFingerprint: caps.capabilityFingerprint,
        configurationDigest: caps.configurationDigest, snapshotSchemaVersion: caps.snapshotSchemaVersion)
    AgentRunRequest(value.runId, value.sessionId, value.model, value.prompt, system: value.system, thinking: value.thinking,
        userRequestedThinking: value.requestedPolicy.userRequestedThinking, thinkingSource: value.requestedPolicy.thinkingSource,
        modelCapabilitiesSnapshot: Some(frozenCaps), resolverVersion: value.resolverVersion,
        capabilities: CapabilitySet(values: value.capabilities.values.clone()), budget: value.budget, interactions: value.interactions,
        approvalModeOverride: value.approvalModeOverride, autoRetry: value.autoRetry, serviceTier: value.serviceTier,
        pricing: value.pricing, imageInputs: images.toArray(), structuredOutput: model.structuredOutput,
        cachePolicy: value.cachePolicy, cacheKey: value.cacheKey, parallelToolCalls: value.parallelToolCalls,
        toolContext: toolContextDescriptorFromValue(parseUnifiedJson(stringifyUnifiedJson(toolContextDescriptorValue(value.toolContext)), maxBytes: 8388608)),
        contextSnapshot: contextSnapshotFromValue(parseUnifiedJson(stringifyUnifiedJson(contextSnapshotValue(value.contextSnapshot)), maxBytes: 8388608)),
        contextWindow: value.contextWindow, providerSafetyMargin: value.providerSafetyMargin,
        executionLaneId: value.executionLaneId, initializeContext: value.initializeContext)
}

func continuationRequestSnapshot(request: AgentRunRequest, lane: ModelLane): AgentValue {
    let blocks = ArrayList<ModelBlock>(); blocks.add(ModelBlock(ModelBlockKind.Text, text: request.prompt))
    for (image in request.imageInputs) { blocks.add(ModelBlock(ModelBlockKind.Image, image: Some(image))) }
    let caps = request.modelCapabilitiesSnapshot; let b = request.budget
    let budget = objectValue([
        ValueField("maxInputTokens", integerValue(b.maxInputTokens)),
        ValueField("maxOutputTokens", integerValue(b.maxOutputTokens)),
        ValueField("maxTotalInputTokens", integerValue(b.maxTotalInputTokens)),
        ValueField("maxTotalOutputTokens", integerValue(b.maxTotalOutputTokens)),
        ValueField("maxModelRequests", integerValue(b.maxModelRequests)),
        ValueField("maxTurns", integerValue(b.maxTurns)),
        ValueField("maxDrainModelRequests", integerValue(b.maxDrainModelRequests)),
        ValueField("maxDrainTurns", integerValue(b.maxDrainTurns)),
        ValueField("maxToolCalls", integerValue(b.maxToolCalls)),
        ValueField("maxWallMillis", integerValue(b.maxWallMillis)),
        ValueField("maxIdleMillis", integerValue(b.maxIdleMillis)),
        ValueField("maxChildren", integerValue(b.maxChildren)),
        ValueField("maxDepth", integerValue(b.maxDepth)),
        ValueField("maxConcurrentChildren", integerValue(b.maxConcurrentChildren)),
        ValueField("maxContextMessages", integerValue(b.maxContextMessages)),
        ValueField("maxConcurrentTools", integerValue(b.maxConcurrentTools)),
        ValueField("maxCostMicros", integerValue(b.maxCostMicros)),
        ValueField("deadlineMillis", integerValue(b.deadlineMillis)),
        ValueField("min_visible", integerValue(b.requestOutputBudget.minVisibleResponseTokens)),
        ValueField("process_limits", objectValue([ValueField("maxOutputBytes", integerValue(b.processLimits.maxOutputBytes)), ValueField("addressSpaceBytes", integerValue(b.processLimits.addressSpaceBytes)), ValueField("fileSizeBytes", integerValue(b.processLimits.fileSizeBytes)), ValueField("openFiles", integerValue(b.processLimits.openFiles)), ValueField("processes", integerValue(b.processLimits.processes)), ValueField("cpuSeconds", integerValue(b.processLimits.cpuSeconds))]))])
    let pricing = match (request.pricing) { case None => nullValue(); case Some(p) => objectValue([
        ValueField("input", continuationOptionalInt(p.inputMicrosPerMillion)), ValueField("output", continuationOptionalInt(p.outputMicrosPerMillion)),
        ValueField("cache_read", continuationOptionalInt(p.cacheReadMicrosPerMillion)), ValueField("cache_write", continuationOptionalInt(p.cacheWriteMicrosPerMillion))]) }
    objectValue([ValueField("schema", textValue("axyndra.host-continuation-request/v1")),
        ValueField("run_id", textValue(request.runId.value)), ValueField("thread_id", textValue(request.sessionId.value)),
        ValueField("lane_id", textValue(request.executionLaneId.value)),
        ValueField("model_input", modelRequestSnapshotValue(ModelRequest(request.model, [ModelMessage(ModelRole.User, blocks.toArray())],
            system: request.system, tools: coreModelToolDefinitions(lane.toolSet), thinking: request.thinking,
            maxOutputTokens: request.budget.maxOutputTokens, streaming: true, parallelToolCalls: request.parallelToolCalls,
            serviceTier: request.serviceTier, cachePolicy: request.cachePolicy, structuredOutput: request.structuredOutput, cacheKey: request.cacheKey))),
        ValueField("model_capabilities", textValue(canonicalModelCapabilitySnapshotPayload(caps.snapshotSchemaVersion, caps.modelId,
            caps.thinking, caps.modelMaxOutputTokens, caps.endpointMaxOutputTokens, configurationDigest: caps.configurationDigest))),
        ValueField("resolver_version", textValue(request.resolverVersion.toString())),
        ValueField("user_requested_thinking", match (request.requestedPolicy.userRequestedThinking) { case Some(level) => textValue(modelPolicyThinkingLevelName(level)); case None => nullValue() }),
        ValueField("thinking_source", textValue(match (request.requestedPolicy.thinkingSource) { case ThinkingPreferenceSource.ExplicitUser => "user"; case ThinkingPreferenceSource.ModePreference => "mode"; case ThinkingPreferenceSource.ModelDefault => "default" })),
        ValueField("budget", budget), ValueField("pricing", pricing), ValueField("auto_retry", boolValue(request.autoRetry)),
        ValueField("approval_mode", textValue(approvalModeName(request.approvalModeOverride))),
        ValueField("capabilities", listValue(request.capabilities.values.map { c => objectValue([ValueField("kind", textValue(capabilityDisplayName(c.kind))), ValueField("resource", textValue(c.resource))]) })),
        ValueField("tool_context", toolContextDescriptorValue(request.toolContext)), ValueField("context", contextSnapshotValue(request.contextSnapshot)),
        ValueField("initialize_context", boolValue(request.initializeContext)), ValueField("context_window", integerValue(request.contextWindow)),
        ValueField("provider_margin", integerValue(request.providerSafetyMargin))])
}
func continuationOptionalInt(value: ?Int64): AgentValue { match (value) { case Some(n) => integerValue(n); case None => nullValue() } }

func continuationProjectionInputs(projection: ModelContextProjection, runs: RunRepository): Result<Array<(ItemId, ModelMessage)>> {
    let result = ArrayList<(ItemId, ModelMessage)>()
    for (item in projection.recentItems where isContinuationInitiatorDescription(item) || isContinuationHistoryDescription(item)) {
        let message = match (runs.continuationModelInput(item)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        result.add((item.id, message))
    }
    Result.Ok(result.toArray())
}
