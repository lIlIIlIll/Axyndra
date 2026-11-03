package compaction_plugin

import agent_domain.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Frozen pre-migration algorithm is a test oracle, never a protocol action.
func legacyStructuredSummary(
    messages: Array<ModelMessage>,
    goal!: ?StructuredGoal = None,
    todos!: Array<StructuredTodoPhase> = []
): String {
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
    for (message in messages) {
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
    var summary = "[Compacted session history]\n" + "messages: " + messages.size.toString() + " (user " +
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


@Test
class StructuredPageParityTests {
    @TestCase
    func actualPageAlgebraMatchesOriginalWholeHistoryAcrossBoundaries(): Unit {
        let messages = ArrayList<ModelMessage>()
        for (index in 0..1001) {
            let path = "src/" + (index % 31).toString() + ".cj"
            messages.add(ModelMessage(if (index % 2 == 0) { ModelRole.User } else { ModelRole.Assistant }, [
                ModelBlock(ModelBlockKind.Text, text: if (index % 17 == 0) {
                    "[Compacted session history]\nprior " + (index % 3).toString() +
                    MODEL_COMPACTION_OVERVIEW_MARKER + "not authoritative"
                } else { "  request\r\n" + index.toString() + " 雪  " }),
                ModelBlock(ModelBlockKind.ToolCall, name: if (index % 3 == 0) { "edit" } else { "read" },
                    arguments: objectValue([ValueField("path", textValue(path)),
                        ValueField("input", textValue("[src/other.cj#8]\nchange")),
                        ValueField("command", textValue("build\n" + (index % 9).toString()))])),
                ModelBlock(ModelBlockKind.ToolResult, name: "bash", isError: index % 4 == 0,
                    arguments: objectValue([ValueField("exit_code", integerValue(index % 2)),
                        ValueField("stderr", textValue("failure\n" + (index % 13).toString()))]))]))
        }
        let goal = Some(StructuredGoal("Finish migration", "active"))
        let todos = [StructuredTodoPhase("Verify", [StructuredTodoTask("actual native parity", StructuredTodoStatus.Blocked, "SDK")])]
        let workflow = [ValueField("goal", objectValue([ValueField("objective", textValue("Finish migration")), ValueField("status", textValue("active"))])),
            ValueField("todos", listValue([objectValue([ValueField("name", textValue("Verify")), ValueField("tasks", listValue([
                objectValue([ValueField("content", textValue("actual native parity")), ValueField("status", textValue("blocked")),
                    ValueField("blocker", textValue("SDK"))])]))])]))]
        let expected = legacyStructuredSummary(messages.toArray(), goal: goal, todos: todos)
        for (width in [1, 7, 128, 512]) {
            var state = nullValue(); var offset: Int64 = 0; var summary = ""
            while (offset < messages.size) {
                let end = min(messages.size, offset + width)
                let fields = ArrayList<ValueField>([ValueField("schema", textValue("axyndra.compaction-policy/v1")),
                    ValueField("phase", textValue("structured_page")), ValueField("snapshot_digest", textValue("oracle")),
                    ValueField("page_id", textValue(offset.toString())), ValueField("offset", integerValue(offset)),
                    ValueField("total", integerValue(messages.size)), ValueField("state", state),
                    ValueField("projection", modelRequestSnapshotValue(ModelRequest("compaction-history", messages.toArray()[offset..end])))])
                fields.add(all: workflow)
                let result = compactionPolicy(objectValue(fields.toArray()))
                @Expect(structuredInteger(result, "next_offset"), end)
                state = result.field("state").getOrThrow()
                if (end == messages.size) { summary = policyText(result, "summary") }
                else { @Expect(result.field("summary").getOrThrow().unifiedKind, ValueKind.Null) }
                offset = end
            }
            @Expect(summary, expected)
        }
    }
}
