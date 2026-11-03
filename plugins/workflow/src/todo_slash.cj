package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func workflowCommandWhitespace(byte: Byte): Bool {
    byte == b' ' || byte == b'\t' || byte == b'\r' || byte == b'\n'
}

func workflowCommandArguments(source: String): Array<String> {
    let tokens = ArrayList<String>()
    let data = unsafe { source.rawData() }
    var index: Int64 = 0
    while (index < data.size) {
        while (index < data.size && workflowCommandWhitespace(data[index])) { index++ }
        if (index >= data.size) { break }
        let decoded = ArrayList<Byte>()
        var inQuote = false
        while (index < data.size) {
            let byte = data[index]
            if (!inQuote && workflowCommandWhitespace(byte)) { break }
            if (byte == b'\\' && index + 1 < data.size &&
                ((inQuote && (data[index + 1] == b'"' || data[index + 1] == b'\\')) ||
                (!inQuote && (workflowCommandWhitespace(data[index + 1]) || data[index + 1] == b'"' || data[index + 1] == b'\\')))) {
                decoded.add(data[index + 1]); index += 2; continue
            }
            if (byte == b'"') { inQuote = !inQuote; index++; continue }
            decoded.add(byte); index++
        }
        if (inQuote) { throw PureProviderError("cli.unterminated_quote", "unterminated double quote") }
        tokens.add(String.fromUtf8(decoded.toArray()))
    }
    tokens.toArray()
}

func workflowTodoCommand(input: AgentValue): AgentValue {
    workflowFields(input, ["command_args"])
    let raw = workflowText(input, "command_args").trimAscii()
    // Preserve the previously introduced exact JSON Tool convenience syntax.
    if (raw.startsWith("{")) {
        let args = parseUnifiedJson(raw, maxBytes: 65536, maxDepth: 32)
        if (args.unifiedKind != ValueKind.Object || args.field(CONTEXT_READ_INPUT_FIELD).isSome() || args.field("command_args").isSome()) {
            throw PureProviderError("workflow.command_invalid", "command cannot supply a Host fact envelope") }
        return objectValue([ValueField("schema", textValue("axyndra.command-proposal/v1")),
            ValueField("local_tool", textValue("todo")), ValueField("input", args)])
    }
    let args = workflowCommandArguments(raw)
    let verb = if (args.isEmpty()) { "" } else { args[0].toAsciiLower() }
    if (verb == "help" || verb == "?") {
        return objectValue([ValueField("schema", textValue("axyndra.command-message/v1")), ValueField("text", textValue(todoHelpText()))])
    }
    if (verb == "edit") {
        throw PureProviderError("application.todo_edit_tui_only", "/todo edit requires the TUI editor; use /todo export then /todo import for non-interactive edits.") }
    if (verb == "import" || verb == "export") {
        if(args.size>2){throw PureProviderError("application.invalid_command_arguments","Todo import/export accepts one optional resource reference")}
        let target=if(args.size==1){"TODO.md"}else{args[1]}
        if(target=="" || target.size>4096 || target.contains("\u{0000}")){
            throw PureProviderError("application.invalid_command_arguments","Todo import/export resource reference is invalid")}
        if(verb=="import"){
            return objectValue([ValueField("schema",textValue("axyndra.command-proposal/v1")),
                ValueField("local_tool",textValue("todo")),ValueField("input",objectValue([
                    ValueField("frontend_action",textValue("import")),ValueField("reference",textValue(target))]))])}
        return objectValue([ValueField("schema",textValue("axyndra.command-proposal/v1")),
            ValueField("local_tool",textValue("todo")),ValueField("input",objectValue([
                ValueField("frontend_action",textValue("export")),ValueField("destination",textValue(target))]))])
    }
    if (!["", "view", "copy", "append", "start", "done", "drop", "rm"].contains(verb)) {
        throw PureProviderError("application.todo_unknown_subcommand", "Unknown /todo subcommand. Use append, start, done, drop, rm, copy, export, import.") }
    return objectValue([ValueField("schema", textValue("axyndra.command-proposal/v1")),
        ValueField("local_tool", textValue("todo")), ValueField("input", objectValue([ValueField("command_args", textValue(raw))]))])
}

func workflowTodoSlashResult(before: AgentValue, after: Array<TodoPhase>, text: String, error!: String = "", usage!: String = ""): AgentValue {
    let encoded = encodeTodoPhases(after)
    let detail = objectValue([ValueField("code", textValue(error)), ValueField("message", textValue(text))])
    if (usage != "") { detail.put("fields", objectValue([ValueField("usage", textValue(usage))])) }
    objectValue([ValueField("changed", boolValue(error == "" && canonicalAgentValue(before) != canonicalAgentValue(encoded))),
        ValueField("document", if (error == "") { encoded } else { before }), ValueField("is_error", boolValue(error != "")),
        ValueField("output", if (error == "") { textValue(text) } else {
            objectValue([ValueField("error", detail)]) })])
}

