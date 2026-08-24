package agent_product

import agent_domain.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*

public class ProductGoalState {
    public let id: String
    public let objective: String
    public var status: String
    public let tokenBudget: ?Int64
    public var tokensUsed: Int64
    public var timeUsedSeconds: Int64
    public let createdAt: Int64
    public var updatedAt: Int64
    var enabled: Bool
    var baselineTokens: Int64
    var accountedAt: Int64

    public init(
        id: String,
        objective: String,
        status: String,
        tokenBudget: ?Int64,
        tokensUsed: Int64,
        timeUsedSeconds: Int64,
        createdAt: Int64,
        updatedAt: Int64,
        enabled: Bool,
        baselineTokens: Int64,
        accountedAt: Int64
    ) {
        this.id = id
        this.objective = objective
        this.status = status
        this.tokenBudget = tokenBudget
        this.tokensUsed = tokensUsed
        this.timeUsedSeconds = timeUsedSeconds
        this.createdAt = createdAt
        this.updatedAt = updatedAt
        this.enabled = enabled
        this.baselineTokens = baselineTokens
        this.accountedAt = accountedAt
    }
}

public class ProductGoalRuntime {
    private let repository: SessionMetadataRepository
    private let runs: SqliteRunRepository
    private let lock = Mutex()
    private var counter: Int64 = 0

