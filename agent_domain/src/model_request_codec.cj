package agent_domain

import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*

// Canonical v1 request payload extracted without changing persisted field names.
// Transport identity/deadline live in the outer typed envelope, not this semantic digest.
public func modelRequestSnapshotValue(request: ModelRequest): AgentValue {
    let messages = ArrayList<AgentValue>()
    for (message in request.messages) {
        let blocks = ArrayList<AgentValue>()
        for (block in message.blocks) {
            let fields = ArrayList<ValueField>()
            fields.add(ValueField("kind", textValue(modelInputModelBlockKindName(block.kind))))
            fields.add(ValueField("text", textValue(block.text)))
            fields.add(ValueField("call_id", textValue(block.callId)))
            fields.add(ValueField("name", textValue(block.name)))
            fields.add(ValueField("arguments", block.arguments))
            fields.add(ValueField("is_error", boolValue(block.isError)))
            fields.add(ValueField("receipt_id", textValue(block.receiptId)))
            fields.add(ValueField("image", match (block.image) {
                case Some(image) => objectValue([
                    ValueField("source", textValue(match (image.sourceKind) {
                        case ModelImageSourceKind.Url => "url"
                        case ModelImageSourceKind.Base64 => "base64"
                    })),
                    ValueField("data", textValue(image.data)),
                    ValueField("media_type", textValue(image.mediaType)),
                    ValueField("detail", textValue(match (image.detail) {
                        case ModelImageDetail.Auto => "auto"
                        case ModelImageDetail.Low => "low"
                        case ModelImageDetail.High => "high"
                    }))
                ])
                case None => nullValue()
            }))
            fields.add(ValueField("opaque_state", match (block.opaqueState) {
                case Some(state) => objectValue([
                    ValueField("provider_id", textValue(state.providerId)),
                    ValueField("protocol", textValue(state.protocol)),
                    ValueField("item_id", textValue(state.itemId)),
                    ValueField("payload", textValue(state.payload)),
                    ValueField("replay_required", boolValue(state.replayRequired))
                ])
                case None => nullValue()
            }))
            blocks.add(objectValue(fields.toArray()))
        }
        messages.add(objectValue([
            ValueField("role", textValue(match (message.role) {
                case ModelRole.User => "user"
                case ModelRole.Assistant => "assistant"
            })),
            ValueField("blocks", listValue(blocks.toArray()))
        ]))
    }
    let tools = ArrayList<AgentValue>()
    for (tool in request.tools) {
        tools.add(objectValue([
            ValueField("name", textValue(tool.name)),
            ValueField("description", textValue(tool.description)),
            ValueField("input_schema", tool.inputSchema)
        ]))
    }
    objectValue([
        ValueField("model", textValue(request.model)),
        ValueField("system", textValue(request.system)),
        ValueField("messages", listValue(messages.toArray())),
        ValueField("tools", listValue(tools.toArray())),
        ValueField("thinking", textValue(modelInputThinkingLevelName(request.thinking))),
        ValueField("wire_max_output_tokens", integerValue(request.wireMaxOutputTokens)),
        ValueField("streaming", boolValue(request.streaming)),
        ValueField("parallel_tool_calls", boolValue(request.parallelToolCalls)),
        ValueField("service_tier", textValue(request.serviceTier)),
        ValueField("cache_policy", textValue(match (request.cachePolicy) {
            case ModelCachePolicy.Default => "default"
            case ModelCachePolicy.StablePrefix => "stable_prefix"
        })),
        ValueField("cache_key", textValue(request.cacheKey)),
        ValueField("tool_choice", textValue(modelInputModelToolChoiceName(request.toolChoice))),
        ValueField("structured_output", match (request.structuredOutput) {
            case Some(value) => objectValue([
                ValueField("name", textValue(value.name)),
                ValueField("description", textValue(value.description)),
                ValueField("schema", value.schema),
                ValueField("strict", boolValue(value.strict))
            ])
            case None => nullValue()
        }),
        ValueField("resolved_policy", match (request.resolvedPolicy) {
            case Some(value) => objectValue([
                ValueField("canonical", textValue(canonicalResolvedModelRequestPolicy(value))),
                ValueField("thinking_requested", textValue(modelInputThinkingLevelName(value.thinking.requested))),
                ValueField("thinking_effective", textValue(modelInputThinkingLevelName(value.thinking.effective))),
                ValueField("thinking_mode", textValue(modelInputThinkingControlModeName(value.thinking.mode))),
                ValueField("thinking_budget_tokens", match (value.thinking.budgetTokens) {
                    case Some(tokens) => integerValue(tokens)
                    case None => nullValue()
                }),
                ValueField("adaptive_effort", match (value.thinking.adaptiveEffort) {
                    case Some(level) => textValue(modelInputThinkingLevelName(level))
                    case None => nullValue()
                }),
                ValueField("output_requested", integerValue(value.output.requestedHardLimit)),
                ValueField("output_effective", integerValue(value.output.effectiveWireLimit)),
                ValueField("policy_resolution_version", integerValue(Int64(value.policyResolutionVersion))),
                ValueField("capability_snapshot_version", integerValue(Int64(value.capabilitySnapshotVersion))),
                ValueField("capability_fingerprint", textValue(value.capabilityFingerprint)),
                ValueField("capability_snapshot_payload", textValue(value.capabilitySnapshotPayload)),
                ValueField("response_reserve", integerValue(value.minVisibleResponseTokens)),
                ValueField("thinking_source", textValue(modelInputThinkingPreferenceSourceName(value.thinkingSource))),
                ValueField("user_requested_thinking", match (value.userRequestedThinking) {
                    case Some(level) => textValue(modelInputThinkingLevelName(level))
                    case None => nullValue()
                }),
                ValueField("thinking_constraints", modelInputResolutionConstraintsValue(value.thinking.constraints)),
                ValueField("output_constraints", modelInputResolutionConstraintsValue(value.output.constraints))
            ])
            case None => nullValue()
        })
    ])
}

