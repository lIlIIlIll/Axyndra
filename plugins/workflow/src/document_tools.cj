package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func workflowDocumentSnapshot(input: AgentValue, key: String): AgentValue {
    let envelope = input.field(CONTEXT_READ_INPUT_FIELD) ?? nullValue()
    let data = envelope.field("data") ?? nullValue()
    if (httpIntentText(envelope, "schema") != "axyndra.context-read-input/v1" ||
        httpIntentText(data, "schema") != "axyndra.plugin-document-read-result/v1") {
        throw PureProviderError("workflow.document_fact_missing", "document Tool requires the Host's completed read observation") }
    var found: ?AgentValue = None
    for (item in (data.field("documents") ?? listValue([])).items where httpIntentText(item, "key") == key) {
        if (found.isSome()) { throw PureProviderError("workflow.document_fact_ambiguous", "document observation is duplicated") }
        found = Some(item)
    }
    match (found) { case Some(value) => value
        case None => throw PureProviderError("workflow.document_fact_missing", "requested document was not observed") }
}

func workflowDocumentProposal(name: String, input: AgentValue): AgentValue {
    if (name == "goal") { return workflowGoalDocumentProposal(input) }
    if (name != "todo") { throw PureProviderError("workflow.tool_unknown", "no exact document Tool implementation") }
    let snapshot = workflowDocumentSnapshot(input, "todo")
    let raw = httpIntentText(snapshot, "json")
    if (raw == "" || modelPolicySha256Text(raw) != httpIntentText(snapshot, "sha256")) {
        throw PureProviderError("workflow.document_fact_invalid", "document bytes differ from their observation") }
    let value = parseUnifiedJson(raw, maxBytes: 8388608, maxDepth: 32)
    // A verified absence/tombstone has the same old empty-todo semantics. An
    // existing malformed document is still a typed error, never overwritten.
    let previous = if (value.unifiedKind == ValueKind.Null) { listValue([]) } else { value }
    let arguments = objectValue(input.fields.toArray().filter { field => field.name != CONTEXT_READ_INPUT_FIELD }
        .map { field => ValueField(field.name, field.value) })
    if (arguments.field("frontend_action").isSome()) {
        return workflowTodoFrontend(previous,snapshot,arguments)
    }
    if (arguments.field("command_args").isSome()) {
        workflowFields(arguments, ["command_args"])
        return workflowTodoSlash(previous, workflowText(arguments, "command_args"))
    }
    workflowTodo(objectValue([ValueField("schema", textValue("axyndra.workflow-policy/v1")),
        ValueField("action", textValue("todo")), ValueField("source_digest", textValue(httpIntentText(snapshot, "sha256"))),
        ValueField("arguments", arguments), ValueField("document", previous)]))
}

func workflowDocumentIntent(name: String, proposal: AgentValue): AgentValue {
    // A Host user-control claim must share a real document CAS/Receipt. The
    // same bytes still get a new revision; a read Receipt cannot carry control.
    let changed = proposal.field("changed").getOrThrow().asBool() || proposal.field("user_control").isSome()
    objectValue([ValueField("id", textValue(name + "-1")), ValueField("key", textValue(name)),
        ValueField("mode", textValue(if (changed) { "compare_exchange" } else { "read" })),
        ValueField("next_json", if (changed) { textValue(stringifyUnifiedJson(proposal.field("document").getOrThrow())) } else { nullValue() })])
}

func workflowDocumentPrepare(name: String, arguments: AgentValue): AgentValue {
    workflowFields(arguments, ["input"])
    let input = arguments.field("input").getOrThrow()
    if (!["todo", "goal"].contains(name) || input.unifiedKind != ValueKind.Object) {
        throw PureProviderError("workflow.tool_unknown", "unsupported document preparation") }
    if (input.field(CONTEXT_READ_INPUT_FIELD).isNone()) {
        return objectValue([ValueField("document_read", objectValue([ValueField("keys", listValue([textValue(name)]))]))]) }
    let proposal = workflowDocumentProposal(name, input)
    let result = objectValue([ValueField("intents", listValue([workflowDocumentIntent(name, proposal)]))])
    match (proposal.field("user_control")) { case Some(value) => result.put("user_control", value); case None => () }
    result
}

