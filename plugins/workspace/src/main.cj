package workspace_plugin

import agent_domain.*
import std.env.*
import process4cj.*
import yjson.*
import yjson_support.*

var workspaceHostReadView = false

let WORKSPACE_FRAME_BYTES: Int64 = 262144
let WORKSPACE_INPUT_BYTES: Int64 = 16384
let WORKSPACE_WRITE_CONTENT_BYTES: Int64 = 32768
let WORKSPACE_WRITE_INPUT_BYTES: Int64 = 229376

func workspaceInputLimit(tool: String): Int64 {
    if (tool == "write") { WORKSPACE_WRITE_INPUT_BYTES } else { WORKSPACE_INPUT_BYTES }
}
let WORKSPACE_RESULT_BYTES: Int64 = 65536
func workspaceResultLimit(tool: String): Int64 {
    if (tool == "read" && workspacePayloadProfile.isSome()) { return workspacePayloadProfile.getOrThrow().maxResultBytes }
    if (tool == "write") { 200704 } else { WORKSPACE_RESULT_BYTES }
}

class WorkspaceFailure <: Exception {
    let code: String
    init(code: String, message: String) { super(message); this.code = code }
}

func wsError(code: String, message: String): JsonNode {
    jsonObject([JsonObjectEntry("error", jsonString(if (code.size <= 128) { code } else { "workspace.failed" })),
        JsonObjectEntry("message", jsonString(if (message.size <= 4096) { message } else { "Workspace diagnostic exceeds its limit" }))])
}

func wsText(value: JsonNode, key: String, fallback!: String = ""): String {
    let field = value.field(key) ?? jsonNull()
    if (field.unifiedKind == UnifiedJsonKind.Text) { field.text } else { fallback }
}

func wsBool(value: JsonNode, key: String, fallback!: Bool = false): Bool {
    let field = value.field(key) ?? jsonNull()
    if (field.unifiedKind == UnifiedJsonKind.Boolean) { field.asBool() } else { fallback }
}

func wsEmit(value: JsonNode): Unit {
    let stream = getStdOut()
    stream.write((stringifyUnifiedJson(value) + "\n").toArray()); stream.flush()
}

func wsWorker(arguments: Array<String>): Int64 {
    try {
        let profiled = arguments.size == 5 && arguments[1] == "--view-worker-profile" && arguments[2] == "read"
        let frozenFile = arguments.size == 3 && arguments[1] == "--view-worker-file"
        if ((!frozenFile && !profiled && arguments.size != 4) || arguments.size < 3) {
            throw WorkspaceFailure("workspace.input_limit", "Worker requires one bounded frozen JSON object") }
        if (profiled) {
            workspacePayloadProfile = ordinaryToolPayloadLimitsFromValue(parseUnifiedJson(arguments[4], maxBytes: 4096))
            if (workspacePayloadProfile.isNone() || workspacePayloadProfile.getOrThrow().contribution != arguments[2]) {
                throw WorkspaceFailure("workspace.payload_profile", "Worker profile differs from its prepared contribution") }
        }
        if (profiled) { workspaceInvocationPayment = Some(workspacePayloadOwners.acquire(1)) }
        let encoded = if (frozenFile) {
            wsReadText(getWorkingDirectory().toString(), ".axyndra-worker-input.json", maximumBytes: WORKSPACE_WRITE_INPUT_BYTES)
        } else { arguments[3] }
        if (encoded.size > workspaceInputLimit(arguments[2])) { throw WorkspaceFailure("workspace.input_limit", "Worker input exceeds its bound") }
        let input = parseUnifiedJson(encoded, maxBytes: workspaceInputLimit(arguments[2]), maxDepth: 16)
        let output = if (workspaceHostReadView && arguments[2] == "read") {
            wsReadMapped(input, getWorkingDirectory().toString(), "target")
        } else { runWorkspaceTool(arguments[2], input, getWorkingDirectory().toString(), arguments[0]) }
        if (stringifyUnifiedJson(output).size > workspaceResultLimit(arguments[2])) {
            throw WorkspaceFailure("workspace.output_limit", "Result or proposal exceeds 64 KiB; narrow the requested range or edit")
        }
        wsEmit(output); 0
    } catch (error: WorkspaceFailure) { wsEmit(wsError(error.code, error.message)); 2 }
    catch (_: Exception) { wsEmit(wsError("workspace.failed", "Workspace operation failed")); 2 }
    finally { workspaceReleasePayload() }
}

main(): Int64 {
    let arguments = getCommandLine()
    if (arguments.size > 1 && ["--view-worker", "--view-worker-file", "--view-worker-profile"].contains(arguments[1])) { workspaceHostReadView = true; return wsWorker(arguments) }
    if (arguments.size > 1 && arguments[1] == "--worker") { return wsWorker(arguments) }
    if (arguments.size != 1) { return 2 }
    try { runWorkspaceProtocol() } catch (_: Exception) { 3 }
}
