package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Data only. Live steering/cancellation/host participants are not request data;
// the caller supplies its interaction source when it restores this snapshot.
// Freeze the actual JSON before deriving any identity or reconstructing types.
public func coreContextBoundaryRequestValue(request: AgentRunRequest): AgentValue {
    let frozen = contextBoundaryRequestFreeze(contextBoundaryRequestSnapshot(request))
    let _ = coreContextBoundaryRequestFromValue(frozen)
    frozen
}

public func coreContextBoundaryRequestFromValue(
    value: AgentValue,
    interactions!: ?AgentInteractionSource = None,
    ownedEvents!: ?OwnedAgentEventSink = None<OwnedAgentEventSink>,
    callerCancellation180!: ?CancellationToken = None<CancellationToken>
): AgentRunRequest {
    let frozen = contextBoundaryRequestFreeze(value)
    contextBoundaryRequestFields(frozen, ["schema", "run_id", "thread_id", "lane_id", "model_input",
        "requested_policy", "model_capabilities", "resolver_version", "capabilities", "budget",
        "pricing", "approval_mode", "auto_retry", "tool_context", "context_snapshot", "initialize_context",
        "context_window", "provider_margin"])
    contextBoundaryRequestRequire(requiredCoreTextField(frozen, "schema") ==
        "axyndra.core-context-boundary-request/v1", "unsupported schema")
    let budget = contextBoundaryRequestBudgetFromValue(requiredCoreValueField(frozen, "budget"))
    let policy = requiredCoreValueField(frozen, "requested_policy")
    contextBoundaryRequestFields(policy, ["policy_requested_thinking", "user_requested_thinking",
        "thinking_source", "request_output_budget"])
    let requestedOutput = contextBoundaryRequestOutputFromValue(requiredCoreValueField(policy, "request_output_budget"))
    contextBoundaryRequestRequire(requestedOutput.hardLimit == budget.maxOutputTokens &&
        requestedOutput.minVisibleResponseTokens == budget.requestOutputBudget.minVisibleResponseTokens,
        "requested output policy differs from budget")
    let modelValue = requiredCoreValueField(frozen, "model_input")
    contextBoundaryRequestModelFields(modelValue)
    let model = match (modelRequestFromSnapshotValue(modelValue, "")) {
        case Result.Ok(decoded) => decoded
        case Result.Err(error) => throw IllegalArgumentException(error.message)
    }
    let thinking = thinkingLevelFromName(requiredCoreTextField(policy, "policy_requested_thinking"))
    contextBoundaryRequestRequire(model.thinking == thinking && model.wireMaxOutputTokens == budget.maxOutputTokens,
        "model input differs from requested policy")
    contextBoundaryRequestRequire(model.messages.size == 1 && model.messages[0].role == ModelRole.User &&
        !model.messages[0].blocks.isEmpty() && model.messages[0].blocks[0].kind == ModelBlockKind.Text,
        "model input must contain the original user prompt")
    contextBoundaryRequestRequire(model.tools.isEmpty() && model.resolvedPolicy.isNone() &&
        (match (model.toolChoice) { case ModelToolChoice.Auto => true; case _ => false }) && model.streaming, "model input has non-request execution state")
    let blocks = model.messages[0].blocks
    let images = ArrayList<ModelImage>()
    for (index in 1..blocks.size) {
        contextBoundaryRequestRequire(blocks[index].kind == ModelBlockKind.Image && blocks[index].image.isSome(),
            "model input contains a non-image prompt attachment")
        images.add(blocks[index].image.getOrThrow())
    }
    let capabilities = ArrayList<Capability>()
    for (raw in requiredCoreListField(frozen, "capabilities")) {
        contextBoundaryRequestFields(raw, ["kind", "resource"])
        capabilities.add(Capability(contextBoundaryRequestCapabilityFromName(requiredCoreTextField(raw, "kind")),
            resource: requiredCoreTextField(raw, "resource")))
    }
    let approvalName = requiredCoreTextField(frozen, "approval_mode")
    contextBoundaryRequestRequire(approvalName == "" || approvalName == "always_ask" ||
        approvalName == "write" || approvalName == "yolo", "unknown approval mode")
    let toolValue = requiredCoreValueField(frozen, "tool_context")
    contextBoundaryRequestToolFields(toolValue)
    let request = AgentRunRequest(RunId(requiredCoreTextField(frozen, "run_id")),
        SessionId(requiredCoreTextField(frozen, "thread_id")), model.model, blocks[0].text,
        system: model.system, thinking: thinking,
        userRequestedThinking: optionalCoreThinkingField(policy, "user_requested_thinking"),
        thinkingSource: thinkingPreferenceSourceFromName(requiredCoreTextField(policy, "thinking_source")),
        modelCapabilitiesSnapshot: Some(contextBoundaryRequestCapsFromValue(requiredCoreValueField(frozen, "model_capabilities"))),
        resolverVersion: contextBoundaryRequestUInt32(frozen, "resolver_version"),
        capabilities: CapabilitySet(values: capabilities.toArray()), budget: budget, interactions: interactions,
        approvalModeOverride: approvalModeFromName(approvalName), autoRetry: requiredCoreBoolField(frozen, "auto_retry"),
        callerCancellation180: callerCancellation180,
        serviceTier: model.serviceTier, pricing: contextBoundaryRequestPricingFromValue(requiredCoreValueField(frozen, "pricing")),
        imageInputs: images.toArray(), structuredOutput: model.structuredOutput,
        cachePolicy: model.cachePolicy, cacheKey: model.cacheKey, parallelToolCalls: model.parallelToolCalls,
        toolContext: toolContextDescriptorFromValue(toolValue),
        contextSnapshot: contextSnapshotFromValue(requiredCoreValueField(frozen, "context_snapshot")),
        contextWindow: contextBoundaryRequestInteger(frozen, "context_window"),
        providerSafetyMargin: contextBoundaryRequestInteger(frozen, "provider_margin"),
        executionLaneId: LaneId(requiredCoreTextField(frozen, "lane_id")),
        initializeContext: requiredCoreBoolField(frozen, "initialize_context"), ownedEvents: ownedEvents)
    // Also rejects constructor normalization, ignored fields, duplicate semantic
    // descriptors, or model blocks not expressible by an AgentRunRequest.
    let encoded = contextBoundaryRequestFreeze(contextBoundaryRequestSnapshot(request))
    contextBoundaryRequestRequire(canonicalAgentValue(encoded) == canonicalAgentValue(frozen),
        "request snapshot does not round-trip exactly")
    request
}

