package compaction_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Pure summary policy copied from the previous product implementation. The
// projection is data, never a Model call, Run, permission or checkpoint.
let MODEL_COMPACTION_OVERVIEW_MARKER = "\nmodel-generated overview (non-authoritative):\n"

class StructuredGoal {
    let objective: String
    let status: String
    init(objective: String, status: String) { this.objective = objective; this.status = status }
}
enum StructuredTodoStatus { Pending | InProgress | Completed | Abandoned | Blocked }
class StructuredTodoTask {
    let content: String
    let status: StructuredTodoStatus
    let blocker: String
    init(content: String, status: StructuredTodoStatus, blocker: String) {
        this.content = content; this.status = status; this.blocker = blocker
    }
}
class StructuredTodoPhase {
    let name: String
    let tasks: Array<StructuredTodoTask>
    init(name: String, tasks: Array<StructuredTodoTask>) { this.name = name; this.tasks = tasks }
}

func structuredPolicy(value: AgentValue): AgentValue {
    policyFields(value, ["schema", "phase", "snapshot_digest", "projection", "goal", "todos"])
    let projection = match (modelRequestFromSnapshotValue(value.field("projection").getOrThrow(), "")) {
        case Result.Ok(value) => value
        case Result.Err(_) => throw PureProviderError("compaction.projection_invalid", "invalid neutral history projection")
    }
    let workflow = structuredWorkflow(value)
    objectValue([ValueField("snapshot_digest", textValue(policyText(value, "snapshot_digest"))),
        ValueField("summary", textValue(structuredSummary(projection.messages, goal: workflow.goal, todos: workflow.todos)))])
}

func authoritativeCompactionSummary(value: String): String {
    match (value.indexOf(MODEL_COMPACTION_OVERVIEW_MARKER)) {
        case Some(index) => value[..index]
        case None => value
    }
}

