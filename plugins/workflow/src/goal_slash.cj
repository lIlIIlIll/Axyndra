package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Same lexical arguments as the original CLI. No state is read here and no
// continuation permission comes from the returned data object.
func workflowGoalSlashArguments(raw: String): AgentValue {
    let parts = workflowCommandArguments(raw)
    let verb = if (parts.isEmpty()) { "show" } else { parts[0] }
    let rest = if (parts.isEmpty()) { "" } else { joinTodoArguments(parts, 1) }
    if(verb == "migrate") {
        throw PureProviderError("goal.legacy_payload_required", "Explicit migration requires the selected frontend frozen legacy payload.") }
    var budget: ?Int64 = None
    var objective = ""
    if (["show", "pause", "resume", "drop"].contains(verb)) {
        if (rest != "") { throw PureProviderError("application.goal_invalid_usage", "Invalid goal command.") }
    } else if (verb == "set") {
        if (rest.trimAscii() == "") { throw PureProviderError("application.goal_objective_required", "Goal objective is required.") }
        objective = rest
    } else if (verb == "budget") {
        let value = rest.trimAscii()
        if (value == "") { throw PureProviderError("application.goal_budget_required", "Goal budget must be a positive integer or `off`.") }
        if (value != "off") {
            let amount = try { Int64.parse(value) } catch (_: Exception) {
                throw PureProviderError("application.goal_budget_invalid", "Goal budget must be a positive integer or `off`.") }
            if (amount <= 0 || amount.toString() != value) {
                throw PureProviderError("application.goal_budget_invalid", "Goal budget must be a positive integer or `off`.") }
            budget = Some(amount)
        }
    } else { objective = joinTodoArguments(parts, 0) }
    objectValue([ValueField("verb", textValue(verb)), ValueField("objective", textValue(objective)),
        ValueField("budget", match (budget) { case Some(value) => integerValue(value); case None => nullValue() })])
}

func workflowGoalSlashPolicy(query: AgentValue, document: AgentValue, method: String, arguments: AgentValue): AgentValue {
    workflowGoal(objectValue(query.fields.toArray().map { field => ValueField(field.name,
        if (field.name == "document") { document } else if (field.name == "method") { textValue(method) }
        else if (field.name == "arguments") { arguments } else { field.value }) }))
}

func workflowGoalSlashControl(action: String, budget: AgentValue, prompt: String): AgentValue {
    let fields = ArrayList<ValueField>([ValueField("kind", textValue("continuation")),
        ValueField("document_key", textValue("goal")), ValueField("action", textValue(action))])
    if (["create", "replace", "set_budget", "resume_or_create"].contains(action)) { fields.add(ValueField("token_budget", budget)) }
    if (["create", "replace", "resume", "resume_or_create"].contains(action)) { fields.add(ValueField("next_prompt", textValue(prompt))) }
    if (["create", "replace", "resume", "set_budget", "resume_or_create"].contains(action)) {
        fields.add(ValueField("restriction", objectValue([ValueField("provider", textValue("propose")),
            ValueField("selector", objectValue([ValueField("action", textValue("goal_continuation"))]))])))
    }
    objectValue(fields.toArray())
}

func workflowGoalSlashResult(before: AgentValue, result: AgentValue, text: String, control!: ?AgentValue = None): AgentValue {
    let failure = result.field("failure").getOrThrow()
    let failed = failure.unifiedKind != ValueKind.Null
    let next = result.field("document").getOrThrow()
    let fields = ArrayList<ValueField>([ValueField("changed", boolValue(canonicalAgentValue(before) != canonicalAgentValue(next))),
        ValueField("document", next), ValueField("is_error", boolValue(failed)),
        ValueField("output", if (failed) { objectValue([ValueField("error", failure)]) } else { textValue(text) })])
    if (!failed) { match (control) { case Some(value) => fields.add(ValueField("user_control", value)); case None => () } }
    objectValue(fields.toArray())
}

