package workspace_plugin

import process4cj.*
import std.collection.*
import std.env.*
import yjson.*
import yjson_support.*

let WS_IDENTITY_FIELDS = ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind", "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]

func workspaceEnvelope(source: JsonNode, kind: String): ArrayList<JsonObjectEntry> {
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry("type", jsonString(kind))])
    for (name in WS_IDENTITY_FIELDS) {
        match (source.field(name)) { case Some(value) => fields.add(JsonObjectEntry(name, value)); case None => () }
    }
    fields
}

func workspaceSameIdentity(left: JsonNode, right: JsonNode): Bool {
    for (name in WS_IDENTITY_FIELDS) {
        if (stringifyUnifiedJson(left.field(name) ?? jsonNull()) != stringifyUnifiedJson(right.field(name) ?? jsonNull())) { return false }
    }
    true
}

func workspaceValidInvocation(frame: JsonNode, hello: JsonNode): Bool {
    for (name in ["protocol", "extension_id", "extension_version", "generation"]) {
        if (stringifyUnifiedJson(frame.field(name) ?? jsonNull()) != stringifyUnifiedJson(hello.field(name) ?? jsonNull())) { return false }
    }
    for (name in ["id", "thread_id", "run_id", "call_id"]) {
        let value = frame.field(name) ?? jsonNull()
        if (value.unifiedKind != UnifiedJsonKind.Text || value.text == "" || value.text.size > 1024 || value.text.contains("\u{0000}")) { return false }
    }
    let operation = frame.field("operation_id") ?? jsonNull()
    if (operation.unifiedKind != UnifiedJsonKind.Text || operation.text.size > 1024 || operation.text.contains("\u{0000}") ||
        ((wsText(frame, "kind") == "prepare") != (operation.text == ""))) { return false }
    wsInteger(frame, "epoch", 0) > 0 && wsText(frame, "command_id") == ""
}

func workspaceReady(hello: JsonNode): Unit {
    if (wsInteger(hello, "generation", 0) < 1 || wsText(hello, "protocol") != "axyndra-js-host-v2" || wsText(hello, "extension_id") != "workspace" || wsText(hello, "extension_version") != "1.0.0") {
        throw WorkspaceFailure("workspace.protocol_identity", "unsupported host handshake")
    }
    let fields = workspaceEnvelope(hello, "ready")
    fields.add(JsonObjectEntry("capabilities", hello.field("capabilities") ?? jsonArray([])))
    fields.add(JsonObjectEntry("tools", parseUnifiedJson("""
[{"name":"read","description":"Read workspace UTF-8 files with full-file hashline anchors, line ranges or :raw, or list approved directories. Special file paths require exact host approval.","input_schema":{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":["integer","null"]},"limit":{"type":["integer","null"]},"destination":{"type":"string"}},"required":["path"],"additionalProperties":false}},{"name":"grep","description":"Search workspace contents with a regex, case/count controls and semicolon-separated paths or glob filters.","input_schema":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"case":{"type":"boolean"},"count":{"type":"boolean"},"gitignore":{"type":"boolean"},"skip":{"type":"integer","minimum":0}},"required":["pattern"],"additionalProperties":false}},{"name":"glob","description":"Find sorted workspace paths using a glob pattern and explicit hidden/gitignore controls.","input_schema":{"type":"object","properties":{"pattern":{"type":"string"},"hidden":{"type":"boolean"},"gitignore":{"type":"boolean"},"limit":{"type":"integer","minimum":1}},"required":["pattern"],"additionalProperties":false}},{"name":"edit","description":"Propose hashline SWAP, DEL and INS changes with stale-anchor checks; review and apply the returned immutable file plan separately.","input_schema":{"type":"object","properties":{"input":{"type":"string"}},"required":["input"],"additionalProperties":false}},{"name":"write","description":"Propose creation or replacement of a UTF-8 workspace file; no file changes occur until apply_file_plan is approved.","input_schema":{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"],"additionalProperties":false}}]
    """)))
    fields.add(JsonObjectEntry("commands", jsonArray([])))
    fields.add(JsonObjectEntry("hooks", jsonArray([])))
    wsEmit(jsonObject(fields.toArray()))
}

