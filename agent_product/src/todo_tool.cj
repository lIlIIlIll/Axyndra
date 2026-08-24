package agent_product

import agent_domain.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.sync.*

class TodoInitEntry {
    let phase: String
    let items: Array<String>

    init(phase: String, items: Array<String>) {
        this.phase = phase
        this.items = items
    }
}

class TodoParams {
    let op: String
    let list: Array<TodoInitEntry>
    let hasList: Bool
    let task: String
    let phase: String
    let items: Array<String>
    let hasItems: Bool
    let reason: String

    init(
        op: String,
        list: Array<TodoInitEntry>,
        hasList: Bool,
        task: String,
        phase: String,
        items: Array<String>,
        hasItems: Bool,
        reason: String
    ) {
        this.op = op
        this.list = list
        this.hasList = hasList
        this.task = task
        this.phase = phase
        this.items = items
        this.hasItems = hasItems
        this.reason = reason
    }
}

class MutableTodoItem {
    let content: String
    var status: TodoStatus
    var blocker: String

    init(content: String, status: TodoStatus, blocker: String) {
        this.content = content
        this.status = status
        this.blocker = blocker
    }
}

class MutableTodoPhase {
    let name: String
    let tasks: ArrayList<MutableTodoItem>

    init(name: String, tasks: ArrayList<MutableTodoItem>) {
        this.name = name
        this.tasks = tasks
    }
}

class TodoCompletion {
    let phase: String
    let content: String

    init(phase: String, content: String) {
        this.phase = phase
        this.content = content
    }
}

class TodoTool <: ToolExecutor {
    private let repository: SessionMetadataRepository
    private let lock = Mutex()

    init(repository: SessionMetadataRepository) {
        this.repository = repository
    }

    public func execute(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        lock.lock()
        try {
            executeLocked(context, call)
        } finally {
            lock.unlock()
        }
    }