public func modelRequestFromSnapshotValue(
    value: AgentValue,
    requestId: String
): Result<ModelRequest> {
    try {
        let messages = ArrayList<ModelMessage>()
        for (messageValue in modelInputRequiredCoreListField(value, "messages")) {
            let blocks = ArrayList<ModelBlock>()
            for (blockValue in modelInputRequiredCoreListField(messageValue, "blocks")) {
                let image: ?ModelImage = match (blockValue.field("image")) {
                    case Some(raw) => if (raw.unifiedKind == ValueKind.Null) { None } else { Some(ModelImage(
                        match (modelInputRequiredCoreTextField(raw, "source")) {
                            case "url" => ModelImageSourceKind.Url
                            case "base64" => ModelImageSourceKind.Base64
                            case _ => throw IllegalArgumentException("unknown durable image source")
                        },
                        modelInputRequiredCoreTextField(raw, "data"),
                        mediaType: modelInputRequiredCoreTextField(raw, "media_type"),
                        detail: match (modelInputRequiredCoreTextField(raw, "detail")) {
                            case "auto" => ModelImageDetail.Auto
                            case "low" => ModelImageDetail.Low
                            case "high" => ModelImageDetail.High
                            case _ => throw IllegalArgumentException("unknown durable image detail")
                        }
                    )) }
                    case None => throw IllegalArgumentException("durable image field is missing")
                }
                let opaque: ?OpaqueProviderState = match (blockValue.field("opaque_state")) {
                    case Some(raw) => if (raw.unifiedKind == ValueKind.Null) { None } else { Some(OpaqueProviderState(
                        modelInputRequiredCoreTextField(raw, "provider_id"),
                        modelInputRequiredCoreTextField(raw, "protocol"),
                        modelInputRequiredCoreTextField(raw, "payload"),
                        itemId: modelInputRequiredCoreTextField(raw, "item_id"),
                        replayRequired: modelInputRequiredCoreBoolField(raw, "replay_required")
                    )) }
                    case None => throw IllegalArgumentException("durable opaque state field is missing")
                }
                blocks.add(ModelBlock(
                    modelInputModelBlockKindFromName(modelInputRequiredCoreTextField(blockValue, "kind")),
                    text: modelInputRequiredCoreTextField(blockValue, "text"),
                    callId: modelInputRequiredCoreTextField(blockValue, "call_id"),
                    name: modelInputRequiredCoreTextField(blockValue, "name"),
                    arguments: modelInputRequiredCoreValueField(blockValue, "arguments"),
                    isError: modelInputRequiredCoreBoolField(blockValue, "is_error"),
                    image: image,
                    receiptId: modelInputRequiredCoreTextField(blockValue, "receipt_id"),
                    opaqueState: opaque
                ))
            }
            messages.add(ModelMessage(
                match (modelInputRequiredCoreTextField(messageValue, "role")) {
                    case "user" => ModelRole.User
                    case "assistant" => ModelRole.Assistant
                    case _ => throw IllegalArgumentException("unknown durable model role")
                },
                blocks.toArray()
            ))
        }
        let tools = ArrayList<ModelToolDefinition>()
        for (tool in modelInputRequiredCoreListField(value, "tools")) {
            tools.add(ModelToolDefinition(
                modelInputRequiredCoreTextField(tool, "name"),
                modelInputRequiredCoreTextField(tool, "description"),
                modelInputRequiredCoreValueField(tool, "input_schema")
            ))
        }
        let structured: ?StructuredOutputSpec = match (value.field("structured_output")) {
            case Some(raw) => if (raw.unifiedKind == ValueKind.Null) { None } else { Some(StructuredOutputSpec(
                modelInputRequiredCoreTextField(raw, "name"), modelInputRequiredCoreValueField(raw, "schema"),
                description: modelInputRequiredCoreTextField(raw, "description"),
                strict: modelInputRequiredCoreBoolField(raw, "strict")
            )) }
            case None => throw IllegalArgumentException("durable structured output field is missing")
        }
        let resolved: ?ResolvedModelRequestPolicy = match (value.field("resolved_policy")) {
            case Some(raw) => if (raw.unifiedKind == ValueKind.Null) { None } else {
                let mode = modelInputThinkingControlModeFromName(modelInputRequiredCoreTextField(raw, "thinking_mode"))
                let requested = modelInputThinkingLevelFromName(modelInputRequiredCoreTextField(raw, "thinking_requested"))
                let effective = modelInputThinkingLevelFromName(modelInputRequiredCoreTextField(raw, "thinking_effective"))
                let policy = ResolvedModelRequestPolicy(
                    ThinkingResolution(
                        requested, effective, mode,
                        budgetTokens: modelInputOptionalCoreIntegerField(raw, "thinking_budget_tokens"),
                        adaptiveEffort: modelInputOptionalCoreThinkingField(raw, "adaptive_effort"),
                        constraints: modelInputResolutionConstraintsFromValue(
                            modelInputRequiredCoreValueField(raw, "thinking_constraints")
                        )
                    ),
                    OutputLimitResolution(
                        modelInputRequiredCoreIntegerField(raw, "output_requested"),
                        modelInputRequiredCoreIntegerField(raw, "output_effective"),
                        constraints: modelInputResolutionConstraintsFromValue(
                            modelInputRequiredCoreValueField(raw, "output_constraints")
                        )
                    ),
                    policyResolutionVersion: UInt32(modelInputRequiredCoreIntegerField(raw, "policy_resolution_version")),
                    capabilitySnapshotVersion: UInt32(modelInputRequiredCoreIntegerField(raw, "capability_snapshot_version")),
                    capabilityFingerprint: modelInputRequiredCoreTextField(raw, "capability_fingerprint"),
                    capabilitySnapshotPayload: modelInputRequiredCoreTextField(raw, "capability_snapshot_payload"),
                    minVisibleResponseTokens: modelInputRequiredCoreIntegerField(raw, "response_reserve"),
                    thinkingSource: modelInputThinkingPreferenceSourceFromName(modelInputRequiredCoreTextField(raw, "thinking_source")),
                    userRequestedThinking: modelInputOptionalCoreThinkingField(raw, "user_requested_thinking")
                )
                if (canonicalResolvedModelRequestPolicy(policy) !=
                    modelInputRequiredCoreTextField(raw, "canonical")) {
                    throw IllegalArgumentException("durable resolved policy canonical identity drift")
                }
                Some(policy)
            }
            case None => throw IllegalArgumentException("durable resolved policy field is missing")
        }
        Result.Ok(ModelRequest(
            modelInputRequiredCoreTextField(value, "model"),
            messages.toArray(),
            system: modelInputRequiredCoreTextField(value, "system"),
            tools: tools.toArray(),
            thinking: modelInputThinkingLevelFromName(modelInputRequiredCoreTextField(value, "thinking")),
            maxOutputTokens: modelInputRequiredCoreIntegerField(value, "wire_max_output_tokens"),
            wireMaxOutputTokens: Some(modelInputRequiredCoreIntegerField(value, "wire_max_output_tokens")),
            resolvedPolicy: resolved,
            streaming: modelInputRequiredCoreBoolField(value, "streaming"),
            parallelToolCalls: modelInputRequiredCoreBoolField(value, "parallel_tool_calls"),
            requestId: requestId,
            serviceTier: modelInputRequiredCoreTextField(value, "service_tier"),
            cachePolicy: match (modelInputRequiredCoreTextField(value, "cache_policy")) {
                case "default" => ModelCachePolicy.Default
                case "stable_prefix" => ModelCachePolicy.StablePrefix
                case _ => throw IllegalArgumentException("unknown durable cache policy")
            },
            toolChoice: modelInputModelToolChoiceFromName(modelInputRequiredCoreTextField(value, "tool_choice")),
            structuredOutput: structured,
            cacheKey: modelInputRequiredCoreTextField(value, "cache_key"),
            transportHardTimeoutMillis: 0
        ))
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "model.checkpoint_corrupt",
            "durable model request checkpoint is corrupt: " + error.message
        ))
    }
}

