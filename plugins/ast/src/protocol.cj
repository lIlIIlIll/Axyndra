package ast_plugin

import process4cj.*
import std.collection.*
import std.env.*
import yjson.*
import yjson_support.*

let AST_IDENTITY_FIELDS = ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind", "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]

func astEnvelope(source: JsonNode, kind: String): ArrayList<JsonObjectEntry> {
    let fields = ArrayList<JsonObjectEntry>([JsonObjectEntry("type", jsonString(kind))])
    for (name in AST_IDENTITY_FIELDS) {
        match (source.field(name)) { case Some(value) => fields.add(JsonObjectEntry(name, value)); case None => () }
    }
    fields
}

func astSameIdentity(left: JsonNode, right: JsonNode): Bool {
    for (name in AST_IDENTITY_FIELDS) {
        if (stringifyUnifiedJson(left.field(name) ?? jsonNull()) != stringifyUnifiedJson(right.field(name) ?? jsonNull())) { return false }
    }
    true
}

func astReady(hello: JsonNode): Unit {
    if (astText(hello, "protocol") != "axyndra-js-host-v2" || astText(hello, "extension_id") != "ast" || astText(hello, "extension_version") != "1.1.0") {
        throw AstPluginFailure("ast.protocol_identity", "unsupported host handshake")
    }
    let fields = astEnvelope(hello, "ready")
    fields.add(JsonObjectEntry("capabilities", hello.field("capabilities") ?? jsonArray([])))
    fields.add(JsonObjectEntry("tools", jsonArray([jsonObject([
        JsonObjectEntry("name", jsonString("ast_grep")),
        JsonObjectEntry("description", jsonString("Search source structurally with AST patterns and uppercase metavariables such as $NAME and $$$ARGS.")),
        JsonObjectEntry("input_schema", parseUnifiedJson("""
        {"type":"object","properties":{"pat":{"type":"string"},"path":{"type":"string"},"skip":{"type":"integer","minimum":0}},"required":["pat"],"additionalProperties":false}
        """))
    ]), jsonObject([
        JsonObjectEntry("name", jsonString("ast_edit")),
        JsonObjectEntry("description", jsonString("Preview structural rewrites as an immutable file plan. Files are unchanged; apply the returned plan_ref and plan_digest with apply_file_plan after review.")),
        JsonObjectEntry("input_schema", parseUnifiedJson("""
        {"type":"object","properties":{"ops":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"object","properties":{"pat":{"type":"string"},"out":{"type":"string"}},"required":["pat","out"],"additionalProperties":false}},"paths":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"string"}}},"required":["ops","paths"],"additionalProperties":false}
        """))
    ])])))
    fields.add(JsonObjectEntry("commands", jsonArray([])))
    fields.add(JsonObjectEntry("hooks", jsonArray([])))
    astWriteJson(jsonObject(fields.toArray()))
}

func astReply(invocation: JsonNode, value: JsonNode, ok: Bool): Unit {
    let fields = astEnvelope(invocation, "result")
    fields.add(JsonObjectEntry("ok", jsonBool(ok)))
    fields.add(JsonObjectEntry("result", value))
    astWriteJson(jsonObject(fields.toArray()))
}

func astRequest(invocation: JsonNode): Unit {
    let editing = astText(invocation, "tool") == "ast_edit"
    if ((!editing && astText(invocation, "tool") != "ast_grep") || astText(invocation, "kind") != "tool") {
        throw AstPluginFailure("ast.tool_unknown", "AST plugin only provides ast_grep and ast_edit")
    }
    let input = if (editing) { validatedAstEditInput(invocation.field("arguments") ?? jsonNull()) }
        else { validatedAstInput(invocation.field("arguments") ?? jsonNull()) }
    let encoded = stringifyUnifiedJson(input)
    if (encoded.size > AST_PLUGIN_INPUT_BYTES) { throw AstPluginFailure("tool.ast_grep_input_limit", "AST input exceeds its limit") }
    let fields = astEnvelope(invocation, "service_request")
    fields.add(JsonObjectEntry("request_id", jsonString("ast-query-1")))
    fields.add(JsonObjectEntry("service", jsonString("process.readonly")))
    fields.add(JsonObjectEntry("arguments", jsonObject([
        JsonObjectEntry("executable", jsonString("bin/ast-plugin")),
        JsonObjectEntry("arguments", astStringArray([if (editing) { "--edit-worker" } else { "--query-worker" }, encoded])),
        JsonObjectEntry("timeout_ms", jsonNumber("30000"))
    ])))
    astWriteJson(jsonObject(fields.toArray()))
}

