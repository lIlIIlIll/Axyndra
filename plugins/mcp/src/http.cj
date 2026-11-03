package mcp_client_plugin

import mcp4cj.*
import std.collection.*
import std.io.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// This adapter has no socket, credential resolver, proxy or direct fallback.
// All identities below correlate one host-owned invocation; none grant IO.
class BrokerHttpWindow {
    let invocation: JsonNode
    let maintenance: Bool
    let expected: JsonNode
    let deadline: MonoTime
    let exchanges = ArrayList<BrokerHttpExchange>()
    var closing = false
    var opened = false
    var inFlight: Int64 = 0
    var requests: Int64 = 0
    var responseBytes: Int64 = 0
    var requestBytes: Int64 = 0
    var decodedNodes: Int64 = 0
    let responseReservation: ?PayloadCharge
    init(invocation: JsonNode, maintenance: Bool, expected: JsonNode, timeoutMillis: Int64, reservation: ?PayloadCharge) {
        this.responseReservation = reservation
        this.invocation = invocation; this.maintenance = maintenance; this.expected = expected
        deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
    }
}
class BrokerHttpPending {
    let window: BrokerHttpWindow
    let waitForHeaders: Bool
    let accept: (JsonNode) -> Unit
    let done = AtomicBool(false)
    let failed = AtomicBool(false)
    init(window: BrokerHttpWindow, waitForHeaders: Bool, accept: (JsonNode) -> Unit) {
        this.window = window; this.waitForHeaders = waitForHeaders; this.accept = accept
    }
}

