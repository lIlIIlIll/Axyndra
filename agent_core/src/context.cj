package agent_core

import agent_domain.*
import std.collection.*

// Persistent compaction uses a high-water trigger and a lower target so one
// compaction releases meaningful headroom. Message count is only an emergency
// guard for pathological histories; it is not the normal trigger.
public class ContextCompactionPolicy {
    public let triggerPercent: Int64
    public let targetPercent: Int64
    public let emergencyMessageLimit: Int64
    public let keepRecentTokens: Int64
    public let keepRecentMessages: Int64
    public let oversizedToolResultTokens: Int64

    public init(
        triggerPercent!: Int64 = 88,
        targetPercent!: Int64 = 60,
        emergencyMessageLimit!: Int64 = 512,
        keepRecentTokens!: Int64 = 50000,
        keepRecentMessages!: Int64 = 12,
        oversizedToolResultTokens!: Int64 = 12000
    ) {
        if (triggerPercent < 1 || triggerPercent > 100 || targetPercent < 1 ||
            targetPercent >= triggerPercent || emergencyMessageLimit < 1 || keepRecentTokens < 1 ||
            keepRecentMessages < 1 || oversizedToolResultTokens < 64) {
            throw IllegalArgumentException("context compaction policy values are out of range")
        }
        this.triggerPercent = triggerPercent
        this.targetPercent = targetPercent
        this.emergencyMessageLimit = emergencyMessageLimit
        this.keepRecentTokens = keepRecentTokens
        this.keepRecentMessages = keepRecentMessages
        this.oversizedToolResultTokens = oversizedToolResultTokens
    }
}

public class ContextWindow {
    public let messages: Array<ModelMessage>
    public let estimatedTokens: Int64
    public let startIndex: Int64
    public let truncatedToolResults: Int64
    public let overBudget: Bool

    public init(
        messages: Array<ModelMessage>,
        estimatedTokens: Int64,
        startIndex: Int64,
        truncatedToolResults: Int64,
        overBudget: Bool
    ) {
        this.messages = messages
        this.estimatedTokens = estimatedTokens
        this.startIndex = startIndex
        this.truncatedToolResults = truncatedToolResults
        this.overBudget = overBudget
    }
}

class TruncatedContext {
    let messages: Array<ModelMessage>
    let toolResults: Int64

    init(messages: Array<ModelMessage>, toolResults: Int64) {
        this.messages = messages
        this.toolResults = toolResults
    }
}

// Cheap deterministic estimate: CJK/non-ASCII code points are charged at
// roughly one token each (four-byte code points at two), Latin text at about
// four bytes/token, and JSON/tool payloads more conservatively. Framing and
// tool protocol fields receive fixed overhead. No serialization or tokenizer
// dependency is required.
public func estimateContextTokens(
    messages: Array<ModelMessage>,
    system!: String = "",
    tools!: Array<ModelToolDefinition> = []
): Int64 {
    var tokens = estimateTextTokens(system, 4) + 8
    for (tool in tools) {
        tokens += 18 + estimateTextTokens(tool.name, 3) + estimateTextTokens(tool.description, 4) +
            estimateAgentValueTokens(tool.inputSchema)
    }
    for (message in messages) {
        tokens += estimateMessageTokens(message)
    }
    max(1, tokens)
}

public func estimateMessagesTokens(messages: Array<ModelMessage>): Int64 {
    var tokens: Int64 = 0
    for (message in messages) {
        tokens += estimateMessageTokens(message)
    }
    tokens
}

public func compactionTriggerTokens(
    budget: ResourceBudget,
    policy: ContextCompactionPolicy
): Int64 {
    max(1, budget.maxInputTokens * policy.triggerPercent / 100)
}

public func compactionTargetTokens(
    budget: ResourceBudget,
    policy: ContextCompactionPolicy
): Int64 {
    max(1, budget.maxInputTokens * policy.targetPercent / 100)
}

public func shouldCompactContext(
    messages: Array<ModelMessage>,
    budget: ResourceBudget,
    policy: ContextCompactionPolicy,
    system!: String = "",
    tools!: Array<ModelToolDefinition> = []
): Bool {
    messages.size >= policy.emergencyMessageLimit ||
        estimateContextTokens(messages, system: system, tools: tools) >= compactionTriggerTokens(budget, policy)
}

