package agent_domain

import yjson.*
import yjson_support.*
import std.deriving.*

public enum Result<T> {
    Ok(T) | Err(AgentError)

    public func isOk(): Bool {
        match (this) {
            case Ok(_) => true
            case Err(_) => false
        }
    }

    public func isError(): Bool {
        !isOk()
    }

    public func value(): ?T {
        match (this) {
            case Ok(value) => Some(value)
            case Err(_) => None
        }
    }

    public func error(): ?AgentError {
        match (this) {
            case Ok(_) => None
            case Err(error) => Some(error)
        }
    }
}

@Derive[Equatable]
public enum AgentErrorKind {
    Configuration
    | Authentication
    | PermissionDenied
    | InvalidInput
    | RateLimited
    | Timeout
    | Transport
    | Provider
    | Protocol
    | Cancelled
    | BudgetExceeded
    | Conflict
    | RecoveryRequired
    | Internal
}

public class ErrorField {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        this.name = name
        this.value = value
    }
}

public class AgentError {
    public let kind: AgentErrorKind
    public let code: String
    public let message: String
    public let retryable: Bool
    public let fallbackAllowed: Bool
    public let fields: Array<ErrorField>
    // Typed model-attempt semantics are carried separately from the stable
    // public error code. Recovery policy must never parse provider messages or
    // error-code strings to decide whether another model attempt is safe.
    public let attemptFailure: ?AttemptFailure

    public init(
        kind: AgentErrorKind,
        code: String,
        message: String,
        retryable!: Bool = false,
        fallbackAllowed!: Bool = false,
        fields!: Array<ErrorField> = [],
        attemptFailure!: ?AttemptFailure = None
    ) {
        if (code.trimAscii() == "") {
            throw IllegalArgumentException("agent error code must not be empty")
        }
        if (message.trimAscii() == "") {
            throw IllegalArgumentException("agent error message must not be empty")
        }
        this.kind = kind
        this.code = code
        this.message = message
        this.retryable = retryable
        this.fallbackAllowed = fallbackAllowed
        this.fields = fields
        this.attemptFailure = attemptFailure
    }

    public func field(name: String): ?String {
        for (item in fields where item.name == name) {
            return Some(item.value)
        }
        None
    }

    public func describe(): String {
        var text = message
        if (code != "") {
            text += " (" + code + ")"
        }
        for (item in fields) {
            text += "\n" + item.name + ": " + item.value
        }
        text
    }
}

// Agent payloads use the canonical JSON value tree. These aliases preserve the
// product vocabulary without maintaining a second AST or parser.
public type ValueKind = UnifiedJsonKind
public type ValueField = JsonObjectEntry
public type AgentValue = JsonNode

public func nullValue(): AgentValue {
    jsonNull()
}

public func boolValue(value: Bool): AgentValue {
    jsonBool(value)
}

public func integerValue(value: Int64): AgentValue {
    numberValue(value.toString())
}

public func numberValue(value: String): AgentValue {
    if (value.trimAscii() == "") {
        throw IllegalArgumentException("number value must not be empty")
    }
    jsonNumber(value)
}

public func textValue(value: String): AgentValue {
    jsonString(value)
}

public func listValue(values: Array<AgentValue>): AgentValue {
    jsonArray(values)
}

public func objectValue(fields: Array<ValueField>): AgentValue {
    jsonObject(fields)
}

public class RunId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("run", value)
    }
}

public class SessionId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("session", value)
    }
}

public class OperationId {
    public let value: String
    public init(value: String) {
        this.value = validatedIdentifier("operation", value)
    }
}

@Derive[Equatable]
public enum ModelRole {
    User | Assistant
}

@Derive[Equatable]
public enum ModelBlockKind {
    Text | Image | Reasoning | ToolCall | ToolResult | Refusal | Error | Unknown
}

@Derive[Equatable]
public enum ModelImageSourceKind {
    Url | Base64
}

@Derive[Equatable]
public enum ModelImageDetail {
    Auto | Low | High
}

// Provider-neutral image input. URL sources keep the original URL while
// base64 sources carry raw base64 data plus an explicit media type.
public class ModelImage {
    public let sourceKind: ModelImageSourceKind
    public let data: String
    public let mediaType: String
    public let detail: ModelImageDetail

    public init(
        sourceKind: ModelImageSourceKind,
        data: String,
        mediaType!: String = "",
        detail!: ModelImageDetail = ModelImageDetail.Auto
    ) {
        if (data.trimAscii() == "") {
            throw IllegalArgumentException("model image data must not be empty")
        }
        let normalizedMediaType = mediaType.trimAscii()
        match (sourceKind) {
            case ModelImageSourceKind.Url =>
                if ((!data.startsWith("https://") && !data.startsWith("http://")) || data.size > 8192) {
                    throw IllegalArgumentException("model image URL must be an HTTP(S) URL of at most 8192 bytes")
                }
            case ModelImageSourceKind.Base64 =>
                if (normalizedMediaType == "") {
                    throw IllegalArgumentException("base64 model image requires a media type")
                }
                validateModelImageBase64(data)
        }
        if (normalizedMediaType != "") {
            validateModelImageMediaType(normalizedMediaType)
        }
        this.sourceKind = sourceKind
        this.data = data
        this.mediaType = normalizedMediaType
        this.detail = detail
    }
}

