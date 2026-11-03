package mcp_client_plugin

import mcp4cj.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

func mcpRequire<T>(result: McpResult<T>): T {
    match (result) { case McpResult.Ok(value) => value; case McpResult.Err(error) => throw error }
}
class CachedCall {
    let localName: String
    let inputText: String
    let prepared: McpPreparedToolCall
    let bytesHex: String
    let httpRequest: ?JsonNode
    let retainedBytes: Int64
    var dispatched = false
    var charge: ?PayloadCharge = None
    init(localName: String, inputText: String, prepared: McpPreparedToolCall, config: McpPluginConfiguration, metadataBytes!: Int64 = 0) {
        this.localName = localName; this.inputText = inputText; this.prepared = prepared
        if (config.transport == "http") {
            require(prepared.httpExchange.isSome(), "mcp_plugin.http_prepared_missing")
            httpRequest = Some(frozenHttpRequest(prepared.httpExchange.getOrThrow(), config)); bytesHex = ""
        } else { bytesHex = hex(prepared.stdioFrame()); httpRequest = None }
        retainedBytes = metadataBytes + inputText.size + prepared.rpcJson.size + bytesHex.size +
            match (httpRequest) { case Some(value) => stringifyUnifiedJson(value).size; case None => 0 }
    }
    func retain(): Unit { charge = Some(payloadPool.acquire(retainedBytes, transfer: false)) }
    func close(): Unit { match (charge) { case Some(value) => value.close(); case None => () }; charge = None }
    func intents(): JsonNode {
        match (httpRequest) {
            case Some(request) => return jsonArray([jsonObject([JsonObjectEntry("id", jsonString("mcp-call")),
                JsonObjectEntry("request", request)])])
            case None => ()
        }
        jsonArray([jsonObject([JsonObjectEntry("id", jsonString("mcp-call")), JsonObjectEntry("bytes_hex", jsonString(bytesHex))])])
    }
}
class SessionReply {
    let value: JsonNode
    let ok: Bool
    init(value: JsonNode) { this.value = value; this.ok = true }
    init(value: JsonNode, ok: Bool) { this.value = value; this.ok = ok }
}
func serviceOutcome(status: String, result: JsonNode): JsonNode { serviceOutcome(status, result, "") }
func serviceOutcome(status: String, result: JsonNode, error: String): JsonNode {
    jsonObject([JsonObjectEntry("schema", jsonString("axyndra.service-call-result/v1")),
        JsonObjectEntry("status", jsonString(status)), JsonObjectEntry("result", result),
        JsonObjectEntry("error", if (error == "") { jsonNull() } else { jsonString(error) }),
        JsonObjectEntry("retry_safe", jsonBool(false))])
}
class McpPluginSession {
    let channel: BrokerChannel
    private let output: WireOutput
    private var http: ?BrokerHttpExchangePort = None
    private var client: ?McpClient = None
    private let tools = HashMap<String, McpTool>()
    private let prepared = HashMap<String, CachedCall>()
    private let consumed = HashSet<String>()
    private var retainedPreparedBytes: Int64 = 0
    private var directoryCharge: ?PayloadCharge = None
    private var started = false
    private var configuration: ?McpPluginConfiguration = None
    private var responseReservation: ?PayloadCharge = None
    init(output: WireOutput) { this.output = output; channel = BrokerChannel(output) }
    func receive(frame: JsonNode): Unit {
        match (http) { case Some(value) => value.receive(frame); case None => channel.receive(frame) }
    }
    func abort(): Unit {
        channel.abort(); match (http) { case Some(value) => value.abort(); case None => () }
    }
    private func closeWindow(): Unit {
        match (http) { case Some(value) => value.closeWindow(); case None => channel.closeWindow() }
    }
    func close(): Unit {
        abort()
        match (client) { case Some(value) => let _ = value.close(); case None => () }
        for ((_, cached) in prepared) { cached.close() }
        prepared.clear(); retainedPreparedBytes = 0
        tools.clear()
        match (directoryCharge) { case Some(value) => value.close(); case None => () }; directoryCharge = None
    }
    func handle(invocation: JsonNode, responseBudget!: ?PayloadCharge = None): SessionReply {
        require(!channel.isClosed(), "mcp_plugin.session_closed")
        match (http) { case Some(value) => require(!value.isClosed(), "mcp_plugin.session_closed"); case None => () }
        responseReservation = responseBudget
        match (http) { case Some(value) => value.setResponseReservation(responseBudget); case None => () }
        let args = field(invocation, "arguments")
        if (text(invocation, "kind") == "service_prepare") { return prepare(invocation, args) }
        if (text(args, "action") == "start") { return start(invocation, args) }
        if (text(args, "action") == "refresh") { return refresh(invocation, args) }
        execute(invocation, args)
    }
    private func start(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "configuration"])
        require(!started && client.isNone(), "mcp_plugin.session_already_started")
        let selected = McpPluginConfiguration(field(args, "configuration"), limits: output.limits)
        configuration = Some(selected)
        // Operator grants remain host-owned for both transports. Merely
        // selecting a URL cannot open a socket from this endpoint sandbox.
        try {
            let framing = McpFramingConfig(maxFrameBytes: selected.maxFrameBytes, requestTimeoutMillis: selected.requestTimeoutMillis,
                gracefulShutdownMillis: selected.gracefulShutdownMillis, maxConcurrentRequests: 1)
            let transport: McpTransport = if (selected.transport == "http") {
                let port = BrokerHttpExchangePort(output, selected); port.setResponseReservation(responseReservation); http = Some(port)
                port.openWindow(invocation, true, jsonNull())
                mcpRequire(attachStreamableHttpMcpTransport(McpStreamableHttpClientConfig(selected.url,
                    preferSse: selected.preferSse, origin: selected.origin, headers: selected.headers, framing: framing), port))
            } else {
                channel.openWindow(invocation, true)
                mcpRequire(attachStdioMcpTransport(channel, framing: framing))
            }
            let connected = McpClient(transport, McpRequestMeta(clientInfo: Some(McpImplementationInfo("axyndra-mcp-plugin", "1.0.0"))))
            client = Some(connected)
            let _ = mcpRequire(connected.discover())
            let directory = readDirectory(connected, selected)
            closeWindow(); started = true
            SessionReply(directory)
        } catch (error: Exception) { close(); throw error }
    }
    private func readDirectory(connected: McpClient, selected: McpPluginConfiguration): JsonNode {
        let nextTools = HashMap<String, McpTool>()
            let entries = ArrayList<JsonNode>()
            let cursors = HashSet<String>()
            var cursor = ""
            var directoryTtl: Int64 = -1
            var directoryScope = ""
            var complete = false
            var metadataBytes: Int64 = 0
            var metadataNodes: Int64 = 0
            for (_ in 0..selected.maxPages) {
                let page = mcpRequire(connected.listTools(cursor: cursor))
                // Preserve the library's cross-page cache contract while keeping
                // the exact operator-selected finite page/tool bounds.
                if (directoryTtl < 0) {
                    directoryTtl = page.ttlMillis; directoryScope = page.cacheScope
                } else {
                    require(directoryTtl == page.ttlMillis && directoryScope == page.cacheScope,
                        "mcp_plugin.directory_metadata_changed")
                }
                for (tool in page.tools) {
                    require(entries.size < selected.maxTools && tool.name.size <= 4096, "mcp_plugin.directory_limit")
                    let local = "t_" + sha(tool.name)
                    require(!nextTools.contains(local), "mcp_plugin.directory_duplicate")
                    if (output.limits.payload.isSome()) {
                        let metadata = stringifyUnifiedJson(tool.toValue())
                        require(metadata.size <= output.limits.directory - metadataBytes, "mcp_plugin.directory_limit")
                        metadataBytes += metadata.size; metadataNodes += payloadNodeCount(metadata)
                        require(metadataNodes <= 65536, "mcp_plugin.payload_nodes")
                    }
                    nextTools.add(local, tool)
                    let description = "MCP " + tool.name + ": " + tool.description
                    require(description.size <= 4096, "mcp_plugin.directory_limit")
                    entries.add(jsonObject([JsonObjectEntry("name", jsonString(local)),
                        JsonObjectEntry("description", jsonString(description)), JsonObjectEntry("input_schema", tool.inputSchema)]))
                }
                require(stringifyUnifiedJson(jsonObject([JsonObjectEntry("tools", jsonArray(entries.toArray()))])).size <= output.limits.directory, "mcp_plugin.directory_limit")
                if (page.nextCursor == "") { complete = true; break }
                require(!cursors.contains(page.nextCursor), "mcp_plugin.directory_cursor_repeated")
                cursors.add(page.nextCursor); cursor = page.nextCursor
            }
            require(complete, "mcp_plugin.directory_page_limit")
            // Publish the adapter's name map only after every page is valid.
            // If the later host CAS fails it revokes this entire session.
            let retained: ?PayloadCharge = if (output.limits.payload.isSome()) {
                Some(payloadPool.acquire(max(524288, metadataBytes * 4), transfer: false))
            } else { None }
            tools.clear()
            for ((name, tool) in nextTools) { tools.add(name, tool) }
            match (directoryCharge) { case Some(value) => value.close(); case None => () }
            directoryCharge = retained
            jsonObject([JsonObjectEntry("tools", jsonArray(entries.toArray()))])
    }
    private func refresh(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "configuration"])
        require(started && client.isSome(), "mcp_plugin.session_not_started")
        let selected = McpPluginConfiguration(field(args, "configuration"), limits: output.limits)
        require(selected.identity == configuration.getOrThrow().identity, "mcp_plugin.configuration_changed")
        match (http) {
            case Some(value) => value.openWindow(invocation, true, jsonNull())
            case None => channel.openRefreshWindow(invocation)
        }
        try {
            let connected = client.getOrThrow()
            connected.invalidateToolDirectory()
            let directory = readDirectory(connected, selected)
            closeWindow()
            // An old prepared frame cannot be dispatched under a new directory.
            // Keep its consumed key rather than allowing an ID to be reminted.
            for ((id, cached) in prepared) { consumed.add(id); cached.close() }
            prepared.clear(); retainedPreparedBytes = 0
            SessionReply(directory)
        } catch (error: Exception) { close(); throw error }
    }
    private func prepare(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input"])
        require(started && text(args, "action") == "call", "mcp_plugin.session_not_started")
        let local = text(args, "tool")
        let tool = tools.get(local)
        require(tool.isSome(), "mcp_plugin.tool_unknown")
        require(field(args, "input").unifiedKind == UnifiedJsonKind.Object)
        match (tool.getOrThrow().execution) {
            case Some(value) => require(value.taskSupport != McpTaskSupport.Required, "mcp_plugin.tasks_unsupported")
            case None => ()
        }
        let id = stableId(invocation)
        require(!consumed.contains(id), "mcp_plugin.prepared_consumed")
        let input = stringifyUnifiedJson(field(args, "input"))
        require(input.size <= output.limits.input, "mcp_plugin.input_limit")
        let existing = prepared.get(id)
        if (existing.isSome()) {
            let prior = existing.getOrThrow()
            require(!prior.dispatched, "mcp_plugin.prepared_consumed")
            require(prior.localName == local && sameJson(parseUnifiedJson(prior.inputText, maxBytes: output.limits.input), field(args, "input")),
                "mcp_plugin.prepared_identity_conflict")
            return SessionReply(jsonObject([JsonObjectEntry("intents", prior.intents())]))
        }
        // Retain at most 128 undelivered frames within the selected byte cap, plus bounded
        // consumed-ID tombstones. Never evict an ID and accidentally reuse it.
        require(prepared.size < 128 && consumed.size + prepared.size < 4096, "mcp_plugin.prepared_capacity")
        let frozen = mcpRequire(client.getOrThrow().prepareToolCall(id, tool.getOrThrow().name, field(args, "input"), owner: id))
        require(frozen.stdioFrame().size <= output.limits.request, "mcp_plugin.rpc_frame_limit")
        let metadataBytes = if (output.limits.payload.isSome()) { stringifyUnifiedJson(tool.getOrThrow().toValue()).size } else { 0 }
        let cached = CachedCall(local, input, frozen, configuration.getOrThrow(), metadataBytes: metadataBytes)
        let value = jsonObject([JsonObjectEntry("intents", cached.intents())])
        require(stringifyUnifiedJson(value).size <= output.limits.prepared, "mcp_plugin.prepare_output_limit")
        require(cached.retainedBytes <= output.limits.cache - retainedPreparedBytes, "mcp_plugin.prepared_capacity")
        if (output.limits.payload.isSome()) { cached.retain() }
        prepared.add(id, cached); retainedPreparedBytes += cached.retainedBytes
        SessionReply(value)
    }
    private func execute(invocation: JsonNode, args: JsonNode): SessionReply {
        exact(args, ["action", "tool", "input", "host_plan"])
        require(started && text(args, "action") == "call", "mcp_plugin.session_not_started")
        let id = stableId(invocation)
        require(!consumed.contains(id), "mcp_plugin.prepared_consumed")
        let saved = prepared.get(id)
        require(saved.isSome(), "mcp_plugin.prepared_missing")
        let cached = saved.getOrThrow()
        require(!cached.dispatched, "mcp_plugin.prepared_consumed")
        require(cached.localName == text(args, "tool") && sameJson(parseUnifiedJson(cached.inputText, maxBytes: output.limits.input), field(args, "input")),
            "mcp_plugin.prepared_identity_conflict")
        let plan = field(args, "host_plan")
        exact(plan, ["version", "binding", "intents"])
        require(field(plan, "binding").unifiedKind == UnifiedJsonKind.Object, "mcp_plugin.host_plan_invalid")
        // Authority and the added network rule are host verified. This adapter
        // only ensures that execution still uses its exact immutable request.
        match (cached.httpRequest) {
            case Some(request) =>
                let payloadMode = text(plan, "version") == "http-stream-intents/v2"
                require((payloadMode && output.limits.payload.isSome()) ||
                    (!payloadMode && text(plan, "version") == "http-stream-intents/v1" && output.limits.payload.isNone()), "mcp_plugin.host_plan_invalid")
                let intents = field(plan, "intents")
                require(intents.unifiedKind == UnifiedJsonKind.List && intents.items.size == 1, "mcp_plugin.intent_mismatch")
                let intent = intents.items[0]; exact(intent, ["id", "request", "network"])
                var expected = request
                if (payloadMode) {
                    let raw = cached.prepared.httpExchange.getOrThrow().body
                    let hexadecimal = text(request, "body_hex")
                    let entries = ArrayList<JsonObjectEntry>()
                    for (entry in request.fields where entry.name != "body_hex") { entries.add(JsonObjectEntry(entry.name, entry.value)) }
                    entries.add(JsonObjectEntry("body_payload", jsonObject([
                        JsonObjectEntry("schema", jsonString("axyndra.service-payload/v1")),
                        JsonObjectEntry("artifact_ref", jsonString("blob:sha256:" + sha(hexadecimal))),
                        JsonObjectEntry("encoding", jsonString("hex")), JsonObjectEntry("bytes", jsonNumber(raw.size.toString())),
                        JsonObjectEntry("sha256", jsonString(sha(raw))), JsonObjectEntry("encoded_sha256", jsonString(sha(hexadecimal)))])))
                    expected = jsonObject(entries.toArray())
                }
                require(text(intent, "id") == "mcp-call" && sameJson(field(intent, "request"), expected) &&
                    field(intent, "network").unifiedKind == UnifiedJsonKind.Object, "mcp_plugin.intent_mismatch")
            case None =>
                if (text(plan, "version") == "process-channel-intent-v2") {
                    require(output.limits.payload.isSome(), "mcp_plugin.payload_unsupported")
                    let intents = field(plan, "intents")
                    require(intents.unifiedKind == UnifiedJsonKind.List && intents.items.size == 1, "mcp_plugin.intent_mismatch")
                    let intent = intents.items[0]; exact(intent, ["id", "payload"])
                    let payload = field(intent, "payload")
                    exact(payload, ["schema", "artifact_ref", "encoding", "bytes", "sha256", "encoded_sha256"])
                    let raw = cached.prepared.stdioFrame()
                    require(text(intent, "id") == "mcp-call" && text(payload, "schema") == "axyndra.service-payload/v1" &&
                        text(payload, "encoding") == "hex" && number(payload, "bytes") == raw.size &&
                        field(payload, "bytes").asNumberText() == raw.size.toString() &&
                        text(payload, "sha256") == sha(String.fromUtf8(raw)) && text(payload, "encoded_sha256") == sha(cached.bytesHex) &&
                        text(payload, "artifact_ref") == "blob:sha256:" + sha(cached.bytesHex), "mcp_plugin.intent_mismatch")
                } else {
                    require(text(plan, "version") == "process-channel-intent-v1", "mcp_plugin.host_plan_invalid")
                    require(sameJson(field(plan, "intents"), cached.intents()), "mcp_plugin.intent_mismatch")
                }
        }
        cached.dispatched = true
        consumed.add(id); prepared.remove(id); retainedPreparedBytes -= cached.retainedBytes
        try {
            match (http) {
                case Some(value) => value.openWindow(invocation, false, cached.httpRequest.getOrThrow())
                case None => channel.openWindow(invocation, false, cached.bytesHex)
            }
            let result = client.getOrThrow().dispatchPreparedToolCall(cached.prepared)
            closeWindow()
            match (result) {
                case McpResult.Err(_) =>
                    close()
                    return SessionReply(serviceOutcome("unknown", jsonNull(), "mcp_plugin.call_outcome_unknown"), false)
                case McpResult.Ok(McpCallToolOutcome.Complete(value)) =>
                    return SessionReply(serviceOutcome("complete", value.toValue(),
                        if (value.isError) { "mcp_plugin.tool_error" } else { "" }), !value.isError)
                case McpResult.Ok(McpCallToolOutcome.InputRequired(value)) =>
                    return SessionReply(serviceOutcome("input_required", value.toValue(), "mcp_plugin.input_required_unsupported"), false)
                case McpResult.Ok(_) =>
                    close()
                    return SessionReply(serviceOutcome("unknown", jsonNull(), "mcp_plugin.outcome_unsupported"), false)
            }
        } catch (_: Exception) {
            close()
            SessionReply(serviceOutcome("unknown", jsonNull(), "mcp_plugin.call_outcome_unknown"), false)
        } finally { cached.close() }
    }
}
