package compaction_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func structuredInteger(value: AgentValue, key: String): Int64 {
    let node = value.field(key).getOrThrow()
    if (node.unifiedKind != ValueKind.Number) { throw PureProviderError("compaction.page_invalid", "integer required") }
    Int64.parse(node.asNumberText())
}
func structuredStrings(values: ArrayList<String>): AgentValue {
    listValue(values.toArray().map { value => textValue(value) })
}
func structuredLoadStrings(value: AgentValue, key: String, limit: Int64, into: ArrayList<String>): Unit {
    let values = value.field(key).getOrThrow()
    if (values.unifiedKind != ValueKind.List || values.items.size > limit) {
        throw PureProviderError("compaction.page_invalid", "invalid bounded summary state") }
    for (entry in values.items) {
        if (entry.unifiedKind != ValueKind.Text) { throw PureProviderError("compaction.page_invalid", "invalid summary text") }
        into.add(entry.text)
    }
}
func structuredStateValue(state: StructuredSummaryAccumulator): AgentValue {
    objectValue([ValueField("messages", integerValue(state.messageCount)), ValueField("users", integerValue(state.users)),
        ValueField("assistants", integerValue(state.assistants)), ValueField("excerpts", structuredStrings(state.excerpts)),
        ValueField("prior", structuredStrings(state.priorSummaries)), ValueField("tools", structuredStrings(state.tools)),
        ValueField("read_files", structuredStrings(state.readFiles)), ValueField("modified_files", structuredStrings(state.modifiedFiles)),
        ValueField("created_files", structuredStrings(state.createdFiles)), ValueField("commands", structuredStrings(state.commands)),
        ValueField("results", structuredStrings(state.results)), ValueField("diagnostics", structuredStrings(state.diagnostics))])
}
func structuredStateFromValue(value: AgentValue, offset: Int64): StructuredSummaryAccumulator {
    let state = StructuredSummaryAccumulator()
    if (value.unifiedKind == ValueKind.Null && offset == 0) { return state }
    policyFields(value, ["messages", "users", "assistants", "excerpts", "prior", "tools", "read_files", "modified_files",
        "created_files", "commands", "results", "diagnostics"])
    state.messageCount = structuredInteger(value, "messages")
    state.users = structuredInteger(value, "users"); state.assistants = structuredInteger(value, "assistants")
    if (state.messageCount != offset || state.users < 0 || state.assistants < 0 || state.users > offset ||
        state.assistants != offset - state.users) { throw PureProviderError("compaction.page_invalid", "inconsistent message counts") }
    structuredLoadStrings(value, "excerpts", 6, state.excerpts); structuredLoadStrings(value, "prior", 2, state.priorSummaries)
    structuredLoadStrings(value, "tools", 24, state.tools); structuredLoadStrings(value, "read_files", 24, state.readFiles)
    structuredLoadStrings(value, "modified_files", 24, state.modifiedFiles); structuredLoadStrings(value, "created_files", 24, state.createdFiles)
    structuredLoadStrings(value, "commands", 8, state.commands); structuredLoadStrings(value, "results", 10, state.results)
    structuredLoadStrings(value, "diagnostics", 10, state.diagnostics)
    state
}
// A conservative bound on the old formatter's copied source bytes, before
// constructing its final string. Crossing it selects the exact reference
// strategy; it never truncates or rejects the history. Six accounts for JSON
// control-character escaping, leaving room for the bounded framing literals.
func structuredPageOutputFits(state: StructuredSummaryAccumulator, workflow: StructuredWorkflow): Bool {
    var remaining: Int64 = 450000
    for (values in [state.excerpts, state.priorSummaries, state.tools, state.readFiles, state.modifiedFiles,
        state.createdFiles, state.commands, state.results, state.diagnostics]) {
        for (value in values) { if (value.size > remaining) { return false }; remaining -= value.size }
    }
    match (workflow.goal) {
        case Some(goal) => if (goal.status.size > remaining || remaining - goal.status.size < 600) { return false }
            remaining -= goal.status.size + 600
        case None => ()
    }
    for (phase in workflow.todos) {
        for (task in phase.tasks) {
            match (task.status) {
                case StructuredTodoStatus.Pending | StructuredTodoStatus.InProgress | StructuredTodoStatus.Blocked =>
                    if (phase.name.size > remaining || remaining - phase.name.size < 512) { return false }
                    remaining -= phase.name.size + 512
                case _ => ()
            }
        }
    }; true
}
func structuredReferenceRequired(value: AgentValue): AgentValue {
    objectValue([ValueField("snapshot_digest", value.field("snapshot_digest").getOrThrow()),
        ValueField("page_id", value.field("page_id").getOrThrow()), ValueField("reference_required", boolValue(true))])
}
func structuredPagePolicy(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "page_id", "offset", "total", "projection", "state", "goal", "todos"])
    let offset = structuredInteger(value, "offset"); let total = structuredInteger(value, "total")
    if (offset < 0 || total < offset) { throw PureProviderError("compaction.page_invalid", "invalid projection coverage") }
    let request = match (modelRequestFromSnapshotValue(value.field("projection").getOrThrow(), "")) {
        case Result.Err(_) => throw PureProviderError("compaction.projection_invalid", "invalid neutral projection")
        case Result.Ok(data) => data }
    if (request.messages.size > total - offset || (request.messages.isEmpty() && offset != total)) {
        throw PureProviderError("compaction.page_invalid", "non-progressing projection page") }
    let state = structuredStateFromValue(value.field("state").getOrThrow(), offset)
    for (message in request.messages) { state.add(message) }
    let workflow = structuredWorkflow(value)
    let finalPage = state.messageCount == total
    if (!structuredPageOutputFits(state, workflow)) { return structuredReferenceRequired(value) }
    let result = objectValue([ValueField("snapshot_digest", textValue(policyText(value, "snapshot_digest"))),
        ValueField("page_id", textValue(policyText(value, "page_id"))), ValueField("next_offset", integerValue(state.messageCount)),
        ValueField("state", if (finalPage) { nullValue() } else { structuredStateValue(state) }),
        ValueField("summary", if (finalPage) { textValue(state.finish(workflow.goal, workflow.todos)) } else { nullValue() })])
    if (stringifyUnifiedJson(result).size > 3000000) {
        return structuredReferenceRequired(value) }
    result
}