class BrokerHttpExchangePort <: McpHttpExchangePort {
    private let output: WireOutput
    private let config: McpPluginConfiguration
    private let lock = Mutex()
    private let closed = AtomicBool(false)
    private let failed = AtomicBool(false)
    private var window: ?BrokerHttpWindow = None
    private let pending = HashMap<String, BrokerHttpPending>()
    private let exchangeIds = HashSet<String>()
    private var serial: Int64 = 0
    private var responseReservation: ?PayloadCharge = None
    func setResponseReservation(value: ?PayloadCharge): Unit { lock.lock(); try { require(window.isNone()); responseReservation = value } finally { lock.unlock() } }
    init(output: WireOutput, config: McpPluginConfiguration) { this.output = output; this.config = config }
    func isClosed(): Bool { closed.load() }
    func failedBoundary(): Bool { failed.load() }
    func poison(): Unit { failed.store(true) }
    func abort(): Unit { closed.store(true) }
    func openWindow(invocation: JsonNode, maintenance: Bool, expected: JsonNode): Unit {
        lock.lock(); try {
            require(!closed.load() && !failed.load() && window.isNone() && pending.isEmpty(), "mcp_plugin.http_unavailable")
            require(config.limits.payload.isNone() || responseReservation.isSome(), "mcp_plugin.http_decode_owner_missing")
            window = Some(BrokerHttpWindow(invocation, maintenance, expected,
                if (maintenance) { 60000 } else { config.requestTimeoutMillis }, responseReservation))
        } finally { lock.unlock() }
    }
    // Pure local copy/validation. A native service_prepare never calls this
    // method; McpClient freezes HTTP in its own immutable prepared value.
    public func prepare(request: McpHttpExchangeRequest): McpHttpExchange {
        let exactRequest = frozenHttpRequest(request, config)
        lock.lock(); try {
            require(!closed.load() && !failed.load() && window.isSome(), "mcp_plugin.http_outside_invocation")
            let current = window.getOrThrow()
            require(!current.closing && current.exchanges.size < 32, "mcp_plugin.http_exchange_limit")
            let inputCeiling = match (config.limits.payload) { case Some(value) => value.prepared; case None => 262144 }
            require(request.body.size <= inputCeiling - current.requestBytes, "mcp_plugin.http_input_limit")
            current.requestBytes += request.body.size
            if (!current.maintenance) {
                require(!current.opened && sameJson(exactRequest, current.expected), "mcp_plugin.http_request_not_prepared")
                current.opened = true
            }
            let exchange = BrokerHttpExchange(this, current, exactRequest, config.maxResponseBytes)
            current.exchanges.add(exchange)
            exchange
        } finally { lock.unlock() }
    }
    func claimExchange(id: String): Unit {
        require(httpHandle(id), "mcp_plugin.http_exchange_invalid")
        lock.lock(); try {
            require(exchangeIds.size < 4096 && !exchangeIds.contains(id), "mcp_plugin.http_exchange_reused")
            exchangeIds.add(id)
        } finally { lock.unlock() }
    }
    func chargeResponse(owner: BrokerHttpWindow, count: Int64, nodes: Int64): Unit {
        lock.lock(); try {
            let outputCeiling = match (config.limits.payload) { case Some(value) => value.result; case None => 1048576 }
            require(count >= 0 && count <= outputCeiling - owner.responseBytes, "mcp_plugin.http_output_limit")
            owner.responseBytes += count; owner.decodedNodes += nodes
            require(nodes >= 0 && owner.decodedNodes <= 65536, "mcp_plugin.payload_nodes")
            match (owner.responseReservation) { case Some(value) => value.ensureDecoded(owner.responseBytes, owner.decodedNodes); case None => () }
        } finally { lock.unlock() }
    }
    // Register before emission. receive consumes exactly one matching response
    // even if its caller has already been interrupted by exchange.close().
    func request(owner: BrokerHttpWindow, service: String, args: JsonNode,
        accept: (JsonNode) -> Unit): BrokerHttpPending {
        let item = BrokerHttpPending(owner, service == "network.http.stream.open", accept)
        lock.lock()
        let id = try {
            require(!closed.load() && !failed.load() && window.isSome() && refEq(window.getOrThrow(), owner),
                "mcp_plugin.http_window_stale")
            require(service == "network.http.stream.close" || MonoTime.now() < owner.deadline,
                "mcp_plugin.http_window_expired")
            require(owner.requests < 4096, "mcp_plugin.service_request_limit")
            owner.requests += 1; owner.inFlight += 1; serial += 1
            let key = "mcp-http-" + serial.toString(); pending.add(key, item); key
        } finally { lock.unlock() }
        try {
            let entries = envelope(owner.invocation, "service_request")
            entries.add(JsonObjectEntry("request_id", jsonString(id)))
            entries.add(JsonObjectEntry("service", jsonString(service)))
            entries.add(JsonObjectEntry("arguments", args))
            output.writeGuarded(jsonObject(entries.toArray()), { => !closed.load() })
        } catch (error: Exception) { failed.store(true); throw error }
        item
    }
    func receive(frame: JsonNode): Unit {
        if (closed.load()) { return }
        lock.lock()
        let item = try {
            let value = pending.get(text(frame, "request_id"))
            require(value.isSome() && sameIdentity(frame, value.getOrThrow().window.invocation),
                "mcp_plugin.response_identity_invalid")
            pending.remove(text(frame, "request_id")); value.getOrThrow()
        } finally { lock.unlock() }
        try {
            require(field(frame, "ok").unifiedKind == UnifiedJsonKind.Boolean && boolean(frame, "ok"),
                "mcp_plugin.http_service_failed")
            item.accept(field(frame, "result"))
        } catch (_: Exception) { item.failed.store(true); failed.store(true) }
        finally {
            lock.lock(); try { item.window.inFlight -= 1 } finally { lock.unlock() }
            item.done.store(true)
        }
    }
    func wait(item: BrokerHttpPending, interrupted: AtomicBool): Unit {
        // Opening waits for actual response headers, so its bound is the
        // frozen request timeout. Short read polls/close ACKs retain the
        // separate protocol watchdog; cancellation interrupts both at once.
        let deadline = MonoTime.now() + Duration.millisecond *
            (if (item.waitForHeaders) { config.requestTimeoutMillis } else { 5000 })
        while (!item.done.load()) {
            require(!closed.load() && !interrupted.load(), "mcp_plugin.http_exchange_closed")
            if (failed.load() || MonoTime.now() >= deadline || MonoTime.now() >= item.window.deadline) {
                failed.store(true); throw PluginFailure("mcp_plugin.http_response_timeout")
            }
            sleep(Duration.millisecond)
        }
        require(!closed.load() && !interrupted.load() && !item.failed.load() && !failed.load(),
            "mcp_plugin.http_exchange_failed")
    }
    func closeWindow(): Unit {
        lock.lock()
        let owner = try {
            require(window.isSome(), "mcp_plugin.http_window_missing")
            let current = window.getOrThrow(); current.closing = true; current
        } finally { lock.unlock() }
        // close never takes the stream read lock, and pending open responses
        // retain callbacks which will close the late handle before this drains.
        for (exchange in owner.exchanges) { exchange.close() }
        let deadline = MonoTime.now() + Duration.second * 5
        while (true) {
            require(!closed.load() && !failed.load(), "mcp_plugin.http_cleanup_unverified")
            lock.lock(); let drained = try { owner.inFlight == 0 } finally { lock.unlock() }
            var complete = drained
            for (exchange in owner.exchanges where !exchange.finished()) { complete = false }
            if (complete) {
                for (exchange in owner.exchanges) { exchange.verifyClose() }
                lock.lock(); try {
                    require(window.isSome() && refEq(window.getOrThrow(), owner) && pending.isEmpty())
                    window = None
                } finally { lock.unlock() }
                return
            }
            if (MonoTime.now() >= deadline) { failed.store(true); throw PluginFailure("mcp_plugin.http_cleanup_unverified") }
            sleep(Duration.millisecond)
        }
    }
}

