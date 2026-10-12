package shell_readonly_plugin

import agent_domain.*
import process4cj.*
import std.collection.*
import std.env.*
import yjson.*
import yjson_support.*

func srEmit(value: JsonNode): Unit { let text=stringifyUnifiedJson(value);srRequire(text.size<=SR_FRAME_BYTES);let output=getStdOut();output.write((text+"\n").toArray());output.flush() }
func srEnvelope(frame: JsonNode, kind: String): ArrayList<JsonObjectEntry> {
    let result = ArrayList<JsonObjectEntry>([JsonObjectEntry("type", jsonString(kind))])
    for (name in SR_ID_FIELDS) { match (frame.field(name)) { case Some(value) => result.add(JsonObjectEntry(name, value)); case None => () } }
    result
}
func srReply(frame: JsonNode, value: JsonNode, ok: Bool, transport!:?ReadonlyShellPayloadInput=None): Unit {
    let result=srEnvelope(frame,"result");result.add(JsonObjectEntry("ok",jsonBool(ok)));result.add(JsonObjectEntry("result",value))
    match(transport){case Some(input)=>input.reply(jsonObject(result.toArray()));case None=>srEmit(jsonObject(result.toArray()))} }
func srError(frame: JsonNode, code: String, transport!:?ReadonlyShellPayloadInput=None): Unit {
    srReply(frame,jsonObject([JsonObjectEntry("error",jsonString(code)),JsonObjectEntry("message",jsonString("Readonly Shell operation failed"))]),false,transport:transport) }
func srSame(left: JsonNode, right: JsonNode): Bool {
    for (name in SR_ID_FIELDS where stringifyUnifiedJson(srField(left, name)) != stringifyUnifiedJson(srField(right, name))) { return false }; true }
