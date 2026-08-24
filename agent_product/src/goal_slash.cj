package agent_product

import agent_domain.*
import std.convert.*

func handleGoalSlash(
    product: ProductRuntime,
    sessionId: SessionId,
    arguments: Array<String>
): Result<ApplicationResponse> {
    if (arguments.isEmpty()) {
        return goalShowResponse(product, sessionId)
    }
    let command = arguments[0]
    let rest = joinCommandArguments(arguments[1..])
    match (command) {
        case "set" => goalSetResponse(product, sessionId, rest)
        case "show" =>
            if (rest == "") {
                goalShowResponse(product, sessionId)
            } else {
                goalSlashUsage()
            }
        case "pause" =>
            if (rest == "") {
                goalPauseResponse(product, sessionId)
            } else {
                goalSlashUsage()
            }
        case "resume" =>
            if (rest == "") {
                goalToolSlashResponse(
                    product,
                    sessionId,
                    "resume"
                )
            } else {
                goalSlashUsage()
            }
        case "drop" =>
            if (rest == "") {
                goalToolSlashResponse(product, sessionId, "drop")
            } else {
                goalSlashUsage()
            }
        case "budget" =>
            goalBudgetResponse(product, sessionId, rest)
        case _ =>
            goalObjectiveResponse(
                product,
                sessionId,
                joinCommandArguments(arguments)
            )
    }
}

func goalObjectiveResponse(
    product: ProductRuntime,
    sessionId: SessionId,
    objective: String
): Result<ApplicationResponse> {
    let state = match (product.goalState(sessionId)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match (state) {
        case Some(goal) =>
            if (goal.enabled) {
                Result.Ok(localResponse(
                    "Goal mode is already active. Use /goal set to " +
                        "replace it, or /goal drop to start over."
                ))
            } else {
                Result.Ok(localResponse(
                    "Resume the current goal first, or drop it before " +
                        "setting a new objective."
                ))
            }
        case None =>
            match (product.createGoal(sessionId, objective)) {
                case Result.Ok(goal) =>
                    Result.Ok(localResponse(
                        "Goal mode enabled.\n" +
                            goalDetails(goal)
                    ))
                case Result.Err(error) => Result.Err(error)
            }
    }
}

func goalSetResponse(
    product: ProductRuntime,
    sessionId: SessionId,
    objective: String
): Result<ApplicationResponse> {
    if (objective.trimAscii() == "") {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "application.goal_objective_required",
            "Goal objective is required.",
            fields: [ErrorField(
                "usage",
                "/goal set <objective>"
            )]
        ))
    }
    let state = match (product.goalState(sessionId)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match (state) {
        case Some(goal) =>
            if (!goal.enabled) {
                return Result.Ok(localResponse(
                    "Resume the current goal first, or drop it before " +
                        "setting a new objective."
                ))
            }
            match (product.replaceGoal(sessionId, objective)) {
                case Result.Ok(updated) =>
                    Result.Ok(localResponse(
                        "Goal replaced.\n" + goalDetails(updated)
                    ))
                case Result.Err(error) => Result.Err(error)
            }
        case None =>
            match (product.createGoal(sessionId, objective)) {
                case Result.Ok(created) =>
                    Result.Ok(localResponse(
                        "Goal mode enabled.\n" + goalDetails(created)
                    ))
                case Result.Err(error) => Result.Err(error)
            }
    }
}

func goalShowResponse(
    product: ProductRuntime,
    sessionId: SessionId
): Result<ApplicationResponse> {
    match (product.goalState(sessionId)) {
        case Result.Ok(Some(goal)) =>
            Result.Ok(localResponse(goalDetails(goal)))
        case Result.Ok(None) =>
            Result.Ok(localResponse("No goal set."))
        case Result.Err(error) => Result.Err(error)
    }
}

func goalPauseResponse(
    product: ProductRuntime,
    sessionId: SessionId
): Result<ApplicationResponse> {
    let state = match (product.goalState(sessionId)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    match (state) {
        case Some(goal) =>
            if (!goal.enabled) {
                return Result.Ok(localResponse(
                    "No active goal to pause."
                ))
            }
            match (product.pauseGoal(sessionId)) {
                case Result.Ok(_) =>
                    Result.Ok(localResponse("Goal mode paused."))
                case Result.Err(error) => Result.Err(error)
            }
        case None =>
            Result.Ok(localResponse("No active goal to pause."))
    }
}

func goalToolSlashResponse(
    product: ProductRuntime,
    sessionId: SessionId,
    op: String
): Result<ApplicationResponse> {
    match (product.invokeLocalTool(
        sessionId,
        "goal",
        objectValue([
            ValueField("op", textValue(op))
        ])
    )) {
        case Result.Ok(result) =>
            let content = match (result.output.field("content")) {
                case Some(value) => value.text
                case None => ""
            }
            Result.Ok(localResponse(
                if (op == "resume") {
                    "Goal mode resumed.\n" + content
                } else if (op == "drop") {
                    "Goal dropped.\n" + content
                } else {
                    content
                }
            ))
        case Result.Err(error) => Result.Err(error)
    }
}

func goalBudgetResponse(
    product: ProductRuntime,
    sessionId: SessionId,
    raw: String
): Result<ApplicationResponse> {
    let value = raw.trimAscii()
    if (value == "") {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "application.goal_budget_required",
            "Goal budget must be a positive integer or `off`.",
            fields: [ErrorField(
                "usage",
                "/goal budget <N|off>"
            )]
        ))
    }
    let budget: ?Int64 = if (value == "off") {
        None
    } else {
        try {
            let parsed = Int64.parse(value)
            if (parsed <= 0 || parsed.toString() != value) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "application.goal_budget_invalid",
                    "Goal budget must be a positive integer or `off`."
                ))
            }
            Some(parsed)
        } catch (_: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "application.goal_budget_invalid",
                "Goal budget must be a positive integer or `off`."
            ))
        }
    }
    match (product.setGoalBudget(sessionId, budget)) {
        case Result.Ok(goal) =>
            Result.Ok(localResponse(
                match (budget) {
                    case Some(amount) =>
                        "Goal budget set to " + amount.toString() + ".\n" +
                            goalDetails(goal)
                    case None =>
                        "Goal budget cleared.\n" + goalDetails(goal)
                }
            ))
        case Result.Err(error) => Result.Err(error)
    }
}

func goalDetails(goal: ProductGoalState): String {
    var tokens = goal.tokensUsed.toString()
    match (goal.tokenBudget) {
        case Some(value) =>
            tokens += " / " + value.toString() + " (" +
                max(0, value - goal.tokensUsed).toString() + " left)"
        case None => tokens += " (no budget)"
    }
    "Objective: " + goal.objective +
        "\nStatus: " + goal.status +
        (if (goal.enabled) { "" } else { " (paused)" }) +
        "\nTokens: " + tokens +
        "\nTime spent: " + goal.timeUsedSeconds.toString() + "s"
}

func goalSlashUsage(): Result<ApplicationResponse> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "application.goal_invalid_usage",
        "Invalid goal command.",
        fields: [ErrorField(
            "usage",
            "/goal [<objective>|set <objective>|show|pause|resume|" +
                "drop|budget <N|off>]"
        )]
    ))
}
