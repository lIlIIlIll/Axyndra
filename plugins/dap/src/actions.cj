package dap_plugin

import std.collection.*
import yjson.*
import yjson_support.*

func actionNames(): Array<String> { ["launch", "attach", "set_breakpoint", "remove_breakpoint", "set_instruction_breakpoint",
    "remove_instruction_breakpoint", "data_breakpoint_info", "set_data_breakpoint", "remove_data_breakpoint", "continue",
    "step_over", "step_in", "step_out", "pause", "evaluate", "stack_trace", "terminate", "disconnect", "threads", "scopes",
    "variables", "disassemble", "read_memory", "write_memory", "modules", "loaded_sources", "custom_request", "configuration_done"] }
func actionCommand(action: String, input: JsonNode): String {
    match (action) {
        case "set_breakpoint" | "remove_breakpoint" => "setBreakpoints"
        case "set_instruction_breakpoint" | "remove_instruction_breakpoint" => "setInstructionBreakpoints"
        case "data_breakpoint_info" => "dataBreakpointInfo"
        case "set_data_breakpoint" | "remove_data_breakpoint" => "setDataBreakpoints"
        case "step_over" => "next"
        case "step_in" => "stepIn"
        case "step_out" => "stepOut"
        case "stack_trace" => "stackTrace"
        case "read_memory" => "readMemory"
        case "write_memory" => "writeMemory"
        case "loaded_sources" => "loadedSources"
        case "configuration_done" => "configurationDone"
        case "custom_request" => let command = text(input, "command"); require(command != "" && command.size <= 128); command
        case _ => action
    }
}
func actionDirectory(): JsonNode {
    let entries = ArrayList<JsonNode>()
    for (name in actionNames()) {
        let schema = jsonObject([JsonObjectEntry("type", jsonString("object")), JsonObjectEntry("properties", jsonObject([
            JsonObjectEntry("arguments", jsonObject([JsonObjectEntry("type", jsonString("object"))])),
            JsonObjectEntry("command", jsonObject([JsonObjectEntry("type", jsonString("string"))])),
            JsonObjectEntry("following_requests", jsonObject([JsonObjectEntry("type", jsonString("array")), JsonObjectEntry("maxItems", jsonNumber("15"))]))])),
            JsonObjectEntry("required", jsonArray([jsonString("arguments"), jsonString("command"), jsonString("following_requests")])),
            JsonObjectEntry("additionalProperties", jsonBool(false))])
        entries.add(jsonObject([JsonObjectEntry("name", jsonString(name)), JsonObjectEntry("input_schema", schema),
            JsonObjectEntry("description", jsonString("DAP " + name + "; exact raw arguments or legacy item/snake aliases; pure state projection and bounded batch"))]))
    }
    jsonObject([JsonObjectEntry("tools", jsonArray(entries.toArray()))])
}
func actionRequests(name: String, input: JsonNode): Array<JsonNode> {
    exact(input, ["arguments", "command", "following_requests"])
    require(field(input, "arguments").unifiedKind == UnifiedJsonKind.Object && field(input, "command").unifiedKind == UnifiedJsonKind.Text)
    let following = field(input, "following_requests")
    require(following.unifiedKind == UnifiedJsonKind.List && following.items.size <= 15)
    let result = ArrayList<JsonNode>()
    result.add(jsonObject([JsonObjectEntry("command", jsonString(actionCommand(name, input))), JsonObjectEntry("arguments", field(input, "arguments"))]))
    for (request in following.items) {
        exact(request, ["command", "arguments"])
        require(text(request, "command") != "" && text(request, "command").size <= 128 && field(request, "arguments").unifiedKind == UnifiedJsonKind.Object)
        result.add(request)
    }
    result.toArray()
}