func contextBoundaryRequestSnapshot(request: AgentRunRequest): AgentValue {
    let blocks = ArrayList<ModelBlock>()
    blocks.add(ModelBlock(ModelBlockKind.Text, text: request.prompt))
    for (image in request.imageInputs) { blocks.add(ModelBlock(ModelBlockKind.Image, image: Some(image))) }
    let policy = request.requestedPolicy
    objectValue([
        ValueField("schema", textValue("axyndra.core-context-boundary-request/v1")),
        ValueField("run_id", textValue(request.runId.value)), ValueField("thread_id", textValue(request.sessionId.value)),
        ValueField("lane_id", textValue(request.executionLaneId.value)),
        ValueField("model_input", modelRequestSnapshotValue(ModelRequest(request.model,
            [ModelMessage(ModelRole.User, blocks.toArray())], system: request.system, thinking: request.thinking,
            maxOutputTokens: request.budget.maxOutputTokens, streaming: true, parallelToolCalls: request.parallelToolCalls,
            serviceTier: request.serviceTier, cachePolicy: request.cachePolicy,
            structuredOutput: request.structuredOutput, cacheKey: request.cacheKey))),
        ValueField("requested_policy", objectValue([
            ValueField("policy_requested_thinking", textValue(thinkingLevelName(policy.policyRequestedThinking))),
            ValueField("user_requested_thinking", match (policy.userRequestedThinking) {
                case Some(level) => textValue(thinkingLevelName(level)); case None => nullValue() }),
            ValueField("thinking_source", textValue(thinkingPreferenceSourceName(policy.thinkingSource))),
            ValueField("request_output_budget", contextBoundaryRequestOutputValue(policy.requestOutputBudget))])),
        ValueField("model_capabilities", contextBoundaryRequestCapsValue(request.modelCapabilitiesSnapshot)),
        ValueField("resolver_version", integerValue(Int64(request.resolverVersion))),
        ValueField("capabilities", listValue(request.capabilities.values.map { c => objectValue([
            ValueField("kind", textValue(capabilityDisplayName(c.kind))), ValueField("resource", textValue(c.resource))]) })),
        ValueField("budget", contextBoundaryRequestBudgetValue(request.budget)),
        ValueField("pricing", contextBoundaryRequestPricingValue(request.pricing)),
        ValueField("approval_mode", textValue(approvalModeName(request.approvalModeOverride))),
        ValueField("auto_retry", boolValue(request.autoRetry)),
        ValueField("tool_context", toolContextDescriptorValue(request.toolContext)),
        ValueField("context_snapshot", contextSnapshotValue(request.contextSnapshot)),
        ValueField("initialize_context", boolValue(request.initializeContext)),
        ValueField("context_window", integerValue(request.contextWindow)),
        ValueField("provider_margin", integerValue(request.providerSafetyMargin))])
}