class StructuredSummaryAccumulator {
    var messageCount: Int64 = 0
    var users: Int64 = 0
    var assistants: Int64 = 0
    let excerpts = ArrayList<String>()
    let priorSummaries = ArrayList<String>()
    let tools = ArrayList<String>()
    let readFiles = ArrayList<String>()
    let modifiedFiles = ArrayList<String>()
    let createdFiles = ArrayList<String>()
    let commands = ArrayList<String>()
    let results = ArrayList<String>()
    let diagnostics = ArrayList<String>()
    func add(message: ModelMessage): Unit {
        messageCount += 1
        if (message.role == ModelRole.User) {
            users += 1
        } else {
            assistants += 1
        }
        for (block in message.blocks) {
            if (block.kind == ModelBlockKind.Text || block.kind == ModelBlockKind.Reasoning) {
                if (block.text.startsWith("[Compacted session history]")) {
                    addUniqueLimited(
                        priorSummaries,
                        compactText(authoritativeCompactionSummary(block.text), 1600),
                        2
                    )
                } else if (excerpts.size < 6) {
                    let excerpt = compactText(block.text, 240)
                    if (excerpt != "") {
                        excerpts.add(if (message.role == ModelRole.User) { "user: " } else { "assistant: " } + excerpt)
                    }
                }
            }
            if (block.kind == ModelBlockKind.ToolCall) {
                addUniqueLimited(tools, block.name, 24)
                let path = argumentText(block.arguments, "path")
                if (path != "") {
                    if (block.name == "write" || block.name == "edit") {
                        addUniqueLimited(modifiedFiles, path, 24)
                    } else {
                        addUniqueLimited(readFiles, path, 24)
                    }
                }
                if (block.name == "edit") {
                    collectHashlinePaths(
                        argumentText(block.arguments, "input"),
                        modifiedFiles
                    )
                }
                let command = argumentText(block.arguments, "command")
                if (command != "") {
                    addUniqueLimited(commands, compactText(command, 240), 8)
                }
            }
            if (block.kind == ModelBlockKind.ToolResult) {
                let action = argumentText(block.arguments, "action")
                let path = argumentText(block.arguments, "path")
                if (path != "" && action == "create") {
                    addUniqueLimited(createdFiles, path, 24)
                } else if (path != "" && action == "overwrite") {
                    addUniqueLimited(modifiedFiles, path, 24)
                }
                let exitCode = argumentNumber(block.arguments, "exit_code")
                if (exitCode != "") {
                    addUniqueLimited(
                        results,
                        (if (block.name == "") { "command" } else { block.name }) + " exit " + exitCode,
                        10
                    )
                }
                let status = argumentText(block.arguments, "status")
                if (status != "") {
                    addUniqueLimited(results, block.name + ": " + compactText(status, 160), 10)
                }
                if (block.isError || (exitCode != "" && exitCode != "0")) {
                    let detail = firstNonEmpty([
                        argumentText(block.arguments, "stderr"),
                        argumentText(block.arguments, "error"),
                        block.text
                    ])
                    addUniqueLimited(
                        diagnostics,
                        (if (block.name == "") { "tool" } else { block.name }) + ": " +
                            if (detail == "") { "failed" } else { compactText(detail, 280) },
                        10
                    )
                }
            }
        }
    }
    func finish(goal: ?StructuredGoal, todos: Array<StructuredTodoPhase>): String {
    var summary = "[Compacted session history]\n" + "messages: " + messageCount.toString() + " (user " +
        users.toString() + ", assistant " + assistants.toString() + ")"
    match (goal) {
        case Some(value) =>
            summary += "\ngoal:\n- objective: " + compactText(value.objective, 500) + "\n- status: " + value.status
        case None => ()
    }
    let unresolved = unresolvedTodos(todos)
    if (!unresolved.isEmpty()) {
        summary += "\nunresolved:"
        for (item in unresolved) {
            summary += "\n- " + item
        }
    }
    if (!priorSummaries.isEmpty()) {
        summary += "\nprior structured context:"
        for (value in priorSummaries) {
            summary += "\n---\n" + value
        }
    }
    if (!excerpts.isEmpty()) {
        summary += "\nkey excerpts:"
        for (excerpt in excerpts) {
            summary += "\n- " + excerpt
        }
    }
    if (!tools.isEmpty()) {
        summary += "\ntools: " + joinCompact(tools.toArray())
    }
    let files = mergedFileSummary(readFiles, modifiedFiles, createdFiles)
    if (files != "") {
        summary += "\nfiles:\n" + files
    }
    if (!commands.isEmpty()) {
        summary += "\nimportant commands:"
        for (command in commands) {
            summary += "\n- " + command
        }
    }
    if (!results.isEmpty()) {
        summary += "\ntool results:"
        for (result in results) {
            summary += "\n- " + result
        }
    }
    if (!diagnostics.isEmpty()) {
        summary += "\ndiagnostics:"
        for (diagnostic in diagnostics) {
            summary += "\n- " + diagnostic
        }
    }
    summary
    }
}

func structuredSummary(messages: Array<ModelMessage>, goal!: ?StructuredGoal = None,
    todos!: Array<StructuredTodoPhase> = []): String {
    let state = StructuredSummaryAccumulator()
    for (message in messages) { state.add(message) }
    state.finish(goal, todos)
}

func compactText(value: String, limit: Int64): String {
    let text = value.replace("\r", "").replace("\n", " ").trimAscii()
    if (text.size <= limit) {
        text
    } else {
        text[..limit] + "..."
    }
}

func argumentText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func argumentNumber(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.unifiedKind == ValueKind.Number) { item.asNumberText() } else { "" }
        case None => ""
    }
}

func firstNonEmpty(values: Array<String>): String {
    for (value in values where value.trimAscii() != "") {
        return value
    }
    ""
}

func unresolvedTodos(phases: Array<StructuredTodoPhase>): Array<String> {
    let values = ArrayList<String>()
    for (phase in phases) {
        for (task in phase.tasks) {
            match (task.status) {
                case StructuredTodoStatus.Pending | StructuredTodoStatus.InProgress =>
                    addUniqueLimited(values, phase.name + ": " + compactText(task.content, 240), 16)
                case StructuredTodoStatus.Blocked =>
                    addUniqueLimited(
                        values,
                        phase.name + ": " + compactText(task.content, 200) + if (task.blocker == "") {
                            " [blocked]"
                        } else {
                            " [blocked: " + compactText(task.blocker, 160) + "]"
                        },
                        16
                    )
                case _ => ()
            }
        }
    }
    values.toArray()
}

