package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// The observation is data from the actual result slot. Revision is a CAS
// condition only; it cannot authorize a write or manufacture a delegated Run.
func workflowYieldWriter150(arguments: AgentValue, slot: AgentValue): AgentValue {
    workflowFields(slot, ["available", "revision", "has_error"])
    if (slot.field("available").getOrThrow().unifiedKind != ValueKind.Boolean ||
        slot.field("has_error").getOrThrow().unifiedKind != ValueKind.Boolean ||
        slot.field("revision").getOrThrow().unifiedKind != ValueKind.Number ||
        arguments.unifiedKind != ValueKind.Object) {
        throw PureProviderError("workflow.yield_observation_invalid", "invalid observed result slot")
    }
    let available = slot.field("available").getOrThrow().asBool()
    let revision = Int64.parse(slot.field("revision").getOrThrow().asNumberText())
    if ((available && (revision < 0 || revision == Int64.Max)) || (!available && revision != -1)) {
        throw PureProviderError("workflow.yield_observation_invalid", "invalid observed result revision")
    }
    let state = WorkflowYieldState111()
    // The old response needs only whether an earlier accepted error exists.
    // Its actual text and all earlier terminal/section values stay in Host.
    if (slot.field("has_error").getOrThrow().asBool()) { state.error = "observed prior error" }
    let call = ToolCall("policy-data", "yield", arguments)
    let executed: Result<ToolResult> = if (available) { workflowApplyYield111(state, call) }
        else { Result.Ok(ToolResult(call.callId,
            objectValue([ValueField("error", textValue("yield is only available inside a delegated task"))]), isError: true)) }
    let result = match (executed) {
        case Result.Err(error) => return objectValue([ValueField("failure", workflowBusinessFailure111(error))])
        case Result.Ok(value) => value
    }
    var kind = "none"
    var value: AgentValue = nullValue()
    var labels: Array<AgentValue> = []
    if (!result.isError && available) {
        if (!state.sections.isEmpty()) {
            kind = "append_section"; value = state.sections[0].data
            labels = state.sections[0].labels.map { label => textValue(label) }
        } else if (state.terminal.isSome()) {
            kind = "replace_terminal"; value = state.terminal.getOrThrow()
        } else if (state.useLastTurn) {
            kind = "use_last_turn"
        } else {
            kind = "replace_error"; value = textValue(state.error)
        }
    }
    objectValue([ValueField("revision", integerValue(revision)), ValueField("available", boolValue(available)),
        ValueField("mutation", objectValue([ValueField("kind", textValue(kind)),
            ValueField("labels", listValue(labels)), ValueField("value", value)])),
        ValueField("result", objectValue([ValueField("output", result.output), ValueField("is_error", boolValue(result.isError))]))])
}

func workflowYieldPrepare150(arguments: AgentValue, options: AgentValue): AgentValue {
    workflowFields(arguments, ["input"])
    workflowFields(options, ["result_slot"])
    let input = workflowYieldWriter150(arguments.field("input").getOrThrow(), options.field("result_slot").getOrThrow())
    if (input.field("failure").isSome()) { return input }
    objectValue([ValueField("intents", listValue([objectValue([
        ValueField("id", textValue("result-write")), ValueField("service", textValue("child.result.write")),
        ValueField("input", input)])]))])
}

func workflowYieldExecute150(arguments: AgentValue, broker: FrozenPrimitiveBroker111): DocumentPolicyToolResult {
    workflowFields(arguments, ["input", "configuration", "host_plan"])
    let proposed = workflowYieldPrepare150(objectValue([ValueField("input", arguments.field("input").getOrThrow())]),
        arguments.field("configuration").getOrThrow())
    if (proposed.field("failure").isSome()) { throw PureProviderError("workflow.yield_plan_invalid", "failed validation cannot be executed") }
    let plan = arguments.field("host_plan").getOrThrow()
    if (httpIntentText(plan, "version") != PLUGIN_PRIMITIVE_PARENT111 ||
        canonicalAgentValue(proposed.field("intents").getOrThrow()) != canonicalAgentValue(plan.field("intents").getOrThrow())) {
        throw PureProviderError("workflow.yield_plan_changed", "frozen result mutation changed after approval")
    }
    let response = broker.consume("result-write")
    let output = response.field("output").getOrThrow()
    workflowFields(output, ["output", "is_error"])
    if (output.field("is_error").getOrThrow().unifiedKind != ValueKind.Boolean ||
        canonicalAgentValue(output) != canonicalAgentValue(proposed.field("intents").getOrThrow().items[0]
            .field("input").getOrThrow().field("result").getOrThrow())) {
        throw PureProviderError("workflow.yield_result_changed", "actual result writer acknowledged another response")
    }
    DocumentPolicyToolResult(output.field("output").getOrThrow(), isError: output.field("is_error").getOrThrow().asBool())
}
