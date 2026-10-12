package persistence_runtime

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*

// Only the opt-in complete MR18 DATA writer delegates to Runtime. The old
// six-field encodeSnapshot/encodeEvent/errorValue functions remain unchanged.
// These prefix nodes are created only inside the actual publication loan and
// after its existing metadata/SQL invoice; Runtime funds encoding increments.
func encodeFailureSnapshot113(snapshot:RunSnapshot,fund:(Int64)->Result<Unit>):Result<String>{
    match(fund(65536)){case Result.Err(error)=>return Result<String>.Err(error);case Result.Ok(_)=>()}
    let prefix=            [
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
                })
            ]
    encodeOwnedFailureError113(snapshot.error,prefix,"error",fund)
}
func encodeFailureEvent113(event:AgentEvent,fund:(Int64)->Result<Unit>):Result<String>{
    let error=match(event.payload){case AgentEventPayload.Diagnostic(actual)=>actual
        case _=>return Result<String>.Err(AgentError(AgentErrorKind.InvalidInput,
            "data.failure_diagnostic_changed","typed failure event must be Diagnostic"))}
    match(fund(65536)){case Result.Err(failure)=>return Result<String>.Err(failure);case Result.Ok(_)=>()}
    let prefix=            [
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
                ValueField("payload_type", textValue(eventPayloadName(event.payload)))
            ]
    encodeOwnedFailureError113(error,prefix,"detail",fund)
}

// Decoder/oracle vocabulary remains byte-identical; it is not a second
// production encoder or authority. Full original error/writer byte oracles
// continue to compare Runtime's output against the independent old DOM path.
func failureErrorKindName113(value:AgentErrorKind):String{
    match(value){
        case AgentErrorKind.Configuration=>"configuration"
        case AgentErrorKind.Authentication=>"authentication"
        case AgentErrorKind.PermissionDenied=>"permission_denied"
        case AgentErrorKind.InvalidInput=>"invalid_input"
        case AgentErrorKind.RateLimited=>"rate_limited"
        case AgentErrorKind.Timeout=>"timeout"
        case AgentErrorKind.Transport=>"transport"
        case AgentErrorKind.Provider=>"provider"
        case AgentErrorKind.Protocol=>"protocol"
        case AgentErrorKind.Cancelled=>"cancelled"
        case AgentErrorKind.BudgetExceeded=>"budget_exceeded"
        case AgentErrorKind.Conflict=>"conflict"
        case AgentErrorKind.RecoveryRequired=>"recovery_required"
        case AgentErrorKind.Internal=>"internal"
    }
}
func failureAttemptKindName113(value:AttemptFailureKind):String{
    match(value){
        case AttemptFailureKind.ConnectTimeout=>"connect_timeout"
        case AttemptFailureKind.FirstResponseTimeout=>"first_response_timeout"
        case AttemptFailureKind.StreamIdleTimeout=>"stream_idle_timeout"
        case AttemptFailureKind.AttemptSoftDeadlineExceeded=>"attempt_soft_deadline_exceeded"
        case AttemptFailureKind.AttemptHardDeadlineExceeded=>"attempt_hard_deadline_exceeded"
        case AttemptFailureKind.DecisionIncompleteAtDeadline=>"decision_incomplete_at_deadline"
        case AttemptFailureKind.ProviderTerminalMissing=>"provider_terminal_missing"
        case AttemptFailureKind.ProtocolIncomplete=>"protocol_incomplete"
        case AttemptFailureKind.OutputLimited=>"output_limited"
        case AttemptFailureKind.OutputLimitedBeforeDecision=>"output_limited_before_decision"
        case AttemptFailureKind.ProviderTransportError=>"provider_transport_error"
        case AttemptFailureKind.ProviderProtocolError=>"provider_protocol_error"
        case AttemptFailureKind.MalformedToolArguments=>"malformed_tool_arguments"
        case AttemptFailureKind.UserCancelled=>"user_cancelled"
        case AttemptFailureKind.RunDeadlineExceeded=>"run_deadline_exceeded"
    }
}
func failureProgressKindName113(value:AttemptProgressKind):String{
    match(value){
        case AttemptProgressKind.NoProgress=>"no_progress"
        case AttemptProgressKind.ReasoningProgress=>"reasoning_progress"
        case AttemptProgressKind.TextProgress=>"text_progress"
        case AttemptProgressKind.ToolCallStartedProgress=>"tool_call_started_progress"
        case AttemptProgressKind.ToolArgumentProgress=>"tool_argument_progress"
        case AttemptProgressKind.ContentBlockCompletedProgress=>"content_block_completed_progress"
        case AttemptProgressKind.ProviderTerminalProgress=>"provider_terminal_progress"
    }
}
func failureAttemptValue113(value:AttemptFailure):AgentValue{
    let data=value.diagnostics
    objectValue([ValueField("kind",textValue(failureAttemptKindName113(value.kind))),
        ValueField("diagnostics",objectValue([
            ValueField("elapsed_millis",integerValue(data.elapsedMillis)),
            ValueField("soft_deadline_millis",integerValue(data.softDeadlineMillis)),
            ValueField("hard_deadline_millis",integerValue(data.hardDeadlineMillis)),
            ValueField("entered_completion_grace",boolValue(data.enteredCompletionGrace)),
            ValueField("last_progress_kind",textValue(failureProgressKindName113(data.lastProgressKind))),
            ValueField("last_progress_age_millis",integerValue(data.lastProgressAgeMillis)),
            ValueField("provider_terminal_observed",boolValue(data.providerTerminalObserved)),
            ValueField("open_content_block_count",integerValue(data.openContentBlockCount)),
            ValueField("tool_calls_started",integerValue(data.toolCallsStarted)),
            ValueField("tool_calls_completed",integerValue(data.toolCallsCompleted))]))])
}

