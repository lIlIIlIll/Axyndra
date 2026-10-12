package workflow_plugin

import std.deriving.*

@Derive[Equatable]
enum TodoStatus {
    Pending | InProgress | Completed | Abandoned | Blocked
}

class TodoItem {
    let content: String
    let status: TodoStatus
    let blocker: String

    init(
        content: String,
        status!: TodoStatus = TodoStatus.Pending,
        blocker!: String = ""
    ) {
        if (content.trimAscii() == "") {
            throw IllegalArgumentException("todo item content must not be empty")
        }
        this.content = content
        this.status = status
        this.blocker = blocker
    }
}

class TodoPhase {
    let name: String
    let tasks: Array<TodoItem>

    init(name: String, tasks: Array<TodoItem>) {
        if (name.trimAscii() == "") {
            throw IllegalArgumentException("todo phase name must not be empty")
        }
        this.name = name
        this.tasks = tasks
    }
}