func validateModelImageMediaType(value: String): Unit {
    if (!value.startsWith("image/") || value.size > 127) {
        throw IllegalArgumentException("model image media type must be a valid image/* token")
    }
    let bytes = unsafe { value.rawData() }
    for (byte in bytes) {
        if (!((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'/' || byte == b'+' ||
            byte == b'-' || byte == b'.')) {
            throw IllegalArgumentException("model image media type must be a valid image/* token")
        }
    }
}

func validateModelImageBase64(value: String): Unit {
    // 20 MiB decoded is the portable product ceiling. Keeping the bound in
    // the neutral domain prevents every adapter and persistence entry point
    // from accepting a different unbounded payload.
    if (value.size > 27962028 || value.size % 4 != 0) {
        throw IllegalArgumentException("model image base64 payload is invalid or exceeds 20 MiB")
    }
    let bytes = unsafe { value.rawData() }
    var padding: Int64 = 0
    var sawPadding = false
    for (byte in bytes) {
        if (byte == b'=') {
            sawPadding = true
            padding += 1
            if (padding > 2) {
                throw IllegalArgumentException("model image base64 payload is invalid")
            }
        } else {
            if (sawPadding || !((byte >= b'a' && byte <= b'z') ||
                (byte >= b'A' && byte <= b'Z') || (byte >= b'0' && byte <= b'9') ||
                byte == b'+' || byte == b'/')) {
                throw IllegalArgumentException("model image base64 payload is invalid")
            }
        }
    }
}

public class OpaqueProviderState {
    public let providerId: String
    public let protocol: String
    public let itemId: String
    public let payload: String
    public let replayRequired: Bool

    public init(
        providerId: String,
        protocol: String,
        payload: String,
        itemId!: String = "",
        replayRequired!: Bool = false
    ) {
        this.providerId = providerId
        this.protocol = protocol
        this.itemId = itemId
        this.payload = payload
        this.replayRequired = replayRequired
    }
}

public class ModelBlock {
    public let kind: ModelBlockKind
    public let text: String
    public let callId: String
    public let name: String
    public let arguments: AgentValue
    public let isError: Bool
    public let image: ?ModelImage
    // Durable operation receipt used to make transcript persistence
    // idempotent after an approved tool execution is replayed.
    public let receiptId: String
    public let opaqueState: ?OpaqueProviderState

    public init(
        kind: ModelBlockKind,
        text!: String = "",
        callId!: String = "",
        name!: String = "",
        arguments!: AgentValue = objectValue([]),
        isError!: Bool = false,
        image!: ?ModelImage = None,
        receiptId!: String = "",
        opaqueState!: ?OpaqueProviderState = None
    ) {
        if (kind == ModelBlockKind.Image && image.isNone()) {
            throw IllegalArgumentException("image model block requires image data")
        }
        if (kind != ModelBlockKind.Image && image.isSome()) {
            throw IllegalArgumentException("non-image model block must not carry image data")
        }
        this.kind = kind
        this.text = text
        this.callId = callId
        this.name = name
        this.arguments = arguments
        this.isError = isError
        this.image = image
        this.receiptId = receiptId
        this.opaqueState = opaqueState
    }
}

// A provider-neutral request for schema-constrained model output. Adapters
// own the protocol-specific wire shape; the Runtime validates the returned
// JSON value against the same schema before exposing it to callers.
public class StructuredOutputSpec {
    public let name: String
    public let description: String
    public let schema: AgentValue
    public let strict: Bool

    public init(
        name: String,
        schema: AgentValue,
        description!: String = "",
        strict!: Bool = true
    ) {
        let normalized = name.trimAscii()
        if (normalized == "") {
            throw IllegalArgumentException("structured output name must not be empty")
        }
        if (normalized.size > 64) {
            throw IllegalArgumentException("structured output name must not exceed 64 bytes")
        }
        for (rune in normalized.runes()) {
            if (!((rune >= r'a' && rune <= r'z') ||
                (rune >= r'A' && rune <= r'Z') ||
                (rune >= r'0' && rune <= r'9') || rune == r'_' || rune == r'-')) {
                throw IllegalArgumentException(
                    "structured output name may only contain letters, digits, '_' or '-'"
                )
            }
        }
        if (schema.unifiedKind != ValueKind.Object) {
            throw IllegalArgumentException("structured output schema must be an object")
        }
        this.name = normalized
        this.description = description.trimAscii()
        this.schema = schema
        this.strict = strict
    }
}

public class ModelMessage {
    public let role: ModelRole
    public let blocks: Array<ModelBlock>

    public init(role: ModelRole, blocks: Array<ModelBlock>) {
        this.role = role
        this.blocks = blocks
    }
}

public class ModelToolDefinition {
    public let name: String
    public let description: String
    public let inputSchema: AgentValue

    public init(name: String, description: String, inputSchema: AgentValue) {
        if (name.trimAscii() == "") {
            throw IllegalArgumentException("tool name must not be empty")
        }
        if (inputSchema.unifiedKind != ValueKind.Object) {
            throw IllegalArgumentException("tool schema must be an object")
        }
        this.name = name
        this.description = description
        this.inputSchema = inputSchema
    }
}

@Derive[Equatable]
public enum ThinkingLevel {
    Off | Minimal | Low | Medium | High | XHigh | Max
}

@Derive[Equatable]
public enum TodoStatus {
    Pending | InProgress | Completed | Abandoned | Blocked
}

public class TodoItem {
    public let content: String
    public let status: TodoStatus
    public let blocker: String

    public init(
        content: String,
        status!: TodoStatus = TodoStatus.Pending,
        blocker!: String = ""
    ) {
        if (content.trimAscii() == "") {
            throw IllegalArgumentException("todo item content must not be empty")
        }
        this.content = content
        this.status = status
        this.blocker = blocker
    }
}

public class TodoPhase {
    public let name: String
    public let tasks: Array<TodoItem>

    public init(name: String, tasks: Array<TodoItem>) {
        if (name.trimAscii() == "") {
            throw IllegalArgumentException("todo phase name must not be empty")
        }
        this.name = name
        this.tasks = tasks
    }
}

@Derive[Equatable]
public enum ModelCachePolicy {
    Default | StablePrefix
}

public enum ModelToolChoice {
    Auto | NoTools | Required
}

public class ModelRequest {
    public let model: String
    public let system: String
    public let messages: Array<ModelMessage>
    public let tools: Array<ModelToolDefinition>
    public let thinking: ThinkingLevel
    public let maxOutputTokens: Int64
    // Canonical provider wire ceiling. maxOutputTokens is retained as a
    // read-only source compatibility alias with the same value.
    public let wireMaxOutputTokens: Int64
    // Present on Core-owned provider calls. The scalar fields remain
    // available for source compatibility, but adapters lower this policy when
    // supplied and must not mutate its values.
    public let resolvedPolicy: ?ResolvedModelRequestPolicy
    public let streaming: Bool
    public let parallelToolCalls: Bool
    public let requestId: String
    public let serviceTier: String
    public let cachePolicy: ModelCachePolicy
    public let cacheKey: String
    public let toolChoice: ModelToolChoice
    public let structuredOutput: ?StructuredOutputSpec
    // Transport safety limit for direct callers. RecoveryV1 Core calls
    // materialize zero here and rely on semantic-progress idle detection plus
    // the Run wall budget; this is not a thinking or attempt-duration policy.
    public let transportHardTimeoutMillis: Int64

    public init(
        model: String,
        messages: Array<ModelMessage>,
        system!: String = "",
        tools!: Array<ModelToolDefinition> = [],
        thinking!: ThinkingLevel = ThinkingLevel.Medium,
        maxOutputTokens!: Int64 = 2000,
        wireMaxOutputTokens!: ?Int64 = None,
        resolvedPolicy!: ?ResolvedModelRequestPolicy = None,
        streaming!: Bool = false,
        parallelToolCalls!: Bool = true,
        requestId!: String = "",
        serviceTier!: String = "",
        cachePolicy!: ModelCachePolicy = ModelCachePolicy.Default,
        toolChoice!: ModelToolChoice = ModelToolChoice.Auto,
        structuredOutput!: ?StructuredOutputSpec = None,
        cacheKey!: String = "",
        transportHardTimeoutMillis!: Int64 = 0
    ) {
        if (model.trimAscii() == "") {
            throw IllegalArgumentException("model must not be empty")
        }
        let effectiveWireMaxOutputTokens = match (wireMaxOutputTokens) {
            case Some(value) => value
            case None => maxOutputTokens
        }
        if (effectiveWireMaxOutputTokens < 1) {
            throw IllegalArgumentException("max output tokens must be positive")
        }
        if (transportHardTimeoutMillis < 0) {
            throw IllegalArgumentException("transport hard timeout must not be negative")
        }
        this.model = model
        this.system = system
        this.messages = messages
        this.tools = tools
        this.thinking = thinking
        this.maxOutputTokens = effectiveWireMaxOutputTokens
        this.wireMaxOutputTokens = effectiveWireMaxOutputTokens
        this.resolvedPolicy = resolvedPolicy
        this.streaming = streaming
        this.parallelToolCalls = parallelToolCalls
        this.requestId = requestId
        this.serviceTier = serviceTier
        this.cachePolicy = cachePolicy
        this.toolChoice = toolChoice
        this.structuredOutput = structuredOutput
        this.cacheKey = cacheKey.trimAscii()
        this.transportHardTimeoutMillis = transportHardTimeoutMillis
    }
}

// Provider-independent token accounting. Cache token counts are subsets of
// inputTokens after adapter normalization; costMicros is absent unless the
// active model catalog supplied every rate needed by the observed usage.
@Derive[Equatable]
public enum ModelUsageSource {
    Unknown | ProviderFinal | ProviderStreamFinal | Estimated
}

public class ModelUsageEvidence {
    public let protocol: String
    public let eventKind: String
    public let providerResponseId: String

    public init(
        protocol: String,
        eventKind: String,
        providerResponseId!: String = ""
    ) {
        if (protocol.trimAscii() == "" || eventKind.trimAscii() == "") {
            throw IllegalArgumentException("model usage evidence is incomplete")
        }
        this.protocol = protocol.trimAscii()
        this.eventKind = eventKind.trimAscii()
        this.providerResponseId = providerResponseId.trimAscii()
    }
}

public class ModelUsage {
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public let costMicros: ?Int64
    public let source: ModelUsageSource
    public let evidence: ?ModelUsageEvidence

    public init(
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        reasoningTokens!: Int64 = 0,
        cacheReadTokens!: Int64 = 0,
        cacheWriteTokens!: Int64 = 0,
        costMicros!: ?Int64 = None,
        source!: ModelUsageSource = ModelUsageSource.Unknown,
        evidence!: ?ModelUsageEvidence = None
    ) {
        if (inputTokens < 0 || outputTokens < 0 || reasoningTokens < 0 ||
            cacheReadTokens < 0 || cacheWriteTokens < 0 ||
            match (costMicros) {
                case Some(value) => value < 0
                case None => false
            }) {
            throw IllegalArgumentException("model usage values must not be negative")
        }
        if (cacheReadTokens + cacheWriteTokens > inputTokens) {
            throw IllegalArgumentException("cached input tokens must not exceed total input tokens")
        }
        if (reasoningTokens > outputTokens) {
            throw IllegalArgumentException(
                "reasoning tokens are a subset of output tokens"
            )
        }
        match (source) {
            case ModelUsageSource.Unknown => ()
            case _ => if (evidence.isNone()) {
                throw IllegalArgumentException("model usage source requires evidence")
            }
        }
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
        this.reasoningTokens = reasoningTokens
        this.cacheReadTokens = cacheReadTokens
        this.cacheWriteTokens = cacheWriteTokens
        this.costMicros = costMicros
        this.source = source
        this.evidence = evidence
    }
}

public func modelUsageSourceName(value: ModelUsageSource): String {
    match (value) {
        case ModelUsageSource.Unknown => "unknown"
        case ModelUsageSource.ProviderFinal => "provider_final"
        case ModelUsageSource.ProviderStreamFinal => "provider_stream_final"
        case ModelUsageSource.Estimated => "estimated"
    }
}

public func modelUsageSourceFromName(value: String): ModelUsageSource {
    match (value) {
        case "provider_final" => ModelUsageSource.ProviderFinal
        case "provider_stream_final" => ModelUsageSource.ProviderStreamFinal
        case "estimated" => ModelUsageSource.Estimated
        case _ => ModelUsageSource.Unknown
    }
}

// Fixed-point prices in micro-currency units per one million tokens. Optional
// fields preserve the distinction between an explicitly free category and an
// unknown price.
public class ModelPricing {
    public let inputMicrosPerMillion: ?Int64
    public let outputMicrosPerMillion: ?Int64
    public let cacheReadMicrosPerMillion: ?Int64
    public let cacheWriteMicrosPerMillion: ?Int64

    public init(
        inputMicrosPerMillion!: ?Int64 = None,
        outputMicrosPerMillion!: ?Int64 = None,
        cacheReadMicrosPerMillion!: ?Int64 = None,
        cacheWriteMicrosPerMillion!: ?Int64 = None
    ) {
        for (value in [
            inputMicrosPerMillion,
            outputMicrosPerMillion,
            cacheReadMicrosPerMillion,
            cacheWriteMicrosPerMillion
        ]) {
            match (value) {
                case Some(number) => if (number < 0) {
                    throw IllegalArgumentException("model prices must not be negative")
                }
                case None => ()
            }
        }
        this.inputMicrosPerMillion = inputMicrosPerMillion
        this.outputMicrosPerMillion = outputMicrosPerMillion
        this.cacheReadMicrosPerMillion = cacheReadMicrosPerMillion
        this.cacheWriteMicrosPerMillion = cacheWriteMicrosPerMillion
    }
}

public func priceModelUsage(
    usage: ModelUsage,
    pricing: ModelPricing
): ?Int64 {
    let regularInput = max(
        0,
        usage.inputTokens - usage.cacheReadTokens - usage.cacheWriteTokens
    )
    var weightedMicros: Int64 = 0
    let categories = [
        (regularInput, pricing.inputMicrosPerMillion),
        (usage.outputTokens, pricing.outputMicrosPerMillion),
        (usage.cacheReadTokens, pricing.cacheReadMicrosPerMillion),
        (usage.cacheWriteTokens, pricing.cacheWriteMicrosPerMillion)
    ]
    for ((tokens, rate) in categories) {
        if (tokens == 0) {
            continue
        }
        match (rate) {
            case Some(value) => weightedMicros += tokens * value
            case None => return None
        }
    }
    Some((weightedMicros + 500000) / 1000000)
}

public class ModelReply {
    public let blocks: Array<ModelBlock>
    public let stopReason: String
    public let usage: ModelUsage
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let reasoningTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public let costMicros: ?Int64
    public let acceptedOutput: Bool
    public let providerId: String
    public let responseId: String
    public let structuredOutput: ?AgentValue
    public let terminalEvidence: ?TerminalEvidence
    public let completionDisposition: CompletionDisposition
    public let decisionOutcome: DecisionOutcome
    public let validationVersion: Int64

    public init(
        blocks: Array<ModelBlock>,
        stopReason!: String = "",
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        acceptedOutput!: Bool = true,
        providerId!: String = "",
        responseId!: String = "",
        reasoningTokens!: Int64 = 0,
        cacheReadTokens!: Int64 = 0,
        cacheWriteTokens!: Int64 = 0,
        costMicros!: ?Int64 = None,
        usage!: ?ModelUsage = None,
        structuredOutput!: ?AgentValue = None,
        terminalEvidence!: ?TerminalEvidence = None,
        completionDisposition!: CompletionDisposition = CompletionDisposition.Unknown,
        decisionOutcome!: DecisionOutcome = DecisionOutcome.Unknown,
        validationVersion!: Int64 = 0
    ) {
        let resolvedUsage = match (usage) {
            case Some(value) => value
            case None => ModelUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                costMicros: costMicros
            )
        }
        this.blocks = blocks
        this.stopReason = stopReason
        this.usage = resolvedUsage
        this.inputTokens = resolvedUsage.inputTokens
        this.outputTokens = resolvedUsage.outputTokens
        this.reasoningTokens = resolvedUsage.reasoningTokens
        this.cacheReadTokens = resolvedUsage.cacheReadTokens
        this.cacheWriteTokens = resolvedUsage.cacheWriteTokens
        this.costMicros = resolvedUsage.costMicros
        this.acceptedOutput = acceptedOutput
        this.providerId = providerId
        this.responseId = responseId
        this.structuredOutput = structuredOutput
        this.terminalEvidence = terminalEvidence
        this.completionDisposition = completionDisposition
        this.decisionOutcome = decisionOutcome
        this.validationVersion = validationVersion
    }
}

