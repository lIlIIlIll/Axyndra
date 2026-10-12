package mcp_server_plugin

import mcp4cj.*
import jsonrpc4cj.*
import std.collection.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

class DecoderReply {
    let value: JsonNode
    let ok: Bool
    init(value: JsonNode) { this.value = value; ok = true }
}
// The consumer retains this reservation through all JSON parsing, protocol
// conversion and response encoding. A stored blob charge covers bytes only.
class DecoderBlobRead {
    let text: String
    private let charge: ?PayloadCharge
    init(text: String, charge: ?PayloadCharge) { this.text = text; this.charge = charge }
    func close(): Unit { match (charge) { case Some(value) => value.close(); case None => () } }
}
class DecoderBlob {
    let size: Int64
    let digest: String
    private let chunkBytes: Int64
    private let deadline: MonoTime
    private let expanded: Bool
    private var charge: ?PayloadCharge = None
    private var bytes = ArrayList<Byte>()
    private var frozen = false
    init(size: Int64, digest: String, maximum: Int64, chunkBytes: Int64, expanded: Bool) {
        require(size >= 0 && size <= maximum && maximum <= 4194304 && chunkBytes > 0 && payloadDigest(digest))
        this.size = size; this.digest = digest; this.chunkBytes = chunkBytes; this.expanded = expanded
        deadline = MonoTime.now() + Duration.second * (if (expanded) { 30 } else { 10 })
        // Blob storage persists across distinct powerless parser invocations.
        // Reserve declared bytes before allocating or accepting any chunk.
        if (expanded) { charge = Some(payloadPool.acquire(max(1, size), transfer: false)) }
        if (size == 0) {
            if (sha("") != digest) { close(); throw PluginFailure("mcp_server.blob_digest") }
            frozen = true
        }
    }
    private func reserveConsumer(): ?PayloadCharge {
        if (!expanded) { return None }
        // Scan the original bounded buffer before any String, copy or JSON DOM.
        // Counts and bytes have hard bounds, so the arithmetic cannot overflow.
        let nodes = payloadFrameNodeCount(bytes)
        let wire = max(1, bytes.size)
        require(wire <= 4194304 && nodes <= 65536, "mcp_server.payload_capacity")
        let cost = max(wire * 8, wire * 4 + nodes * 512 + 1048576)
        // Non-transfer acquire multiplies by two and does not occupy a transfer
        // slot. 512/token is a conservative accounting coefficient, not RSS.
        Some(payloadPool.acquire((cost + 1) / 2, transfer: false))
    }
    func append(offset: Int64, incoming: Array<Byte>): Unit {
        require(!frozen && MonoTime.now() < deadline, "mcp_server.blob_expired")
        require(offset == bytes.size && incoming.size > 0 && incoming.size <= chunkBytes && incoming.size <= size - bytes.size)
        for (byte in incoming) { bytes.add(byte) }
        if (bytes.size == size) {
            let verification = reserveConsumer()
            try {
                let source = String.fromUtf8(bytes.toArray())
                require(sha(source) == digest, "mcp_server.blob_digest")
                // Only a complete, verified upload becomes immutable. Late
                // final chunks or an expensive late hash cannot reset the clock.
                require(MonoTime.now() < deadline, "mcp_server.blob_expired")
                frozen = true
            } finally { match (verification) { case Some(value) => value.close(); case None => () } }
        } else { require(MonoTime.now() < deadline, "mcp_server.blob_expired") }
    }
    func read(): DecoderBlobRead {
        require(frozen && bytes.size == size, "mcp_server.blob_incomplete")
        let consumer = reserveConsumer()
        try { DecoderBlobRead(String.fromUtf8(bytes.toArray()), consumer) }
        catch (error: Exception) { match (consumer) { case Some(value) => value.close(); case None => () }; throw error }
    }
    func close(): Unit {
        frozen = false; bytes = ArrayList<Byte>()
        match (charge) { case Some(value) => value.close(); case None => () }; charge = None
    }
}
func decoderId(value: JsonRpcId): JsonNode {
    jsonObject([JsonObjectEntry("kind", jsonString(match (value.kind) {
        case JsonRpcIdKind.Text => "text"; case JsonRpcIdKind.Number => "number"; case JsonRpcIdKind.Null => "null" })),
        JsonObjectEntry("value", jsonString(value.value))])
}
func decoderNodeId(value: JsonNode): JsonRpcId {
    match (value.unifiedKind) {
        case UnifiedJsonKind.Text => JsonRpcId(JsonRpcIdKind.Text, value: value.text)
        case UnifiedJsonKind.Number => JsonRpcId(JsonRpcIdKind.Number, value: value.asNumberText())
        case UnifiedJsonKind.Null => JsonRpcId(JsonRpcIdKind.Null)
        case _ => throw PluginFailure("mcp_server.cancel_id_invalid")
    }
}
func decoderDirective(frame: String, action: String, extra: Array<JsonObjectEntry>): JsonNode {
    let values = ArrayList<JsonObjectEntry>([JsonObjectEntry("schema", jsonString("axyndra.ingress-directive/v1")),
        JsonObjectEntry("frame_id", jsonString(frame)), JsonObjectEntry("action", jsonString(action))])
    for (item in extra) { values.add(item) }
    jsonObject(values.toArray())
}
func decoderResponse(frame: String, response: JsonRpcResponse, maximum: Int64): JsonNode {
    let encoded = encodeJsonRpc(JsonRpcEnvelope.Response(response))
    if (encoded.size > maximum) {
        let bounded = JsonRpcResponse(response.id, JsonRpcResponsePayload.Failure(JsonRpcError(JSON_RPC_INTERNAL_ERROR,
            "MCP response exceeds the configured ingress bound")))
        return decoderDirective(frame, "respond", [JsonObjectEntry("response_hex", jsonString(hex(encodeJsonRpc(JsonRpcEnvelope.Response(bounded)).toArray())))])
    }
    decoderDirective(frame, "respond", [JsonObjectEntry("response_hex", jsonString(hex(encoded.toArray())))])
}

