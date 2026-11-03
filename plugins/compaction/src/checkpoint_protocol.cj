package compaction_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// All fields and ordinals below are immutable policy DATA. None is a Source,
// Receipt, execution permission, canonical boundary or durable checkpoint.
// The caller independently owns the actual Thread and canonical cut checks.
func checkpointPolicyPhase(value: AgentValue): AgentValue {
    match (policyText(value, "phase")) {
        case "checkpoint_select" => checkpointPolicySelect(value)
        case "checkpoint_trim" => checkpointPolicyTrim(value)
        case "checkpoint_validate" => checkpointPolicyValidate(value)
        case "checkpoint_begin" => checkpointPolicyBegin(value)
        case "checkpoint_latest" => checkpointPolicyLatest(value)
        case "checkpoint_latest_batch" => checkpointPolicyBatch(value, false)
        case "checkpoint_after_begin" => checkpointPolicyAfterBegin(value)
        case "checkpoint_after" => checkpointPolicyAfter(value)
        case "checkpoint_after_batch" => checkpointPolicyBatch(value, true)
        case "checkpoint_check" => checkpointPolicyCheck(value)
        case "checkpoint_result" => checkpointPolicyResult(value)
        case "checkpoint_save_layout" => checkpointSavePolicyPhase113(value)
        case "checkpoint_save_validate" => checkpointSavePolicyPhase113(value)
        case "checkpoint_save_check" => checkpointSavePolicyPhase113(value)
        case "checkpoint_save_recipe" => checkpointSavePolicyPhase113(value)
        case _ => compactionFragmentError()
    }
}

func checkpointPolicyName(value: AgentValue): String {
    let name = value.field("tool").getOrThrow()
    if (checkpointToolHistoryReference173(name, "checkpoint")) { return "checkpoint" }
    if (checkpointToolHistoryReference173(name, "rewind")) { return "rewind" }
    compactionFragmentError()
}
func checkpointPolicySelect(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "tool"])
    let name = checkpointPolicyName(value)
    objectValue([ValueField("argument", textValue(if (name == "checkpoint") { "goal" } else { "report" }))])
}
func checkpointPolicyError(kind: String, code: String, message: String,
    fields!: Array<AgentValue> = []): AgentValue {
    objectValue([ValueField("error", objectValue([ValueField("kind", textValue(kind)),
        ValueField("code", textValue(code)), ValueField("message", textValue(message)),
        ValueField("fields", listValue(fields))]))])
}
func checkpointPolicyArgumentError(name: String, argument: String, message: String): AgentValue {
    checkpointPolicyError("invalid_input", "tool.invalid_argument", message,
        fields: [objectValue([ValueField("name", textValue("tool")), ValueField("value", textValue(name))]),
            objectValue([ValueField("name", textValue("argument")), ValueField("value", textValue(argument))])])
}