func modelInputModelBlockKindName(value: ModelBlockKind): String {
    match (value) {
        case ModelBlockKind.Text => "text"
        case ModelBlockKind.Image => "image"
        case ModelBlockKind.Reasoning => "reasoning"
        case ModelBlockKind.ToolCall => "tool_call"
        case ModelBlockKind.ToolResult => "tool_result"
        case ModelBlockKind.Refusal => "refusal"
        case ModelBlockKind.Error => "error"
        case ModelBlockKind.Unknown => "unknown"
    }
}

func modelInputModelBlockKindFromName(value: String): ModelBlockKind {
    match (value) {
        case "text" => ModelBlockKind.Text
        case "image" => ModelBlockKind.Image
        case "reasoning" => ModelBlockKind.Reasoning
        case "tool_call" => ModelBlockKind.ToolCall
        case "tool_result" => ModelBlockKind.ToolResult
        case "refusal" => ModelBlockKind.Refusal
        case "error" => ModelBlockKind.Error
        case "unknown" => ModelBlockKind.Unknown
        case _ => throw IllegalArgumentException("unknown durable model block kind")
    }
}

func modelInputThinkingLevelFromName(value: String): ThinkingLevel {
    match (value) {
        case "off" => ThinkingLevel.Off
        case "minimal" => ThinkingLevel.Minimal
        case "low" => ThinkingLevel.Low
        case "medium" => ThinkingLevel.Medium
        case "high" => ThinkingLevel.High
        case "xhigh" => ThinkingLevel.XHigh
        case "max" => ThinkingLevel.Max
        case _ => throw IllegalArgumentException("unknown durable thinking level")
    }
}