func collectHashlinePaths(
    input: String,
    output: ArrayList<String>
): Unit {
    for (line in input.split("\n")) {
        if (line.startsWith("[") && line.endsWith("]")) {
            let separator = line.indexOf("#")
            match (separator) {
                case Some(index) =>
                    if (index > 1) {
                        addUniqueLimited(output, line[1..index], 24)
                    }
                case None => ()
            }
        }
    }
}

func mergedFileSummary(
    reads: ArrayList<String>,
    modifications: ArrayList<String>,
    creations: ArrayList<String>
): String {
    var result = ""
    for (path in reads) {
        let mode = if (containsValue(creations, path)) {
            "Created"
        } else if (containsValue(modifications, path)) {
            "RW"
        } else {
            "Read"
        }
        result += if (result == "") {
            ""
        } else {
            "\n"
        }
        result += "- " + path + " (" + mode + ")"
    }
    for (path in modifications where !containsValue(reads, path) && !containsValue(creations, path)) {
        result += if (result == "") {
            ""
        } else {
            "\n"
        }
        result += "- " + path + " (Write)"
    }
    for (path in creations where !containsValue(reads, path)) {
        result += if (result == "") { "" } else { "\n" }
        result += "- " + path + " (Created)"
    }
    result
}

func addUnique(values: ArrayList<String>, value: String): Unit {
    if (value != "" && !containsValue(values, value)) {
        values.add(value)
    }
}

func addUniqueLimited(
    values: ArrayList<String>,
    value: String,
    limit: Int64
): Unit {
    if (values.size < limit) {
        addUnique(values, value)
    }
}

func containsValue(values: ArrayList<String>, value: String): Bool {
    for (candidate in values where candidate == value) {
        return true
    }
    false
}

func joinCompact(values: Array<String>): String {
    var result = ""
    for (value in values) {
        if (result != "") {
            result += ", "
        }
        result += value
    }
    result
}


class StructuredWorkflow {
    let goal: ?StructuredGoal
    let todos: Array<StructuredTodoPhase>
    init(goal: ?StructuredGoal, todos: Array<StructuredTodoPhase>) { this.goal = goal; this.todos = todos }
}
func structuredWorkflow(value: AgentValue): StructuredWorkflow {
    let rawGoal = value.field("goal").getOrThrow()
    let goal: ?StructuredGoal = if (rawGoal.unifiedKind == ValueKind.Null) { None } else {
        policyFields(rawGoal, ["objective", "status"])
        Some(StructuredGoal(policyText(rawGoal, "objective"), policyText(rawGoal, "status")))
    }
    let rawTodos = value.field("todos").getOrThrow()
    if (rawTodos.unifiedKind != ValueKind.List) { throw PureProviderError("compaction.todos_invalid", "invalid workflow projection") }
    let todos = ArrayList<StructuredTodoPhase>()
    for (rawPhase in rawTodos.items) {
        policyFields(rawPhase, ["name", "tasks"])
        let rawTasks = rawPhase.field("tasks").getOrThrow()
        if (rawTasks.unifiedKind != ValueKind.List) { throw PureProviderError("compaction.todos_invalid", "invalid workflow tasks") }
        let tasks = ArrayList<StructuredTodoTask>()
        for (rawTask in rawTasks.items) {
            policyFields(rawTask, if (rawTask.field("blocker").isSome()) { ["content", "status", "blocker"] } else { ["content", "status"] })
            let status = match (policyText(rawTask, "status")) {
                case "pending" => StructuredTodoStatus.Pending
                case "in_progress" => StructuredTodoStatus.InProgress
                case "completed" => StructuredTodoStatus.Completed
                case "abandoned" => StructuredTodoStatus.Abandoned
                case "blocked" => StructuredTodoStatus.Blocked
                case _ => throw PureProviderError("compaction.todos_invalid", "invalid workflow status")
            }
            tasks.add(StructuredTodoTask(policyText(rawTask, "content"), status,
                if (rawTask.field("blocker").isSome()) { policyText(rawTask, "blocker") } else { "" }))
        }
        todos.add(StructuredTodoPhase(policyText(rawPhase, "name"), tasks.toArray()))
    }
    StructuredWorkflow(goal, todos.toArray())
}
