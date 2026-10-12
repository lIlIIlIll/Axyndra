package dap_plugin

import dap4cj.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

func dapRequire<T>(value: DapResult<T>): T { match (value) { case DapResult.Ok(result) => result; case DapResult.Err(error) => throw error } }
class SessionReply {
    let value: JsonNode; let ok: Bool
    init(value: JsonNode, ok!: Bool = true) { this.value = value; this.ok = ok }
}
func serviceOutcome(status: String, result: JsonNode, error!: String = ""): JsonNode {
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.service-call-result/v1")), JsonObjectEntry("status", jsonString(status)),
        JsonObjectEntry("result", result), JsonObjectEntry("error", if (error == "") { jsonNull() } else { jsonString(error) }),
        JsonObjectEntry("retry_safe", jsonBool(false))])
}
class DapCachedCall {
    let local: String; let inputDigest: String; let revision: Int64
    let requests: Array<DapPreparedRequest>; let bytesHex: String; let bytes: Int64; let retainedBytes: Int64
    let projection: DapFrozenPolicy
    var charge: ?PayloadCharge = None
    init(local: String, input: String, revision: Int64, requests: Array<DapPreparedRequest>, projection: DapFrozenPolicy) {
        this.projection = projection
        this.local = local; this.inputDigest = sha(input); this.revision = revision; this.requests = requests
        let raw = ArrayList<Byte>(); var retained: Int64 = input.size + projection.retainedBytes()
        for (request in requests) {
            let frame = request.framedBytes(); raw.add(all: frame)
            // Library retains immutable arguments/request/frame strings until
            // dispatch; our cache owns their lifetime after dispatch too.
            retained += request.requestJson.size * 2 + frame.size
        }
        bytes = raw.size; bytesHex = hex(raw.toArray()); retainedBytes = retained + bytesHex.size
    }
    func intents(): JsonNode { jsonArray([jsonObject([JsonObjectEntry("id", jsonString("dap-call")), JsonObjectEntry("bytes_hex", jsonString(bytesHex))])]) }
    func close(): Unit { match (charge) { case Some(value) => value.close(); case None => () }; charge = None }
}
class DapEvents {
    private let lock = Mutex()
    private let encoded = ArrayList<String>()
    private var bytes: Int64 = 0
    private var omitted: Int64 = 0
    private let storage = payloadPool.acquire(524288, transfer: false)
    private let consumed = ArrayList<OwnedProtocolFrame>()
    private let budget = DapResponseBudget(32768)
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
class DapPluginSession {
    let channel: BrokerChannel
    private let output: WireOutput
    private var client: ?DapClient = None
    private var configuration: ?DapConfiguration = None
    private let prepared = HashMap<String, DapCachedCall>()
    private let consumed = HashSet<String>()
    private var revision: Int64 = 0
    private var preparedBytes: Int64 = 0
    private let events = DapEvents()
    private let policy = DapSessionPolicy()
    private let stateStorage = payloadPool.acquire(2097152, transfer: false)
    private var ownedDebug: ?DapOwnedDebugRegistry = None
    init(output: WireOutput) { this.output = output; channel = BrokerChannel(output) }
    func receive(frame: JsonNode): Unit { channel.receive(frame) }
    func abort(): Unit { channel.abort(); match (ownedDebug) { case Some(value) => value.abort(); case None => () } }
    func stop(): Unit {
        abort(); match (client) { case Some(value) => let _ = value.close(); case None => () }
        for ((_, value) in prepared) { value.close() }; prepared.clear(); preparedBytes = 0
    }
    func finishInvocation(): Unit {
        match (client) { case Some(value) => value.releaseConsumedResponses(); case None => () }
        events.releaseConsumed()
        match (ownedDebug) { case Some(value) => value.finishInvocation(); case None => () }
    }
    func close(): Unit { stop(); events.close(); policy.close(); stateStorage.close()
        match (ownedDebug) { case Some(value) => value.close(); case None => () }; ownedDebug = None }
    private func completed(result: JsonNode, error!: String = "", ok!: Bool = true): SessionReply {
        let original = serviceOutcome("complete", result, error: error)
        let entries = ArrayList<JsonObjectEntry>()
        for (entry in result.fields) { entries.add(entry) }
        entries.add(JsonObjectEntry("snapshot", policy.snapshot()))
        let augmented = serviceOutcome("complete", jsonObject(entries.toArray()), error: error)
        // The optional observation must not displace a previously supported
        // raw response at the exact negotiated terminal capacity boundary.
        SessionReply(if (stringifyUnifiedJson(augmented).size <= output.limits.result) { augmented } else { original }, ok: ok)
    }
    func handle(invocation: JsonNode, deadline: MonoTime): SessionReply {
        require(!channel.isClosed(), "dap_plugin.session_closed")
        require(MonoTime.now() < deadline, "dap_plugin.request_expired")
        let args = field(invocation, "arguments")
        if(text(args,"action")=="channel_directory") {
            exact(args,["action"]);require(text(invocation,"kind")=="service_prepare" && client.isNone(),"dap_plugin.owned_entry_required")
            let directory=dapOwnedDebugDirectory();require(stringifyUnifiedJson(directory).size<=output.limits.directory,"dap_plugin.directory_limit")
            return SessionReply(directory)
        }
        if(text(args,"action")=="channel_prepare") {
            require(text(invocation,"kind")=="service_prepare" && client.isNone(),"dap_plugin.owned_entry_required")
            if(ownedDebug.isNone()){ownedDebug=Some(DapOwnedDebugRegistry(output.limits))}
            return ownedDebug.getOrThrow().handle(invocation,args,deadline)
        }
        if (text(args, "action").startsWith("debug_") || text(args,"action").startsWith("channel_")) {
            require(text(invocation, "kind") == "service" && client.isNone(), "dap_plugin.owned_entry_required")
            if (ownedDebug.isNone()) { ownedDebug = Some(DapOwnedDebugRegistry(output.limits)) }
            return ownedDebug.getOrThrow().handle(invocation, args, deadline)
        }
        require(ownedDebug.isNone(), "dap_plugin.raw_session_conflict")
        if (text(invocation, "kind") == "service_prepare") { return prepare(invocation, args) }
        if (text(args, "action") == "start") { return start(invocation, args, deadline) }
        if (text(args, "action") == "refresh") { throw PluginFailure("dap_plugin.refresh_not_implemented") }
        execute(invocation, args, deadline)
    }
    private func start(invocation: JsonNode, args: JsonNode, deadline: MonoTime): SessionReply {
        exact(args, ["action", "configuration"]); require(client.isNone(), "dap_plugin.already_started")
        let selected = DapConfiguration(field(args, "configuration"), output.limits); configuration = Some(selected)
        channel.openWindow(invocation, true, deadline)
        try {
            let captured = events; let state = policy
            let connected = DapClient(channel, maxFrameBytes: output.limits.result,
                frameBudget: Some(DapResponseBudget(output.limits.result)), discardPreparedAfterDispatch: true,
                eventHandler: { event, body => state.event(event, body); captured.append(event, body) },
                reverseRequestHandler: { _, _ => DapResult.Err(DapError(DapErrorKind.Protocol,
                    "dap_plugin.reverse_request_requires_host_operation", "reverse request has no independently approved host operation")) })
            client = Some(connected)
            let initialized = dapRequire(connected.initialize(selected.initialization(), timeoutMillis: selected.timeoutMillis))
            require(initialized.unifiedKind == UnifiedJsonKind.Object, "dap_plugin.initialize_invalid")
            policy.configure(initialized)
            channel.closeWindow()
            let directory = actionDirectory(); require(stringifyUnifiedJson(directory).size <= output.limits.directory, "dap_plugin.directory_limit")
            SessionReply(directory)
        } catch (error: Exception) { stop(); throw error }
    }
    private func prepare(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input"])
        require(client.isSome() && text(args, "action") == "call", "dap_plugin.not_started")
        let name = text(args, "tool"); require(actionNames().contains(name), "dap_plugin.action_unknown")
        let id = stableId(invocation); require(!consumed.contains(id), "dap_plugin.prepared_consumed")
        let input = field(args, "input"); let encoded = stringifyUnifiedJson(input)
        require(encoded.size <= output.limits.input, "dap_plugin.input_limit")
        match (prepared.get(id)) {
            case Some(cached) =>
                require(cached.local == name && cached.revision == revision && cached.inputDigest == sha(encoded), "dap_plugin.prepared_changed")
                policy.validate(cached.projection)
                return SessionReply(jsonObject([JsonObjectEntry("intents", cached.intents())]))
            case None => ()
        }
        require(prepared.size < 128 && consumed.size + prepared.size < 4096, "dap_plugin.prepared_capacity")
        let requests = ArrayList<DapPreparedRequest>(); var retained = false
        try {
            let projection = policy.prepare(name, input)
            let batch = projection.requests()
            for (index in 0..batch.size) {
                requests.add(dapRequire(client.getOrThrow().prepareRequest(id + ":" + index.toString(),
                    text(batch[index], "command"), field(batch[index], "arguments"))))
            }
            let cached = DapCachedCall(name, encoded, revision, requests.toArray(), projection.frozen)
            require(cached.bytes <= output.limits.request, "dap_plugin.request_limit")
            require(cached.retainedBytes <= output.limits.cache - preparedBytes, "dap_plugin.prepared_capacity")
            let result = jsonObject([JsonObjectEntry("intents", cached.intents())])
            require(stringifyUnifiedJson(result).size <= output.limits.prepared, "dap_plugin.prepare_limit")
            cached.charge = Some(payloadPool.acquire(cached.retainedBytes, transfer: false))
            prepared.add(id, cached); preparedBytes += cached.retainedBytes; retained = true
            SessionReply(result)
        } finally { if (!retained) { for (request in requests) { client.getOrThrow().discardPrepared(request) } } }
    }
    private func execute(invocation: JsonNode, args: JsonNode, deadline: MonoTime): SessionReply {
        exact(args, ["action", "tool", "input", "host_plan"])
        require(client.isSome() && text(args, "action") == "call", "dap_plugin.not_started")
        let id = stableId(invocation); require(!consumed.contains(id), "dap_plugin.prepared_consumed")
        let cached = prepared.get(id).getOrThrow()
        require(cached.revision == revision && cached.local == text(args, "tool") &&
            cached.inputDigest == sha(stringifyUnifiedJson(field(args, "input"))), "dap_plugin.prepared_changed")
        let plan = field(args, "host_plan"); exact(plan, ["version", "binding", "intents"])
        require(field(plan, "binding").unifiedKind == UnifiedJsonKind.Object, "dap_plugin.host_plan_invalid")
        if (text(plan, "version") == "process-channel-intent-v2") {
            require(output.limits.payload.isSome(), "dap_plugin.payload_unsupported")
            let intents = field(plan, "intents"); require(intents.unifiedKind == UnifiedJsonKind.List && intents.items.size == 1)
            let intent = intents.items[0]; exact(intent, ["id", "payload"])
            let payload = field(intent, "payload"); exact(payload, ["schema", "artifact_ref", "encoding", "bytes", "sha256", "encoded_sha256"])
            let raw = unhex(cached.bytesHex, output.limits.request)
            require(text(intent, "id") == "dap-call" && text(payload, "schema") == "axyndra.service-payload/v1" && text(payload, "encoding") == "hex" &&
                number(payload, "bytes") == raw.size && text(payload, "sha256") == sha(String.fromUtf8(raw)) &&
                text(payload, "encoded_sha256") == sha(cached.bytesHex) && text(payload, "artifact_ref") == "blob:sha256:" + sha(cached.bytesHex), "dap_plugin.intent_changed")
        } else { require(text(plan, "version") == "process-channel-intent-v1" && sameJson(field(plan, "intents"), cached.intents()), "dap_plugin.intent_changed") }
        // Last pure state check occurs before consuming the prepared call or
        // opening its only actual host window. No new request is appended.
        let dispatchContext = policy.adopt(cached.projection)
        consumed.add(id); prepared.remove(id); preparedBytes -= cached.retainedBytes
        try {
            channel.openWindow(invocation, false, cached.bytesHex, deadline)
            let outcome = client.getOrThrow().dispatchPreparedBatch(cached.requests, timeoutMillis: configuration.getOrThrow().timeoutMillis)
            channel.closeWindow(); revision += 1
            match (outcome) {
                case DapResult.Ok(values) =>
                    policy.observeResponses(cached.projection, values, dispatchContext)
                    completed(jsonObject([JsonObjectEntry("responses", jsonArray(values)), JsonObjectEntry("events", events.take())]))
                case DapResult.Err(error) =>
                    if (error.code == "dap.adapter_error") {
                        completed(jsonObject([JsonObjectEntry("protocol_error", jsonString(error.message)), JsonObjectEntry("events", events.take())]), error: error.code, ok: false)
                    } else { stop(); SessionReply(serviceOutcome("unknown", events.take(), error: "dap_plugin.call_outcome_unknown"), ok: false) }
            }
        } catch (_: Exception) { stop(); SessionReply(serviceOutcome("unknown", events.take(), error: "dap_plugin.call_outcome_unknown"), ok: false) }
        finally { cached.close() }
    }
}
