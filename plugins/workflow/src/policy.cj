package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Pure proposals only. Current document, time and usage facts are supplied by
// the Host; no repository, Run, model loop or permission is held by this worker.
func workflowFields(value: AgentValue, names: Array<String>): Unit {
    if (value.unifiedKind != ValueKind.Object || value.fields.size != names.size) {
        throw PureProviderError("workflow.input_invalid", "unexpected workflow fields") }
    for (name in names where value.field(name).isNone()) { throw PureProviderError("workflow.input_invalid", "missing workflow field") }
}
func workflowText(value: AgentValue, name: String): String {
    let node = value.field(name).getOrThrow()
    if (node.unifiedKind != ValueKind.Text) { throw PureProviderError("workflow.input_invalid", "text field required") }
    node.text
}
func workflowProposal(input: AgentValue, before: AgentValue, after: AgentValue, result: ToolResult): AgentValue {
    objectValue([ValueField("source_digest", textValue(workflowText(input, "source_digest"))),
        ValueField("changed", boolValue(!canonicalAgentValuesEqual(before, after))),
        ValueField("document", after), ValueField("output", result.output), ValueField("is_error", boolValue(result.isError))])
}
func workflowTodo(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "arguments", "document"])
    let before = input.field("document").getOrThrow()
    let previous = match (decodeTodoPhases(before)) {
        case Result.Ok(value) => value
        case Result.Err(error) => throw PureProviderError(error.code, error.message) }
    let arguments = input.field("arguments").getOrThrow()
    if (arguments.unifiedKind != ValueKind.Object) { throw PureProviderError("workflow.input_invalid", "tool arguments must be an object") }
    let call = ToolCall("policy-data", "todo", arguments)
    let params = match (parseTodoParams(call, !previous.isEmpty())) {
        case Result.Ok(value) => value
        case Result.Err(error) => return workflowProposal(input, before, before, todoErrorResult(call, previous, error.message)) }
    if (params.op == "view") {
        return workflowProposal(input, before, before, todoResult(call, params.op, previous, [], todoSummary(previous, readOnly: true))) }
    let phases = mutableTodoPhases(previous)
    let errors = ArrayList<String>()
    applyTodoOperation(phases, params, errors)
    if (!errors.isEmpty()) {
        return workflowProposal(input, before, before, todoErrorResult(call, previous, joinTodoErrors(errors.toArray()))) }
    normalizeTodoProgress(phases)
    let updated = immutableTodoPhases(phases)
    workflowProposal(input, before, encodeTodoPhases(updated), todoResult(call, params.op, updated,
        todoCompletions(previous, updated), todoSummary(updated)))
}
func workflowMarkdown(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "mode", "document", "text"])
    let mode = workflowText(input, "mode")
    let document = if (mode == "parse") {
        match (todoPhasesFromMarkdown(workflowText(input, "text"))) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw PureProviderError(error.code, error.message) }
    } else if (mode == "format") {
        match (decodeTodoPhases(input.field("document").getOrThrow())) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw PureProviderError(error.code, error.message) }
    } else { throw PureProviderError("workflow.input_invalid", "unknown markdown mode") }
    objectValue([ValueField("source_digest", textValue(workflowText(input, "source_digest"))),
        ValueField("document", encodeTodoPhases(document)), ValueField("text", textValue(todoPhasesToMarkdown(document)))])
}
func workflowPlan(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "arguments"])
    let arguments = input.field("arguments").getOrThrow()
    if (arguments.unifiedKind != ValueKind.Object) { throw PureProviderError("workflow.input_invalid", "tool arguments must be an object") }
    let content = match (arguments.field("content")) { case Some(value) => value.text.trimAscii(); case None => "" }
    if (content == "") { throw PureProviderError("plan_write.empty", "plan_write requires a non-empty content field") }
    objectValue([ValueField("source_digest", textValue(workflowText(input, "source_digest"))),
        ValueField("content", textValue(content)), ValueField("output", textValue("Plan recorded for review. The user reviews it via /plan-review before execution."))])
}
func workflowPolicy(input: AgentValue): AgentValue {
    if (workflowText(input, "schema") == "axyndra.continuation-restriction/v1") {
        return workflowGoalContinuation(input) }
    if (workflowText(input, "schema") != "axyndra.workflow-policy/v1") {
        throw PureProviderError("workflow.schema", "unsupported workflow schema") }
    match (workflowText(input, "action")) {
        case "todo" => workflowTodo(input)
        case "todo_markdown" => workflowMarkdown(input)
        case "plan" => workflowPlan(input)
        case "goal" => workflowGoal(input)
        case "task" => workflowTask(input)
        case "task_output" => workflowTaskOutput111(input)
        case "task_projection" => workflowTaskProjection151(input)
        case "task_route" => workflowTaskRouting111(input)
        case "yield" => workflowYieldPolicy111(input)
        case "hub" => workflowHubPolicy111(input)
        case "hub_process" => workflowHubProcessPolicy(input)
        case "hub_process_output" => workflowHubProcessProjectionPolicy(input)
        case "role" => workflowRole(input)
        case "roles" => workflowRoles(input)
        case "guidance" => workflowGuidance(input)
        case _ => throw PureProviderError("workflow.action", "unsupported workflow proposal") }
}