public enum ModelEvent {
    TextDelta(String)
    | ReasoningDelta(String)
    | ToolCallStarted(String, String)
    | ToolArgumentsDelta(String, String)
    | ToolCallCompleted(String)
    | UsageUpdated(Int64, Int64)
    | ProviderProgress(ProviderStreamEvent)
    | Completed
}

public type ModelEventSink = (ModelEvent) -> Unit

@Derive[Equatable]
public enum CapabilityKind {
    WorkspaceRead
    | WorkspaceWrite
    | ProcessSpawn
    | NetworkAccess
    | PeerMessage
    | Delegate
    | ExtensionInvoke
}

public class Capability {
    public let kind: CapabilityKind
    public let resource: String

    public init(kind: CapabilityKind, resource!: String = "") {
        this.kind = kind
        this.resource = resource
    }
}

public class CapabilitySet {
    public let values: Array<Capability>

    public init(values!: Array<Capability> = []) {
        this.values = values
    }

    public func allows(kind: CapabilityKind, resource!: String = ""): Bool {
        for (item in values where item.kind == kind) {
            if (item.resource == "" || item.resource == resource) {
                return true
            }
        }
        false
    }
}

public class ResourceBudget {
    public let maxInputTokens: Int64
    public let maxOutputTokens: Int64
    // Canonical per-request output policy. maxOutputTokens remains a source-
    // compatible alias for requestOutputBudget.hardLimit.
    public let requestOutputBudget: RequestOutputBudget
    // Per-request token ceilings above are context/model protocol limits.
    // These optional totals are the cumulative Run budget; zero is unbounded.
    public let maxTotalInputTokens: Int64
    public let maxTotalOutputTokens: Int64
    public let maxModelRequests: Int64
    public let maxTurns: Int64
    // Control-plane finalization turns allowed after the work-turn budget is
    // exhausted. Strictly bounded so graceful draining can never loop.
    public let maxDrainTurns: Int64
    public let maxToolCalls: Int64
    public let maxWallMillis: Int64
    public let maxIdleMillis: Int64
    public let maxChildren: Int64
    public let maxDepth: Int64
    public let maxConcurrentChildren: Int64
    public let maxContextMessages: Int64
    public let maxConcurrentTools: Int64
    public let maxCostMicros: Int64
    public let deadlineMillis: Int64

