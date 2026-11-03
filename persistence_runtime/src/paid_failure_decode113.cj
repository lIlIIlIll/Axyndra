package persistence_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Complete error DATA is decoded only while the actual SQL text, full grammar
// DOM and independently retained output consumer are all paid in one bank.
func strictLegacyFailureError113(value: AgentValue): Result<AgentError> {
    if (value.unifiedKind != ValueKind.Object) {
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
        if (field.unifiedKind != ValueKind.Object) {
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

func decodeFailureSnapshot113(source: String): Result<RunSnapshot> {
    let value = match (decodeAgentValue(source, maxBytes: 67108864)) {
        case Result.Ok(item) => item
        case Result.Err(error) => return Result.Err(error)
    }
    if (value.unifiedKind != ValueKind.Object) {
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
        case Some(raw) => if (raw.unifiedKind == ValueKind.Null) { None } else { Some(raw) }
        case None => return codecError("missing field: structured_output")
    }
    let snapshotError: ?AgentError = match (value.field("error")) {
        case Some(raw) =>
            if (raw.unifiedKind == ValueKind.Null) {
                None
            } else {
                match (strictFailureError113(raw)) {
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

func failureAttemptKindFrom113(value: String): Result<AttemptFailureKind> {
    match (value) {
        case "connect_timeout" => Result.Ok(AttemptFailureKind.ConnectTimeout)
        case "first_response_timeout" => Result.Ok(AttemptFailureKind.FirstResponseTimeout)
        case "stream_idle_timeout" => Result.Ok(AttemptFailureKind.StreamIdleTimeout)
        case "attempt_soft_deadline_exceeded" => Result.Ok(AttemptFailureKind.AttemptSoftDeadlineExceeded)
        case "attempt_hard_deadline_exceeded" => Result.Ok(AttemptFailureKind.AttemptHardDeadlineExceeded)
        case "decision_incomplete_at_deadline" => Result.Ok(AttemptFailureKind.DecisionIncompleteAtDeadline)
        case "provider_terminal_missing" => Result.Ok(AttemptFailureKind.ProviderTerminalMissing)
        case "protocol_incomplete" => Result.Ok(AttemptFailureKind.ProtocolIncomplete)
        case "output_limited" => Result.Ok(AttemptFailureKind.OutputLimited)
        case "output_limited_before_decision" => Result.Ok(AttemptFailureKind.OutputLimitedBeforeDecision)
        case "provider_transport_error" => Result.Ok(AttemptFailureKind.ProviderTransportError)
        case "provider_protocol_error" => Result.Ok(AttemptFailureKind.ProviderProtocolError)
        case "malformed_tool_arguments" => Result.Ok(AttemptFailureKind.MalformedToolArguments)
        case "user_cancelled" => Result.Ok(AttemptFailureKind.UserCancelled)
        case "run_deadline_exceeded" => Result.Ok(AttemptFailureKind.RunDeadlineExceeded)
        case _ => codecError("unknown complete failure AttemptFailureKind")
    }
}
func failureProgressKindFrom113(value: String): Result<AttemptProgressKind> {
    match (value) {
        case "no_progress" => Result.Ok(AttemptProgressKind.NoProgress)
        case "reasoning_progress" => Result.Ok(AttemptProgressKind.ReasoningProgress)
        case "text_progress" => Result.Ok(AttemptProgressKind.TextProgress)
        case "tool_call_started_progress" => Result.Ok(AttemptProgressKind.ToolCallStartedProgress)
        case "tool_argument_progress" => Result.Ok(AttemptProgressKind.ToolArgumentProgress)
        case "content_block_completed_progress" => Result.Ok(AttemptProgressKind.ContentBlockCompletedProgress)
        case "provider_terminal_progress" => Result.Ok(AttemptProgressKind.ProviderTerminalProgress)
        case _ => codecError("unknown complete failure AttemptProgressKind")
    }
}

func failureExactFields113(value: AgentValue, names: Array<String>): Bool {
    if (value.unifiedKind != ValueKind.Object || value.fields.size != names.size) { return false }
    let seen = HashSet<String>()
    for (field in value.fields) {
        if (seen.contains(field.name)) { return false }; seen.add(field.name)
        var expected = false
        for (name in names where name == field.name) { expected = true }
        if (!expected) { return false }
    }
    true
}
func strictFailureError113(value: AgentValue): Result<AgentError> {
    // Original legacy six-field sources still decode with the complete old
    // predicates. New eight-field sources require every attachment field.
    if (value.fields.size == 6) { return strictLegacyFailureError113(value) }
    if (!failureExactFields113(value, ["kind","code","message","retryable","fallback_allowed",
        "fields","attempt_failure","observation"])) { return codecError("complete error fields changed") }
    let base = match (strictLegacyFailureError113(value)) { case Result.Ok(v) => v
        case Result.Err(error) => return Result<AgentError>.Err(error) }
    let attempt: ?AttemptFailure = match (value.field("attempt_failure").getOrThrow()) {
        case item => if (item.unifiedKind == ValueKind.Null) { None<AttemptFailure> } else {
            match (strictFailureAttempt113(item)) { case Result.Ok(v) => Some(v)
                case Result.Err(error) => return Result<AgentError>.Err(error) } } }
    let observation: ?OperationObservation = match (value.field("observation").getOrThrow()) {
        case item => if (item.unifiedKind == ValueKind.Null) { None<OperationObservation> } else {
            if (!failureExactFields113(item,["schema","trust","authorizes_effects","content"]) ||
                textOr(item,"schema") != "axyndra.operation-observation/v1" ||
                textOr(item,"trust") != "untrusted_data") { return codecError("complete observation wrapper changed") }
            let authority = match (requiredBoolean(item,"authorizes_effects")) { case Result.Ok(v) => v
                case Result.Err(error) => return Result<AgentError>.Err(error) }
            if (authority) { return codecError("diagnostic observation cannot authorize effects") }
            try { Some(OperationObservation(encodeAgentValue(item.field("content").getOrThrow()))) }
            catch (error: Exception) { return codecError(error.message) }
        } }
    try { Result.Ok(AgentError(base.kind,base.code,base.message,retryable:base.retryable,
        fallbackAllowed:base.fallbackAllowed,fields:base.fields,attemptFailure:attempt,observation:observation)) }
    catch (error: Exception) { codecError(error.message) }
}
func strictFailureAttempt113(value: AgentValue): Result<AttemptFailure> {
    if (!failureExactFields113(value,["kind","diagnostics"])) { return codecError("complete attempt fields changed") }
    let kind = match (requiredText(value,"kind")) { case Result.Ok(v) =>
        match (failureAttemptKindFrom113(v)) { case Result.Ok(k) => k; case Result.Err(e) => return Result<AttemptFailure>.Err(e) }
        case Result.Err(e) => return Result<AttemptFailure>.Err(e) }
    let d=value.field("diagnostics").getOrThrow()
    if (!failureExactFields113(d,["elapsed_millis","soft_deadline_millis","hard_deadline_millis",
        "entered_completion_grace","last_progress_kind","last_progress_age_millis",
        "provider_terminal_observed","open_content_block_count","tool_calls_started","tool_calls_completed"])) {
        return codecError("complete attempt diagnostics changed") }
    let integers=ArrayList<Int64>()
    for (name in ["elapsed_millis","soft_deadline_millis","hard_deadline_millis","last_progress_age_millis",
        "open_content_block_count","tool_calls_started","tool_calls_completed"]) {
        let n=match(requiredInteger(d,name)){case Result.Ok(v)=>v;case Result.Err(e)=>return Result<AttemptFailure>.Err(e)}
        if(n<0){return codecError("negative complete attempt diagnostics")};integers.add(n)
    }
    let grace=match(requiredBoolean(d,"entered_completion_grace")){case Result.Ok(v)=>v;case Result.Err(e)=>return Result<AttemptFailure>.Err(e)}
    let terminal=match(requiredBoolean(d,"provider_terminal_observed")){case Result.Ok(v)=>v;case Result.Err(e)=>return Result<AttemptFailure>.Err(e)}
    let progress=match(requiredText(d,"last_progress_kind")){case Result.Ok(v)=>
        match(failureProgressKindFrom113(v)){case Result.Ok(k)=>k;case Result.Err(e)=>return Result<AttemptFailure>.Err(e)}
        case Result.Err(e)=>return Result<AttemptFailure>.Err(e)}
    Result.Ok(AttemptFailure(kind,diagnostics:AttemptFailureDiagnostics(elapsedMillis:integers[0],
        softDeadlineMillis:integers[1],hardDeadlineMillis:integers[2],lastProgressAgeMillis:integers[3],
        openContentBlockCount:integers[4],toolCallsStarted:integers[5],toolCallsCompleted:integers[6],
        enteredCompletionGrace:grace,providerTerminalObserved:terminal,lastProgressKind:progress)))
}
