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
    let id: Int64
    var response: ?JsonNode = None
    var error: ?LspError = None
    var cancelled: Bool = false
    init(id: Int64) { this.id = id }
}

// Process-backed protocol client. Product-specific notification/request
// semantics are supplied by callbacks and never enter this package.
public class LspClient {
    private let process: ManagedProcess
    private let maxFrameBytes: Int64
    private let notificationHandler: LspNotificationHandler
    private let requestHandler: LspRequestHandler
    private let writeLock = Mutex()
    private let stateLock = Mutex()
    private let pending = ArrayList<LspPendingRequest>()
    private var nextId: Int64 = 1
    private var closed = false
    private var closeError: ?LspError = None
    private var capabilities = jsonObject([])
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
        this.process = process
        this.notificationHandler = notificationHandler
        this.requestHandler = requestHandler
        this.maxFrameBytes = maxFrameBytes
        let output = process.stdout
        reader = Some(spawn { readLoop(output) })
        let errors = process.stderr; let captured = stderr
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
                stateLock.lock()
                try { capabilities = match (value.field("capabilities")) {
                    case Some(found) => found
                    case None => jsonObject([])
                } } finally { stateLock.unlock() }
                match (notify("initialized", jsonObject([]))) {
                    case LspResult.Ok(_) => LspResult.Ok(value)
                    case LspResult.Err(error) => LspResult.Err(error)
                }
            case LspResult.Err(error) => LspResult.Err(error)
        }
    }

    public func serverCapabilities(): JsonNode {
        stateLock.lock(); try { capabilities } finally { stateLock.unlock() }
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
            item = LspPendingRequest(nextId); nextId++
            pending.add(item)
        } finally { stateLock.unlock() }
        match (write(jsonObject([
            JsonObjectEntry("jsonrpc", jsonString("2.0")),
            JsonObjectEntry("id", jsonNumber(item.id.toString())),
            JsonObjectEntry("method", jsonString(method)),
            JsonObjectEntry("params", params)
        ]))) {
            case LspResult.Ok(_) => ()
            case LspResult.Err(error) => settleError(item.id, error); return LspResult.Err(error)
        }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        while (MonoTime.now() < deadline) {
            match (take(item.id)) {
                case Some(LspResult.Ok(value)) => return LspResult.Ok(value)
                case Some(LspResult.Err(error)) => return LspResult.Err(error)
                case None => sleep(Duration.millisecond * 5)
            }
        }
        let _ = cancel(item.id, reason: "deadline exceeded")
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
            for (item in pending where item.id == requestId) {
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
        stateLock.lock()
        try {
            if (closed) { return LspResult.Ok(()) }
            closed = true
            closeError = Some(LspError(LspErrorKind.Cancelled, "lsp.client_closed", "LSP client closed"))
            for (item in pending where item.response.isNone() && item.error.isNone()) {
                item.error = closeError
            }
        } finally { stateLock.unlock() }
        let _ = process.terminate(force: true)
        let _ = process.wait()
        match (reader) {
            case Some(task) => try { task.get() } catch (_: Exception) {}
            case None => ()
        }
        match (stderrReader) {
            case Some(task) => try { task.get() } catch (_: Exception) {}
            case None => ()
        }
        let _ = process.close()
        stateLock.lock(); try { pending.clear() } finally { stateLock.unlock() }
        LspResult.Ok(())
    }

    private func readLoop(stream: InputStream): Unit {
        while (true) {
            if (isClosed()) { return }
            match (readLspMessage(stream, maxBodyBytes: maxFrameBytes)) {
                case LspResult.Ok(message) => dispatch(message)
                case LspResult.Err(error) => failAll(error); return
            }
        }
    }

    private func dispatch(message: JsonNode): Unit {
        match (message.field("method")) {
            case Some(methodValue) =>
                if (methodValue.unifiedKind != UnifiedJsonKind.Text) { failAll(LspError(LspErrorKind.Protocol, "lsp.method_invalid", "method must be a string")); return }
                let params = match (message.field("params")) { case Some(value) => value; case None => jsonObject([]) }
                match (message.field("id")) {
                    case Some(id) => handleServerRequest(id, methodValue.text, params)
                    case None => notificationHandler(methodValue.text, params)
                }
            case None =>
                let id = jsonInteger(message, "id", -1)
                if (id < 0) { failAll(LspError(LspErrorKind.Protocol, "lsp.response_id_invalid", "response id is invalid")); return }
                match (message.field("error")) {
                    case Some(error) => settleError(id, LspError(
                        LspErrorKind.Protocol, "lsp.server_error", stringifyUnifiedJson(error)
                    ))
                    case None => settleResponse(id, match (message.field("result")) {
                        case Some(value) => value
                        case None => jsonNull()
                    })
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

    private func write(value: JsonNode): LspResult<Unit> {
        writeLock.lock()
        try {
            try { process.writeStdin(encodeLspMessage(value)); process.flushInput(); LspResult.Ok(()) }
            catch (error: ProcessError) { LspResult.Err(LspError(LspErrorKind.Transport, "lsp.write_failed", error.message)) }
        } finally { writeLock.unlock() }
    }

    private func settleResponse(id: Int64, value: JsonNode): Unit {
        stateLock.lock(); try { for (item in pending where item.id == id && item.response.isNone() && item.error.isNone()) { item.response = Some(value); return } }
        finally { stateLock.unlock() }
    }
    private func settleError(id: Int64, error: LspError): Unit {
        stateLock.lock(); try { for (item in pending where item.id == id && item.response.isNone() && item.error.isNone()) { item.error = Some(error); return } }
        finally { stateLock.unlock() }
    }
    private func take(id: Int64): ?LspResult<JsonNode> {
        stateLock.lock(); try {
            for (index in 0..pending.size where pending[index].id == id) {
                let item = pending[index]
                match (item.response) { case Some(value) => pending.remove(at: index); return Some(LspResult.Ok(value)); case None => () }
                match (item.error) { case Some(error) => pending.remove(at: index); return Some(LspResult.Err(error)); case None => return None }
            }
            match (closeError) {
                case Some(error) => Some(LspResult.Err(error))
                case None => Some(LspResult.Err(LspError(LspErrorKind.Correlation, "lsp.request_unknown", "request is no longer pending")))
            }
        } finally { stateLock.unlock() }
    }
    private func release(id: Int64): Unit { stateLock.lock(); try { for (index in 0..pending.size where pending[index].id == id) { pending.remove(at: index); return } } finally { stateLock.unlock() } }
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
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Number) { try { Int64.parse(item.number) } catch (_: Exception) { fallback } } else { fallback }
        case None => fallback
    }
}
