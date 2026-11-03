package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

// Native owns completion precedence. This bounded recipe does not transport
// whole section/terminal values and grants no permission or child identity.
func workflowTaskProjection151(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "has_error", "has_terminal",
        "use_last_turn", "section_count", "parsed_json"])
    let error = workflowProjectionBoolean151(input, "has_error")
    let terminal = workflowProjectionBoolean151(input, "has_terminal")
    let last = workflowProjectionBoolean151(input, "use_last_turn")
    let sections = workflowNonnegative(input, "section_count")
    let parsed = input.field("parsed_json").getOrThrow()
    if (parsed.unifiedKind != ValueKind.Null && parsed.unifiedKind != ValueKind.Boolean) {
        throw PureProviderError("workflow.input_invalid", "parsed JSON observation must be null or Boolean") }
    let recipe = if (error) { workflowProjectionRecipe151("value", 3) }
        else if (terminal) { workflowProjectionRecipe151("value", 0) }
        else if (last) { workflowProjectionRecipe151("value", 1) }
        else if (sections > 0) { workflowProjectionRecipe151("fields", 0) }
        else if (parsed.unifiedKind == ValueKind.Null) { workflowProjectionRecipe151("parse", 1) }
        else if (parsed.asBool()) { workflowProjectionRecipe151("value", 2) }
        else { workflowProjectionRecipe151("value", 1) }
    objectValue([ValueField("source_digest", textValue(workflowText(input, "source_digest"))),
        ValueField("failed", boolValue(error)), ValueField("projection", recipe)])
}
func workflowProjectionRecipe151(kind: String, reference: Int64): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.value-projection/v1")),
        ValueField("kind", textValue(kind)), ValueField("reference", integerValue(reference))])
}
func workflowProjectionBoolean151(input: AgentValue, name: String): Bool {
    let value = input.field(name).getOrThrow()
    if (value.unifiedKind != ValueKind.Boolean) {
        throw PureProviderError("workflow.input_invalid", "completion observation must be Boolean") }
    value.asBool()
}