func astCompleteWorker(invocation: JsonNode, response: JsonNode): ?JsonNode {
    if (!astBool(response, "ok")) {
        let error = response.field("error") ?? jsonObject([])
        astReply(invocation, astFailureValue(astText(error, "code", fallback: "ast.service_failed"), astText(error, "message")), false)
        return None
    }
    let result = response.field("result") ?? jsonObject([])
    if (astText(result, "request_id") != "ast-query-1" || astText(result, "service") != "process.readonly" || astText(result, "receipt_id") == "") {
        throw AstPluginFailure("ast.service_identity", "host service omitted its matching operation receipt")
    }
    let output = result.field("output") ?? jsonObject([])
    if (astBool(output, "timed_out")) { throw AstPluginFailure("tool.ast_grep_timeout", "AST query timed out") }
    if (astBool(output, "truncated")) { throw AstPluginFailure("tool.ast_grep_output_limit", "AST worker output was truncated") }
    let source = astText(output, "stdout")
    if (source.size > AST_PLUGIN_RESULT_BYTES + 1) { throw AstPluginFailure("tool.ast_grep_output_limit", "AST worker output exceeds its limit") }
    let value = parseUnifiedJson(source, maxBytes: AST_PLUGIN_RESULT_BYTES + 1, maxDepth: 32)
    if (value.unifiedKind != UnifiedJsonKind.Object) { throw AstPluginFailure("tool.ast_grep_protocol", "AST worker returned a non-object") }
    let ok = !astBool(result, "is_error") && astInteger(output, "exit_code", -1) == 0 && value.field("error").isNone()
    if (!ok || astText(invocation, "tool") != "ast_edit" || value.field("proposal").isNone()) {
        astReply(invocation, value, ok)
        return None
    }
    let proposal = value.field("proposal").getOrThrow()
    if (stringifyUnifiedJson(proposal).size > AST_PLUGIN_RESULT_BYTES ||
        proposal.field("source").isSome() || astText(proposal, "schema") != "axyndra.file-change-proposal/v1") {
        throw AstPluginFailure("tool.ast_edit_protocol", "AST worker returned an invalid bounded proposal")
    }
    let fields = astEnvelope(invocation, "service_request")
    fields.add(JsonObjectEntry("request_id", jsonString("ast-plan-1")))
    fields.add(JsonObjectEntry("service", jsonString("file.plan.propose")))
    fields.add(JsonObjectEntry("arguments", jsonObject([JsonObjectEntry("proposal", proposal)])))
    astWriteJson(jsonObject(fields.toArray()))
    Some(value)
}

func astCompletePlan(invocation: JsonNode, workerOutput: JsonNode, response: JsonNode): Unit {
    if (!astBool(response, "ok")) {
        let error = response.field("error") ?? jsonObject([])
        astReply(invocation, astFailureValue(astText(error, "code", fallback: "ast.service_failed"), astText(error, "message")), false)
        return
    }
    let result = response.field("result") ?? jsonObject([])
    if (astText(result, "request_id") != "ast-plan-1" || astText(result, "service") != "file.plan.propose" || astText(result, "receipt_id") == "") {
        throw AstPluginFailure("ast.service_identity", "host plan service omitted its matching operation receipt")
    }
    let plan = result.field("output") ?? jsonObject([])
    if (astBool(result, "is_error")) { astReply(invocation, plan, false); return }
    if (astText(plan, "plan_ref") == "" || astText(plan, "plan_digest") == "") {
        throw AstPluginFailure("tool.ast_edit_protocol", "host plan service omitted the immutable plan reference")
    }
    let fields = ArrayList<JsonObjectEntry>()
    for (field in workerOutput.fields where field.name != "proposal" && field.name != "content") { fields.add(field) }
    fields.add(JsonObjectEntry("content", jsonString("Files have not been modified. Review application_plan, then call apply_file_plan with its plan_ref and plan_digest; discard by leaving the plan unapplied.")))
    fields.add(JsonObjectEntry("application_plan", plan))
    let output = jsonObject(fields.toArray())
    if (stringifyUnifiedJson(output).size > AST_PLUGIN_RESULT_BYTES) { throw AstPluginFailure("tool.ast_edit_output_limit", "AST plan reply exceeds its bounded result") }
    astReply(invocation, output, true)
}

func runAstProtocol(): Int64 {
    var initialized = false
    var pending: ?JsonNode = None
    var pendingPlan: ?JsonNode = None
    while (true) {
        let line = match (readLineBounded(getStdIn(), AST_PLUGIN_FRAME_BYTES)) { case Some(value) => value; case None => return 0 }
        let frame = parseUnifiedJson(line, maxBytes: AST_PLUGIN_FRAME_BYTES, maxDepth: 32)
        match (astText(frame, "type")) {
            case "hello" =>
                if (initialized) { return 3 }
                astReady(frame); initialized = true
            case "invoke" =>
                if (!initialized || pending.isSome()) { return 3 }
                try { astRequest(frame); pending = Some(frame) } catch (error: AstPluginFailure) {
                    astReply(frame, astFailureValue(error.code, error.message), false)
                }
            case "service_response" =>
                let invocation = match (pending) { case Some(value) => value; case None => return 3 }
                let requestId = if (pendingPlan.isSome()) { "ast-plan-1" } else { "ast-query-1" }
                if (!astSameIdentity(invocation, frame) || astText(frame, "request_id") != requestId) { return 3 }
                var followup: ?JsonNode = None
                try {
                    match (pendingPlan) {
                        case Some(value) => astCompletePlan(invocation, value, frame)
                        case None => followup = astCompleteWorker(invocation, frame)
                    }
                } catch (error: AstPluginFailure) {
                    astReply(invocation, astFailureValue(error.code, error.message), false)
                } catch (_: Exception) {
                    astReply(invocation, astFailureValue("tool.ast_grep_protocol", "AST worker returned invalid JSON"), false)
                }
                pendingPlan = followup
                if (followup.isNone()) { pending = None }
            case "cancel" =>
                if (!initialized) { return 3 }
                match (pending) { case Some(value) => if (!astSameIdentity(value, frame)) { return 3 }; case None => () }
                astWriteJson(jsonObject(astEnvelope(frame, "cancelled").toArray())); pending = None; pendingPlan = None
            case "shutdown" | "close" => return 0
            case _ => return 3
        }
    }
    0
}
