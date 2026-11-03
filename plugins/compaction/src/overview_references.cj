package compaction_plugin

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func compactionOverviewLimit(value: AgentValue): Int64 {
    let tokens = structuredInteger(value, "max_output_tokens")
    if (tokens < 1 || tokens > 65536) { compactionFragmentError() }
    max(64, tokens * 4)
}
func compactionOverviewState(text: String, overflow: Bool, invalid: Bool): AgentValue {
    objectValue([ValueField("text", textValue(text)), ValueField("overflow", boolValue(overflow)), ValueField("invalid", boolValue(invalid))])
}
func compactionOverviewReferences(input: AgentValue): AgentValue {
    let phase = policyText(input, "phase"); let limit = compactionOverviewLimit(input)
    if (phase == "prepare_reference") {
        policyFields(input, ["schema", "phase", "snapshot_digest", "facts", "model", "max_output_tokens"])
        return objectValue([ValueField("model", input.field("model").getOrThrow()),
            ValueField("system", textValue(COMPACTION_SEMANTIC_SYSTEM_PROMPT)), ValueField("thinking", textValue("low")),
            ValueField("user_recipe", listValue([compactionLiteral("Write the semantic overview from these authoritative structured facts:\n\n"),
                compactionSource(input.field("facts").getOrThrow())]))])
    }
    if (phase == "overview_begin") {
        policyFields(input, ["schema", "phase", "snapshot_digest", "max_output_tokens", "accepted_output", "stop_reason"])
        return compactionOverviewState("", false, !compactionFragmentBool(input, "accepted_output") || policyText(input, "stop_reason") == "tool_use")
    }
    let state = input.field("state").getOrThrow()
    policyFields(state, ["text", "overflow", "invalid"])
    let prefix = policyText(state, "text"); let overflow = compactionFragmentBool(state, "overflow")
    let invalid = compactionFragmentBool(state, "invalid")
    if (prefix.toRuneArray().size > limit) { compactionFragmentError() }
    if (phase == "overview_finish") {
        policyFields(input, ["schema", "phase", "snapshot_digest", "max_output_tokens", "state"])
        return objectValue([ValueField("overview", if (invalid || prefix == "") { nullValue() }
            else { textValue(prefix + if (overflow) { "…" } else { "" }) })])
    }
    let kind = policyText(input, "kind")
    if (phase == "overview_plan") {
        policyFields(input, ["schema", "phase", "snapshot_digest", "max_output_tokens", "state", "kind"])
        return objectValue([ValueField("read", boolValue(kind == "text" && !overflow && !invalid))])
    }
    policyFields(input, ["schema", "phase", "snapshot_digest", "max_output_tokens", "state", "kind", "reduced"])
    if (phase != "overview_merge") { compactionFragmentError() }
    if (kind != "text" && kind != "reasoning") { return compactionOverviewState(prefix, overflow, true) }
    if (kind == "reasoning" || overflow || invalid) { return state }
    let reduced = policyText(input, "reduced")
    if (reduced.toRuneArray().size > limit + 1) { compactionFragmentError() }
    if (reduced == "") { return state }
    let combined = prefix + if (prefix == "") { "" } else { "\n" } + reduced
    let runes = combined.toRuneArray()
    compactionOverviewState(if (runes.size > limit) { String(runes[..limit]) } else { combined }, runes.size > limit, false)
}

// Unlike structured compactText, overview normalization preserves LF and
// truncates by Unicode scalar count. The bounded pending suffix is necessary:
// arbitrary trailing ASCII whitespace must be discarded, not counted as text.
func compactionOverviewFragment(input: AgentValue): AgentValue {
    policyFields(input, ["schema", "phase", "snapshot_digest", "source", "sequence", "mode", "limit", "offset", "total", "text", "carry"])
    let offset = structuredInteger(input, "offset"); let total = structuredInteger(input, "total")
    let limit = structuredInteger(input, "limit"); let chunk = policyText(input, "text")
    if (policyText(input, "mode") != "overview" || limit < 64 || limit > 262144 || offset < 0 || total < offset ||
        chunk.size > min(262144, total - offset) || (chunk == "" && total != 0)) { compactionFragmentError() }
    let carry = input.field("carry").getOrThrow(); var prefix = ""; var pending = ""; var excess = false
    if (carry.unifiedKind != ValueKind.Null) {
        policyFields(carry, ["offset", "prefix", "pending", "excess"])
        if (structuredInteger(carry, "offset") != offset) { compactionFragmentError() }
        prefix = policyText(carry, "prefix"); pending = policyText(carry, "pending"); excess = compactionFragmentBool(carry, "excess")
    } else if (offset != 0) { compactionFragmentError() }
    let output = ArrayList<Rune>(prefix.toRuneArray()); let held = ArrayList<Rune>(pending.toRuneArray())
    if (output.size > limit || held.size > limit + 1 - output.size) { compactionFragmentError() }
    for (rune in held where !(rune == r' ' || (rune >= r'\t' && rune <= r'\r'))) { compactionFragmentError() }
    var complete = false
    for (rune in chunk.toRuneArray()) {
        if (rune == r'\r') { continue }
        if (rune == r' ' || (rune >= r'\t' && rune <= r'\r')) {
            if (!output.isEmpty()) {
                if (held.size < limit + 1 - output.size) { held.add(rune) } else { excess = true }
            }
        } else {
            output.add(all: held.toArray()); held.clear()
            if (output.size <= limit) { output.add(rune) }
            if (excess || output.size > limit) { complete = true; break }
        }
    }
    let next = offset + chunk.size
    complete = complete || next == total
    let text = String(output.toArray())
    compactionFragmentReply(input, [ValueField("next_offset", integerValue(next)), ValueField("complete", boolValue(complete)),
        ValueField("prior", boolValue(false)), ValueField("result", if (complete) { textValue(text) } else { nullValue() }),
        ValueField("carry", objectValue([ValueField("offset", integerValue(next)), ValueField("prefix", textValue(text)),
            ValueField("pending", textValue(if (complete) { "" } else { String(held.toArray()) })), ValueField("excess", boolValue(excess))]))])
}
