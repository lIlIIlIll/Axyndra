package model_provider_runtime

import agent_domain.*
import yjson.*
import yjson_support.*
import std.collection.*

public func modelProviderTerminalValue(value: TerminalEvidence): AgentValue { objectValue([
    ValueField("protocol", textValue(value.protocol)), ValueField("event", textValue(value.terminalEventKind)),
    ValueField("stop_reason", textValue(value.rawStopReason)),
    ValueField("message_terminal", boolValue(value.messageTerminalObserved)),
    ValueField("stream_eof", boolValue(value.streamEofObserved)),
    ValueField("adapter_version", textValue(value.adapterVersion))
]) }
func providerTerminal(value: AgentValue): TerminalEvidence {
    providerExact(value, ["protocol", "event", "stop_reason", "message_terminal", "stream_eof", "adapter_version"])
    TerminalEvidence(providerText(value, "protocol"), providerText(value, "event"),
        rawStopReason: providerText(value, "stop_reason"),
        messageTerminalObserved: providerBool(value, "message_terminal"),
        streamEofObserved: providerBool(value, "stream_eof"), adapterVersion: providerText(value, "adapter_version"))
}
public func modelProviderUsageValue(value: ModelUsage): AgentValue { objectValue([
    ValueField("input", integerValue(value.inputTokens)), ValueField("output", integerValue(value.outputTokens)),
    ValueField("reasoning", integerValue(value.reasoningTokens)), ValueField("cache_read", integerValue(value.cacheReadTokens)),
    ValueField("cache_write", integerValue(value.cacheWriteTokens)),
    ValueField("cost_micros", match (value.costMicros) { case Some(n) => integerValue(n); case None => nullValue() }),
    ValueField("source", textValue(modelUsageSourceName(value.source))),
    ValueField("evidence", match (value.evidence) { case None => nullValue(); case Some(e) => objectValue([
        ValueField("protocol", textValue(e.protocol)), ValueField("event", textValue(e.eventKind)),
        ValueField("response_id", textValue(e.providerResponseId))]) })
]) }
func providerUsage(value: AgentValue): ModelUsage {
    providerExact(value, ["input", "output", "reasoning", "cache_read", "cache_write", "cost_micros", "source", "evidence"])
    let source = match (providerText(value, "source")) {
        case "unknown" => ModelUsageSource.Unknown
        case "provider_final" => ModelUsageSource.ProviderFinal
        case "provider_stream_final" => ModelUsageSource.ProviderStreamFinal
        case "estimated" => ModelUsageSource.Estimated
        case _ => throw IllegalArgumentException("invalid provider usage source")
    }
    let rawEvidence = providerField(value, "evidence")
    let evidence: ?ModelUsageEvidence = if (rawEvidence.unifiedKind == ValueKind.Null) { None } else {
        providerExact(rawEvidence, ["protocol", "event", "response_id"])
        Some(ModelUsageEvidence(providerText(rawEvidence, "protocol"), providerText(rawEvidence, "event"),
            providerResponseId: providerText(rawEvidence, "response_id")))
    }
    let rawCost = providerField(value, "cost_micros")
    let cost: ?Int64 = if (rawCost.unifiedKind == ValueKind.Null) { None }
        else { Some(providerInt(value, "cost_micros")) }
    let input = providerInt(value, "input"); let output = providerInt(value, "output")
    let read = providerInt(value, "cache_read"); let write = providerInt(value, "cache_write")
    // Subtraction avoids integer overflow before the domain subset check.
    if (input < 0 || read < 0 || write < 0 || read > input || write > input - read) {
        throw IllegalArgumentException("invalid cached token accounting")
    }
    if (source == ModelUsageSource.Unknown && cost.isSome()) {
        throw IllegalArgumentException("unknown usage cannot claim known cost")
    }
    ModelUsage(inputTokens: input, outputTokens: output,
        reasoningTokens: providerInt(value, "reasoning"), cacheReadTokens: read, cacheWriteTokens: write,
        costMicros: cost, source: source, evidence: evidence)
}