    private func executeLocked(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolResult> {
        let previous = match (repository.todoPhases(context.sessionId)) {
            case Result.Ok(value) =>
                match (decodeTodoPhases(value)) {
                    case Result.Ok(phases) => phases
                    case Result.Err(error) => return Result.Err(error)
                }
            case Result.Err(error) => return Result.Err(error)
        }
        let params = match (parseTodoParams(call, !previous.isEmpty())) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                return Result.Ok(todoErrorResult(
                    call,
                    previous,
                    error.message
                ))
        }
        if (params.op == "view") {
            return Result.Ok(todoResult(
                call,
                params.op,
                previous,
                [],
                todoSummary(previous, readOnly: true)
            ))
        }

        let phases = mutableTodoPhases(previous)
        let errors = ArrayList<String>()
        applyTodoOperation(phases, params, errors)
        if (!errors.isEmpty()) {
            return Result.Ok(todoErrorResult(
                call,
                previous,
                joinTodoErrors(errors.toArray())
            ))
        }
        normalizeTodoProgress(phases)
        let updated = immutableTodoPhases(phases)
        let completed = todoCompletions(previous, updated)
        match (repository.setTodoPhases(
            context.sessionId,
            encodeTodoPhases(updated)
        )) {
            case Result.Ok(_) =>
                Result.Ok(todoResult(
                    call,
                    params.op,
                    updated,
                    completed,
                    todoSummary(updated)
                ))
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func parseTodoParams(
    call: ToolCall,
    hasExisting: Bool
): Result<TodoParams> {
    for (field in call.arguments.fields) {
        if (!isTodoArgument(field.name)) {
            return todoArgumentError<TodoParams>(
                call,
                field.name,
                "unknown todo argument"
            )
        }
    }
    let listResult = parseTodoInitList(call)
    let list = match (listResult) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let itemsResult = parseTodoStringList(call, "items")
    let items = match (itemsResult) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let task = match (todoText(call, "task")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let phase = match (todoText(call, "phase")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let reason = match (todoText(call, "reason")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    var op = match (todoText(call, "op")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (op == "") {
        if (list.hasValue) {
            op = "init"
        } else if (items.hasValue && !items.values.isEmpty()) {
            if (phase != "") {
                op = "append"
            } else if (!hasExisting) {
                op = "init"
            }
        }
    }
    if (!validTodoOperation(op)) {
        return todoArgumentError<TodoParams>(
            call,
            "op",
            if (op == "") {
                "todo op is required"
            } else {
                "unknown todo operation: " + op
            }
        )
    }
    Result.Ok(TodoParams(
        op,
        list.entries,
        list.hasValue,
        task,
        phase,
        items.values,
        items.hasValue,
        reason
    ))
}

class TodoListParse {
    let entries: Array<TodoInitEntry>
    let hasValue: Bool

    init(entries: Array<TodoInitEntry>, hasValue: Bool) {
        this.entries = entries
        this.hasValue = hasValue
    }
}

class TodoStringsParse {
    let values: Array<String>
    let hasValue: Bool

    init(values: Array<String>, hasValue: Bool) {
        this.values = values
        this.hasValue = hasValue
    }
}

func parseTodoInitList(call: ToolCall): Result<TodoListParse> {
    let value = match (call.arguments.field("list")) {
        case Some(value) => value
        case None => return Result.Ok(TodoListParse([], false))
    }
    if (value.kind != ValueKind.List) {
        return todoArgumentError<TodoListParse>(
            call,
            "list",
            "list must be an array"
        )
    }
    let entries = ArrayList<TodoInitEntry>()
    for (entry in value.items) {
        if (entry.kind != ValueKind.Object) {
            return todoArgumentError<TodoListParse>(
                call,
                "list",
                "each list entry must be an object"
            )
        }
        for (field in entry.fields) {
            if (field.name != "phase" && field.name != "items") {
                return todoArgumentError<TodoListParse>(
                    call,
                    "list",
                    "unknown init list field: " + field.name
                )
            }
        }
        let phase = match (entry.field("phase")) {
            case Some(field) =>
                if (field.kind != ValueKind.Text ||
                    field.text.trimAscii() == "") {
                    return todoArgumentError<TodoListParse>(
                        call,
                        "list",
                        "phase must be a non-empty string"
                    )
                }
                field.text
            case None =>
                return todoArgumentError<TodoListParse>(
                    call,
                    "list",
                    "phase is required"
                )
        }
        let itemValue = match (entry.field("items")) {
            case Some(field) => field
            case None =>
                return todoArgumentError<TodoListParse>(
                    call,
                    "list",
                    "items are required"
                )
        }
        let items = match (parseTodoStrings(call, "list", itemValue)) {
            case Result.Ok(values) => values
            case Result.Err(error) => return Result.Err(error)
        }
        if (items.isEmpty()) {
            return todoArgumentError<TodoListParse>(
                call,
                "list",
                "each phase must contain at least one task"
            )
        }
        entries.add(TodoInitEntry(phase, items))
    }
    Result.Ok(TodoListParse(entries.toArray(), true))
}

func parseTodoStringList(
    call: ToolCall,
    name: String
): Result<TodoStringsParse> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            match (parseTodoStrings(call, name, value)) {
                case Result.Ok(values) =>
                    Result.Ok(TodoStringsParse(values, true))
                case Result.Err(error) => Result.Err(error)
            }
        case None => Result.Ok(TodoStringsParse([], false))
    }
}

func parseTodoStrings(
    call: ToolCall,
    name: String,
    value: AgentValue
): Result<Array<String>> {
    if (value.kind != ValueKind.List) {
        return todoArgumentError<Array<String>>(
            call,
            name,
            name + " must be an array of strings"
        )
    }
    let values = ArrayList<String>()
    for (item in value.items) {
        if (item.kind != ValueKind.Text ||
            item.text.trimAscii() == "") {
            return todoArgumentError<Array<String>>(
                call,
                name,
                name + " must contain non-empty strings"
            )
        }
        values.add(item.text)
    }
    Result.Ok(values.toArray())
}

func todoText(call: ToolCall, name: String): Result<String> {
    match (call.arguments.field(name)) {
        case Some(value) =>
            if (value.kind != ValueKind.Text) {
                todoArgumentError<String>(
                    call,
                    name,
                    name + " must be a string"
                )
            } else {
                Result.Ok(value.text.trimAscii())
            }
        case None => Result.Ok("")
    }
}

func todoArgumentError<T>(
    call: ToolCall,
    name: String,
    message: String
): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.InvalidInput,
        "todo.invalid_arguments",
        message,
        fields: [
            ErrorField("tool", call.name),
            ErrorField("argument", name)
        ]
    ))
}

func isTodoArgument(name: String): Bool {
    name == "op" || name == "list" || name == "task" ||
        name == "phase" || name == "items" || name == "reason"
}

func validTodoOperation(op: String): Bool {
    op == "init" || op == "start" || op == "done" || op == "rm" ||
        op == "drop" || op == "block" || op == "unblock" ||
        op == "append" || op == "view"
}

func mutableTodoPhases(
    phases: Array<TodoPhase>
): ArrayList<MutableTodoPhase> {
    let result = ArrayList<MutableTodoPhase>()
    for (phase in phases) {
        let tasks = ArrayList<MutableTodoItem>()
        for (task in phase.tasks) {
            tasks.add(MutableTodoItem(
                task.content,
                task.status,
                task.blocker
            ))
        }
        result.add(MutableTodoPhase(phase.name, tasks))
    }
    result
}

func immutableTodoPhases(
    phases: ArrayList<MutableTodoPhase>
): Array<TodoPhase> {
    let result = ArrayList<TodoPhase>()
    for (phase in phases) {
        let tasks = ArrayList<TodoItem>()
        for (task in phase.tasks) {
            tasks.add(TodoItem(
                task.content,
                status: task.status,
                blocker: task.blocker
            ))
        }
        result.add(TodoPhase(phase.name, tasks.toArray()))
    }
    result.toArray()
}

func applyTodoOperation(
    phases: ArrayList<MutableTodoPhase>,
    params: TodoParams,
    errors: ArrayList<String>
): Unit {
    match (params.op) {
        case "init" => initializeTodos(phases, params, errors)
        case "start" => startTodo(phases, params.task, errors)
        case "done" =>
            updateTodoTargets(
                phases,
                params,
                errors,
                TodoStatus.Completed
            )
        case "drop" =>
            updateTodoTargets(
                phases,
                params,
                errors,
                TodoStatus.Abandoned
            )
        case "block" => blockTodos(phases, params, errors)
        case "unblock" => unblockTodos(phases, params, errors)
        case "rm" => removeTodos(phases, params, errors)
        case "append" => appendTodos(phases, params, errors)
        case _ => ()
    }
}

func initializeTodos(
    phases: ArrayList<MutableTodoPhase>,
    params: TodoParams,
    errors: ArrayList<String>
): Unit {
    var entries = params.list
    if (!params.hasList) {
        if (!params.hasItems || params.items.isEmpty()) {
            errors.add("Missing list for init operation")
            return
        }
        entries = [TodoInitEntry(
            if (params.phase == "") { "Tasks" } else { params.phase },
            params.items
        )]
    }
    for (index in 0..entries.size) {
        let entry = entries[index]
        for (previousIndex in 0..index) {
            if (entries[previousIndex].phase == entry.phase) {
                errors.add(
                    "Duplicate phase \"" + entry.phase + "\" in init list"
                )
            }
        }
        for (itemIndex in 0..entry.items.size) {
            let item = entry.items[itemIndex]
            for (earlierPhase in 0..index) {
                for (earlierItem in entries[earlierPhase].items) {
                    if (earlierItem == item) {
                        errors.add(
                            "Duplicate task \"" + item + "\" in init list"
                        )
                    }
                }
            }
            for (earlierItem in 0..itemIndex) {
                if (entry.items[earlierItem] == item) {
                    errors.add(
                        "Duplicate task \"" + item + "\" in init list"
                    )
                }
            }
        }
    }
    if (!errors.isEmpty()) { return }
    phases.clear()
    for (entry in entries) {
        let tasks = ArrayList<MutableTodoItem>()
        for (item in entry.items) {
            tasks.add(MutableTodoItem(
                item,
                TodoStatus.Pending,
                ""
            ))
        }
        phases.add(MutableTodoPhase(entry.phase, tasks))
    }
}

func startTodo(
    phases: ArrayList<MutableTodoPhase>,
    content: String,
    errors: ArrayList<String>
): Unit {
    let target = findTodo(phases, content)
    match (target) {
        case Some(hit) =>
            for (phase in phases) {
                for (task in phase.tasks) {
                    if (task.status == TodoStatus.InProgress) {
                        task.status = TodoStatus.Pending
                    }
                }
            }
            hit.task.status = TodoStatus.InProgress
        case None => addMissingTodoError(phases, content, errors)
    }
}

class TodoHit {
    let phase: MutableTodoPhase
    let task: MutableTodoItem

    init(phase: MutableTodoPhase, task: MutableTodoItem) {
        this.phase = phase
        this.task = task
    }
}

func findTodo(
    phases: ArrayList<MutableTodoPhase>,
    content: String
): ?TodoHit {
    if (content == "") { return None }
    for (phase in phases) {
        for (task in phase.tasks where task.content == content) {
            return Some(TodoHit(phase, task))
        }
    }
    None
}

func findTodoPhase(
    phases: ArrayList<MutableTodoPhase>,
    name: String
): ?MutableTodoPhase {
    if (name == "") { return None }
    for (phase in phases where phase.name == name) {
        return Some(phase)
    }
    None
}

func addMissingTodoError(
    phases: ArrayList<MutableTodoPhase>,
    content: String,
    errors: ArrayList<String>
): Unit {
    if (content == "") {
        errors.add("Missing task content")
        return
    }
    var count: Int64 = 0
    for (phase in phases) { count += phase.tasks.size }
    errors.add(
        "Task \"" + content + "\" not found" +
        if (count == 0) {
            " (todo list is empty — was it replaced or not yet created?)"
        } else {
            ""
        }
    )
}

func addMissingPhaseError(
    name: String,
    errors: ArrayList<String>
): Unit {
    if (name == "") {
        errors.add("Missing phase name")
    } else {
        errors.add("Phase \"" + name + "\" not found")
    }
}

func updateTodoTargets(
    phases: ArrayList<MutableTodoPhase>,
    params: TodoParams,
    errors: ArrayList<String>,
    status: TodoStatus
): Unit {
    if (params.task != "") {
        match (findTodo(phases, params.task)) {
            case Some(hit) => hit.task.status = status
            case None => addMissingTodoError(phases, params.task, errors)
        }
        return
    }
    if (params.phase != "") {
        match (findTodoPhase(phases, params.phase)) {
            case Some(phase) =>
                for (task in phase.tasks) { task.status = status }
            case None => addMissingPhaseError(params.phase, errors)
        }
        return
    }
    for (phase in phases) {
        for (task in phase.tasks) { task.status = status }
    }
}

func blockTodos(
    phases: ArrayList<MutableTodoPhase>,
    params: TodoParams,
    errors: ArrayList<String>
): Unit {
    if (params.task == "" && params.phase == "") {
        errors.add("block requires a task or phase target")
        return
    }
    let reason = normalizeTodoReason(params.reason)
    if (params.task != "") {
        match (findTodo(phases, params.task)) {
            case Some(hit) => blockTodoItem(hit.task, reason)
            case None => addMissingTodoError(phases, params.task, errors)
        }
        return
    }
    match (findTodoPhase(phases, params.phase)) {
        case Some(phase) =>
            for (task in phase.tasks) { blockTodoItem(task, reason) }
        case None => addMissingPhaseError(params.phase, errors)
    }
}

func blockTodoItem(task: MutableTodoItem, reason: String): Unit {
    if (task.status == TodoStatus.Pending ||
        task.status == TodoStatus.InProgress ||
        task.status == TodoStatus.Blocked) {
        task.status = TodoStatus.Blocked
        task.blocker = reason
    }
}

func unblockTodos(
    phases: ArrayList<MutableTodoPhase>,
    params: TodoParams,
    errors: ArrayList<String>
): Unit {
    if (params.task == "" && params.phase == "") {
        errors.add("unblock requires a task or phase target")
        return
    }
    if (params.task != "") {
        match (findTodo(phases, params.task)) {
            case Some(hit) => unblockTodoItem(hit.task)
            case None => addMissingTodoError(phases, params.task, errors)
        }
        return
    }
    match (findTodoPhase(phases, params.phase)) {
        case Some(phase) =>
            for (task in phase.tasks) { unblockTodoItem(task) }
        case None => addMissingPhaseError(params.phase, errors)
    }
}

func unblockTodoItem(task: MutableTodoItem): Unit {
    if (task.status == TodoStatus.Blocked) {
        task.status = TodoStatus.Pending
        task.blocker = ""
    }
}

func removeTodos(
    phases: ArrayList<MutableTodoPhase>,
    params: TodoParams,
    errors: ArrayList<String>
): Unit {
    if (params.task != "") {
        match (findTodo(phases, params.task)) {
            case Some(hit) =>
                for (index in 0..hit.phase.tasks.size) {
                    if (hit.phase.tasks[index].content == params.task) {
                        hit.phase.tasks.remove(at: index)
                        return
                    }
                }
            case None => addMissingTodoError(phases, params.task, errors)
        }
        return
    }
    if (params.phase != "") {
        match (findTodoPhase(phases, params.phase)) {
            case Some(phase) => phase.tasks.clear()
            case None => addMissingPhaseError(params.phase, errors)
        }
        return
    }
    for (phase in phases) { phase.tasks.clear() }
}

func appendTodos(
    phases: ArrayList<MutableTodoPhase>,
    params: TodoParams,
    errors: ArrayList<String>
): Unit {
    if (params.phase == "") {
        errors.add("Missing phase name for append operation")
        return
    }
    if (!params.hasItems || params.items.isEmpty()) {
        errors.add("Missing items for append operation")
        return
    }
    for (index in 0..params.items.size) {
        let content = params.items[index]
        if (findTodo(phases, content).isSome()) {
            errors.add("Task \"" + content + "\" already exists")
        }
        for (earlier in 0..index) {
            if (params.items[earlier] == content) {
                errors.add("Task \"" + content + "\" already exists")
            }
        }
    }
    if (!errors.isEmpty()) { return }
    let phase = match (findTodoPhase(phases, params.phase)) {
        case Some(value) => value
        case None =>
            let value = MutableTodoPhase(
                params.phase,
                ArrayList<MutableTodoItem>()
            )
            phases.add(value)
            value
    }
    for (content in params.items) {
        phase.tasks.add(MutableTodoItem(
            content,
            TodoStatus.Pending,
            ""
        ))
    }
}

func normalizeTodoProgress(
    phases: ArrayList<MutableTodoPhase>
): Unit {
    var found = false
    for (phase in phases) {
        for (task in phase.tasks) {
            if (task.status == TodoStatus.InProgress) {
                if (found) {
                    task.status = TodoStatus.Pending
                } else {
                    found = true
                }
            }
        }
    }
    if (found) { return }
    for (phase in phases) {
        for (task in phase.tasks) {
            if (task.status == TodoStatus.Pending) {
                task.status = TodoStatus.InProgress
                return
            }
        }
    }
}

func normalizeTodoReason(source: String): String {
    var result = source
        .replace("\n", " ")
        .replace("\r", " ")
        .replace("\t", " ")
        .trimAscii()
    while (result.contains("  ")) {
        result = result.replace("  ", " ")
    }
    result
}

func todoCompletions(
    previous: Array<TodoPhase>,
    updated: Array<TodoPhase>
): Array<TodoCompletion> {
    let result = ArrayList<TodoCompletion>()
    for (phase in updated) {
        for (task in phase.tasks where task.status == TodoStatus.Completed) {
            let old = findImmutableTodo(previous, phase.name, task.content)
            match (old) {
                case Some(value) =>
                    if (value.status != TodoStatus.Completed) {
                        result.add(TodoCompletion(phase.name, task.content))
                    }
                case None => ()
            }
        }
    }
    result.toArray()
}

func findImmutableTodo(
    phases: Array<TodoPhase>,
    phaseName: String,
    content: String
): ?TodoItem {
    for (phase in phases where phase.name == phaseName) {
        for (task in phase.tasks where task.content == content) {
            return Some(task)
        }
    }
    None
}

func todoResult(
    call: ToolCall,
    op: String,
    phases: Array<TodoPhase>,
    completed: Array<TodoCompletion>,
    summary: String
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField("op", textValue(op)),
            ValueField("phases", encodeTodoPhases(phases)),
            ValueField("storage", textValue("session")),
            ValueField(
                "completedTasks",
                encodeTodoCompletions(completed)
            ),
            ValueField("summary", textValue(summary))
        ])
    )
}

