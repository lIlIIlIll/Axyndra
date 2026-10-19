package dap_plugin

import process4cj.*
import std.collection.*
import std.time.*
import yjson.*
import yjson_support.*

// No operation in this file calls a Host service or touches a process. Each
// concrete write/spawn/close is returned as descriptive data, frozen until the
// actual Host normal-policy child has a Known outcome. Reads arrive only from
// that Host's current physical lease, and remain full paid Native frames.
class DapOwnedDebugSession {
    let id: String
    var adapter: String
    var locations: DapDebugLocations
    let policy: DapSessionPolicy
    let frames: DapOwnedFrameBuffer
    private let storage: DapOwnedDebugRetainedCharge
    private var configuration: String
    private var requestSequence: Int64 = 0
    var leaseId = ""
    var initialized = false
    var unknown = false
    var closed = false
    init(id: String, configuration: JsonNode, locations: DapDebugLocations, maximum: Int64) {
        let paid = dapOwnedDebugRetainedCharge(configuration, 8388608,
            retainedTexts: [locations.cwd, locations.program, locations.source])
        let (encoded, selectedAdapter) = try {
            let encoded = stringifyUnifiedJson(configuration)
            require(encoded.size <= 8388608, "dap_plugin.configuration_limit")
            let selected = text(configuration, "adapter")
            require(selected != "", "dap_plugin.configuration_invalid")
            (encoded, selected)
        } catch (error: Exception) { paid.close(); throw error }
        let actualFrames = try { DapOwnedFrameBuffer(maximum) }
            catch (error: Exception) { paid.close(); throw error }
        let actualPolicy = try { DapSessionPolicy() }
            catch (error: Exception) { actualFrames.close(); paid.close(); throw error }
        this.id = id; this.locations = locations; this.configuration = encoded
        adapter = selectedAdapter; frames = actualFrames; policy = actualPolicy; storage = paid
    }
    func config(): JsonNode { parseUnifiedJson(configuration, maxBytes: 8388608, maxDepth: 64) }
    func sequence(): Int64 {
        require(!closed && !unknown && requestSequence < Int64.Max, "dap.sequence_invalid")
        requestSequence++; requestSequence
    }
    func snapshot(): JsonNode { debugSnapshotValue(id, adapter, locations, policy.snapshot()) }
    func close(): Unit {
        if (closed) { return }; closed = true
        configuration = ""; adapter = ""; locations = DapDebugLocations("")
        frames.close(); policy.close(); storage.close()
    }
}

class DapOwnedPendingRequest {
    let sequence: Int64
    let command: String
    let purpose: String
    let projection: ?DapFrozenPolicy
    var contextRevision: Int64 = 0
    var sent = false
    var sentChildSequence: Int64 = 0
    // Alias of the very same complete parsed message owned by frame. Keeping
    // it never decodes a second DOM or replaces the actual response budget.
    var response: ?JsonNode = None
    var body: ?JsonNode = None
    var error = ""
    var frame: ?OwnedProtocolFrame = None
    init(sequence: Int64, command: String, purpose: String, projection: ?DapFrozenPolicy) {
        this.sequence = sequence; this.command = command; this.purpose = purpose; this.projection = projection
    }
    func close(): Unit {
        body = None; response = None
        match (frame) { case Some(value) => value.close(); case None => () }; frame = None
    }
}

class DapOwnedDebugEffect {
    let sequence: Int64
    var operation: JsonNode
    let purpose: String
    let request: ?DapOwnedPendingRequest
    private let charge: DapOwnedDebugRetainedCharge
    init(sequence: Int64, operation: JsonNode, purpose: String, request: ?DapOwnedPendingRequest, charge: DapOwnedDebugRetainedCharge) {
        this.sequence = sequence; this.operation = operation; this.purpose = purpose; this.request = request; this.charge = charge
    }
    func close(): Unit { operation = jsonNull(); charge.close() }
}

