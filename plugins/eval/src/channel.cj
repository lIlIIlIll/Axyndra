package eval_plugin

import std.collection.*
import std.io.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

class BrokerPending {
    let invocation: JsonNode
    private let lock = Mutex()
    private var response: ?JsonNode = None
    init(invocation: JsonNode) { this.invocation = invocation }
    func complete(value: JsonNode): Unit { lock.lock(); try { require(response.isNone(), "eval_plugin.duplicate_response"); response = Some(value) } finally { lock.unlock() } }
    func poll(): ?JsonNode { lock.lock(); try { response } finally { lock.unlock() } }
}
class BrokerWindow {
    let invocation: JsonNode
    let startup: Bool
    let refresh: Bool
    let expectedHex: String
    var usedWrite = false
    var inFlight: Int64 = 0
    var requestCount: Int64 = 0
    init(invocation: JsonNode, startup: Bool, expectedHex: String, refresh: Bool) {
        this.invocation = invocation; this.startup = startup; this.expectedHex = expectedHex; this.refresh = refresh
    }
}

// One session, one actual invocation window, bounded stdout/stderr readers. Empty reads are
// local waits, not EOF. No host service request can be emitted while idle.
class BrokerChannel {
    private let output: WireOutput
    private let lock = Mutex()
    private let closed = AtomicBool(false)
    private var window: ?BrokerWindow = None
    private var serial: Int64 = 0
    private let pending = HashMap<String, BrokerPending>()
    private var outStream: ?BrokerInput = None
    private var errStream: ?BrokerInput = None
    init(output: WireOutput) {
        this.output = output; outStream = Some(BrokerInput(this, "stdout")); errStream = Some(BrokerInput(this, "stderr"))
    }
    public prop stdout: InputStream { get() { outStream.getOrThrow() } }
    public prop stderr: InputStream { get() { errStream.getOrThrow() } }
    func isClosed(): Bool { closed.load() }
    func openWindow(invocation: JsonNode, startup: Bool): Unit { openWindow(invocation, startup, "") }
    func openWindow(invocation: JsonNode, startup: Bool, expectedHex: String): Unit {
        lock.lock(); try {
            require(!closed.load() && window.isNone() && pending.isEmpty(), "eval_plugin.session_unavailable")
            window = Some(BrokerWindow(invocation, startup, expectedHex, false))
        } finally { lock.unlock() }
    }
    func openRefreshWindow(invocation: JsonNode): Unit {
        lock.lock(); try {
            require(!closed.load() && window.isNone() && pending.isEmpty(), "eval_plugin.session_unavailable")
            window = Some(BrokerWindow(invocation, true, "", true))
        } finally { lock.unlock() }
    }
    func closeWindow(): Unit {
        lock.lock(); let captured = try { let old = window; window = None; old } finally { lock.unlock() }
        let deadline = MonoTime.now() + Duration.second * 2
        while (true) {
            lock.lock(); let drained = try { captured.isNone() || captured.getOrThrow().inFlight == 0 } finally { lock.unlock() }
            if (drained) { return }
            if (closed.load() || MonoTime.now() >= deadline) { abort(); throw PluginFailure("eval_plugin.poll_drain_failed") }
            sleep(Duration.millisecond * 1)
        }
    }
    func receive(frame: JsonNode): Unit {
        if (closed.load()) { return }
        lock.lock()
        let request = try { pending.get(text(frame, "request_id")) } finally { lock.unlock() }
        require(request.isSome() && sameIdentity(frame, request.getOrThrow().invocation), "eval_plugin.response_identity_invalid")
        request.getOrThrow().complete(frame)
    }
    // None means the read gate is idle; it must never become InputStream EOF.
    func request(service: String, arguments: JsonNode, writing!: Bool = false, bytesHex!: String = ""): ?JsonNode {
        lock.lock()
        let admitted = try {
            if (closed.load()) { throw PluginFailure("eval_plugin.session_closed") }
            if (window.isNone()) {
                if (writing) { throw PluginFailure("eval_plugin.write_outside_invocation") }
                return None
            }
            let active = window.getOrThrow()
            var selectedService = service
            var selectedArguments = arguments
            if (writing) {
                if (active.startup) {
                    selectedService = if (active.refresh) { "process.channel.refresh.write" } else { "process.channel.startup.write" }
                    selectedArguments = jsonObject([JsonObjectEntry("bytes_hex", jsonString(bytesHex))])
                } else {
                    require(!active.usedWrite && bytesHex == active.expectedHex, "eval_plugin.write_not_prepared")
                    active.usedWrite = true
                    selectedService = "process.channel.write"
                    selectedArguments = jsonObject([JsonObjectEntry("intent_id", jsonString("eval-call"))])
                }
            }
            require(active.requestCount < 4096, "eval_plugin.service_request_limit")
            active.requestCount += 1; active.inFlight += 1; serial += 1
            let id = "eval-channel-" + serial.toString()
            let entry = BrokerPending(active.invocation); pending.add(id, entry)
            (active, id, entry, selectedService, selectedArguments)
        } finally { lock.unlock() }
        let (active, id, entry, selectedService, selectedArguments) = admitted
        try {
            let entries = envelope(active.invocation, "service_request")
            entries.add(JsonObjectEntry("request_id", jsonString(id)))
            entries.add(JsonObjectEntry("service", jsonString(selectedService)))
            entries.add(JsonObjectEntry("arguments", selectedArguments))
            output.writeGuarded(jsonObject(entries.toArray()), { => !closed.load() })
            let deadline = MonoTime.now() + Duration.second * 5
            while (!closed.load() && MonoTime.now() < deadline) {
                match (entry.poll()) {
                    case Some(frame) =>
                        require(boolean(frame, "ok"), "eval_plugin.channel_service_failed")
                        return Some(field(frame, "result"))
                    case None => sleep(Duration.millisecond * 1)
                }
            }
            abort(); throw PluginFailure("eval_plugin.channel_response_timeout")
        } finally {
            lock.lock(); try { pending.remove(id); active.inFlight -= 1 } finally { lock.unlock() }
        }
    }
    public func write(bytes: Array<Byte>): Unit {
        require(!bytes.isEmpty() && bytes.size <= 30720, "eval_plugin.rpc_frame_limit")
        let result = request("", jsonObject([]), writing: true, bytesHex: hex(bytes)).getOrThrow()
        require(number(result, "written_bytes") == bytes.size, "eval_plugin.write_ack_invalid")
        // Receipt identity is required for every approved active write. Startup
        // writes settle within the actual canonical lifecycle root instead.
        lock.lock(); let activeWrite = try { window.isSome() && !window.getOrThrow().startup } finally { lock.unlock() }
        if (activeWrite) { require(text(result, "receipt_id") != "", "eval_plugin.write_receipt_missing") }
    }
    public func flush(): Unit { require(!closed.load(), "eval_plugin.session_closed") }
    public func abort(): Unit { closed.store(true) }
    public func stop(_: Int64): Unit { abort() }
    public func close(): Unit { abort() }
}