func workflowDocumentExecute(name: String, arguments: AgentValue, broker: DocumentPolicyBroker): DocumentPolicyToolResult {
    workflowFields(arguments, ["input", "configuration", "host_plan"])
    let proposal = workflowDocumentProposal(name, arguments.field("input").getOrThrow())
    let expected = workflowDocumentIntent(name, proposal)
    let plan = arguments.field("host_plan").getOrThrow()
    let intents = plan.field("intents") ?? nullValue()
    if (httpIntentText(plan, "version") != "axyndra.plugin-document-parent/v1" ||
        intents.unifiedKind != ValueKind.List || intents.items.size != 1) {
        throw PureProviderError("workflow.document_plan_invalid", "Tool execution requires its one frozen document intent") }
    let actual = intents.items[0]
    for (field in ["id", "key", "mode", "next_json"]) {
        if (canonicalAgentValue(actual.field(field) ?? nullValue()) != canonicalAgentValue(expected.field(field).getOrThrow())) {
            throw PureProviderError("workflow.document_plan_changed", "document proposal changed after preparation") }
    }
    // This is the only service call. Read-only/error proposals consume a read
    // intent too, so no business success can bypass the canonical read Receipt.
    let _ = broker.consume(name + "-1")
    DocumentPolicyToolResult(proposal.field("output").getOrThrow(), isError: proposal.field("is_error").getOrThrow().asBool())
}

func workflowDocumentCommand(name: String, input: AgentValue): AgentValue {
    if (name == "plan_review") { return workflowPlanReviewCommand(input) }
    if (name == "goal") { return workflowGoalCommand(input) }
    if (name != "todo") { throw PureProviderError("workflow.command_unknown", "no exact document command implementation") }
    workflowTodoCommand(input)
}

func workflowDocumentTools(): AgentValue {
    listValue([workflowGoalDocumentTool(), workflowPlanTool(), objectValue([ValueField("name", textValue("todo")),
        ValueField("description", textValue("Read or update the current session's ordered task phases.")),
        ValueField("input_schema", objectValue([ValueField("type", textValue("object")),
            ValueField("properties", objectValue([
                ValueField("frontend_action",objectValue([ValueField("type",textValue("string"))])),
                ValueField("text",objectValue([ValueField("type",textValue("string"))])),
                ValueField("expected_digest",objectValue([ValueField("type",textValue("string"))])),
                ValueField("phases",objectValue([ValueField("type",textValue("array"))])),
                ValueField("legacy_json",objectValue([ValueField("type",textValue("string"))])),
                ValueField("legacy_digest",objectValue([ValueField("type",textValue("string"))])),
                ValueField("destination",objectValue([ValueField("type",textValue("string"))])),
                ValueField("reference",objectValue([ValueField("type",textValue("string"))])),
                ValueField("command_args", objectValue([ValueField("type", textValue("string")),
                    ValueField("description", textValue("Frozen Todo command arguments; exclusive with structured operation fields."))])),
                ValueField("op", objectValue([ValueField("type", textValue("string"))])),
                ValueField("task", objectValue([ValueField("type", textValue("string"))])),
                ValueField("phase", objectValue([ValueField("type", textValue("string"))])),
                ValueField("reason", objectValue([ValueField("type", textValue("string"))])),
                ValueField("items", objectValue([ValueField("type", textValue("array"))])),
                ValueField("list", objectValue([ValueField("type", textValue("array"))]))]))]))])])
}

func workflowDocumentPolicy(name: String, input: AgentValue): AgentValue {
    if (name == "propose") { return workflowPolicy(input) }
    workflowFields(input, ["schema", "tool", "input"])
    if (name != "prepare_document" || httpIntentText(input, "schema") != "axyndra.tool-preparation-query/v1") {
        throw PureProviderError("workflow.preparation_query_invalid", "expected exact pure Tool preparation data") }
    workflowDocumentPrepare(httpIntentText(input, "tool"), objectValue([ValueField("input", input.field("input").getOrThrow())]))
}