    public init(
        maxInputTokens!: Int64 = 100000,
        maxOutputTokens!: Int64 = 100000,
        requestOutputBudget!: ?RequestOutputBudget = None,
        minVisibleResponseTokens!: Int64 = DEFAULT_VISIBLE_RESPONSE_TOKENS,
        maxTotalInputTokens!: Int64 = 0,
        maxTotalOutputTokens!: Int64 = 0,
        maxModelRequests!: Int64 = 64,
        maxTurns!: Int64 = 32,
        maxDrainTurns!: Int64 = 2,
        maxToolCalls!: Int64 = 64,
        maxWallMillis!: Int64 = 600000,
        maxIdleMillis!: Int64 = 120000,
        maxChildren!: Int64 = 8,
        maxDepth!: Int64 = 4,
        maxConcurrentChildren!: Int64 = 4,
        maxContextMessages!: Int64 = 0,
        maxConcurrentTools!: Int64 = 4,
        maxCostMicros!: Int64 = 0,
        deadlineMillis!: Int64 = 0
    ) {
        let effectiveOutputBudget = match (requestOutputBudget) {
            case Some(value) => value
            case None => RequestOutputBudget(
                maxOutputTokens,
                minVisibleResponseTokens: minVisibleResponseTokens
            )
        }
        if (maxInputTokens < 1 || effectiveOutputBudget.hardLimit < 1 ||
            effectiveOutputBudget.minVisibleResponseTokens < 0 ||
            maxModelRequests < 1 || maxTurns < 1 || maxDrainTurns < 1 || maxToolCalls < 1 ||
            // maxWallMillis == 0 means no wall-clock limit (a stream that
            // keeps emitting tokens is never cut off; only idle hangs are).
            maxWallMillis < 0 || maxIdleMillis < 1 || maxChildren < 0 || maxDepth < 0 || maxConcurrentChildren < 1 ||
            maxContextMessages < 0 || maxConcurrentTools < 1 || maxCostMicros < 0 || deadlineMillis < 0 ||
            maxTotalInputTokens < 0 || maxTotalOutputTokens < 0) {
            throw IllegalArgumentException("resource budget values are out of range")
        }
        this.maxInputTokens = maxInputTokens
        this.maxOutputTokens = effectiveOutputBudget.hardLimit
        this.requestOutputBudget = effectiveOutputBudget
        this.maxTotalInputTokens = maxTotalInputTokens
        this.maxTotalOutputTokens = maxTotalOutputTokens
        this.maxModelRequests = maxModelRequests
        this.maxTurns = maxTurns
        this.maxDrainTurns = maxDrainTurns
        this.maxToolCalls = maxToolCalls
        this.maxWallMillis = maxWallMillis
        this.maxIdleMillis = maxIdleMillis
        this.maxChildren = maxChildren
        this.maxDepth = maxDepth
        this.maxConcurrentChildren = maxConcurrentChildren
        this.maxContextMessages = maxContextMessages
        this.maxConcurrentTools = maxConcurrentTools
        this.maxCostMicros = maxCostMicros
        this.deadlineMillis = deadlineMillis
    }
}

public class ToolCall {
    public let callId: String
    public let name: String
    public let arguments: AgentValue

    public init(callId: String, name: String, arguments: AgentValue) {
        if (callId.trimAscii() == "" || name.trimAscii() == "") {
            throw IllegalArgumentException("tool call id and name must not be empty")
        }
        this.callId = callId
        this.name = name
        this.arguments = arguments
    }
}

public class ToolResult {
    public let callId: String
    public let output: AgentValue
    public let isError: Bool
    public let receiptId: String

    public init(
        callId: String,
        output: AgentValue,
        isError!: Bool = false,
        receiptId!: String = ""
    ) {
        this.callId = callId
        this.output = output
        this.isError = isError
        this.receiptId = receiptId
    }
}

@Derive[Equatable]
public enum ApprovalDecision {
    Approve
    | ApproveSession
    | Reject
    | RejectWithReason(String)
}

@Derive[Equatable]
public enum ApprovalRoutingMode {
    Manual | Ai | Never | Trusted
}

@Derive[Equatable]
public enum ApprovalFailurePolicy {
    Deny | AskUser
}

@Derive[Equatable]
public enum ApprovalReviewDecision {
    Approve | Deny | AskUser
}

public class ApprovalReview {
    public let decision: ApprovalReviewDecision
    public let reason: String
    public let riskLevel: String
    public let reviewerModel: String
    public let latencyMillis: Int64
    public let failureType: String
    public let approvedCapabilities: Array<String>

