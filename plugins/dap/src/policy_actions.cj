package dap_plugin

import std.collection.*
import std.convert.*
import yjson.*
import yjson_support.*

// Pure compatibility projection. Neither paths nor adapter state grant host I/O.
func policyInteger(value: JsonNode, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case None => fallback
        case Some(item) =>
            require(item.unifiedKind == UnifiedJsonKind.Number, "dap_plugin.argument_invalid")
            let parsed = Int64.parse(item.asNumberText())
            require(parsed.toString() == item.asNumberText(), "dap_plugin.argument_invalid"); parsed
    }
}
func policyString(value: JsonNode, name: String, required!: Bool = false): String {
    match (value.field(name)) {
        case None => require(!required, "dap_plugin.argument_missing"); ""
        case Some(item) =>
            require(item.unifiedKind == UnifiedJsonKind.Text && (!required || item.text != "") && !item.text.contains("\u{0000}"), "dap_plugin.argument_invalid")
            item.text
    }
}
func policyOptionalText(source: JsonNode, target: JsonNode, from: String, to: String): Unit {
    let value = policyString(source, from)
    if (value != "") { target.put(to, jsonString(value)) }
}
func policyBlankBreakpoints(known!: Bool = true): JsonNode {
    jsonObject([JsonObjectEntry("sources", jsonArray([])), JsonObjectEntry("sources_known", jsonBool(known)),
        JsonObjectEntry("functions", jsonArray([])), JsonObjectEntry("functions_known", jsonBool(known)),
        JsonObjectEntry("instructions", jsonArray([])), JsonObjectEntry("instructions_known", jsonBool(known)),
        JsonObjectEntry("data", jsonArray([])), JsonObjectEntry("data_known", jsonBool(known))])
}
func policyBreakpointKey(kind: String, value: JsonNode): String {
    require(value.unifiedKind == UnifiedJsonKind.Object, "dap_plugin.breakpoint_cache_unknown")
    match (kind) {
        case "sources" => let line = policyInteger(value, "line", -1); require(line > 0); line.toString()
        case "functions" => policyString(value, "name", required: true)
        case "instructions" => stringifyUnifiedJson(jsonArray([jsonString(policyString(value, "instructionReference", required: true)),
            jsonNumber(policyInteger(value, "offset", 0).toString())]))
        case "data" => policyString(value, "dataId", required: true)
        case _ => throw PluginFailure("dap_plugin.breakpoint_kind_invalid")
    }
}
func policyCachedList(state: JsonNode, kind: String, path: String): JsonNode {
    if (kind == "sources") {
        for (source in field(state, "sources").items where text(source, "path") == path) { return field(source, "breakpoints") }
    }
    require(boolean(state, kind + "_known"), "dap_plugin.breakpoint_cache_unknown")
    if (kind == "sources") { jsonArray([]) } else { field(state, kind) }
}
func policySetList(state: JsonNode, kind: String, path: String, list: JsonNode): Unit {
    if (kind != "sources") { state.put(kind, list); state.put(kind + "_known", jsonBool(true)); return }
    let sources = ArrayList<JsonNode>(); var found = false
    for (source in field(state, "sources").items) {
        if (text(source, "path") == path) {
            sources.add(jsonObject([JsonObjectEntry("path", jsonString(path)), JsonObjectEntry("breakpoints", list)])); found = true
        } else { sources.add(source) }
    }
    if (!found) { sources.add(jsonObject([JsonObjectEntry("path", jsonString(path)), JsonObjectEntry("breakpoints", list)])) }
    require(sources.size <= 128, "dap_plugin.breakpoint_capacity")
    state.put("sources", jsonArray(sources.toArray()))
}
func policyMutate(state: JsonNode, kind: String, path: String, entry: JsonNode, add: Bool): JsonNode {
    let prior = policyCachedList(state, kind, path); let key = policyBreakpointKey(kind, entry)
    let values = ArrayList<JsonNode>(); var found = false
    for (item in prior.items) {
        if (policyBreakpointKey(kind, item) == key) { found = true; if (add) { values.add(item) } }
        else { values.add(item) }
    }
    // Legacy duplicate add keeps the original condition/hit count unchanged.
    if (add && !found) { values.add(entry) }
    require(values.size <= 512, "dap_plugin.breakpoint_capacity")
    let result = jsonArray(values.toArray()); policySetList(state, kind, path, result); result
}
func policyAbsolutePath(path: String): Bool {
    if (path.startsWith("/")) { return true }
    let bytes = path.toArray()
    bytes.size >= 3 && ((bytes[0] >= b'a' && bytes[0] <= b'z') || (bytes[0] >= b'A' && bytes[0] <= b'Z')) &&
        bytes[1] == b':' && (bytes[2] == b'/' || bytes[2] == b'\\')
}
func policyItemBreakpoint(action: String, input: JsonNode, state: JsonNode, capabilities: JsonNode): ?JsonNode {
    var kind = ""; var command = ""; var path = ""
    var entry = jsonObject([])
    if ((action == "set_breakpoint" || action == "remove_breakpoint") &&
        (input.field("file").isSome() || input.field("function").isSome())) {
        let functionName = policyString(input, "function")
        if (functionName != "") { kind = "functions"; command = "setFunctionBreakpoints"; entry.put("name", jsonString(functionName)) }
        else {
            kind = "sources"; command = "setBreakpoints"; path = policyString(input, "file", required: true)
            // Old relative-path/existence checks need a separate host metadata
            // proof. Do not pretend a plugin can resolve the workspace itself.
            require(policyAbsolutePath(path), "dap_plugin.source_metadata_required")
            let line = policyInteger(input, "line", -1); require(line > 0, "dap_plugin.argument_invalid")
            entry.put("line", jsonNumber(line.toString()))
        }
    } else if ((action == "set_instruction_breakpoint" || action == "remove_instruction_breakpoint") && input.field("instruction_reference").isSome()) {
        require(boolean(capabilities, "supportsInstructionBreakpoints"), "dap_plugin.capability_unsupported")
        kind = "instructions"; command = "setInstructionBreakpoints"
        entry.put("instructionReference", jsonString(policyString(input, "instruction_reference", required: true)))
        entry.put("offset", jsonNumber(policyInteger(input, "offset", 0).toString()))
    } else if ((action == "set_data_breakpoint" || action == "remove_data_breakpoint") && input.field("data_id").isSome()) {
        require(boolean(capabilities, "supportsDataBreakpoints"), "dap_plugin.capability_unsupported")
        kind = "data"; command = "setDataBreakpoints"; entry.put("dataId", jsonString(policyString(input, "data_id", required: true)))
        policyOptionalText(input, entry, "access_type", "accessType")
    } else { return None }
    require(input.field("breakpoints").isNone(), "dap_plugin.ambiguous_breakpoints")
    policyOptionalText(input, entry, "condition", "condition"); policyOptionalText(input, entry, "hit_condition", "hitCondition")
    let arguments = jsonObject([JsonObjectEntry("breakpoints", policyMutate(state, kind, path, entry, action.startsWith("set_")))])
    if (kind == "sources") {
        arguments.put("source", jsonObject([JsonObjectEntry("path", jsonString(path))])); arguments.put("sourceModified", jsonBool(false))
    }
    Some(jsonObject([JsonObjectEntry("command", jsonString(command)), JsonObjectEntry("arguments", arguments)]))
}