// Apply the actual original String.trimAscii() to every complete UTF8 fragment.
// Carry only the first and last nontrimmed byte positions, so interior spaces
// and arbitrarily long whitespace runs remain exact without an output copy.
func checkpointPolicyTrim(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "source", "offset", "text", "carry"])
    let source = value.field("source").getOrThrow()
    let total = compactionReferenceBytes(source); let offset = structuredInteger(value, "offset")
    let text = policyText(value, "text"); let carry = value.field("carry").getOrThrow()
    if (offset < 0 || offset > total || text.size > total - offset || text.size > 262144 ||
        (text == "" && total != 0)) { compactionFragmentError() }
    var first: Int64 = -1; var last: Int64 = 0
    if (carry.unifiedKind != ValueKind.Null) {
        policyFields(carry, ["offset", "first", "last"])
        first = structuredInteger(carry, "first"); last = structuredInteger(carry, "last")
        if (structuredInteger(carry, "offset") != offset || first < -1 || first > last ||
            last > offset || (first == -1 && last != 0)) { compactionFragmentError() }
    } else if (offset != 0) { compactionFragmentError() }
    let trimmed = text.trimAscii()
    if (trimmed != "") {
        let local = text.indexOf(trimmed).getOrThrow()
        if (first < 0) { first = offset + local }
        last = offset + local + trimmed.size
    }
    let next = offset + text.size
    objectValue([ValueField("source", source), ValueField("next_offset", integerValue(next)),
        ValueField("complete", boolValue(next == total)),
        ValueField("carry", objectValue([ValueField("offset", integerValue(next)),
            ValueField("first", integerValue(first)), ValueField("last", integerValue(last))])),
        ValueField("range", if (next == total) { objectValue([ValueField("source", source),
            ValueField("offset", integerValue(if (first < 0) { 0 } else { first })),
            ValueField("bytes", integerValue(if (first < 0) { 0 } else { last - first }))]) } else { nullValue() })])
}
func checkpointPolicyRange(range: AgentValue, source: AgentValue): Unit {
    policyFields(range, ["source", "offset", "bytes"])
    let total = compactionReferenceBytes(source)
    let offset = structuredInteger(range, "offset"); let bytes = structuredInteger(range, "bytes")
    if (!compactionReferenceEqual(range.field("source").getOrThrow(), source) ||
        offset < 0 || offset > total || bytes < 0 || bytes > total - offset) { compactionFragmentError() }
}
func checkpointPolicyValidate(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "tool", "present", "kind", "source", "range"])
    let name = checkpointPolicyName(value)
    let argument = if (name == "checkpoint") { "goal" } else { "report" }
    if (!compactionFragmentBool(value, "present")) {
        return checkpointPolicyArgumentError(name, argument, "required argument is missing") }
    if (policyText(value, "kind") != "text") {
        return checkpointPolicyArgumentError(name, argument, "argument must be a string") }
    let source = value.field("source").getOrThrow(); let range = value.field("range").getOrThrow()
    checkpointPolicyRange(range, source)
    if (structuredInteger(range, "bytes") == 0) {
        return checkpointPolicyArgumentError(name, argument,
            if (name == "checkpoint") { "investigation goal must not be empty" } else { "Report cannot be empty." }) }
    objectValue([ValueField("valid", boolValue(true))])
}