    public init(
        decision: ApprovalReviewDecision,
        reason: String,
        riskLevel: String,
        reviewerModel: String,
        latencyMillis!: Int64 = 0,
        failureType!: String = "",
        approvedCapabilities!: Array<String> = []
    ) {
        this.decision = decision
        this.reason = reason
        this.riskLevel = riskLevel
        this.reviewerModel = reviewerModel
        this.latencyMillis = latencyMillis
        this.failureType = failureType
        this.approvedCapabilities = approvedCapabilities
    }
}

@Derive[Equatable]
public enum ApprovalRiskLevel {
    Low | Medium | High | Critical
}

public class RiskAssessment {
    public let level: ApprovalRiskLevel
    public let flags: Array<String>
    public let reasons: Array<String>

    public init(
        level: ApprovalRiskLevel,
        flags!: Array<String> = [],
        reasons!: Array<String> = []
    ) {
        this.level = level
        this.flags = flags
        this.reasons = reasons
    }
}

public class ApprovalGrantScope {
    public let capability: String
    public let pathPrefix: String
    public let toolName: String
    public let host: String
    public let sessionOnly: Bool

    public init(
        capability: String,
        pathPrefix!: String = "",
        toolName!: String = "",
        host!: String = "",
        sessionOnly!: Bool = true
    ) {
        this.capability = capability
        this.pathPrefix = pathPrefix
        this.toolName = toolName
        this.host = host
        this.sessionOnly = sessionOnly
    }
}

public class WriteApprovalSummary {
    public let path: String
    public let action: String
    public let exists: Bool
    public let bytes: Int64
    public let lines: Int64
    public let language: String
    public let preview: Array<String>
    public let truncated: Bool
    public let contentHash: String
    public let beforeBytes: Int64
    public let addedLines: Int64
    public let removedLines: Int64

    public init(
        path: String,
        action: String,
        exists: Bool,
        bytes: Int64,
        lines: Int64,
        language!: String = "",
        preview!: Array<String> = [],
        truncated!: Bool = false,
        contentHash!: String = "",
        beforeBytes!: Int64 = 0,
        addedLines!: Int64 = 0,
        removedLines!: Int64 = 0
    ) {
        this.path = path
        this.action = action
        this.exists = exists
        this.bytes = bytes
        this.lines = lines
        this.language = language
        this.preview = preview
        this.truncated = truncated
        this.contentHash = contentHash
        this.beforeBytes = beforeBytes
        this.addedLines = addedLines
        this.removedLines = removedLines
    }
}

public class ToolApprovalMetadata {
    public let capabilityLabel: String
    public let assessment: RiskAssessment
    public let grantScope: ApprovalGrantScope
    public let writeSummary: ?WriteApprovalSummary

    public init(
        capabilityLabel: String,
        assessment: RiskAssessment,
        grantScope: ApprovalGrantScope,
        writeSummary!: ?WriteApprovalSummary = None
    ) {
        this.capabilityLabel = capabilityLabel
        this.assessment = assessment
        this.grantScope = grantScope
        this.writeSummary = writeSummary
    }
}

@Derive[Equatable]
public enum ApprovalDecisionSource {
    StaticPolicy | SessionGrant | AiReviewer | User | HardDeny
}

public class ApprovalRequest {
    public let operationId: OperationId
    public let callId: String
    public let toolName: String
    public let capability: Capability
    public let preview: AgentValue

    public let sessionId: String
    public let argumentHash: String
    public let riskFlags: Array<String>
    public let review: ?ApprovalReview
    public let metadata: ToolApprovalMetadata
    public let decisionSource: ApprovalDecisionSource

    public init(
        operationId: OperationId,
        callId: String,
        toolName: String,
        capability: Capability,
        preview!: AgentValue = objectValue([]),
        sessionId!: String = "",
        argumentHash!: String = "",
        riskFlags!: Array<String> = [],
        review!: ?ApprovalReview = None,
        metadata!: ToolApprovalMetadata = defaultToolApprovalMetadata(capability),
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.User
    ) {
        this.operationId = operationId
        this.callId = callId
        this.toolName = toolName
        this.capability = capability
        this.preview = preview
        this.sessionId = sessionId
        this.argumentHash = argumentHash
        this.riskFlags = riskFlags
        this.review = review
        this.metadata = metadata
        this.decisionSource = decisionSource
    }
}

@Derive[Equatable]
public enum RunContinuationKind {
    WaitingApproval | RunningModel
}

// Provider-neutral durable checkpoint. canonicalRequest contains every
// semantic ModelRequest field; transport-only retry bookkeeping is stored in
// the explicit identity fields below and is excluded from its digest.
public class RunningModelCheckpoint {
    public let semanticRequestId: SemanticModelRequestId
    public let canonicalRequest: AgentValue
    public let semanticRequestDigest: String
    public let wirePolicyDigest: String
    public let originalAttemptId: ModelAttemptId
    public let activeAttemptId: ModelAttemptId
    public let stableTurnId: String
    public let stableRequestId: String
    public let requestStartedAtMillis: Int64
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
    public let consecutiveCapabilityDenials: Int64
    public let lastCapabilityDeniedTool: String

    public init(
        semanticRequestId: SemanticModelRequestId,
        canonicalRequest: AgentValue,
        semanticRequestDigest: String,
        wirePolicyDigest: String,
        originalAttemptId: ModelAttemptId,
        activeAttemptId: ModelAttemptId,
        stableTurnId: String,
        stableRequestId: String,
        requestStartedAtMillis: Int64,
        modelRequests!: Int64 = 0,
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        reasoningTokens!: Int64 = 0,
        cacheReadTokens!: Int64 = 0,
        cacheWriteTokens!: Int64 = 0,
        costMicros!: ?Int64 = None,
        lastInputTokens!: Int64 = 0,
        lastOutputTokens!: Int64 = 0,
        lastRequestDurationMillis!: Int64 = 0,
        toolCalls!: Int64 = 0,
        turns!: Int64 = 0,
        consecutiveCapabilityDenials!: Int64 = 0,
        lastCapabilityDeniedTool!: String = ""
    ) {
        if (canonicalRequest.unifiedKind != ValueKind.Object ||
            semanticRequestDigest.trimAscii() == "" || wirePolicyDigest.trimAscii() == "" ||
            stableTurnId.trimAscii() == "" || stableRequestId.trimAscii() == "" ||
            requestStartedAtMillis < 0 || modelRequests < 0 || inputTokens < 0 ||
            outputTokens < 0 || reasoningTokens < 0 || cacheReadTokens < 0 ||
            cacheWriteTokens < 0 || lastInputTokens < 0 || lastOutputTokens < 0 ||
            lastRequestDurationMillis < 0 || toolCalls < 0 || turns < 0 ||
            consecutiveCapabilityDenials < 0 || match (costMicros) {
                case Some(value) => value < 0
                case None => false
            }) {
            throw IllegalArgumentException("running model checkpoint is invalid")
        }
        this.semanticRequestId = semanticRequestId
        this.canonicalRequest = canonicalRequest
        this.semanticRequestDigest = semanticRequestDigest
        this.wirePolicyDigest = wirePolicyDigest
        this.originalAttemptId = originalAttemptId
        this.activeAttemptId = activeAttemptId
        this.stableTurnId = stableTurnId
        this.stableRequestId = stableRequestId
        this.requestStartedAtMillis = requestStartedAtMillis
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
        this.consecutiveCapabilityDenials = consecutiveCapabilityDenials
        this.lastCapabilityDeniedTool = lastCapabilityDeniedTool
    }
}

