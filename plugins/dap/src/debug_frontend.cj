package dap_plugin

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Business projection only. Paths are supplied by the current, completed
// Host context-read result. These values neither authorize filesystem access
// nor select a process lease. The Host independently freezes the real call.
class DapDebugLocations {
    let cwd: String
    let program: String
    let source: String
    init(cwd: String, program!: String = "", source!: String = "") {
        this.cwd = cwd; this.program = program; this.source = source
    }
}

// A complete legacy debug command, including its response-dependent work.
// The runner must admit each later concrete write through the original Tool
// pipeline. Neither waitForStop nor refreshFrame is permission to write.
class DapDebugCall {
    let action: String
    let timeoutMillis: Int64
    let request: ?JsonNode
    let waitForStop: Bool
    let refreshFrame: Bool
    let usesContext: Bool
    init(action: String, timeoutMillis: Int64, request: ?JsonNode,
        waitForStop!: Bool = false, refreshFrame!: Bool = false, usesContext!: Bool = false) {
        this.action = action; this.timeoutMillis = timeoutMillis; this.request = request
        this.waitForStop = waitForStop; this.refreshFrame = refreshFrame
        this.usesContext = usesContext
    }
}

func debugActionNames(): Array<String> {
    ["launch", "attach", "set_breakpoint", "remove_breakpoint", "set_instruction_breakpoint",
        "remove_instruction_breakpoint", "data_breakpoint_info", "set_data_breakpoint", "remove_data_breakpoint",
        "continue", "step_over", "step_in", "step_out", "pause", "evaluate", "stack_trace", "threads", "scopes",
        "variables", "disassemble", "read_memory", "write_memory", "modules", "loaded_sources", "custom_request",
        "output", "terminate", "sessions"]
}

func debugReadonlyAction(action: String): Bool {
    ["output", "threads", "stack_trace", "scopes", "variables", "disassemble", "read_memory",
        "loaded_sources", "modules", "sessions"].contains(action)
}

// Match the former public debug schema. Optional values retain the old
// defaulting behavior; authorization is not inferred from this schema.
func debugInputSchema(): JsonNode {
    let properties = ArrayList<JsonObjectEntry>()
    let actions = ArrayList<JsonNode>()
    for (action in debugActionNames()) { actions.add(jsonString(action)) }
    properties.add(JsonObjectEntry("action", jsonObject([JsonObjectEntry("type", jsonString("string")),
        JsonObjectEntry("enum", jsonArray(actions.toArray()))])))
    for ((name, kind) in [("program", "string"), ("adapter", "string"), ("cwd", "string"), ("file", "string"),
        ("line", "number"), ("function", "string"), ("name", "string"), ("condition", "string"),
        ("hit_condition", "string"), ("expression", "string"), ("context", "string"), ("frame_id", "number"),
        ("scope_id", "number"), ("variable_ref", "number"), ("pid", "number"), ("port", "number"),
        ("host", "string"), ("levels", "number"), ("memory_reference", "string"), ("instruction_reference", "string"),
        ("instruction_count", "number"), ("instruction_offset", "number"), ("count", "number"), ("data", "string"),
        ("data_id", "string"), ("command", "string"), ("arguments", "object"), ("offset", "number"),
        ("resolve_symbols", "boolean"), ("allow_partial", "boolean"), ("start_module", "number"),
        ("module_count", "number"), ("timeout", "number")]) {
        properties.add(JsonObjectEntry(name, jsonObject([JsonObjectEntry("type", jsonString(kind))])))
    }
    properties.add(JsonObjectEntry("args", jsonObject([JsonObjectEntry("type", jsonString("array")),
        JsonObjectEntry("items", jsonObject([JsonObjectEntry("type", jsonString("string"))]))])))
    properties.add(JsonObjectEntry("access_type", jsonObject([JsonObjectEntry("type", jsonString("string")),
        JsonObjectEntry("enum", jsonArray([jsonString("read"), jsonString("write"), jsonString("readWrite")]))])))
    jsonObject([JsonObjectEntry("type", jsonString("object")), JsonObjectEntry("properties", jsonObject(properties.toArray())),
        JsonObjectEntry("required", jsonArray([jsonString("action")])), JsonObjectEntry("additionalProperties", jsonBool(false))])
}