func contextBoundaryRequestCapsValue(caps: ModelExecutionCapabilitiesSnapshot): AgentValue {
    objectValue([
        ValueField("schema_version", integerValue(Int64(caps.snapshotSchemaVersion))),
        ValueField("model_id", textValue(caps.modelId)),
        ValueField("thinking", objectValue([
            ValueField("mode", textValue(thinkingControlModeName(caps.thinking.mode))),
            ValueField("supported_levels", listValue(caps.thinking.supportedLevels.map { level => textValue(thinkingLevelName(level)) })),
            ValueField("budget_tiers", listValue(caps.thinking.budgetTiers.map { tier => objectValue([
                ValueField("level", textValue(thinkingLevelName(tier.level))), ValueField("budget_tokens", integerValue(tier.budgetTokens))]) }))])),
        ValueField("model_max_output_tokens", integerValue(caps.modelMaxOutputTokens)),
        ValueField("endpoint_max_output_tokens", contextBoundaryRequestOptionalInt(caps.endpointMaxOutputTokens)),
        ValueField("capability_fingerprint", textValue(caps.capabilityFingerprint)),
        ValueField("configuration_digest", textValue(caps.configurationDigest))])
}

func contextBoundaryRequestCapsFromValue(value: AgentValue): ModelExecutionCapabilitiesSnapshot {
    contextBoundaryRequestFields(value, ["schema_version", "model_id", "thinking", "model_max_output_tokens",
        "endpoint_max_output_tokens", "capability_fingerprint", "configuration_digest"])
    let raw = requiredCoreValueField(value, "thinking")
    contextBoundaryRequestFields(raw, ["mode", "supported_levels", "budget_tiers"])
    let levels = ArrayList<ThinkingLevel>()
    for (item in requiredCoreListField(raw, "supported_levels")) {
        contextBoundaryRequestRequire(item.unifiedKind == ValueKind.Text, "supported thinking level must be text")
        levels.add(thinkingLevelFromName(item.text))
    }
    let tiers = ArrayList<ThinkingBudgetTier>()
    for (item in requiredCoreListField(raw, "budget_tiers")) {
        contextBoundaryRequestFields(item, ["level", "budget_tokens"])
        tiers.add(ThinkingBudgetTier(thinkingLevelFromName(requiredCoreTextField(item, "level")),
            contextBoundaryRequestInteger(item, "budget_tokens")))
    }
    let mode = thinkingControlModeFromName(requiredCoreTextField(raw, "mode"))
    // Toggle exposes canonical levels, but its constructor accepts no levels.
    // The complete round-trip comparison verifies those exposed values exactly.
    let thinking = if (mode == ThinkingControlMode.Toggle) {
        contextBoundaryRequestRequire(tiers.isEmpty(), "toggle thinking has numeric tiers")
        ThinkingCapabilities(mode)
    } else { ThinkingCapabilities(mode, supportedLevels: levels.toArray(), budgetTiers: tiers.toArray()) }
    ModelExecutionCapabilitiesSnapshot(requiredCoreTextField(value, "model_id"), thinking,
        contextBoundaryRequestInteger(value, "model_max_output_tokens"),
        endpointMaxOutputTokens: contextBoundaryRequestOptionalInteger(value, "endpoint_max_output_tokens"),
        capabilityFingerprint: requiredCoreTextField(value, "capability_fingerprint"),
        configurationDigest: requiredCoreTextField(value, "configuration_digest"),
        snapshotSchemaVersion: contextBoundaryRequestUInt32(value, "schema_version"))
}

