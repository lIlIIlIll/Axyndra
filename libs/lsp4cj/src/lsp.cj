package lsp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.io.*
import std.sync.*
import std.time.*

public enum LspErrorKind { Frame | Json | Protocol | Correlation | Transport | Cancelled | Deadline }

public class LspError <: Exception {
    public let kind: LspErrorKind
    public let code: String
    public init(kind: LspErrorKind, code: String, message: String) {
        super(message); this.kind = kind; this.code = code
    }
}

public enum LspResult<T> {
    Ok(T) | Err(LspError)
    public func isOk(): Bool { match (this) { case Ok(_) => true; case Err(_) => false } }
}

public func encodeLspMessage(value: JsonNode): Array<Byte> {
    encodeContentLengthFrame(stringifyUnifiedJson(value))
}

public func readLspMessage(
    stream: InputStream,
    maxBodyBytes!: Int64 = 33554432,
    maxDepth!: Int64 = 128
): LspResult<JsonNode> {
    let body = try { readContentLengthBody(stream, maxBodyBytes: maxBodyBytes) } catch (error: ProcessError) {
        return LspResult.Err(LspError(
            if (let ProcessErrorKind.Io <- error.kind) { LspErrorKind.Transport } else { LspErrorKind.Frame },
            if (let ProcessErrorKind.Io <- error.kind) { "lsp.transport_closed" } else { "lsp.frame_invalid" },
            error.message
        ))
    }
    try {
        LspResult.Ok(parseUnifiedJson(String.fromUtf8(body), maxBytes: maxBodyBytes, maxDepth: maxDepth))
    } catch (error: JsonException) {
        LspResult.Err(LspError(LspErrorKind.Json, "lsp.json_invalid", error.message))
    } catch (error: Exception) {
        LspResult.Err(LspError(LspErrorKind.Json, "lsp.utf8_invalid", error.message))
    }
}

public class LspCorrelation {
    private let primitive = JsonRpcCorrelation()
    public init() {}
    public func reserve(id: JsonRpcId): LspResult<Unit> { adapt(primitive.reserve(id)) }
    public func complete(id: JsonRpcId): LspResult<Unit> { adapt(primitive.complete(id)) }
    public func cancel(id: JsonRpcId): LspResult<Unit> { adapt(primitive.cancel(id)) }
    public func release(id: JsonRpcId): Bool { primitive.release(id) }
    private func adapt(value: JsonRpcResult<Unit>): LspResult<Unit> {
        match (value) {
            case JsonRpcResult.Ok(_) => LspResult.Ok(())
            case JsonRpcResult.Err(error) => LspResult.Err(LspError(LspErrorKind.Correlation, error.code, error.message))
        }
    }
}

public type LspNotificationHandler = (String, JsonNode) -> Unit
public type LspRequestHandler = (String, JsonNode) -> LspResult<JsonNode>

class LspPendingRequest {
    let id: String
    var response: ?JsonNode = None
    var error: ?LspError = None
    var cancelled: Bool = false
    var frame: ?OwnedProtocolFrame = None
    init(id: String) { this.id = id }
}

// Process-backed protocol client. Product-specific notification/request
// semantics are supplied by callbacks and never enter this package.
public class LspClient {
    private let channel: ProcessDuplexChannel
    private let maxFrameBytes: Int64
    private let frameBudget: ?ProtocolFrameBudget
    private let consumedFrames = ArrayList<OwnedProtocolFrame>()
    private var capabilitiesText = "{}"
    private var capabilitiesStorage: ?ProtocolFrameReservation = None
    private let notificationHandler: LspNotificationHandler
    private let requestHandler: LspRequestHandler
    private let writeLock = Mutex()
    private let stateLock = Mutex()
    private let closeLock = Mutex()
    private var cleanupDone = false
    private let pending = ArrayList<LspPendingRequest>()
    private var nextId: Int64 = 1
    private let preparedSeal = LspPreparedClientSeal()
    private let dispatchedPrepared = HashSet<String>()
    private var closed = false
    private var closeError: ?LspError = None
    private var reader: ?Future<Unit> = None
    private var stderrReader: ?Future<Unit> = None
    private let stderr = BoundedByteBuffer(65536)

