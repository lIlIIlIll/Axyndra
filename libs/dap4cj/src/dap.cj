package dap4cj

import json4cj.*
import process4cj.*
import std.collection.*
import std.convert.*
import std.io.*
import std.sync.*
import std.time.*

public enum DapErrorKind { Frame | Json | Protocol | Correlation | Transport | Cancelled | Deadline }

public class DapError <: Exception {
    public let kind: DapErrorKind
    public let code: String
    public init(kind: DapErrorKind, code: String, message: String) {
        super(message); this.kind = kind; this.code = code
    }
}

public enum DapResult<T> {
    Ok(T) | Err(DapError)
    public func isOk(): Bool { match (this) { case Ok(_) => true; case Err(_) => false } }
}

public func encodeDapMessage(value: JsonValue): Array<Byte> {
    encodeContentLengthFrame(encodeJson(value))
}

public func readDapMessage(
    stream: InputStream,
    maxBodyBytes!: Int64 = 33554432,
    maxDepth!: Int64 = 128
): DapResult<JsonValue> {
    let body = try { readContentLengthBody(stream, maxBodyBytes: maxBodyBytes) } catch (error: ProcessError) {
        return DapResult.Err(DapError(
            if (let ProcessErrorKind.Io <- error.kind) { DapErrorKind.Transport } else { DapErrorKind.Frame },
            if (let ProcessErrorKind.Io <- error.kind) { "dap.transport_closed" } else { "dap.frame_invalid" },
            error.message
        ))
    }
    let value = try {
        parseJson(String.fromUtf8(body), maxBytes: maxBodyBytes, maxDepth: maxDepth)
    } catch (error: JsonError) {
        return DapResult.Err(DapError(DapErrorKind.Json, "dap.json_invalid", error.message))
    } catch (error: Exception) {
        return DapResult.Err(DapError(DapErrorKind.Json, "dap.utf8_invalid", error.message))
    }
    if (value.kind != JsonKind.Object || value.field("seq").isNone() || value.field("type").isNone()) {
        return DapResult.Err(DapError(DapErrorKind.Protocol, "dap.envelope_invalid", "DAP message requires seq and type"))
    }
    DapResult.Ok(value)
}

public class DapCorrelation {
    private let lock = Mutex()
    private let pending = HashMap<Int64, Bool>()
    public init() {}
    public func reserve(sequence: Int64): DapResult<Unit> {
        if (sequence < 1) { return failure("dap.sequence_invalid", "DAP sequence must be positive") }
        lock.lock(); try {
            if (pending.contains(sequence)) { return failure("dap.sequence_in_use", "DAP sequence is already pending") }
            pending[sequence] = true
            DapResult.Ok(())
        } finally { lock.unlock() }
    }
    public func complete(requestSequence: Int64): DapResult<Unit> {
        lock.lock(); try {
            if (!pending.contains(requestSequence)) { return failure("dap.sequence_unknown", "DAP response references an unknown request") }
            pending.remove(requestSequence)
            DapResult.Ok(())
        } finally { lock.unlock() }
    }
    public func cancel(requestSequence: Int64): DapResult<Unit> { complete(requestSequence) }
    private func failure(code: String, message: String): DapResult<Unit> {
        DapResult.Err(DapError(DapErrorKind.Correlation, code, message))
    }
}

public type DapEventHandler = (String, JsonValue) -> Unit
public type DapReverseRequestHandler = (String, JsonValue) -> DapResult<JsonValue>

class DapPendingRequest {
    let sequence: Int64
    let command: String
    var result: ?JsonValue = None
    var error: ?DapError = None
    init(sequence: Int64, command: String) { this.sequence = sequence; this.command = command }
}

// Process-backed DAP protocol client. Debugger authorization, workspace
// validation and runInTerminal execution are supplied by the product handler.
public class DapClient {
    private let process: ManagedProcess
    private let eventHandler: DapEventHandler
    private let reverseHandler: DapReverseRequestHandler
    private let maxFrameBytes: Int64
    private let writeLock = Mutex()
    private let stateLock = Mutex()
    private let pending = ArrayList<DapPendingRequest>()
    private var nextSequence: Int64 = 1
    private var closed = false
    private var closeError: ?DapError = None
    private var reader: ?Future<Unit> = None
    private var stderrReader: ?Future<Unit> = None
    private let stderr = BoundedByteBuffer(65536)

