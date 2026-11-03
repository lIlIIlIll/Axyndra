package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import yjson.*
import yjson_support.*

// This contribution consumes input data and produces text. It owns no broker
// service, document intent, capability, source, approval or Receipt.
func workflowPlanToolValue(arguments: AgentValue): AgentValue {
    workflowPlan(objectValue([ValueField("schema", textValue("axyndra.workflow-policy/v1")),
        ValueField("action", textValue("plan")), ValueField("source_digest", textValue("")),
        ValueField("arguments", arguments)]))
}

func workflowPlanPrepare(arguments: AgentValue): AgentValue {
    // The canonical pipeline preserves the submitted arguments. Validation
    // uses the same plugin-owned algorithm as actual execution.
    let _ = workflowPlanToolValue(arguments)
    arguments
}

func workflowPlanExecute(arguments: AgentValue): DocumentPolicyToolResult {
    DocumentPolicyToolResult(workflowPlanToolValue(arguments).field("output").getOrThrow())
}

func workflowPlanTool(): AgentValue {
    objectValue([ValueField("name", textValue("plan_write")),
        ValueField("execution_profile", textValue("data_only")),
        ValueField("description", textValue("Write the complete implementation plan for review. Call once in plan mode " +
            "when the plan is finished. The plan must contain: Goal, Constraints, " +
            "Approach (ordered steps naming files and symbols), Acceptance criteria " +
            "(observable outcomes), Unresolved decisions.")),
        ValueField("input_schema", objectValue([ValueField("type", textValue("object")),
            ValueField("properties", objectValue([ValueField("content", objectValue([
                ValueField("type", textValue("string"))]))])),
            ValueField("required", listValue([textValue("content")])),
            ValueField("additionalProperties", boolValue(false))]))])
}