func debugText(input: JsonNode, name: String, fallback!: String = ""): String {
    let value = field(input, name)
    if (value.unifiedKind == UnifiedJsonKind.Text) { value.text } else { fallback }
}
func debugRequiredText(input: JsonNode, name: String): String {
    let value = field(input, name)
    require(value.unifiedKind == UnifiedJsonKind.Text, "tool.invalid_argument"); value.text
}
func debugInteger(input: JsonNode, name: String, fallback: Int64): Int64 {
    let value = field(input, name)
    if (value.unifiedKind != UnifiedJsonKind.Number) { return fallback }
    try { Int64.parse(value.asNumberText()) } catch (_: Exception) { fallback }
}
func debugBoolean(input: JsonNode, name: String, fallback: Bool): Bool {
    let value = field(input, name)
    if (value.unifiedKind == UnifiedJsonKind.Boolean) { value.asBool() } else { fallback }
}
func debugOptionalNumber(input: JsonNode, target: JsonNode, name: String, destination: String): Unit {
    let missing: Int64 = -9223372036854775807
    let value = debugInteger(input, name, missing)
    if (value != missing) { target.put(destination, jsonNumber(value.toString())) }
}
func debugOptionalText(input: JsonNode, target: JsonNode, name: String, destination: String): Unit {
    let value = debugText(input, name)
    if (value != "") { target.put(destination, jsonString(value)) }
}
func debugMerge(defaults: JsonNode, values: JsonNode): JsonNode {
    require(defaults.unifiedKind == UnifiedJsonKind.Object && values.unifiedKind == UnifiedJsonKind.Object)
    let result = ArrayList<JsonObjectEntry>()
    for (entry in defaults.fields where values.field(entry.name).isNone()) { result.add(entry) }
    for (entry in values.fields) { result.add(entry) }
    jsonObject(result.toArray())
}
func debugRequest(command: String, args: JsonNode): JsonNode {
    jsonObject([JsonObjectEntry("command", jsonString(command)), JsonObjectEntry("arguments", args)])
}
func debugCapabilities(action: String, capabilities: JsonNode): Unit {
    let name = match (action) {
        case "set_instruction_breakpoint" | "remove_instruction_breakpoint" => "supportsInstructionBreakpoints"
        case "data_breakpoint_info" | "set_data_breakpoint" | "remove_data_breakpoint" => "supportsDataBreakpoints"
        case "disassemble" => "supportsDisassembleRequest"
        case "read_memory" => "supportsReadMemoryRequest"
        case "write_memory" => "supportsWriteMemoryRequest"
        case "modules" => "supportsModulesRequest"
        case "loaded_sources" => "supportsLoadedSourcesRequest"
        case _ => ""
    }
    require(name == "" || boolean(capabilities, name), "tool.debug_capability")
}