// Reuse the exact Domain block codec (including images and opaque replay state).
// These are serialization-only ModelMessage values, never a request or Attempt.
public func modelProviderReplyValue(reply: ModelReply): AgentValue {
    modelProviderReplyWithBlocks(reply, reply.blocks)
}
func modelProviderReplyWithBlocks(reply: ModelReply, replyBlocks: Array<ModelBlock>): AgentValue {
    let neutral = modelRequestSnapshotValue(ModelRequest("codec", [ModelMessage(ModelRole.Assistant, replyBlocks)]))
    let blocks = providerField(providerField(neutral, "messages").items[0], "blocks")
    objectValue([
        ValueField("blocks", blocks), ValueField("stop_reason", textValue(reply.stopReason)),
        ValueField("usage", modelProviderUsageValue(reply.usage)), ValueField("accepted", boolValue(reply.acceptedOutput)),
        ValueField("provider_id", textValue(reply.providerId)), ValueField("response_id", textValue(reply.responseId)),
        ValueField("structured_output", reply.structuredOutput ?? nullValue()),
        ValueField("terminal", match (reply.terminalEvidence) {
            case Some(value) => modelProviderTerminalValue(value); case None => nullValue() }),
        ValueField("disposition", textValue(match (reply.completionDisposition) {
            case CompletionDisposition.Complete => "complete"; case CompletionDisposition.ToolUse => "tool_use"
            case CompletionDisposition.OutputLimited => "output_limited"; case CompletionDisposition.Filtered => "filtered"
            case CompletionDisposition.ProtocolIncomplete => "protocol_incomplete"; case CompletionDisposition.Unknown => "unknown" })),
        ValueField("outcome", textValue(match (reply.decisionOutcome) {
            case DecisionOutcome.Response => "response"; case DecisionOutcome.ToolCalls => "tool_calls"
            case DecisionOutcome.Refusal => "refusal"; case DecisionOutcome.Unknown => "unknown" })),
        ValueField("validation_version", integerValue(reply.validationVersion))
    ])
}
func providerReply(value: AgentValue): ModelReply {
    providerExact(value, ["blocks", "stop_reason", "usage", "accepted", "provider_id", "response_id",
        "structured_output", "terminal", "disposition", "outcome", "validation_version"])
    let neutral = modelRequestSnapshotValue(ModelRequest("codec", []))
    neutral.put("messages", listValue([objectValue([ValueField("role", textValue("assistant")),
        ValueField("blocks", providerField(value, "blocks"))])]))
    let parsed = match (modelRequestFromSnapshotValue(neutral, "codec")) {
        case Result.Ok(request) => request
        case Result.Err(_) => throw IllegalArgumentException("invalid provider output blocks")
    }
    let terminal = providerTerminal(providerField(value, "terminal"))
    let structured = providerField(value, "structured_output")
    ModelReply(parsed.messages[0].blocks, stopReason: providerText(value, "stop_reason"),
        usage: Some(providerUsage(providerField(value, "usage"))), acceptedOutput: providerBool(value, "accepted"),
        providerId: providerText(value, "provider_id"), responseId: providerText(value, "response_id"),
        structuredOutput: if (structured.unifiedKind == ValueKind.Null) { None } else { Some(structured) },
        terminalEvidence: Some(terminal), completionDisposition: match (providerText(value, "disposition")) {
            case "complete" => CompletionDisposition.Complete; case "tool_use" => CompletionDisposition.ToolUse
            case "output_limited" => CompletionDisposition.OutputLimited; case "filtered" => CompletionDisposition.Filtered
            case "protocol_incomplete" => CompletionDisposition.ProtocolIncomplete; case "unknown" => CompletionDisposition.Unknown
            case _ => throw IllegalArgumentException("invalid provider disposition") },
        decisionOutcome: match (providerText(value, "outcome")) {
            case "response" => DecisionOutcome.Response; case "tool_calls" => DecisionOutcome.ToolCalls
            case "refusal" => DecisionOutcome.Refusal; case "unknown" => DecisionOutcome.Unknown
            case _ => throw IllegalArgumentException("invalid provider outcome") },
        validationVersion: providerInt(value, "validation_version"))
}

public func modelProviderFrame(identity: AgentValue, sequence: Int64, kind: String, payload: AgentValue): AgentValue {
    objectValue([ValueField("schema", textValue(MODEL_PROVIDER_PROTOCOL)), ValueField("identity", identity),
        ValueField("sequence", integerValue(sequence)), ValueField("kind", textValue(kind)), ValueField("payload", payload)])
}