func workspaceReply(invocation: JsonNode, value: JsonNode, ok: Bool): Unit {
    let fields = workspaceEnvelope(invocation, "result")
    fields.add(JsonObjectEntry("ok", jsonBool(ok)))
    fields.add(JsonObjectEntry("result", value))
    wsEmit(jsonObject(fields.toArray()))
}

func workspaceRequest(invocation: JsonNode): Unit {
    if (wsText(invocation, "kind") != "tool") { throw WorkspaceFailure("workspace.tool_unknown", "Only Tool invocations are accepted") }
    let input = wsValidate(wsText(invocation, "tool"), invocation.field("arguments") ?? jsonNull())
    let encoded = stringifyUnifiedJson(input)
    if (encoded.size > workspaceInputLimit(wsText(invocation, "tool"))) { throw WorkspaceFailure("workspace.input_limit", "Workspace input exceeds its limit") }
    let fields = workspaceEnvelope(invocation, "service_request")
    fields.add(JsonObjectEntry("request_id", jsonString("workspace-query-1")))
    fields.add(JsonObjectEntry("service", jsonString("process.readview")))
    fields.add(JsonObjectEntry("arguments", jsonObject([
        JsonObjectEntry("intent_id", jsonString("workspace-query-1"))
    ])))
    wsEmit(jsonObject(fields.toArray()))
}

func workspaceCompleteWorker(invocation: JsonNode, response: JsonNode): ?JsonNode {
    if (!wsBool(response, "ok")) {
        let error = response.field("error") ?? jsonObject([])
        workspaceReply(invocation, wsError(wsText(error, "code", fallback: "workspace.service_failed"), wsText(error, "message")), false)
        return None
    }
    let result = response.field("result") ?? jsonObject([])
    if (wsText(result, "request_id") != "workspace-query-1" || wsText(result, "service") != "process.readview" || wsText(result, "receipt_id") == "") {
        throw WorkspaceFailure("workspace.service_identity", "host service omitted its matching operation receipt")
    }
    let output = result.field("output") ?? jsonObject([])
    if (wsBool(output, "timed_out")) { throw WorkspaceFailure("workspace.timeout", "Workspace query timed out") }
    if (wsBool(output, "truncated")) { throw WorkspaceFailure("workspace.output_limit", "Workspace worker output was truncated") }
    let source = wsText(output, "stdout")
    if (source.size > workspaceResultLimit(wsText(invocation, "tool")) + 1) { throw WorkspaceFailure("workspace.output_limit", "Workspace worker output exceeds its limit") }
    let value = parseUnifiedJson(source, maxBytes: workspaceResultLimit(wsText(invocation, "tool")) + 1, maxDepth: 32)
    if (value.unifiedKind != UnifiedJsonKind.Object) { throw WorkspaceFailure("workspace.protocol", "Workspace worker returned a non-object") }
    let ok = !wsBool(result, "is_error") && wsInteger(output, "exit_code", -1) == 0 && value.field("error").isNone()
    if (!ok || !["edit", "write"].contains(wsText(invocation, "tool")) || value.field("proposal").isNone()) {
        workspaceReply(invocation, value, ok)
        return None
    }
    let proposal = value.field("proposal").getOrThrow()
    if (stringifyUnifiedJson(proposal).size > workspaceResultLimit(wsText(invocation, "tool")) ||
        proposal.field("source").isSome() || wsText(proposal, "schema") != "axyndra.file-change-proposal/v1") {
        throw WorkspaceFailure("workspace.protocol", "Workspace worker returned an invalid bounded proposal")
    }
    let fields = workspaceEnvelope(invocation, "service_request")
    fields.add(JsonObjectEntry("request_id", jsonString("workspace-plan-1")))
    fields.add(JsonObjectEntry("service", jsonString("file.plan.propose")))
    fields.add(JsonObjectEntry("arguments", jsonObject([JsonObjectEntry("proposal", proposal)])))
    wsEmit(jsonObject(fields.toArray()))
    Some(value)
}