// Return the first legal retained-message index at or after `candidate`.
// A tool-result message can only be interpreted together with the immediately
// preceding assistant tool-call message, so a cut inside a tool round advances
// past the complete result group. Unknown blocks are conservative cut points:
// they are summarized/discarded instead of becoming an unproven window root.
public func findSafeCutPoint(
    messages: Array<ModelMessage>,
    candidate: Int64
): Int64 {
    var start = max(0, min(candidate, messages.size))
    while (start < messages.size) {
        if (isOnlyToolResultMessage(messages[start])) {
            start += 1
            continue
        }
        if (containsUnknownProtocolBlock(messages[start])) {
            start += 1
            continue
        }
        if (!toolProtocolCompleteFrom(messages, start)) {
            start += 1
            continue
        }
        break
    }
    start
}

public func findRecentTokenCutPoint(
    messages: Array<ModelMessage>,
    maxTokens: Int64
): Int64 {
    var used: Int64 = 0
    var start = messages.size
    var index = messages.size
    while (index > 0) {
        let next = estimateMessageTokens(messages[index - 1])
        if (used + next > maxTokens) {
            break
        }
        used += next
        index -= 1
        start = index
    }
    findSafeCutPoint(messages, start)
}

// Build one request window without mutating persistent session history. It
// accounts for the system prompt and tool definitions, applies the optional
// message-count emergency cap, truncates only oversized historical payloads,
// and always selects a protocol-safe boundary.
public func buildRequestContext(
    messages: Array<ModelMessage>,
    budget: ResourceBudget,
    system!: String = "",
    tools!: Array<ModelToolDefinition> = [],
    oversizedToolResultTokens!: Int64 = 12000
): ContextWindow {
    let fixedTokens = estimateContextTokens([], system: system, tools: tools)
    if (fixedTokens > budget.maxInputTokens) {
        return ContextWindow([], fixedTokens, messages.size, 0, true)
    }
    let perPayloadLimit = min(
        oversizedToolResultTokens,
        max(128, (budget.maxInputTokens - fixedTokens) / 3)
    )
    let truncated = truncateHistoricalToolPayloads(messages, perPayloadLimit)
    let normalized = truncated.messages
    let available = max(0, budget.maxInputTokens - fixedTokens)
    var used: Int64 = 0
    var tokenStart = normalized.size
    var index = normalized.size
    while (index > 0) {
        let next = estimateMessageTokens(normalized[index - 1])
        if (used + next > available) {
            break
        }
        used += next
        index -= 1
        tokenStart = index
    }
    if (!normalized.isEmpty() && tokenStart == normalized.size) {
        return ContextWindow(
            [],
            fixedTokens + estimateMessageTokens(normalized[normalized.size - 1]),
            normalized.size,
            truncated.toolResults,
            true
        )
    }
    var candidate = tokenStart
    if (budget.maxContextMessages > 0 && normalized.size - candidate > budget.maxContextMessages) {
        candidate = normalized.size - budget.maxContextMessages
    }
    let start = findSafeCutPoint(normalized, candidate)
    let selected = ArrayList<ModelMessage>()
    for (position in start..normalized.size) {
        selected.add(normalized[position])
    }
    let output = selected.toArray()
    let total = estimateContextTokens(output, system: system, tools: tools)
    ContextWindow(
        output,
        total,
        start,
        truncated.toolResults,
        total > budget.maxInputTokens
    )
}

// Public protocol assertion used by contract/property-style tests and by
// higher layers before persisting a compacted window. A legal tool round is an
// assistant message with one or more unique call IDs immediately followed by
// user tool results that contain every call ID and no unrelated result ID.
public func isToolProtocolComplete(messages: Array<ModelMessage>): Bool {
    toolProtocolCompleteFrom(messages, 0)
}

func toolProtocolCompleteFrom(messages: Array<ModelMessage>, start: Int64): Bool {
    var index: Int64 = start
    while (index < messages.size) {
        let calls = toolCallIds(messages[index])
        if (!calls.isEmpty()) {
            if (index + 1 >= messages.size || !isOnlyToolResultMessage(messages[index + 1])) {
                return false
            }
            let results = ArrayList<String>()
            var scan = index + 1
            while (scan < messages.size && isOnlyToolResultMessage(messages[scan])) {
                for (result in toolResultIds(messages[scan])) {
                    if (containsString(results, result)) {
                        return false
                    }
                    results.add(result)
                }
                scan += 1
            }
            if (!sameIds(calls, results.toArray())) {
                return false
            }
            index = scan
            continue
        }
        if (containsToolCallBlock(messages[index]) || containsToolResultBlock(messages[index])) {
            return false
        }
        index += 1
    }
    true
}

