package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// A restrict-only answer. The actual Host owns the user control, fixed prompt,
// accounting allowance, current canonical document and the next Run admission.
// This pure query can stop an existing owner; true cannot create or resume one.
func workflowGoalContinuation(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "selector", "approved_document", "current_document", "facts"])
    if (workflowText(input, "schema") != "axyndra.continuation-restriction/v1") {
        throw PureProviderError("workflow.continuation_schema", "unsupported continuation restriction") }
    let selector = input.field("selector").getOrThrow()
    workflowFields(selector, ["action"])
    if (workflowText(selector, "action") != "goal_continuation") {
        throw PureProviderError("workflow.continuation_selector", "unsupported continuation selector") }
    let facts = input.field("facts").getOrThrow()
    workflowFields(facts, ["now_millis", "total_tokens"])
    let now = workflowNonnegative(facts, "now_millis")
    let total = workflowNonnegative(facts, "total_tokens")
    if (now.toString() != facts.field("now_millis").getOrThrow().asNumberText() ||
        total.toString() != facts.field("total_tokens").getOrThrow().asNumberText()) {
        throw PureProviderError("workflow.input_invalid", "canonical integer observations required") }
    let approvedNode = input.field("approved_document").getOrThrow()
    let currentNode = input.field("current_document").getOrThrow()
    if (approvedNode.unifiedKind == ValueKind.Null || currentNode.unifiedKind == ValueKind.Null) {
        return workflowContinuationAnswer(false) }
    let approved = match (decodeGoalState(approvedNode)) {
        case Result.Err(error) => throw PureProviderError(error.code, error.message)
        case Result.Ok(value) => value }
    let current = match (decodeGoalState(currentNode)) {
        case Result.Err(error) => throw PureProviderError(error.code, error.message)
        case Result.Ok(value) => value }
    if (!approved.enabled || approved.status != "active" || approved.id != current.id ||
        approved.objective != current.objective) { return workflowContinuationAnswer(false) }
    // Same old post-Run algorithm: finalizeRun then state(). The second refresh
    // is intentionally retained and has no extra delta at these same facts.
    // The proposed document is query-local and is never returned or committed.
    let policy = WorkflowGoalPolicy(currentNode, now, total, approved.id)
    let session = SessionId("continuation-policy-data")
    match (policy.finalizeRun(session)) {
        case Result.Err(error) => throw PureProviderError(error.code, error.message)
        case Result.Ok(_) => () }
    let state = match (policy.state(session)) {
        case Result.Err(error) => throw PureProviderError(error.code, error.message)
        case Result.Ok(value) => value }
    workflowContinuationAnswer(match (state) {
        case Some(value) => value.enabled && value.status == "active"
        case None => false })
}

func workflowContinuationAnswer(value: Bool): AgentValue {
    objectValue([ValueField("continue", boolValue(value))])
}