func workspaceCompletePlan(invocation: JsonNode, workerOutput: JsonNode, response: JsonNode): Unit {
    if (!wsBool(response, "ok")) {
        let error = response.field("error") ?? jsonObject([])
        workspaceReply(invocation, wsError(wsText(error, "code", fallback: "workspace.service_failed"), wsText(error, "message")), false)
        return
    }
    let result = response.field("result") ?? jsonObject([])
    if (wsText(result, "request_id") != "workspace-plan-1" || wsText(result, "service") != "file.plan.propose" || wsText(result, "receipt_id") == "") {
        throw WorkspaceFailure("workspace.service_identity", "host plan service omitted its matching operation receipt")
    }
    let plan = result.field("output") ?? jsonObject([])
    if (wsBool(result, "is_error")) { workspaceReply(invocation, plan, false); return }
    if (wsText(plan, "plan_ref") == "" || wsText(plan, "plan_digest") == "") {
        throw WorkspaceFailure("workspace.protocol", "host plan service omitted the immutable plan reference")
    }
    let fields = ArrayList<JsonObjectEntry>()
    for (field in workerOutput.fields where field.name != "proposal" && field.name != "content") { fields.add(field) }
    fields.add(JsonObjectEntry("content", jsonString("Files have not been modified. Review application_plan, then call apply_file_plan with its plan_ref and plan_digest; discard by leaving the plan unapplied.")))
    fields.add(JsonObjectEntry("application_plan", plan))
    let output = jsonObject(fields.toArray())
    if (stringifyUnifiedJson(output).size > WORKSPACE_RESULT_BYTES) { throw WorkspaceFailure("workspace.output_limit", "Workspace plan reply exceeds its bounded result") }
    workspaceReply(invocation, output, true)
}

func runWorkspaceProtocol(): Int64 {
    var initialized = false
    var helloIdentity: ?JsonNode = None
    let usedIds = ArrayList<String>()
    var pending: ?JsonNode = None
    var pendingPlan: ?JsonNode = None
    while (true) {
        let line = match (readLineBounded(getStdIn(), WORKSPACE_FRAME_BYTES)) { case Some(value) => value; case None => return 0 }
        let frame = parseUnifiedJson(line, maxBytes: WORKSPACE_FRAME_BYTES, maxDepth: 32)
        match (wsText(frame, "type")) {
            case "hello" =>
                if (initialized) { return 3 }
                workspaceReady(frame); initialized = true; helloIdentity = Some(frame)
            case "invoke" =>
                if (!initialized || pending.isSome()) { return 3 }
                let hello = helloIdentity.getOrThrow()
                if (!workspaceValidInvocation(frame, hello) || usedIds.contains(wsText(frame, "id")) || usedIds.size >= 4096) { return 3 }
                usedIds.add(wsText(frame, "id"))
                try {
                    if (wsText(frame, "kind") == "prepare") { workspacePrepare(frame) }
                    else { workspaceRequest(frame); pending = Some(frame) }
                } catch (error: WorkspaceFailure) {
                    workspaceReply(frame, wsError(error.code, error.message), false)
                }
            case "service_response" =>
                let invocation = match (pending) { case Some(value) => value; case None => return 3 }
                let requestId = if (pendingPlan.isSome()) { "workspace-plan-1" } else { "workspace-query-1" }
                if (!workspaceSameIdentity(invocation, frame) || wsText(frame, "request_id") != requestId) { return 3 }
                var followup: ?JsonNode = None
                try {
                    match (pendingPlan) {
                        case Some(value) => workspaceCompletePlan(invocation, value, frame)
                        case None => followup = workspaceCompleteWorker(invocation, frame)
                    }
                } catch (error: WorkspaceFailure) {
                    workspaceReply(invocation, wsError(error.code, error.message), false)
                } catch (_: Exception) {
                    workspaceReply(invocation, wsError("workspace.protocol", "Workspace worker returned invalid JSON"), false)
                }
                pendingPlan = followup
                if (followup.isNone()) { pending = None }
            case "cancel" =>
                if (!initialized) { return 3 }
                match (pending) { case Some(value) => if (!workspaceSameIdentity(value, frame)) { return 3 }; case None => return 3 }
                wsEmit(jsonObject(workspaceEnvelope(frame, "cancelled").toArray())); pending = None; pendingPlan = None
            case "shutdown" | "close" => return 0
            case _ => return 3
        }
    }
    0
}
