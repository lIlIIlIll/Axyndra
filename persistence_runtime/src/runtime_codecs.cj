package persistence_runtime

import agent_domain.*
import model_adapters.*
import std.collection.*
import std.convert.*
import std.fs.*
import std.overflow.*

const RUN_SNAPSHOT_FORMAT_VERSION: Int64 = 2
const RUN_EVENT_FORMAT_VERSION: Int64 = 1

func ensureDirectory(path: String): Unit {
    if (!exists(Path(path))) { Directory.create(path, recursive: true) }
}

func readText(path: String): String { String.fromUtf8(File.readFrom(path)) }

func readTextResult(path: String, code: String): Result<String> {
    try {
        Result.Ok(readText(path))
    } catch (error: Exception) {
        Result.Err(AgentError(AgentErrorKind.Internal, code, error.message))
    }
}

func atomicWrite(path: String, source: String): Result<Unit> {
    var temporary = ""
    try {
        ensureDirectory(Path(path).parent.toString())
        let file = File.createTemp(Path(path).parent)
        temporary = file.info.path.toString()
        try { file.write(source.toArray()) } finally { file.close() }
        rename(temporary, to: path, overwrite: true)
        Result.Ok(())
    } catch (error: Exception) {
        if (temporary != "") { try { let _ = removeIfExists(temporary) } catch (_: Exception) {} }
        Result.Err(AgentError(
            AgentErrorKind.Internal, "persistence.atomic_write", error.message,
            fields: [ErrorField("path", path)]
        ))
    }
}

func safeId(value: String): String {
    var safe = value != "" && value != "." && value != ".."
    for (byte in value.toArray()) {
        let alpha = (byte >= UInt8(65) && byte <= UInt8(90)) ||
            (byte >= UInt8(97) && byte <= UInt8(122))
        let digit = byte >= UInt8(48) && byte <= UInt8(57)
        if (!alpha && !digit && byte != UInt8(45) && byte != UInt8(46) && byte != UInt8(95)) {
            safe = false
        }
    }
    if (safe) { return value }
    var hash: UInt64 = 1469598103934665603
    for (byte in value.toArray()) {
        hash = (hash ^ UInt64(byte)).wrappingMul(1099511628211)
    }
    "id-" + hash.toString()
}

func canonicalSessionWorkspacePath(value: String, field: String): Result<String> {
    let authored = value.trimAscii()
    if (authored == "" || !Path(authored).isAbsolute()) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "persistence.session_workspace_" + field + "_invalid",
            "session " + field + " must be an absolute existing path"
        ))
    }
    try {
        Result.Ok(canonicalize(Path(authored)).toString())
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "persistence.session_workspace_" + field + "_invalid",
            error.message
        ))
    }
}

func agentValuesEqual(left: AgentValue, right: AgentValue): Bool {
    encodeAgentValue(left) == encodeAgentValue(right)
}

func sameContinuationBinding(left: RunContinuation, right: RunContinuation): Bool {
    encodeAgentValue(continuationValue(
        left, approvalRequestBindingValue(left.approval)
    )) == encodeAgentValue(continuationValue(
        right, approvalRequestBindingValue(right.approval)
    ))
}

func sameContinuationRequestBinding(left: RunContinuation, right: RunContinuation): Bool {
    encodeAgentValue(continuationRequestBindingValue(left)) ==
        encodeAgentValue(continuationRequestBindingValue(right))
}

func continuationRequestBindingValue(value: RunContinuation): AgentValue {
    let capabilities = ArrayList<AgentValue>()
    for (capability in value.capabilities.values) {
        capabilities.add(capabilityValue(capability))
    }
    let images = ArrayList<AgentValue>()
    for (image in value.imageInputs) { images.add(modelImageValue(image)) }
    objectValue([
        ValueField("run_id", textValue(value.runId.value)),
        ValueField("session_id", textValue(value.sessionId.value)),
        ValueField("model", textValue(value.model)),
        ValueField("prompt", textValue(value.prompt)),
        ValueField("system", textValue(value.system)),
        ValueField("thinking", textValue(thinkingName(value.thinking))),
        ValueField("capabilities", listValue(capabilities.toArray())),
        ValueField("budget", budgetValue(value.budget)),
        ValueField("approval_mode", textValue(value.approvalMode)),
        ValueField("auto_retry", boolValue(value.autoRetry)),
        ValueField("service_tier", textValue(value.serviceTier)),
        ValueField("pricing", match (value.pricing) {
            case Some(pricing) => pricingValue(pricing)
            case None => nullValue()
        }),
        ValueField("image_inputs", listValue(images.toArray())),
        ValueField("structured_output", match (value.structuredOutput) {
            case Some(spec) => structuredOutputSpecValue(spec)
            case None => nullValue()
        }),
        ValueField("cache_policy", textValue(modelCachePolicyName(value.cachePolicy))),
        ValueField("cache_key", textValue(value.cacheKey)),
        ValueField("parallel_tool_calls", boolValue(value.parallelToolCalls)),
        ValueField("requested_policy", match (value.requestedPolicy) {
            case Some(policy) => requestedModelPolicyValue(policy)
            case None => nullValue()
        }),
        ValueField("model_capabilities_snapshot", match (value.modelCapabilitiesSnapshot) {
            case Some(snapshot) => modelCapabilitiesSnapshotValue(snapshot)
            case None => nullValue()
        }),
        ValueField("resolver_version", integerValue(Int64(value.resolverVersion))),
        ValueField("skill_stack", value.skillStackPayload),
        ValueField("context_window", integerValue(value.contextWindow)),
        ValueField("provider_safety_margin", integerValue(value.providerSafetyMargin)),
        ValueField("tool_context", value.toolContextPayload)
    ])
}

func sameDecisionReceipt(
    left: ApprovalDecisionReceipt,
    right: ApprovalDecisionReceipt
): Bool {
    left.operationId.value == right.operationId.value &&
        left.runId.value == right.runId.value &&
        left.sessionId.value == right.sessionId.value &&
        left.callId == right.callId && left.argumentHash == right.argumentHash &&
        left.decision == right.decision
}

func storedApprovalGrantAllows(value: AgentValue, requested: ApprovalGrantScope): Bool {
    let capability = value.field("capability")
    let pathPrefix = value.field("path_prefix")
    let toolName = value.field("tool_name")
    let host = value.field("host")
    if (capability.isNone() || capability.getOrThrow().kind != ValueKind.Text ||
        capability.getOrThrow().text != requested.capability) { return false }
    let storedTool = if (toolName.isSome() && toolName.getOrThrow().kind == ValueKind.Text) {
        toolName.getOrThrow().text
    } else { "" }
    let storedHost = if (host.isSome() && host.getOrThrow().kind == ValueKind.Text) {
        host.getOrThrow().text
    } else { "" }
    let storedPath = if (pathPrefix.isSome() && pathPrefix.getOrThrow().kind == ValueKind.Text) {
        pathPrefix.getOrThrow().text
    } else { "" }
    if (storedTool != "" && storedTool != requested.toolName) { return false }
    if (storedHost != "" && storedHost != requested.host) { return false }
    if (storedPath != "" && requested.pathPrefix != storedPath &&
        !requested.pathPrefix.startsWith(storedPath + "/")) { return false }
    true
}

func isRunAccountingEvent(event: AgentEvent): Bool {
    match (event.payload) {
        case AgentEventPayload.ModelUsageUpdated(_) |
             AgentEventPayload.ModelRequestAttemptCompleted(_) => true
        case _ => false
    }
}

public class SessionRunStats {
    public let runs: Int64
    public let modelRequests: Int64
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public let costMicros: ?Int64
    public let lastInputTokens: Int64
    public let lastOutputTokens: Int64
    public let lastRequestDurationMillis: Int64
    public let toolCalls: Int64
    public let turns: Int64

    public init(
        runs: Int64,
        modelRequests: Int64,
        inputTokens: Int64,
        outputTokens: Int64,
        toolCalls: Int64,
        turns: Int64,
        reasoningTokens!: Int64 = 0,
        cacheReadTokens!: Int64 = 0,
        cacheWriteTokens!: Int64 = 0,
        costMicros!: ?Int64 = None,
        lastInputTokens!: Int64 = 0,
        lastOutputTokens!: Int64 = 0,
        lastRequestDurationMillis!: Int64 = 0
    ) {
        this.runs = runs
        this.modelRequests = modelRequests
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.reasoningTokens = reasoningTokens
        this.cacheReadTokens = cacheReadTokens
        this.cacheWriteTokens = cacheWriteTokens
        this.costMicros = costMicros
        this.lastInputTokens = lastInputTokens
        this.lastOutputTokens = lastOutputTokens
        this.lastRequestDurationMillis = lastRequestDurationMillis
        this.toolCalls = toolCalls
        this.turns = turns
    }
}



func modelImageValue(value: ModelImage): AgentValue {
    objectValue([
        ValueField("source_kind", textValue(modelImageSourceName(value.sourceKind))),
        ValueField("data", textValue(value.data)),
        ValueField("media_type", textValue(value.mediaType)),
        ValueField("detail", textValue(modelImageDetailName(value.detail)))
    ])
}

func modelImageFromValue(value: AgentValue): Result<ModelImage> {
    if (value.kind != ValueKind.Object) {
        return codecError("model image must be an object")
    }
    let sourceKind = match (requiredText(value, "source_kind")) {
        case Result.Ok("url") => ModelImageSourceKind.Url
        case Result.Ok("base64") => ModelImageSourceKind.Base64
        case Result.Ok(_) => return codecError("unknown model image source kind")
        case Result.Err(error) => return Result.Err(error)
    }
    let detail = match (requiredText(value, "detail")) {
        case Result.Ok("auto") => ModelImageDetail.Auto
        case Result.Ok("low") => ModelImageDetail.Low
        case Result.Ok("high") => ModelImageDetail.High
        case Result.Ok(_) => return codecError("unknown model image detail")
        case Result.Err(error) => return Result.Err(error)
    }
    let data = match (requiredText(value, "data")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let mediaType = match (requiredText(value, "media_type")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(ModelImage(sourceKind, data, mediaType: mediaType, detail: detail))
    } catch (error: Exception) {
        codecError(error.message)
    }
}

func encodeSnapshot(snapshot: RunSnapshot): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("format_version", integerValue(RUN_SNAPSHOT_FORMAT_VERSION)),
                ValueField("run_id", textValue(snapshot.runId.value)),
                ValueField("session_id", textValue(snapshot.sessionId.value)),
                ValueField("status", textValue(statusName(snapshot.status))),
                ValueField("run_kind", textValue(runKindName(snapshot.kind))),
                ValueField("sequence", integerValue(snapshot.sequence)),
                ValueField("summary", textValue(snapshot.summary)),
                ValueField("model_requests", integerValue(snapshot.modelRequests)),
                ValueField("input_tokens", integerValue(snapshot.inputTokens)),
                ValueField("output_tokens", integerValue(snapshot.outputTokens)),
                ValueField("reasoning_tokens", integerValue(snapshot.reasoningTokens)),
                ValueField("cache_read_tokens", integerValue(snapshot.cacheReadTokens)),
                ValueField("cache_write_tokens", integerValue(snapshot.cacheWriteTokens)),
                ValueField("cost_micros", optionalIntegerValue(snapshot.costMicros)),
                ValueField("last_input_tokens", integerValue(snapshot.lastInputTokens)),
                ValueField("last_output_tokens", integerValue(snapshot.lastOutputTokens)),
                ValueField(
                    "last_request_duration_millis",
                    integerValue(snapshot.lastRequestDurationMillis)
                ),
                ValueField("tool_calls", integerValue(snapshot.toolCalls)),
                ValueField("turns", integerValue(snapshot.turns)),
                ValueField("structured_output", match (snapshot.structuredOutput) {
                    case Some(value) => value
                    case None => nullValue()
                }),
                ValueField("error", match (snapshot.error) {
                    case Some(error) => errorValue(error)
                    case None => nullValue()
                })
            ]
        )
    )
}

