package agent_core

import agent_domain.*
import agent_ports.*
import yjson.*
import yjson_support.*
import std.time.*

// Called inside the original paid Model action. No provider sees this input
// when selected; ordinary calls keep their actual Returning/Pending/Held port.
func executeFrozenModelFault180(settings: AgentValue, counters: ?ModelStreamFaultCounters180,
    events: ModelEventSink, stopped: () -> Bool): ?Result<ModelReply> {
    if (settings.unifiedKind == ValueKind.Null) { return None<Result<ModelReply>> }
    if (requiredCoreTextField(settings, "schema") != "axyndra.operator-request-settings/v1") {
        return Some(Result<ModelReply>.Err(AgentError(AgentErrorKind.InvalidInput,
            "model.operator_settings_schema_invalid", "invalid frozen operator settings schema")))
    }
    let profile = requiredCoreValueField(settings, "model_stream_fault")
    if (profile.unifiedKind == ValueKind.Null) { return None<Result<ModelReply>> }
    let id = requiredCoreTextField(profile, "id")
    let trigger = requiredCoreIntegerField(profile, "trigger_attempt_ordinal")
    let maximum = requiredCoreIntegerField(profile, "max_injected_attempts")
    let partial = requiredCoreTextField(profile, "partial_text")
    let delay = requiredCoreIntegerField(profile, "fault_delay_ms")
    if (id.trimAscii() == "" || trigger < 1 || maximum < 1 || partial == "" || delay < 1) {
        return Some(Result<ModelReply>.Err(AgentError(AgentErrorKind.InvalidInput,
            "model.controlled_fault_profile_invalid", "invalid frozen controlled fault profile")))
    }
    let counter = match (counters) {
        case Some(value) => value
        case None => return Some(Result<ModelReply>.Err(AgentError(AgentErrorKind.RecoveryRequired,
            "model.controlled_fault_owner_missing", "frozen controlled fault counters are no longer owned")))
    }
    let selected = match (counter.claim180(trigger, maximum)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Some(Result<ModelReply>.Err(error))
    }
    if (!selected[1]) { return None<Result<ModelReply>> }
    events(ModelEvent.ProviderProgress(ProviderStreamEvent.ControlledFaultInjected(id, selected[0])))
    events(ModelEvent.TextDelta(partial))
    var waited: Int64 = 0
    while (!stopped() && waited < delay) { sleep(Duration.millisecond); waited += 1 }
    if (stopped()) {
        return Some(Result<ModelReply>.Err(AgentError(AgentErrorKind.Cancelled,
            "model.controlled_fault_cancelled", "controlled incomplete stream was cancelled",
            attemptFailure: Some(AttemptFailure(AttemptFailureKind.UserCancelled)))))
    }
    Some(Result<ModelReply>.Err(AgentError(AgentErrorKind.Timeout, "model.stream_idle_timeout",
        "controlled stream became incomplete at the deterministic fault boundary", retryable: true,
        fields: [ErrorField("fault_profile_id", id)],
        attemptFailure: Some(AttemptFailure(AttemptFailureKind.StreamIdleTimeout,
            diagnostics: AttemptFailureDiagnostics(elapsedMillis: delay,
                lastProgressKind: AttemptProgressKind.TextProgress, lastProgressAgeMillis: delay))))))
}
