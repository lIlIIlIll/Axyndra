package lsp_plugin

import lsp4cj.*
import process4cj.*
import std.collection.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

func lspRequire<T>(value: LspResult<T>): T { match (value) { case LspResult.Ok(result) => result; case LspResult.Err(error) => throw error } }
class SessionReply {
    let value: JsonNode
    let ok: Bool
    init(value: JsonNode, ok!: Bool = true) { this.value = value; this.ok = ok }
}
func serviceOutcome(status: String, result: JsonNode, error!: String = ""): JsonNode {
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.service-call-result/v1")), JsonObjectEntry("status", jsonString(status)),
        JsonObjectEntry("result", result), JsonObjectEntry("error", if (error == "") { jsonNull() } else { jsonString(error) }),
        JsonObjectEntry("retry_safe", jsonBool(false))])
}
class LspCachedCall {
    let local: String
    let inputDigest: String
    let revision: Int64
    let request: LspPreparedRequest
    let updates: Array<DocumentUpdate>
    let bytesHex: String
    let retainedBytes: Int64
    var charge: ?PayloadCharge = None
    init(local: String, input: String, revision: Int64, request: LspPreparedRequest, updates: Array<DocumentUpdate>) {
        this.local = local; this.inputDigest = sha(input); this.revision = revision; this.request = request; this.updates = updates
        let encoded = hex(request.framedBytes()); bytesHex = encoded
        retainedBytes = input.size * 2 + request.requestJson.size + encoded.size
    }
    func intents(): JsonNode { jsonArray([jsonObject([JsonObjectEntry("id", jsonString("lsp-call")), JsonObjectEntry("bytes_hex", jsonString(bytesHex))])]) }
    func close(): Unit { match (charge) { case Some(value) => value.close(); case None => () }; charge = None }
}
class LspNotices {
    private let lock = Mutex()
    private let encoded = ArrayList<String>()
    private var bytes: Int64 = 0
    private var omitted: Int64 = 0
    private let storage = payloadPool.acquire(524288, transfer: false)
    private let consumed = ArrayList<OwnedProtocolFrame>()
    private let budget = LspResponseBudget(32768)
    func append(method: String, value: JsonNode): Unit {
        let item = stringifyUnifiedJson(jsonObject([JsonObjectEntry("method", jsonString(method)), JsonObjectEntry("params", value)]))
        let bounded = if (item.size <= 32768) { try { let _ = parseUnifiedJson(item, maxBytes: 32768, maxDepth: 32); true } catch (_: Exception) { false } } else { false }
        lock.lock()
        try {
            if (!bounded || item.size > 32768 || encoded.size >= 64 || item.size > 262144 - bytes) { omitted += 1; return }
            encoded.add(item); bytes += item.size
        } finally { lock.unlock() }
    }
    func take(): JsonNode {
        lock.lock()
        try {
            let values = ArrayList<JsonNode>()
            for (item in encoded) {
                let reserved = budget.reserve(item.size)
                let frame = OwnedProtocolFrame(item.toArray(), Some(reserved))
                var retained = false
                try {
                    frame.beforeDecode(); values.add(parseUnifiedJson(item, maxBytes: 32768, maxDepth: 32))
                    consumed.add(frame); retained = true
                } finally { if (!retained) { frame.close() } }
            }
            let result = jsonObject([JsonObjectEntry("events", jsonArray(values.toArray())), JsonObjectEntry("omitted", jsonNumber(omitted.toString()))])
            encoded.clear(); bytes = 0; omitted = 0; result
        } finally { lock.unlock() }
    }
    func releaseConsumed(): Unit {
        lock.lock(); let old = try { let values = consumed.toArray(); consumed.clear(); values } finally { lock.unlock() }
        for (frame in old) { frame.close() }
    }
    func close(): Unit { releaseConsumed(); storage.close() }

}
class LspPluginSession {
    let channel: BrokerChannel
    private let output: WireOutput
    private var client: ?LspClient = None
    private var configuration: ?LspConfiguration = None
    private let prepared = HashMap<String, LspCachedCall>()
    private let consumed = HashSet<String>()
    private let versions = HashMap<String, Int64>()
    private var revision: Int64 = 0
    private var preparedBytes: Int64 = 0
    private let notices = LspNotices()
    // 1024 bounded URI/version entries, 4096 dispatch tombstones, configuration
    // and map overhead remain retained across calls, independently of a reply.
    private let stateStorage = payloadPool.acquire(5242880, transfer: false)
    init(output: WireOutput) { this.output = output; channel = BrokerChannel(output) }
    func receive(frame: JsonNode): Unit { channel.receive(frame) }
    func abort(): Unit { channel.abort() }
    func stop(): Unit {
        abort(); match (client) { case Some(value) => let _ = value.close(); case None => () }
        for ((_, value) in prepared) { value.close() }; prepared.clear(); preparedBytes = 0
        versions.clear()
    }
    func finishInvocation(): Unit {
        match (client) { case Some(value) => value.releaseConsumedResponses(); case None => () }
        notices.releaseConsumed()
    }
    func close(): Unit { stop(); notices.close(); stateStorage.close() }
    func handle(invocation: JsonNode, deadline: MonoTime): SessionReply {
        require(!channel.isClosed(), "lsp_plugin.session_closed")
        require(MonoTime.now() < deadline, "lsp_plugin.request_expired")
        let args = field(invocation, "arguments")
        if (text(invocation, "kind") == "service_prepare") { return prepare(invocation, args) }
        if (text(args, "action") == "start") { return start(invocation, args, deadline) }
        if (text(args, "action") == "refresh") { throw PluginFailure("lsp_plugin.refresh_not_implemented") }
        execute(invocation, args, deadline)
    }
    private func start(invocation: JsonNode, args: JsonNode, deadline: MonoTime): SessionReply {
        exact(args, ["action", "configuration"]); require(client.isNone(), "lsp_plugin.already_started")
        let selected = LspConfiguration(field(args, "configuration"), output.limits)
        configuration = Some(selected)
        channel.openWindow(invocation, true, deadline)
        try {
            let captured = notices
            let connected = LspClient(channel, maxFrameBytes: output.limits.result, frameBudget: Some(LspResponseBudget(output.limits.result)),
                notificationHandler: { method, params => captured.append(method, params) },
                requestHandler: { method, params =>
                    if (method == "workspace/workspaceFolders") { LspResult.Ok(selected.folders()) }
                    else if (method == "workspace/configuration") {
                        let items = field(params, "items"); let result = ArrayList<JsonNode>()
                        if (items.unifiedKind != UnifiedJsonKind.List || items.items.size > 128) {
                            LspResult.Err(LspError(LspErrorKind.Protocol, "lsp_plugin.configuration_request_invalid", "bounded configuration request required"))
                        } else {
                            for (item in items.items) {
                                var value = selected.settingsValue()
                                let section = text(item, "section")
                                if (section != "") { for (part in section.split(".")) { value = field(value, part) } }
                                result.add(value)
                            }
                            LspResult.Ok(jsonArray(result.toArray()))
                        }
                    } else { LspResult.Err(LspError(LspErrorKind.Protocol, "lsp_plugin.server_request_requires_host_operation", "server request has no independently approved host operation")) }
                })
            client = Some(connected)
            let initialized = lspRequire(connected.initialize(selected.initialization(), timeoutMillis: selected.timeoutMillis))
            let encoding = text(field(initialized, "capabilities"), "positionEncoding")
            require(encoding == "" || encoding == "utf-16", "lsp_plugin.position_encoding_unsupported")
            channel.closeWindow()
            let directory = actionDirectory()
            require(stringifyUnifiedJson(directory).size <= output.limits.directory, "lsp_plugin.directory_limit")
            SessionReply(directory)
        } catch (error: Exception) { stop(); throw error }
    }
    private func prepare(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input"])
        require(client.isSome() && text(args, "action") == "call", "lsp_plugin.not_started")
        let name = text(args, "tool"); require(actionNames().contains(name), "lsp_plugin.action_unknown")
        let id = stableId(invocation); require(!consumed.contains(id), "lsp_plugin.prepared_consumed")
        let input = field(args, "input"); let encoded = stringifyUnifiedJson(input)
        require(encoded.size <= output.limits.input, "lsp_plugin.input_limit")
        match (prepared.get(id)) {
            case Some(cached) =>
                require(cached.local == name && cached.revision == revision && cached.inputDigest == sha(encoded), "lsp_plugin.prepared_changed")
                return SessionReply(jsonObject([JsonObjectEntry("intents", cached.intents())]))
            case None => ()
        }
        match (lspResourceReadRequest(input, configuration.getOrThrow())) {
            case Some(request) => return SessionReply(request)
            case None => ()
        }
        require(prepared.size < 128 && consumed.size + prepared.size < 4096, "lsp_plugin.prepared_capacity")
        let business = lspMaterializeResources(input, configuration.getOrThrow())
        let updates = documentUpdates(business, configuration.getOrThrow(), versions)
        require(versions.size + updates.size <= 1024, "lsp_plugin.document_capacity")
        let notifications = ArrayList<LspNotification>()
        for (update in updates) { notifications.add(update.notification) }
        let method = actionMethod(name, business)
        if (name == "notify") { notifications.add(LspNotification(method, field(business, "params"))) }
        let frozen = lspRequire(client.getOrThrow().prepareRequest(id, if (name == "notify") { "" } else { method },
            field(business, "params"), notifications: notifications.toArray()))
        require(frozen.framedBytes().size <= output.limits.request, "lsp_plugin.request_limit")
        let cached = LspCachedCall(name, encoded, revision, frozen, updates)
        require(cached.retainedBytes <= output.limits.cache - preparedBytes, "lsp_plugin.prepared_capacity")
        let result = jsonObject([JsonObjectEntry("intents", cached.intents())])
        require(stringifyUnifiedJson(result).size <= output.limits.prepared, "lsp_plugin.prepare_limit")
        cached.charge = Some(payloadPool.acquire(cached.retainedBytes, transfer: false))
        prepared.add(id, cached); preparedBytes += cached.retainedBytes
        SessionReply(result)
    }
    private func execute(invocation: JsonNode, args: JsonNode, deadline: MonoTime): SessionReply {
        exact(args, ["action", "tool", "input", "host_plan"])
        require(client.isSome() && text(args, "action") == "call", "lsp_plugin.not_started")
        let id = stableId(invocation); require(!consumed.contains(id), "lsp_plugin.prepared_consumed")
        let cached = prepared.get(id).getOrThrow()
        require(cached.revision == revision && cached.local == text(args, "tool") &&
            cached.inputDigest == sha(stringifyUnifiedJson(field(args, "input"))), "lsp_plugin.prepared_changed")
        let plan = field(args, "host_plan"); exact(plan, ["version", "binding", "intents"])
        require(field(plan, "binding").unifiedKind == UnifiedJsonKind.Object, "lsp_plugin.host_plan_invalid")
        if (text(plan, "version") == "process-channel-intent-v2") {
            require(output.limits.payload.isSome(), "lsp_plugin.payload_unsupported")
            let intents = field(plan, "intents"); require(intents.unifiedKind == UnifiedJsonKind.List && intents.items.size == 1)
            let intent = intents.items[0]; exact(intent, ["id", "payload"])
            let payload = field(intent, "payload"); exact(payload, ["schema", "artifact_ref", "encoding", "bytes", "sha256", "encoded_sha256"])
            let raw = cached.request.framedBytes()
            require(text(intent, "id") == "lsp-call" && text(payload, "schema") == "axyndra.service-payload/v1" && text(payload, "encoding") == "hex" &&
                number(payload, "bytes") == raw.size && text(payload, "sha256") == sha(String.fromUtf8(raw)) &&
                text(payload, "encoded_sha256") == sha(cached.bytesHex) && text(payload, "artifact_ref") == "blob:sha256:" + sha(cached.bytesHex), "lsp_plugin.intent_changed")
        } else { require(text(plan, "version") == "process-channel-intent-v1" && sameJson(field(plan, "intents"), cached.intents()), "lsp_plugin.intent_changed") }
        consumed.add(id); prepared.remove(id); preparedBytes -= cached.retainedBytes
        try {
            channel.openWindow(invocation, false, cached.bytesHex, deadline)
            let outcome = client.getOrThrow().dispatchPrepared(cached.request, timeoutMillis: configuration.getOrThrow().timeoutMillis)
            var applicationPlan: JsonNode = jsonNull()
            match (outcome) {
                case LspResult.Ok(value) =>
                    if (cached.local == "rename" || cached.local == "rename_file") {
                        let proposal = languageFileProposal(value,
                            lspMaterializeResources(field(args, "input"), configuration.getOrThrow()), configuration.getOrThrow().rootUri)
                        if (proposal.unifiedKind != UnifiedJsonKind.Null) { applicationPlan = channel.proposeFiles(proposal) }
                    }
                case _ => ()
            }
            channel.closeWindow()
            for (update in cached.updates) { versions.add(update.uri, update.version) }
            revision += 1
            match (outcome) {
                case LspResult.Ok(value) => SessionReply(serviceOutcome("complete", jsonObject([JsonObjectEntry("value", value), JsonObjectEntry("notifications", notices.take()),
                    JsonObjectEntry("workspace_changes_applied", jsonBool(false)), JsonObjectEntry("application_plan", applicationPlan)])))
                case LspResult.Err(error) =>
                    if (error.code == "lsp.server_error") {
                        SessionReply(serviceOutcome("complete", jsonObject([JsonObjectEntry("protocol_error", jsonString(error.message)), JsonObjectEntry("notifications", notices.take())]), error: error.code), ok: false)
                    } else { stop(); SessionReply(serviceOutcome("unknown", notices.take(), error: "lsp_plugin.call_outcome_unknown"), ok: false) }
            }
        } catch (_: Exception) { stop(); SessionReply(serviceOutcome("unknown", notices.take(), error: "lsp_plugin.call_outcome_unknown"), ok: false) }
        finally { cached.close() }
    }
}
