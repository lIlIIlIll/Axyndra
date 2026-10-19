package native_model_providers

import agent_domain.*
import std.collection.*

// Provider wire names are a projection of the already frozen request. They
// never replace canonical catalog names, identities, arguments or Decisions.
// A SHA-256 name fits the strictest supported ASCII/64 grammar. Preserve
// already portable names and reject every ambiguous mapping before I/O.
func portableModelToolName(name: String): Bool {
    if (name.size < 1 || name.size > 64) { return false }
    for (byte in name.toArray()) {
        if (!((byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) || byte == 45 || byte == 95)) { return false }
    }
    true
}

class ModelToolNames {
    private let projected = HashMap<String, String>()
    private let allWireNames = HashMap<String, String>()
    private let offered = HashMap<String, String>()
    private let rejectedCalls = HashSet<String>()
    private var invalidReply = false

    init(request: ModelRequest) {
        for (tool in request.tools) {
            let wire = add(tool.name)
            if (offered.contains(wire)) { throw ModelWireFailure("model.tool_name_duplicate") }
            offered[wire] = tool.name
        }
        // Include history in collision checks: an unavailable historical Tool
        // must never become an active one through an alias collision.
        for (message in request.messages) {
            for (block in message.blocks where (block.kind == ModelBlockKind.ToolCall ||
                block.kind == ModelBlockKind.ToolResult) && block.name != "") { add(block.name) }
        }
    }

    private func add(name: String): String {
        match (projected.get(name)) { case Some(value) => return value; case None => () }
        if (name == "") { throw ModelWireFailure("model.tool_name_invalid") }
        let wire = if (portableModelToolName(name)) { name } else { modelPolicySha256Text(name) }
        match (allWireNames.get(wire)) {
            case Some(other) => if (other != name) { throw ModelWireFailure("model.tool_name_collision") }
            case None => ()
        }
        projected[name] = wire; allWireNames[wire] = name
        wire
    }

    private func blockWithName(block: ModelBlock, name: String): ModelBlock {
        ModelBlock(block.kind, text: block.text, callId: block.callId, name: name,
            arguments: block.arguments, isError: block.isError, image: block.image,
            receiptId: block.receiptId, opaqueState: block.opaqueState)
    }

    func request(original: ModelRequest): ModelRequest {
        let messages = ArrayList<ModelMessage>()
        for (message in original.messages) {
            let blocks = ArrayList<ModelBlock>()
            for (block in message.blocks) {
                if ((block.kind == ModelBlockKind.ToolCall || block.kind == ModelBlockKind.ToolResult) && block.name != "") {
                    blocks.add(blockWithName(block, projected.get(block.name).getOrThrow()))
                } else { blocks.add(block) }
            }
            messages.add(ModelMessage(message.role, blocks.toArray()))
        }
        let tools = original.tools.map { tool => ModelToolDefinition(
            projected.get(tool.name).getOrThrow(), tool.description, tool.inputSchema) }
        ModelRequest(original.model, messages.toArray(), system: original.system, tools: tools,
            thinking: original.thinking, wireMaxOutputTokens: Some(original.wireMaxOutputTokens),
            resolvedPolicy: original.resolvedPolicy, streaming: original.streaming,
            parallelToolCalls: original.parallelToolCalls, requestId: original.requestId,
            serviceTier: original.serviceTier, cachePolicy: original.cachePolicy,
            cacheKey: original.cacheKey, toolChoice: original.toolChoice,
            structuredOutput: original.structuredOutput,
            transportHardTimeoutMillis: original.transportHardTimeoutMillis)
    }

    func event(event: ModelEvent): ?ModelEvent {
        match (event) {
            case ModelEvent.ToolCallStarted(id, name) => match (offered.get(name)) {
                case Some(canonical) => return Some(ModelEvent.ToolCallStarted(id, canonical))
                case None => invalidReply = true; rejectedCalls.add(id); return None
            }
            case ModelEvent.ToolArgumentsDelta(id, _) =>
                if (rejectedCalls.contains(id)) { return None }
            case ModelEvent.ToolCallCompleted(id) =>
                if (rejectedCalls.contains(id)) { return None }
            case _ => ()
        }
        Some(event)
    }

    func reply(original: ModelReply): ?ModelReply {
        let blocks = ArrayList<ModelBlock>()
        for (block in original.blocks) {
            if (block.kind == ModelBlockKind.ToolCall) {
                match (offered.get(block.name)) {
                    case Some(canonical) => blocks.add(blockWithName(block, canonical))
                    case None => invalidReply = true
                }
            } else { blocks.add(block) }
        }
        if (invalidReply) { return None }
        Some(ModelReply(blocks.toArray(), stopReason: original.stopReason, usage: Some(original.usage),
            acceptedOutput: original.acceptedOutput, providerId: original.providerId,
            responseId: original.responseId, structuredOutput: original.structuredOutput,
            terminalEvidence: original.terminalEvidence, completionDisposition: original.completionDisposition,
            decisionOutcome: original.decisionOutcome, validationVersion: original.validationVersion))
    }
}


func unknownModelToolName(usage: ModelUsage): AgentError {
    let fields = ArrayList<ErrorField>([
        ErrorField("usage_input_tokens", usage.inputTokens.toString()),
        ErrorField("usage_output_tokens", usage.outputTokens.toString()),
        ErrorField("usage_reasoning_tokens", usage.reasoningTokens.toString()),
        ErrorField("usage_cache_read_tokens", usage.cacheReadTokens.toString()),
        ErrorField("usage_cache_write_tokens", usage.cacheWriteTokens.toString()),
        ErrorField("usage_source", modelUsageSourceName(usage.source))
    ])
    match (usage.evidence) {
        case Some(evidence) =>
            fields.add(ErrorField("usage_protocol", evidence.protocol))
            fields.add(ErrorField("usage_event", evidence.eventKind))
        case None => ()
    }
    AgentError(AgentErrorKind.Protocol, "model.tool_name_unknown", "provider returned an unoffered wire Tool name",
        fields: fields.toArray(), attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError)))
}
