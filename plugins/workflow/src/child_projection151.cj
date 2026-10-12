package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// The frozen Task recipe chooses business priority and the COMPLETE row shape.
// The numbered members are DATA selectors into a Host-private allocation.
// No large result/history value is included in either policy request.
func workflowChildProjection151(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "recipe", "observation"])
    let recipe = input.field("recipe").getOrThrow()
    workflowFields(recipe, ["schema", "arguments", "batch"])
    if (workflowText(recipe, "schema") != "axyndra.workflow-child-completion/v1") {
        throw PureProviderError("workflow.child_recipe_invalid", "unknown frozen completion recipe") }
    let spec = match (parseWorkflowTask(ToolCall("policy-data", "task", recipe.field("arguments").getOrThrow()))) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw PureProviderError(error.code, error.message) }
    let observed = input.field("observation").getOrThrow()
    let digest = modelPolicySha256Text(canonicalAgentValue(recipe))
    let phase = workflowText(observed, "phase")
    if (phase == "select") {
        workflowFields(observed, ["phase", "status", "has_error", "has_terminal", "use_last_turn", "section_count", "parsed_json"])
        let query = objectValue([ValueField("schema", textValue("axyndra.workflow-policy/v1")),
            ValueField("action", textValue("task_projection")), ValueField("source_digest", textValue(digest)),
            ValueField("has_error", boolValue(workflowText(observed, "status") != "completed" ||
                workflowProjectionBoolean151(observed, "has_error"))),
            ValueField("has_terminal", observed.field("has_terminal").getOrThrow()),
            ValueField("use_last_turn", observed.field("use_last_turn").getOrThrow()),
            ValueField("section_count", observed.field("section_count").getOrThrow()),
            ValueField("parsed_json", observed.field("parsed_json").getOrThrow())])
        let selected = workflowTaskProjection151(query)
        objectValue([ValueField("recipe_digest", textValue(digest)), ValueField("phase", textValue("select")),
            ValueField("projection", selected.field("projection").getOrThrow()),
            ValueField("output_schema", spec.outputSchema ?? nullValue())])
    } else if (phase == "render") {
        workflowFields(observed, ["phase", "run_id", "thread_id", "status", "error", "result_error", "state", "schema_valid", "schema_error"])
        let resultError = workflowText(observed, "result_error")
        let valid = workflowProjectionBoolean151(observed, "schema_valid")
        let schemaError = workflowText(observed, "schema_error")
        let schemaRejected = resultError == "" && !valid && spec.schemaMode == "strict"
        let failed = resultError != "" || schemaRejected
        let business = objectValue([ValueField("application_status", textValue(if (failed) { "failed" } else { "completed" })),
            ValueField("exitCode", integerValue(if (failed) { 1 } else { 0 })), ValueField("output", nullValue()),
            ValueField("stderr", textValue(if (resultError != "") { resultError } else if (schemaRejected) { schemaError } else { "" })),
            ValueField("schema_status", textValue(if (resultError != "" || spec.outputSchema.isNone()) { "unavailable" }
                else if (valid) { "valid" } else { "invalid" })),
            ValueField("schema_error", textValue(if (resultError != "") { "" } else { schemaError })),
            ValueField("schema_mode", textValue(spec.schemaMode))])
        let actualSuccess = workflowText(observed, "status") == "completed"
        // Reuse the original Native row formatter, including original order,
        // state/error precedence and every metadata field. Only its two large
        // payload positions become private-member expressions below.
        let row = workflowChildResultRow111(observed, business)
        let fields = ArrayList<ValueField>()
        for (field in row.fields) {
            let expression = if (field.name == "output" && actualSuccess) {
                workflowProjectionExpression151("encoded_text", 100)
            } else if (field.name == "structuredOutput") {
                let inner = ArrayList<ValueField>()
                for (member in field.value.fields) {
                    inner.add(ValueField(member.name, if (member.name == "data") {
                        workflowProjectionExpression151("member", 100)
                    } else { workflowProjectionLiteral151(member.value) })) }
                workflowProjectionObject151(inner.toArray())
            } else { workflowProjectionLiteral151(field.value) }
            fields.add(ValueField(field.name, expression)) }
        objectValue([ValueField("recipe_digest", textValue(digest)), ValueField("phase", textValue("render")),
            ValueField("accepted", boolValue(actualSuccess && !failed)),
            ValueField("diagnostic", textValue(if (!actualSuccess) { workflowText(observed, "error") } else { httpIntentText(business, "stderr") })),
            ValueField("projection", workflowProjectionObject151(fields.toArray()))])
    } else { throw PureProviderError("workflow.child_observation_invalid", "unknown completion projection phase") }
}
func workflowProjectionExpression151(kind: String, reference: Int64): AgentValue {
    objectValue([ValueField("kind", textValue(kind)), ValueField("reference", integerValue(reference))])
}
func workflowProjectionLiteral151(value: AgentValue): AgentValue {
    objectValue([ValueField("kind", textValue("literal")), ValueField("value", value)])
}
func workflowProjectionObject151(fields: Array<ValueField>): AgentValue {
    objectValue([ValueField("kind", textValue("object")), ValueField("fields", objectValue(fields))])
}