func workflowTodoSlashUsage(before: AgentValue, current: Array<TodoPhase>, expected: String): AgentValue {
    workflowTodoSlashResult(before, current, "invalid command arguments",
        error: "application.invalid_command_arguments", usage: expected)
}

func workflowTodoSlash(previous: AgentValue, raw: String): AgentValue {
    let current = match (decodeTodoPhases(previous)) {
        case Result.Ok(value) => value; case Result.Err(error) => throw PureProviderError(error.code, error.message) }
    let arguments = workflowCommandArguments(raw)
    let verb = if (arguments.isEmpty()) { "" } else { arguments[0].toAsciiLower() }
    let rest = if (arguments.isEmpty()) { "" } else { joinTodoArguments(arguments, 1).trimAscii() }
    if (verb == "" || verb == "view") {
        return workflowTodoSlashResult(previous, current, if (current.isEmpty()) {
            "No todos. Use /todo append <task> to start one." } else { todoPhasesToMarkdown(current).trimAscii() }) }
    if (verb == "copy") {
        if (rest != "") { return workflowTodoSlashUsage(previous, current, "/todo copy") }
        return workflowTodoSlashResult(previous, current, "Copy not available in non-interactive mode; printing instead:\n\n" +
            if (current.isEmpty()) { "No todos." } else { todoPhasesToMarkdown(current).trimAscii() }) }
    var task = ""; var phase = ""; var content = ""; var message = ""
    let params: TodoParams
    if (verb == "append") {
        let count = arguments.size - 1
        if (count == 0) { return workflowTodoSlashUsage(previous, current, "/todo append [<phase>] <task...>") }
        let query = if (count == 1) { "" } else { arguments[1] }
        content = sentenceCaseTodo(if (count == 1) { arguments[1] } else { joinTodoArguments(arguments, 2) })
        phase = if (query == "") { if (current.isEmpty()) { "Todos" } else { current[current.size - 1].name } }
            else { match (findTodoPhaseFuzzy(current, query)) { case Some(value) => value.name; case None => titleCaseTodoWords(query) } }
        params = TodoParams("append", [], false, "", phase, [content], true, "")
        message = "Appended to " + phase + ": " + content
    } else if (verb == "start") {
        if (rest == "") { return workflowTodoSlashUsage(previous, current, "/todo start <task>") }
        task = match (findTodoTaskFuzzy(current, rest)) { case Some(value) => value.content
            case None => return workflowTodoSlashResult(previous, current, "No task matched \"" + rest + "\". Use /todo to list current tasks.",
                error: "application.todo_task_not_found") }
        params = TodoParams("start", [], false, task, "", [], false, "")
        message = "Started: " + task
    } else if (["done", "drop", "rm"].contains(verb)) {
        if (rest == "" && verb == "rm") { return workflowTodoSlashResult(previous, [], "Cleared all todos.") }
        if (rest != "") {
            match (findTodoTaskFuzzy(current, rest)) { case Some(value) => task = value.content
                case None => match (findTodoPhaseFuzzy(current, rest)) { case Some(value) => phase = value.name
                    case None => return workflowTodoSlashResult(previous, current, "No task or phase matched \"" + rest + "\".",
                        error: "application.todo_target_not_found") } }
        }
        params = TodoParams(verb, [], false, task, phase, [], false, "")
        message = workflowTodoMutationMessage(verb, task, phase)
    } else { return workflowTodoSlashResult(previous, current, "Unknown /todo subcommand.", error: "application.todo_unknown_subcommand") }
    let phases = mutableTodoPhases(current)
    let errors = ArrayList<String>()
    applyTodoOperation(phases, params, errors)
    if (!errors.isEmpty()) { return workflowTodoSlashResult(previous, current, joinTodoErrors(errors.toArray()), error: "application.todo_operation_invalid") }
    normalizeTodoProgress(phases)
    workflowTodoSlashResult(previous, immutableTodoPhases(phases), message)
}

func workflowTodoMutationMessage(verb: String, task: String, phase: String): String {
    if (task != "") { return match (verb) { case "done" => "Marked completed: " + task
        case "drop" => "Marked abandoned: " + task; case _ => "Removed: " + task } }
    if (phase != "") { return match (verb) { case "done" => "Marked phase " + phase + " completed."
        case "drop" => "Marked phase " + phase + " abandoned."; case _ => "Removed phase: " + phase } }
    if (verb == "done") { "Marked all tasks completed." } else { "Marked all tasks abandoned." }
}