func workflowGoalSlash(query: AgentValue, raw: String): AgentValue {
    let parsed = workflowGoalSlashArguments(raw)
    let verb = workflowText(parsed, "verb")
    let objective = workflowText(parsed, "objective")
    let original = query.field("document").getOrThrow()
    var current = original
    var state: ?AgentValue = None
    // Original show/set/objective/pause call goalState first. Resume, drop
    // and budget have their own old policy refresh rules and must not get an
    // extra state() refresh (which would alter token accounting on resume).
    if (!["resume", "drop", "budget"].contains(verb)) {
        let value = workflowGoalSlashPolicy(query, current, "state", objectValue([]))
        if (value.field("failure").getOrThrow().unifiedKind != ValueKind.Null) {
            return workflowGoalSlashResult(original, value, "") }
        state = Some(value); current = value.field("document").getOrThrow()
    }
    if (verb == "show") {
        return workflowGoalSlashResult(original, state.getOrThrow(),
            if (current.unifiedKind == ValueKind.Null) { "No goal set." } else { workflowGoalDetails(current) }) }
    if (verb == "pause") {
        if (current.unifiedKind == ValueKind.Null || !current.field("enabled").getOrThrow().asBool()) {
            return workflowGoalSlashResult(original, state.getOrThrow(), "No active goal to pause.") }
        let result = workflowGoalSlashPolicy(query, current, "pause", objectValue([]))
        return workflowGoalSlashResult(original, result, "Goal mode paused.",
            control: Some(workflowGoalSlashControl("pause", nullValue(), "")))
    }
    if (verb == "resume" || verb == "drop") {
        let result = workflowGoalSlashPolicy(query, current, "tool", objectValue([ValueField("op", textValue(verb))]))
        let content = httpIntentText(result.field("output").getOrThrow(), "content")
        let text = (if (verb == "resume") { "Goal mode resumed.\n" } else { "Goal dropped.\n" }) + content
        var resumeBudget: AgentValue = nullValue()
        if (verb == "resume" && result.field("failure").getOrThrow().unifiedKind == ValueKind.Null) {
            let actualGoal = match (decodeGoalState(result.field("document").getOrThrow())) {
                case Result.Ok(value) => value
                case Result.Err(error) => throw PureProviderError(error.code, error.message) }
            resumeBudget = match (actualGoal.tokenBudget) {
                case Some(value) => integerValue(value); case None => nullValue() }
        }
        let control: ?AgentValue = if (verb == "drop" && current.unifiedKind == ValueKind.Null) { None }
            else { Some(workflowGoalSlashControl(if (verb == "drop") { "close" } else { "resume_or_create" }, resumeBudget,
                httpIntentText(result.field("document").getOrThrow(), "objective"))) }
        return workflowGoalSlashResult(original, result, text, control: control)
    }
    if (verb == "budget") {
        let budget = parsed.field("budget").getOrThrow()
        let result = workflowGoalSlashPolicy(query, current, "budget", objectValue([ValueField("token_budget", budget)]))
        let text = if (result.field("failure").getOrThrow().unifiedKind == ValueKind.Null) {
            (if (budget.unifiedKind == ValueKind.Null) { "Goal budget cleared.\n" }
             else { "Goal budget set to " + budget.asNumberText() + ".\n" }) + workflowGoalDetails(result.field("document").getOrThrow())
        } else { "" }
        return workflowGoalSlashResult(original, result, text, control: Some(workflowGoalSlashControl("set_budget", budget, "")))
    }
    if (current.unifiedKind != ValueKind.Null) {
        let enabled = current.field("enabled").getOrThrow().asBool()
        if (!enabled) {
            return workflowGoalSlashResult(original, state.getOrThrow(), "Resume the current goal first, or drop it before setting a new objective.") }
        if (verb != "set") {
            return workflowGoalSlashResult(original, state.getOrThrow(), "Goal mode is already active. Use /goal set to replace it, or /goal drop to start over.") }
    }
    let action = if (current.unifiedKind == ValueKind.Null) { "create" } else { "replace" }
    let result = workflowGoalSlashPolicy(query, current, action, objectValue([ValueField("objective", textValue(objective))]))
    let text = if (result.field("failure").getOrThrow().unifiedKind == ValueKind.Null) {
        (if (action == "create") { "Goal mode enabled.\n" } else { "Goal replaced.\n" }) + workflowGoalDetails(result.field("document").getOrThrow())
    } else { "" }
    workflowGoalSlashResult(original, result, text, control: Some(workflowGoalSlashControl(action, nullValue(), objective.trimAscii())))
}

func workflowGoalDetails(value: AgentValue): String {
    let goal = match (decodeGoalState(value)) { case Result.Ok(result) => result
        case Result.Err(error) => throw PureProviderError(error.code, error.message) }
    var tokens = goal.tokensUsed.toString()
    match (goal.tokenBudget) { case Some(budget) => tokens += " / " + budget.toString() + " (" + max(0, budget - goal.tokensUsed).toString() + " left)"
        case None => tokens += " (no budget)" }
    "Objective: " + goal.objective + "\nStatus: " + goal.status + (if (goal.enabled) { "" } else { " (paused)" }) +
        "\nTokens: " + tokens + "\nTime spent: " + goal.timeUsedSeconds.toString() + "s"
}