class BrokerHttpExchange <: McpHttpExchange {
    private let port: BrokerHttpExchangePort
    private let owner: BrokerHttpWindow
    private let requestValue: JsonNode
    private let maximum: Int64
    private let lock = Mutex()
    private let closed = AtomicBool(false)
    private var started = false
    private var closeSent = false
    private var id = ""
    private var responseValue: ?BrokerHttpResponse = None
    private var closeValue: ?JsonNode = None
    private var delivered: Int64 = 0
    private var sawEof = false
    private var expectedLength: ?Int64 = None
    private var decoder: ?HttpPayloadTokenCounter = None
    init(port: BrokerHttpExchangePort, owner: BrokerHttpWindow, request: JsonNode, maximum: Int64) {
        this.port = port; this.owner = owner; requestValue = request; this.maximum = maximum
    }
    public func send(): McpHttpExchangeResponse {
        lock.lock(); try {
            require(!closed.load() && !started, "mcp_plugin.http_send_repeated"); started = true
        } finally { lock.unlock() }
        let args = if (owner.maintenance) { jsonObject([JsonObjectEntry("request", requestValue)]) }
            else { jsonObject([JsonObjectEntry("intent_id", jsonString("mcp-call"))]) }
        let pending = port.request(owner, "network.http.stream.open", args, { value => opened(value) })
        port.wait(pending, closed)
        lock.lock(); try { responseValue.getOrThrow() } finally { lock.unlock() }
    }
    private func opened(value: JsonNode): Unit {
        exact(value, ["exchange_id", "status", "content_type", "body_size"])
        let handle = text(value, "exchange_id"); port.claimExchange(handle)
        let status = canonicalNumber(value, "status", 200, 599)
        require(field(value, "content_type").unifiedKind == UnifiedJsonKind.Text && text(value, "content_type").size <= 1024,
            "mcp_plugin.http_metadata_invalid")
        let length = field(value, "body_size")
        let bodySize: ?Int64 = if (length.unifiedKind == UnifiedJsonKind.Null) { None }
            else { Some(canonicalNumber(value, "body_size", 0, maximum)) }
        lock.lock(); try {
            require(id == "", "mcp_plugin.http_exchange_repeated")
            id = handle
            expectedLength = bodySize
            decoder = Some(HttpPayloadTokenCounter(text(value, "content_type").toAsciiLower().startsWith("text/event-stream")))
            responseValue = Some(BrokerHttpResponse(this, status, text(value, "content_type"), bodySize))
        } finally { lock.unlock() }
        if (closed.load()) { sendClose() }
    }
    func read(): Array<Byte> {
        require(!closed.load(), "mcp_plugin.http_exchange_closed")
        lock.lock(); let handle = try { require(id != ""); id } finally { lock.unlock() }
        let result = BrokerHttpReadValue()
        let pending = port.request(owner, "network.http.stream.read", jsonObject([
            JsonObjectEntry("exchange_id", jsonString(handle)), JsonObjectEntry("max_bytes", jsonNumber("16384")),
            JsonObjectEntry("wait_ms", jsonNumber("25"))]), { value =>
                exact(value, ["bytes_hex", "eof"])
                require(field(value, "bytes_hex").unifiedKind == UnifiedJsonKind.Text &&
                    field(value, "eof").unifiedKind == UnifiedJsonKind.Boolean, "mcp_plugin.http_body_invalid")
                let bytes = unhex(text(value, "bytes_hex"), 16384)
                let nodes = decoder.getOrThrow().accept(bytes)
                // Before these bytes reach the JSON/SSE library decoder, charge
                // their cumulative node/byte bound to the real worker owner.
                port.chargeResponse(owner, bytes.size, nodes)
                lock.lock(); try {
                    require(!sawEof && bytes.size <= maximum - delivered, "mcp_plugin.http_body_invalid")
                    delivered += bytes.size; sawEof = boolean(value, "eof")
                    match (expectedLength) {
                        case Some(length) => require(delivered <= length && (!sawEof || delivered == length),
                            "mcp_plugin.http_body_length_mismatch")
                        case None => ()
                    }
                } finally { lock.unlock() }
                result.bytes = bytes; result.eof = boolean(value, "eof")
            })
        port.wait(pending, closed)
        result.bytes
    }
    func eof(): Bool { lock.lock(); try { sawEof } finally { lock.unlock() } }
    func isClosed(): Bool { closed.load() || port.isClosed() || port.failedBoundary() }
    public func close(): Unit {
        closed.store(true)
        // A pending open has no handle yet. Its response callback owns later
        // close. This returns promptly, allowing library cancellation to unwind.
        sendClose()
    }
    private func sendClose(): Unit {
        lock.lock()
        let selected = try {
            if (id == "" || closeSent || port.isClosed()) { return }
            closeSent = true; id
        } finally { lock.unlock() }
        try {
            let _ = port.request(owner, "network.http.stream.close", jsonObject([
                JsonObjectEntry("exchange_id", jsonString(selected))]), { value =>
                    exact(value, ["closed", "receipt_id", "body_eof", "consumed_bytes"])
                    require(field(value, "closed").unifiedKind == UnifiedJsonKind.Boolean && boolean(value, "closed") &&
                        field(value, "body_eof").unifiedKind == UnifiedJsonKind.Boolean, "mcp_plugin.http_close_invalid")
                    let receipt = field(value, "receipt_id")
                    require(if (owner.maintenance) { receipt.unifiedKind == UnifiedJsonKind.Null }
                        else { receipt.unifiedKind == UnifiedJsonKind.Text && httpHandle(receipt.text) },
                        "mcp_plugin.http_receipt_missing")
                    let _ = canonicalNumber(value, "consumed_bytes", 0, maximum)
                    lock.lock(); try { require(closeValue.isNone()); closeValue = Some(value) } finally { lock.unlock() }
                })
        } catch (_: Exception) { port.poison() }
    }
    func finished(): Bool { lock.lock(); try { (!started && closed.load()) || closeValue.isSome() } finally { lock.unlock() } }
    func verifyClose(): Unit {
        lock.lock(); try {
            if (!started) { require(closed.load()); return }
            let value = closeValue.getOrThrow()
            require(number(value, "consumed_bytes") == delivered && (!sawEof || boolean(value, "body_eof")),
                "mcp_plugin.http_close_count_mismatch")
        } finally { lock.unlock() }
    }
}
class BrokerHttpReadValue { var bytes: Array<Byte> = []; var eof = false }
class BrokerHttpResponse <: McpHttpExchangeResponse {
    private let exchange: BrokerHttpExchange
    private let statusValue: Int64
    private let typeValue: String
    private let sizeValue: ?Int64
    private let stream: BrokerHttpInput
    init(exchange: BrokerHttpExchange, status: Int64, contentType: String, bodySize: ?Int64) {
        this.exchange = exchange; statusValue = status; typeValue = contentType; sizeValue = bodySize
        stream = BrokerHttpInput(exchange)
    }
    public prop status: Int64 { get() { statusValue } }
    public prop contentType: String { get() { typeValue } }
    public prop bodySize: ?Int64 { get() { sizeValue } }
    public prop body: InputStream { get() { stream } }
    public func close(): Unit { exchange.close() }
}
class BrokerHttpInput <: InputStream {
    private let exchange: BrokerHttpExchange
    private let lock = Mutex()
    private var buffered: Array<Byte> = []
    private var offset: Int64 = 0
    init(exchange: BrokerHttpExchange) { this.exchange = exchange }
    public func read(buffer: Array<Byte>): Int64 {
        if (buffer.isEmpty()) { return 0 }
        lock.lock(); try {
            while (true) {
                require(!exchange.isClosed(), "mcp_plugin.http_exchange_closed")
                if (offset < buffered.size) {
                    let count = min(buffer.size, buffered.size - offset)
                    for (index in 0..count) { buffer[index] = buffered[offset + index] }
                    offset += count; return count
                }
                if (exchange.eof()) { return 0 }
                buffered = exchange.read(); offset = 0
                if (buffered.isEmpty() && !exchange.eof()) { sleep(Duration.millisecond) }
            }
            0
        } finally { lock.unlock() }
    }
}