func checkpointPolicyState(state: AgentValue, after: Bool): Unit {
    policyFields(state, if (after) { ["offset", "total", "checkpoint", "checkpoint_call", "rewind", "completed", "retain", "retained"] }
        else { ["offset", "total", "checkpoint", "checkpoint_call", "rewind"] })
    let total = structuredInteger(state, "total"); let offset = structuredInteger(state, "offset")
    let checkpoint = structuredInteger(state, "checkpoint"); let rewind = structuredInteger(state, "rewind")
    if (total < 0 || offset < 0 || offset > total || checkpoint < 0 || rewind < 0) { compactionFragmentError() }
    let call = state.field("checkpoint_call").getOrThrow()
    if (checkpoint == 0) { if (call.unifiedKind != ValueKind.Null) { compactionFragmentError() } }
    else { let _ = compactionReferenceBytes(call) }
    if (after) {
        let _ = compactionFragmentBool(state, "completed"); let _ = compactionFragmentBool(state, "retained")
        if (structuredInteger(state, "retain") < 0) { compactionFragmentError() }
    }
}
func checkpointPolicyBegin(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "total"])
    let total = structuredInteger(value, "total")
    if (total < 0) { compactionFragmentError() }
    objectValue([ValueField("offset", integerValue(0)), ValueField("total", integerValue(total)),
        ValueField("checkpoint", integerValue(0)), ValueField("checkpoint_call", nullValue()), ValueField("rewind", integerValue(0))])
}
func checkpointPolicyEvent(event: AgentValue): Unit {
    policyFields(event, ["kind", "ordinal", "name", "call_id", "is_error"])
    let kind = policyText(event, "kind")
    if (!["call", "result", "other"].contains(kind) || structuredInteger(event, "ordinal") < 1) { compactionFragmentError() }
    if (kind != "other") {
        let _ = compactionReferenceBytes(event.field("name").getOrThrow())
        let _ = compactionReferenceBytes(event.field("call_id").getOrThrow())
        if (kind == "result") { let _ = compactionFragmentBool(event, "is_error") }
    }
}
func checkpointPolicyLatest(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "state", "event", "target_call"])
    let state = value.field("state").getOrThrow(); checkpointPolicyState(state, false)
    let event = value.field("event").getOrThrow(); checkpointPolicyEvent(event)
    let offset = structuredInteger(state, "offset"); let total = structuredInteger(state, "total")
    if (offset == total) { compactionFragmentError() }
    let target = value.field("target_call").getOrThrow(); let _ = compactionReferenceBytes(target)
    var latest = structuredInteger(state, "checkpoint")
    var checkpointCall = state.field("checkpoint_call").getOrThrow(); var rewind = structuredInteger(state, "rewind")
    if (policyText(event, "kind") == "result" && !compactionFragmentBool(event, "is_error")) {
        if (checkpointToolHistoryReference173(event.field("name").getOrThrow(), "checkpoint")) {
            latest = structuredInteger(event, "ordinal"); checkpointCall = event.field("call_id").getOrThrow() }
        if (rewind == 0 && compactionReferenceEqual(event.field("call_id").getOrThrow(), target) &&
            checkpointToolHistoryReference173(event.field("name").getOrThrow(), "rewind")) { rewind = structuredInteger(event, "ordinal") }
    }
    objectValue([ValueField("offset", integerValue(offset + 1)), ValueField("total", integerValue(total)),
        ValueField("checkpoint", integerValue(latest)), ValueField("checkpoint_call", checkpointCall), ValueField("rewind", integerValue(rewind))])
}
func checkpointPolicyAfterBegin(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "state"])
    let state = value.field("state").getOrThrow(); checkpointPolicyState(state, false)
    if (structuredInteger(state, "offset") != structuredInteger(state, "total")) { compactionFragmentError() }
    objectValue([ValueField("offset", integerValue(0)), ValueField("total", state.field("total").getOrThrow()),
        ValueField("checkpoint", state.field("checkpoint").getOrThrow()), ValueField("checkpoint_call", state.field("checkpoint_call").getOrThrow()),
        ValueField("rewind", state.field("rewind").getOrThrow()), ValueField("completed", boolValue(false)),
        ValueField("retain", integerValue(0)), ValueField("retained", boolValue(false))])
}
func checkpointPolicyAfter(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "state", "event"])
    let state = value.field("state").getOrThrow(); checkpointPolicyState(state, true)
    let event = value.field("event").getOrThrow(); checkpointPolicyEvent(event)
    let offset = structuredInteger(state, "offset"); let total = structuredInteger(state, "total")
    if (offset == total) { compactionFragmentError() }
    let checkpoint = structuredInteger(state, "checkpoint")
    var completed = compactionFragmentBool(state, "completed")
    var retained = compactionFragmentBool(state, "retained"); var retain = structuredInteger(state, "retain")
    if (checkpoint > 0) {
        if (policyText(event, "kind") == "result" && structuredInteger(event, "ordinal") > checkpoint &&
            !compactionFragmentBool(event, "is_error") && checkpointToolHistoryReference173(event.field("name").getOrThrow(), "rewind")) { completed = true }
        if (!retained && policyText(event, "kind") == "call" &&
            compactionReferenceEqual(event.field("call_id").getOrThrow(), state.field("checkpoint_call").getOrThrow()) &&
            checkpointToolHistoryReference173(event.field("name").getOrThrow(), "checkpoint")) {
            retained = true; retain = max(0, structuredInteger(event, "ordinal") - 1) }
    }
    objectValue([ValueField("offset", integerValue(offset + 1)), ValueField("total", integerValue(total)),
        ValueField("checkpoint", state.field("checkpoint").getOrThrow()), ValueField("checkpoint_call", state.field("checkpoint_call").getOrThrow()),
        ValueField("rewind", state.field("rewind").getOrThrow()), ValueField("completed", boolValue(completed)),
        ValueField("retain", integerValue(retain)), ValueField("retained", boolValue(retained))])
}
func checkpointPolicyBatch(value: AgentValue, after: Bool): AgentValue {
    policyFields(value, if (after) { ["schema", "phase", "snapshot_digest", "state", "events"] }
        else { ["schema", "phase", "snapshot_digest", "state", "events", "target_call"] })
    let events = value.field("events").getOrThrow()
    if (events.unifiedKind != ValueKind.List || events.items.isEmpty() || events.items.size > 64) { compactionFragmentError() }
    var state = value.field("state").getOrThrow()
    for (event in events.items) {
        let fields = ArrayList<ValueField>([ValueField("schema", value.field("schema").getOrThrow()),
            ValueField("phase", textValue(if (after) { "checkpoint_after" } else { "checkpoint_latest" })),
            ValueField("snapshot_digest", value.field("snapshot_digest").getOrThrow()), ValueField("state", state), ValueField("event", event)])
        if (!after) { fields.add(ValueField("target_call", value.field("target_call").getOrThrow())) }
        state = if (after) { checkpointPolicyAfter(objectValue(fields.toArray())) } else { checkpointPolicyLatest(objectValue(fields.toArray())) }
    }
    state
}
func checkpointPolicyTextField(name: String, parts: Array<AgentValue>): AgentValue {
    objectValue([ValueField("name", textValue(name)), ValueField("kind", textValue("text")), ValueField("recipe", listValue(parts))])
}
func checkpointPolicyCompletionError113(name: String, state: AgentValue): ?AgentValue {
    checkpointPolicyState(state, true)
    if (structuredInteger(state, "offset") != structuredInteger(state, "total")) { compactionFragmentError() }
    let active = structuredInteger(state, "checkpoint") > 0 && !compactionFragmentBool(state, "completed")
    if (name == "checkpoint" && active) {
        return Some(checkpointPolicyError("conflict", "tool.checkpoint_active", "Checkpoint already active.")) }
    if (name == "rewind" && !active) {
        let completed = compactionFragmentBool(state, "completed")
        return Some(checkpointPolicyError("conflict", if (completed) { "tool.checkpoint_completed" } else { "tool.checkpoint_missing" },
            if (completed) { "Checkpoint already completed; continue from the retained rewind report instead of calling rewind again." }
            else { "No active checkpoint. Create a checkpoint before calling rewind." })) }
    None<AgentValue>
}
func checkpointPolicyCheck(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "tool", "state"])
    match (checkpointPolicyCompletionError113(checkpointPolicyName(value), value.field("state").getOrThrow())) {
        case Some(error) => error
        case None => objectValue([ValueField("valid", boolValue(true))])
    }
}
func checkpointPolicyResult(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "tool", "state", "source", "range", "timestamp"])
    let name = checkpointPolicyName(value); let state = value.field("state").getOrThrow()
    checkpointPolicyState(state, true)
    if (structuredInteger(state, "offset") != structuredInteger(state, "total")) { compactionFragmentError() }
    let source = value.field("source").getOrThrow(); let range = value.field("range").getOrThrow()
    checkpointPolicyRange(range, source)
    if (structuredInteger(range, "bytes") == 0) { compactionFragmentError() }
    match (checkpointPolicyCompletionError113(name, state)) { case Some(error) => return error; case None => () }
    let timestamp = value.field("timestamp").getOrThrow(); let _ = compactionReferenceBytes(timestamp)
    let fields = if (name == "checkpoint") {
        [checkpointPolicyTextField("content", [compactionLiteral("Checkpoint created.\nGoal: "), range,
                compactionLiteral("\nRun your investigation, then call rewind with a concise report.")]),
            checkpointPolicyTextField("goal", [range]), checkpointPolicyTextField("started_at", [compactionSource(timestamp)])]
    } else {
        [checkpointPolicyTextField("content", [compactionLiteral("Rewind requested.\nReport captured for context replacement.")]),
            checkpointPolicyTextField("report", [range]),
            objectValue([ValueField("name", textValue("rewound")), ValueField("kind", textValue("boolean")), ValueField("value", boolValue(true))]),
            checkpointPolicyTextField("rewound_at", [compactionSource(timestamp)])]
    }
    objectValue([ValueField("fields", listValue(fields))])
}