// No transport, process, Store, workspace or Host API is called here. The
// current session cache supplies stopped/frame data only; it is not a grant.
func prepareDebugCall(input: JsonNode, snapshot: JsonNode, capabilities: JsonNode,
    locations: DapDebugLocations, launchDefaults: JsonNode, attachDefaults: JsonNode): DapDebugCall {
    require(input.unifiedKind == UnifiedJsonKind.Object, "tool.invalid_argument")
    let action = debugRequiredText(input, "action").trimAscii().toAsciiLower()
    require(debugActionNames().contains(action), "tool.invalid_argument")
    let seconds = debugInteger(input, "timeout", 30)
    require(seconds >= 1 && seconds <= 3600, "tool.invalid_argument")
    let timeout = seconds * 1000
    if (action == "output" || action == "sessions") { return DapDebugCall(action, timeout, None) }
    debugCapabilities(action, capabilities)
    var command = if (action == "custom_request") { debugRequiredText(input, "command") } else { actionCommand(action, input) }
    var args = jsonObject([])
    match (action) {
        case "launch" =>
            let _ = debugRequiredText(input, "program")
            require(locations.program != "" && locations.cwd != "", "dap_plugin.source_metadata_required")
            let values = ArrayList<JsonNode>()
            let authored = field(input, "args")
            if (authored.unifiedKind == UnifiedJsonKind.List) {
                for (value in authored.items where value.unifiedKind == UnifiedJsonKind.Text) { values.add(jsonString(value.text)) }
            }
            args = debugMerge(launchDefaults, jsonObject([JsonObjectEntry("request", jsonString("launch")),
                JsonObjectEntry("program", jsonString(locations.program)), JsonObjectEntry("cwd", jsonString(locations.cwd)),
                JsonObjectEntry("args", jsonArray(values.toArray()))]))
        case "attach" =>
            let pid = debugInteger(input, "pid", -1); let port = debugInteger(input, "port", -1)
            require(pid >= 0 || port >= 0, "tool.invalid_argument")
            require(locations.cwd != "", "dap_plugin.source_metadata_required")
            args.put("request", jsonString("attach")); args.put("cwd", jsonString(locations.cwd))
            if (pid >= 0) { args.put("pid", jsonNumber(pid.toString())); args.put("processId", jsonNumber(pid.toString())) }
            if (port >= 0) { args.put("port", jsonNumber(port.toString())) }
            debugOptionalText(input, args, "host", "host"); args = debugMerge(attachDefaults, args)
        case "set_breakpoint" | "remove_breakpoint" =>
            let functionName = debugText(input, "function")
            if (functionName != "") { args.put("function", jsonString(functionName)) }
            else {
                let _ = debugRequiredText(input, "file")
                let line = debugInteger(input, "line", -1); require(line > 0, "tool.invalid_argument")
                require(locations.source != "", "dap_plugin.source_metadata_required")
                args.put("file", jsonString(locations.source)); args.put("line", jsonNumber(line.toString()))
            }
            debugOptionalText(input, args, "condition", "condition"); debugOptionalText(input, args, "hit_condition", "hit_condition")
        case "set_instruction_breakpoint" | "remove_instruction_breakpoint" =>
            args.put("instruction_reference", jsonString(debugRequiredText(input, "instruction_reference")))
            args.put("offset", jsonNumber(debugInteger(input, "offset", 0).toString()))
            debugOptionalText(input, args, "condition", "condition"); debugOptionalText(input, args, "hit_condition", "hit_condition")
        case "data_breakpoint_info" =>
            args.put("name", jsonString(debugRequiredText(input, "name")))
            let reference = debugInteger(input, "variable_ref", debugInteger(input, "scope_id", -1))
            let frame = debugInteger(input, "frame_id", -1)
            if (reference >= 0) { args.put("variablesReference", jsonNumber(reference.toString())) }
            if (frame >= 0) { args.put("frameId", jsonNumber(frame.toString())) }
        case "set_data_breakpoint" | "remove_data_breakpoint" =>
            args.put("data_id", jsonString(debugRequiredText(input, "data_id")))
            debugOptionalText(input, args, "access_type", "access_type")
            debugOptionalText(input, args, "condition", "condition"); debugOptionalText(input, args, "hit_condition", "hit_condition")
        case "continue" | "step_over" | "step_in" | "step_out" | "stack_trace" =>
            let thread = number(snapshot, "threadId"); require(thread > 0, "tool.debug_no_thread")
            args.put("threadId", jsonNumber(thread.toString()))
            if (action == "stack_trace") {
                let levels = debugInteger(input, "levels", -1)
                if (levels >= 0) { args.put("levels", jsonNumber(levels.toString())) }
            }
        case "pause" =>
            let thread = number(snapshot, "threadId")
            if (thread > 0) { args.put("threadId", jsonNumber(thread.toString())) }
        case "evaluate" =>
            args.put("expression", jsonString(debugRequiredText(input, "expression")))
            args.put("context", jsonString(debugText(input, "context", fallback: "repl")))
            let frame = debugInteger(input, "frame_id", number(snapshot, "frameId"))
            if (frame > 0) { args.put("frameId", jsonNumber(frame.toString())) }
        case "scopes" =>
            let frame = debugInteger(input, "frame_id", number(snapshot, "frameId"))
            require(frame > 0, "tool.debug_no_frame"); args.put("frameId", jsonNumber(frame.toString()))
        case "variables" =>
            let reference = debugInteger(input, "variable_ref", debugInteger(input, "scope_id", -1))
            require(reference >= 0, "tool.invalid_argument"); args.put("variablesReference", jsonNumber(reference.toString()))
        case "disassemble" =>
            let count = debugInteger(input, "instruction_count", -1); require(count > 0, "tool.invalid_argument")
            let authored = debugText(input, "memory_reference")
            let reference = if (authored != "") { authored } else { text(snapshot, "instructionPointerReference") }
            require(reference != "", "tool.invalid_argument")
            args.put("memoryReference", jsonString(reference)); args.put("instructionCount", jsonNumber(count.toString()))
            debugOptionalNumber(input, args, "offset", "offset"); debugOptionalNumber(input, args, "instruction_offset", "instructionOffset")
            args.put("resolveSymbols", jsonBool(debugBoolean(input, "resolve_symbols", false)))
        case "read_memory" =>
            args.put("memoryReference", jsonString(debugRequiredText(input, "memory_reference")))
            let count = debugInteger(input, "count", -1); require(count >= 0, "tool.invalid_argument")
            args.put("count", jsonNumber(count.toString())); debugOptionalNumber(input, args, "offset", "offset")
        case "write_memory" =>
            args.put("memoryReference", jsonString(debugRequiredText(input, "memory_reference")))
            args.put("data", jsonString(debugRequiredText(input, "data")))
            debugOptionalNumber(input, args, "offset", "offset"); args.put("allowPartial", jsonBool(debugBoolean(input, "allow_partial", false)))
        case "modules" =>
            debugOptionalNumber(input, args, "start_module", "startModule"); debugOptionalNumber(input, args, "module_count", "moduleCount")
        case "custom_request" =>
            command = debugRequiredText(input, "command")
            match (input.field("arguments")) {
                case Some(value) => require(value.unifiedKind == UnifiedJsonKind.Object, "tool.invalid_argument"); args = value
                case None => ()
            }
        case "terminate" =>
            command = if (boolean(capabilities, "supportsTerminateRequest")) { "terminate" } else { "disconnect" }
            args.put("restart", jsonBool(false)); args.put("terminateDebuggee", jsonBool(true))
        case "threads" | "loaded_sources" => ()
        case _ => throw PluginFailure("tool.invalid_argument")
    }
    let resume = ["continue", "step_over", "step_in", "step_out", "pause"].contains(action)
    let usesFrame = (action == "evaluate" || action == "scopes") &&
        debugInteger(input, "frame_id", -9223372036854775807) == -9223372036854775807
    let usesInstruction = action == "disassemble" && debugText(input, "memory_reference") == ""
    DapDebugCall(action, timeout, Some(debugRequest(command, args)), waitForStop: resume || action == "launch" || action == "attach",
        refreshFrame: resume || action == "launch" || action == "attach",
        usesContext: resume || action == "stack_trace" || usesFrame || usesInstruction)
}

