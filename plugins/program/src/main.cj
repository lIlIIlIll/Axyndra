package program_plugin

import agent_domain.*
import program_language.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.env.*
import std.io.*
import std.time.*
import yjson.*
import yjson_support.*

let PROGRAM_FRAME_BYTES: Int64 = 262144
let programPayloadOwner = LogicalJsonOwnerBudget()
let programPayloadProcess = LogicalJsonProcessBudget(programPayloadOwner)
let PROGRAM_IDENTITY = ["protocol", "extension_id", "extension_version", "generation", "id", "tool", "kind",
    "command_id", "thread_id", "run_id", "epoch", "operation_id", "call_id"]

class ProgramProtocolFailure <: Exception { init(message: String) { super(message) } }
class ProgramCancelled <: Exception { init() { super("program invocation cancelled") } }
func require(value: Bool): Unit { if (!value) { throw ProgramProtocolFailure("invalid Program protocol frame") } }
func stringField(value: JsonNode, key: String): String {
    let found = value.field(key) ?? jsonNull(); if (found.unifiedKind == UnifiedJsonKind.Text) { found.text } else { "" }
}
func emit(value: JsonNode): Unit {
    let text = stringifyUnifiedJson(value); require(text.size <= PROGRAM_FRAME_BYTES)
    let output = getStdOut(); output.write((text + "\n").toArray()); output.flush()
}
func envelope(invocation: JsonNode, typeName: String): ArrayList<JsonObjectEntry> {
    let entries = ArrayList<JsonObjectEntry>([JsonObjectEntry("type", jsonString(typeName))])
    for (key in PROGRAM_IDENTITY) { match (invocation.field(key)) { case Some(value) => entries.add(JsonObjectEntry(key, value)); case None => () } }
    entries
}
func sameIdentity(left: JsonNode, right: JsonNode): Bool {
    for (key in PROGRAM_IDENTITY where stringifyUnifiedJson(left.field(key) ?? jsonNull()) != stringifyUnifiedJson(right.field(key) ?? jsonNull())) { return false }
    true
}
func reply(invocation: JsonNode, output: JsonNode, ok: Bool, window!: ?ProgramPayloadWindow = None): Unit {
    let fields = envelope(invocation, "result"); fields.add(JsonObjectEntry("ok", jsonBool(ok))); fields.add(JsonObjectEntry("result", output))
    match (window) { case Some(value) => value.reply(jsonObject(fields.toArray())); case None => emit(jsonObject(fields.toArray())) }
}
func errorValue(code: String, message: String): JsonNode {
    jsonObject([JsonObjectEntry("error", jsonString(code)), JsonObjectEntry("message", jsonString(message))])
}

// One borrowed stdin reader, bounded readiness waits, never close fd 0.
class ProgramInput {
    private var bytes: Array<Byte> = []
    private var offset: Int64 = 0
    private let fixed = programPayloadOwner.acquireFixedBuffer(8192)
    var charge = programPayloadProcess.acquire(PROGRAM_FRAME_BYTES)
    private var retainedBytes: Int64 = 0
    private var retainedNodes: Int64 = 0
    func retain(bytes: Int64, nodes: Int64): Unit { retainedBytes = bytes; retainedNodes = nodes }
    func resetCharge(): Unit { charge.close(); retainedBytes = 0; retainedNodes = 0; charge = programPayloadProcess.acquire(PROGRAM_FRAME_BYTES) }
    func close(): Unit { charge.close(); fixed.close() }
    func frame(): ?JsonNode {
        let line = ArrayList<Byte>()
        while (true) {
            if (offset == bytes.size) {
                if (!waitReadableFd(0, 10)) { sleep(Duration.millisecond); continue }
                match (readFdChunk(0, maxBytes: 8192)) {
                    case Some(value) => bytes = value; offset = 0
                    case None => require(line.isEmpty()); return None }
            }
            let byte = bytes[offset]; offset++
            if (byte == 10u8) {
                let source = String.fromUtf8(line.toArray())
                charge.ensureDecoded(source.size + retainedBytes, logicalJsonNodeCount(source) + retainedNodes)
                return Some(parseUnifiedJson(source, maxBytes: PROGRAM_FRAME_BYTES, maxDepth: 32))
            }
            require(line.size < PROGRAM_FRAME_BYTES); line.add(byte)
        }
        None
    }
}