func decodeSnapshot(source: String): Result<RunSnapshot> {
    let value = match (decodeAgentValue(source, maxBytes: 67108864)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (value.kind != ValueKind.Object) {
        return codecError("run snapshot must be an object")
    }
    let formatVersion = match (requiredInteger(value, "format_version")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (formatVersion != RUN_SNAPSHOT_FORMAT_VERSION) {
        return codecError("unsupported run snapshot format version")
    }
    let runId = match (requiredNonEmptyText(value, "run_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let sessionId = match (requiredNonEmptyText(value, "session_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let statusName = match (requiredText(value, "status")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let status = match (statusFrom(statusName)) {
        case Some(item) => item
        case None => return codecError("unknown run status")
    }
    let kindName = match (requiredText(value, "run_kind")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let kind = match (runKindFrom(kindName)) {
        case Some(item) => item
        case None => return codecError("unknown run kind")
    }
    let sequence = match (requiredInteger(value, "sequence")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let summary = match (requiredText(value, "summary")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let modelRequests = match (requiredInteger(value, "model_requests")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let inputTokens = match (requiredInteger(value, "input_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let outputTokens = match (requiredInteger(value, "output_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let reasoningTokens = match (requiredInteger(value, "reasoning_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let cacheReadTokens = match (requiredInteger(value, "cache_read_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let cacheWriteTokens = match (requiredInteger(value, "cache_write_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let costMicros = match (requiredOptionalInteger(value, "cost_micros")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let lastInputTokens = match (requiredInteger(value, "last_input_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let lastOutputTokens = match (requiredInteger(value, "last_output_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let lastRequestDurationMillis = match (requiredInteger(
        value,
        "last_request_duration_millis"
    )) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let toolCalls = match (requiredInteger(value, "tool_calls")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let turns = match (requiredInteger(value, "turns")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let structuredOutput: ?AgentValue = match (value.field("structured_output")) {
        case Some(raw) => if (raw.kind == ValueKind.Null) { None } else { Some(raw) }
        case None => return codecError("missing field: structured_output")
    }
    let snapshotError: ?AgentError = match (value.field("error")) {
        case Some(raw) =>
            if (raw.kind == ValueKind.Null) {
                None
            } else {
                match (strictErrorFrom(raw)) {
                    case Result.Ok(item) => Some(item)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        case None => return codecError("missing field: error")
    }
    try {
        Result.Ok(RunSnapshot(
            RunId(runId),
            SessionId(sessionId),
            status,
            sequence: sequence,
            summary: summary,
            error: snapshotError,
            modelRequests: modelRequests,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            reasoningTokens: reasoningTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            costMicros: costMicros,
            lastInputTokens: lastInputTokens,
            lastOutputTokens: lastOutputTokens,
            lastRequestDurationMillis: lastRequestDurationMillis,
            toolCalls: toolCalls,
            turns: turns,
            structuredOutput: structuredOutput,
            kind: kind
        ))
    } catch (error: Exception) {
        codecError(error.message)
    }
}

func requiredOptionalInteger(
    value: AgentValue,
    name: String
): Result<?Int64> {
    match (value.field(name)) {
        case Some(raw) =>
            if (raw.kind == ValueKind.Null) {
                Result.Ok(None)
            } else if (raw.kind == ValueKind.Number) {
                try {
                    Result.Ok(Some(Int64.parse(raw.number)))
                } catch (_: Exception) {
                    codecError("field is not an integer or null: " + name)
                }
            } else {
                codecError("field is not an integer or null: " + name)
            }
        case None => codecError("missing field: " + name)
    }
}

func encodeContinuation(value: RunContinuation): String {
    encodeAgentValue(continuationValue(
        value, approvalRequestValue(value.approval)
    ))
}

func continuationValue(
    value: RunContinuation,
    approval: AgentValue
): AgentValue {
    let capabilities = ArrayList<AgentValue>()
    for (capability in value.capabilities.values) {
        capabilities.add(capabilityValue(capability))
    }
    let imageInputs = ArrayList<AgentValue>()
    for (image in value.imageInputs) {
        imageInputs.add(modelImageValue(image))
    }
    objectValue([
        ValueField("version", integerValue(4)),
        ValueField("kind", textValue(match (value.kind) {
            case RunContinuationKind.WaitingApproval => "waiting_approval"
            case RunContinuationKind.RunningModel => "running_model"
        })),
        ValueField("run_id", textValue(value.runId.value)),
        ValueField("session_id", textValue(value.sessionId.value)),
        ValueField("model", textValue(value.model)),
        ValueField("prompt", textValue(value.prompt)),
        ValueField("system", textValue(value.system)),
        ValueField("thinking", textValue(thinkingName(value.thinking))),
        ValueField("capabilities", listValue(capabilities.toArray())),
        ValueField("budget", budgetValue(value.budget)),
        ValueField("approval_mode", textValue(value.approvalMode)),
        ValueField("auto_retry", boolValue(value.autoRetry)),
        ValueField("service_tier", textValue(value.serviceTier)),
        ValueField("pricing", match (value.pricing) {
            case Some(pricing) => pricingValue(pricing)
            case None => nullValue()
        }),
        ValueField("image_inputs", listValue(imageInputs.toArray())),
        ValueField("structured_output", match (value.structuredOutput) {
            case Some(spec) => structuredOutputSpecValue(spec)
            case None => nullValue()
        }),
        ValueField("cache_policy", textValue(modelCachePolicyName(value.cachePolicy))),
        ValueField("cache_key", textValue(value.cacheKey)),
        ValueField("parallel_tool_calls", boolValue(value.parallelToolCalls)),
        ValueField("approval", approval),
        ValueField("requested_policy", match (value.requestedPolicy) {
            case Some(policy) => requestedModelPolicyValue(policy)
            case None => nullValue()
        }),
        ValueField("model_capabilities_snapshot", match (value.modelCapabilitiesSnapshot) {
            case Some(snapshot) => modelCapabilitiesSnapshotValue(snapshot)
            case None => nullValue()
        }),
        ValueField("resolver_version", integerValue(Int64(value.resolverVersion))),
        ValueField("skill_stack", value.skillStackPayload),
        ValueField("context_window", integerValue(value.contextWindow)),
        ValueField("provider_safety_margin", integerValue(value.providerSafetyMargin)),
        ValueField("tool_context", value.toolContextPayload),
        ValueField("running_model", match (value.runningModel) {
            case Some(checkpoint) => runningModelCheckpointValue(checkpoint)
            case None => nullValue()
        })
    ])
}

func requestedModelPolicyValue(value: RequestedModelPolicy): AgentValue {
    objectValue([
        ValueField("user_requested_thinking", match (value.userRequestedThinking) {
            case Some(level) => textValue(thinkingName(level))
            case None => nullValue()
        }),
        ValueField("policy_requested_thinking", textValue(thinkingName(value.policyRequestedThinking))),
        ValueField("thinking_source", textValue(thinkingPreferenceSourceName(value.thinkingSource))),
        ValueField("output_hard_limit", integerValue(value.requestOutputBudget.hardLimit)),
        ValueField("min_visible_response_tokens", integerValue(
            value.requestOutputBudget.minVisibleResponseTokens
        ))
    ])
}

func modelCapabilitiesSnapshotValue(value: ModelExecutionCapabilitiesSnapshot): AgentValue {
    let levels = ArrayList<AgentValue>()
    for (level in value.thinking.supportedLevels) {
        levels.add(textValue(thinkingName(level)))
    }
    let tiers = ArrayList<AgentValue>()
    for (tier in value.thinking.budgetTiers) {
        tiers.add(objectValue([
            ValueField("level", textValue(thinkingName(tier.level))),
            ValueField("budget_tokens", integerValue(tier.budgetTokens))
        ]))
    }
    objectValue([
        ValueField("snapshot_schema_version", integerValue(Int64(value.snapshotSchemaVersion))),
        ValueField("model_id", textValue(value.modelId)),
        ValueField("thinking_mode", textValue(thinkingControlModeName(value.thinking.mode))),
        ValueField("supported_levels", listValue(levels.toArray())),
        ValueField("budget_tiers", listValue(tiers.toArray())),
        ValueField("model_max_output_tokens", integerValue(value.modelMaxOutputTokens)),
        ValueField("endpoint_max_output_tokens", optionalIntegerValue(value.endpointMaxOutputTokens)),
        ValueField("capability_fingerprint", textValue(value.capabilityFingerprint))
    ])
}

func runningModelCheckpointValue(value: RunningModelCheckpoint): AgentValue {
    objectValue([
        ValueField("semantic_request_id", textValue(value.semanticRequestId.value)),
        ValueField("canonical_request", value.canonicalRequest),
        ValueField("semantic_request_digest", textValue(value.semanticRequestDigest)),
        ValueField("wire_policy_digest", textValue(value.wirePolicyDigest)),
        ValueField("original_attempt_id", textValue(value.originalAttemptId.value)),
        ValueField("active_attempt_id", textValue(value.activeAttemptId.value)),
        ValueField("stable_turn_id", textValue(value.stableTurnId)),
        ValueField("stable_request_id", textValue(value.stableRequestId)),
        ValueField("request_started_at_millis", integerValue(value.requestStartedAtMillis)),
        ValueField("model_requests", integerValue(value.modelRequests)),
        ValueField("input_tokens", integerValue(value.inputTokens)),
        ValueField("output_tokens", integerValue(value.outputTokens)),
        ValueField("reasoning_tokens", integerValue(value.reasoningTokens)),
        ValueField("cache_read_tokens", integerValue(value.cacheReadTokens)),
        ValueField("cache_write_tokens", integerValue(value.cacheWriteTokens)),
        ValueField("cost_micros", optionalIntegerValue(value.costMicros)),
        ValueField("last_input_tokens", integerValue(value.lastInputTokens)),
        ValueField("last_output_tokens", integerValue(value.lastOutputTokens)),
        ValueField("last_request_duration_millis", integerValue(value.lastRequestDurationMillis)),
        ValueField("tool_calls", integerValue(value.toolCalls)),
        ValueField("turns", integerValue(value.turns)),
        ValueField("consecutive_capability_denials", integerValue(value.consecutiveCapabilityDenials)),
        ValueField("last_capability_denied_tool", textValue(value.lastCapabilityDeniedTool))
    ])
}

func requestedModelPolicyFromValue(value: AgentValue): Result<RequestedModelPolicy> {
    if (value.kind != ValueKind.Object) {
        return codecError("requested model policy must be an object")
    }
    let userRequested: ?ThinkingLevel = match (value.field("user_requested_thinking")) {
        case Some(raw) => if (raw.kind == ValueKind.Null) {
            None
        } else if (raw.kind == ValueKind.Text) {
            match (thinkingFromName(raw.text)) {
                case Result.Ok(level) => Some(level)
                case Result.Err(error) => return Result.Err(error)
            }
        } else {
            return codecError("user requested thinking must be text or null")
        }
        case None => return codecError("missing field: user_requested_thinking")
    }
    let requested = match (requiredThinking(value, "policy_requested_thinking")) {
        case Result.Ok(level) => level
        case Result.Err(error) => return Result.Err(error)
    }
    let source = match (requiredText(value, "thinking_source")) {
        case Result.Ok("explicit_user") => ThinkingPreferenceSource.ExplicitUser
        case Result.Ok("mode_preference") => ThinkingPreferenceSource.ModePreference
        case Result.Ok("model_default") => ThinkingPreferenceSource.ModelDefault
        case Result.Ok(_) => return codecError("unknown thinking preference source")
        case Result.Err(error) => return Result.Err(error)
    }
    let hardLimit = match (requiredInteger(value, "output_hard_limit")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let reserve = match (requiredInteger(value, "min_visible_response_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(RequestedModelPolicy(
            requested,
            RequestOutputBudget(hardLimit, minVisibleResponseTokens: reserve),
            userRequestedThinking: userRequested,
            thinkingSource: source
        ))
    } catch (error: Exception) {
        codecError("invalid requested model policy: " + error.message)
    }
}

func modelCapabilitiesSnapshotFromValue(
    value: AgentValue
): Result<ModelExecutionCapabilitiesSnapshot> {
    if (value.kind != ValueKind.Object) {
        return codecError("model capabilities snapshot must be an object")
    }
    let version = match (requiredInteger(value, "snapshot_schema_version")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (version < 0 || version > 4294967295) {
        return codecError("model capabilities snapshot version is out of range")
    }
    let mode = match (requiredText(value, "thinking_mode")) {
        case Result.Ok("none") => ThinkingControlMode.NoThinking
        case Result.Ok("toggle") => ThinkingControlMode.Toggle
        case Result.Ok("effort") => ThinkingControlMode.Effort
        case Result.Ok("budget") => ThinkingControlMode.Budget
        case Result.Ok("adaptive") => ThinkingControlMode.Adaptive
        case Result.Ok(_) => return codecError("unknown thinking control mode")
        case Result.Err(error) => return Result.Err(error)
    }
    let levels = ArrayList<ThinkingLevel>()
    for (raw in match (requiredList(value, "supported_levels")) {
        case Result.Ok(items) => items
        case Result.Err(error) => return Result.Err(error)
    }) {
        if (raw.kind != ValueKind.Text) {
            return codecError("supported thinking level must be text")
        }
        match (thinkingFromName(raw.text)) {
            case Result.Ok(level) => levels.add(level)
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let tiers = ArrayList<ThinkingBudgetTier>()
    for (raw in match (requiredList(value, "budget_tiers")) {
        case Result.Ok(items) => items
        case Result.Err(error) => return Result.Err(error)
    }) {
        let level = match (requiredThinking(raw, "level")) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        let tokens = match (requiredInteger(raw, "budget_tokens")) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            tiers.add(ThinkingBudgetTier(level, tokens))
        } catch (error: Exception) {
            return codecError("invalid thinking budget tier: " + error.message)
        }
    }
    let endpoint = match (requiredOptionalInteger(value, "endpoint_max_output_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let modelId = match (requiredNonEmptyText(value, "model_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let maxOutput = match (requiredInteger(value, "model_max_output_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let fingerprint = match (requiredNonEmptyText(value, "capability_fingerprint")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(ModelExecutionCapabilitiesSnapshot(
            modelId,
            ThinkingCapabilities(mode, supportedLevels: levels.toArray(), budgetTiers: tiers.toArray()),
            maxOutput,
            endpointMaxOutputTokens: endpoint,
            capabilityFingerprint: fingerprint,
            snapshotSchemaVersion: UInt32(version)
        ))
    } catch (error: Exception) {
        codecError("invalid model capabilities snapshot: " + error.message)
    }
}

func runningModelCheckpointFromValue(value: AgentValue): Result<RunningModelCheckpoint> {
    if (value.kind != ValueKind.Object) {
        return codecError("running model checkpoint must be an object")
    }
    let canonicalRequest = match (value.field("canonical_request")) {
        case Some(item) => item
        case None => return codecError("missing field: canonical_request")
    }
    let cost = match (requiredOptionalInteger(value, "cost_micros")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(RunningModelCheckpoint(
            SemanticModelRequestId(requiredCodecText(value, "semantic_request_id")),
            canonicalRequest,
            requiredCodecText(value, "semantic_request_digest"),
            requiredCodecText(value, "wire_policy_digest"),
            ModelAttemptId(requiredCodecText(value, "original_attempt_id")),
            ModelAttemptId(requiredCodecText(value, "active_attempt_id")),
            requiredCodecText(value, "stable_turn_id"),
            requiredCodecText(value, "stable_request_id"),
            requiredCodecInteger(value, "request_started_at_millis"),
            modelRequests: requiredCodecInteger(value, "model_requests"),
            inputTokens: requiredCodecInteger(value, "input_tokens"),
            outputTokens: requiredCodecInteger(value, "output_tokens"),
            reasoningTokens: requiredCodecInteger(value, "reasoning_tokens"),
            cacheReadTokens: requiredCodecInteger(value, "cache_read_tokens"),
            cacheWriteTokens: requiredCodecInteger(value, "cache_write_tokens"),
            costMicros: cost,
            lastInputTokens: requiredCodecInteger(value, "last_input_tokens"),
            lastOutputTokens: requiredCodecInteger(value, "last_output_tokens"),
            lastRequestDurationMillis: requiredCodecInteger(value, "last_request_duration_millis"),
            toolCalls: requiredCodecInteger(value, "tool_calls"),
            turns: requiredCodecInteger(value, "turns"),
            consecutiveCapabilityDenials: requiredCodecInteger(value, "consecutive_capability_denials"),
            lastCapabilityDeniedTool: requiredCodecAnyText(value, "last_capability_denied_tool")
        ))
    } catch (error: Exception) {
        codecError("invalid running model checkpoint: " + error.message)
    }
}

func requiredCodecText(value: AgentValue, name: String): String {
    match (requiredNonEmptyText(value, name)) {
        case Result.Ok(item) => item
        case Result.Err(error) => throw IllegalArgumentException(error.message)
    }
}

func requiredCodecInteger(value: AgentValue, name: String): Int64 {
    match (requiredInteger(value, name)) {
        case Result.Ok(item) => item
        case Result.Err(error) => throw IllegalArgumentException(error.message)
    }
}

func requiredCodecAnyText(value: AgentValue, name: String): String {
    match (requiredText(value, name)) {
        case Result.Ok(item) => item
        case Result.Err(error) => throw IllegalArgumentException(error.message)
    }
}

func structuredOutputSpecValue(value: StructuredOutputSpec): AgentValue {
    objectValue([
        ValueField("name", textValue(value.name)),
        ValueField("description", textValue(value.description)),
        ValueField("schema", value.schema),
        ValueField("strict", boolValue(value.strict))
    ])
}

func structuredOutputSpecFromValue(
    value: AgentValue
): Result<StructuredOutputSpec> {
    if (value.kind != ValueKind.Object) {
        return codecError("structured output specification must be an object")
    }
    let name = match (requiredNonEmptyText(value, "name")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let description = match (requiredText(value, "description")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let schema = match (value.field("schema")) {
        case Some(item) => item
        case None => return codecError("missing field: structured output schema")
    }
    let strict = match (requiredBoolean(value, "strict")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(StructuredOutputSpec(
            name,
            schema,
            description: description,
            strict: strict
        ))
    } catch (error: Exception) {
        codecError("invalid structured output specification: " + error.message)
    }
}

func modelCachePolicyName(value: ModelCachePolicy): String {
    match (value) {
        case ModelCachePolicy.Default => "default"
        case ModelCachePolicy.StablePrefix => "stable_prefix"
    }
}

func decodeContinuation(source: String): Result<RunContinuation> {
    let value = match (decodeAgentValue(source, maxBytes: 67108864)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (value.kind != ValueKind.Object) {
        return codecError("run continuation must be an object")
    }
    let version = match (requiredInteger(value, "version")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (version != 4) {
        return codecError("unsupported run continuation version")
    }
    let kind = match (requiredText(value, "kind")) {
        case Result.Ok("waiting_approval") => RunContinuationKind.WaitingApproval
        case Result.Ok("running_model") => RunContinuationKind.RunningModel
        case Result.Ok(_) => return codecError("unknown run continuation kind")
        case Result.Err(error) => return Result.Err(error)
    }
    let runId = match (requiredNonEmptyText(value, "run_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let sessionId = match (requiredNonEmptyText(value, "session_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let model = match (requiredNonEmptyText(value, "model")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let prompt = match (requiredNonEmptyText(value, "prompt")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let system = match (requiredText(value, "system")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let thinking = match (requiredThinking(value, "thinking")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let approvalMode = match (requiredApprovalMode(value, "approval_mode")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let autoRetry = match (requiredBoolean(value, "auto_retry")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let serviceTier = match (value.field("service_tier")) {
        case Some(raw) =>
            if (raw.kind == ValueKind.Text) {
                raw.text
            } else {
                return codecError("field is not text: service_tier")
            }
        case None => ""
    }
    if (serviceTier != "" && serviceTier != "auto" &&
        serviceTier != "default" && serviceTier != "flex" &&
        serviceTier != "scale" && serviceTier != "priority") {
        return codecError("unknown run continuation service tier")
    }
    let pricing: ?ModelPricing = match (value.field("pricing")) {
        case Some(raw) =>
            if (raw.kind == ValueKind.Null) {
                None
            } else {
                match (strictPricingFromValue(raw)) {
                    case Result.Ok(item) => Some(item)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        case None => None
    }
    let imageInputs = ArrayList<ModelImage>()
    for (raw in match (requiredList(value, "image_inputs")) {
        case Result.Ok(items) => items
        case Result.Err(error) => return Result.Err(error)
    }) {
        match (modelImageFromValue(raw)) {
            case Result.Ok(item) => imageInputs.add(item)
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let structuredOutput: ?StructuredOutputSpec = match (value.field("structured_output")) {
        case Some(raw) =>
            if (raw.kind == ValueKind.Null) {
                None
            } else {
                match (structuredOutputSpecFromValue(raw)) {
                    case Result.Ok(item) => Some(item)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        case None => return codecError("missing field: structured_output")
    }
    let cachePolicy = match (requiredText(value, "cache_policy")) {
        case Result.Ok("default") => ModelCachePolicy.Default
        case Result.Ok("stable_prefix") => ModelCachePolicy.StablePrefix
        case Result.Ok(_) => return codecError("unknown model cache policy")
        case Result.Err(error) => return Result.Err(error)
    }
    let cacheKey = match (requiredText(value, "cache_key")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let parallelToolCalls = match (requiredBoolean(value, "parallel_tool_calls")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        let capabilities = ArrayList<Capability>()
        for (raw in match (requiredList(value, "capabilities")) {
            case Result.Ok(items) => items
            case Result.Err(error) => return Result.Err(error)
        }) {
            match (strictCapabilityFrom(raw)) {
                case Result.Ok(item) => capabilities.add(item)
                case Result.Err(error) => return Result.Err(error)
            }
        }
        let budget = match (value.field("budget")) {
            case Some(raw) => match (strictBudgetFromValue(raw)) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            case None => return codecError("missing field: budget")
        }
        let approval = match (value.field("approval")) {
            case Some(raw) => match (strictApprovalRequestFromValue(raw)) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            case None => return codecError("missing field: approval")
        }
        if (approval.sessionId != sessionId || approval.callId == "" ||
            approval.argumentHash == "") {
            return codecError("run continuation approval binding is incomplete")
        }
        let requestedPolicy: ?RequestedModelPolicy = match (value.field("requested_policy")) {
            case Some(raw) => if (raw.kind == ValueKind.Null) { None } else {
                match (requestedModelPolicyFromValue(raw)) {
                    case Result.Ok(item) => Some(item)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
            case None => return codecError("missing field: requested_policy")
        }
        let snapshot: ?ModelExecutionCapabilitiesSnapshot = match (
            value.field("model_capabilities_snapshot")
        ) {
            case Some(raw) => if (raw.kind == ValueKind.Null) { None } else {
                match (modelCapabilitiesSnapshotFromValue(raw)) {
                    case Result.Ok(item) => Some(item)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
            case None => return codecError("missing field: model_capabilities_snapshot")
        }
        let resolverVersion = match (requiredInteger(value, "resolver_version")) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        if (resolverVersion < 0 || resolverVersion > 4294967295) {
            return codecError("run continuation resolver version is out of range")
        }
        let skillStack = match (value.field("skill_stack")) {
            case Some(item) => item
            case None => return codecError("missing field: skill_stack")
        }
        let contextWindow = match (requiredInteger(value, "context_window")) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        let safetyMargin = match (requiredInteger(value, "provider_safety_margin")) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        let toolContext = match (value.field("tool_context")) {
            case Some(item) => item
            case None => return codecError("missing field: tool_context")
        }
        let runningModel: ?RunningModelCheckpoint = match (value.field("running_model")) {
            case Some(raw) => if (raw.kind == ValueKind.Null) { None } else {
                match (runningModelCheckpointFromValue(raw)) {
                    case Result.Ok(item) => Some(item)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
            case None => return codecError("missing field: running_model")
        }
        match (kind) {
            case RunContinuationKind.WaitingApproval =>
                if (runningModel.isSome()) {
                    return codecError("waiting approval continuation contains running model state")
                }
                let policy = match (requestedPolicy) {
                    case Some(item) => item
                    case None => return codecError("waiting approval continuation has no requested policy")
                }
                let capabilitiesSnapshot = match (snapshot) {
                    case Some(item) => item
                    case None => return codecError("waiting approval continuation has no capabilities snapshot")
                }
                Result.Ok(RunContinuation(
                    RunId(runId), SessionId(sessionId), model, prompt, approval,
                    system: system, thinking: thinking,
                    capabilities: CapabilitySet(values: capabilities.toArray()),
                    budget: budget, approvalMode: approvalMode, autoRetry: autoRetry,
                    serviceTier: serviceTier, pricing: pricing,
                    imageInputs: imageInputs.toArray(), structuredOutput: structuredOutput,
                    cachePolicy: cachePolicy, cacheKey: cacheKey,
                    parallelToolCalls: parallelToolCalls,
                    requestedPolicy: policy,
                    modelCapabilitiesSnapshot: capabilitiesSnapshot,
                    resolverVersion: UInt32(resolverVersion), skillStackPayload: skillStack,
                    contextWindow: contextWindow, providerSafetyMargin: safetyMargin,
                    toolContextPayload: toolContext
                ))
            case RunContinuationKind.RunningModel =>
                let policy = match (requestedPolicy) {
                    case Some(item) => item
                    case None => return codecError("running model continuation has no requested policy")
                }
                let capabilitiesSnapshot = match (snapshot) {
                    case Some(item) => item
                    case None => return codecError("running model continuation has no capabilities snapshot")
                }
                let checkpoint = match (runningModel) {
                    case Some(item) => item
                    case None => return codecError("running model continuation has no checkpoint")
                }
                Result.Ok(RunContinuation(
                    RunContinuationKind.RunningModel,
                    RunId(runId), SessionId(sessionId), model, prompt,
                    checkpoint, policy, capabilitiesSnapshot,
                    system: system, thinking: thinking,
                    capabilities: CapabilitySet(values: capabilities.toArray()),
                    budget: budget, approvalMode: approvalMode, autoRetry: autoRetry,
                    serviceTier: serviceTier, pricing: pricing,
                    imageInputs: imageInputs.toArray(), structuredOutput: structuredOutput,
                    cachePolicy: cachePolicy, cacheKey: cacheKey,
                    parallelToolCalls: parallelToolCalls,
                    resolverVersion: UInt32(resolverVersion), skillStackPayload: skillStack,
                    contextWindow: contextWindow, providerSafetyMargin: safetyMargin,
                    toolContextPayload: toolContext
                ))
        }
    } catch (error: Exception) {
        codecError("invalid run continuation: " + error.message)
    }
}

func encodeDecisionReceipt(receipt: ApprovalDecisionReceipt): String {
    encodeAgentValue(objectValue([
        ValueField("version", integerValue(1)),
        ValueField("operation_id", textValue(receipt.operationId.value)),
        ValueField("run_id", textValue(receipt.runId.value)),
        ValueField("session_id", textValue(receipt.sessionId.value)),
        ValueField("call_id", textValue(receipt.callId)),
        ValueField("argument_hash", textValue(receipt.argumentHash)),
        ValueField("decision", approvalDecisionValue(receipt.decision))
    ]))
}

func decodeDecisionReceipt(source: String): Result<ApprovalDecisionReceipt> {
    let value = match (decodeAgentValue(source, maxBytes: 67108864)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (value.kind != ValueKind.Object) {
        return codecError("approval decision receipt must be an object")
    }
    let version = match (requiredInteger(value, "version")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (version != 1) {
        return codecError("unsupported approval decision receipt version")
    }
    let operationId = match (requiredNonEmptyText(value, "operation_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let runId = match (requiredNonEmptyText(value, "run_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let sessionId = match (requiredNonEmptyText(value, "session_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let callId = match (requiredNonEmptyText(value, "call_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let argumentHash = match (requiredNonEmptyText(value, "argument_hash")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let decision = match (value.field("decision")) {
        case Some(raw) => match (approvalDecisionFromValue(raw)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        case None => return codecError("missing field: decision")
    }
    try {
        Result.Ok(ApprovalDecisionReceipt(
            OperationId(operationId),
            RunId(runId),
            SessionId(sessionId),
            callId,
            argumentHash,
            decision
        ))
    } catch (error: Exception) {
        codecError("invalid approval decision receipt: " + error.message)
    }
}

func budgetValue(value: ResourceBudget): AgentValue {
    objectValue([
        ValueField("max_input_tokens", integerValue(value.maxInputTokens)),
        ValueField("max_output_tokens", integerValue(value.maxOutputTokens)),
        ValueField("max_model_requests", integerValue(value.maxModelRequests)),
        ValueField("max_turns", integerValue(value.maxTurns)),
        ValueField("max_tool_calls", integerValue(value.maxToolCalls)),
        ValueField("max_wall_millis", integerValue(value.maxWallMillis)),
        ValueField("max_idle_millis", integerValue(value.maxIdleMillis)),
        ValueField("max_children", integerValue(value.maxChildren)),
        ValueField("max_depth", integerValue(value.maxDepth)),
        ValueField("max_concurrent_children", integerValue(value.maxConcurrentChildren)),
        ValueField("max_context_messages", integerValue(value.maxContextMessages))
    ])
}

func pricingValue(value: ModelPricing): AgentValue {
    objectValue([
        ValueField("input_micros_per_million", optionalIntegerValue(value.inputMicrosPerMillion)),
        ValueField("output_micros_per_million", optionalIntegerValue(value.outputMicrosPerMillion)),
        ValueField("cache_read_micros_per_million", optionalIntegerValue(value.cacheReadMicrosPerMillion)),
        ValueField("cache_write_micros_per_million", optionalIntegerValue(value.cacheWriteMicrosPerMillion))
    ])
}

func optionalIntegerValue(value: ?Int64): AgentValue {
    match (value) {
        case Some(number) => integerValue(number)
        case None => nullValue()
    }
}

func strictPricingFromValue(value: AgentValue): Result<ModelPricing> {
    if (value.kind != ValueKind.Object) {
        return codecError("field is not an object: pricing")
    }
    let input = match (strictOptionalInteger(value, "input_micros_per_million")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let output = match (strictOptionalInteger(value, "output_micros_per_million")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let cacheRead = match (strictOptionalInteger(value, "cache_read_micros_per_million")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let cacheWrite = match (strictOptionalInteger(value, "cache_write_micros_per_million")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(ModelPricing(
            inputMicrosPerMillion: input,
            outputMicrosPerMillion: output,
            cacheReadMicrosPerMillion: cacheRead,
            cacheWriteMicrosPerMillion: cacheWrite
        ))
    } catch (error: Exception) {
        codecError("invalid run continuation pricing: " + error.message)
    }
}

func strictOptionalInteger(
    value: AgentValue,
    name: String
): Result<?Int64> {
    match (value.field(name)) {
        case Some(raw) => match (raw.kind) {
            case ValueKind.Null => Result.Ok(None)
            case ValueKind.Number => try {
                Result.Ok(Some(Int64.parse(raw.number)))
            } catch (_: Exception) {
                codecError("field is not an integer: " + name)
            }
            case _ => codecError("field is not an integer or null: " + name)
        }
        case None => codecError("missing field: " + name)
    }
}

func strictBudgetFromValue(value: AgentValue): Result<ResourceBudget> {
    if (value.kind != ValueKind.Object) {
        return codecError("field is not an object: budget")
    }
    let input = match (requiredInteger(value, "max_input_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let output = match (requiredInteger(value, "max_output_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let requests = match (requiredInteger(value, "max_model_requests")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let turns = match (requiredInteger(value, "max_turns")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let tools = match (requiredInteger(value, "max_tool_calls")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let wall = match (requiredInteger(value, "max_wall_millis")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let idle = match (requiredInteger(value, "max_idle_millis")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let children = match (requiredInteger(value, "max_children")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let depth = match (requiredInteger(value, "max_depth")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let concurrent = match (requiredInteger(value, "max_concurrent_children")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let contextMessages = match (requiredInteger(value, "max_context_messages")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(ResourceBudget(
            maxInputTokens: input,
            maxOutputTokens: output,
            maxModelRequests: requests,
            maxTurns: turns,
            maxToolCalls: tools,
            maxWallMillis: wall,
            maxIdleMillis: idle,
            maxChildren: children,
            maxDepth: depth,
            maxConcurrentChildren: concurrent,
            maxContextMessages: contextMessages
        ))
    } catch (error: Exception) {
        codecError("invalid run continuation budget: " + error.message)
    }
}

func approvalRequestValue(value: ApprovalRequest): AgentValue {
    objectValue([
        ValueField("operation_id", textValue(value.operationId.value)),
        ValueField("call_id", textValue(value.callId)),
        ValueField("tool_name", textValue(value.toolName)),
        ValueField("capability", capabilityValue(value.capability)),
        ValueField("preview", value.preview),
        ValueField("session_id", textValue(value.sessionId)),
        ValueField("argument_hash", textValue(value.argumentHash)),
        ValueField("risk_flags", stringListValue(value.riskFlags)),
        ValueField("review", match (value.review) {
            case Some(review) => approvalReviewValue(review)
            case None => nullValue()
        }),
        ValueField("metadata", approvalMetadataValue(value.metadata)),
        ValueField("decision_source", textValue(decisionSourceName(value.decisionSource)))
    ])
}

func approvalRequestBindingValue(value: ApprovalRequest): AgentValue {
    objectValue([
        ValueField("operation_id", textValue(value.operationId.value)),
        ValueField("call_id", textValue(value.callId)),
        ValueField("tool_name", textValue(value.toolName)),
        ValueField("capability", capabilityValue(value.capability)),
        ValueField("preview", value.preview),
        ValueField("session_id", textValue(value.sessionId)),
        ValueField("argument_hash", textValue(value.argumentHash)),
        ValueField("risk_flags", stringListValue(value.riskFlags)),
        ValueField("metadata", approvalMetadataValue(value.metadata))
    ])
}

// Continuations are an authority-bearing recovery boundary. Keep the generic
// record decoders compatible, but reject any missing, mistyped, or unknown
// approval semantics here.
func strictApprovalRequestFromValue(
    value: AgentValue
): Result<ApprovalRequest> {
    if (value.kind != ValueKind.Object) {
        return codecError("approval request must be an object")
    }
    let operationId = match (requiredNonEmptyText(value, "operation_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let callId = match (requiredNonEmptyText(value, "call_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let toolName = match (requiredNonEmptyText(value, "tool_name")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let capability = match (value.field("capability")) {
        case Some(raw) => match (strictCapabilityFrom(raw)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        case None => return codecError("missing field: approval.capability")
    }
    let preview = match (value.field("preview")) {
        case Some(raw) => raw
        case None => return codecError("missing field: approval.preview")
    }
    let sessionId = match (requiredNonEmptyText(value, "session_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let argumentHash = match (requiredNonEmptyText(value, "argument_hash")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let riskFlags = match (requiredStringList(value, "risk_flags")) {
        case Result.Ok(items) => items
        case Result.Err(error) => return Result.Err(error)
    }
    let review: ?ApprovalReview = match (value.field("review")) {
        case Some(raw) =>
            if (raw.kind == ValueKind.Null) {
                None
            } else {
                match (validateStrictApprovalReview(raw)) {
                    case Result.Ok(_) => Some(approvalReviewFromValue(raw))
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        case None => return codecError("missing field: approval.review")
    }
    let metadata = match (value.field("metadata")) {
        case Some(raw) => match (validateStrictApprovalMetadata(raw)) {
            case Result.Ok(_) => approvalMetadataFromValue(raw, capability)
            case Result.Err(error) => return Result.Err(error)
        }
        case None => return codecError("missing field: approval.metadata")
    }
    let decisionSource = match (requiredDecisionSource(
        value,
        "decision_source"
    )) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(ApprovalRequest(
        OperationId(operationId),
        callId,
        toolName,
        capability,
        preview: preview,
        sessionId: sessionId,
        argumentHash: argumentHash,
        riskFlags: riskFlags,
        review: review,
        metadata: metadata,
        decisionSource: decisionSource
    ))
}

func validateStrictApprovalReview(value: AgentValue): Result<Unit> {
    if (value.kind != ValueKind.Object) {
        return codecError("approval review must be an object")
    }
    let decision = match (requiredText(value, "decision")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (decision != "approve" && decision != "deny" &&
        decision != "ask_user") {
        return codecError("unknown approval review decision")
    }
    match (requiredText(value, "reason")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (requiredText(value, "risk_level")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (requiredText(value, "reviewer_model")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (requiredInteger(value, "latency_millis")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (requiredText(value, "failure_type")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (requiredStringList(value, "approved_capabilities")) {
        case Result.Ok(_) => Result.Ok(())
        case Result.Err(error) => Result.Err(error)
    }
}

func validateStrictApprovalMetadata(value: AgentValue): Result<Unit> {
    if (value.kind != ValueKind.Object) {
        return codecError("approval metadata must be an object")
    }
    match (requiredText(value, "capability_label")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let assessment = match (requiredObject(value, "assessment")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let level = match (requiredText(assessment, "level")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (level != "low" && level != "medium" && level != "high" &&
        level != "critical") {
        return codecError("unknown approval risk level")
    }
    match (requiredStringList(assessment, "flags")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (requiredStringList(assessment, "reasons")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let scope = match (requiredObject(value, "grant_scope")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    for (name in ["capability", "path_prefix", "tool_name", "host"]) {
        match (requiredText(scope, name)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    match (requiredBoolean(scope, "session_only")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (value.field("write_summary")) {
        case Some(raw) =>
            if (raw.kind == ValueKind.Null) {
                Result.Ok(())
            } else {
                validateStrictWriteSummary(raw)
            }
        case None => codecError("missing field: approval.metadata.write_summary")
    }
}

func validateStrictWriteSummary(value: AgentValue): Result<Unit> {
    if (value.kind != ValueKind.Object) {
        return codecError("approval write summary must be an object")
    }
    for (name in ["path", "action", "language", "content_hash"]) {
        match (requiredText(value, name)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    for (name in [
        "bytes",
        "lines",
        "before_bytes",
        "added_lines",
        "removed_lines"
    ]) {
        match (requiredInteger(value, name)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    match (requiredBoolean(value, "exists")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (requiredBoolean(value, "truncated")) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (requiredStringList(value, "preview")) {
        case Result.Ok(_) => Result.Ok(())
        case Result.Err(error) => Result.Err(error)
    }
}

func approvalReviewValue(value: ApprovalReview): AgentValue {
    objectValue([
        ValueField("decision", textValue(reviewDecisionName(value.decision))),
        ValueField("reason", textValue(value.reason)),
        ValueField("risk_level", textValue(value.riskLevel)),
        ValueField("reviewer_model", textValue(value.reviewerModel)),
        ValueField("latency_millis", integerValue(value.latencyMillis)),
        ValueField("failure_type", textValue(value.failureType)),
        ValueField("approved_capabilities", stringListValue(value.approvedCapabilities))
    ])
}

func approvalReviewFromValue(value: AgentValue): ApprovalReview {
    ApprovalReview(
        reviewDecisionFrom(textOr(value, "decision")),
        textOr(value, "reason"),
        textOr(value, "risk_level"),
        textOr(value, "reviewer_model"),
        latencyMillis: integerOr(value, "latency_millis"),
        failureType: textOr(value, "failure_type"),
        approvedCapabilities: stringListFrom(value, "approved_capabilities")
    )
}

func approvalMetadataValue(value: ToolApprovalMetadata): AgentValue {
    objectValue([
        ValueField("capability_label", textValue(value.capabilityLabel)),
        ValueField("assessment", objectValue([
            ValueField("level", textValue(riskLevelName(value.assessment.level))),
            ValueField("flags", stringListValue(value.assessment.flags)),
            ValueField("reasons", stringListValue(value.assessment.reasons))
        ])),
        ValueField("grant_scope", objectValue([
            ValueField("capability", textValue(value.grantScope.capability)),
            ValueField("path_prefix", textValue(value.grantScope.pathPrefix)),
            ValueField("tool_name", textValue(value.grantScope.toolName)),
            ValueField("host", textValue(value.grantScope.host)),
            ValueField("session_only", boolValue(value.grantScope.sessionOnly))
        ])),
        ValueField("write_summary", match (value.writeSummary) {
            case Some(summary) => writeSummaryValue(summary)
            case None => nullValue()
        })
    ])
}

func approvalMetadataFromValue(value: AgentValue, capability: Capability): ToolApprovalMetadata {
    let fallback = defaultToolApprovalMetadata(capability)
    let assessment = match (value.field("assessment")) {
        case Some(raw) => RiskAssessment(
            riskLevelFrom(textOr(raw, "level")),
            flags: stringListFrom(raw, "flags"),
            reasons: stringListFrom(raw, "reasons")
        )
        case None => fallback.assessment
    }
    let scope = match (value.field("grant_scope")) {
        case Some(raw) => ApprovalGrantScope(
            textOr(raw, "capability"),
            pathPrefix: textOr(raw, "path_prefix"),
            toolName: textOr(raw, "tool_name"),
            host: textOr(raw, "host"),
            sessionOnly: boolOrDefault(raw, "session_only", true)
        )
        case None => fallback.grantScope
    }
    let summary: ?WriteApprovalSummary = match (value.field("write_summary")) {
        case Some(raw) => if (raw.kind == ValueKind.Null) {
            None
        } else {
            Some(writeSummaryFromValue(raw))
        }
        case None => None
    }
    ToolApprovalMetadata(
        if (textOr(value, "capability_label") == "") {
            fallback.capabilityLabel
        } else {
            textOr(value, "capability_label")
        },
        assessment,
        scope,
        writeSummary: summary
    )
}

func writeSummaryValue(value: WriteApprovalSummary): AgentValue {
    objectValue([
        ValueField("path", textValue(value.path)),
        ValueField("action", textValue(value.action)),
        ValueField("exists", boolValue(value.exists)),
        ValueField("bytes", integerValue(value.bytes)),
        ValueField("lines", integerValue(value.lines)),
        ValueField("language", textValue(value.language)),
        ValueField("preview", stringListValue(value.preview)),
        ValueField("truncated", boolValue(value.truncated)),
        ValueField("content_hash", textValue(value.contentHash)),
        ValueField("before_bytes", integerValue(value.beforeBytes)),
        ValueField("added_lines", integerValue(value.addedLines)),
        ValueField("removed_lines", integerValue(value.removedLines))
    ])
}

func writeSummaryFromValue(value: AgentValue): WriteApprovalSummary {
    WriteApprovalSummary(
        textOr(value, "path"),
        textOr(value, "action"),
        boolOr(value, "exists"),
        integerOr(value, "bytes"),
        integerOr(value, "lines"),
        language: textOr(value, "language"),
        preview: stringListFrom(value, "preview"),
        truncated: boolOr(value, "truncated"),
        contentHash: textOr(value, "content_hash"),
        beforeBytes: integerOr(value, "before_bytes"),
        addedLines: integerOr(value, "added_lines"),
        removedLines: integerOr(value, "removed_lines")
    )
}

func approvalDecisionValue(value: ApprovalDecision): AgentValue {
    match (value) {
        case ApprovalDecision.Approve => objectValue([ValueField("kind", textValue("approve"))])
        case ApprovalDecision.ApproveSession => objectValue([ValueField("kind", textValue("approve_session"))])
        case ApprovalDecision.Reject => objectValue([ValueField("kind", textValue("reject"))])
        case ApprovalDecision.RejectWithReason(reason) => objectValue([
            ValueField("kind", textValue("reject_with_reason")),
            ValueField("reason", textValue(reason))
        ])
    }
}

func approvalDecisionFromValue(value: AgentValue): Result<ApprovalDecision> {
    match (textOr(value, "kind")) {
        case "approve" => Result.Ok(ApprovalDecision.Approve)
        case "approve_session" => Result.Ok(ApprovalDecision.ApproveSession)
        case "reject" => Result.Ok(ApprovalDecision.Reject)
        case "reject_with_reason" => match (requiredNonEmptyText(
            value,
            "reason"
        )) {
            case Result.Ok(reason) => Result.Ok(
                ApprovalDecision.RejectWithReason(reason)
            )
            case Result.Err(error) => Result.Err(error)
        }
        case _ => codecError("unknown approval decision")
    }
}

func stringListValue(values: Array<String>): AgentValue {
    let result = ArrayList<AgentValue>()
    for (value in values) {
        result.add(textValue(value))
    }
    listValue(result.toArray())
}

func stringListFrom(value: AgentValue, name: String): Array<String> {
    let result = ArrayList<String>()
    match (value.field(name)) {
        case Some(raw) => for (item in raw.items where item.kind == ValueKind.Text) {
            result.add(item.text)
        }
        case None => ()
    }
    result.toArray()
}

func encodeEvent(event: AgentEvent): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField("format_version", integerValue(RUN_EVENT_FORMAT_VERSION)),
                ValueField("sequence", integerValue(event.sequence)),
                ValueField("run_id", textValue(event.runId.value)),
                ValueField("kind", textValue(eventKindName(event.kind))),
                ValueField("timestamp_ms", integerValue(event.meta.occurredAtMillis)),
                ValueField("trace_id", textValue(event.meta.traceId.value)),
                ValueField("turn_id", eventOptionalTurnIdValue(event.meta.turnId)),
                ValueField("request_id", eventOptionalRequestIdValue(event.meta.requestId)),
                ValueField("tool_batch_id", eventOptionalToolBatchIdValue(event.meta.toolBatchId)),
                ValueField("tool_call_id", eventOptionalToolCallIdValue(event.meta.toolCallId)),
                ValueField("operation_id", eventOptionalOperationIdValue(event.meta.operationId)),
                ValueField("payload_type", textValue(eventPayloadName(event.payload))),
                ValueField("detail", event.detail)
            ]
        )
    )
}

func eventOptionalTurnIdValue(value: ?TurnId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventOptionalRequestIdValue(value: ?RequestId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventOptionalToolBatchIdValue(value: ?ToolBatchId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventOptionalToolCallIdValue(value: ?ToolCallId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventOptionalOperationIdValue(value: ?OperationId): AgentValue {
    match (value) {
        case Some(item) => textValue(item.value)
        case None => nullValue()
    }
}

func eventPayloadName(payload: AgentEventPayload): String {
    match (payload) {
        case AgentEventPayload.RunStarted => "run_started"
        case AgentEventPayload.RunStateChanged(_, _, _) => "run_state_changed"
        case AgentEventPayload.AssistantStarted(_) => "assistant_started"
        case AgentEventPayload.TextDelta(_) => "text_delta"
        case AgentEventPayload.ReasoningDelta(_) => "reasoning_delta"
        case AgentEventPayload.ModelUsageUpdated(_) => "model_usage_updated"
        case AgentEventPayload.ModelRequestAttemptCompleted(_) =>
            "model_request_attempt_completed"
        case AgentEventPayload.ToolStarted(_, _, _) => "tool_started"
        case AgentEventPayload.ToolOutput(_, _, _) => "tool_output"
        case AgentEventPayload.ToolCompleted(_, _, _) => "tool_completed"
        case AgentEventPayload.ApprovalRequested(_, _) => "approval_requested"
        case AgentEventPayload.BudgetUpdated(_) => "budget_updated"
        case AgentEventPayload.ContextCompacted(_, _) => "context_compacted"
        case AgentEventPayload.Diagnostic(_) => "diagnostic"
        case AgentEventPayload.Audit(_, _) => "audit"
        case AgentEventPayload.Transcript(_) => "transcript"
        case AgentEventPayload.StructuredOutputCompleted(_) =>
            "structured_output_completed"
        case AgentEventPayload.TurnCompleted(_) => "turn_completed"
        case AgentEventPayload.RunCompleted => "run_completed"
        case AgentEventPayload.Extension(_, _) => "extension"
    }
}

func encodeOperation(operation: OperationRecord): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField(
                    "operation_id",
                    textValue(operation.operationId.value)
                ),
                ValueField("run_id", textValue(operation.runId.value)),
                ValueField("status", textValue(operationStatusName(operation.status))),
                ValueField("capability", capabilityValue(operation.capability)),
                ValueField("request_digest", textValue(operation.requestDigest)),
                ValueField("call", match (operation.call) {
                    case Some(call) => toolCallValue(call)
                    case None => nullValue()
                })
            ]
        )
    )
}

func decodeOperation(source: String): Result<OperationRecord> {
    let value = match (decodeAgentValue(source, maxBytes: 67108864)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let status = match (operationStatusFrom(textOr(value, "status"))) {
        case Some(item) => item
        case None => return codecError("unknown operation status")
    }
    let capability = match (value.field("capability")) {
        case Some(raw) => capabilityFrom(raw)
        case None => Capability(CapabilityKind.WorkspaceRead)
    }
    let call: ?ToolCall = match (value.field("call")) {
        case Some(raw) =>
            if (raw.kind == ValueKind.Null) {
                None
            } else {
                Some(toolCallFrom(raw))
            }
        case None => None
    }
    Result.Ok(
        OperationRecord(
            OperationId(textOr(value, "operation_id")),
            RunId(textOr(value, "run_id")),
            status,
            capability,
            textOr(value, "request_digest"),
            call: call
        )
    )
}

func encodeReceipt(receipt: OperationReceipt): String {
    encodeAgentValue(
        objectValue(
            [
                ValueField(
                    "operation_id",
                    textValue(receipt.operationId.value)
                ),
                ValueField("committed", boolValue(receipt.committed)),
                ValueField("is_error", boolValue(receipt.isError)),
                ValueField("detail", receipt.detail)
            ]
        )
    )
}

func decodeReceipt(source: String): Result<OperationReceipt> {
    let value = match (decodeAgentValue(source, maxBytes: 67108864)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(
        OperationReceipt(
            OperationId(textOr(value, "operation_id")),
            boolOr(value, "committed"),
            match (value.field("detail")) {
                case Some(item) => item
                case None => objectValue([])
            },
            isError: boolOr(value, "is_error")
        )
    )
}

func toolCallValue(call: ToolCall): AgentValue {
    objectValue(
        [
            ValueField("call_id", textValue(call.callId)),
            ValueField("name", textValue(call.name)),
            ValueField("arguments", call.arguments)
        ]
    )
}

func toolCallFrom(value: AgentValue): ToolCall {
    ToolCall(
        textOr(value, "call_id"),
        textOr(value, "name"),
        match (value.field("arguments")) {
            case Some(item) => item
            case None => objectValue([])
        }
    )
}

func capabilityValue(capability: Capability): AgentValue {
    objectValue(
        [
            ValueField("kind", textValue(capabilityKindName(capability.kind))),
            ValueField("resource", textValue(capability.resource))
        ]
    )
}

func capabilityFrom(value: AgentValue): Capability {
    Capability(
        capabilityKindFrom(textOr(value, "kind")),
        resource: textOr(value, "resource")
    )
}

func strictCapabilityFrom(value: AgentValue): Result<Capability> {
    if (value.kind != ValueKind.Object) {
        return codecError("capability must be an object")
    }
    let kind = match (requiredText(value, "kind")) {
        case Result.Ok(item) => match (item) {
            case "workspace_read" => CapabilityKind.WorkspaceRead
            case "workspace_write" => CapabilityKind.WorkspaceWrite
            case "process_spawn" => CapabilityKind.ProcessSpawn
            case "network_access" => CapabilityKind.NetworkAccess
            case "peer_message" => CapabilityKind.PeerMessage
            case "delegate" => CapabilityKind.Delegate
            case "extension_invoke" => CapabilityKind.ExtensionInvoke
            case _ => return codecError("unknown capability kind")
        }
        case Result.Err(error) => return Result.Err(error)
    }
    let resource = match (requiredText(value, "resource")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    Result.Ok(Capability(kind, resource: resource))
}

func decodeEventLines(source: String): Result<Array<AgentEvent>> {
    let events = ArrayList<AgentEvent>()
    for (line in source.split("\n") where line.trimAscii() != "") {
        let value = match (decodeAgentValue(
            line,
            maxBytes: 67108864
        )) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        let event = match (decodeCurrentEvent(value)) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        events.add(event)
    }
    Result.Ok(events.toArray())
}

func decodeCurrentEvent(value: AgentValue): Result<AgentEvent> {
    if (value.kind != ValueKind.Object) {
        return codecError("run event must be an object")
    }
    let formatVersion = match (requiredInteger(value, "format_version")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (formatVersion != RUN_EVENT_FORMAT_VERSION) {
        return codecError("unsupported run event format version")
    }
    let sequence = match (requiredInteger(value, "sequence")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let runId = match (requiredNonEmptyText(value, "run_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let kind = match (requiredText(value, "kind")) {
        case Result.Ok(raw) => match (eventKindFrom(raw)) {
            case Some(item) => item
            case None => return codecError("unknown event kind")
        }
        case Result.Err(error) => return Result.Err(error)
    }
    let timestamp = match (requiredInteger(value, "timestamp_ms")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let traceId = match (requiredNonEmptyText(value, "trace_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let turnId = match (requiredOptionalEventText(value, "turn_id")) {
        case Result.Ok(Some(item)) => Some(TurnId(item))
        case Result.Ok(None) => None<TurnId>
        case Result.Err(error) => return Result.Err(error)
    }
    let requestId = match (requiredOptionalEventText(value, "request_id")) {
        case Result.Ok(Some(item)) => Some(RequestId(item))
        case Result.Ok(None) => None<RequestId>
        case Result.Err(error) => return Result.Err(error)
    }
    let toolBatchId = match (requiredOptionalEventText(value, "tool_batch_id")) {
        case Result.Ok(Some(item)) => Some(ToolBatchId(item))
        case Result.Ok(None) => None<ToolBatchId>
        case Result.Err(error) => return Result.Err(error)
    }
    let toolCallId = match (requiredOptionalEventText(value, "tool_call_id")) {
        case Result.Ok(Some(item)) => Some(ToolCallId(item))
        case Result.Ok(None) => None<ToolCallId>
        case Result.Err(error) => return Result.Err(error)
    }
    let operationId = match (requiredOptionalEventText(value, "operation_id")) {
        case Result.Ok(Some(item)) => Some(OperationId(item))
        case Result.Ok(None) => None<OperationId>
        case Result.Err(error) => return Result.Err(error)
    }
    let payloadType = match (requiredNonEmptyText(value, "payload_type")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let detail = match (value.field("detail")) {
        case Some(item) => item
        case None => return codecError("missing field: detail")
    }
    let payload = match (decodeEventPayload(payloadType, kind, detail)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (eventKind(payload) != kind) {
        return codecError("run event kind does not match its typed payload")
    }
    match (payload) {
        case AgentEventPayload.ModelRequestAttemptCompleted(attempt) =>
            match (requestId) {
                case Some(metaId) => if (metaId.value != attempt.requestId.value) {
                    return codecError("model attempt request id does not match event metadata")
                }
                case None => return codecError("model attempt event requires request metadata")
            }
        case _ => ()
    }
    try {
        Result.Ok(AgentEvent(
            EventMeta(
                sequence,
                TraceId(traceId),
                RunId(runId),
                occurredAtMillis: timestamp,
                turnId: turnId,
                requestId: requestId,
                toolBatchId: toolBatchId,
                toolCallId: toolCallId,
                operationId: operationId
            ),
            payload
        ))
    } catch (error: Exception) {
        codecError(error.message)
    }
}

func requiredOptionalEventText(
    value: AgentValue,
    name: String
): Result<?String> {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Null) {
                Result.Ok(None)
            } else if (item.kind == ValueKind.Text &&
                item.text.trimAscii() != "") {
                Result.Ok(Some(item.text))
            } else {
                codecError("event id must be non-empty text or null: " + name)
            }
        case None => codecError("missing field: " + name)
    }
}

func decodeEventPayload(
    payloadType: String,
    kind: AgentEventKind,
    detail: AgentValue
): Result<AgentEventPayload> {
    match (payloadType) {
        case "run_started" => Result.Ok(AgentEventPayload.RunStarted)
        case "run_state_changed" =>
            let from = match (requiredRunState(detail, "from")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let to = match (requiredRunState(detail, "to")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let reason = match (requiredText(detail, "reason")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            Result.Ok(AgentEventPayload.RunStateChanged(from, to, reason))
        case "assistant_started" => match (requiredNonEmptyText(detail, "request_id")) {
            case Result.Ok(item) => Result.Ok(
                AgentEventPayload.AssistantStarted(RequestId(item))
            )
            case Result.Err(error) => Result.Err(error)
        }
        case "text_delta" => match (requiredText(detail, "text")) {
            case Result.Ok(item) => Result.Ok(AgentEventPayload.TextDelta(item))
            case Result.Err(error) => Result.Err(error)
        }
        case "reasoning_delta" => match (requiredText(detail, "reasoning")) {
            case Result.Ok(item) => Result.Ok(AgentEventPayload.ReasoningDelta(item))
            case Result.Err(error) => Result.Err(error)
        }
        case "model_usage_updated" => match (requiredModelUsage(detail)) {
            case Result.Ok(item) => Result.Ok(AgentEventPayload.ModelUsageUpdated(item))
            case Result.Err(error) => Result.Err(error)
        }
        case "model_request_attempt_completed" =>
            match (requiredModelRequestAttempt(detail)) {
                case Result.Ok(item) => Result.Ok(
                    AgentEventPayload.ModelRequestAttemptCompleted(item)
                )
                case Result.Err(error) => Result.Err(error)
            }
        case "tool_started" =>
            let callId = match (requiredNonEmptyText(detail, "call_id")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let name = match (requiredNonEmptyText(detail, "name")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let index = match (requiredInteger(detail, "call_index")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            Result.Ok(AgentEventPayload.ToolStarted(ToolCallId(callId), name, index))
        case "tool_output" =>
            let callId = match (requiredNonEmptyText(detail, "call_id")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let channel = match (requiredToolOutputChannel(detail, "channel")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let delta = match (requiredText(detail, "delta")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            Result.Ok(AgentEventPayload.ToolOutput(ToolCallId(callId), channel, delta))
        case "tool_completed" =>
            let callId = match (requiredNonEmptyText(detail, "call_id")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let succeeded = match (requiredBoolean(detail, "succeeded")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let index = match (requiredInteger(detail, "call_index")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            Result.Ok(AgentEventPayload.ToolCompleted(ToolCallId(callId), succeeded, index))
        case "approval_requested" =>
            let operation = match (requiredNonEmptyText(detail, "operation_id")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let call = match (requiredNonEmptyText(detail, "call_id")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            Result.Ok(AgentEventPayload.ApprovalRequested(
                OperationId(operation),
                ToolCallId(call)
            ))
        case "budget_updated" => match (requiredExecutionUsage(detail)) {
            case Result.Ok(item) => Result.Ok(AgentEventPayload.BudgetUpdated(item))
            case Result.Err(error) => Result.Err(error)
        }
        case "context_compacted" =>
            let before = match (requiredInteger(detail, "before_tokens")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            let after = match (requiredInteger(detail, "after_tokens")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            Result.Ok(AgentEventPayload.ContextCompacted(before, after))
        case "diagnostic" => match (strictErrorFrom(detail)) {
            case Result.Ok(item) => Result.Ok(AgentEventPayload.Diagnostic(item))
            case Result.Err(error) => Result.Err(error)
        }
        case "audit" =>
            let action = match (requiredNonEmptyText(detail, "action")) {
                case Result.Ok(item) => item
                case Result.Err(error) => return Result.Err(error)
            }
            match (detail.field("detail")) {
                case Some(item) => Result.Ok(AgentEventPayload.Audit(action, item))
                case None => codecError("missing field: detail")
            }
        case "transcript" => Result.Ok(AgentEventPayload.Transcript(detail))
        case "structured_output_completed" => match (detail.field("value")) {
            case Some(item) => Result.Ok(
                AgentEventPayload.StructuredOutputCompleted(item)
            )
            case None => codecError("missing field: value")
        }
        case "turn_completed" => match (requiredNonEmptyText(detail, "turn_id")) {
            case Result.Ok(item) => Result.Ok(
                AgentEventPayload.TurnCompleted(TurnId(item))
            )
            case Result.Err(error) => Result.Err(error)
        }
        case "run_completed" => Result.Ok(AgentEventPayload.RunCompleted)
        case "extension" => Result.Ok(AgentEventPayload.Extension(kind, detail))
        case _ => codecError("unknown run event payload type")
    }
}

func requiredRunState(value: AgentValue, name: String): Result<RunState> {
    let raw = match (requiredText(value, name)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    match (raw) {
        case "idle" => Result.Ok(RunState.Created)
        case "created" => Result.Ok(RunState.Created)
        case "running" => Result.Ok(RunState.Running)
        case "waiting_approval" => Result.Ok(RunState.WaitingApproval)
        case "waiting_external" => Result.Ok(RunState.WaitingExternal)
        case "cancelling" => Result.Ok(RunState.Cancelling)
        case "cancelled" => Result.Ok(RunState.Cancelled)
        case "completed" => Result.Ok(RunState.Completed)
        case "failed" => Result.Ok(RunState.Failed)
        case "recovery_required" => Result.Ok(RunState.RecoveryRequired)
        case _ => codecError("unknown run state")
    }
}

func requiredToolOutputChannel(
    value: AgentValue,
    name: String
): Result<ToolOutputChannel> {
    let raw = match (requiredText(value, name)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    match (raw) {
        case "stdout" => Result.Ok(ToolOutputChannel.Stdout)
        case "stderr" => Result.Ok(ToolOutputChannel.Stderr)
        case "artifact" => Result.Ok(ToolOutputChannel.Artifact)
        case "summary" => Result.Ok(ToolOutputChannel.Summary)
        case _ => codecError("unknown tool output channel")
    }
}

func requiredModelUsage(value: AgentValue): Result<ModelUsage> {
    let input = match (requiredInteger(value, "input_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let output = match (requiredInteger(value, "output_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let reasoning = match (requiredInteger(value, "reasoning_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let cacheRead = match (requiredInteger(value, "cache_read_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let cacheWrite = match (requiredInteger(value, "cache_write_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let cost = match (requiredOptionalInteger(value, "cost_micros")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(ModelUsage(
            inputTokens: input,
            outputTokens: output,
            reasoningTokens: reasoning,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            costMicros: cost
        ))
    } catch (error: Exception) {
        codecError(error.message)
    }
}

func requiredModelRequestAttempt(
    value: AgentValue
): Result<ModelRequestAttempt> {
    let requestId = match (requiredNonEmptyText(value, "request_id")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let model = match (requiredNonEmptyText(value, "model")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let attempt = match (requiredInteger(value, "attempt")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let outcome = match (requiredText(value, "outcome")) {
        case Result.Ok("succeeded") => ModelRequestOutcome.Succeeded
        case Result.Ok("failed") => ModelRequestOutcome.Failed
        case Result.Ok("cancelled") => ModelRequestOutcome.Cancelled
        case Result.Ok(_) => return codecError("unknown model request outcome")
        case Result.Err(error) => return Result.Err(error)
    }
    let usage: ?ModelUsage = match (value.field("usage")) {
        case Some(item) =>
            if (item.kind == ValueKind.Null) {
                None
            } else {
                match (requiredModelUsage(item)) {
                    case Result.Ok(resolved) => Some(resolved)
                    case Result.Err(error) => return Result.Err(error)
                }
            }
        case None => return codecError("missing field: usage")
    }
    let errorCode = match (requiredText(value, "error_code")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(ModelRequestAttempt(
            RequestId(requestId),
            model,
            attempt,
            outcome,
            usage: usage,
            errorCode: errorCode
        ))
    } catch (error: Exception) {
        codecError(error.message)
    }
}

func requiredExecutionUsage(value: AgentValue): Result<ExecutionUsage> {
    let turns = match (requiredInteger(value, "turns")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let toolCalls = match (requiredInteger(value, "tool_calls")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let activeTools = match (requiredInteger(value, "active_tools")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let input = match (requiredInteger(value, "input_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let output = match (requiredInteger(value, "output_tokens")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let cost = match (requiredInteger(value, "cost_micros")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        Result.Ok(ExecutionUsage(
            turns: turns,
            toolCalls: toolCalls,
            activeTools: activeTools,
            inputTokens: input,
            outputTokens: output,
            costMicros: cost
        ))
    } catch (error: Exception) {
        codecError(error.message)
    }
}

func errorValue(error: AgentError): AgentValue {
    let fields = ArrayList<AgentValue>()
    for (field in error.fields) {
        fields.add(
            objectValue(
                [
                    ValueField("name", textValue(field.name)),
                    ValueField("value", textValue(field.value))
                ]
            )
        )
    }
    objectValue(
        [
            ValueField("kind", textValue(errorKindName(error.kind))),
            ValueField("code", textValue(error.code)),
            ValueField("message", textValue(error.message)),
            ValueField("retryable", boolValue(error.retryable)),
            ValueField("fallback_allowed", boolValue(error.fallbackAllowed)),
            ValueField("fields", listValue(fields.toArray()))
        ]
    )
}

func strictErrorFrom(value: AgentValue): Result<AgentError> {
    if (value.kind != ValueKind.Object) {
        return codecError("run snapshot error must be an object or null")
    }
    let rawKind = match (requiredText(value, "kind")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let kind = match (rawKind) {
        case "configuration" => AgentErrorKind.Configuration
        case "authentication" => AgentErrorKind.Authentication
        case "permission_denied" => AgentErrorKind.PermissionDenied
        case "invalid_input" => AgentErrorKind.InvalidInput
        case "rate_limited" => AgentErrorKind.RateLimited
        case "timeout" => AgentErrorKind.Timeout
        case "transport" => AgentErrorKind.Transport
        case "provider" => AgentErrorKind.Provider
        case "protocol" => AgentErrorKind.Protocol
        case "cancelled" => AgentErrorKind.Cancelled
        case "budget_exceeded" => AgentErrorKind.BudgetExceeded
        case "conflict" => AgentErrorKind.Conflict
        case "recovery_required" => AgentErrorKind.RecoveryRequired
        case "internal" => AgentErrorKind.Internal
        case _ => return codecError("unknown run snapshot error kind")
    }
    let code = match (requiredNonEmptyText(value, "code")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let message = match (requiredNonEmptyText(value, "message")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let retryable = match (requiredBoolean(value, "retryable")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let fallbackAllowed = match (requiredBoolean(value, "fallback_allowed")) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    let rawFields = match (requiredList(value, "fields")) {
        case Result.Ok(items) => items
        case Result.Err(error) => return Result.Err(error)
    }
    let fields = ArrayList<ErrorField>()
    for (field in rawFields) {
        if (field.kind != ValueKind.Object) {
            return codecError("run snapshot error field must be an object")
        }
        let name = match (requiredText(field, "name")) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        let fieldValue = match (requiredText(field, "value")) {
            case Result.Ok(item) => item
            case Result.Err(error) => return Result.Err(error)
        }
        fields.add(ErrorField(name, fieldValue))
    }
    try {
        Result.Ok(AgentError(
            kind,
            code,
            message,
            retryable: retryable,
            fallbackAllowed: fallbackAllowed,
            fields: fields.toArray()
        ))
    } catch (error: Exception) {
        codecError(error.message)
    }
}

func requiredText(value: AgentValue, name: String): Result<String> {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Text) {
                Result.Ok(item.text)
            } else {
                codecError("field is not text: " + name)
            }
        case None => codecError("missing field: " + name)
    }
}

func requiredNonEmptyText(
    value: AgentValue,
    name: String
): Result<String> {
    match (requiredText(value, name)) {
        case Result.Ok(item) =>
            if (item.trimAscii() == "") {
                codecError("field must not be empty: " + name)
            } else {
                Result.Ok(item)
            }
        case Result.Err(error) => Result.Err(error)
    }
}

func requiredBoolean(value: AgentValue, name: String): Result<Bool> {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Boolean) {
                Result.Ok(item.boolean)
            } else {
                codecError("field is not boolean: " + name)
            }
        case None => codecError("missing field: " + name)
    }
}

func requiredInteger(value: AgentValue, name: String): Result<Int64> {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind != ValueKind.Number) {
                return codecError("field is not an integer: " + name)
            }
            try {
                Result.Ok(Int64.parse(item.number))
            } catch (_: Exception) {
                codecError("field is not an integer: " + name)
            }
        case None => codecError("missing field: " + name)
    }
}

func requiredThinking(
    value: AgentValue,
    name: String
): Result<ThinkingLevel> {
    let raw = match (requiredText(value, name)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    match (raw) {
        case "off" => Result.Ok(ThinkingLevel.Off)
        case "minimal" => Result.Ok(ThinkingLevel.Minimal)
        case "low" => Result.Ok(ThinkingLevel.Low)
        case "medium" => Result.Ok(ThinkingLevel.Medium)
        case "high" => Result.Ok(ThinkingLevel.High)
        case "xhigh" => Result.Ok(ThinkingLevel.XHigh)
        case "max" => Result.Ok(ThinkingLevel.Max)
        case _ => codecError("unknown thinking level")
    }
}

func requiredApprovalMode(
    value: AgentValue,
    name: String
): Result<String> {
    let raw = match (requiredText(value, name)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    match (raw) {
        case "" | "always_ask" | "write" | "yolo" => Result.Ok(raw)
        case _ => codecError("unknown approval mode")
    }
}

func requiredDecisionSource(
    value: AgentValue,
    name: String
): Result<ApprovalDecisionSource> {
    let raw = match (requiredText(value, name)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    match (raw) {
        case "static_policy" => Result.Ok(ApprovalDecisionSource.StaticPolicy)
        case "session_grant" => Result.Ok(ApprovalDecisionSource.SessionGrant)
        case "ai_reviewer" => Result.Ok(ApprovalDecisionSource.AiReviewer)
        case "hard_deny" => Result.Ok(ApprovalDecisionSource.HardDeny)
        case "user" => Result.Ok(ApprovalDecisionSource.User)
        case _ => codecError("unknown approval decision source")
    }
}

func requiredList(value: AgentValue, name: String): Result<Array<AgentValue>> {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.List) {
                Result.Ok(item.items)
            } else {
                codecError("field is not a list: " + name)
            }
        case None => codecError("missing field: " + name)
    }
}

func requiredObject(value: AgentValue, name: String): Result<AgentValue> {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Object) {
                Result.Ok(item)
            } else {
                codecError("field is not an object: " + name)
            }
        case None => codecError("missing field: " + name)
    }
}

func requiredStringList(
    value: AgentValue,
    name: String
): Result<Array<String>> {
    let raw = match (requiredList(value, name)) {
        case Result.Ok(items) => items
        case Result.Err(error) => return Result.Err(error)
    }
    let result = ArrayList<String>()
    for (item in raw) {
        if (item.kind != ValueKind.Text) {
            return codecError("list field contains non-text value: " + name)
        }
        result.add(item.text)
    }
    Result.Ok(result.toArray())
}

func textOr(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func boolOr(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => item.kind == ValueKind.Boolean && item.boolean
        case None => false
    }
}

func boolOrDefault(value: AgentValue, name: String, fallback: Bool): Bool {
    match (value.field(name)) {
        case Some(item) => if (item.kind == ValueKind.Boolean) {
            item.boolean
        } else {
            fallback
        }
        case None => fallback
    }
}

func integerOr(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Number) {
                try {
                    Int64.parse(item.number)
                } catch (_: Exception) {
                    0
                }
            } else {
                0
            }
        case None => 0
    }
}

func thinkingName(value: ThinkingLevel): String {
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

func thinkingFromName(value: String): Result<ThinkingLevel> {
    match (value) {
        case "off" => Result.Ok(ThinkingLevel.Off)
        case "minimal" => Result.Ok(ThinkingLevel.Minimal)
        case "low" => Result.Ok(ThinkingLevel.Low)
        case "medium" => Result.Ok(ThinkingLevel.Medium)
        case "high" => Result.Ok(ThinkingLevel.High)
        case "xhigh" => Result.Ok(ThinkingLevel.XHigh)
        case "max" => Result.Ok(ThinkingLevel.Max)
        case _ => codecError("unknown thinking level")
    }
}

func thinkingPreferenceSourceName(value: ThinkingPreferenceSource): String {
    match (value) {
        case ThinkingPreferenceSource.ExplicitUser => "explicit_user"
        case ThinkingPreferenceSource.ModePreference => "mode_preference"
        case ThinkingPreferenceSource.ModelDefault => "model_default"
    }
}

func thinkingControlModeName(value: ThinkingControlMode): String {
    match (value) {
        case ThinkingControlMode.NoThinking => "none"
        case ThinkingControlMode.Toggle => "toggle"
        case ThinkingControlMode.Effort => "effort"
        case ThinkingControlMode.Budget => "budget"
        case ThinkingControlMode.Adaptive => "adaptive"
    }
}

func riskLevelName(value: ApprovalRiskLevel): String {
    match (value) {
        case ApprovalRiskLevel.Low => "low"
        case ApprovalRiskLevel.Medium => "medium"
        case ApprovalRiskLevel.High => "high"
        case ApprovalRiskLevel.Critical => "critical"
    }
}

func riskLevelFrom(value: String): ApprovalRiskLevel {
    match (value) {
        case "low" => ApprovalRiskLevel.Low
        case "medium" => ApprovalRiskLevel.Medium
        case "critical" => ApprovalRiskLevel.Critical
        case _ => ApprovalRiskLevel.High
    }
}

func reviewDecisionName(value: ApprovalReviewDecision): String {
    match (value) {
        case ApprovalReviewDecision.Approve => "approve"
        case ApprovalReviewDecision.Deny => "deny"
        case ApprovalReviewDecision.AskUser => "ask_user"
    }
}

func reviewDecisionFrom(value: String): ApprovalReviewDecision {
    match (value) {
        case "approve" => ApprovalReviewDecision.Approve
        case "deny" => ApprovalReviewDecision.Deny
        case _ => ApprovalReviewDecision.AskUser
    }
}

func decisionSourceName(value: ApprovalDecisionSource): String {
    match (value) {
        case ApprovalDecisionSource.StaticPolicy => "static_policy"
        case ApprovalDecisionSource.SessionGrant => "session_grant"
        case ApprovalDecisionSource.AiReviewer => "ai_reviewer"
        case ApprovalDecisionSource.HardDeny => "hard_deny"
        case ApprovalDecisionSource.User => "user"
    }
}

func modelImageSourceName(kind: ModelImageSourceKind): String {
    match (kind) {
        case ModelImageSourceKind.Url => "url"
        case ModelImageSourceKind.Base64 => "base64"
    }
}

func modelImageDetailName(detail: ModelImageDetail): String {
    match (detail) {
        case ModelImageDetail.Auto => "auto"
        case ModelImageDetail.Low => "low"
        case ModelImageDetail.High => "high"
    }
}

func statusName(status: RunState): String {
    match (status) {
        case RunState.Created => "created"
        case RunState.Running => "running"
        case RunState.WaitingApproval => "waiting_approval"
        case RunState.WaitingExternal => "waiting_external"
        case RunState.Cancelling => "cancelling"
        case RunState.Cancelled => "cancelled"
        case RunState.Completed => "completed"
        case RunState.Failed => "failed"
        case RunState.RecoveryRequired => "recovery_required"
    }
}

func statusFrom(value: String): ?RunState {
    match (value) {
        case "created" => Some(RunState.Created)
        case "running" => Some(RunState.Running)
        case "waiting_approval" => Some(RunState.WaitingApproval)
        case "waiting_external" => Some(RunState.WaitingExternal)
        case "cancelling" => Some(RunState.Cancelling)
        case "cancelled" => Some(RunState.Cancelled)
        case "completed" => Some(RunState.Completed)
        case "failed" => Some(RunState.Failed)
        case "recovery_required" => Some(RunState.RecoveryRequired)
        case _ => None
    }
}

func runKindName(kind: RunKind): String {
    match (kind) {
        case RunKind.Agent => "agent"
        case RunKind.Maintenance => "maintenance"
        case RunKind.Chat => "chat"
        case RunKind.Compaction => "compaction"
        case RunKind.NavigationSummary => "navigation_summary"
        case RunKind.Verification => "verification"
    }
}

func runKindFrom(value: String): ?RunKind {
    match (value) {
        case "agent" => Some(RunKind.Agent)
        case "maintenance" => Some(RunKind.Maintenance)
        case "chat" => Some(RunKind.Chat)
        case "compaction" => Some(RunKind.Compaction)
        case "navigation_summary" => Some(RunKind.NavigationSummary)
        case "verification" => Some(RunKind.Verification)
        case _ => None
    }
}

func eventKindName(kind: AgentEventKind): String {
    match (kind) {
        case AgentEventKind.RunStarted => "run_started"
        case AgentEventKind.RunStateChanged => "run_state_changed"
        case AgentEventKind.Model => "model"
        case AgentEventKind.Tool => "tool"
        case AgentEventKind.Approval => "approval"
        case AgentEventKind.Budget => "budget"
        case AgentEventKind.Diagnostic => "diagnostic"
        case AgentEventKind.Audit => "audit"
        case AgentEventKind.Transcript => "transcript"
        case AgentEventKind.Completed => "completed"
    }
}

func eventKindFrom(value: String): ?AgentEventKind {
    match (value) {
        case "run_started" => Some(AgentEventKind.RunStarted)
        case "run_state_changed" => Some(AgentEventKind.RunStateChanged)
        case "model" => Some(AgentEventKind.Model)
        case "tool" => Some(AgentEventKind.Tool)
        case "approval" => Some(AgentEventKind.Approval)
        case "budget" => Some(AgentEventKind.Budget)
        case "diagnostic" => Some(AgentEventKind.Diagnostic)
        case "audit" => Some(AgentEventKind.Audit)
        case "transcript" => Some(AgentEventKind.Transcript)
        case "completed" => Some(AgentEventKind.Completed)
        case _ => None
    }
}

func operationStatusName(status: OperationStatus): String {
    match (status) {
        case OperationStatus.Prepared => "prepared"
        case OperationStatus.Approved => "approved"
        case OperationStatus.Executing => "executing"
        case OperationStatus.Committed => "committed"
        case OperationStatus.Failed => "failed"
        case OperationStatus.RecoveryRequired => "recovery_required"
    }
}

func operationStatusFrom(value: String): ?OperationStatus {
    match (value) {
        case "prepared" => Some(OperationStatus.Prepared)
        case "approved" => Some(OperationStatus.Approved)
        case "executing" => Some(OperationStatus.Executing)
        case "committed" => Some(OperationStatus.Committed)
        case "failed" => Some(OperationStatus.Failed)
        case "recovery_required" => Some(OperationStatus.RecoveryRequired)
        case _ => None
    }
}

func capabilityKindName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace_read"
        case CapabilityKind.WorkspaceWrite => "workspace_write"
        case CapabilityKind.ProcessSpawn => "process_spawn"
        case CapabilityKind.NetworkAccess => "network_access"
        case CapabilityKind.PeerMessage => "peer_message"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension_invoke"
    }
}

func capabilityKindFrom(value: String): CapabilityKind {
    match (value) {
        case "workspace_write" => CapabilityKind.WorkspaceWrite
        case "process_spawn" => CapabilityKind.ProcessSpawn
        case "network_access" => CapabilityKind.NetworkAccess
        case "peer_message" => CapabilityKind.PeerMessage
        case "delegate" => CapabilityKind.Delegate
        case "extension_invoke" => CapabilityKind.ExtensionInvoke
        case _ => CapabilityKind.WorkspaceRead
    }
}

func errorKindName(kind: AgentErrorKind): String {
    match (kind) {
        case AgentErrorKind.Configuration => "configuration"
        case AgentErrorKind.Authentication => "authentication"
        case AgentErrorKind.PermissionDenied => "permission_denied"
        case AgentErrorKind.InvalidInput => "invalid_input"
        case AgentErrorKind.RateLimited => "rate_limited"
        case AgentErrorKind.Timeout => "timeout"
        case AgentErrorKind.Transport => "transport"
        case AgentErrorKind.Provider => "provider"
        case AgentErrorKind.Protocol => "protocol"
        case AgentErrorKind.Cancelled => "cancelled"
        case AgentErrorKind.BudgetExceeded => "budget_exceeded"
        case AgentErrorKind.Conflict => "conflict"
        case AgentErrorKind.RecoveryRequired => "recovery_required"
        case AgentErrorKind.Internal => "internal"
    }
}

func diskMissing<T>(resource: String, id: String): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "persistence.not_found",
            "repository value was not found",
            fields: [ErrorField("resource", resource), ErrorField("id", id)]
        )
    )
}

func diskError<T>(code: String, message: String): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.Internal,
            code,
            if (message == "") {
                "disk persistence failed"
            } else {
                message
            }
        )
    )
}

func codecError<T>(message: String): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.Protocol,
            "persistence.invalid_record",
            message
        )
    )
}

func operationConflict<T>(message: String): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.Conflict,
            "persistence.conflict",
            message
        )
    )
}