func contextBoundaryRequestOutputValue(value: RequestOutputBudget): AgentValue {
    objectValue([ValueField("hard_limit", integerValue(value.hardLimit)),
        ValueField("min_visible_response_tokens", integerValue(value.minVisibleResponseTokens))])
}

func contextBoundaryRequestOutputFromValue(value: AgentValue): RequestOutputBudget {
    contextBoundaryRequestFields(value, ["hard_limit", "min_visible_response_tokens"])
    RequestOutputBudget(contextBoundaryRequestInteger(value, "hard_limit"),
        minVisibleResponseTokens: contextBoundaryRequestInteger(value, "min_visible_response_tokens"))
}

func contextBoundaryRequestBudgetValue(b: ResourceBudget): AgentValue {
    objectValue([
        ValueField("max_input_tokens", integerValue(b.maxInputTokens)),
        ValueField("max_output_tokens", integerValue(b.maxOutputTokens)),
        ValueField("request_output_budget", contextBoundaryRequestOutputValue(b.requestOutputBudget)),
        ValueField("max_total_input_tokens", integerValue(b.maxTotalInputTokens)),
        ValueField("max_total_output_tokens", integerValue(b.maxTotalOutputTokens)),
        ValueField("max_model_requests", integerValue(b.maxModelRequests)), ValueField("max_turns", integerValue(b.maxTurns)),
        ValueField("max_drain_model_requests", integerValue(b.maxDrainModelRequests)),
        ValueField("max_drain_turns", integerValue(b.maxDrainTurns)), ValueField("max_tool_calls", integerValue(b.maxToolCalls)),
        ValueField("max_wall_millis", integerValue(b.maxWallMillis)), ValueField("max_idle_millis", integerValue(b.maxIdleMillis)),
        ValueField("max_children", integerValue(b.maxChildren)), ValueField("max_depth", integerValue(b.maxDepth)),
        ValueField("max_concurrent_children", integerValue(b.maxConcurrentChildren)),
        ValueField("max_context_messages", integerValue(b.maxContextMessages)),
        ValueField("max_concurrent_tools", integerValue(b.maxConcurrentTools)), ValueField("max_cost_micros", integerValue(b.maxCostMicros)),
        ValueField("deadline_millis", integerValue(b.deadlineMillis)),
        ValueField("process_limits", objectValue([
            ValueField("max_output_bytes", integerValue(b.processLimits.maxOutputBytes)),
            ValueField("address_space_bytes", integerValue(b.processLimits.addressSpaceBytes)),
            ValueField("file_size_bytes", integerValue(b.processLimits.fileSizeBytes)), ValueField("open_files", integerValue(b.processLimits.openFiles)),
            ValueField("processes", integerValue(b.processLimits.processes)), ValueField("cpu_seconds", integerValue(b.processLimits.cpuSeconds))]))])
}