// Everything needed to resume a run at either durable boundary.
// Process-local interaction/cancellation objects are intentionally excluded.
public class RunContinuation {
    public let kind: RunContinuationKind
    public let runId: RunId
    public let sessionId: SessionId
    public let model: String
    public let prompt: String
    public let system: String
    public let thinking: ThinkingLevel
    public let capabilities: CapabilitySet
    public let budget: ResourceBudget
    public let approvalMode: String
    public let autoRetry: Bool
    public let serviceTier: String
    public let pricing: ?ModelPricing
    public let imageInputs: Array<ModelImage>
    public let structuredOutput: ?StructuredOutputSpec
    public let cachePolicy: ModelCachePolicy
    public let cacheKey: String
    public let parallelToolCalls: Bool
    public let approval: ApprovalRequest
    public let requestedPolicy: ?RequestedModelPolicy
    public let modelCapabilitiesSnapshot: ?ModelExecutionCapabilitiesSnapshot
    public let resolverVersion: UInt32
    public let skillStackPayload: AgentValue
    public let contextWindow: Int64
    public let providerSafetyMargin: Int64
    public let toolContextPayload: AgentValue
    public let runningModel: ?RunningModelCheckpoint
    public let executionLaneId: LaneId

    public init(
        runId: RunId,
        sessionId: SessionId,
        model: String,
        prompt: String,
        approval: ApprovalRequest,
        system!: String = "",
        thinking!: ThinkingLevel = ThinkingLevel.Medium,
        capabilities!: CapabilitySet = CapabilitySet(),
        budget!: ResourceBudget = ResourceBudget(),
        approvalMode!: String = "",
        autoRetry!: Bool = true,
        serviceTier!: String = "",
        pricing!: ?ModelPricing = None,
        imageInputs!: Array<ModelImage> = [],
        structuredOutput!: ?StructuredOutputSpec = None,
        cachePolicy!: ModelCachePolicy = ModelCachePolicy.Default,
        cacheKey!: String = "",
        parallelToolCalls!: Bool = false,
        requestedPolicy!: ?RequestedModelPolicy = None,
        modelCapabilitiesSnapshot!: ?ModelExecutionCapabilitiesSnapshot = None,
        resolverVersion!: UInt32 = MODEL_POLICY_RESOLUTION_VERSION,
        skillStackPayload!: AgentValue = objectValue([]),
        contextWindow!: Int64 = 0,
        providerSafetyMargin!: Int64 = 1024,
        toolContextPayload!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main")
    ) {
        if (model.trimAscii() == "" || prompt.trimAscii() == "") {
            throw IllegalArgumentException("run continuation model and prompt must not be empty")
        }
        this.kind = RunContinuationKind.WaitingApproval
        this.runId = runId
        this.sessionId = sessionId
        this.model = model
        this.prompt = prompt
        this.system = system
        this.thinking = thinking
        this.capabilities = capabilities
        this.budget = budget
        this.approvalMode = approvalMode
        this.autoRetry = autoRetry
        this.serviceTier = serviceTier
        this.pricing = pricing
        this.imageInputs = imageInputs
        this.structuredOutput = structuredOutput
        this.cachePolicy = cachePolicy
        this.cacheKey = cacheKey.trimAscii()
        this.parallelToolCalls = parallelToolCalls
        this.approval = approval
        this.requestedPolicy = requestedPolicy
        this.modelCapabilitiesSnapshot = modelCapabilitiesSnapshot
        this.resolverVersion = resolverVersion
        this.skillStackPayload = skillStackPayload
        this.contextWindow = contextWindow
        this.providerSafetyMargin = providerSafetyMargin
        this.toolContextPayload = toolContextPayload
        this.runningModel = None
        this.executionLaneId = executionLaneId
    }

    public init(
        kind: RunContinuationKind,
        runId: RunId,
        sessionId: SessionId,
        model: String,
        prompt: String,
        runningModel: RunningModelCheckpoint,
        requestedPolicy: RequestedModelPolicy,
        modelCapabilitiesSnapshot: ModelExecutionCapabilitiesSnapshot,
        system!: String = "",
        thinking!: ThinkingLevel = ThinkingLevel.Medium,
        capabilities!: CapabilitySet = CapabilitySet(),
        budget!: ResourceBudget = ResourceBudget(),
        approvalMode!: String = "",
        autoRetry!: Bool = true,
        serviceTier!: String = "",
        pricing!: ?ModelPricing = None,
        imageInputs!: Array<ModelImage> = [],
        structuredOutput!: ?StructuredOutputSpec = None,
        cachePolicy!: ModelCachePolicy = ModelCachePolicy.Default,
        cacheKey!: String = "",
        parallelToolCalls!: Bool = false,
        resolverVersion!: UInt32 = MODEL_POLICY_RESOLUTION_VERSION,
        skillStackPayload!: AgentValue = objectValue([]),
        contextWindow!: Int64 = 0,
        providerSafetyMargin!: Int64 = 1024,
        toolContextPayload!: AgentValue = objectValue([]),
        executionLaneId!: LaneId = LaneId("main")
    ) {
        if (kind != RunContinuationKind.RunningModel || model.trimAscii() == "" ||
            prompt.trimAscii() == "") {
            throw IllegalArgumentException("running model continuation is invalid")
        }
        this.kind = kind
        this.runId = runId
        this.sessionId = sessionId
        this.model = model
        this.prompt = prompt
        this.system = system
        this.thinking = thinking
        this.capabilities = capabilities
        this.budget = budget
        this.approvalMode = approvalMode
        this.autoRetry = autoRetry
        this.serviceTier = serviceTier
        this.pricing = pricing
        this.imageInputs = imageInputs
        this.structuredOutput = structuredOutput
        this.cachePolicy = cachePolicy
        this.cacheKey = cacheKey.trimAscii()
        this.parallelToolCalls = parallelToolCalls
        // Compatibility field; callers must branch on kind before reading it.
        this.approval = ApprovalRequest(
            OperationId("running-model-" + runningModel.activeAttemptId.value),
            "running-model", "running_model",
            Capability(CapabilityKind.NetworkAccess),
            sessionId: sessionId.value,
            argumentHash: runningModel.semanticRequestDigest
        )
        this.requestedPolicy = Some(requestedPolicy)
        this.modelCapabilitiesSnapshot = Some(modelCapabilitiesSnapshot)
        this.resolverVersion = resolverVersion
        this.skillStackPayload = skillStackPayload
        this.contextWindow = contextWindow
        this.providerSafetyMargin = providerSafetyMargin
        this.toolContextPayload = toolContextPayload
        this.runningModel = Some(runningModel)
        this.executionLaneId = executionLaneId
    }
}

// Written before applying a decision. The complete binding prevents a stale
// UI or another session from changing either the decision or its target on a
// retry.
public class ApprovalDecisionReceipt {
    public let operationId: OperationId
    public let runId: RunId
    public let sessionId: SessionId
    public let callId: String
    public let argumentHash: String
    public let decision: ApprovalDecision