func debugPolicyInput(value: DapDebugCall): JsonNode {
    let request = value.request.getOrThrow()
    jsonObject([JsonObjectEntry("arguments", field(request, "arguments")), JsonObjectEntry("command", field(request, "command")),
        JsonObjectEntry("following_requests", jsonArray([]))])
}

func debugSnapshotValue(sessionId: String, adapter: String, locations: DapDebugLocations, snapshot: JsonNode): JsonNode {
    let result = ArrayList<JsonObjectEntry>([JsonObjectEntry("id", jsonString(sessionId)), JsonObjectEntry("adapter", jsonString(adapter)),
        JsonObjectEntry("cwd", jsonString(locations.cwd)), JsonObjectEntry("program", jsonString(locations.program))])
    for (name in ["status", "threadId", "frameId", "stopReason", "frameName", "sourcePath", "line", "column",
        "instructionPointerReference", "outputBytes", "outputTruncated"]) { result.add(JsonObjectEntry(name, field(snapshot, name))) }
    match (snapshot.field("exitCode")) { case Some(value) => result.add(JsonObjectEntry("exitCode", value)); case None => () }
    jsonObject(result.toArray())
}

func formatDebugSnapshot(snapshot: JsonNode): String {
    var result = "Session: " + text(snapshot, "id") + "\nStatus: " + text(snapshot, "status") +
        "\nAdapter: " + text(snapshot, "adapter") + "\nCWD: " + text(snapshot, "cwd")
    if (text(snapshot, "program") != "") { result += "\nProgram: " + text(snapshot, "program") }
    if (text(snapshot, "stopReason") != "") { result += "\nStop reason: " + text(snapshot, "stopReason") }
    if (text(snapshot, "sourcePath") != "") {
        result += "\nLocation: " + text(snapshot, "sourcePath") + ":" + number(snapshot, "line").toString() + ":" + number(snapshot, "column").toString()
    }
    result
}