func srValidInvocation(frame: JsonNode, hello: JsonNode): Bool {
    for (name in ["protocol", "extension_id", "extension_version", "generation"] where
        stringifyUnifiedJson(srField(frame, name)) != stringifyUnifiedJson(srField(hello, name))) { return false }
    for (name in ["id", "thread_id", "run_id", "call_id"]) {
        let found = srField(frame, name)
        if (found.unifiedKind != UnifiedJsonKind.Text || found.text == "" || found.text.size > 1024 || found.text.contains("\u{0000}")) { return false } }
    let operation = srField(frame, "operation_id")
    operation.unifiedKind == UnifiedJsonKind.Text && operation.text.size <= 1024 && !operation.text.contains("\u{0000}") &&
        ((srText(frame, "kind") == "prepare") == (operation.text == "")) && srInteger(frame, "epoch") > 0 && srText(frame, "command_id") == ""
}
func srReady(hello: JsonNode): Unit {
    srRequire(srText(hello, "extension_id") == "shell-readonly" && srText(hello, "extension_version") == "1.0.0" &&
        srText(hello, "protocol") == "axyndra-js-host-v2" && srInteger(hello, "generation") > 0)
    let result = srEnvelope(hello, "ready")
    result.add(JsonObjectEntry("capabilities", srField(hello, "capabilities")))
    result.add(JsonObjectEntry("tools", parseUnifiedJson("""
[{"name":"exec","description":"Run a bounded readonly shell in the exact admitted workspace resource view. Long timeouts require the operator finite read-view deadline profile; no writes or network.","input_schema":{"type":"object","properties":{"command":{"type":"string","minLength":1,"maxLength":131072},"timeout":{"type":"integer","minimum":0,"maximum":600},"timeout_ms":{"type":"integer","minimum":1,"maximum":600000},"cwd":{"type":"string"},"env":{"type":"object","additionalProperties":{"type":"string"}},"title":{"type":"string"}},"required":["command"],"additionalProperties":false}}]
""")))
    for (name in ["commands", "hooks"]) { result.add(JsonObjectEntry(name, jsonArray([]))) }
    srEmit(jsonObject(result.toArray()))
}
func srPrepare(frame: JsonNode): Unit {
    let envelope = srField(frame, "arguments")
    srRequire(srExact(envelope, ["schema", "reference"]) && srText(envelope, "schema") == "axyndra.read-view-parameter-input/v1")
    let reference = srField(envelope, "reference")
    srRequire(srExact(reference, ["binding", "input_bytes", "input_sha256", "metadata"]) && srDigest(srText(reference, "input_sha256")) &&
        srInteger(reference, "input_bytes") >= 0 && srInteger(reference, "input_bytes") <= SR_INPUT_BYTES)
    let binding = srField(reference, "binding")
    srRequire(srExact(binding, ["thread_id", "run_id", "epoch", "call_id", "tool_name", "plugin", "contribution", "package_digest", "generation", "configuration_digest", "working_directory"]) &&
        srText(binding, "thread_id") == srText(frame, "thread_id") && srText(binding, "run_id") == srText(frame, "run_id") &&
        stringifyUnifiedJson(srField(binding, "epoch")) == stringifyUnifiedJson(srField(frame, "epoch")) &&
        srText(binding, "call_id") == srText(frame, "call_id") && srText(binding, "plugin") == "axyndra:" + srText(frame, "extension_id") &&
        srText(binding, "contribution") == "exec" && srText(binding, "tool_name") == "plugin.axyndra:shell-readonly.exec" &&
        srText(binding, "generation") == stringifyUnifiedJson(srField(frame, "generation")) &&
        httpServicePackageDigest(srText(binding, "package_digest")) && srDigest(srText(binding, "configuration_digest")) &&
        srField(binding, "working_directory").unifiedKind == UnifiedJsonKind.Text && srRelative(srText(binding, "working_directory")))
    let metadata = srField(reference, "metadata")
    srRequire(srExact(metadata, ["type", "fields"]) && srText(metadata, "type") == "object" && srField(metadata, "fields").unifiedKind == UnifiedJsonKind.List)
    let names = HashSet<String>(); let small = ArrayList<JsonObjectEntry>(); var commandFound = false
    for (entry in srField(metadata, "fields").items) {
        let name = srText(entry, "name"); let node = srField(entry, "node")
        srRequire(srExact(entry, ["name", "node"]) && !names.contains(name) && ["command", "timeout", "timeout_ms", "cwd", "env", "title"].contains(name)); names.add(name)
        if (name == "command") {
            let hasValue = node.field("value").isSome()
            srRequire(srExact(node, if (hasValue) { ["type", "utf8_bytes", "sha256", "has_nul", "value"] } else { ["type", "utf8_bytes", "sha256", "has_nul"] }) &&
                srText(node, "type") == "text" && srInteger(node, "utf8_bytes") >= 1 && srInteger(node, "utf8_bytes") <= SR_COMMAND_BYTES &&
                srDigest(srText(node, "sha256")) && srField(node, "has_nul").unifiedKind == UnifiedJsonKind.Boolean && !srBool(node, "has_nul"))
            if (hasValue) {
                let authored = srField(node, "value")
                srRequire(authored.unifiedKind == UnifiedJsonKind.Text && authored.text.size == srInteger(node, "utf8_bytes") &&
                    modelPolicySha256Text(authored.text) == srText(node, "sha256") && stringifyUnifiedJson(authored).size <= 8192 && !srReadonlyViolation(authored.text)) }
            else { srRequire(srInteger(node, "utf8_bytes") >= 1366) }
            commandFound = true
        } else if (name == "timeout" || name == "timeout_ms") {
            srRequire(srExact(node, ["type", "utf8_bytes", "sha256", "has_nul", "value"]) && srText(node, "type") == "number" &&
                srField(node, "value").unifiedKind == UnifiedJsonKind.Number && srDigest(srText(node, "sha256")))
            small.add(JsonObjectEntry(name, srField(node, "value")))
        } else {
            // cwd/env/title grammar is checked against the full exact captured
            // input by the isolated worker; no omitted value authorizes a path.
            srRequire(srField(node, "type").unifiedKind == UnifiedJsonKind.Text) }
    }
    srRequire(commandFound)
    let requested = srTimeout(jsonObject(small.toArray()))
    let workerDeadline = if (requested > 599000) { 600000 } else { requested + 1000 }
    let request = jsonObject([JsonObjectEntry("executable", jsonString("bin/shell-readonly-plugin")),
        JsonObjectEntry("arguments", jsonArray([jsonString("--view-worker-file"), jsonString(srText(binding, "working_directory"))])), JsonObjectEntry("timeout_ms", jsonNumber(workerDeadline.toString())),
        JsonObjectEntry("input_reference", reference)])
    srReply(frame, jsonObject([JsonObjectEntry("intents", jsonArray([jsonObject([
        JsonObjectEntry("id", jsonString("readonly-shell-1")), JsonObjectEntry("request", request),
        JsonObjectEntry("resources", jsonArray([jsonObject([JsonObjectEntry("source", jsonString(".")), JsonObjectEntry("path", jsonString(".")), JsonObjectEntry("mode", jsonString("directory"))])]))])]))]), true)
}
func srRunProtocol(): Int64 {
    var hello: ?JsonNode = None; var pending: ?JsonNode = None
    let ids = HashSet<String>()
    let input=ReadonlyShellPayloadInput()
    try {while (true) {
        let frame=match(input.frame()){case Some(value)=>value;case None=>return 0}
        match (srText(frame, "type")) {
            case "hello" => if (hello.isSome()) { return 3 }; srReady(frame); hello = Some(frame)
            case "invoke" =>
                if (hello.isNone() || pending.isSome() || !srValidInvocation(frame, hello.getOrThrow()) ||
                    ids.contains(srText(frame, "id")) || ids.size >= 4096 || srText(frame, "tool") != "exec") { return 3 }
                ids.add(srText(frame, "id"))
                try {
                    if (srText(frame, "kind") == "prepare") { srPrepare(frame) }
                    else {
                        srRequire(srText(frame,"kind")=="tool");input.begin(hello.getOrThrow(),frame);let _=srValidate(srField(frame,"arguments"))
                        let request = srEnvelope(frame, "service_request")
                        request.add(JsonObjectEntry("request_id", jsonString("readonly-shell-1"))); request.add(JsonObjectEntry("service", jsonString("process.readview")))
                        request.add(JsonObjectEntry("arguments", jsonObject([JsonObjectEntry("intent_id", jsonString("readonly-shell-1"))])))
                        srEmit(jsonObject(request.toArray())); pending = Some(frame) }
                } catch (error: ReadonlyShellFailure) { srError(frame,error.code,transport:Some(input)) }
            case "service_response" =>
                if (pending.isNone() || !srSame(pending.getOrThrow(), frame) || srText(frame, "request_id") != "readonly-shell-1") { return 3 }
                let invocation = pending.getOrThrow(); pending = None
                if(!srBool(frame,"ok")){srError(invocation,srText(srField(frame,"error"),"code"),transport:Some(input));input.reset();continue}
                let result = srField(frame, "result"); let output = srField(result, "output")
                srRequire(srText(result, "request_id") == "readonly-shell-1" && srText(result, "service") == "process.readview" && srText(result, "receipt_id") != "")
                srRequire(!srBool(output, "timed_out") && !srBool(output, "truncated") && srInteger(output, "exit_code") == 0)
                let body=input.decodeWorker(srText(output,"stdout"))
                srReply(invocation,body,!srBool(result,"is_error") && srInteger(body,"exit_code")==0,transport:Some(input))
            case "shutdown" => if (pending.isSome()) { return 3 }; return 0
            case _ => return 3
        }
        if(pending.isNone()){input.reset()}
    }}finally{input.close()}
    0
}
