package compaction_plugin

import agent_domain.*
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

// Native owns the grammar and phase recipe. Returned binding/ordinal data is
// never permission, a Source, a canonical boundary or a durable projection.
func checkpointToolDefinitions173(): AgentValue {
    listValue([checkpointToolDefinition173("checkpoint", "goal", "Create a context checkpoint before exploratory work."),
        checkpointToolDefinition173("rewind", "report", "Replace checkpoint exploration with a concise report.")])
}
func checkpointToolDefinition173(name: String, argument: String, description: String): AgentValue {
    objectValue([ValueField("name", textValue(name)), ValueField("execution_profile", textValue("data_only")),
        ValueField("description", textValue(description)),
        ValueField("input_schema", objectValue([ValueField("type", textValue("object")),
            ValueField("properties", objectValue([ValueField(argument, objectValue([ValueField("type", textValue("string"))]))])),
            ValueField("required", listValue([textValue(argument)])), ValueField("additionalProperties", boolValue(false))]))])
}
func checkpointToolName173(name: String): String {
    if (name == "checkpoint" || name == "plugin.axyndra:compaction.checkpoint") { return "checkpoint" }
    if (name == "rewind" || name == "plugin.axyndra:compaction.rewind") { return "rewind" }
    throw PureProviderError("compaction.tool_unknown", "unknown exact compaction Tool contribution")
}
func checkpointToolHistoryReference173(value: AgentValue, name: String): Bool {
    if (name == "checkpoint") {
        return compactionReferenceIs(value, "checkpoint") || compactionReferenceIs(value, "plugin.axyndra:compaction.checkpoint") }
    if (name == "rewind") {
        return compactionReferenceIs(value, "rewind") || compactionReferenceIs(value, "plugin.axyndra:compaction.rewind") }
    false
}
func checkpointToolPrepare173(name: String, arguments: AgentValue): AgentValue {
    let role = checkpointToolName173(name)
    policyFields(arguments, ["schema", "namespace", "package_digest", "generation", "tool", "provider", "action",
        "capability", "effect", "configuration_digest"])
    if (policyText(arguments, "schema") != "axyndra.canonical-data-binding/v1" ||
        policyText(arguments, "namespace") != "axyndra:compaction" || policyText(arguments, "tool") != role) {
        throw PureProviderError("compaction.tool_binding_data_invalid", "unexpected preparation binding description") }
    // Only the actual Host captures this pure recipe in the original prepared
    // plan. It carries no Source, authority, Thread state or legal ordinal.
    checkpointToolRecipe173(role)
}
func checkpointToolExecute173(name: String, arguments: AgentValue): DocumentPolicyToolResult {
    let role = checkpointToolName173(name)
    if (arguments.unifiedKind != ValueKind.Object ||
        arguments.field("projection_recipe").isNone() || arguments.field("projection_binding").isNone()) {
        return DocumentPolicyToolResult(objectValue([ValueField("kind", textValue("configuration")),
            ValueField("code", textValue("checkpoint.canonical_route_required")),
            ValueField("message", textValue("checkpoint Tool requires its current operator-selected canonical-data route")),
            ValueField("fields", listValue([])), ValueField("retryable", boolValue(false)),
            ValueField("fallback_allowed", boolValue(false)), ValueField("attempt_failure", nullValue()),
            ValueField("observation", nullValue())]), isError: true)
    }
    let binding = arguments.field("projection_binding").getOrThrow()
    policyFields(binding, ["schema", "namespace", "package_digest", "generation", "tool", "provider", "action",
        "capability", "effect", "configuration_digest"])
    if (policyText(binding, "schema") != "axyndra.canonical-data-binding/v1" ||
        policyText(binding, "namespace") != "axyndra:compaction" || policyText(binding, "tool") != role ||
        policyText(binding, "action") != "canonical.context.project" || policyText(binding, "capability") != "workspace.read" ||
        policyText(binding, "effect") != "read_only") {
        throw PureProviderError("compaction.tool_binding_data_invalid", "unexpected canonical-data binding description") }
    // A successful actual Tool invocation selects the Native recipe. The
    // mounted Host independently revalidates the original plan/current grant,
    // and Store independently proves the real Receipt and legal save boundary.
    DocumentPolicyToolResult(checkpointToolRecipe173(role))
}
func checkpointToolRecipe173(role: String): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.canonical-data-recipe/v1")),
        ValueField("action", textValue("canonical.context.project")),
        ValueField("role", textValue(role)), ValueField("provider", textValue("summarize")),
        ValueField("execution", objectValue([ValueField("select", textValue("checkpoint_select")),
            ValueField("trim", textValue("checkpoint_trim")), ValueField("validate", textValue("checkpoint_validate")),
            ValueField("begin", textValue("checkpoint_begin")), ValueField("first_batch", textValue("checkpoint_latest_batch")),
            ValueField("second_begin", textValue("checkpoint_after_begin")), ValueField("second_batch", textValue("checkpoint_after_batch")),
            ValueField("check", textValue("checkpoint_check")), ValueField("result", textValue("checkpoint_result"))])),
        ValueField("post_canonical", if (role == "rewind") { objectValue([
            ValueField("layout", textValue("checkpoint_save_layout")), ValueField("validate", textValue("checkpoint_save_validate")),
            ValueField("check", textValue("checkpoint_save_check")), ValueField("result", textValue("checkpoint_save_recipe"))]) } else { nullValue() })])
}