func modelInputThinkingControlModeFromName(value: String): ThinkingControlMode {
    match (value) {
        case "none" => ThinkingControlMode.NoThinking
        case "toggle" => ThinkingControlMode.Toggle
        case "effort" => ThinkingControlMode.Effort
        case "budget" => ThinkingControlMode.Budget
        case "adaptive" => ThinkingControlMode.Adaptive
        case _ => throw IllegalArgumentException("unknown durable thinking mode")
    }
}

func modelInputThinkingPreferenceSourceFromName(value: String): ThinkingPreferenceSource {
    match (value) {
        case "explicit_user" => ThinkingPreferenceSource.ExplicitUser
        case "mode_preference" => ThinkingPreferenceSource.ModePreference
        case "model_default" => ThinkingPreferenceSource.ModelDefault
        case _ => throw IllegalArgumentException("unknown durable thinking source")
    }
}

func modelInputModelToolChoiceFromName(value: String): ModelToolChoice {
    match (value) {
        case "auto" => ModelToolChoice.Auto
        case "none" => ModelToolChoice.NoTools
        case "required" => ModelToolChoice.Required
        case _ => throw IllegalArgumentException("unknown durable tool choice")
    }
}

func modelInputThinkingPreferenceSourceName(value: ThinkingPreferenceSource): String {
    match (value) {
        case ThinkingPreferenceSource.ExplicitUser => "explicit_user"
        case ThinkingPreferenceSource.ModePreference => "mode_preference"
        case ThinkingPreferenceSource.ModelDefault => "model_default"
    }
}

