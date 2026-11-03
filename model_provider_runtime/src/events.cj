package model_provider_runtime

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// A codec for existing events, not an alternate model execution loop. The
// host alone emits Completed after terminal validation and actual cleanup ACK.
public func modelProviderEventValue(event: ModelEvent): ?AgentValue {
    let fields = ArrayList<ValueField>()
    match (event) {
        case ModelEvent.TextDelta(text) => fields.add(ValueField("kind", textValue("text"))); fields.add(ValueField("text", textValue(text)))
        case ModelEvent.ReasoningDelta(text) => fields.add(ValueField("kind", textValue("reasoning"))); fields.add(ValueField("text", textValue(text)))
        case ModelEvent.ToolCallStarted(id, name) => fields.add(ValueField("kind", textValue("tool_start"))); fields.add(ValueField("id", textValue(id))); fields.add(ValueField("name", textValue(name)))
        case ModelEvent.ToolArgumentsDelta(id, text) => fields.add(ValueField("kind", textValue("tool_arguments"))); fields.add(ValueField("id", textValue(id))); fields.add(ValueField("text", textValue(text)))
        case ModelEvent.ToolCallCompleted(id) => fields.add(ValueField("kind", textValue("tool_end"))); fields.add(ValueField("id", textValue(id)))
        case ModelEvent.UsageUpdated(input, output) => return Some(providerUsageEvent("usage_counts", input, output))
        case ModelEvent.Completed => return None
        case ModelEvent.ProviderProgress(progress) => match (progress) {
            case ProviderStreamEvent.StreamStarted(protocol) => fields.add(ValueField("kind", textValue("started"))); fields.add(ValueField("protocol", textValue(protocol)))
            case ProviderStreamEvent.ContentBlockStarted(index, kind) => return Some(providerBlockEvent("block_start", index, kind))
            case ProviderStreamEvent.ContentBlockCompleted(index, kind) => return Some(providerBlockEvent("block_end", index, kind))
            case ProviderStreamEvent.MessageTerminalObserved(evidence) => fields.add(ValueField("kind", textValue("terminal"))); fields.add(ValueField("evidence", modelProviderTerminalValue(evidence)))
            case ProviderStreamEvent.UsageDelta(input, output) => return Some(providerUsageEvent("usage_delta", input, output))
            case ProviderStreamEvent.UsageCompleted(input, output) => return Some(providerUsageEvent("usage_completed", input, output))
            case ProviderStreamEvent.StreamTransportClosed => fields.add(ValueField("kind", textValue("transport_closed")))
            // Provider diagnostic text is untrusted. The typed failure follows;
            // do not smuggle arbitrary text or test controls across this path.
            case ProviderStreamEvent.ProviderError(_) => fields.add(ValueField("kind", textValue("provider_error")))
            case ProviderStreamEvent.ControlledFaultInjected(_, _) => throw IllegalArgumentException("host test control is not a provider event")
        }
    }
    Some(objectValue(fields.toArray()))
}
func providerUsageEvent(kind: String, input: Int64, output: Int64): AgentValue {
    objectValue([ValueField("kind", textValue(kind)), ValueField("input", integerValue(input)), ValueField("output", integerValue(output))])
}
func providerBlockEvent(kind: String, index: Int64, block: String): AgentValue {
    objectValue([ValueField("kind", textValue(kind)), ValueField("index", integerValue(index)), ValueField("block_kind", textValue(block))])
}

func providerFailureKindName(kind: AttemptFailureKind): String {
    match (kind) {
        case AttemptFailureKind.ProviderTerminalMissing => "terminal_missing"
        case AttemptFailureKind.ProtocolIncomplete => "protocol_incomplete"
        case AttemptFailureKind.OutputLimited => "output_limited"
        case AttemptFailureKind.OutputLimitedBeforeDecision => "output_limited_before_decision"
        case AttemptFailureKind.MalformedToolArguments => "malformed_tool_arguments"
        case AttemptFailureKind.ProviderProtocolError => "protocol"
        case _ => "transport"
    }
}
func providerFailureKind(value: String): AttemptFailureKind {
    match (value) {
        case "terminal_missing" => AttemptFailureKind.ProviderTerminalMissing
        case "protocol_incomplete" => AttemptFailureKind.ProtocolIncomplete
        case "output_limited" => AttemptFailureKind.OutputLimited
        case "output_limited_before_decision" => AttemptFailureKind.OutputLimitedBeforeDecision
        case "malformed_tool_arguments" => AttemptFailureKind.MalformedToolArguments
        case "protocol" => AttemptFailureKind.ProviderProtocolError
        case "transport" => AttemptFailureKind.ProviderTransportError
        case _ => throw IllegalArgumentException("provider cannot claim host cancellation or deadline authority")
    }
}
public func modelProviderFailureValue(error: AgentError): AgentValue {
    let kind = match (error.kind) {
        case AgentErrorKind.Authentication => "authentication"; case AgentErrorKind.RateLimited => "rate_limited"
        case AgentErrorKind.Timeout => "timeout"; case AgentErrorKind.Transport => "transport"
        case AgentErrorKind.Provider => "provider"; case AgentErrorKind.BudgetExceeded => "budget"
        case _ => "protocol"
    }
    let retry = match (retryAfterMillisField(error)) { case Some(text) => try { max(0, min(3600000, Int64.parse(text))) } catch (_: Exception) { 0 }; case None => 0 }
    let fields = ArrayList<ValueField>()
    for (field in error.fields where field.name.startsWith("usage_")) {
        if (field.value.size <= 4096 && fields.size < 16) { fields.add(ValueField(field.name, textValue(field.value))) }
    }
    objectValue([ValueField("kind", textValue(kind)), ValueField("code", textValue(error.code)),
        ValueField("attempt_failure", match (error.attemptFailure) { case Some(f) => textValue(providerFailureKindName(f.kind)); case None => nullValue() }),
        ValueField("retry_after_ms", integerValue(retry)), ValueField("usage_fields", objectValue(fields.toArray()))])
}

