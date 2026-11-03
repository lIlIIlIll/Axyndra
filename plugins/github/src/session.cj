package github_plugin

import std.collection.*
import std.io.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

let BACKEND_SCHEMA = "axyndra.github-backend/v1"

class SessionReply {
    let value: JsonNode
    let ok: Bool
    init(value: JsonNode, ok!: Bool = true) { this.value = value; this.ok = ok }
}

class GithubPreparedCall {
    let localName: String
    let inputText: String
    let bytesHex: String
    init(localName: String, input: JsonNode, id: String) {
        this.localName = localName
        inputText = stringifyUnifiedJson(input)
        let request = jsonObject([JsonObjectEntry("schema", jsonString(BACKEND_SCHEMA)),
            JsonObjectEntry("id", jsonString(id)), JsonObjectEntry("action", jsonString("call")),
            JsonObjectEntry("tool", jsonString(localName)), JsonObjectEntry("input", input)])
        let raw = (stringifyUnifiedJson(request) + "\n").toArray()
        require(raw.size <= 30720, "github_plugin.request_limit")
        bytesHex = hex(raw)
    }
    func intents(): JsonNode {
        jsonArray([jsonObject([JsonObjectEntry("id", jsonString("github-call")),
            JsonObjectEntry("bytes_hex", jsonString(bytesHex))])])
    }
}

func githubOutcome(status: String, value: JsonNode, error: String): JsonNode {
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.service-call-result/v1")),
        JsonObjectEntry("status", jsonString(status)), JsonObjectEntry("result", value),
        JsonObjectEntry("error", if (error == "") { jsonNull() } else { jsonString(error) }),
        JsonObjectEntry("retry_safe", jsonBool(false))])
}

class GithubPluginSession {
    private let channel: BrokerChannel
    private var started = false
    private var configurationText = ""
    private var timeoutMillis: Int64 = 10000
    private let tools = HashSet<String>()
    private let prepared = HashMap<String, GithubPreparedCall>()
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
    private func response(id: String): JsonNode {
        let complete = AtomicBool(false)
        let port = channel
        let until = MonoTime.now() + Duration.millisecond * timeoutMillis
        let watchdog = spawn {
            while (!complete.load() && !port.isClosed() && MonoTime.now() < until) { sleep(Duration.millisecond * 5) }
            if (!complete.load()) { port.abort() }
        }
        try {
            let reply = readFrame(channel.stdout)
            require(reply.isSome(), "github_plugin.backend_closed")
            let value = reply.getOrThrow()
            exact(value, ["schema", "id", "status", "result", "error"])
            require(text(value, "schema") == BACKEND_SCHEMA && text(value, "id") == id &&
                ["complete", "unknown"].contains(text(value, "status")), "github_plugin.backend_identity_invalid")
            let error = field(value, "error")
            require(error.unifiedKind == UnifiedJsonKind.Null ||
                (error.unifiedKind == UnifiedJsonKind.Text && error.text.size > 0 && error.text.size <= 256),
                "github_plugin.backend_error_invalid")
            require(text(value, "status") != "unknown" || error.unifiedKind == UnifiedJsonKind.Text,
                "github_plugin.backend_error_invalid")
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
                "github_plugin.discovery_failed")
            let directory = field(reply, "result")
            exact(directory, ["tools"])
            let entries = field(directory, "tools")
            require(entries.unifiedKind == UnifiedJsonKind.List && entries.items.size > 0 && entries.items.size <= 64,
                "github_plugin.directory_limit")
            let names = HashSet<String>()
            for (entry in entries.items) {
                exact(entry, ["name", "description", "input_schema"])
                let name = text(entry, "name")
                require(name != "" && name.size <= 128 && !names.contains(name) &&
                    field(entry, "input_schema").unifiedKind == UnifiedJsonKind.Object, "github_plugin.directory_invalid")
                names.add(name)
            }
            require(stringifyUnifiedJson(directory).size <= OUTPUT_LIMIT, "github_plugin.directory_limit")
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
                number(configuration, "request_timeout_ms") <= 120000, "github_plugin.configuration_invalid")
            if (action == "start") {
                require(!started, "github_plugin.already_started")
                configurationText = stringifyUnifiedJson(configuration)
                timeoutMillis = number(configuration, "request_timeout_ms")
            } else {
                require(started && sameJson(configuration, parseUnifiedJson(configurationText)), "github_plugin.configuration_changed")
            }
            return discover(invocation, action == "refresh")
        }
        require(action == "call", "github_plugin.action_unknown")
        execute(invocation, args)
    }
    private func prepare(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input"])
        require(started && text(args, "action") == "call" && tools.contains(text(args, "tool")) &&
            field(args, "input").unifiedKind == UnifiedJsonKind.Object, "github_plugin.tool_unknown")
        let id = stableId(invocation)
        require(!consumed.contains(id), "github_plugin.prepared_consumed")
        match (prepared.get(id)) {
            case Some(value) =>
                require(value.localName == text(args, "tool") && sameJson(parseUnifiedJson(value.inputText), field(args, "input")),
                    "github_plugin.prepared_identity_conflict")
                return SessionReply(jsonObject([JsonObjectEntry("intents", value.intents())]))
            case None => ()
        }
        require(prepared.size < 128 && consumed.size + prepared.size < 4096, "github_plugin.prepared_capacity")
        let saved = GithubPreparedCall(text(args, "tool"), field(args, "input"), id)
        let result = jsonObject([JsonObjectEntry("intents", saved.intents())])
        require(stringifyUnifiedJson(result).size <= OUTPUT_LIMIT, "github_plugin.prepare_output_limit")
        prepared.add(id, saved)
        SessionReply(result)
    }
    private func execute(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input", "host_plan"])
        let id = stableId(invocation)
        require(started && !consumed.contains(id) && prepared.get(id).isSome(), "github_plugin.prepared_missing")
        let saved = prepared.get(id).getOrThrow()
        require(saved.localName == text(args, "tool") && sameJson(parseUnifiedJson(saved.inputText), field(args, "input")),
            "github_plugin.prepared_identity_conflict")
        let plan = field(args, "host_plan")
        exact(plan, ["version", "binding", "intents"])
        require(text(plan, "version") == "process-channel-intent-v1" &&
            field(plan, "binding").unifiedKind == UnifiedJsonKind.Object && sameJson(field(plan, "intents"), saved.intents()),
            "github_plugin.intent_mismatch")
        consumed.add(id); prepared.remove(id)
        channel.openWindow(invocation, false, saved.bytesHex)
        try {
            channel.write(unhex(saved.bytesHex, 30720))
            let reply = response(id)
            channel.closeWindow()
            let error = text(reply, "error")
            if (text(reply, "status") == "unknown") { channel.abort() }
            SessionReply(githubOutcome(text(reply, "status"), field(reply, "result"), error), ok: error == "")
        } catch (_: Exception) {
            channel.abort()
            SessionReply(githubOutcome("unknown", jsonNull(), "github_plugin.call_outcome_unknown"), ok: false)
        }
    }
}
