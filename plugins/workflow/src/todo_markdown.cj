package workflow_plugin

import agent_domain.*
import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

func todoPhasesToMarkdown(phases: Array<TodoPhase>): String {
    if (phases.isEmpty()) { return "# Todos\n" }
    var text = ""
    for (phaseIndex in 0..phases.size) {
        let phase = phases[phaseIndex]
        if (phaseIndex > 0) { text += "\n" }
        text += "# " + phase.name + "\n"
        for (task in phase.tasks) {
            text += "- [" + todoStatusMarker(task.status) + "] " +
                task.content
            if (task.status == TodoStatus.Blocked &&
                task.blocker.trimAscii() != "") {
                text += " <!-- blocker: " +
                    cleanTodoBlocker(task.blocker) + " -->"
            }
            text += "\n"
        }
    }
    text
}

func todoPhasesFromMarkdown(
    markdown: String
): Result<Array<TodoPhase>> {
    let phases = ArrayList<MutableTodoPhase>()
    let errors = ArrayList<String>()
    var current: ?MutableTodoPhase = None
    let lines = markdown.replace("\r\n", "\n").split("\n")
    for (index in 0..lines.size) {
        let line = lines[index].trimAscii()
        if (line == "") { continue }
        match (todoHeading(line)) {
            case Some(name) =>
                let phase = MutableTodoPhase(
                    name,
                    ArrayList<MutableTodoItem>()
                )
                phases.add(phase)
                current = Some(phase)
                continue
            case None => ()
        }
        match (todoMarkdownTask(line)) {
            case Some(parsed) =>
                let phase = match (current) {
                    case Some(value) => value
                    case None =>
                        let value = MutableTodoPhase(
                            "Todos",
                            ArrayList<MutableTodoItem>()
                        )
                        phases.add(value)
                        current = Some(value)
                        value
                }
                match (todoStatusFromMarker(parsed.marker)) {
                    case Some(status) =>
                        phase.tasks.add(MutableTodoItem(
                            parsed.content,
                            status,
                            parsed.blocker
                        ))
                    case None =>
                        errors.add(
                            "Line " + (index + 1).toString() +
                            ": unknown status marker \"[" +
                            parsed.marker +
                            "]\" (use [ ], [x], [/], [-], [!])"
                        )
                }
                continue
            case None => ()
        }
        errors.add(
            "Line " + (index + 1).toString() +
            ": unrecognized syntax \"" + line + "\""
        )
    }
    if (!errors.isEmpty()) {
        return Result.Err(AgentError(
            AgentErrorKind.InvalidInput,
            "application.todo_markdown_invalid",
            "Could not parse todo Markdown:\n  " +
                joinTodoErrors(errors.toArray())
        ))
    }
    normalizeTodoProgress(phases)
    Result.Ok(immutableTodoPhases(phases))
}

class ParsedTodoMarkdownTask {
    let marker: String
    let content: String
    let blocker: String

    init(marker: String, content: String, blocker: String) {
        this.marker = marker
        this.content = content
        this.blocker = blocker
    }
}

func todoMarkdownTask(line: String): ?ParsedTodoMarkdownTask {
    if (line.size < 6 ||
        (line[0] != b'-' && line[0] != b'*' && line[0] != b'+') ||
        line[1] != b' ' || line[2] != b'[' || line[4] != b']' ||
        line[5] != b' ') {
        return None
    }
    let marker = line[3..4]
    var content = line[6..].trimAscii()
    if (content == "") { return None }
    var blocker = ""
    if (marker == "!" && content.endsWith("-->")) {
        match (content.lastIndexOf("<!-- blocker:")) {
            case Some(start) =>
                blocker = content[
                    start + "<!-- blocker:".size..
                    content.size - "-->".size
                ].trimAscii()
                content = content[..start].trimAscii()
            case None => ()
        }
    }
    if (content == "") { return None }
    Some(ParsedTodoMarkdownTask(marker, content, blocker))
}

func todoHeading(line: String): ?String {
    var count: Int64 = 0
    while (count < line.size && line[count] == b'#') { count += 1 }
    if (count < 1 || count > 6 || count >= line.size ||
        line[count] != b' ') {
        return None
    }
    let name = line[count + 1..].trimAscii()
    if (name == "") { None } else { Some(name) }
}