class BrokerInput <: InputStream {
    private let channel: BrokerChannel
    private let stream: String
    private var buffered: Array<Byte> = []
    private var offset: Int64 = 0
    private var eof = false
    init(channel: BrokerChannel, stream: String) { this.channel = channel; this.stream = stream }
    public func read(buffer: Array<Byte>): Int64 {
        if (buffer.isEmpty()) { return 0 }
        while (true) {
            if (channel.isClosed()) { return 0 }
            if (offset < buffered.size) {
                let count = if (buffer.size < buffered.size - offset) { buffer.size } else { buffered.size - offset }
                for (index in 0..count) { buffer[index] = buffered[offset + index] }
                offset += count; return count
            }
            if (eof) { return 0 }
            let response = channel.request("process.channel.read", jsonObject([
                JsonObjectEntry("stream", jsonString(stream)), JsonObjectEntry("max_bytes", jsonNumber("16384")),
                JsonObjectEntry("wait_ms", jsonNumber("25"))]))
            match (response) {
                case None => sleep(Duration.millisecond * 5)
                case Some(value) =>
                    exact(value, ["bytes_hex", "eof"])
                    require(field(value, "bytes_hex").unifiedKind == UnifiedJsonKind.Text &&
                        field(value, "eof").unifiedKind == UnifiedJsonKind.Boolean, "eval_plugin.channel_response_invalid")
                    buffered = unhex(text(value, "bytes_hex"), 16384); offset = 0; eof = boolean(value, "eof")
                    if (buffered.isEmpty() && !eof) { sleep(Duration.millisecond * 2) }
            }
        }
        0
    }
}