    public init(
        process: ManagedProcess,
        notificationHandler!: LspNotificationHandler = { _: String, _: JsonNode => () },
        requestHandler!: LspRequestHandler = { method: String, _: JsonNode =>
            LspResult.Err(LspError(
                LspErrorKind.Protocol, "lsp.method_not_found",
                "unsupported server request: " + method
            ))
        },
        maxFrameBytes!: Int64 = 33554432
    ) {
        if (maxFrameBytes < 1024) { throw IllegalArgumentException("invalid LSP frame limit") }
        this.channel = ManagedProcessDuplexChannel(process)
        this.notificationHandler = notificationHandler
        this.requestHandler = requestHandler
        this.maxFrameBytes = maxFrameBytes; frameBudget = None
        let output = guardedProtocolInput(channel.stdout)
        reader = Some(spawn { readLoop(output) })
        let errors = guardedProtocolInput(channel.stderr); let captured = stderr
        stderrReader = Some(spawn {
            let buffer = Array<Byte>(4096, repeat: 0)
            while (true) {
                let count = try { errors.read(buffer) } catch (_: Exception) { return }
                if (count <= 0) { return }
                let _ = captured.append(buffer, count: count)
            }
        })
    }

    public init(
        channel: ProcessDuplexChannel,
        notificationHandler!: LspNotificationHandler = { _: String, _: JsonNode => () },
        requestHandler!: LspRequestHandler = { method: String, _: JsonNode =>
            LspResult.Err(LspError(
                LspErrorKind.Protocol, "lsp.method_not_found",
                "unsupported server request: " + method
            ))
        },
        maxFrameBytes!: Int64 = 33554432,
        frameBudget!: ?ProtocolFrameBudget = None
    ) {
        if (maxFrameBytes < 1024) { throw IllegalArgumentException("invalid LSP frame limit") }
        this.channel = channel
        this.notificationHandler = notificationHandler
        this.requestHandler = requestHandler
        this.maxFrameBytes = maxFrameBytes; this.frameBudget = frameBudget
        let output = guardedProtocolInput(channel.stdout)
        reader = Some(spawn { readLoop(output) })
        let errors = guardedProtocolInput(channel.stderr); let captured = stderr
        stderrReader = Some(spawn {
            let buffer = Array<Byte>(4096, repeat: 0)
            while (true) {
                let count = try { errors.read(buffer) } catch (_: Exception) { return }
                if (count <= 0) { return }
                let _ = captured.append(buffer, count: count)
            }
        })
    }

    public static func `spawn`(
        command: ProcessCommand,
        notificationHandler!: LspNotificationHandler = { _: String, _: JsonNode => () },
        requestHandler!: LspRequestHandler = { method: String, _: JsonNode =>
            LspResult.Err(LspError(LspErrorKind.Protocol, "lsp.method_not_found", "unsupported server request: " + method))
        },
        maxFrameBytes!: Int64 = 33554432,
        backend!: ProcessBackend = defaultProcessBackend()
    ): LspResult<LspClient> {
        if (!command.terminateProcessTree) { return LspResult.Err(LspError(LspErrorKind.Transport,
            "lsp.channel_tree_required", "protocol client requires process-tree ownership before spawn")) }
        try { LspResult.Ok(LspClient(
            startProcess(command, backend: backend),
            notificationHandler: notificationHandler,
            requestHandler: requestHandler,
            maxFrameBytes: maxFrameBytes
        )) } catch (error: ProcessError) {
            LspResult.Err(LspError(LspErrorKind.Transport, "lsp.spawn_failed", error.message))
        }
    }

    public func initialize(params: JsonNode, timeoutMillis!: Int64 = 30000): LspResult<JsonNode> {
        match (request("initialize", params, timeoutMillis: timeoutMillis)) {
            case LspResult.Ok(value) =>
                let encoded = stringifyUnifiedJson(value.field("capabilities") ?? jsonObject([]))
                let reserved: ?ProtocolFrameReservation = try { match (frameBudget) { case Some(budget) => Some(budget.reserve(encoded.size)); case None => None } }
                    catch (_: Exception) { return LspResult.Err(LspError(LspErrorKind.Frame, "lsp.frame_budget_exceeded", "capability storage reservation was rejected")) }
                var retained = false
                stateLock.lock()
                let old: ?ProtocolFrameReservation = try {
                    if (closed) { None } else {
                        let prior = capabilitiesStorage; capabilitiesStorage = reserved; capabilitiesText = encoded; retained = true; prior
                    }
                } finally { stateLock.unlock() }
                if (!retained) {
                    match (reserved) { case Some(storage) => storage.close(); case None => () }
                    return LspResult.Err(LspError(LspErrorKind.Cancelled, "lsp.client_closed", "protocol client closed"))
                }
                match (old) { case Some(storage) => storage.close(); case None => () }
                match (notify("initialized", jsonObject([]))) {
                    case LspResult.Ok(_) => LspResult.Ok(value)
                    case LspResult.Err(error) => LspResult.Err(error)
                }
            case LspResult.Err(error) => LspResult.Err(error)
        }
    }

