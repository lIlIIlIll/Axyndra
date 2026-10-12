package eval_plugin

import std.collection.*
import std.convert.*
import std.io.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

class SessionReply {
    let value: JsonNode
    let ok: Bool
    init(value: JsonNode, ok!: Bool = true) { this.value = value; this.ok = ok }
}

func evalOutcome(status: String, value: JsonNode, error: String): JsonNode {
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.service-call-result/v1")),
        JsonObjectEntry("status", jsonString(status)), JsonObjectEntry("result", value),
        JsonObjectEntry("error", if (error == "") { jsonNull() } else { jsonString(error) }),
        JsonObjectEntry("retry_safe", jsonBool(false))])
}

class EvalPreparedCell {
    let inputText: String
    let bytesHex: String
    let timeoutMillis: Int64
    init(input: JsonNode, language: String, maximumMillis: Int64) {
        require(input.unifiedKind == UnifiedJsonKind.Object, "eval_plugin.input_invalid")
        for (entry in input.fields) {
            require(["language", "code", "title", "timeout", "reset"].contains(entry.name), "eval_plugin.input_invalid")
        }
        require(text(input, "language") == language && field(input, "code").unifiedKind == UnifiedJsonKind.Text,
            "eval_plugin.language_or_code_invalid")
        match (input.field("title")) { case Some(value) => require(value.unifiedKind == UnifiedJsonKind.Text); case None => () }
        match (input.field("reset")) { case Some(value) => require(value.unifiedKind == UnifiedJsonKind.Boolean); case None => () }
        let seconds = if (input.field("timeout").isSome()) { number(input, "timeout") } else { 30 }
        // A short-lived channel cannot honestly provide the legacy seven-day
        // timeout=0. Reject before preparing any effect, never shorten silently.
        require(seconds >= 1 && seconds <= maximumMillis / 1000, "eval_plugin.timeout_unavailable")
        timeoutMillis = seconds * 1000
        inputText = stringifyUnifiedJson(input)
        let raw = (timeoutMillis.toString() + "|" + (if (boolean(input, "reset")) { "1" } else { "0" }) +
            "|" + hex(text(input, "code").toArray()) + "\n").toArray()
        require(raw.size <= 30720, "eval_plugin.request_limit")
        bytesHex = hex(raw)
    }
    func intents(): JsonNode {
        jsonArray([jsonObject([JsonObjectEntry("id", jsonString("eval-call")),
            JsonObjectEntry("bytes_hex", jsonString(bytesHex))])])
    }
}

