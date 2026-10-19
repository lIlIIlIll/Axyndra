package agent_app

import agent_domain.*
import agent_product.*
import std.collection.*
import yjson.*
import yjson_support.*

func printToolsHelp(): Unit {
    println("axyndra tools list")
    println("axyndra tools inspect <tool-name>")
    println("axyndra tools invoke <tool-name> '<JSON object>'")
    println("Tools use the configured policy and canonical Direct invocation pipeline.")
    println("An approval requirement is reported without executing the tool.")
}

func runToolsCli(session: ApplicationSession, arguments: Array<String>): Int64 {
    if (arguments.isEmpty() || (arguments.size == 1 &&
        (arguments[0] == "--help" || arguments[0] == "-h"))) {
        printToolsHelp()
        return 0
    }
    if (arguments.size == 1 && arguments[0] == "list") {
        let values = ArrayList<AgentValue>()
        for (tool in session.tools()) {
            values.add(objectValue([
                ValueField("name", textValue(tool.name)),
                ValueField("description", textValue(tool.description))
            ]))
        }
        println(stringifyUnifiedJson(listValue(values.toArray())))
        return 0
    }
    if (arguments.size == 2 && arguments[0] == "inspect") {
        for (tool in session.tools() where tool.name == arguments[1]) {
            println(stringifyUnifiedJson(objectValue([
                ValueField("name", textValue(tool.name)),
                ValueField("description", textValue(tool.description)),
                ValueField("parameters", tool.inputSchema)
            ])))
            return 0
        }
        printError(AgentError(AgentErrorKind.Configuration, "tool.unavailable",
            "tool is not available in the current contribution catalog",
            fields: [ErrorField("tool", arguments[1])]))
        return 1
    }
    if (arguments.size != 3 || arguments[0] != "invoke" ||
        arguments[1].size == 0 || arguments[1].size > 256 || arguments[2].size > 65536) {
        eprintln("error: expected tools list, inspect <name>, or invoke <name> '<JSON object>' (up to 64 KiB)")
        return 2
    }
    let input = try { parseUnifiedJson(arguments[2], maxBytes: 65536, maxDepth: 32) }
        catch (_: Exception) {
            eprintln("error: tool arguments must be bounded valid JSON")
            return 2
        }
    if (input.unifiedKind != ValueKind.Object) {
        eprintln("error: tool arguments must be a JSON object")
        return 2
    }
    match (session.invokeLocalTool(arguments[1], input)) {
        case Result.Err(error) =>
            printError(error)
            1
        case Result.Ok(result) => try {
            println(stringifyUnifiedJson(result.output))
            if (result.isError) { 1 } else { 0 }
        } finally { result.releasePayload() }
    }
}