// Explicit raw set* requests and following batches also update the local view.
// Unknown or oversized raw shapes remain valid raw protocol requests, but may
// never make an old cached list look authoritative for a later item mutation.
func policyCaptureBreakpoints(state: JsonNode, request: JsonNode): Unit {
    let command = text(request, "command"); let args = field(request, "arguments")
    let kind = match (command) { case "setBreakpoints" => "sources"; case "setFunctionBreakpoints" => "functions"
        case "setInstructionBreakpoints" => "instructions"; case "setDataBreakpoints" => "data"; case _ => return }
    var path = ""
    try {
        if (kind == "sources") { path = policyString(field(args, "source"), "path", required: true) }
        let list = field(args, "breakpoints")
        require(list.unifiedKind == UnifiedJsonKind.List && list.items.size <= 512)
        let keys = HashSet<String>()
        for (item in list.items) { let key = policyBreakpointKey(kind, item); require(!keys.contains(key)); keys.add(key) }
        require(stringifyUnifiedJson(list).size <= 262144)
        policySetList(state, kind, path, list)
    } catch (_: Exception) {
        state.put(kind, jsonArray([])); state.put(kind + "_known", jsonBool(false))
    }
}
func policyRename(args: JsonNode, aliases: Array<(String, String)>): JsonNode {
    let entries = ArrayList<JsonObjectEntry>()
    for (entry in args.fields) {
        var name = entry.name
        for (pair in aliases where pair[0] == entry.name) {
            require(args.field(pair[1]).isNone(), "dap_plugin.ambiguous_argument"); name = pair[1]
        }
        entries.add(JsonObjectEntry(name, entry.value))
    }
    jsonObject(entries.toArray())
}
func policyWithout(args: JsonNode, omitted: String): JsonNode {
    let entries = ArrayList<JsonObjectEntry>()
    for (entry in args.fields where entry.name != omitted) { entries.add(entry) }
    jsonObject(entries.toArray())
}
func policyArguments(action: String, input: JsonNode, context: JsonNode, capabilities: JsonNode): (JsonNode, Bool) {
    let aliases = ArrayList<(String, String)>()
    if (["continue", "step_over", "step_in", "step_out", "pause", "stack_trace"].contains(action)) { aliases.add(("thread_id", "threadId")) }
    if (["evaluate", "scopes", "data_breakpoint_info"].contains(action)) { aliases.add(("frame_id", "frameId")) }
    if (["variables", "data_breakpoint_info"].contains(action)) { aliases.add(("variable_ref", "variablesReference")); aliases.add(("scope_id", "variablesReference")) }
    if (["disassemble", "read_memory", "write_memory"].contains(action)) { aliases.add(("memory_reference", "memoryReference")) }
    if (action == "disassemble") { aliases.add(("instruction_count", "instructionCount")); aliases.add(("instruction_offset", "instructionOffset")); aliases.add(("resolve_symbols", "resolveSymbols")) }
    if (action == "write_memory") { aliases.add(("allow_partial", "allowPartial")) }
    if (action == "modules") { aliases.add(("start_module", "startModule")); aliases.add(("module_count", "moduleCount")) }
    // Legacy variable_ref takes precedence over its older scope_id spelling.
    let source = if (["variables", "data_breakpoint_info"].contains(action) && input.field("variable_ref").isSome()) {
        policyWithout(input, "scope_id") } else { input }
    var args = policyRename(source, aliases.toArray()); var implicit = false
    var legacy = false
    for (pair in aliases where input.field(pair[0]).isSome()) { legacy = true }
    if (legacy) {
        let capability = match (action) {
            case "data_breakpoint_info" => "supportsDataBreakpoints"
            case "disassemble" => "supportsDisassembleRequest"
            case "read_memory" => "supportsReadMemoryRequest"
            case "write_memory" => "supportsWriteMemoryRequest"
            case "modules" => "supportsModulesRequest"
            case _ => "" }
        require(capability == "" || boolean(capabilities, capability), "dap_plugin.capability_unsupported")
        for (name in ["threadId", "frameId", "variablesReference", "instructionCount", "instructionOffset", "startModule", "moduleCount", "count", "offset"]
            where args.field(name).isSome()) { let _ = policyInteger(args, name, -1) }
        if (action == "read_memory") { require(policyString(args, "memoryReference", required: true) != "" && policyInteger(args, "count", -1) >= 0, "dap_plugin.argument_invalid") }
        if (action == "write_memory") { let _ = policyString(args, "memoryReference", required: true); let _ = policyString(args, "data", required: true) }
        if (action == "disassemble") { require(policyInteger(args, "instructionCount", -1) > 0, "dap_plugin.argument_invalid") }
        if (action == "variables") { require(policyInteger(args, "variablesReference", -1) >= 0, "dap_plugin.argument_invalid") }
        if (action == "scopes") { require(policyInteger(args, "frameId", -1) > 0, "dap_plugin.no_frame") }
        if (action == "evaluate" && input.field("frame_id").isSome() && policyInteger(args, "frameId", -1) <= 0) { args = policyWithout(args, "frameId") }
        if (action == "data_breakpoint_info") {
            if (policyInteger(args, "frameId", -1) < 0) { args = policyWithout(args, "frameId") }
            if (policyInteger(args, "variablesReference", -1) < 0) { args = policyWithout(args, "variablesReference") }
        }
        if (action == "disassemble" && args.field("resolveSymbols").isNone()) { args.put("resolveSymbols", jsonBool(false)) }
        if (action == "write_memory" && args.field("allowPartial").isNone()) { args.put("allowPartial", jsonBool(false)) }
        for (name in ["resolveSymbols", "allowPartial"] where args.field(name).isSome()) {
            require(field(args, name).unifiedKind == UnifiedJsonKind.Boolean, "dap_plugin.argument_invalid")
        }
    }
    if (["continue", "step_over", "step_in", "step_out", "pause", "stack_trace"].contains(action) && args.field("threadId").isNone()) {
        let id = number(context, "threadId"); require(id > 0 || action == "pause", "dap_plugin.no_thread")
        if (id > 0) { args.put("threadId", jsonNumber(id.toString())); implicit = true }
    }
    if ((action == "scopes" || action == "evaluate") && args.field("frameId").isNone() && input.field("frame_id").isNone()) {
        let id = number(context, "frameId")
        if (id > 0) { args.put("frameId", jsonNumber(id.toString())); implicit = true }
        else { require(action != "scopes", "dap_plugin.no_frame") }
    }
    if (action == "evaluate" && args.field("context").isNone()) { args.put("context", jsonString("repl")) }
    if (action == "disassemble" && args.field("memoryReference").isNone()) {
        let value = text(context, "instructionPointerReference"); require(value != "", "dap_plugin.no_instruction_pointer")
        args.put("memoryReference", jsonString(value)); implicit = true
    }
    (args, implicit)
}
