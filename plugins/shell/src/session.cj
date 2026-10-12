package shell_plugin

import std.collection.*
import std.io.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

let BACKEND_SCHEMA = "axyndra.shell-backend/v1"

class SessionReply {
    let value: JsonNode
    let ok: Bool
    init(value: JsonNode, ok!: Bool = true) { this.value = value; this.ok = ok }
}

class ShellPreparedCall {
    let localName: String
    let inputText: String
    let bytesHex: String
    let managed: Bool
    let timeout: Int64
    init(localName: String, input: JsonNode, id: String, timeout: Int64) {
        this.localName = localName
        inputText = stringifyUnifiedJson(input)
        let asyncValue = input.field("async")
        require(asyncValue.isNone() || asyncValue.getOrThrow().unifiedKind == UnifiedJsonKind.Boolean, "shell_plugin.async_invalid")
        managed = asyncValue.isSome() && asyncValue.getOrThrow().boolValue
        this.timeout = timeout
        // The backend remains synchronous and owned by the host Task. Only
        // the native pure preparation requests background scheduling.
        let executionInput = parseUnifiedJson(inputText)
        if (managed) { executionInput.put("async", jsonBool(false)) }
        let request = jsonObject([JsonObjectEntry("schema", jsonString(BACKEND_SCHEMA)),
            JsonObjectEntry("id", jsonString(id)), JsonObjectEntry("action", jsonString("call")),
            JsonObjectEntry("tool", jsonString(localName)), JsonObjectEntry("input", executionInput)])
        let raw = (stringifyUnifiedJson(request) + "\n").toArray()
        require(raw.size <= 30720, "shell_plugin.request_limit")
        bytesHex = hex(raw)
    }
    func preparation(): JsonNode {
        let result = jsonObject([JsonObjectEntry("intents", intents())])
        if (managed) { result.put("managed_job", jsonObject([JsonObjectEntry("timeout_ms", jsonNumber(timeout.toString()))])) }
        result
    }
    func intents(): JsonNode {
        jsonArray([jsonObject([JsonObjectEntry("id", jsonString("shell-call")),
            JsonObjectEntry("bytes_hex", jsonString(bytesHex))])])
    }
}

func shellOutcome(status: String, value: JsonNode, error: String): JsonNode {
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.service-call-result/v1")),
        JsonObjectEntry("status", jsonString(status)), JsonObjectEntry("result", value),
        JsonObjectEntry("error", if (error == "") { jsonNull() } else { jsonString(error) }),
        JsonObjectEntry("retry_safe", jsonBool(false))])
}

class ShellPluginSession {
    private let channel: BrokerChannel
    private let responses: ShellFrameReader
    private var started = false
    private var configurationText = ""
    private var timeoutMillis: Int64 = 10000
    private let tools = HashSet<String>()
    private let prepared = HashMap<String, ShellPreparedCall>()
    private let consumed = HashSet<String>()
    private var stderrWorker: ?Future<Unit> = None
    init(output: WireOutput) {
        let port = BrokerChannel(output)
        channel = port; responses = ShellFrameReader(port.stdout)
    }