func modelInputResolutionConstraintsValue(values: Array<ResolutionConstraint>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) {
        result.add(objectValue([
            ValueField("target", textValue(modelInputResolutionConstraintTargetName(value.target))),
            ValueField("kind", textValue(modelInputResolutionConstraintKindName(value.kind))),
            ValueField("before", modelInputResolutionValueValue(value.before)),
            ValueField("after", modelInputResolutionValueValue(value.after))
        ]))
    }
    listValue(result.toArray())
}

func modelInputResolutionConstraintsFromValue(value: AgentValue): Array<ResolutionConstraint> {
    let result = ArrayList<ResolutionConstraint>()
    if (value.unifiedKind != ValueKind.List) {
        throw IllegalArgumentException("durable resolution constraints must be a list")
    }
    for (raw in value.items) {
        let target = match (modelInputRequiredCoreTextField(raw, "target")) {
            case "output_limit" => ResolutionConstraintTarget.OutputLimit
            case "thinking_level" => ResolutionConstraintTarget.ThinkingLevel
            case _ => throw IllegalArgumentException("unknown durable resolution constraint target")
        }
        let kind = match (modelInputRequiredCoreTextField(raw, "kind")) {
            case "model_output_limit" => ResolutionConstraintKind.ModelOutputLimit
            case "endpoint_output_limit" => ResolutionConstraintKind.EndpointOutputLimit
            case "model_supported_level" => ResolutionConstraintKind.ModelSupportedLevel
            case "attempt_recovery_ceiling" => ResolutionConstraintKind.AttemptRecoveryCeiling
            case "available_thinking_budget" => ResolutionConstraintKind.AvailableThinkingBudget
            case _ => throw IllegalArgumentException("unknown durable resolution constraint kind")
        }
        let before = modelInputResolutionValueFromValue(
            modelInputRequiredCoreValueField(raw, "before"), target
        )
        let after = modelInputResolutionValueFromValue(
            modelInputRequiredCoreValueField(raw, "after"), target
        )
        result.add(ResolutionConstraint(target, kind, before, after))
    }
    result.toArray()
}

func modelInputResolutionValueFromValue(
    value: AgentValue,
    target: ResolutionConstraintTarget
): ResolutionValue {
    match (target) {
        case ResolutionConstraintTarget.OutputLimit =>
            if (value.unifiedKind != ValueKind.Number) {
                throw IllegalArgumentException("durable output constraint value must be an integer")
            }
            ResolutionValue.TokenLimit(Int64.parse(value.asNumberText()))
        case ResolutionConstraintTarget.ThinkingLevel =>
            if (value.unifiedKind != ValueKind.Text) {
                throw IllegalArgumentException("durable thinking constraint value must be text")
            }
            ResolutionValue.ThinkingValue(modelInputThinkingLevelFromName(value.text))
    }
}