func contextBoundaryRequestBudgetFromValue(value: AgentValue): ResourceBudget {
    contextBoundaryRequestFields(value, ["max_input_tokens", "max_output_tokens", "request_output_budget",
        "max_total_input_tokens", "max_total_output_tokens", "max_model_requests", "max_turns",
        "max_drain_model_requests", "max_drain_turns", "max_tool_calls", "max_wall_millis", "max_idle_millis",
        "max_children", "max_depth", "max_concurrent_children", "max_context_messages", "max_concurrent_tools",
        "max_cost_micros", "deadline_millis", "process_limits"])
    let output = contextBoundaryRequestOutputFromValue(requiredCoreValueField(value, "request_output_budget"))
    contextBoundaryRequestRequire(output.hardLimit == contextBoundaryRequestInteger(value, "max_output_tokens"),
        "output budget alias differs from hard limit")
    let process = requiredCoreValueField(value, "process_limits")
    contextBoundaryRequestFields(process, ["max_output_bytes", "address_space_bytes", "file_size_bytes", "open_files", "processes", "cpu_seconds"])
    ResourceBudget(maxInputTokens: contextBoundaryRequestInteger(value, "max_input_tokens"),
        maxOutputTokens: output.hardLimit, requestOutputBudget: Some(output),
        maxTotalInputTokens: contextBoundaryRequestInteger(value, "max_total_input_tokens"),
        maxTotalOutputTokens: contextBoundaryRequestInteger(value, "max_total_output_tokens"),
        maxModelRequests: contextBoundaryRequestInteger(value, "max_model_requests"), maxTurns: contextBoundaryRequestInteger(value, "max_turns"),
        maxDrainModelRequests: contextBoundaryRequestInteger(value, "max_drain_model_requests"),
        maxDrainTurns: contextBoundaryRequestInteger(value, "max_drain_turns"), maxToolCalls: contextBoundaryRequestInteger(value, "max_tool_calls"),
        maxWallMillis: contextBoundaryRequestInteger(value, "max_wall_millis"), maxIdleMillis: contextBoundaryRequestInteger(value, "max_idle_millis"),
        maxChildren: contextBoundaryRequestInteger(value, "max_children"), maxDepth: contextBoundaryRequestInteger(value, "max_depth"),
        maxConcurrentChildren: contextBoundaryRequestInteger(value, "max_concurrent_children"),
        maxContextMessages: contextBoundaryRequestInteger(value, "max_context_messages"),
        maxConcurrentTools: contextBoundaryRequestInteger(value, "max_concurrent_tools"), maxCostMicros: contextBoundaryRequestInteger(value, "max_cost_micros"),
        deadlineMillis: contextBoundaryRequestInteger(value, "deadline_millis"),
        processLimits: ExecutionResourceLimits(maxOutputBytes: contextBoundaryRequestInteger(process, "max_output_bytes"),
            addressSpaceBytes: contextBoundaryRequestInteger(process, "address_space_bytes"),
            fileSizeBytes: contextBoundaryRequestInteger(process, "file_size_bytes"), openFiles: contextBoundaryRequestInteger(process, "open_files"),
            processes: contextBoundaryRequestInteger(process, "processes"), cpuSeconds: contextBoundaryRequestInteger(process, "cpu_seconds")))
}

func contextBoundaryRequestPricingValue(value: ?ModelPricing): AgentValue {
    match (value) {
        case None => nullValue()
        case Some(p) => objectValue([
            ValueField("input", contextBoundaryRequestOptionalInt(p.inputMicrosPerMillion)),
            ValueField("output", contextBoundaryRequestOptionalInt(p.outputMicrosPerMillion)),
            ValueField("cache_read", contextBoundaryRequestOptionalInt(p.cacheReadMicrosPerMillion)),
            ValueField("cache_write", contextBoundaryRequestOptionalInt(p.cacheWriteMicrosPerMillion))])
    }
}

func contextBoundaryRequestPricingFromValue(value: AgentValue): ?ModelPricing {
    if (value.unifiedKind == ValueKind.Null) { return None }
    contextBoundaryRequestFields(value, ["input", "output", "cache_read", "cache_write"])
    Some(ModelPricing(inputMicrosPerMillion: contextBoundaryRequestOptionalInteger(value, "input"),
        outputMicrosPerMillion: contextBoundaryRequestOptionalInteger(value, "output"),
        cacheReadMicrosPerMillion: contextBoundaryRequestOptionalInteger(value, "cache_read"),
        cacheWriteMicrosPerMillion: contextBoundaryRequestOptionalInteger(value, "cache_write")))
}