class EvalPluginSession {
    private let channel: BrokerChannel
    private var started = false
    private var language = ""
    private var configurationText = ""
    private var maximumMillis: Int64 = 30000
    private let prepared = HashMap<String, EvalPreparedCell>()
    private let consumed = HashSet<String>()
    private var stderrWorker: ?Future<Unit> = None
    init(output: WireOutput) { channel = BrokerChannel(output) }
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
    private func runnerLine(timeoutMillis: Int64): String {
        let complete = AtomicBool(false)
        let port = channel
        let until = MonoTime.now() + Duration.millisecond * timeoutMillis
        let watchdog = spawn {
            while (!complete.load() && !port.isClosed() && MonoTime.now() < until) { sleep(Duration.millisecond * 5) }
            if (!complete.load()) { port.abort() }
        }
        try {
            let buffer = ArrayList<Byte>()
            let one = Array<Byte>(1, repeat: 0)
            while (true) {
                require(channel.stdout.read(one) == 1, "eval_plugin.runner_closed")
                if (one[0] == 10u8) { return String.fromUtf8(buffer.toArray()) }
                require(buffer.size < 131072, "eval_plugin.runner_output_limit")
                buffer.add(one[0])
            }
            ""
        } finally { complete.store(true); watchdog.get() }
    }
    private func directory(): JsonNode {
        let schema = parseUnifiedJson("{\"type\":\"object\",\"properties\":{\"language\":{\"type\":\"string\",\"enum\":[\"" +
            language + "\"]},\"code\":{\"type\":\"string\"},\"title\":{\"type\":\"string\"}," +
            "\"timeout\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":" + (maximumMillis / 1000).toString() +
            "},\"reset\":{\"type\":\"boolean\"}},\"required\":[\"language\",\"code\"],\"additionalProperties\":false}")
        jsonObject([JsonObjectEntry("tools", jsonArray([jsonObject([
            JsonObjectEntry("name", jsonString("eval")),
            JsonObjectEntry("description", jsonString("Execute a cell in the approved persistent " + language + " runtime. State is private to this service; reset clears cell state.")),
            JsonObjectEntry("input_schema", schema)])]))])
    }
    private func start(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "configuration"])
        require(!started, "eval_plugin.already_started")
        let configuration = field(args, "configuration")
        exact(configuration, ["version", "language", "max_timeout_ms"])
        language = text(configuration, "language")
        maximumMillis = number(configuration, "max_timeout_ms")
        require(number(configuration, "version") == 1 && ["py", "js", "rb", "jl"].contains(language) &&
            maximumMillis >= 30000 && maximumMillis <= 120000 && maximumMillis % 1000 == 0,
            "eval_plugin.configuration_invalid")
        configurationText = stringifyUnifiedJson(configuration)
        channel.openWindow(invocation, true)
        startStderr()
        try {
            require(runnerLine(10000) == "READY|" + language + "|1", "eval_plugin.runner_identity_invalid")
            channel.closeWindow()
            started = true
            SessionReply(directory())
        } catch (error: Exception) { channel.abort(); throw error }
    }
    func handle(invocation: JsonNode): SessionReply {
        let args = field(invocation, "arguments")
        if (text(invocation, "kind") == "service_prepare") { return prepare(invocation, args) }
        let action = text(args, "action")
        if (action == "start") { return start(invocation, args) }
        if (action == "refresh") {
            exact(args, ["action", "configuration"])
            require(started && sameJson(field(args, "configuration"), parseUnifiedJson(configurationText)), "eval_plugin.configuration_changed")
            channel.openRefreshWindow(invocation)
            channel.closeWindow()
            for ((id, _) in prepared) { consumed.add(id) }; prepared.clear()
            return SessionReply(directory())
        }
        require(action == "call", "eval_plugin.action_unknown")
        execute(invocation, args)
    }
    private func prepare(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input"])
        require(started && text(args, "action") == "call" && text(args, "tool") == "eval", "eval_plugin.tool_unknown")
        let id = stableId(invocation)
        require(!consumed.contains(id), "eval_plugin.prepared_consumed")
        match (prepared.get(id)) {
            case Some(value) =>
                require(sameJson(parseUnifiedJson(value.inputText), field(args, "input")), "eval_plugin.prepared_identity_conflict")
                return SessionReply(jsonObject([JsonObjectEntry("intents", value.intents())]))
            case None => ()
        }
        require(prepared.size < 128 && consumed.size + prepared.size < 4096, "eval_plugin.prepared_capacity")
        let saved = EvalPreparedCell(field(args, "input"), language, maximumMillis)
        let result = jsonObject([JsonObjectEntry("intents", saved.intents())])
        require(stringifyUnifiedJson(result).size <= OUTPUT_LIMIT, "eval_plugin.prepare_output_limit")
        prepared.add(id, saved)
        SessionReply(result)
    }
    private func cellResult(line: String, input: JsonNode): SessionReply {
        let parts = line.split("|")
        require(parts.size == 6 && parts[0] == "OK" && ["0", "1"].contains(parts[2]), "eval_plugin.runner_protocol_invalid")
        let exitCode = Int64.parse(parts[1])
        let duration = Int64.parse(parts[3])
        require(duration >= 0, "eval_plugin.runner_protocol_invalid")
        let stdout = String.fromUtf8(unhex(parts[4], 65536))
        let stderr = String.fromUtf8(unhex(parts[5], 65536))
        let timedOut = parts[2] == "1"
        let failed = exitCode != 0 || timedOut
        var content = stdout
        if (stderr != "") { content += (if (content == "") { "" } else { "\n" }) + stderr }
        if (content == "") { content = if (failed) { "eval cell failed without output" } else { "(no output)" } }
        let result = jsonObject([JsonObjectEntry("content", jsonString(content)), JsonObjectEntry("language", jsonString(language)),
            JsonObjectEntry("title", jsonString(text(input, "title"))), JsonObjectEntry("status", jsonString(if (failed) { "error" } else { "complete" })),
            JsonObjectEntry("stdout", jsonString(stdout)), JsonObjectEntry("stderr", jsonString(stderr)),
            JsonObjectEntry("stdout_bytes", jsonNumber(stdout.size.toString())), JsonObjectEntry("stderr_bytes", jsonNumber(stderr.size.toString())),
            JsonObjectEntry("artifacts", jsonArray([])), JsonObjectEntry("artifact_error", jsonNull()),
            JsonObjectEntry("exit_code", jsonNumber(exitCode.toString())), JsonObjectEntry("duration_ms", jsonNumber(duration.toString())),
            JsonObjectEntry("timed_out", jsonBool(timedOut)), JsonObjectEntry("truncated", jsonBool(false)),
            JsonObjectEntry("reset", jsonBool(boolean(input, "reset")))])
        // The Bun runner terminates after timeout. The generic protocol has no
        // completed-and-retire state or process-cleanup ACK. Do not publish a
        // reusable session after observing that terminal runtime condition.
        // Keep the observed cell output in the bounded wire outcome.
        let retired = timedOut && language == "js"
        let outcome = evalOutcome(if (retired) { "unknown" } else { "complete" }, result,
            if (retired) { "eval_plugin.runtime_retired" } else if (failed) { "eval_plugin.cell_failed" } else { "" })
        require(stringifyUnifiedJson(outcome).size <= OUTPUT_LIMIT, "eval_plugin.result_limit")
        if (retired) { channel.abort() }
        SessionReply(outcome, ok: !failed)
    }
    private func execute(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input", "host_plan"])
        let id = stableId(invocation)
        require(started && text(args, "tool") == "eval" && !consumed.contains(id) && prepared.get(id).isSome(),
            "eval_plugin.prepared_missing")
        let saved = prepared.get(id).getOrThrow()
        require(sameJson(parseUnifiedJson(saved.inputText), field(args, "input")), "eval_plugin.prepared_identity_conflict")
        let plan = field(args, "host_plan")
        exact(plan, ["version", "binding", "intents"])
        require(text(plan, "version") == "process-channel-intent-v1" && field(plan, "binding").unifiedKind == UnifiedJsonKind.Object &&
            sameJson(field(plan, "intents"), saved.intents()), "eval_plugin.intent_mismatch")
        consumed.add(id); prepared.remove(id)
        channel.openWindow(invocation, false, saved.bytesHex)
        try {
            channel.write(unhex(saved.bytesHex, 30720))
            let line = runnerLine(saved.timeoutMillis + 1000)
            channel.closeWindow()
            cellResult(line, field(args, "input"))
        } catch (_: Exception) {
            channel.abort()
            SessionReply(evalOutcome("unknown", jsonNull(), "eval_plugin.cell_outcome_unknown"), ok: false)
        }
    }
}