func providerFailureValue(value: AgentValue): AgentError {
    let legacy = value.fields.size == 2
    providerExact(value, if (legacy) { ["kind", "code"] } else { ["kind", "code", "attempt_failure", "retry_after_ms", "usage_fields"] })
    providerIdentifier(providerText(value, "code"))
    let kind = match (providerText(value, "kind")) {
        case "authentication" => AgentErrorKind.Authentication; case "rate_limited" => AgentErrorKind.RateLimited
        case "timeout" => AgentErrorKind.Timeout; case "transport" => AgentErrorKind.Transport
        case "provider" => AgentErrorKind.Provider; case "protocol" => AgentErrorKind.Protocol; case "budget" => AgentErrorKind.BudgetExceeded
        case _ => throw IllegalArgumentException("invalid provider failure")
    }
    var failure: ?AttemptFailure = None
    let fields = ArrayList<ErrorField>([ErrorField("provider_code", providerText(value, "code"))])
    if (legacy) { failure = Some(AttemptFailure(if (kind == AgentErrorKind.Protocol) { AttemptFailureKind.ProviderProtocolError } else { AttemptFailureKind.ProviderTransportError })) }
    else {
        let raw = providerField(value, "attempt_failure")
        if (raw.unifiedKind != ValueKind.Null) { failure = Some(AttemptFailure(providerFailureKind(providerText(value, "attempt_failure")))) }
        let retry = providerInt(value, "retry_after_ms")
        if (retry < 0 || retry > 3600000) { throw IllegalArgumentException("provider retry delay exceeds bound") }
        if (retry > 0) { fields.add(ErrorField(RETRY_AFTER_MILLIS_FIELD, retry.toString())) }
        let usage = providerField(value, "usage_fields")
        let allowed = ["usage_input_tokens", "usage_output_tokens", "usage_reasoning_tokens", "usage_cache_read_tokens", "usage_cache_write_tokens", "usage_source", "usage_protocol", "usage_event", "usage_response_id"]
        if (usage.unifiedKind != ValueKind.Object || usage.fields.size > allowed.size) { throw IllegalArgumentException("invalid failure usage") }
        for (field in usage.fields) {
            if (!allowed.contains(field.name) || field.value.unifiedKind != ValueKind.Text || field.value.text.size > 4096) { throw IllegalArgumentException("invalid failure usage field") }
            if (field.name.endsWith("_tokens")) { if (Int64.parse(field.value.text) < 0) { throw IllegalArgumentException("negative failure usage") } }
            fields.add(ErrorField(field.name, field.value.text))
        }
        match (usage.field("usage_source")) {
            case None => ()
            case Some(source) =>
                if (!["unknown", "provider_final", "provider_stream_final", "estimated"].contains(source.text) ||
                    (source.text != "unknown" && (usage.field("usage_protocol").isNone() || usage.field("usage_event").isNone()))) {
                    throw IllegalArgumentException("failure usage source lacks evidence")
                }
        }
        // Partial counters stay partial. When both sides are present, retain
        // the same subset/overflow checks as full usage without filling gaps.
        match (usage.field("usage_input_tokens")) {
            case None => ()
            case Some(input) =>
                let total = Int64.parse(input.text)
                let read = match (usage.field("usage_cache_read_tokens")) { case Some(v) => Int64.parse(v.text); case None => 0 }
                let write = match (usage.field("usage_cache_write_tokens")) { case Some(v) => Int64.parse(v.text); case None => 0 }
                if (read > total || write > total - read) { throw IllegalArgumentException("invalid partial cache accounting") }
        }
        match ((usage.field("usage_output_tokens"), usage.field("usage_reasoning_tokens"))) {
            case (Some(output), Some(reasoning)) => if (Int64.parse(reasoning.text) > Int64.parse(output.text)) {
                throw IllegalArgumentException("invalid partial reasoning accounting") }
            case _ => ()
        }
    }
    let typedRetry = match (failure) { case Some(value) =>
        value.kind == AttemptFailureKind.MalformedToolArguments || value.kind == AttemptFailureKind.ProviderTerminalMissing
        case None => false }
    let retryable = typedRetry || kind == AgentErrorKind.RateLimited || kind == AgentErrorKind.Timeout || kind == AgentErrorKind.Provider || kind == AgentErrorKind.Transport
    AgentError(kind, "model.plugin_failure", "provider plugin reported failure", retryable: retryable,
        fallbackAllowed: retryable, fields: fields.toArray(), attemptFailure: failure)
}