    func receive(frame: JsonNode): Unit { channel.receive(frame) }
    func abort(): Unit { channel.abort() }
    func close(): Unit {
        channel.abort()
        match (stderrWorker) { case Some(worker) => worker.get(); case None => () }
    }
    private func startStderr(): Unit {
        if (stderrWorker.isSome()) { return }
        let port = channel
        stderrWorker = Some(spawn {
            let buffer = Array<Byte>(4096, repeat: 0)
            var total: Int64 = 0
            try {
                while (!port.isClosed()) {
                    let count = port.stderr.read(buffer)
                    if (count == 0) { return }
                    total += count
                    if (total > 65536) { port.abort(); return }
                }
            } catch (_: Exception) { port.abort() }
        })
    }
    private func response(id: String, allowArtifacts!: Bool = false): JsonNode {
        let complete = AtomicBool(false)
        let port = channel
        let until = MonoTime.now() + Duration.millisecond * timeoutMillis
        let watchdog = spawn {
            while (!complete.load() && !port.isClosed() && MonoTime.now() < until) { sleep(Duration.millisecond * 5) }
            if (!complete.load()) { port.abort() }
        }
        try {
            let artifacts = ArrayList<JsonNode>()
            let previews = HashMap<String, String>()
            let names = HashSet<String>()
            var active = ""
            var offset: Int64 = 0
            var length: Int64 = 0
            var expectedDigest = ""
            var total: Int64 = 0
            var terminal: ?JsonNode = None
            while (terminal.isNone()) {
                let reply = responses.readFrame()
                require(reply.isSome(), "shell_plugin.backend_closed")
                let value = reply.getOrThrow()
                require(text(value, "schema") == BACKEND_SCHEMA && text(value, "id") == id,
                    "shell_plugin.backend_identity_invalid")
                let kind = text(value, "type")
                if (kind == "") {
                    require(active == "", "shell_plugin.output_incomplete")
                    terminal = Some(value); continue
                }
                let name = text(value, "stream")
                require(allowArtifacts && ["stdout", "stderr"].contains(name), "shell_plugin.output_stream_invalid")
                let args = jsonObject([JsonObjectEntry("stream", jsonString(name))])
                if (kind == "output_begin") {
                    exact(value, ["schema", "id", "stream", "type", "bytes", "sha256"])
                    require(active == "" && !names.contains(name), "shell_plugin.output_reused")
                    length = number(value, "bytes")
                    require(length >= 0 && length <= 16777216 - total, "shell_plugin.output_limit")
                    names.add(name); total += length; active = name; offset = 0; expectedDigest = text(value, "sha256")
                    args.put("action", jsonString("begin")); args.put("bytes", field(value, "bytes")); args.put("sha256", field(value, "sha256"))
                } else if (kind == "output_chunk") {
                    let encoded = value.field("data_base64")
                    exact(value, if (encoded.isSome()) { ["schema", "id", "stream", "type", "offset", "data_base64"] }
                        else { ["schema", "id", "stream", "type", "offset", "text"] })
                    let data = match (encoded) {
                        case Some(raw) =>
                            require(raw.unifiedKind == UnifiedJsonKind.Text, "shell_plugin.output_encoding")
                            jsonString(shellArtifactBase64(raw.text, maxBytes: 16384))
                        case None => field(value, "text")
                    }
                    require(active == name && number(value, "offset") == offset && data.unifiedKind == UnifiedJsonKind.Text &&
                        data.text.size > 0 && data.text.size <= 16384 && data.text.size <= length - offset, "shell_plugin.output_offset")
                    args.put("action", jsonString("append")); args.put("offset", field(value, "offset"))
                    // Preserve the already validated compact wire form through
                    // the Host boundary; decoded content and offsets are identical.
                    match (encoded) { case Some(raw) => args.put("data_base64", raw)
                        case None => args.put("text", data) }
                    offset += data.text.size
                } else {
                    exact(value, ["schema", "id", "stream", "type"])
                    require(kind == "output_end" && active == name && offset == length, "shell_plugin.output_incomplete")
                    args.put("action", jsonString("finish")); active = ""
                }
                let observed = channel.request("output.artifact", args).getOrThrow()
                if (kind == "output_begin") { require(number(observed, "accepted_bytes") == length, "shell_plugin.output_ack_invalid") }
                else if (kind == "output_chunk") { require(number(observed, "next_offset") == offset, "shell_plugin.output_ack_invalid") }
                else {
                    exact(observed, ["artifact", "preview", "truncated"])
                    let reference = field(observed, "artifact")
                    require(text(reference, "stream") == name && number(reference, "bytes") == length &&
                        text(reference, "sha256") == expectedDigest && text(reference, "ref") == "blob:sha256:" + expectedDigest,
                        "shell_plugin.output_ack_invalid")
                    artifacts.add(reference)
                    let raw = text(observed, "preview").toArray(); var cut = min(raw.size, 4096)
                    while (cut < raw.size && cut > 0 && (raw[cut] & 192u8) == 128u8) { cut -= 1 }
                    previews.add(name, String.fromUtf8(raw[..cut]))
                }
            }
            let value = terminal.getOrThrow()
            exact(value, ["schema", "id", "status", "result", "error"])
            if (!artifacts.isEmpty()) {
                let body = field(value, "result")
                require(body.unifiedKind == UnifiedJsonKind.Object, "shell_plugin.output_terminal_missing")
                for ((name, preview) in previews) { body.put(name, jsonString(preview)) }
                body.put("artifacts", jsonArray(artifacts.toArray())); body.put("artifact_error", jsonNull())
                body.put("truncated", jsonBool(true))
            }
            require(text(value, "schema") == BACKEND_SCHEMA && text(value, "id") == id &&
                ["complete", "unknown"].contains(text(value, "status")), "shell_plugin.backend_identity_invalid")
            let error = field(value, "error")
            require(error.unifiedKind == UnifiedJsonKind.Null ||
                (error.unifiedKind == UnifiedJsonKind.Text && error.text.size > 0 && error.text.size <= 256),
                "shell_plugin.backend_error_invalid")
            require(text(value, "status") != "unknown" || error.unifiedKind == UnifiedJsonKind.Text,
                "shell_plugin.backend_error_invalid")
            value
        } finally { complete.store(true); watchdog.get() }
    }
    private func discover(invocation: JsonNode, refresh: Bool): SessionReply {
        let id = stableId(invocation)
        if (refresh) { channel.openRefreshWindow(invocation) } else { channel.openWindow(invocation, true) }
        startStderr()
        try {
            channel.write((stringifyUnifiedJson(jsonObject([
                JsonObjectEntry("schema", jsonString(BACKEND_SCHEMA)), JsonObjectEntry("id", jsonString(id)),
                JsonObjectEntry("action", jsonString("discover"))])) + "\n").toArray())
            let reply = response(id)
            require(text(reply, "status") == "complete" && field(reply, "error").unifiedKind == UnifiedJsonKind.Null,
                "shell_plugin.discovery_failed")
            let directory = field(reply, "result")
            exact(directory, ["tools"])
            let entries = field(directory, "tools")
            require(entries.unifiedKind == UnifiedJsonKind.List && entries.items.size > 0 && entries.items.size <= 64,
                "shell_plugin.directory_limit")
            let names = HashSet<String>()
            for (entry in entries.items) {
                exact(entry, ["name", "description", "input_schema"])
                let name = text(entry, "name")
                require(name != "" && name.size <= 128 && !names.contains(name) &&
                    field(entry, "input_schema").unifiedKind == UnifiedJsonKind.Object, "shell_plugin.directory_invalid")
                names.add(name)
            }
            require(stringifyUnifiedJson(directory).size <= OUTPUT_LIMIT, "shell_plugin.directory_limit")
            channel.closeWindow()
            tools.clear(); for (name in names) { tools.add(name) }
            for ((key, _) in prepared) { consumed.add(key) }; prepared.clear()
            started = true
            SessionReply(directory)
        } catch (error: Exception) { channel.abort(); throw error }
    }
    func handle(invocation: JsonNode): SessionReply {
        let args = field(invocation, "arguments")
        if (text(invocation, "kind") == "service_prepare") { return prepare(invocation, args) }
        let action = text(args, "action")
        if (action == "start" || action == "refresh") {
            exact(args, ["action", "configuration"])
            let configuration = field(args, "configuration")
            exact(configuration, ["version", "request_timeout_ms"])
            require(number(configuration, "version") == 1 && number(configuration, "request_timeout_ms") >= 1 &&
                number(configuration, "request_timeout_ms") <= 3600000, "shell_plugin.configuration_invalid")
            if (action == "start") {
                require(!started, "shell_plugin.already_started")
                configurationText = stringifyUnifiedJson(configuration)
                timeoutMillis = number(configuration, "request_timeout_ms")
            } else {
                require(started && sameJson(configuration, parseUnifiedJson(configurationText)), "shell_plugin.configuration_changed")
            }
            return discover(invocation, action == "refresh")
        }
        require(action == "call", "shell_plugin.action_unknown")
        execute(invocation, args)
    }
    private func prepare(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input"])
        require(started && text(args, "action") == "call" && tools.contains(text(args, "tool")) &&
            field(args, "input").unifiedKind == UnifiedJsonKind.Object, "shell_plugin.tool_unknown")
        let id = stableId(invocation)
        require(!consumed.contains(id), "shell_plugin.prepared_consumed")
        match (prepared.get(id)) {
            case Some(value) =>
                require(value.localName == text(args, "tool") && sameJson(parseUnifiedJson(value.inputText), field(args, "input")),
                    "shell_plugin.prepared_identity_conflict")
                return SessionReply(value.preparation())
            case None => ()
        }
        require(prepared.size < 128 && consumed.size + prepared.size < 4096, "shell_plugin.prepared_capacity")
        let saved = ShellPreparedCall(text(args, "tool"), field(args, "input"), id, timeoutMillis)
        let result = saved.preparation()
        require(stringifyUnifiedJson(result).size <= OUTPUT_LIMIT, "shell_plugin.prepare_output_limit")
        prepared.add(id, saved)
        SessionReply(result)
    }
    private func execute(invocation: JsonNode, args: JsonNode): SessionReply {
        let reference = args.field("preparation_ref")
        exact(args, if (reference.isSome()) { ["action", "tool", "input", "host_plan", "preparation_ref"] }
            else { ["action", "tool", "input", "host_plan"] })
        let id = if (reference.isSome()) {
            let value = reference.getOrThrow()
            exact(value, ["thread_id", "run_id", "epoch", "call_id"])
            for (key in ["thread_id", "run_id", "call_id"]) {
                require(field(value, key).unifiedKind == UnifiedJsonKind.Text && text(value, key) != "" &&
                    text(value, key).size <= 512, "shell_plugin.preparation_reference_invalid") }
            require(field(value, "epoch").unifiedKind == UnifiedJsonKind.Number && number(value, "epoch") > 0 &&
                text(value, "thread_id") != text(invocation, "thread_id") && text(value, "run_id") != text(invocation, "run_id"),
                "shell_plugin.preparation_reference_invalid")
            stableId(value)
        } else { stableId(invocation) }
        require(started && !consumed.contains(id) && prepared.get(id).isSome(), "shell_plugin.prepared_missing")
        let saved = prepared.get(id).getOrThrow()
        require(saved.localName == text(args, "tool") && sameJson(parseUnifiedJson(saved.inputText), field(args, "input")),
            "shell_plugin.prepared_identity_conflict")
        let plan = field(args, "host_plan")
        require(saved.managed == reference.isSome(), "shell_plugin.preparation_reference_required")
        exact(plan, if (saved.managed) { ["version", "binding", "intents", "managed_job"] }
            else { ["version", "binding", "intents"] })
        if (saved.managed) {
            let job = field(plan, "managed_job")
            exact(job, ["schema", "job_id", "thread_id", "run_id", "deadline_ms", "max_tool_calls"])
            require(text(job, "schema") == "axyndra.managed-job/v1" && text(job, "job_id") != "" &&
                text(job, "thread_id") == text(invocation, "thread_id") && text(job, "run_id") == text(invocation, "run_id") &&
                number(job, "deadline_ms") > 0 && number(job, "max_tool_calls") >= 2 &&
                text(field(plan, "binding"), "target_thread_id") == text(reference.getOrThrow(), "thread_id"),
                "shell_plugin.preparation_reference_invalid")
        }
        require(text(plan, "version") == "process-channel-intent-v1" &&
            field(plan, "binding").unifiedKind == UnifiedJsonKind.Object && sameJson(field(plan, "intents"), saved.intents()),
            "shell_plugin.intent_mismatch")
        consumed.add(id); prepared.remove(id)
        channel.openWindow(invocation, false, saved.bytesHex)
        try {
            channel.write(unhex(saved.bytesHex, 30720))
            let reply = response(id, allowArtifacts: true)
            channel.closeWindow()
            let error = text(reply, "error")
            if (text(reply, "status") == "unknown") { channel.abort() }
            SessionReply(shellOutcome(text(reply, "status"), field(reply, "result"), error), ok: error == "")
        } catch (_: Exception) {
            channel.abort()
            SessionReply(shellOutcome("unknown", jsonNull(), "shell_plugin.call_outcome_unknown"), ok: false)
        }
    }
}
