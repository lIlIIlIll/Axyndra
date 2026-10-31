package agent_store

import agent_domain.*
import yjson.*
import yjson_support.*

// Store-private typed error data, never an execution/settlement authority.
// Uses the same caller owner; it neither acquires a second floor nor closes
// the borrowed owner. Scalar/field/attachment allocation is paid before DOM.
func livePolicyRejectedErrorDetailOwned(error:AgentError,owner:LogicalJsonOwnerReservation,
    extraRetained:Int64,guard:()->Result<Unit>):AgentValue{
    journalStreamCheck(guard)
    if(extraRetained<0){throw IllegalStateException("negative retained rejection error extent")}
    var bytes:Int64=4096;var nodes:Int64=128
    bytes=journalStreamAdd(bytes,journalStreamAdd(error.code.size,error.message.size))
    for(field in error.fields){
        journalStreamCheck(guard)
        bytes=journalStreamAdd(bytes,journalStreamAdd(128,journalStreamAdd(field.name.size,field.value.size)))
        nodes=journalStreamAdd(nodes,8)
    }
    if(error.attemptFailure.isSome()){
        bytes=journalStreamAdd(bytes,4096);nodes=journalStreamAdd(nodes,128)}
    if(error.observation.isSome()){
        // OperationObservation freezes JSON to the original 65536 byte/depth32
        // bound and exposes only toValue. Prepay its worst complete DOM BEFORE
        // that method allocates; no extra API or guessed private content length.
        bytes=journalStreamAdd(bytes,528384);nodes=journalStreamAdd(nodes,65536)}
    if(bytes>Int64.Max/12){throw IllegalStateException("typed rejection error payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(extraRetained,
        journalStreamAdd(contextReadMetadataPeak(bytes,nodes),bytes*12)))
    journalStreamCheck(guard)
    let detail=objectValue([
        ValueField("kind",textValue(livePolicyRejectedErrorKindName(error.kind))),
        ValueField("code",textValue(error.code)),ValueField("message",textValue(error.message)),
        ValueField("retryable",boolValue(error.retryable)),
        ValueField("fallback_allowed",boolValue(error.fallbackAllowed)),
        ValueField("fields",listValue(error.fields.map{field=>objectValue([
            ValueField("name",textValue(field.name)),ValueField("value",textValue(field.value))])})),
        ValueField("attempt_failure",match(error.attemptFailure){
            case None=>nullValue();case Some(value)=>livePolicyRejectedFailureValue(value)}),
        ValueField("observation",match(error.observation){
            case None=>nullValue();case Some(value)=>value.toValue()})])
    let actual=livePolicyStoredExtent(detail)
    if(actual.bytes>8388608 || actual.nodes>1000000){
        throw IllegalStateException("typed rejection error exceeds the original durable codec")}
    if(actual.bytes>bytes || actual.nodes>nodes){
        throw IllegalStateException("typed rejection error exceeded its prepaid complete extent")}
    journalStreamCheck(guard);detail
}

func livePolicyRejectedErrorKindName(value:AgentErrorKind):String{
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
func livePolicyRejectedFailureKindName(value:AttemptFailureKind):String{
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
func livePolicyRejectedProgressKindName(value:AttemptProgressKind):String{
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
func livePolicyRejectedFailureValue(value:AttemptFailure):AgentValue{
    let data=value.diagnostics
    objectValue([ValueField("kind",textValue(livePolicyRejectedFailureKindName(value.kind))),
        ValueField("diagnostics",objectValue([
            ValueField("elapsed_millis",integerValue(data.elapsedMillis)),
            ValueField("soft_deadline_millis",integerValue(data.softDeadlineMillis)),
            ValueField("hard_deadline_millis",integerValue(data.hardDeadlineMillis)),
            ValueField("entered_completion_grace",boolValue(data.enteredCompletionGrace)),
            ValueField("last_progress_kind",textValue(livePolicyRejectedProgressKindName(data.lastProgressKind))),
            ValueField("last_progress_age_millis",integerValue(data.lastProgressAgeMillis)),
            ValueField("provider_terminal_observed",boolValue(data.providerTerminalObserved)),
            ValueField("open_content_block_count",integerValue(data.openContentBlockCount)),
            ValueField("tool_calls_started",integerValue(data.toolCallsStarted)),
            ValueField("tool_calls_completed",integerValue(data.toolCallsCompleted))]))])
}