    public init(
        operationId: OperationId,
        runId: RunId,
        sessionId: SessionId,
        callId: String,
        argumentHash: String,
        decision: ApprovalDecision
    ) {
        if (callId.trimAscii() == "" || argumentHash.trimAscii() == "") {
            throw IllegalArgumentException("approval decision receipt binding must not be empty")
        }
        this.operationId = operationId
        this.runId = runId
        this.sessionId = sessionId
        this.callId = callId
        this.argumentHash = argumentHash
        this.decision = decision
    }
}

public func reviewedApprovalRequest(
    request: ApprovalRequest,
    review: ApprovalReview
): ApprovalRequest {
    ApprovalRequest(
        request.operationId,
        request.callId,
        request.toolName,
        request.capability,
        preview: request.preview,
        sessionId: request.sessionId,
        argumentHash: request.argumentHash,
        riskFlags: request.riskFlags,
        review: Some(review),
        metadata: request.metadata,
        decisionSource: ApprovalDecisionSource.AiReviewer
    )
}

public func sourcedApprovalRequest(
    request: ApprovalRequest,
    source: ApprovalDecisionSource
): ApprovalRequest {
    ApprovalRequest(
        request.operationId,
        request.callId,
        request.toolName,
        request.capability,
        preview: request.preview,
        sessionId: request.sessionId,
        argumentHash: request.argumentHash,
        riskFlags: request.riskFlags,
        review: request.review,
        metadata: request.metadata,
        decisionSource: source
    )
}

@Derive[Equatable]
public enum ApprovalRisk {
    Low | Medium | High
}

public class ApprovalDetails {
    public let operationId: OperationId
    public let callId: String
    public let toolName: String
    public let capability: Capability
    public let risk: ApprovalRisk
    public let arguments: AgentValue

    public let argumentHash: String
    public let riskFlags: Array<String>
    public let review: ?ApprovalReview
    public let metadata: ToolApprovalMetadata
    public let decisionSource: ApprovalDecisionSource

    public init(
        operationId: OperationId,
        callId: String,
        toolName: String,
        capability: Capability,
        risk: ApprovalRisk,
        arguments: AgentValue,
        argumentHash!: String = "",
        riskFlags!: Array<String> = [],
        review!: ?ApprovalReview = None,
        metadata!: ToolApprovalMetadata = defaultToolApprovalMetadata(capability),
        decisionSource!: ApprovalDecisionSource = ApprovalDecisionSource.User
    ) {
        this.operationId = operationId
        this.callId = callId
        this.toolName = toolName
        this.capability = capability
        this.risk = risk
        this.arguments = arguments
        this.argumentHash = argumentHash
        this.riskFlags = riskFlags
        this.review = review
        this.metadata = metadata
        this.decisionSource = decisionSource
    }
}

public func approvalDetails(request: ApprovalRequest): ApprovalDetails {
    ApprovalDetails(
        request.operationId,
        request.callId,
        request.toolName,
        request.capability,
        approvalRiskFromLevel(request.metadata.assessment.level),
        request.preview,
        argumentHash: request.argumentHash,
        riskFlags: request.riskFlags,
        review: request.review,
        metadata: request.metadata,
        decisionSource: request.decisionSource
    )
}

public func defaultToolApprovalMetadata(capability: Capability): ToolApprovalMetadata {
    let level = match (capability.kind) {
        case CapabilityKind.ProcessSpawn | CapabilityKind.NetworkAccess => ApprovalRiskLevel.High
        case CapabilityKind.WorkspaceWrite | CapabilityKind.PeerMessage |
            CapabilityKind.Delegate | CapabilityKind.ExtensionInvoke => ApprovalRiskLevel
            .Medium
        case CapabilityKind.WorkspaceRead => ApprovalRiskLevel.Low
    }
    let label = capabilityDisplayName(capability.kind)
    ToolApprovalMetadata(
        label,
        RiskAssessment(level),
        ApprovalGrantScope(label, pathPrefix: capability.resource)
    )
}

public func approvalRiskFromLevel(level: ApprovalRiskLevel): ApprovalRisk {
    match (level) {
        case ApprovalRiskLevel.Low => ApprovalRisk.Low
        case ApprovalRiskLevel.Medium => ApprovalRisk.Medium
        case ApprovalRiskLevel.High | ApprovalRiskLevel.Critical => ApprovalRisk.High
    }
}

public func approvalRiskLevelName(level: ApprovalRiskLevel): String {
    match (level) {
        case ApprovalRiskLevel.Low => "low"
        case ApprovalRiskLevel.Medium => "medium"
        case ApprovalRiskLevel.High => "high"
        case ApprovalRiskLevel.Critical => "critical"
    }
}

public func approvalDecisionSourceName(source: ApprovalDecisionSource): String {
    match (source) {
        case ApprovalDecisionSource.StaticPolicy => "static_policy"
        case ApprovalDecisionSource.SessionGrant => "session_grant"
        case ApprovalDecisionSource.AiReviewer => "ai_reviewer"
        case ApprovalDecisionSource.User => "user"
        case ApprovalDecisionSource.HardDeny => "hard_deny"
    }
}

public func approvalRiskName(risk: ApprovalRisk): String {
    match (risk) {
        case ApprovalRisk.Low => "low"
        case ApprovalRisk.Medium => "medium"
        case ApprovalRisk.High => "high"
    }
}

public func capabilityDisplayName(kind: CapabilityKind): String {
    match (kind) {
        case CapabilityKind.WorkspaceRead => "workspace.read"
        case CapabilityKind.WorkspaceWrite => "workspace.write"
        case CapabilityKind.ProcessSpawn => "process.spawn"
        case CapabilityKind.NetworkAccess => "network.access"
        case CapabilityKind.PeerMessage => "peer.message"
        case CapabilityKind.Delegate => "delegate"
        case CapabilityKind.ExtensionInvoke => "extension.invoke"
    }
}

public class ToolDenial {
    public let callId: String
    public let toolName: String
    public let reason: AgentError

    public init(callId: String, toolName: String, reason: AgentError) {
        this.callId = callId
        this.toolName = toolName
        this.reason = reason
    }
}

public enum ToolInvocationResult {
    Completed(ToolResult)
    | NeedsApproval(ApprovalRequest)
    | Denied(ToolDenial)
}

// Distinguishes user/subagent execution from host-owned maintenance work.
// Maintenance runs remain fully budgeted and billable, but must not replace
// user-turn context indicators such as the last provider input size.
@Derive[Equatable]
public enum RunKind {
    Agent | Maintenance | Chat | Compaction | NavigationSummary | Verification
}

public class RunSnapshot {
    public let runId: RunId
    public let sessionId: SessionId
    public let status: RunState
    public let kind: RunKind
    public let sequence: Int64
    public let summary: String
    public let error: ?AgentError
    public let modelRequests: Int64
    public let usage: ModelUsage
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
    public let structuredOutput: ?AgentValue