func estimateMessageTokens(message: ModelMessage): Int64 {
    var tokens: Int64 = 8
    for (block in message.blocks) {
        tokens += 6 + estimateTextTokens(block.text, 4)
        match (block.kind) {
            case ModelBlockKind.ToolCall | ModelBlockKind.ToolResult =>
                tokens += 12 + estimateTextTokens(block.callId, 3) + estimateTextTokens(block.name, 3) +
                    estimateAgentValueTokens(block.arguments)
            case ModelBlockKind.Image =>
                tokens += match (block.image) {
                    case Some(image) => estimateImageTokens(image)
                    case None => 1024
                }
            case ModelBlockKind.Reasoning => tokens += 4
            case _ => ()
        }
        match (block.opaqueState) {
            case Some(value) =>
                tokens += 12 + estimateTextTokens(value.providerId, 3) + estimateTextTokens(value.protocol, 3) +
                    estimateTextTokens(value.itemId, 3) + estimateTextTokens(value.payload, 3)
            case None => ()
        }
    }
    tokens
}

// Image billing is provider- and resolution-dependent, while the neutral
// model deliberately carries no provider-specific tile geometry. Reserve a
// conservative bounded allowance so image-only turns cannot bypass context
// compaction without treating base64 transport bytes as language tokens.
func estimateImageTokens(image: ModelImage): Int64 {
    match (image.sourceKind) {
        case ModelImageSourceKind.Url =>
            1024 + estimateTextTokens(image.data, 4)
        case ModelImageSourceKind.Base64 =>
            let decodedBytes = (image.data.size * 3) / 4
            1024 + min(16384, max(0, decodedBytes / 256))
    }
}

func estimateAgentValueTokens(value: AgentValue): Int64 {
    match (value.kind) {
        case ValueKind.Null | ValueKind.Boolean => 1
        case ValueKind.Number => max(1, estimateTextTokens(value.number, 3))
        case ValueKind.Text => estimateTextTokens(value.text, 3) + 2
        case ValueKind.List =>
            var tokens: Int64 = 2
            for (item in value.items) {
                tokens += 1 + estimateAgentValueTokens(item)
            }
            tokens
        case ValueKind.Object =>
            var tokens: Int64 = 2
            for (field in value.fields) {
                tokens += 3 + estimateTextTokens(field.name, 3) + estimateAgentValueTokens(field.value)
            }
            tokens
    }
}

func estimateTextTokens(value: String, asciiDivisor: Int64): Int64 {
    if (value == "") {
        return 0
    }
    let bytes = unsafe { value.rawData() }
    var weightedAscii: Int64 = 0
    var unicodeTokens: Int64 = 0
    var index: Int64 = 0
    while (index < bytes.size) {
        let byte = bytes[index]
        if (byte < 128) {
            weightedAscii += if ((byte >= 33 && byte <= 47) || (byte >= 58 && byte <= 64) ||
                (byte >= 91 && byte <= 96) || (byte >= 123 && byte <= 126)) { 2 } else { 1 }
            index += 1
        } else if (byte >= 240) {
            unicodeTokens += 2
            index += min(4, bytes.size - index)
        } else if (byte >= 224) {
            unicodeTokens += 1
            index += min(3, bytes.size - index)
        } else if (byte >= 192) {
            unicodeTokens += 1
            index += min(2, bytes.size - index)
        } else {
            // Invalid/continuation bytes are charged conservatively.
            unicodeTokens += 1
            index += 1
        }
    }
    unicodeTokens + (weightedAscii + asciiDivisor - 1) / asciiDivisor
}

func truncateHistoricalToolPayloads(
    messages: Array<ModelMessage>,
    tokenLimit: Int64
): TruncatedContext {
    let output = ArrayList<ModelMessage>()
    var truncatedResults: Int64 = 0
    for (message in messages) {
        let blocks = ArrayList<ModelBlock>()
        for (block in message.blocks) {
            if ((block.kind == ModelBlockKind.ToolCall || block.kind == ModelBlockKind.ToolResult) &&
                estimateAgentValueTokens(block.arguments) + estimateTextTokens(block.text, 3) > tokenLimit) {
                let originalTokens = estimateAgentValueTokens(block.arguments) + estimateTextTokens(block.text, 3)
                blocks.add(
                    ModelBlock(
                        block.kind,
                        text: truncateContextText(block.text, tokenLimit * 2),
                        callId: block.callId,
                        name: block.name,
                        arguments: truncateAgentValue(block.arguments, tokenLimit * 2),
                        isError: block.isError,
                        opaqueState: block.opaqueState
                    )
                )
                if (block.kind == ModelBlockKind.ToolResult) {
                    truncatedResults += 1
                }
                // Preserve deterministic size metadata without changing the
                // tool-result kind/call ID that providers use for pairing.
                if (block.kind == ModelBlockKind.ToolResult && blocks.size > 0) {
                    let last = blocks[blocks.size - 1]
                    blocks[blocks.size - 1] = ModelBlock(
                        last.kind,
                        text: last.text + if (last.text == "") { "" } else { "\n" } +
                            "[historical tool output truncated; estimated original tokens: " +
                            originalTokens.toString() + "]",
                        callId: last.callId,
                        name: last.name,
                        arguments: last.arguments,
                        isError: last.isError,
                        opaqueState: last.opaqueState
                    )
                }
            } else {
                blocks.add(block)
            }
        }
        output.add(ModelMessage(message.role, blocks.toArray()))
    }
    TruncatedContext(output.toArray(), truncatedResults)
}