class ProgramClock <: ToolProgramClock {
    private let started = MonoTime.now()
    private var serviceMillis: Int64 = 0
    func addService(duration: Int64): Unit { serviceMillis += duration }
    public func wallElapsedMillis(): UInt64 { UInt64((MonoTime.now() - started).toMilliseconds()) }
    public func computeElapsedMillis(): UInt64 {
        let wall = (MonoTime.now() - started).toMilliseconds(); UInt64(if (wall > serviceMillis) { wall - serviceMillis } else { 0 })
    }
}

class ProgramHost <: ProgramSubOperationExecutor {
    // Program owns business detection; the Host owns the exact live Root,
    // operator opt-in, Derived preview, stored origin and durable Receipt.
    func proposeCompletedValue(value: JsonNode): Result<JsonNode> {
        if(value.unifiedKind!=UnifiedJsonKind.Object || value.field("application_plan").isNone()){return Result.Ok(value)}
        calls++
        if(calls>32){return Result.Err(AgentError(AgentErrorKind.InvalidInput,"tool_program.subcall_limit","program exceeds its bounded service count"))}
        let id="program-plan-"+calls.toString()
        let fields=envelope(invocation,"service_request")
        fields.add(JsonObjectEntry("request_id",jsonString(id)))
        fields.add(JsonObjectEntry("service",jsonString("file.plan.propose")))
        fields.add(JsonObjectEntry("arguments",jsonObject([JsonObjectEntry("proposal",value.field("application_plan").getOrThrow())])))
        window.request(calls+1,jsonObject(fields.toArray()))
        emittedPreviewRequests++
        let started=MonoTime.now()
        try{
            let response=window.response(calls+1,id);require(sameIdentity(response,invocation))
            if(stringField(response,"type")=="cancel"){
                emit(jsonObject(envelope(invocation,"cancelled").toArray()));throw ProgramCancelled()}
            require(stringField(response,"type")=="service_response" && stringField(response,"request_id")==id)
            let ok=response.field("ok").getOrThrow();require(ok.unifiedKind==UnifiedJsonKind.Boolean)
            if(!ok.asBool()){
                let error=response.field("error") ?? jsonObject([])
                return Result.Err(AgentError(AgentErrorKind.PermissionDenied,stringField(error,"code"),"host refused the exact preview child"))}
            let child=response.field("result").getOrThrow()
            if(stringField(child,"receipt_id")=="" || stringField(child,"request_id")!=id ||
                stringField(child,"service")!="file.plan.propose"){
                uncertain=true
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,"tool_program.receipt_missing","preview has no matching durable Receipt"))}
            let isError=child.field("is_error").getOrThrow();require(isError.unifiedKind==UnifiedJsonKind.Boolean)
            if(isError.asBool()){
                return Result.Err(AgentError(AgentErrorKind.InvalidInput,"tool_program.plan_proposal_failed","actual preview child did not succeed"))}
            let sanitized=ArrayList<JsonObjectEntry>()
            for(field in value.fields){sanitized.add(JsonObjectEntry(field.name,
                if(field.name=="application_plan"){child.field("output").getOrThrow()}else{field.value}))}
            Result.Ok(jsonObject(sanitized.toArray()))
        }finally{clock.addService((MonoTime.now()-started).toMilliseconds())}
    }
    private let invocation: JsonNode; private let input: ProgramInput; private let clock: ProgramClock
    private let window: ProgramPayloadWindow
    private var calls: Int64 = 0
    private var emittedPreviewRequests: Int64 = 0
    func additionalEmittedServiceRequests(): Int64 { emittedPreviewRequests }
    var uncertain: Bool = false
    init(invocation: JsonNode, input: ProgramInput, clock: ProgramClock, window: ProgramPayloadWindow) { this.invocation = invocation; this.input = input; this.clock = clock; this.window = window }
    public func isReadOnly(call: ToolCall): Bool { channelIntentIdentifier(call.name) }
    public func invoke(call: ToolCall): Result<ToolInvocationResult> {
        calls++
        if (calls > 32) { return Result.Err(AgentError(AgentErrorKind.InvalidInput, "tool_program.subcall_limit", "program exceeds the Product subcall limit")) }
        let id = "program-call-" + calls.toString()
        let fields = envelope(invocation, "service_request")
        fields.add(JsonObjectEntry("request_id", jsonString(id))); fields.add(JsonObjectEntry("service", jsonString("tool.readonly")))
        fields.add(JsonObjectEntry("arguments", jsonObject([JsonObjectEntry("tool", jsonString(call.name)), JsonObjectEntry("input", call.arguments)])))
        window.request(calls + 1, jsonObject(fields.toArray()))
        let started = MonoTime.now()
        try {
            let response = window.response(calls + 1, id); require(sameIdentity(response, invocation))
            if (stringField(response, "type") == "cancel") {
                emit(jsonObject(envelope(invocation, "cancelled").toArray())); throw ProgramCancelled() }
            require(stringField(response, "type") == "service_response" && stringField(response, "request_id") == id)
            let ok = response.field("ok").getOrThrow(); require(ok.unifiedKind == UnifiedJsonKind.Boolean)
            if (!ok.asBool()) {
                let error = response.field("error") ?? jsonObject([])
                return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                    stringField(error, "code"), "host refused the exact readonly subcall")) }
            let result = response.field("result").getOrThrow()
            if (stringField(result, "receipt_id") == "" || stringField(result, "request_id") != id || stringField(result, "service") != "tool.readonly") {
                uncertain = true
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "tool_program.receipt_missing", "readonly child has no matching durable Receipt")) }
            let isError = result.field("is_error").getOrThrow(); require(isError.unifiedKind == UnifiedJsonKind.Boolean)
            Result.Ok(ToolInvocationResult.Completed(ToolResult(call.callId, result.field("output").getOrThrow(),
                isError: isError.asBool(), receiptId: stringField(result, "receipt_id"))))
        } finally { clock.addService((MonoTime.now() - started).toMilliseconds()) }
    }
}