    public init(
        runId: RunId,
        sessionId: SessionId,
        status: RunState,
        sequence!: Int64 = 0,
        summary!: String = "",
        error!: ?AgentError = None,
        modelRequests!: Int64 = 0,
        inputTokens!: Int64 = 0,
        outputTokens!: Int64 = 0,
        toolCalls!: Int64 = 0,
        turns!: Int64 = 0,
        reasoningTokens!: Int64 = 0,
        cacheReadTokens!: Int64 = 0,
        cacheWriteTokens!: Int64 = 0,
        costMicros!: ?Int64 = None,
        lastInputTokens!: Int64 = 0,
        lastOutputTokens!: Int64 = 0,
        lastRequestDurationMillis!: Int64 = 0,
        usage!: ?ModelUsage = None,
        structuredOutput!: ?AgentValue = None,
        kind!: RunKind = RunKind.Agent
    ) {
        let resolvedUsage = match (usage) {
            case Some(value) => value
            case None => ModelUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWriteTokens: cacheWriteTokens,
                costMicros: costMicros
            )
        }
        if (sequence < 0 || modelRequests < 0 || toolCalls < 0 || turns < 0 ||
            lastInputTokens < 0 || lastOutputTokens < 0 || lastRequestDurationMillis < 0) {
            throw IllegalArgumentException("run snapshot counters must not be negative")
        }
        this.runId = runId
        this.sessionId = sessionId
        this.status = status
        this.kind = kind
        this.sequence = sequence
        this.summary = summary
        this.error = error
        this.modelRequests = modelRequests
        this.usage = resolvedUsage
        this.inputTokens = resolvedUsage.inputTokens
        this.outputTokens = resolvedUsage.outputTokens
        this.reasoningTokens = resolvedUsage.reasoningTokens
        this.cacheReadTokens = resolvedUsage.cacheReadTokens
        this.cacheWriteTokens = resolvedUsage.cacheWriteTokens
        this.costMicros = resolvedUsage.costMicros
        this.lastInputTokens = lastInputTokens
        this.lastOutputTokens = lastOutputTokens
        this.lastRequestDurationMillis = lastRequestDurationMillis
        this.toolCalls = toolCalls
        this.turns = turns
        this.structuredOutput = structuredOutput
    }
}

@Derive[Equatable]
public enum AgentEventKind {
    RunStarted
    | RunStateChanged
    | Model
    | Tool
    | Approval
    | Budget
    | Diagnostic
    | Audit
    | Transcript
    | Completed
}

public class AgentEvent {
    public let meta: EventMeta
    public let payload: AgentEventPayload
    public let sequence: Int64
    public let runId: RunId
    public let kind: AgentEventKind
    public let detail: AgentValue

    public init(meta: EventMeta, payload: AgentEventPayload) {
        this.meta = meta
        this.payload = payload
        this.sequence = meta.sequence
        this.runId = meta.runId
        this.kind = eventKind(payload)
        this.detail = eventDetail(payload)
    }

}

public type AgentEventSink = (AgentEvent) -> Unit

public class EventPage {
    public let events: Array<AgentEvent>
    public let nextSequence: Int64
    public let resyncRequired: Bool

    public init(
        events: Array<AgentEvent>,
        nextSequence: Int64,
        resyncRequired!: Bool = false
    ) {
        this.events = events
        this.nextSequence = nextSequence
        this.resyncRequired = resyncRequired
    }
}

@Derive[Equatable]
public enum OperationStatus {
    Prepared
    | Approved
    | Executing
    | Committed
    | Failed
    | RecoveryRequired
}

public class OperationRecord {
    public let operationId: OperationId
    public let runId: RunId
    public let status: OperationStatus
    public let capability: Capability
    public let requestDigest: String
    public let call: ?ToolCall

    public init(
        operationId: OperationId,
        runId: RunId,
        status: OperationStatus,
        capability: Capability,
        requestDigest: String,
        call!: ?ToolCall = None
    ) {
        this.operationId = operationId
        this.runId = runId
        this.status = status
        this.capability = capability
        this.requestDigest = requestDigest
        this.call = call
    }
}

public class OperationReceipt {
    public let operationId: OperationId
    public let committed: Bool
    public let detail: AgentValue
    public let isError: Bool

    public init(
        operationId: OperationId,
        committed: Bool,
        detail: AgentValue,
        isError!: Bool = false
    ) {
        this.operationId = operationId
        this.committed = committed
        this.detail = detail
        this.isError = isError
    }
}

public class WorkspaceReadRequest {
    public let path: String
    public init(path: String) {
        this.path = path
    }
}

public class WorkspaceReadResult {
    public let path: String
    public let content: String
    public init(path: String, content: String) {
        this.path = path
        this.content = content
    }
}

public class WorkspaceMutation {
    public let operationId: OperationId
    public let path: String
    public let expected: String
    public let replacement: String

    public init(
        operationId: OperationId,
        path: String,
        expected: String,
        replacement: String
    ) {
        this.operationId = operationId
        this.path = path
        this.expected = expected
        this.replacement = replacement
    }
}

@Derive[Equatable]
public enum ProcessSandboxMode {
    Host | WorkspaceReadOnly | WorkspaceReadWrite
}

public class ProcessRequest {
    public let operationId: OperationId
    public let executable: String
    public let arguments: Array<String>
    public let workingDirectory: String
    public let timeoutMillis: Int64
    public let sandboxMode: ProcessSandboxMode
    public let networkAccess: Bool
    // Sandboxed processes inherit no ambient environment by default. These
    // names are code-authored grants; secret-looking variables additionally
    // require an entry in secretEnvironmentAllowlist.
    public let environmentAllowlist: Array<String>
    public let secretEnvironmentAllowlist: Array<String>
    // Values already embedded in argv (for example an HTTP credential) are
    // registered with the sandbox output redactor without being injected into
    // the child environment.
    public let redactedValues: Array<String>

    public init(
        executable: String,
        operationId!: OperationId = OperationId("process"),
        arguments!: Array<String> = [],
        workingDirectory!: String = "",
        timeoutMillis!: Int64 = 60000,
        sandboxMode!: ProcessSandboxMode = ProcessSandboxMode.Host,
        networkAccess!: Bool = false,
        environmentAllowlist!: Array<String> = [],
        secretEnvironmentAllowlist!: Array<String> = [],
        redactedValues!: Array<String> = []
    ) {
        if (executable.trimAscii() == "") {
            throw IllegalArgumentException("process executable must not be empty")
        }
        if (timeoutMillis < 1) {
            throw IllegalArgumentException("process timeout must be positive")
        }
        this.operationId = operationId
        this.executable = executable
        this.arguments = arguments
        this.workingDirectory = workingDirectory
        this.timeoutMillis = timeoutMillis
        this.sandboxMode = sandboxMode
        this.networkAccess = networkAccess
        this.environmentAllowlist = environmentAllowlist
        this.secretEnvironmentAllowlist = secretEnvironmentAllowlist
        this.redactedValues = redactedValues
    }
}

public class ProcessResult {
    public let exitCode: Int64
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    public let workingDirectory: String
    public let truncated: Bool

    public init(
        exitCode: Int64,
        stdout!: String = "",
        stderr!: String = "",
        timedOut!: Bool = false,
        workingDirectory!: String = "",
        truncated!: Bool = false
    ) {
        this.exitCode = exitCode
        this.stdout = stdout
        this.stderr = stderr
        this.timedOut = timedOut
        this.workingDirectory = workingDirectory
        this.truncated = truncated
    }
}