func truncateAgentValue(value: AgentValue, byteLimit: Int64): AgentValue {
    match (value.kind) {
        case ValueKind.Text => textValue(truncateContextText(value.text, byteLimit))
        case ValueKind.List =>
            let items = ArrayList<AgentValue>()
            let childLimit = max(64, byteLimit / max(1, value.items.size))
            for (item in value.items) {
                items.add(truncateAgentValue(item, childLimit))
            }
            listValue(items.toArray())
        case ValueKind.Object =>
            let fields = ArrayList<ValueField>()
            let childLimit = max(64, byteLimit / max(1, value.fields.size))
            for (field in value.fields) {
                fields.add(ValueField(field.name, truncateAgentValue(field.value, childLimit)))
            }
            objectValue(fields.toArray())
        case _ => value
    }
}

func truncateContextText(value: String, byteLimit: Int64): String {
    let bytes = unsafe { value.rawData() }
    if (bytes.size <= byteLimit || byteLimit < 32) {
        return value
    }
    let marker = "\n... [truncated " + bytes.size.toString() + " bytes] ...\n"
    let markerBytes = unsafe { marker.rawData() }
    let side = max(8, (byteLimit - markerBytes.size) / 2)
    let head = safeUtf8Prefix(bytes, side)
    let tail = safeUtf8Suffix(bytes, side)
    head + marker + tail
}

func safeUtf8Prefix(bytes: Array<Byte>, limit: Int64): String {
    var end = min(bytes.size, limit)
    while (end > 0) {
        try {
            return String.fromUtf8(bytes[..end])
        } catch (_: Exception) {
            end -= 1
        }
    }
    ""
}

func safeUtf8Suffix(bytes: Array<Byte>, limit: Int64): String {
    var start = max(0, bytes.size - limit)
    while (start < bytes.size) {
        try {
            return String.fromUtf8(bytes[start..bytes.size])
        } catch (_: Exception) {
            start += 1
        }
    }
    ""
}

func isOnlyToolResultMessage(message: ModelMessage): Bool {
    if (message.role != ModelRole.User || message.blocks.isEmpty()) {
        return false
    }
    for (block in message.blocks) {
        if (block.kind != ModelBlockKind.ToolResult) {
            return false
        }
    }
    true
}

func containsToolCallBlock(message: ModelMessage): Bool {
    for (block in message.blocks where block.kind == ModelBlockKind.ToolCall) {
        return true
    }
    false
}

func containsToolResultBlock(message: ModelMessage): Bool {
    for (block in message.blocks where block.kind == ModelBlockKind.ToolResult) {
        return true
    }
    false
}

func containsUnknownProtocolBlock(message: ModelMessage): Bool {
    for (block in message.blocks where block.kind == ModelBlockKind.Unknown) {
        return true
    }
    false
}

func toolCallIds(message: ModelMessage): Array<String> {
    let ids = ArrayList<String>()
    if (message.role != ModelRole.Assistant) {
        return ids.toArray()
    }
    for (block in message.blocks where block.kind == ModelBlockKind.ToolCall) {
        if (block.callId == "" || containsString(ids, block.callId)) {
            return []
        }
        ids.add(block.callId)
    }
    ids.toArray()
}

func toolResultIds(message: ModelMessage): Array<String> {
    let ids = ArrayList<String>()
    if (!isOnlyToolResultMessage(message)) {
        return ids.toArray()
    }
    for (block in message.blocks) {
        if (block.callId == "" || containsString(ids, block.callId)) {
            return []
        }
        ids.add(block.callId)
    }
    ids.toArray()
}

func sameIds(left: Array<String>, right: Array<String>): Bool {
    if (left.size != right.size || left.isEmpty()) {
        return false
    }
    let values = ArrayList<String>()
    values.add(all: right)
    for (item in left where !containsString(values, item)) {
        return false
    }
    true
}

func containsString(values: ArrayList<String>, value: String): Bool {
    for (item in values where item == value) {
        return true
    }
    false
}