func dapOwnedInitialization(adapter: String): JsonNode {
    let values = ArrayList<JsonObjectEntry>([JsonObjectEntry("clientID", jsonString("axyndra")),
        JsonObjectEntry("clientName", jsonString("axyndra")), JsonObjectEntry("adapterID", jsonString(adapter)),
        JsonObjectEntry("locale", jsonString("en-US")), JsonObjectEntry("pathFormat", jsonString("path"))])
    for (name in ["linesStartAt1", "columnsStartAt1", "supportsVariableType", "supportsVariablePaging",
        "supportsRunInTerminalRequest", "supportsMemoryReferences", "supportsProgressReporting", "supportsInvalidatedEvent"]) {
        values.add(JsonObjectEntry(name, jsonBool(true)))
    }
    jsonObject(values.toArray())
}

class DapOwnedDebugWorkflow {
    let session: DapOwnedDebugSession
    private var input: String
    private var commandLocations: DapDebugLocations
    private let deadline: MonoTime
    private let maximum: Int64
    private let storage: DapOwnedDebugRetainedCharge
    private let pending = HashMap<Int64, DapOwnedPendingRequest>()
    private var effect: ?DapOwnedDebugEffect = None
    private var primary: ?DapOwnedPendingRequest = None
    private var call: ?DapDebugCall = None
    private var childSequence: Int64 = 0
    private var stage = "begin"
    private var drainedStdout = false
    private var beforeStop: Int64 = 0
    private var stopDeadline: ?MonoTime = None
    private var timedOut = false
    private var reverse: ?JsonNode = None
    private var reverseFrame: ?OwnedProtocolFrame = None
    private var terminal: ?JsonNode = None
    private var terminalError = false
    private var terminalProtocol: ?DapOwnedPendingRequest = None
    private var startupError = ""
    private var closed = false
    init(session: DapOwnedDebugSession, input: JsonNode, deadline: MonoTime, maximum: Int64, locations!:?DapDebugLocations=None) {
        this.session = session; this.deadline = deadline; this.maximum = maximum
        let selected=match(locations){case Some(value)=>value;case None=>session.locations}
        let paid = dapOwnedDebugRetainedCharge(input, 8388608,
            retainedTexts:[selected.cwd,selected.program,selected.source])
        let encoded = try {
            let encoded = stringifyUnifiedJson(input)
            require(encoded.size <= 8388608, "dap_plugin.input_limit")
            encoded
        } catch (error: Exception) { paid.close(); throw error }
        storage = paid; this.input = encoded; commandLocations=selected
    }
    func validateEffect(sequence: Int64): Unit {
        require(!closed && !session.unknown && MonoTime.now() < deadline && effect.isSome() &&
            effect.getOrThrow().sequence == sequence, "dap_plugin.prepared_changed")
        match (effect.getOrThrow().request) {
            case Some(value) => match (value.projection) { case Some(policy) => session.policy.validate(policy); case None => () }
            case None => ()
        }
    }
    private func propose(operation: JsonNode, purpose: String, request: ?DapOwnedPendingRequest = None): Unit {
        require(effect.isNone() && childSequence < Int64.Max, "dap_plugin.proposal_overlap")
        let paid = dapOwnedDebugRetainedCharge(operation, 16777216)
        try { childSequence++; effect = Some(DapOwnedDebugEffect(childSequence, operation, purpose, request, paid)) }
        catch (error: Exception) { paid.close(); throw error }
    }
    private func request(command: String, arguments: JsonNode, purpose: String,
        projection: ?DapFrozenPolicy = None): DapOwnedPendingRequest {
        let sequence = session.sequence()
        let value = DapOwnedPendingRequest(sequence, command, purpose, projection)
        // Keep the whole immutable request. A later Host approval neither
        // recreates its sequence nor inserts a response-dependent request.
        let scratch = dapOwnedDebugRetainedCharge(arguments, maximum)
        try {
            let raw = encodeContentLengthFrame(stringifyUnifiedJson(jsonObject([
                JsonObjectEntry("seq", jsonNumber(sequence.toString())), JsonObjectEntry("type", jsonString("request")),
                JsonObjectEntry("command", jsonString(command)), JsonObjectEntry("arguments", arguments)])))
            require(raw.size <= maximum, "dap_plugin.request_limit")
            propose(jsonObject([JsonObjectEntry("kind", jsonString("write")), JsonObjectEntry("lease_id", jsonString(session.leaseId)),
                JsonObjectEntry("id", jsonString("dap-request-" + sequence.toString())),
                JsonObjectEntry("bytes_hex", jsonString(hex(raw)))]), purpose, Some(value))
            pending.add(sequence, value); value
        } finally { scratch.close() }
    }
    private func spawnOperation(role: String, executable: String, args: JsonNode, cwd: String, environment: JsonNode): JsonNode {
        let config = session.config()
        let operation=jsonObject([JsonObjectEntry("kind", jsonString("spawn")), JsonObjectEntry("role", jsonString(role)),
            JsonObjectEntry("executable", jsonString(executable)), JsonObjectEntry("args", args), JsonObjectEntry("cwd", jsonString(cwd)),
            JsonObjectEntry("environment", environment), JsonObjectEntry("workspace_mode", field(config, "workspace_mode")),
            JsonObjectEntry("network", field(config, "network"))])
        if(role=="adapter" && field(config,"configured_process").unifiedKind!=UnifiedJsonKind.Null){
            operation.put("configured_process",field(config,"configured_process"))}
        operation
    }
    private func preparePrimary(): Unit {
        let config = session.config()
        let prepared = session.policy.prepareDebug(parseUnifiedJson(input, maxBytes: 8388608, maxDepth: 64), commandLocations,
            field(config, "launch"), field(config, "attach"))
        call = Some(prepared[0]); beforeStop = session.policy.currentDebugStopRevision()
        if (prepared[1].isNone()) {
            let action = prepared[0].action
            require(action == "output" || action == "sessions", "dap_plugin.session_action_external")
            // The current actual parent first drains both physical streams.
            // Cached events from an earlier Root are never presented as fresh.
            stage = "snapshot-drain"; return
        }
        let projection = prepared[1].getOrThrow()
        let actual = projection.requests()[0]
        primary = Some(request(text(actual, "command"), field(actual, "arguments"), "primary", Some(projection.frozen)))
        stage = "primary"
    }
    private func hasPurpose(purpose: String): Bool {
        for ((_, item) in pending where item.purpose == purpose) { return true }; false
    }
    private func settledPurpose(purpose: String): Bool {
        for ((_, item) in pending where item.purpose == purpose) {
            if (item.frame.isNone()) { return false }
        }; true
    }
    func next(): JsonNode {
        require(!closed, "dap_plugin.session_closed")
        if (terminal.isSome()) { return outcome("complete", terminal.getOrThrow(), terminalError) }
        if (session.unknown) { return unknown() }
        if (effect.isSome()) {
            validateEffect(effect.getOrThrow().sequence)
            let value = effect.getOrThrow()
            return jsonObject([JsonObjectEntry("status", jsonString("effect")), JsonObjectEntry("sequence", jsonNumber(value.sequence.toString())),
                JsonObjectEntry("operation", value.operation)])
        }
        if (MonoTime.now() >= deadline) {
            if (stage == "stopping" && primary.isSome() && primary.getOrThrow().body.isSome()) {
                timedOut = true; stage = "finish"; finishPrimary()
                return next()
            }
            session.unknown = true; return unknown()
        }
        if (stage == "begin") {
            if (session.leaseId == "") {
                let action = debugText(parseUnifiedJson(input, maxBytes: 8388608, maxDepth: 64), "action").trimAscii().toAsciiLower()
                require(action == "launch" || action == "attach", "tool.debug_no_session")
                let config = session.config()
                propose(spawnOperation("adapter", text(config, "executable"), field(config, "args"), session.locations.cwd,
                    field(config, "environment")), "adapter"); stage = "spawning"
            } else { preparePrimary() }
            return next()
        }
        if (stage == "snapshot-complete") {
            let captured = session.policy.debugOutput()
            if (call.getOrThrow().action == "output") {
                complete(if(captured == ""){ "(no output captured)" }else{captured},
                    Some(jsonObject([JsonObjectEntry("output",jsonString(captured))])))
            } else { complete(formatDebugSnapshot(session.snapshot()), None) }
            return next()
        }
        if (stage == "initialized") {
            for ((_, item) in pending where item.purpose == "initialize" && item.frame.isSome() && item.error != "") {
                startupError = item.error; terminalProtocol = Some(item); proposeClose(); return next()
            }
            if (session.initialized) { preparePrimary(); return next() }
        }
        if (stage == "primary" && primary.isSome()) {
            let value = primary.getOrThrow()
            let action = call.getOrThrow().action
            let startup = ["launch", "attach"].contains(action)
            let startupInitialized = !startup || boolean(session.policy.snapshot(), "initialized")
            if (startup && startupInitialized && !hasPurpose("configuration")) {
                if (session.policy.debugSupportsConfigurationDone()) {
                    let _ = request("configurationDone", jsonObject([]), "configuration"); return next()
                }
            }
            if (value.error != "") {
                if (action == "terminate") { proposeClose(); return next() }
                complete(value.error, None, failed: true); return next()
            }
            if (value.frame.isSome() && value.error == "" && startupInitialized && settledPurpose("configuration")) {
                for ((_, item) in pending where item.purpose == "configuration" && item.error != "") {
                    terminalProtocol = Some(item); complete(item.error, None, failed: true); return next()
                }
                if (action == "terminate") { proposeClose(); return next() }
                if (call.getOrThrow().waitForStop) {
                    if (["launch", "attach"].contains(action)) { session.policy.debugMarkStarted() }
                    else if (action != "pause") { session.policy.debugMarkRunningUnlessStoppedAfter(beforeStop) }
                    stopDeadline = Some(minTime(deadline, MonoTime.now() + Duration.millisecond *
                        (if (["launch", "attach"].contains(action)) { min(call.getOrThrow().timeoutMillis, 1000) } else { call.getOrThrow().timeoutMillis })))
                    stage = "stopping"
                } else { stage = "finish" }
            }
        }
        if (stage == "stopping") {
            let state = text(session.policy.snapshot(), "status")
            if (session.policy.currentDebugStopRevision() > beforeStop || state == "exited" || state == "terminated" ||
                MonoTime.now() >= stopDeadline.getOrThrow()) {
                timedOut = session.policy.currentDebugStopRevision() <= beforeStop && state != "exited" && state != "terminated"
                if (call.getOrThrow().refreshFrame && number(session.policy.snapshot(), "threadId") > 0) {
                    let config = session.config()
                    let refreshed = session.policy.prepareDebug(jsonObject([JsonObjectEntry("action", jsonString("stack_trace")),
                        JsonObjectEntry("levels", jsonNumber("1"))]), session.locations, field(config, "launch"), field(config, "attach"))[1].getOrThrow()
                    let actual = refreshed.requests()[0]
                    let _ = request("stackTrace", field(actual, "arguments"), "refresh", Some(refreshed.frozen))
                    stage = "refresh"; return next()
                }
                stage = "finish"
            }
        }
        if (stage == "refresh" && settledPurpose("refresh")) { stage = "finish" }
        if (stage == "finish") { finishPrimary(); return next() }
        jsonObject([JsonObjectEntry("status", jsonString("read")), JsonObjectEntry("lease_id", jsonString(session.leaseId)),
            JsonObjectEntry("stream", jsonString("stdout")), JsonObjectEntry("max_bytes", jsonNumber("16384")),
            JsonObjectEntry("wait_ms", jsonNumber(if(stage == "snapshot-drain"){ "0" }
                else{min(25, max(0, (deadline - MonoTime.now()).toMilliseconds())).toString()}))])
    }
    private func proposeClose(): Unit {
        propose(jsonObject([JsonObjectEntry("kind", jsonString("close")), JsonObjectEntry("lease_id", jsonString(session.leaseId))]), "close")
        stage = "closing"
    }
    func acknowledge(sequence: Int64, result: JsonNode): Unit {
        validateEffect(sequence)
        let value = effect.getOrThrow()
        let kind = text(value.operation, "kind")
        if (kind == "write") {
            exact(result, ["schema", "lease_id", "intent_id", "written_bytes"])
            require(text(result, "schema") == "axyndra.managed-channel-write-result/v1" && text(result, "lease_id") == session.leaseId &&
                text(result, "intent_id") == text(value.operation, "id") &&
                number(result, "written_bytes") == text(value.operation, "bytes_hex").size / 2, "dap_plugin.write_ack_invalid")
            match (value.request) {
                case Some(item) =>
                    item.sent = true; item.sentChildSequence = sequence
                    item.contextRevision = match (item.projection) { case Some(policy) => session.policy.adopt(policy); case None => 0 }
                case None => ()
            }
        } else if (kind == "spawn") {
            exact(result, ["schema", "lease_id", "launch_digest", "resource_binding", "process_id"])
            require(text(result, "schema") == "axyndra.managed-channel-spawn-result/v1" && text(result, "lease_id") != "" &&
                number(result, "process_id") > 0, "dap_plugin.spawn_ack_invalid")
            if (value.purpose == "adapter") {
                session.leaseId = text(result, "lease_id")
                // No startup write occurs before its own separately approved
                // precise request. The completed spawn receipt is not a grant.
                effect = None; value.close()
                let _ = request("initialize", dapOwnedInitialization(session.adapter), "initialize"); stage = "initialized"; return
            }
            require(value.purpose == "reverse" && reverse.isSome(), "dap_plugin.reverse_changed")
            effect = None; value.close()
            proposeReverseResponse(jsonObject([JsonObjectEntry("processId", field(result, "process_id"))])); return
        } else {
            exact(result, ["schema", "lease_id", "resources_released"])
            require(text(result, "schema") == "axyndra.managed-channel-close-result/v1" && text(result, "lease_id") == session.leaseId &&
                boolean(result, "resources_released"), "dap_plugin.close_ack_invalid")
            session.policy.debugMarkTerminated(); stage = "finish"
        }
        effect = None; value.close()
    }
    func abortProposal(reason:String):Unit{
        require(["user_rejected","policy_stop"].contains(reason) && effect.isSome(),"dap_plugin.prepared_changed")
        reject(effect.getOrThrow().sequence)
        if(reason=="policy_stop"){
            terminal.getOrThrow().put("content",jsonString("Debug operation was denied by policy."))
        }
    }
    func reject(sequence: Int64): Unit {
        require(effect.isSome() && effect.getOrThrow().sequence == sequence, "dap_plugin.prepared_changed")
        let value = effect.getOrThrow(); effect = None; value.close(); terminalProtocol = None
        // No unapproved reply, compensation or close is issued after rejection.
        // A reverse request left unresolved quarantines this protocol session.
        if (reverse.isSome()) { session.unknown = true }
        terminal = Some(jsonObject([JsonObjectEntry("content", jsonString("Debug operation was rejected.")),
            JsonObjectEntry("action", jsonString(debugText(parseUnifiedJson(input, maxBytes: 8388608), "action"))),
            JsonObjectEntry("success", jsonBool(false)), JsonObjectEntry("snapshot", session.snapshot())])); terminalError = true
    }
    func commandAction():String {
        debugText(parseUnifiedJson(input,maxBytes:8388608,maxDepth:64),"action").trimAscii().toAsciiLower()
    }
    func receiveStream(stream:String,bytes:Array<Byte>,eof:Bool):Unit {
        require(stream == "stdout" || stream == "stderr", "dap_plugin.stream_invalid")
        if(stream == "stdout") {
            receive(bytes,eof)
            if(stage == "snapshot-drain"){drainedStdout = bytes.isEmpty()}
        } else {
            require(!closed && !session.unknown && effect.isNone(), "dap_plugin.read_outside_stage")
            session.policy.event("output",jsonObject([JsonObjectEntry("output",jsonString(String.fromUtf8(bytes)))]))
            if(stage == "snapshot-drain") {
                if(drainedStdout && bytes.isEmpty()){stage = "snapshot-complete"}
                drainedStdout = false
            }
        }
    }
    func receive(bytes: Array<Byte>, eof: Bool): Unit {
        require(!closed && !session.unknown && effect.isNone(), "dap_plugin.read_outside_stage")
        session.frames.append(bytes, { message, frame => observe(message, frame) })
        if (eof) {
            session.frames.eof()
            if (terminal.isNone() && stage != "finish") { session.unknown = true }
        }
    }
    private func observe(message: JsonNode, frame: OwnedProtocolFrame): Bool {
        let typeName = text(message, "type")
        if (typeName == "event") { session.policy.event(text(message, "event"), field(message, "body")); return false }
        if (typeName == "response") {
            let sequence = number(message, "request_seq")
            let item = pending.get(sequence).getOrThrow()
            require(item.sent && item.frame.isNone() && text(message, "command") == item.command, "dap.response_sequence_invalid")
            if (!boolean(message, "success")) { item.error = text(message, "message"); if (item.error == "") { item.error = "dap.adapter_error" } }
            else {
                item.body = Some(field(message, "body"))
                if (item.purpose == "initialize") {
                    require(field(message, "body").unifiedKind == UnifiedJsonKind.Object, "dap_plugin.initialize_invalid")
                    session.policy.configureDebug(field(message, "body")); session.initialized = true
                }
                match (item.projection) { case Some(policy) => session.policy.observeResponses(policy, [field(message, "body")], item.contextRevision); case None => () }
            }
            require(item.sentChildSequence > 0, "dap_plugin.response_write_missing")
            item.response = Some(message); item.frame = Some(frame); return true
        }
        require(typeName == "request" && reverse.isNone() && number(message, "seq") > 0, "dap.envelope_invalid")
        reverse = Some(message); reverseFrame = Some(frame)
        if (text(message, "command") != "runInTerminal") { proposeReverseFailure("unsupported reverse request"); return true }
        let args = field(message, "arguments"); let argv = field(args, "args")
        require(argv.unifiedKind == UnifiedJsonKind.List && !argv.items.isEmpty(), "tool.invalid_argument")
        for (arg in argv.items) { require(arg.unifiedKind == UnifiedJsonKind.Text, "tool.invalid_argument") }
        let environment = field(args, "env")
        require(environment.unifiedKind == UnifiedJsonKind.Null || environment.unifiedKind == UnifiedJsonKind.Object, "tool.invalid_argument")
        let arguments = ArrayList<JsonNode>()
        for (index in 1..argv.items.size) { arguments.add(argv.items[index]) }
        propose(spawnOperation("auxiliary", argv.items[0].text, jsonArray(arguments.toArray()),
            debugText(args, "cwd", fallback: session.locations.cwd), if (environment.unifiedKind == UnifiedJsonKind.Null) { jsonObject([]) } else { environment }), "reverse")
        true
    }
    private func proposeReverseFailure(message: String): Unit { proposeReverseResponse(jsonObject([]), error: message) }
    private func proposeReverseResponse(body: JsonNode, error!: String = ""): Unit {
        let actual = reverse.getOrThrow(); let sequence = session.sequence()
        let raw = encodeContentLengthFrame(stringifyUnifiedJson(jsonObject([
            JsonObjectEntry("seq", jsonNumber(sequence.toString())), JsonObjectEntry("type", jsonString("response")),
            JsonObjectEntry("request_seq", field(actual, "seq")), JsonObjectEntry("command", field(actual, "command")),
            JsonObjectEntry("success", jsonBool(error == "")), JsonObjectEntry("message", jsonString(error)), JsonObjectEntry("body", body)])))
        require(raw.size <= maximum, "dap_plugin.request_limit")
        propose(jsonObject([JsonObjectEntry("kind", jsonString("write")), JsonObjectEntry("lease_id", jsonString(session.leaseId)),
            JsonObjectEntry("id", jsonString("dap-reverse-" + sequence.toString())), JsonObjectEntry("bytes_hex", jsonString(hex(raw)))]), "reverse-reply")
        reverse = None
        match (reverseFrame) { case Some(frame) => frame.close(); case None => () }; reverseFrame = None
    }
    private func finishPrimary(): Unit {
        if (startupError != "") {
            let result = jsonObject([JsonObjectEntry("content", jsonString(startupError)),
                JsonObjectEntry("action", jsonString(debugText(parseUnifiedJson(input, maxBytes: 8388608), "action"))),
                JsonObjectEntry("success", jsonBool(false)), JsonObjectEntry("snapshot", session.snapshot())])
            terminal = Some(result); terminalError = true; return
        }
        let value = primary.getOrThrow(); let action = call.getOrThrow().action
        if (value.error != "") { complete(value.error, None, failed: true); return }
        var response = value.body.getOrThrow()
        var content = stringifyUnifiedJson(response)
        if (["launch", "attach"].contains(action)) { content = formatDebugSnapshot(session.snapshot()); response = field(call.getOrThrow().request.getOrThrow(), "arguments") }
        else if (["continue", "step_over", "step_in", "step_out"].contains(action)) {
            content = formatDebugSnapshot(session.snapshot()) + "\nTimed out: " + timedOut.toString()
            response = debugMerge(response, jsonObject([JsonObjectEntry("state", field(session.policy.snapshot(), "status")), JsonObjectEntry("timedOut", jsonBool(timedOut))]))
        } else if (action == "pause") { content = formatDebugSnapshot(session.snapshot()) + "\nProgram paused." }
        else if (action == "terminate") { content = formatDebugSnapshot(session.snapshot()) + "\nDebug session terminated." }
        complete(content, Some(response))
    }
    private func complete(content: String, response: ?JsonNode, failed!: Bool = false): Unit {
        if (terminalProtocol.isNone()) {
            match (primary) { case Some(actual) =>
                if (actual.sent && actual.sentChildSequence > 0 && actual.frame.isSome() && actual.response.isSome()) {
                    terminalProtocol = Some(actual)
                }
                case None => () }
        }
        let result = jsonObject([JsonObjectEntry("content", jsonString(content)),
            JsonObjectEntry("action", jsonString(call.getOrThrow().action)), JsonObjectEntry("success", jsonBool(!failed)),
            JsonObjectEntry("snapshot", session.snapshot())])
        match (response) { case Some(value) => result.put("response", value); case None => () }
        terminal = Some(result); terminalError = failed
    }
    private func outcome(status: String, result: JsonNode, failed: Bool): JsonNode {
        let value = jsonObject([JsonObjectEntry("status", jsonString(status)), JsonObjectEntry("result", result), JsonObjectEntry("is_error", jsonBool(failed))])
        if (status == "complete") {
            match (terminalProtocol) {
                case Some(actual) =>
                    require(actual.sent && actual.sentChildSequence > 0 && actual.frame.isSome() && actual.response.isSome(),
                        "dap_plugin.terminal_protocol_changed")
                    // This is complete response DATA and the same workflow's
                    // already-ACKed descriptive step. Host maps it to its own
                    // actual completed Prepared child; Native supplies no
                    // Operation ID, request key, approval or execution Source.
                    value.put("protocol_record", jsonObject([
                        JsonObjectEntry("child_sequence", jsonNumber(actual.sentChildSequence.toString())),
                        JsonObjectEntry("response", actual.response.getOrThrow())]))
                case None => ()
            }
        }
        value
    }
    private func unknown(): JsonNode { outcome("unknown", jsonObject([JsonObjectEntry("error", jsonString("dap_plugin.call_outcome_unknown"))]), true) }
    func close(): Unit {
        if (closed) { return }; closed = true
        input = ""; commandLocations=DapDebugLocations(""); call = None; primary = None; terminal = None; reverse = None; terminalProtocol = None
        match (effect) { case Some(value) => value.close(); case None => () }; effect = None
        for ((_, item) in pending) { item.close() }; pending.clear()
        match (reverseFrame) { case Some(value) => value.close(); case None => () }; reverseFrame = None
        storage.close()
    }
}
func minTime(left: MonoTime, right: MonoTime): MonoTime { if (left < right) { left } else { right } }