func modelInputResolutionValueValue(value: ResolutionValue): AgentValue {
    match (value) {
        case ResolutionValue.TokenLimit(tokens) => integerValue(tokens)
        case ResolutionValue.ThinkingValue(level) => textValue(modelInputThinkingLevelName(level))
    }
}

func modelInputResolutionConstraintTargetName(value: ResolutionConstraintTarget): String {
    match (value) {
        case ResolutionConstraintTarget.OutputLimit => "output_limit"
        case ResolutionConstraintTarget.ThinkingLevel => "thinking_level"
    }
}

func modelInputResolutionConstraintKindName(value: ResolutionConstraintKind): String {
    match (value) {
        case ResolutionConstraintKind.ModelOutputLimit => "model_output_limit"
        case ResolutionConstraintKind.EndpointOutputLimit => "endpoint_output_limit"
        case ResolutionConstraintKind.ModelSupportedLevel => "model_supported_level"
        case ResolutionConstraintKind.AttemptRecoveryCeiling => "attempt_recovery_ceiling"
        case ResolutionConstraintKind.AvailableThinkingBudget => "available_thinking_budget"
    }
}

func modelInputThinkingControlModeName(value: ThinkingControlMode): String {
    match (value) {
        case ThinkingControlMode.NoThinking => "none"
        case ThinkingControlMode.Toggle => "toggle"
        case ThinkingControlMode.Effort => "effort"
        case ThinkingControlMode.Budget => "budget"
        case ThinkingControlMode.Adaptive => "adaptive"
    }
}

func modelInputThinkingLevelName(value: ThinkingLevel): String {
    match (value) {
        case ThinkingLevel.Off => "off"
        case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"
        case ThinkingLevel.Medium => "medium"
        case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"
        case ThinkingLevel.Max => "max"
    }
}

func modelInputModelToolChoiceName(value: ModelToolChoice): String {
    match (value) {
        case ModelToolChoice.Auto => "auto"
        case ModelToolChoice.NoTools => "none"
        case ModelToolChoice.Required => "required"
    }
}

func modelInputRequiredCoreTextField(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Text) { item.text }
            else { throw IllegalArgumentException("durable field is not text: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func modelInputRequiredCoreListField(value: AgentValue, name: String): Array<AgentValue> {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.List) { item.items.toArray() }
            else { throw IllegalArgumentException("durable field is not a list: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func modelInputRequiredCoreValueField(value: AgentValue, name: String): AgentValue {
    match (value.field(name)) {
        case Some(item) => item
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func modelInputRequiredCoreBoolField(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Boolean) { item.asBool() }
            else { throw IllegalArgumentException("durable field is not boolean: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func modelInputRequiredCoreIntegerField(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Number) { Int64.parse(item.asNumberText()) }
            else { throw IllegalArgumentException("durable field is not an integer: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func modelInputOptionalCoreIntegerField(value: AgentValue, name: String): ?Int64 {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Null) { None }
            else if (item.unifiedKind == ValueKind.Number) { Some(Int64.parse(item.asNumberText())) }
            else { throw IllegalArgumentException("durable field is not an optional integer: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

func modelInputOptionalCoreThinkingField(value: AgentValue, name: String): ?ThinkingLevel {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == ValueKind.Null) { None }
            else if (item.unifiedKind == ValueKind.Text) { Some(modelInputThinkingLevelFromName(item.text)) }
            else { throw IllegalArgumentException("durable field is not optional thinking: " + name) }
        case None => throw IllegalArgumentException("durable field is missing: " + name)
    }
}

public func modelRequestWirePolicyDigest(request: ModelRequest): String {
    modelPolicySha256Text("wire-policy-v1\n" + request.model + "\n" +
        request.wireMaxOutputTokens.toString() + "\n" + modelInputModelToolChoiceName(request.toolChoice) + "\n" +
        "transport_hard_timeout_millis=" + request.transportHardTimeoutMillis.toString() + "\n" +
        match (request.resolvedPolicy) { case Some(value) => canonicalResolvedModelRequestPolicy(value)
            case None => modelInputThinkingLevelName(request.thinking) })
}