func workflowNonnegative(input: AgentValue, name: String): Int64 {
    let node = input.field(name).getOrThrow()
    if (node.unifiedKind != ValueKind.Number) { throw PureProviderError("workflow.input_invalid", "integer observation required") }
    let value = try { Int64.parse(node.asNumberText()) } catch (_: Exception) {
        throw PureProviderError("workflow.input_invalid", "integer observation is outside the supported range") }
    if (value < 0) { throw PureProviderError("workflow.input_invalid", "negative observation") }
    value
}
func workflowGoal(input: AgentValue): AgentValue {
    workflowFields(input, ["schema", "action", "source_digest", "method", "session_id", "arguments", "document", "facts"])
    let facts = input.field("facts").getOrThrow()
    workflowFields(facts, ["now_millis", "total_tokens", "proposed_goal_id"])
    let now = workflowNonnegative(facts, "now_millis")
    let total = workflowNonnegative(facts, "total_tokens")
    let proposedId = workflowText(facts, "proposed_goal_id")
    if (proposedId == "") { throw PureProviderError("workflow.input_invalid", "Host proposal identity required") }
    let before = input.field("document").getOrThrow()
    let policy = WorkflowGoalPolicy(before, now, total, proposedId)
    let arguments = input.field("arguments").getOrThrow()
    if (arguments.unifiedKind != ValueKind.Object) { throw PureProviderError("workflow.input_invalid", "goal arguments must be an object") }
    let call = ToolCall("policy-data", "goal", arguments)
    let session = SessionId(workflowText(input, "session_id"))
    let result: Result<AgentValue> = match (workflowText(input, "method")) {
        case "tool" => match (policy.execute(session, call)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(value) => Result.Ok(value.output) }
        case "prompt" => match (policy.activePrompt(session)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(value) => Result.Ok(textValue(value)) }
        case "finalize" => match (policy.finalizeRun(session)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(nullValue()) }
        case "pause" => match (policy.pause(session)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(nullValue()) }
        case "restore" => match (policy.pauseRestoredActive(session)) {
            case Result.Err(error) => Result.Err(error); case Result.Ok(_) => Result.Ok(nullValue()) }
        case "state" => match (policy.state(session)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result.Ok(match (value) { case Some(goal) => encodeGoalState(goal); case None => nullValue() }) }
        case "create" | "replace" =>
            match (goalRequiredText(call, "objective", "objective is required when creating a goal")) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(objective) => match (goalOptionalPositiveInteger(call, "token_budget")) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(budget) =>
                        let created = if (workflowText(input, "method") == "create") {
                            policy.createGoal(session, objective, tokenBudget: budget)
                        } else { policy.replaceGoal(session, objective, tokenBudget: budget) }
                        match (created) { case Result.Err(error) => Result.Err(error); case Result.Ok(goal) => Result.Ok(encodeGoalState(goal)) }
                }
            }
        case "budget" =>
            // The user command's explicit null is the old setBudget(None)
            // operation. Ordinary create/tool arguments keep their positive
            // integer validation; this is not a new budget or resume grant.
            let selected = call.arguments.field("token_budget")
            let parsedBudget: Result<?Int64> = if (selected.isSome() && selected.getOrThrow().unifiedKind == ValueKind.Null) {
                Result.Ok(None)
            } else { goalOptionalPositiveInteger(call, "token_budget") }
            match (parsedBudget) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(value) => match (policy.setBudget(session, value)) {
                    case Result.Err(error) => Result.Err(error); case Result.Ok(goal) => Result.Ok(encodeGoalState(goal)) } }
        case _ => throw PureProviderError("workflow.method", "unsupported goal method")
    }
    let output = match (result) { case Result.Ok(value) => value; case Result.Err(_) => nullValue() }
    let failure = match (result) { case Result.Ok(_) => nullValue(); case Result.Err(error) => objectValue([
        ValueField("code", textValue(error.code)), ValueField("message", textValue(error.message))]) }
    objectValue([ValueField("source_digest", textValue(workflowText(input, "source_digest"))),
        ValueField("changed", boolValue(canonicalAgentValue(before) != canonicalAgentValue(policy.proposedDocument))),
        ValueField("document", policy.proposedDocument), ValueField("output", output), ValueField("failure", failure)])
}