    public func serverCapabilities(): JsonNode {
        stateLock.lock(); let encoded = try { capabilitiesText } finally { stateLock.unlock() }
        if (frameBudget.isNone()) { return parseUnifiedJson(encoded, maxBytes: maxFrameBytes, maxDepth: 128) }
        let reservation = Some(frameBudget.getOrThrow().reserve(encoded.size))
        let frame = OwnedProtocolFrame(encoded.toArray(), reservation)
        var retained = false
        try {
            frame.beforeDecode()
            let result = parseUnifiedJson(encoded, maxBytes: maxFrameBytes, maxDepth: 128)
            stateLock.lock()
            try { if (closed) { throw ProcessError(ProcessErrorKind.Io, "protocol client closed") }; consumedFrames.add(frame); retained = true }
            finally { stateLock.unlock() }
            result
        } finally { if (!retained) { frame.close() } }
    }

    // A resource lifetime acknowledgement, never protocol I/O or permission.
    // The integrating caller closes its actual response-consumer scope first;
    // concurrent consumers must coordinate before releasing the consumed batch.
    public func releaseConsumedResponses(): Unit {
        stateLock.lock()
        let old = try { let values = consumedFrames.toArray(); consumedFrames.clear(); values } finally { stateLock.unlock() }
        let retained = ArrayList<OwnedProtocolFrame>()
        for (frame in old) { try { frame.close() } catch (_: Exception) { retained.add(frame) } }
        if (!retained.isEmpty()) {
            stateLock.lock()
            try { for (frame in retained) { consumedFrames.add(frame) } } finally { stateLock.unlock() }
            throw ProcessError(ProcessErrorKind.Io, "protocol consumer cleanup is still owned")
        }
    }