func todoStatusMarker(status: TodoStatus): String {
    match (status) {
        case TodoStatus.Pending => " "
        case TodoStatus.InProgress => "/"
        case TodoStatus.Completed => "x"
        case TodoStatus.Abandoned => "-"
        case TodoStatus.Blocked => "!"
    }
}

func todoStatusFromMarker(marker: String): ?TodoStatus {
    match (marker) {
        case " " | "" => Some(TodoStatus.Pending)
        case "x" | "X" => Some(TodoStatus.Completed)
        case "/" | ">" => Some(TodoStatus.InProgress)
        case "-" | "~" => Some(TodoStatus.Abandoned)
        case "!" => Some(TodoStatus.Blocked)
        case _ => None
    }
}

func findTodoPhaseFuzzy(
    phases: Array<TodoPhase>,
    query: String
): ?TodoPhase {
    let normalized = query.trimAscii().toAsciiLower()
    if (normalized == "") { return None }
    for (phase in phases where
         phase.name.toAsciiLower() == normalized) {
        return Some(phase)
    }
    let prefixes = ArrayList<TodoPhase>()
    for (phase in phases where
         phase.name.toAsciiLower().startsWith(normalized)) {
        prefixes.add(phase)
    }
    if (prefixes.size == 1) { return Some(prefixes[0]) }
    let substrings = ArrayList<TodoPhase>()
    for (phase in phases where
         phase.name.toAsciiLower().contains(normalized)) {
        substrings.add(phase)
    }
    if (substrings.size == 1) { Some(substrings[0]) } else { None }
}

func findTodoTaskFuzzy(
    phases: Array<TodoPhase>,
    query: String
): ?TodoItem {
    let normalized = query.trimAscii().toAsciiLower()
    if (normalized == "") { return None }
    for (phase in phases) {
        for (task in phase.tasks where
             task.content.toAsciiLower() == normalized) {
            return Some(task)
        }
    }
    let matches = ArrayList<TodoItem>()
    for (phase in phases) {
        for (task in phase.tasks where
             task.content.toAsciiLower().contains(normalized)) {
            matches.add(task)
        }
    }
    if (matches.size == 1) { return Some(matches[0]) }
    let active = ArrayList<TodoItem>()
    for (task in matches where
         task.status == TodoStatus.InProgress ||
         task.status == TodoStatus.Pending) {
        active.add(task)
    }
    if (active.size == 1) { Some(active[0]) } else { None }
}

func joinTodoArguments(values: Array<String>, start: Int64): String {
    var text = ""
    for (index in start..values.size) {
        if (text != "") { text += " " }
        text += values[index]
    }
    text
}

func titleCaseTodoWords(source: String): String {
    let words = source.split(" ")
    var text = ""
    for (word in words where word.trimAscii() != "") {
        if (text != "") { text += " " }
        text += sentenceCaseTodo(word)
    }
    text
}

func sentenceCaseTodo(source: String): String {
    let value = source.trimAscii()
    if (value == "" || value[0] < b'a' || value[0] > b'z') {
        return value
    }
    let first = String.fromUtf8([value[0] - 32])
    first + value[1..]
}

func stripTodoPathQuotes(source: String): String {
    if (source.size >= 2 && source.startsWith("\"") &&
        source.endsWith("\"")) {
        source[1..source.size - 1]
    } else {
        source
    }
}

func cleanTodoBlocker(source: String): String {
    source
        .replace("\r", " ")
        .replace("\n", " ")
        .replace("-->", "-- >")
        .trimAscii()
}

func todoTaskCount(phases: Array<TodoPhase>): Int64 {
    var count: Int64 = 0
    for (phase in phases) { count += phase.tasks.size }
    count
}

func todoHelpText(): String {
    "Usage: /todo <verb> [args]\n" +
    "  /todo                              Show current todos\n" +
    "  /todo edit                         Open the cjtui Markdown editor\n" +
    "  /todo copy                         Copy todos as Markdown\n" +
    "  /todo export [<path>]              Write todos to file " +
        "(default: TODO.md)\n" +
    "  /todo import [<path>]              Replace todos from file " +
        "(default: TODO.md)\n" +
    "  /todo append [<phase>] <task...>   Append a task\n" +
    "  /todo start  <task>                Mark task in_progress\n" +
    "  /todo done   [<task|phase>]        Mark completed\n" +
    "  /todo drop   [<task|phase>]        Mark abandoned\n" +
    "  /todo rm     [<task|phase>]        Remove task/phase/all"
}