    public init(
        process: ManagedProcess,
        eventHandler!: DapEventHandler = { _: String, _: JsonValue => () },
        reverseRequestHandler!: DapReverseRequestHandler = { command: String, _: JsonValue =>
            DapResult.Err(DapError(DapErrorKind.Protocol, "dap.request_unsupported", "unsupported adapter request: " + command))
        },
        maxFrameBytes!: Int64 = 33554432
    ) {
        if (maxFrameBytes < 1024) { throw IllegalArgumentException("invalid DAP frame limit") }
        this.process = process; this.eventHandler = eventHandler
        this.reverseHandler = reverseRequestHandler; this.maxFrameBytes = maxFrameBytes
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
        eventHandler!: DapEventHandler = { _: String, _: JsonValue => () },
        reverseRequestHandler!: DapReverseRequestHandler = { command: String, _: JsonValue =>
            DapResult.Err(DapError(DapErrorKind.Protocol, "dap.request_unsupported", "unsupported adapter request: " + command))
        },
        maxFrameBytes!: Int64 = 33554432,
        backend!: ProcessBackend = defaultProcessBackend()
    ): DapResult<DapClient> {
        try { DapResult.Ok(DapClient(
            startProcess(command, backend: backend), eventHandler: eventHandler,
            reverseRequestHandler: reverseRequestHandler, maxFrameBytes: maxFrameBytes
        )) } catch (error: ProcessError) {
            DapResult.Err(DapError(DapErrorKind.Transport, "dap.spawn_failed", error.message))
        }
    }

    public func initialize(arguments: JsonValue, timeoutMillis!: Int64 = 30000): DapResult<JsonValue> {
        request("initialize", arguments, timeoutMillis: timeoutMillis)
    }

    public func request(
        command: String,
        arguments: JsonValue,
        timeoutMillis!: Int64 = 30000
    ): DapResult<JsonValue> {
        let sequence = match (beginRequest(command, arguments)) {
            case DapResult.Ok(value) => value
            case DapResult.Err(error) => return DapResult.Err(error)
        }
        waitResponse(sequence, timeoutMillis: timeoutMillis)
    }