func ready(hello: JsonNode): Unit {
    require(stringField(hello, "protocol") == "axyndra-js-host-v2" && stringField(hello, "extension_id") == "program" &&
        stringField(hello, "extension_version") == "1.0.0")
    let fields = envelope(hello, "ready")
    fields.add(JsonObjectEntry("capabilities", hello.field("capabilities") ?? jsonArray([])))
    fields.add(JsonObjectEntry("tools", parseUnifiedJson("""
[{"name":"run","input_attachment":{"field":"code","max_bytes":262144},"description":"Execute bounded readonly tool composition using the host operator's exact contribution aliases.","input_schema":{"type":"object","properties":{"code":{"type":"string"}},"required":["code"],"additionalProperties":false}}]
""")))
    fields.add(JsonObjectEntry("commands", jsonArray([]))); fields.add(JsonObjectEntry("hooks", jsonArray([])))
    match (hello.field("ordinary_tool_payload")) { case Some(value) =>
        if (value.unifiedKind != UnifiedJsonKind.Null) { require(validOrdinaryToolPayloadOffer(value)); fields.add(JsonObjectEntry("ordinary_tool_payload", value)) }; case None => () }
    emit(jsonObject(fields.toArray()))
}

main(): Int64 {
    let input = ProgramInput(); let used = HashSet<String>()
    try {
        let hello = input.frame().getOrThrow(); require(stringField(hello, "type") == "hello"); ready(hello)
        while (true) {
            let first = match (input.frame()) { case Some(value) => value; case None => return 0 }
            let window = ProgramPayloadWindow(input, hello, first)
            let invocation = window.invocation
            try {
            require(stringField(invocation, "type") == "invoke" && stringField(invocation, "tool") == "run" && stringField(invocation, "kind") == "tool")
            for (key in ["protocol", "extension_id", "extension_version", "generation"]) {
                require(stringifyUnifiedJson(invocation.field(key).getOrThrow()) == stringifyUnifiedJson(hello.field(key).getOrThrow())) }
            for (key in ["id", "thread_id", "run_id", "operation_id", "call_id"]) { require(stringField(invocation, key) != "" && stringField(invocation, key).size <= 1024) }
            let epoch = invocation.field("epoch").getOrThrow().asNumberText()
            require(stringField(invocation, "command_id") == "" && Int64.parse(epoch) > 0 && Int64.parse(epoch).toString() == epoch)
            let id = stringField(invocation, "id"); require(!used.contains(id) && used.size < 4096); used.add(id)
            let arguments = invocation.field("arguments").getOrThrow()
            if (!httpIntentExactFields(arguments, ["code"]) || arguments.field("code").getOrThrow().unifiedKind != ValueKind.Text) {
                reply(invocation, errorValue("tool_program.arguments_invalid", "Program accepts only code"), false, window: Some(window)); continue }
            let code = stringField(arguments, "code")
            if (code.size > 262144) { reply(invocation, errorValue("tool_program.source_limit", "Program source exceeds 256 KiB"), false, window: Some(window)); continue }
            let attachment = programInputAttachment(invocation, code)
            let program = match (compileRestrictedToolProgram(stringField(invocation, "call_id"), code)) {
                case Result.Ok(value) => value
                case Result.Err(error) => reply(invocation, programWithInputAttachment(errorValue(error.code, error.message), attachment), false, window: Some(window)); continue }
            let clock = ProgramClock(); let host = ProgramHost(invocation, input, clock, window)
            try {
                let result = ToolProgramRuntime(host, clock: clock).execute(program, limits: ToolProgramLimits(maxSubCalls: 32u64, maxParallelCalls: 1u64))
                let status = if (host.uncertain) { "recovery_required" } else { match (result.status) {
                    case ToolProgramStatus.Completed => "completed"; case ToolProgramStatus.Partial => "partial"
                    case ToolProgramStatus.Failed => "failed"; case ToolProgramStatus.RecoveryRequired => "recovery_required" } }
                var observedValue=result.value
                var actualStatus=status
                var actualErrorCode=result.errorCode
                var actualErrorMessage=result.errorMessage
                if(status=="completed"){
                    match(host.proposeCompletedValue(result.value)){
                        case Result.Ok(value)=>observedValue=value
                        case Result.Err(error)=>
                            actualStatus=if(host.uncertain){"recovery_required"}else{"failed"}
                            actualErrorCode=error.code;actualErrorMessage=error.message}}
                let output = jsonObject([JsonObjectEntry("status", jsonString(actualStatus)), JsonObjectEntry("value", observedValue),
                    JsonObjectEntry("instruction_count", jsonNumber(result.instructions.toString())),
                    JsonObjectEntry("sub_call_count", jsonNumber((result.subOperations.size + host.additionalEmittedServiceRequests()).toString())),
                    JsonObjectEntry("error_code", jsonString(actualErrorCode)), JsonObjectEntry("error_message", jsonString(actualErrorMessage))])
                reply(invocation, programWithInputAttachment(output, attachment), actualStatus == "completed", window: Some(window))
            } catch (_: ProgramCancelled) { return 0 }
            } finally { window.close() }
        }
        0
    } catch (_: ProgramCancelled) { 0 } catch (_: Exception) { 3 } finally { input.close() }
}