    public init(
        repository: SessionMetadataRepository,
        runs: SqliteRunRepository
    ) {
        this.repository = repository
        this.runs = runs
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        lock.lock()
        try {
            let op = match (goalOperation(call)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            match (op) {
                case "create" => create(context.sessionId, call)
                case "get" => get(context.sessionId, call)
                case "complete" => complete(context.sessionId, call)
                case "resume" => resume(context.sessionId, call)
                case "drop" => drop(context.sessionId, call)
                case _ => goalError<ToolResult>(
                    "tool.goal_operation",
                    "unknown goal operation: " + op
                )
            }
        } finally {
            lock.unlock()
        }
    }

    public func activePrompt(sessionId: SessionId): Result<String> {
        lock.lock()
        try {
            let state = match (load(sessionId)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            match (state) {
                case Some(goal) =>
                    if (!goal.enabled || goal.status != "active") {
                        return Result.Ok("")
                    }
                    Result.Ok(
                        "<goal-mode>\n" +
                        "Objective: " + goal.objective + "\n" +
                        "Tokens used: " + goal.tokensUsed.toString() +
                        goalBudgetPrompt(goal) + "\n" +
                        "Continue working autonomously until the objective " +
                        "is genuinely achieved. Call goal with op=complete " +
                        "only after verifying completion; call op=drop only " +
                        "when the user abandons the objective.\n" +
                        "</goal-mode>"
                    )
                case None => Result.Ok("")
            }
        } finally {
            lock.unlock()
        }
    }

    public func finalizeRun(sessionId: SessionId): Result<Unit> {
        lock.lock()
        try {
            match (load(sessionId)) {
                case Result.Ok(Some(goal)) =>
                    if (!goal.enabled ||
                        (goal.status != "active" &&
                         goal.status != "budget-limited")) {
                        return Result.Ok(())
                    }
                    match (refresh(sessionId, goal)) {
                        case Result.Ok(_) => Result.Ok(())
                        case Result.Err(error) => Result.Err(error)
                    }
                case Result.Ok(None) => Result.Ok(())
                case Result.Err(error) => Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    public func pause(sessionId: SessionId): Result<Unit> {
        lock.lock()
        try {
            let state = match (load(sessionId)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            match (state) {
                case Some(goal) =>
                    match (refresh(sessionId, goal)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return Result.Err(error)
                    }
                    if (goal.status == "active" ||
                        goal.status == "budget-limited") {
                        goal.status = "paused"
                    }
                    goal.enabled = false
                    goal.updatedAt = goalNowMillis()
                    persist(sessionId, goal)
                case None => Result.Ok(())
            }
        } finally {
            lock.unlock()
        }
    }

    public func pauseRestoredActive(sessionId: SessionId): Result<Unit> {
        lock.lock()
        try {
            let state = match (load(sessionId)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            match (state) {
                case Some(goal) =>
                    if (!goal.enabled ||
                        (goal.status != "active" &&
                         goal.status != "budget-limited")) {
                        return Result.Ok(())
                    }
                    goal.enabled = false
                    goal.status = "paused"
                    goal.updatedAt = goalNowMillis()
                    goal.accountedAt = goal.updatedAt
                    persist(sessionId, goal)
                case None => Result.Ok(())
            }
        } finally {
            lock.unlock()
        }
    }

    public func state(
        sessionId: SessionId
    ): Result<?ProductGoalState> {
        lock.lock()
        try {
            let value = match (load(sessionId)) {
                case Result.Ok(goal) => goal
                case Result.Err(error) => return Result.Err(error)
            }
            match (value) {
                case Some(goal) =>
                    match (refresh(sessionId, goal)) {
                        case Result.Ok(_) => Result.Ok(Some(goal))
                        case Result.Err(error) => Result.Err(error)
                    }
                case None => Result.Ok(None)
            }
        } finally {
            lock.unlock()
        }
    }

    public func createGoal(
        sessionId: SessionId,
        objective: String,
        tokenBudget!: ?Int64 = None
    ): Result<ProductGoalState> {
        lock.lock()
        try {
            createState(
                sessionId,
                objective.trimAscii(),
                tokenBudget,
                false
            )
        } finally {
            lock.unlock()
        }
    }

    public func replaceGoal(
        sessionId: SessionId,
        objective: String,
        tokenBudget!: ?Int64 = None
    ): Result<ProductGoalState> {
        lock.lock()
        try {
            createState(
                sessionId,
                objective.trimAscii(),
                tokenBudget,
                true
            )
        } finally {
            lock.unlock()
        }
    }

    public func setBudget(
        sessionId: SessionId,
        tokenBudget: ?Int64
    ): Result<ProductGoalState> {
        lock.lock()
        try {
            match (tokenBudget) {
                case Some(value) =>
                    if (value <= 0) {
                        return goalError<ProductGoalState>(
                            "tool.goal_budget_value",
                            "Goal budget must be a positive integer or `off`."
                        )
                    }
                case None => ()
            }
            let goal = match (loadRequired(
                sessionId,
                "No active goal."
            )) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            if (!goal.enabled) {
                return goalError<ProductGoalState>(
                    "tool.goal_not_active",
                    "Resume the goal before adjusting the budget."
                )
            }
            match (refresh(sessionId, goal)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let updated = ProductGoalState(
                goal.id,
                goal.objective,
                goal.status,
                tokenBudget,
                goal.tokensUsed,
                goal.timeUsedSeconds,
                goal.createdAt,
                goalNowMillis(),
                goal.enabled,
                goal.baselineTokens,
                goal.accountedAt
            )
            match (tokenBudget) {
                case Some(value) =>
                    if (updated.tokensUsed >= value) {
                        updated.status = "budget-limited"
                    } else if (updated.status == "budget-limited") {
                        updated.status = "active"
                    }
                case None =>
                    if (updated.status == "budget-limited") {
                        updated.status = "active"
                    }
            }
            match (persist(sessionId, updated)) {
                case Result.Ok(_) => Result.Ok(updated)
                case Result.Err(error) => Result.Err(error)
            }
        } finally {
            lock.unlock()
        }
    }

    private func create(
        sessionId: SessionId,
        call: ToolCall
    ): Result<ToolResult> {
        let objective = match (goalRequiredText(
            call,
            "objective",
            "objective is required when op=create"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let tokenBudget = match (goalOptionalPositiveInteger(
            call,
            "token_budget"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (createState(
            sessionId,
            objective,
            tokenBudget,
            false
        )) {
            case Result.Ok(goal) =>
                Result.Ok(goalToolResult(call, "create", Some(goal)))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func createState(
        sessionId: SessionId,
        objective: String,
        tokenBudget: ?Int64,
        replace: Bool
    ): Result<ProductGoalState> {
        if (objective == "") {
            return goalError<ProductGoalState>(
                "tool.goal_argument_required",
                "objective is required when creating a goal"
            )
        }
        match (tokenBudget) {
            case Some(value) =>
                if (value <= 0) {
                    return goalError<ProductGoalState>(
                        "tool.goal_argument_value",
                        "token_budget must be a positive integer when provided"
                    )
                }
            case None => ()
        }
        let existing = match (load(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (existing) {
            case Some(goal) =>
                if (replace) {
                    if (!goal.enabled ||
                        (goal.status != "active" &&
                         goal.status != "budget-limited")) {
                        return goalError<ProductGoalState>(
                            "tool.goal_not_active",
                            "cannot replace goal because no goal is active"
                        )
                    }
                    match (refresh(sessionId, goal)) {
                        case Result.Ok(_) => ()
                        case Result.Err(error) => return Result.Err(error)
                    }
                } else if (goal.status != "dropped" &&
                    goal.status != "complete") {
                    return goalError<ProductGoalState>(
                        "tool.goal_already_exists",
                        "cannot create a new goal because this session " +
                            "already has a goal"
                    )
                }
            case None =>
                if (replace) {
                    return goalError<ProductGoalState>(
                        "tool.goal_not_active",
                        "cannot replace goal because no goal is active"
                    )
                }
        }
        let stats = match (runs.stats(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let now = goalNowMillis()
        counter += 1
        let goal = ProductGoalState(
            "goal-" + now.toString() + "-" + counter.toString(),
            objective,
            "active",
            tokenBudget,
            0,
            0,
            now,
            now,
            true,
            stats.inputTokens + stats.outputTokens,
            now
        )
        match (persist(sessionId, goal)) {
            case Result.Ok(_) => Result.Ok(goal)
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func get(
        sessionId: SessionId,
        call: ToolCall
    ): Result<ToolResult> {
        let state = match (load(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (state) {
            case Some(goal) =>
                match (refresh(sessionId, goal)) {
                    case Result.Ok(_) =>
                        Result.Ok(goalToolResult(
                            call,
                            "get",
                            Some(goal)
                        ))
                    case Result.Err(error) => Result.Err(error)
                }
            case None =>
                Result.Ok(goalToolResult(call, "get", None))
        }
    }

    private func complete(
        sessionId: SessionId,
        call: ToolCall
    ): Result<ToolResult> {
        let goal = match (loadRequired(
            sessionId,
            "cannot complete goal because no goal is active"
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (goal.status == "complete") {
            return goalError<ToolResult>(
                "tool.goal_already_complete",
                "goal is already complete"
            )
        }
        if (goal.status == "dropped") {
            return goalError<ToolResult>(
                "tool.goal_dropped",
                "cannot complete a dropped goal"
            )
        }
        match (refresh(sessionId, goal)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        goal.enabled = false
        goal.status = "complete"
        goal.updatedAt = goalNowMillis()
        match (persist(sessionId, goal)) {
            case Result.Ok(_) =>
                Result.Ok(goalToolResult(
                    call,
                    "complete",
                    Some(goal),
                    completionReport: goalCompletionReport(goal)
                ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func resume(
        sessionId: SessionId,
        call: ToolCall
    ): Result<ToolResult> {
        let goal = match (loadRequired(sessionId, "No paused goal.")) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (goal.status == "complete") {
            return goalError<ToolResult>(
                "tool.goal_already_complete",
                "Goal is already complete."
            )
        }
        let stats = match (runs.stats(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let now = goalNowMillis()
        goal.enabled = true
        goal.status = "active"
        goal.updatedAt = now
        goal.accountedAt = now
        goal.baselineTokens = stats.inputTokens + stats.outputTokens
        match (persist(sessionId, goal)) {
            case Result.Ok(_) =>
                Result.Ok(goalToolResult(call, "resume", Some(goal)))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func drop(
        sessionId: SessionId,
        call: ToolCall
    ): Result<ToolResult> {
        let state = match (load(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (state) {
            case Some(goal) =>
                match (refresh(sessionId, goal)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                goal.enabled = false
                goal.status = "dropped"
                goal.updatedAt = goalNowMillis()
                match (repository.clearGoalState(sessionId)) {
                    case Result.Ok(_) =>
                        Result.Ok(goalToolResult(
                            call,
                            "drop",
                            Some(goal)
                        ))
                    case Result.Err(error) => Result.Err(error)
                }
            case None =>
                Result.Ok(goalToolResult(call, "drop", None))
        }
    }

    private func refresh(
        sessionId: SessionId,
        goal: ProductGoalState
    ): Result<Unit> {
        if (!goal.enabled ||
            (goal.status != "active" &&
             goal.status != "budget-limited")) {
            return Result.Ok(())
        }
        let stats = match (runs.stats(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let total = stats.inputTokens + stats.outputTokens
        if (total > goal.baselineTokens) {
            goal.tokensUsed += total - goal.baselineTokens
        }
        goal.baselineTokens = total
        let now = goalNowMillis()
        if (now > goal.accountedAt) {
            let seconds = (now - goal.accountedAt) / 1000
            if (seconds > 0) {
                goal.timeUsedSeconds += seconds
                goal.accountedAt += seconds * 1000
            }
        }
        match (goal.tokenBudget) {
            case Some(value) =>
                if (goal.tokensUsed >= value &&
                    goal.status == "active") {
                    goal.status = "budget-limited"
                }
            case None => ()
        }
        goal.updatedAt = now
        persist(sessionId, goal)
    }

    private func loadRequired(
        sessionId: SessionId,
        message: String
    ): Result<ProductGoalState> {
        match (load(sessionId)) {
            case Result.Ok(Some(goal)) => Result.Ok(goal)
            case Result.Ok(None) =>
                goalError<ProductGoalState>(
                    "tool.goal_not_found",
                    message
                )
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func load(
        sessionId: SessionId
    ): Result<?ProductGoalState> {
        match (repository.goalState(sessionId)) {
            case Result.Ok(value) =>
                if (value.kind == ValueKind.Null) {
                    Result.Ok(None)
                } else {
                    match (decodeGoalState(value)) {
                        case Result.Ok(goal) => Result.Ok(Some(goal))
                        case Result.Err(error) => Result.Err(error)
                    }
                }
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func persist(
        sessionId: SessionId,
        goal: ProductGoalState
    ): Result<Unit> {
        repository.setGoalState(sessionId, encodeGoalState(goal))
    }
}

class GoalTool <: ToolExecutor {
    private let runtime: ProductGoalRuntime

    init(runtime: ProductGoalRuntime) {
        this.runtime = runtime
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        runtime.execute(context, call)
    }
}

func goalToolDefinition(): ModelToolDefinition {
    ModelToolDefinition(
        "goal",
        "Create, inspect, complete, resume, or drop a durable goal.",
        objectSchema([
            schemaEnumProperty(
                "op",
                ["create", "get", "complete", "resume", "drop"]
            ),
            schemaProperty("objective", "string"),
            schemaProperty("token_budget", "integer")
        ], ["op"])
    )
}

func encodeGoalState(goal: ProductGoalState): AgentValue {
    objectValue([
        ValueField("id", textValue(goal.id)),
        ValueField("objective", textValue(goal.objective)),
        ValueField("status", textValue(goal.status)),
        ValueField(
            "tokenBudget",
            match (goal.tokenBudget) {
                case Some(value) => integerValue(value)
                case None => nullValue()
            }
        ),
        ValueField("tokensUsed", integerValue(goal.tokensUsed)),
        ValueField(
            "timeUsedSeconds",
            integerValue(goal.timeUsedSeconds)
        ),
        ValueField("createdAt", integerValue(goal.createdAt)),
        ValueField("updatedAt", integerValue(goal.updatedAt)),
        ValueField("enabled", boolValue(goal.enabled)),
        ValueField(
            "baselineTokens",
            integerValue(goal.baselineTokens)
        ),
        ValueField("accountedAt", integerValue(goal.accountedAt))
    ])
}

func decodeGoalState(value: AgentValue): Result<ProductGoalState> {
    if (value.kind != ValueKind.Object) {
        return goalError<ProductGoalState>(
            "tool.goal_state_invalid",
            "persisted goal state is not an object"
        )
    }
    let id = goalStateText(value, "id")
    let objective = goalStateText(value, "objective")
    let status = goalStateText(value, "status")
    if (id == "" || objective == "" || !goalStatusValid(status)) {
        return goalError<ProductGoalState>(
            "tool.goal_state_invalid",
            "persisted goal state is incomplete"
        )
    }
    Result.Ok(ProductGoalState(
        id,
        objective,
        status,
        goalStateOptionalInteger(value, "tokenBudget"),
        goalStateInteger(value, "tokensUsed"),
        goalStateInteger(value, "timeUsedSeconds"),
        goalStateInteger(value, "createdAt"),
        goalStateInteger(value, "updatedAt"),
        goalStateBoolean(value, "enabled"),
        goalStateInteger(value, "baselineTokens"),
        goalStateInteger(value, "accountedAt")
    ))
}

func goalToolResult(
    call: ToolCall,
    op: String,
    goal: ?ProductGoalState,
    completionReport!: String = ""
): ToolResult {
    let text = match (goal) {
        case Some(value) =>
            var result = "Goal: " + value.objective +
                "\nStatus: " + value.status +
                "\nTokens: " + value.tokensUsed.toString() + " used"
            match (value.tokenBudget) {
                case Some(budget) =>
                    result += " / " + budget.toString() + " budget"
                case None => ()
            }
            match (goalRemainingTokens(value)) {
                case Some(remaining) =>
                    result += "\nRemaining tokens: " +
                        remaining.toString()
                case None => ()
            }
            if (completionReport != "") {
                result += "\n\n" + completionReport
            }
            result
        case None => "No active goal."
    }
    ToolResult(
        call.callId,
        objectValue([
            ValueField("content", textValue(text)),
            ValueField("op", textValue(op)),
            ValueField(
                "goal",
                match (goal) {
                    case Some(value) => goalPublicValue(value)
                    case None => nullValue()
                }
            ),
            ValueField(
                "remainingTokens",
                match (goal) {
                    case Some(value) =>
                        match (goalRemainingTokens(value)) {
                            case Some(remaining) =>
                                integerValue(remaining)
                            case None => nullValue()
                        }
                    case None => nullValue()
                }
            ),
            ValueField(
                "completionBudgetReport",
                if (completionReport == "") {
                    nullValue()
                } else {
                    textValue(completionReport)
                }
            )
        ])
    )
}

func goalPublicValue(goal: ProductGoalState): AgentValue {
    objectValue([
        ValueField("id", textValue(goal.id)),
        ValueField("objective", textValue(goal.objective)),
        ValueField("status", textValue(goal.status)),
        ValueField(
            "tokenBudget",
            match (goal.tokenBudget) {
                case Some(value) => integerValue(value)
                case None => nullValue()
            }
        ),
        ValueField("tokensUsed", integerValue(goal.tokensUsed)),
        ValueField(
            "timeUsedSeconds",
            integerValue(goal.timeUsedSeconds)
        ),
        ValueField("createdAt", integerValue(goal.createdAt)),
        ValueField("updatedAt", integerValue(goal.updatedAt))
    ])
}

func goalOperation(call: ToolCall): Result<String> {
    for (field in call.arguments.fields) {
        if (field.name != "op" &&
            field.name != "objective" &&
            field.name != "token_budget") {
            return goalError<String>(
                "tool.goal_unknown_argument",
                "unknown goal argument: " + field.name
            )
        }
    }
    let op = match (call.arguments.field("op")) {
        case Some(value) =>
            if (value.kind == ValueKind.Text) {
                value.text.trimAscii()
            } else {
                return goalError<String>(
                    "tool.goal_operation_type",
                    "goal op must be a string"
                )
            }
        case None => ""
    }
    if (op == "") {
        goalError<String>(
            "tool.goal_operation_required",
            "goal op is required"
        )
    } else {
        Result.Ok(op)
    }
}

func goalRequiredText(
    call: ToolCall,
    name: String,
    missingMessage: String
): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.kind != ValueKind.Text) {
                return goalError<String>(
                    "tool.goal_argument_type",
                    name + " must be a string"
                )
            }
            let text = value.text.trimAscii()
            if (text == "") {
                goalError<String>(
                    "tool.goal_argument_required",
                    missingMessage
                )
            } else {
                Result.Ok(text)
            }
        case None =>
            goalError<String>(
                "tool.goal_argument_required",
                missingMessage
            )
    }
}

func goalOptionalPositiveInteger(
    call: ToolCall,
    name: String
): Result<?Int64> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.kind != ValueKind.Number) {
                return goalError<?Int64>(
                    "tool.goal_argument_type",
                    name + " must be a positive integer when provided"
                )
            }
            try {
                let parsed = Int64.parse(value.number)
                if (parsed <= 0 || parsed.toString() != value.number) {
                    return goalError<?Int64>(
                        "tool.goal_argument_value",
                        name + " must be a positive integer when provided"
                    )
                }
                Result.Ok(Some(parsed))
            } catch (_: Exception) {
                goalError<?Int64>(
                    "tool.goal_argument_value",
                    name + " must be a positive integer when provided"
                )
            }
        case None => Result.Ok(None)
    }
}

func goalRemainingTokens(goal: ProductGoalState): ?Int64 {
    match (goal.tokenBudget) {
        case Some(value) => Some(max(0, value - goal.tokensUsed))
        case None => None
    }
}

func goalCompletionReport(goal: ProductGoalState): String {
    let values = ArrayList<String>()
    match (goal.tokenBudget) {
        case Some(value) =>
            values.add(
                "tokens used: " + goal.tokensUsed.toString() +
                    " of " + value.toString()
            )
        case None => ()
    }
    if (goal.timeUsedSeconds > 0) {
        values.add(
            "time used: " + goal.timeUsedSeconds.toString() +
                " seconds"
        )
    }
    if (values.isEmpty()) { return "" }
    var result = "Goal achieved. Report final budget usage to the user: "
    for (index in 0..values.size) {
        if (index > 0) { result += "; " }
        result += values[index]
    }
    result + "."
}

func goalBudgetPrompt(goal: ProductGoalState): String {
    match (goal.tokenBudget) {
        case Some(value) =>
            "\nToken budget: " + value.toString() +
                "\nRemaining tokens: " +
                max(0, value - goal.tokensUsed).toString()
        case None => "\nToken budget: unbounded"
    }
}

func goalStateText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func goalStateInteger(value: AgentValue, name: String): Int64 {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == ValueKind.Number) {
                try { Int64.parse(field.number) } catch (_: Exception) { 0 }
            } else {
                0
            }
        case None => 0
    }
}

func goalStateOptionalInteger(
    value: AgentValue,
    name: String
): ?Int64 {
    match (value.field(name)) {
        case Some(field) =>
            if (field.kind == ValueKind.Number) {
                try {
                    Some(Int64.parse(field.number))
                } catch (_: Exception) {
                    None
                }
            } else {
                None
            }
        case None => None
    }
}

func goalStateBoolean(value: AgentValue, name: String): Bool {
    match (value.field(name)) {
        case Some(field) =>
            field.kind == ValueKind.Boolean && field.boolean
        case None => false
    }
}

func goalStatusValid(value: String): Bool {
    value == "active" || value == "paused" ||
        value == "budget-limited" || value == "complete" ||
        value == "dropped"
}

func goalNowMillis(): Int64 {
    DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()
}

func goalError<T>(
    code: String,
    message: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        code,
        message
    ))
}