// The actual mcp4cj server performs protocol/meta/schema validation. Its only
// execution callback is a pure capture or a host-supplied result conversion;
// it never has an I/O callback or access to a Tool executor.
class DecoderToolHost <: McpToolHost {
    private let tools: Array<McpTool>
    private let response: ?JsonNode
    var captured: ?JsonNode = None
    init(catalogue: JsonNode, response: ?JsonNode) {
        require(catalogue.unifiedKind == UnifiedJsonKind.List && catalogue.items.size <= 256)
        let values = ArrayList<McpTool>(); let names = HashSet<String>()
        for (entry in catalogue.items) {
            exact(entry, ["name", "description", "input_schema"])
            let name = text(entry, "name"); require(name != "" && !names.contains(name)); names.add(name)
            values.add(McpTool(name, text(entry, "description"), field(entry, "input_schema")))
        }
        tools = values.toArray(); this.response = response
    }
    public func listTools(cursor: String): McpResult<McpToolListPage> {
        if (cursor != "") { return McpResult.Err(McpError(McpErrorKind.Protocol, "mcp.product_cursor_invalid", "the fixed export directory has one bounded page")) }
        McpResult.Ok(McpToolListPage(tools, ttlMillis: 0, cacheScope: "private"))
    }
    public func callTool(id: JsonRpcId, name: String, arguments: JsonNode, continuation: McpToolCallContinuation): McpResult<McpCallToolOutcome> {
        if (continuation.isRetry()) { return McpResult.Err(McpError(McpErrorKind.Protocol,
            "mcp.product_continuation_unsupported", "exported tools do not advertise input_required continuations")) }
        captured = Some(jsonObject([JsonObjectEntry("request_id", decoderId(id)), JsonObjectEntry("name", jsonString(name)),
            JsonObjectEntry("arguments", arguments)]))
        match (response) {
            case None => McpResult.Err(McpError(McpErrorKind.Lifecycle, "mcp_server.capture_only", "host execution has not occurred"))
            case Some(value) =>
                if (text(value, "status") == "complete") {
                    exact(value, ["status", "output", "is_error"])
                    require(field(value, "is_error").unifiedKind == UnifiedJsonKind.Boolean)
                    McpResult.Ok(McpCallToolOutcome.Complete(McpCallToolResult(
                        [jsonObject([JsonObjectEntry("type", jsonString("text")),
                            JsonObjectEntry("text", jsonString(stringifyUnifiedJson(field(value, "output"))))])],
                        structuredContent: field(value, "output"), isError: boolean(value, "is_error"))))
                } else {
                    exact(value, ["status", "code"]); require(text(value, "status") == "error" && text(value, "code").size <= 256)
                    McpResult.Err(McpError(McpErrorKind.Authorization, text(value, "code"), "host invocation did not complete; approval and capability policy remain authoritative"))
                }
        }
    }
    public func cancel(id: JsonRpcId, reason: String): McpResult<Unit> { let _ = id; let _ = reason; McpResult.Ok(()) }
}
class McpServerDecoderSession {
    private let blobs = HashMap<String, DecoderBlob>()
    private let closed = AtomicBool(false)
    private var catalogueFrozen = false
    private let output: WireOutput
    init(output: WireOutput) { this.output = output }
    private func blobMaximum(slot: String): Int64 {
        if (slot == "result" && output.limits.payload.isSome()) { output.limits.payload.getOrThrow().input } else { 65536 }
    }
    private func chunkMaximum(): Int64 {
        match (output.limits.payload) { case Some(value) => min(131072, (value.input - 1024) / 2); case None => 4096 }
    }
    private func responseMaximum(): Int64 {
        match (output.limits.payload) { case Some(value) => (value.prepared - 4096) / 2; case None => 24576 }
    }
    func abort(): Unit { closed.store(true) }
    func close(): Unit { abort(); for ((_, blob) in blobs) { blob.close() }; blobs.clear() }
    func handle(invocation: JsonNode): DecoderReply {
        require(!closed.load(), "mcp_server.closed")
        let arguments = field(invocation, "arguments")
        let action = text(arguments, "action")
        if (action == "blob_begin") {
            exact(arguments, ["action", "slot", "size", "digest"])
            let slot = text(arguments, "slot")
            require(["catalogue", "frame", "result"].contains(slot) && !(slot == "catalogue" && catalogueFrozen))
            let replacement = DecoderBlob(number(arguments, "size"), text(arguments, "digest"), blobMaximum(slot),
                chunkMaximum(), output.limits.payload.isSome())
            match (blobs.get(slot)) { case Some(value) => value.close(); case None => () }
            blobs.add(slot, replacement)
            return DecoderReply(jsonObject([JsonObjectEntry("accepted", jsonBool(true))]))
        }
        if (action == "blob_append") {
            exact(arguments, ["action", "slot", "offset", "bytes_hex"])
            let slot = text(arguments, "slot")
            require(!(slot == "catalogue" && catalogueFrozen))
            blobs.get(slot).getOrThrow().append(number(arguments, "offset"), unhex(text(arguments, "bytes_hex"), chunkMaximum()))
            return DecoderReply(jsonObject([JsonObjectEntry("accepted", jsonBool(true))]))
        }
        exact(arguments, ["action", "frame_id"])
        require(action == "decode" || action == "encode")
        let frame = text(arguments, "frame_id"); require(frame != "" && frame.size <= 128)
        let reads = ArrayList<DecoderBlobRead>()
        try {
        let catalogue = parseUnifiedJson(readBlob("catalogue", reads), maxBytes: 65536)
        catalogueFrozen = true
        let raw = readBlob("frame", reads)
        let envelope = match (decodeJsonRpc(raw, maxBytes: 65536)) {
            case JsonRpcResult.Ok(value) => value
            case JsonRpcResult.Err(error) => return DecoderReply(decoderResponse(frame, JsonRpcResponse(JsonRpcId(JsonRpcIdKind.Null),
                JsonRpcResponsePayload.Failure(JsonRpcError(error.rpcCode, "Invalid bounded JSON-RPC request"))), responseMaximum()))
        }
        match (envelope) {
            case JsonRpcEnvelope.Notification(notification) =>
                require(action == "decode")
                if (notification.method == MCP_METHOD_CANCELLED) {
                    // This is MCP protocol interpretation inside the independent
                    // component. The host sees only the typed generic directive.
                    let id = notification.params.field("requestId")
                    if (id.isSome()) { return DecoderReply(decoderDirective(frame, "cancel", [JsonObjectEntry("request_id", decoderId(decoderNodeId(id.getOrThrow())))])) }
                }
                DecoderReply(decoderDirective(frame, "ignore", []))
            case JsonRpcEnvelope.Response(_) => DecoderReply(decoderResponse(frame, JsonRpcResponse(JsonRpcId(JsonRpcIdKind.Null),
                JsonRpcResponsePayload.Failure(JsonRpcError(JSON_RPC_INVALID_REQUEST, "Client responses are not accepted by this server"))), responseMaximum()))
            case JsonRpcEnvelope.Request(request) =>
                let hostResult: ?JsonNode = if (action == "encode") {
                    Some(parseUnifiedJson(readBlob("result", reads), maxBytes: blobMaximum("result"), maxDepth: 32))
                } else { None }
                let host = DecoderToolHost(catalogue, hostResult)
                let server = McpServer(McpDiscoverResult(serverInfo: Some(McpImplementationInfo("axyndra-mcp-server", "1.0.0")),
                    instructions: "Fixed host exports; host approval and capability policy remain authoritative"), host: Some(host))
                let response = try { server.handleRequest(request) } finally { let _ = server.close() }
                if (action == "decode" && host.captured.isSome()) {
                    let call = host.captured.getOrThrow()
                    DecoderReply(decoderDirective(frame, "invoke", [JsonObjectEntry("request_id", field(call, "request_id")),
                        JsonObjectEntry("name", field(call, "name")), JsonObjectEntry("arguments", field(call, "arguments"))]))
                } else { DecoderReply(decoderResponse(frame, response, responseMaximum())) }
        }
        } finally { for (read in reads) { read.close() } }
    }
    private func readBlob(slot: String, reads: ArrayList<DecoderBlobRead>): String {
        let read = blobs.get(slot).getOrThrow().read()
        try { reads.add(read); read.text }
        catch (error: Exception) { read.close(); throw error }
    }
}