    // Pure protocol preparation. It neither allocates a sequence number nor
    // writes to the channel. These values are not host grants or receipts.
    public func prepareRequest(requestId: String, method: String, params: JsonNode,
        notifications!: Array<LspNotification> = []): LspResult<LspPreparedRequest> {
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return LspResult.Err(closedError()) }
            try { LspResult.Ok(LspPreparedRequest(preparedSeal, requestId, method, params, notifications)) }
            catch (_: Exception) { LspResult.Err(LspError(LspErrorKind.Protocol, "lsp.prepared_invalid", "prepared LSP request exceeds its fixed protocol bounds")) }
        } finally { stateLock.unlock() }
    }

    public func prepareNotification(dispatchId: String, notification: LspNotification): LspResult<LspPreparedRequest> {
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return LspResult.Err(closedError()) }
            try { LspResult.Ok(LspPreparedRequest(preparedSeal, dispatchId, "", jsonNull(), [notification])) }
            catch (_: Exception) { LspResult.Err(LspError(LspErrorKind.Protocol, "lsp.prepared_invalid", "prepared LSP notification exceeds its fixed protocol bounds")) }
        } finally { stateLock.unlock() }
    }

    public func dispatchPrepared(request: LspPreparedRequest, timeoutMillis!: Int64 = 30000): LspResult<JsonNode> {
        if (timeoutMillis < 1 || timeoutMillis > 3600000) {
            return LspResult.Err(LspError(LspErrorKind.Deadline, "lsp.deadline_invalid", "prepared request deadline is outside its fixed bound"))
        }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        let item = LspPendingRequest(stringifyUnifiedJson(jsonString(request.requestId)))
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return LspResult.Err(closedError()) }
            if (!request.belongsTo(preparedSeal)) { return LspResult.Err(LspError(LspErrorKind.Correlation, "lsp.prepared_foreign", "prepared request belongs to a different protocol client")) }
            if (dispatchedPrepared.contains(request.requestId)) { return LspResult.Err(LspError(LspErrorKind.Correlation, "lsp.prepared_reused", "prepared request has already been dispatched")) }
            if (dispatchedPrepared.size >= 4096) { return LspResult.Err(LspError(LspErrorKind.Correlation, "lsp.prepared_capacity", "prepared request tombstones reached their bounded capacity")) }
            dispatchedPrepared.add(request.requestId)
            if (request.expectsResponse) { pending.add(item) }
        } finally { stateLock.unlock() }
        match (writeBytes(request.framedBytes())) {
            case LspResult.Err(error) => release(item.id); return LspResult.Err(error)
            case LspResult.Ok(_) => ()
        }
        if (!request.expectsResponse) { return LspResult.Ok(jsonNull()) }
        while (MonoTime.now() < deadline) {
            match (take(item.id)) {
                case Some(value) => return value
                case None => sleep(Duration.millisecond * 1)
            }
        }
        // No undeclared cancel frame can be emitted after an exact-byte handoff.
        // The broker's canonical caller cancellation owns effect settlement.
        release(item.id)
        let error = LspError(LspErrorKind.Deadline, "lsp.prepared_deadline", "prepared LSP request expired after dispatch; its remote outcome is unknown")
        failAll(error)
        try { channel.abort() } catch (_: Exception) { () }
        LspResult.Err(error)
    }

    public func request(
        method: String,
        params: JsonNode,
        timeoutMillis!: Int64 = 30000
    ): LspResult<JsonNode> {
        if (timeoutMillis <= 0) {
            return LspResult.Err(LspError(LspErrorKind.Deadline, "lsp.deadline_invalid", "deadline must be positive"))
        }
        let item: LspPendingRequest
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return LspResult.Err(closedError()) }
            item = LspPendingRequest(nextId.toString()); nextId++
            pending.add(item)
        } finally { stateLock.unlock() }
        match (write(jsonObject([
            JsonObjectEntry("jsonrpc", jsonString("2.0")),
            JsonObjectEntry("id", jsonNumber(item.id)),
            JsonObjectEntry("method", jsonString(method)),
            JsonObjectEntry("params", params)
        ]))) {
            case LspResult.Ok(_) => ()
            case LspResult.Err(error) => release(item.id); return LspResult.Err(error)
        }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        while (MonoTime.now() < deadline) {
            match (take(item.id)) {
                case Some(LspResult.Ok(value)) => return LspResult.Ok(value)
                case Some(LspResult.Err(error)) => return LspResult.Err(error)
                case None => sleep(Duration.millisecond * 5)
            }
        }
        let _ = cancel(Int64.parse(item.id), reason: "deadline exceeded")
        release(item.id)
        LspResult.Err(LspError(LspErrorKind.Deadline, "lsp.deadline_exceeded", "LSP request deadline exceeded"))
    }

    public func notify(method: String, params: JsonNode): LspResult<Unit> {
        stateLock.lock(); try { if (closed || closeError.isSome()) { return LspResult.Err(closedError()) } } finally { stateLock.unlock() }
        write(jsonObject([
            JsonObjectEntry("jsonrpc", jsonString("2.0")),
            JsonObjectEntry("method", jsonString(method)),
            JsonObjectEntry("params", params)
        ]))
    }

    public func cancel(requestId: Int64, reason!: String = "cancelled by caller"): LspResult<Unit> {
        var found = false
        stateLock.lock()
        try {
            for (item in pending where item.id == requestId.toString()) {
                if (!item.cancelled && item.response.isNone() && item.error.isNone()) {
                    item.cancelled = true
                    item.error = Some(LspError(LspErrorKind.Cancelled, "lsp.request_cancelled", reason))
                }
                found = true; break
            }
        } finally { stateLock.unlock() }
        if (!found) { return LspResult.Ok(()) }
        write(jsonObject([
            JsonObjectEntry("jsonrpc", jsonString("2.0")),
            JsonObjectEntry("method", jsonString("$/cancelRequest")),
            JsonObjectEntry("params", jsonObject([
                JsonObjectEntry("id", jsonNumber(requestId.toString()))
            ]))
        ]))
    }

    public func pendingCount(): Int64 {
        stateLock.lock(); try { pending.size } finally { stateLock.unlock() }
    }

    public func stderrSnapshot(): String {
        try { String.fromUtf8(stderr.snapshot()) } catch (_: Exception) { "" }
    }

    public func isClosed(): Bool { stateLock.lock(); try { closed } finally { stateLock.unlock() } }

    public func shutdown(timeoutMillis!: Int64 = 3000): LspResult<Unit> {
        if (isClosed()) { return LspResult.Ok(()) }
        match (request("shutdown", jsonNull(), timeoutMillis: timeoutMillis)) {
            case LspResult.Ok(_) => let _ = notify("exit", jsonObject([])); close()
            case LspResult.Err(error) => let _ = close(); LspResult.Err(error)
        }
    }

    public func close(): LspResult<Unit> {
        closeLock.lock()
        try {
            if (cleanupDone) { return LspResult.Ok(()) }
            stateLock.lock()
            try {
                closed = true
                closeError = Some(LspError(LspErrorKind.Cancelled, "lsp.client_closed", "protocol client closed"))
                for (item in pending where item.response.isNone() && item.error.isNone()) { item.error = closeError }
            } finally { stateLock.unlock() }
            try { channel.abort(); channel.stop(0) } catch (_: Exception) {
                return LspResult.Err(LspError(LspErrorKind.Transport, "lsp.cleanup_pending", "protocol channel cleanup is still owned"))
            }
            match (reader) { case Some(task) => try { task.get() } catch (_: Exception) {}; case None => () }
            match (stderrReader) { case Some(task) => try { task.get() } catch (_: Exception) {}; case None => () }
            try { channel.close() } catch (_: Exception) {
                return LspResult.Err(LspError(LspErrorKind.Transport, "lsp.cleanup_pending", "protocol channel cleanup is still owned"))
            }
            try {
                stateLock.lock()
                try {
                    for (item in pending) { match (item.frame) { case Some(value) => consumedFrames.add(value); case None => () } }
                    pending.clear()
                } finally { stateLock.unlock() }
                releaseConsumedResponses()
                stateLock.lock()
                let capability = try { capabilitiesStorage } finally { stateLock.unlock() }
                match (capability) { case Some(value) => value.close(); case None => () }
                stateLock.lock()
                try { capabilitiesStorage = None; capabilitiesText = "{}" } finally { stateLock.unlock() }
            } catch (_: Exception) {
                return LspResult.Err(LspError(LspErrorKind.Transport, "lsp.cleanup_pending", "protocol frame cleanup is still owned"))
            }
            cleanupDone = true; LspResult.Ok(())
        } finally { closeLock.unlock() }
    }

    private func readLoop(stream: InputStream): Unit {
        while (true) {
            if (isClosed()) { return }
            var owned: ?OwnedProtocolFrame = None
            var retained = false
            try {
                let frame = try { readContentLengthFrame(stream, maxBodyBytes: maxFrameBytes, budget: frameBudget) }
                    catch (error: ProcessError) {
                        failAll(LspError(if (let ProcessErrorKind.Io <- error.kind) { LspErrorKind.Transport } else { LspErrorKind.Frame },
                            if (let ProcessErrorKind.Io <- error.kind) { "lsp.transport_closed" } else { "lsp.frame_invalid" },
                            "protocol frame could not be received")); return
                    } catch (_: Exception) {
                        failAll(LspError(LspErrorKind.Frame, "lsp.frame_budget_exceeded", "protocol frame reservation was rejected")); return
                    }
                owned = Some(frame)
                try { frame.beforeDecode() } catch (_: Exception) {
                    failAll(LspError(LspErrorKind.Frame, "lsp.frame_budget_exceeded", "protocol frame decoding reservation was rejected")); return
                }
                let encoded = try { String.fromUtf8(frame.bytes) } catch (_: Exception) {
                    failAll(LspError(LspErrorKind.Json, "lsp.utf8_invalid", "protocol frame is not valid UTF-8")); return
                }
                let message = try { parseUnifiedJson(encoded, maxBytes: maxFrameBytes, maxDepth: 128) }
                    catch (_: JsonException) {
                        failAll(LspError(LspErrorKind.Json, "lsp.json_invalid", "protocol frame is not valid bounded JSON")); return
                    } catch (_: Exception) {
                        failAll(LspError(LspErrorKind.Json, "lsp.json_invalid", "protocol frame could not be decoded")); return
                    }
                retained = dispatch(message, frame)
            } catch (_: Exception) {
                failAll(LspError(LspErrorKind.Transport, "lsp.callback_failed", "protocol consumer callback failed")); return
            } finally { if (!retained) { match (owned) { case Some(frame) => frame.close(); case None => () } } }
        }
    }

    private func dispatch(message: JsonNode, frame: OwnedProtocolFrame): Bool {
        match (message.field("method")) {
            case Some(methodValue) =>
                if (methodValue.unifiedKind != UnifiedJsonKind.Text) { failAll(LspError(LspErrorKind.Protocol, "lsp.method_invalid", "method must be a string")); return false }
                let params = message.field("params") ?? jsonObject([])
                match (message.field("id")) {
                    case Some(id) => handleServerRequest(id, methodValue.text, params)
                    case None => notificationHandler(methodValue.text, params)
                }
                false
            case None =>
                let id = lspPendingKey(message.field("id") ?? jsonNull())
                if (id == "") { failAll(LspError(LspErrorKind.Protocol, "lsp.response_id_invalid", "response id is invalid")); return false }
                match (message.field("error")) {
                    case Some(error) => settleError(id, LspError(LspErrorKind.Protocol, "lsp.server_error", stringifyUnifiedJson(error)), frame)
                    case None => settleResponse(id, message.field("result") ?? jsonNull(), frame)
                }
        }
    }

    private func handleServerRequest(id: JsonNode, method: String, params: JsonNode): Unit {
        match (requestHandler(method, params)) {
            case LspResult.Ok(value) => let _ = write(jsonObject([
                JsonObjectEntry("jsonrpc", jsonString("2.0")), JsonObjectEntry("id", id), JsonObjectEntry("result", value)
            ]))
            case LspResult.Err(error) => let _ = write(jsonObject([
                JsonObjectEntry("jsonrpc", jsonString("2.0")), JsonObjectEntry("id", id),
                JsonObjectEntry("error", jsonObject([
                    JsonObjectEntry("code", jsonNumber("-32601")),
                    JsonObjectEntry("message", jsonString(error.message))
                ]))
            ]))
        }
    }

    private func write(value: JsonNode): LspResult<Unit> { writeBytes(encodeLspMessage(value)) }
    private func writeBytes(bytes: Array<Byte>): LspResult<Unit> {
        writeLock.lock()
        try {
            try { channel.write(bytes); channel.flush(); LspResult.Ok(()) }
            catch (_: Exception) { LspResult.Err(LspError(LspErrorKind.Transport, "lsp.write_failed", "protocol channel write failed")) }
        } finally { writeLock.unlock() }
    }

    private func settleResponse(id: String, value: JsonNode, frame: OwnedProtocolFrame): Bool {
        stateLock.lock()
        try { for (item in pending where item.id == id && item.response.isNone() && item.error.isNone()) { if (frameBudget.isSome()) { item.frame = Some(frame) }; item.response = Some(value); return frameBudget.isSome() }; false }
        finally { stateLock.unlock() }
    }
    private func settleError(id: String, error: LspError, frame: OwnedProtocolFrame): Bool {
        stateLock.lock()
        try { for (item in pending where item.id == id && item.response.isNone() && item.error.isNone()) { if (frameBudget.isSome()) { item.frame = Some(frame) }; item.error = Some(error); return frameBudget.isSome() }; false }
        finally { stateLock.unlock() }
    }
    private func take(id: String): ?LspResult<JsonNode> {
        stateLock.lock(); try {
            for (index in 0..pending.size where pending[index].id == id) {
                let item = pending[index]
                match (item.response) { case Some(value) => match (item.frame) { case Some(frame) => consumedFrames.add(frame); case None => () }; pending.remove(at: index); return Some(LspResult.Ok(value)); case None => () }
                match (item.error) { case Some(error) => match (item.frame) { case Some(frame) => consumedFrames.add(frame); case None => () }; pending.remove(at: index); return Some(LspResult.Err(error)); case None => return None }
            }
            match (closeError) {
                case Some(error) => Some(LspResult.Err(error))
                case None => Some(LspResult.Err(LspError(LspErrorKind.Correlation, "lsp.request_unknown", "request is no longer pending")))
            }
        } finally { stateLock.unlock() }
    }
    private func release(id: String): Unit {
        var frame: ?OwnedProtocolFrame = None
        stateLock.lock()
        try { for (index in 0..pending.size where pending[index].id == id) { frame = pending[index].frame; pending.remove(at: index); break } }
        finally { stateLock.unlock() }
        match (frame) { case Some(value) => value.close(); case None => () }
    }

    private func failAll(error: LspError): Unit {
        stateLock.lock(); try {
            if (!closed) { closeError = Some(error) }
            for (item in pending where item.response.isNone() && item.error.isNone()) { item.error = Some(error) }
        } finally { stateLock.unlock() }
    }
    private func closedError(): LspError { match (closeError) { case Some(error) => error; case None => LspError(LspErrorKind.Transport, "lsp.client_closed", "LSP client is closed") } }
}

func jsonInteger(value: JsonNode, name: String, fallback: Int64): Int64 {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Number) { try { Int64.parse(item.asNumberText()) } catch (_: Exception) { fallback } } else { fallback }
        case None => fallback
    }
}