func contextBoundaryRequestModelFields(value: AgentValue): Unit {
    contextBoundaryRequestFields(value, ["model", "system", "messages", "tools", "thinking", "wire_max_output_tokens",
        "streaming", "parallel_tool_calls", "service_tier", "cache_policy", "cache_key", "tool_choice", "structured_output", "resolved_policy"])
    let _ = contextBoundaryRequestInteger(value, "wire_max_output_tokens")
    for (message in requiredCoreListField(value, "messages")) {
        contextBoundaryRequestFields(message, ["role", "blocks"])
        for (block in requiredCoreListField(message, "blocks")) {
            contextBoundaryRequestFields(block, ["kind", "text", "call_id", "name", "arguments", "is_error", "receipt_id", "image", "opaque_state"])
            let image = requiredCoreValueField(block, "image")
            if (image.unifiedKind != ValueKind.Null) {
                contextBoundaryRequestFields(image, ["source", "data", "media_type", "detail"])
            }
            contextBoundaryRequestRequire(requiredCoreValueField(block, "opaque_state").unifiedKind == ValueKind.Null,
                "request prompt must not contain provider execution state")
        }
    }
    contextBoundaryRequestRequire(requiredCoreListField(value, "tools").isEmpty(), "request snapshot cannot contain a tool lane")
    contextBoundaryRequestRequire(requiredCoreValueField(value, "resolved_policy").unifiedKind == ValueKind.Null,
        "request snapshot cannot contain an Attempt policy")
    let structured = requiredCoreValueField(value, "structured_output")
    if (structured.unifiedKind != ValueKind.Null) {
        contextBoundaryRequestFields(structured, ["name", "description", "schema", "strict"])
    }
}

func contextBoundaryRequestToolFields(value: AgentValue): Unit {
    if (value.field("execution_settings").isSome()) {
        contextBoundaryRequestFields(value, ["workspace_root", "cwd", "environment", "services", "execution_settings"])
    } else { contextBoundaryRequestFields(value, ["workspace_root", "cwd", "environment", "services"]) }
    for (entry in requiredCoreListField(value, "environment")) { contextBoundaryRequestFields(entry, ["name", "value"]) }
    for (entry in requiredCoreListField(value, "services")) { contextBoundaryRequestFields(entry, ["kind", "name", "version"]) }
}

func contextBoundaryRequestCapabilityFromName(value: String): CapabilityKind {
    match (value) {
        case "workspace.read" => CapabilityKind.WorkspaceRead
        case "workspace.write" => CapabilityKind.WorkspaceWrite
        case "process.spawn" => CapabilityKind.ProcessSpawn
        case "network.access" => CapabilityKind.NetworkAccess
        case "peer.message" => CapabilityKind.PeerMessage
        case "delegate" => CapabilityKind.Delegate
        case "extension.invoke" => CapabilityKind.ExtensionInvoke
        case _ => throw IllegalArgumentException("context request has an unknown capability")
    }
}

func contextBoundaryRequestRequire(condition: Bool, message: String): Unit {
    if (!condition) { throw IllegalArgumentException("context request: " + message) }
}

func contextBoundaryRequestFields(value: AgentValue, names: Array<String>): Unit {
    contextBoundaryRequestRequire(value.unifiedKind == ValueKind.Object && value.fields.size == names.size,
        "field shape is invalid")
    for (name in names) { contextBoundaryRequestRequire(value.field(name).isSome(), "field is missing: " + name) }
}

func contextBoundaryRequestInteger(value: AgentValue, name: String): Int64 {
    let number = requiredCoreIntegerField(value, name)
    contextBoundaryRequestRequire(requiredCoreValueField(value, name).asNumberText() == number.toString(),
        "field is not a canonical integer: " + name)
    number
}

func contextBoundaryRequestOptionalInteger(value: AgentValue, name: String): ?Int64 {
    let number = optionalCoreIntegerField(value, name)
    match (number) {
        case Some(_) => Some(contextBoundaryRequestInteger(value, name))
        case None => None
    }
}

func contextBoundaryRequestUInt32(value: AgentValue, name: String): UInt32 {
    let number = contextBoundaryRequestInteger(value, name)
    contextBoundaryRequestRequire(number >= 0 && number <= 4294967295, "field is outside UInt32 range: " + name)
    UInt32(number)
}

func contextBoundaryRequestOptionalInt(value: ?Int64): AgentValue {
    match (value) { case Some(number) => integerValue(number); case None => nullValue() }
}

func contextBoundaryRequestFreeze(value: AgentValue): AgentValue {
    let original = stringifyUnifiedJson(value)
    contextBoundaryRequestRequire(original.size <= 8388608, "original JSON exceeds 8 MiB")
    parseUnifiedJson(original, maxBytes: 8388608)
}