func httpHandle(value: String): Bool {
    if (value == "" || value.size > 256) { return false }
    for (byte in value.toArray() where byte < 33u8 || byte > 126u8) { return false }
    true
}
func canonicalNumber(value: JsonNode, name: String, minimum: Int64, maximum: Int64): Int64 {
    let result = number(value, name)
    require(result >= minimum && result <= maximum && field(value, name).asNumberText() == result.toString(),
        "mcp_plugin.http_number_invalid")
    result
}
func frozenHttpRequest(request: McpHttpExchangeRequest, config: McpPluginConfiguration): JsonNode {
    require(request.url == config.url && request.method == "POST" && request.body.size <= config.limits.request &&
        request.readTimeoutMillis.isSome() && request.readTimeoutMillis.getOrThrow() == config.requestTimeoutMillis &&
        request.writeTimeoutMillis == config.requestTimeoutMillis, "mcp_plugin.http_request_invalid")
    let headers = ArrayList<JsonObjectEntry>(); let seen = HashSet<String>()
    for (header in request.headers) {
        let name = header.name.toAsciiLower()
        require(!seen.contains(name) && name != "authorization" && name != "cookie" && name != "host" &&
            !name.startsWith("proxy-") && header.value.size <= 4096, "mcp_plugin.http_header_invalid")
        seen.add(name); headers.add(JsonObjectEntry(header.name, jsonString(header.value)))
    }
    require(headers.size <= 32, "mcp_plugin.http_header_invalid")
    let value = jsonObject([JsonObjectEntry("method", jsonString(request.method)), JsonObjectEntry("url", jsonString(request.url)),
        JsonObjectEntry("headers", jsonObject(headers.toArray())), JsonObjectEntry("body_hex", jsonString(hex(request.body.toArray()))),
        JsonObjectEntry("credential_refs", jsonArray(config.credentialRefs.map { ref => jsonString(ref) })),
        JsonObjectEntry("timeout_ms", jsonNumber(config.requestTimeoutMillis.toString())),
        JsonObjectEntry("max_response_bytes", jsonNumber(config.maxResponseBytes.toString()))])
    require(stringifyUnifiedJson(value).size <= config.limits.prepared - 1024, "mcp_plugin.prepare_output_limit")
    value
}
