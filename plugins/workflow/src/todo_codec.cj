package workflow_plugin

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func encodeTodoPhases(phases: Array<TodoPhase>): AgentValue {
    let encoded = ArrayList<AgentValue>()
    for (phase in phases) {
        let tasks = ArrayList<AgentValue>()
        for (task in phase.tasks) {
            let fields = ArrayList<ValueField>()
            fields.add(ValueField("content", textValue(task.content)))
            fields.add(
                ValueField(
                    "status",
                    textValue(todoStatusName(task.status))
                )
            )
            if (task.blocker != "") {
                fields.add(ValueField("blocker", textValue(task.blocker)))
            }
            tasks.add(objectValue(fields.toArray()))
        }
        encoded.add(
            objectValue(
                [
                    ValueField("name", textValue(phase.name)),
                    ValueField("tasks", listValue(tasks.toArray()))
                ]
            )
        )
    }
    listValue(encoded.toArray())
}

func decodeTodoPhases(value: AgentValue): Result<Array<TodoPhase>> {
    if (value.unifiedKind != ValueKind.List) {
        return invalidTodoData("todo phases must be a list")
    }
    let phases = ArrayList<TodoPhase>()
    for (phaseValue in value.items) {
        if (phaseValue.unifiedKind != ValueKind.Object) {
            return invalidTodoData("todo phase must be an object")
        }
        let name = match (phaseValue.field("name")) {
            case Some(field) =>
                if (field.unifiedKind != ValueKind.Text || field.text.trimAscii() == "") {
                    return invalidTodoData("todo phase name must be a non-empty string")
                }
                field.text
            case None => return invalidTodoData("todo phase name is required")
        }
        let taskValues = match (phaseValue.field("tasks")) {
            case Some(field) =>
                if (field.unifiedKind != ValueKind.List) {
                    return invalidTodoData("todo phase tasks must be a list")
                }
                field.items
            case None => return invalidTodoData("todo phase tasks are required")
        }
        let tasks = ArrayList<TodoItem>()
        for (taskValue in taskValues) {
            if (taskValue.unifiedKind != ValueKind.Object) {
                return invalidTodoData("todo task must be an object")
            }
            let content = match (taskValue.field("content")) {
                case Some(field) =>
                    if (field.unifiedKind != ValueKind.Text || field.text.trimAscii() == "") {
                        return invalidTodoData("todo task content must be a non-empty string")
                    }
                    field.text
                case None => return invalidTodoData("todo task content is required")
            }
            let status = match (taskValue.field("status")) {
                case Some(field) =>
                    if (field.unifiedKind != ValueKind.Text) {
                        return invalidTodoData("todo task status must be a string")
                    }
                    match (todoStatusValue(field.text)) {
                        case Some(status) => status
                        case None => return invalidTodoData("todo task status is invalid")
                    }
                case None => return invalidTodoData("todo task status is required")
            }
            let blocker = match (taskValue.field("blocker")) {
                case Some(field) =>
                    if (field.unifiedKind != ValueKind.Text) {
                        return invalidTodoData("todo task blocker must be a string")
                    }
                    field.text
                case None => ""
            }
            tasks.add(TodoItem(content, status: status, blocker: blocker))
        }
        phases.add(TodoPhase(name, tasks.toArray()))
    }
    Result.Ok(phases.toArray())
}

func todoStatusName(status: TodoStatus): String {
    match (status) {
        case TodoStatus.Pending => "pending"
        case TodoStatus.InProgress => "in_progress"
        case TodoStatus.Completed => "completed"
        case TodoStatus.Abandoned => "abandoned"
        case TodoStatus.Blocked => "blocked"
    }
}

func todoStatusValue(value: String): ?TodoStatus {
    match (value) {
        case "pending" => Some(TodoStatus.Pending)
        case "in_progress" => Some(TodoStatus.InProgress)
        case "completed" => Some(TodoStatus.Completed)
        case "abandoned" => Some(TodoStatus.Abandoned)
        case "blocked" => Some(TodoStatus.Blocked)
        case _ => None
    }
}

func invalidTodoData<T>(message: String): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "todo.invalid_phases",
            message
        )
    )
}