func todoErrorResult(
    call: ToolCall,
    phases: Array<TodoPhase>,
    message: String
): ToolResult {
    ToolResult(
        call.callId,
        objectValue([
            ValueField("op", todoOpValue(call)),
            ValueField("phases", encodeTodoPhases(phases)),
            ValueField("storage", textValue("session")),
            ValueField("completedTasks", listValue([])),
            ValueField(
                "summary",
                textValue("Errors: " + message)
            )
        ]),
        isError: true
    )
}

func todoOpValue(call: ToolCall): AgentValue {
    match (call.arguments.field("op")) {
        case Some(value) =>
            if (value.kind == ValueKind.Text) {
                textValue(value.text)
            } else {
                nullValue()
            }
        case None => nullValue()
    }
}

func encodeTodoCompletions(
    completed: Array<TodoCompletion>
): AgentValue {
    let values = ArrayList<AgentValue>()
    for (item in completed) {
        values.add(objectValue([
            ValueField("phase", textValue(item.phase)),
            ValueField("content", textValue(item.content))
        ]))
    }
    listValue(values.toArray())
}

func todoSummary(
    phases: Array<TodoPhase>,
    readOnly!: Bool = false
): String {
    var total: Int64 = 0
    var closed: Int64 = 0
    var open: Int64 = 0
    var blocked: Int64 = 0
    for (phase in phases) {
        for (task in phase.tasks) {
            total += 1
            match (task.status) {
                case TodoStatus.Completed | TodoStatus.Abandoned =>
                    closed += 1
                case TodoStatus.Blocked => blocked += 1
                case TodoStatus.Pending | TodoStatus.InProgress => open += 1
            }
        }
    }
    if (total == 0) {
        return if (readOnly) {
            "Todo list is empty."
        } else {
            "Todo list cleared."
        }
    }
    "Overall: " + closed.toString() + "/" + total.toString() +
        " done, " + open.toString() + " open" +
        if (blocked > 0) {
            ", " + blocked.toString() + " blocked."
        } else {
            "."
        }
}

func joinTodoErrors(errors: Array<String>): String {
    var result = ""
    for (error in errors) {
        if (result != "") { result += "; " }
        result += error
    }
    result
}
