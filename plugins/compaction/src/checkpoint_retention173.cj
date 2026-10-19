package compaction_plugin

import agent_domain.*
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

// This result is a history-retention proposal only. It cannot authorize a
// canonical cut, change a Run, mint Source or acknowledge any history owner.
func checkpointRetentionPhase173(value: AgentValue): AgentValue {
    match (policyText(value, "phase")) {
        case "checkpoint_retained_cut173" =>
            policyFields(value, ["schema", "phase", "snapshot_digest", "state"])
            let state = value.field("state").getOrThrow(); checkpointPolicyState(state, true)
            if (structuredInteger(state, "offset") != structuredInteger(state, "total")) { compactionFragmentError() }
            objectValue([ValueField("retain", integerValue(if (structuredInteger(state, "checkpoint") > 0 &&
                !compactionFragmentBool(state, "completed")) { structuredInteger(state, "retain") } else { -1 }))])
        case "checkpoint_retention_error173" =>
            policyFields(value, ["schema", "phase", "snapshot_digest"])
            checkpointPolicyError("conflict", "session.compaction_checkpoint_active",
                "active checkpoint history cannot fit the compaction target; call rewind before compacting again")
        case "checkpoint_model_begin173" =>
            policyFields(value, ["schema", "phase", "snapshot_digest", "total"])
            let total = structuredInteger(value, "total")
            if (total < 0) { compactionFragmentError() }
            checkpointModelState173(0, total, -1, nullValue(), -1, nullValue(), false, -1, false)
        case "checkpoint_model_second173" =>
            policyFields(value, ["schema", "phase", "snapshot_digest", "state"])
            let state = value.field("state").getOrThrow(); checkpointModelValidate173(state)
            if (structuredInteger(state, "offset") != structuredInteger(state, "total")) { compactionFragmentError() }
            checkpointModelState173(0, structuredInteger(state, "total"), structuredInteger(state, "latest"),
                state.field("call").getOrThrow(), -1, nullValue(), compactionFragmentBool(state, "completed"), 0, true)
        case "checkpoint_model_batch173" => checkpointModelBatch173(value)
        case "checkpoint_model_finish173" =>
            policyFields(value, ["schema", "phase", "snapshot_digest", "state"])
            let state = value.field("state").getOrThrow(); checkpointModelValidate173(state)
            if (!compactionFragmentBool(state, "second") ||
                structuredInteger(state, "offset") != structuredInteger(state, "total")) { compactionFragmentError() }
            objectValue([ValueField("retain", integerValue(if (structuredInteger(state, "latest") < 0 ||
                compactionFragmentBool(state, "completed")) { -1 } else { structuredInteger(state, "retain") }))])
        case _ => compactionFragmentError()
    }
}
func checkpointModelState173(offset: Int64, total: Int64, latest: Int64, call: AgentValue,
    message: Int64, first: AgentValue, completed: Bool, retain: Int64, second: Bool): AgentValue {
    objectValue([ValueField("offset", integerValue(offset)), ValueField("total", integerValue(total)),
        ValueField("latest", integerValue(latest)), ValueField("call", call), ValueField("message", integerValue(message)),
        ValueField("first", first), ValueField("completed", boolValue(completed)),
        ValueField("retain", integerValue(retain)), ValueField("second", boolValue(second))])
}
func checkpointModelValidate173(state: AgentValue): Unit {
    policyFields(state, ["offset", "total", "latest", "call", "message", "first", "completed", "retain", "second"])
    let total = structuredInteger(state, "total"); let offset = structuredInteger(state, "offset")
    if (total < 0 || offset < 0 || offset > total || structuredInteger(state, "latest") < -1 ||
        structuredInteger(state, "message") < -1 || structuredInteger(state, "retain") < -1) { compactionFragmentError() }
    let _ = compactionFragmentBool(state, "completed"); let _ = compactionFragmentBool(state, "second")
    for (key in ["call", "first"]) {
        let reference = state.field(key).getOrThrow()
        if (reference.unifiedKind != ValueKind.Null) { let _ = compactionReferenceBytes(reference) }
    }
}
func checkpointModelBatch173(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "state", "events"])
    let initial = value.field("state").getOrThrow(); checkpointModelValidate173(initial)
    let events = value.field("events").getOrThrow()
    if (events.unifiedKind != ValueKind.List || events.items.isEmpty() || events.items.size > 64) { compactionFragmentError() }
    var state = initial
    for (event in events.items) { state = checkpointModelEvent173(state, event) }
    state
}
func checkpointModelEvent173(state: AgentValue, event: AgentValue): AgentValue {
    checkpointModelValidate173(state)
    policyFields(event, ["message", "kind", "name", "call", "is_error"])
    let at = structuredInteger(event, "message"); let kind = policyText(event, "kind")
    let offset = structuredInteger(state, "offset"); let total = structuredInteger(state, "total")
    if (offset >= total || at < 0 || at < structuredInteger(state, "message") ||
        !["call", "result", "text", "other"].contains(kind)) { compactionFragmentError() }
    let name = event.field("name").getOrThrow(); let call = event.field("call").getOrThrow()
    let _ = compactionReferenceBytes(name); let _ = compactionReferenceBytes(call)
    let failed = compactionFragmentBool(event, "is_error")
    var latest = structuredInteger(state, "latest"); var selected = state.field("call").getOrThrow()
    var first = if (at == structuredInteger(state, "message")) { state.field("first").getOrThrow() } else { nullValue() }
    var completed = compactionFragmentBool(state, "completed"); var retain = structuredInteger(state, "retain")
    let second = compactionFragmentBool(state, "second")
    if (!second) {
        // Original checkpointCallId picks the first checkpoint result in a
        // message, including a failed one preceding a successful result.
        if (kind == "result" && checkpointToolHistoryReference173(name, "checkpoint")) {
            if (first.unifiedKind == ValueKind.Null) { first = call }
            if (!failed) { latest = at; selected = first; completed = false }
        }
        if (kind == "text" && compactionReferenceIs(name, "rewind-report") && latest >= 0 && at > latest) {
            completed = true }
    } else {
        // Ascending traversal overwrites with the last matching earlier
        // message, exactly matching the original backwards call search.
        if (latest >= 0 && at < latest && kind == "call" && selected.unifiedKind != ValueKind.Null &&
            compactionReferenceEqual(call, selected) && checkpointToolHistoryReference173(name, "checkpoint")) { retain = at }
    }
    checkpointModelState173(offset + 1, total, latest, selected, at, first, completed, retain, second)
}