    public func beginRequest(command: String, arguments: JsonValue): DapResult<Int64> {
        let item: DapPendingRequest
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return DapResult.Err(closedFailure()) }
            item = DapPendingRequest(nextSequence, command); nextSequence++
            pending.add(item)
        } finally { stateLock.unlock() }
        match (write(JsonValue.objectValue([
            JsonField("seq", JsonValue.numberValue(item.sequence.toString())),
            JsonField("type", JsonValue.stringValue("request")),
            JsonField("command", JsonValue.stringValue(command)),
            JsonField("arguments", arguments)
        ]))) {
            case DapResult.Ok(_) => DapResult.Ok(item.sequence)
            case DapResult.Err(error) => settleError(item.sequence, error); DapResult.Err(error)
        }
    }

    public func waitResponse(requestSequence: Int64, timeoutMillis!: Int64 = 30000): DapResult<JsonValue> {
        if (timeoutMillis <= 0) { return DapResult.Err(DapError(DapErrorKind.Deadline, "dap.deadline_invalid", "deadline must be positive")) }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        while (MonoTime.now() < deadline) {
            match (take(requestSequence)) {
                case Some(DapResult.Ok(value)) => return DapResult.Ok(value)
                case Some(DapResult.Err(error)) => return DapResult.Err(error)
                case None => sleep(Duration.millisecond * 5)
            }
        }
        let _ = cancel(requestSequence)
        release(requestSequence)
        DapResult.Err(DapError(DapErrorKind.Deadline, "dap.deadline_exceeded", "DAP request deadline exceeded"))
    }

    public func cancel(requestSequence: Int64): DapResult<Unit> {
        var found = false
        stateLock.lock(); try {
            for (item in pending where item.sequence == requestSequence) {
                if (item.result.isNone() && item.error.isNone()) {
                    item.error = Some(DapError(DapErrorKind.Cancelled, "dap.request_cancelled", "DAP request was cancelled"))
                }
                found = true; break
            }
        } finally { stateLock.unlock() }
        if (!found) { return DapResult.Ok(()) }
        let arguments = JsonValue.objectValue([
            JsonField("requestId", JsonValue.numberValue(requestSequence.toString()))
        ])
        let sequence: Int64
        stateLock.lock(); try { sequence = nextSequence; nextSequence++ } finally { stateLock.unlock() }
        // DAP cancel is a control request. Its response is intentionally not
        // correlated with an application waiter, so it must not occupy the
        // pending table.
        write(JsonValue.objectValue([
            JsonField("seq", JsonValue.numberValue(sequence.toString())),
            JsonField("type", JsonValue.stringValue("request")),
            JsonField("command", JsonValue.stringValue("cancel")),
            JsonField("arguments", arguments)
        ]))
    }

    public func pendingCount(): Int64 { stateLock.lock(); try { pending.size } finally { stateLock.unlock() } }
    public func isClosed(): Bool { stateLock.lock(); try { closed } finally { stateLock.unlock() } }
    public func isAlive(): Bool {
        stateLock.lock(); try { !closed && closeError.isNone() } finally { stateLock.unlock() }
    }
    public func stderrSnapshot(): String { try { String.fromUtf8(stderr.snapshot()) } catch (_: Exception) { "" } }

    public func disconnect(arguments!: JsonValue = JsonValue.objectValue([]), timeoutMillis!: Int64 = 3000): DapResult<Unit> {
        if (isClosed()) { return DapResult.Ok(()) }
        match (request("disconnect", arguments, timeoutMillis: timeoutMillis)) {
            case DapResult.Ok(_) => close()
            case DapResult.Err(error) => let _ = close(); DapResult.Err(error)
        }
    }

    public func terminate(arguments!: JsonValue = JsonValue.objectValue([]), timeoutMillis!: Int64 = 3000): DapResult<Unit> {
        if (isClosed()) { return DapResult.Ok(()) }
        match (request("terminate", arguments, timeoutMillis: timeoutMillis)) {
            case DapResult.Ok(_) => DapResult.Ok(())
            case DapResult.Err(error) => DapResult.Err(error)
        }
    }

    public func close(): DapResult<Unit> {
        stateLock.lock(); try {
            if (closed) { return DapResult.Ok(()) }
            closed = true
            closeError = Some(DapError(DapErrorKind.Cancelled, "dap.client_closed", "DAP client closed"))
            for (item in pending where item.result.isNone() && item.error.isNone()) { item.error = closeError }
        } finally { stateLock.unlock() }
        let _ = process.terminate(force: true); let _ = process.wait()
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
        DapResult.Ok(())
    }

    private func readLoop(stream: InputStream): Unit {
        while (true) {
            if (isClosed()) { return }
            match (readDapMessage(stream, maxBodyBytes: maxFrameBytes)) {
                case DapResult.Ok(message) => dispatch(message)
                case DapResult.Err(error) => failAll(error); return
            }
        }
    }

    private func dispatch(message: JsonValue): Unit {
        match (textField(message, "type")) {
            case "event" => eventHandler(
                textField(message, "event"), objectField(message, "body")
            )
            case "request" => handleReverseRequest(message)
            case "response" =>
                let requestSequence = integerField(message, "request_seq", -1)
                if (requestSequence < 1) { failAll(DapError(DapErrorKind.Protocol, "dap.response_sequence_invalid", "response request_seq is invalid")); return }
                if (!boolField(message, "success", false)) {
                    settleError(requestSequence, DapError(
                        DapErrorKind.Protocol, "dap.adapter_error",
                        if (textField(message, "message") == "") { "DAP request failed" } else { textField(message, "message") }
                    ))
                } else { settleResult(requestSequence, objectField(message, "body")) }
            case _ => failAll(DapError(DapErrorKind.Protocol, "dap.message_type_invalid", "unsupported DAP message type"))
        }
    }

    private func handleReverseRequest(message: JsonValue): Unit {
        let requestSequence = integerField(message, "seq", 0)
        let command = textField(message, "command")
        let result = reverseHandler(command, objectField(message, "arguments"))
        let responseSequence: Int64
        stateLock.lock(); try { responseSequence = nextSequence; nextSequence++ } finally { stateLock.unlock() }
        let fields = ArrayList<JsonField>()
        fields.add(JsonField("seq", JsonValue.numberValue(responseSequence.toString())))
        fields.add(JsonField("type", JsonValue.stringValue("response")))
        fields.add(JsonField("request_seq", JsonValue.numberValue(requestSequence.toString())))
        fields.add(JsonField("command", JsonValue.stringValue(command)))
        match (result) {
            case DapResult.Ok(body) => fields.add(JsonField("success", JsonValue.boolValue(true))); fields.add(JsonField("body", body))
            case DapResult.Err(error) => fields.add(JsonField("success", JsonValue.boolValue(false))); fields.add(JsonField("message", JsonValue.stringValue(error.message)))
        }
        let _ = write(JsonValue.objectValue(fields.toArray()))
    }

    private func write(value: JsonValue): DapResult<Unit> {
        writeLock.lock(); try {
            try { process.writeStdin(encodeDapMessage(value)); process.flushInput(); DapResult.Ok(()) }
            catch (error: ProcessError) { DapResult.Err(DapError(DapErrorKind.Transport, "dap.write_failed", error.message)) }
        } finally { writeLock.unlock() }
    }
    private func settleResult(sequence: Int64, value: JsonValue): Unit { stateLock.lock(); try { for (item in pending where item.sequence == sequence && item.result.isNone() && item.error.isNone()) { item.result = Some(value); return } } finally { stateLock.unlock() } }
    private func settleError(sequence: Int64, error: DapError): Unit { stateLock.lock(); try { for (item in pending where item.sequence == sequence && item.result.isNone() && item.error.isNone()) { item.error = Some(error); return } } finally { stateLock.unlock() } }
    private func take(sequence: Int64): ?DapResult<JsonValue> {
        stateLock.lock(); try {
            for (index in 0..pending.size where pending[index].sequence == sequence) {
                let item = pending[index]
                match (item.result) { case Some(value) => pending.remove(at: index); return Some(DapResult.Ok(value)); case None => () }
                match (item.error) { case Some(error) => pending.remove(at: index); return Some(DapResult.Err(error)); case None => return None }
            }
            match (closeError) {
                case Some(error) => Some(DapResult.Err(error))
                case None => Some(DapResult.Err(DapError(DapErrorKind.Correlation, "dap.request_unknown", "request is no longer pending")))
            }
        } finally { stateLock.unlock() }
    }
    private func release(sequence: Int64): Unit { stateLock.lock(); try { for (index in 0..pending.size where pending[index].sequence == sequence) { pending.remove(at: index); return } } finally { stateLock.unlock() } }
    private func failAll(error: DapError): Unit { stateLock.lock(); try { if (!closed) { closeError = Some(error) }; for (item in pending where item.result.isNone() && item.error.isNone()) { item.error = Some(error) } } finally { stateLock.unlock() } }
    private func closedFailure(): DapError { match (closeError) { case Some(error) => error; case None => DapError(DapErrorKind.Transport, "dap.client_closed", "DAP client is closed") } }
}

func textField(value: JsonValue, name: String): String { match (value.field(name)) { case Some(item) => if (item.kind == JsonKind.Text) { item.text } else { "" }; case None => "" } }
func integerField(value: JsonValue, name: String, fallback: Int64): Int64 { match (value.field(name)) { case Some(item) => if (item.kind == JsonKind.Number) { try { Int64.parse(item.number) } catch (_: Exception) { fallback } } else { fallback }; case None => fallback } }
func boolField(value: JsonValue, name: String, fallback: Bool): Bool { match (value.field(name)) { case Some(item) => if (item.kind == JsonKind.Boolean) { item.boolean } else { fallback }; case None => fallback } }
func objectField(value: JsonValue, name: String): JsonValue { match (value.field(name)) { case Some(item) => item; case None => JsonValue.objectValue([]) } }
