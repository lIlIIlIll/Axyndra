package dap4cj

import yjson.*
import yjson_support.*
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

public func encodeDapMessage(value: JsonNode): Array<Byte> {
    encodeContentLengthFrame(stringifyUnifiedJson(value))
}

public func readDapMessage(
    stream: InputStream,
    maxBodyBytes!: Int64 = 33554432,
    maxDepth!: Int64 = 128
): DapResult<JsonNode> {
    let body = try { readContentLengthBody(stream, maxBodyBytes: maxBodyBytes) } catch (error: ProcessError) {
        return DapResult.Err(DapError(
            if (let ProcessErrorKind.Io <- error.kind) { DapErrorKind.Transport } else { DapErrorKind.Frame },
            if (let ProcessErrorKind.Io <- error.kind) { "dap.transport_closed" } else { "dap.frame_invalid" },
            error.message
        ))
    }
    decodeDapBody(body, maxBodyBytes, maxDepth)
}

func decodeDapBody(body: Array<Byte>, maxBodyBytes: Int64, maxDepth: Int64): DapResult<JsonNode> {
    let value = try {
        parseUnifiedJson(String.fromUtf8(body), maxBytes: maxBodyBytes, maxDepth: maxDepth)
    } catch (error: JsonException) {
        return DapResult.Err(DapError(DapErrorKind.Json, "dap.json_invalid", error.message))
    } catch (error: Exception) {
        return DapResult.Err(DapError(DapErrorKind.Json, "dap.utf8_invalid", error.message))
    }
    if (value.unifiedKind != UnifiedJsonKind.Object || value.field("seq").isNone() || value.field("type").isNone()) {
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

public type DapEventHandler = (String, JsonNode) -> Unit
public type DapReverseRequestHandler = (String, JsonNode) -> DapResult<JsonNode>

class DapPendingRequest {
    let sequence: Int64
    let command: String
    var frame: ?OwnedProtocolFrame = None
    var result: ?JsonNode = None
    var error: ?DapError = None
    init(sequence: Int64, command: String) { this.sequence = sequence; this.command = command }
}

// Process-backed DAP protocol client. Debugger authorization, workspace
// validation and runInTerminal execution are supplied by the product handler.
public class DapClient {
    private let channel: ProcessDuplexChannel
    private let eventHandler: DapEventHandler
    private let reverseHandler: DapReverseRequestHandler
    private let maxFrameBytes: Int64
    private let frameBudget: ?ProtocolFrameBudget
    private let consumedFrames = ArrayList<OwnedProtocolFrame>()
    private let discardPreparedAfterDispatch: Bool
    private let writeLock = Mutex()
    private let stateLock = Mutex()
    private let closeLock = Mutex()
    private var cleanupDone = false
    private let pending = ArrayList<DapPendingRequest>()
    private var nextSequence: Int64 = 1
    private let preparedSeal = DapPreparedClientSeal()
    private let preparedCalls = HashMap<String, DapPreparedRequest>()
    private var preparedBytes: Int64 = 0
    private let dispatchedPrepared = HashSet<String>()
    private var closed = false
    private var closeError: ?DapError = None
    private var reader: ?Future<Unit> = None
    private var stderrReader: ?Future<Unit> = None
    private let stderr = BoundedByteBuffer(65536)

    public init(
        process: ManagedProcess,
        eventHandler!: DapEventHandler = { _: String, _: JsonNode => () },
        reverseRequestHandler!: DapReverseRequestHandler = { command: String, _: JsonNode =>
            DapResult.Err(DapError(DapErrorKind.Protocol, "dap.request_unsupported", "unsupported adapter request: " + command))
        },
        maxFrameBytes!: Int64 = 33554432
    ) {
        if (maxFrameBytes < 1024) { throw IllegalArgumentException("invalid DAP frame limit") }
        this.channel = ManagedProcessDuplexChannel(process); this.eventHandler = eventHandler
        this.reverseHandler = reverseRequestHandler; this.maxFrameBytes = maxFrameBytes
        frameBudget = None; discardPreparedAfterDispatch = false
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
        eventHandler!: DapEventHandler = { _: String, _: JsonNode => () },
        reverseRequestHandler!: DapReverseRequestHandler = { command: String, _: JsonNode =>
            DapResult.Err(DapError(DapErrorKind.Protocol, "dap.request_unsupported", "unsupported adapter request: " + command))
        },
        maxFrameBytes!: Int64 = 33554432,
        frameBudget!: ?ProtocolFrameBudget = None,
        discardPreparedAfterDispatch!: Bool = false
    ) {
        if (maxFrameBytes < 1024) { throw IllegalArgumentException("invalid DAP frame limit") }
        this.channel = channel; this.eventHandler = eventHandler
        this.reverseHandler = reverseRequestHandler; this.maxFrameBytes = maxFrameBytes
        this.frameBudget = frameBudget; this.discardPreparedAfterDispatch = discardPreparedAfterDispatch
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
        eventHandler!: DapEventHandler = { _: String, _: JsonNode => () },
        reverseRequestHandler!: DapReverseRequestHandler = { command: String, _: JsonNode =>
            DapResult.Err(DapError(DapErrorKind.Protocol, "dap.request_unsupported", "unsupported adapter request: " + command))
        },
        maxFrameBytes!: Int64 = 33554432,
        backend!: ProcessBackend = defaultProcessBackend()
    ): DapResult<DapClient> {
        if (!command.terminateProcessTree) { return DapResult.Err(DapError(DapErrorKind.Transport,
            "dap.channel_tree_required", "protocol client requires process-tree ownership before spawn")) }
        try { DapResult.Ok(DapClient(
            startProcess(command, backend: backend), eventHandler: eventHandler,
            reverseRequestHandler: reverseRequestHandler, maxFrameBytes: maxFrameBytes
        )) } catch (error: ProcessError) {
            DapResult.Err(DapError(DapErrorKind.Transport, "dap.spawn_failed", error.message))
        }
    }

    public func initialize(arguments: JsonNode, timeoutMillis!: Int64 = 30000): DapResult<JsonNode> {
        request("initialize", arguments, timeoutMillis: timeoutMillis)
    }

    // The DAP protocol requires numeric sequence IDs. Reserve a bounded,
    // repeatable per-key sequence locally during pure preparation; no I/O or
    // host admission occurs here. Re-preparing one key cannot change its bytes.
    public func prepareRequest(requestKey: String, command: String, arguments: JsonNode): DapResult<DapPreparedRequest> {
        if (!dapPreparedIdentifier(requestKey) || !dapPreparedIdentifier(command)) {
            return DapResult.Err(DapError(DapErrorKind.Protocol, "dap.prepared_invalid", "invalid prepared request key or command"))
        }
        let frozen = try { stringifyUnifiedJson(arguments) } catch (_: Exception) {
            return DapResult.Err(DapError(DapErrorKind.Json, "dap.prepared_invalid", "prepared arguments cannot be encoded"))
        }
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return DapResult.Err(closedFailure()) }
            if (discardPreparedAfterDispatch && dispatchedPrepared.contains(requestKey)) {
                return DapResult.Err(DapError(DapErrorKind.Correlation, "dap.prepared_reused", "prepared request was already dispatched"))
            }
            match (preparedCalls.get(requestKey)) {
                case Some(prior) =>
                    if (!prior.sameInput(command, frozen)) { return DapResult.Err(DapError(DapErrorKind.Correlation,
                        "dap.prepared_changed", "one prepared request key cannot change its frozen input")) }
                    return DapResult.Ok(prior)
                case None => ()
            }
            if (preparedCalls.size + (if (discardPreparedAfterDispatch) { dispatchedPrepared.size } else { 0 }) >= 4096) { return DapResult.Err(DapError(DapErrorKind.Correlation, "dap.prepared_capacity", "prepared request cache reached its fixed bound")) }
            let prepared = try { DapPreparedRequest(preparedSeal, requestKey, nextSequence, command, frozen) }
                catch (_: Exception) { return DapResult.Err(DapError(DapErrorKind.Protocol, "dap.prepared_invalid", "prepared request exceeds protocol bounds")) }
            if (prepared.retainedBytes > 33554432 - preparedBytes) { return DapResult.Err(DapError(DapErrorKind.Correlation,
                "dap.prepared_capacity", "prepared request byte budget is exhausted; entries cannot be evicted for replay")) }
            nextSequence++; preparedBytes += prepared.retainedBytes
            preparedCalls.add(requestKey, prepared); DapResult.Ok(prepared)
        } finally { stateLock.unlock() }
    }

    // Discarding an unconsumed request retains its used-key tombstone. This is
    // local memory cleanup, not cancellation I/O or permission to retry it.
    public func discardPrepared(request: DapPreparedRequest): Unit {
        stateLock.lock()
        try {
            if (!request.belongsTo(preparedSeal)) { return }
            dispatchedPrepared.add(request.requestKey)
            match (preparedCalls.get(request.requestKey)) {
                case Some(value) => preparedBytes -= value.retainedBytes; let _ = preparedCalls.remove(request.requestKey)
                case None => ()
            }
        } finally { stateLock.unlock() }
    }

    // One exact writer handoff for a finite prepared batch. This supports the
    // DAP launch/configuration exchange without an unprepared secondary write.
    public func dispatchPreparedBatch(requests: Array<DapPreparedRequest>, timeoutMillis!: Int64 = 30000): DapResult<Array<JsonNode>> {
        if (requests.isEmpty() || requests.size > 16 || timeoutMillis < 1 || timeoutMillis > 3600000) {
            return DapResult.Err(DapError(DapErrorKind.Protocol, "dap.batch_invalid", "bounded prepared batch required"))
        }
        let bytes = ArrayList<Byte>(); let keys = HashSet<String>()
        for (request in requests) {
            if (keys.contains(request.requestKey)) { return DapResult.Err(DapError(DapErrorKind.Correlation, "dap.prepared_reused", "duplicate prepared batch key")) }
            keys.add(request.requestKey)
            let frame = request.framedBytes()
            if (frame.size > 8388608 - bytes.size) { return DapResult.Err(DapError(DapErrorKind.Frame, "dap.batch_limit", "prepared batch exceeds its bound")) }
            bytes.add(all: frame)
        }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return DapResult.Err(closedFailure()) }
            for (request in requests) {
                if (!request.belongsTo(preparedSeal)) { return DapResult.Err(DapError(DapErrorKind.Correlation, "dap.prepared_foreign", "prepared request belongs to another client")) }
                if (dispatchedPrepared.contains(request.requestKey)) { return DapResult.Err(DapError(DapErrorKind.Correlation, "dap.prepared_reused", "prepared request already dispatched")) }
            }
            for (request in requests) {
                dispatchedPrepared.add(request.requestKey); pending.add(DapPendingRequest(request.sequence, request.command))
                if (discardPreparedAfterDispatch) {
                    match (preparedCalls.get(request.requestKey)) {
                        case Some(value) => preparedBytes -= value.retainedBytes; let _ = preparedCalls.remove(request.requestKey)
                        case None => ()
                    }
                }
            }
        } finally { stateLock.unlock() }
        match (writeBytes(bytes.toArray())) {
            case DapResult.Err(error) => for (request in requests) { release(request.sequence) }; return DapResult.Err(error)
            case DapResult.Ok(_) => ()
        }
        let results = ArrayList<JsonNode>(); var firstError: ?DapError = None
        for (request in requests) {
            var settled = false
            while (!settled && MonoTime.now() < deadline) {
                match (take(request.sequence)) {
                    case Some(DapResult.Ok(value)) => results.add(value); settled = true
                    case Some(DapResult.Err(error)) => if (firstError.isNone() || error.code != "dap.adapter_error") { firstError = Some(error) }; settled = true
                    case None => sleep(Duration.millisecond)
                }
            }
            if (!settled) {
                for (pendingRequest in requests) { release(pendingRequest.sequence) }
                let error = DapError(DapErrorKind.Deadline, "dap.prepared_deadline", "prepared batch expired after dispatch; remote outcome unknown")
                failAll(error); try { channel.abort() } catch (_: Exception) { () }
                return DapResult.Err(error)
            }
        }
        match (firstError) { case Some(error) => DapResult.Err(error); case None => DapResult.Ok(results.toArray()) }
    }

    public func dispatchPrepared(request: DapPreparedRequest, timeoutMillis!: Int64 = 30000): DapResult<JsonNode> {
        if (timeoutMillis < 1 || timeoutMillis > 3600000) { return DapResult.Err(DapError(DapErrorKind.Deadline,
            "dap.deadline_invalid", "prepared request deadline is outside its fixed bound")) }
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        let item = DapPendingRequest(request.sequence, request.command)
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return DapResult.Err(closedFailure()) }
            if (!request.belongsTo(preparedSeal)) { return DapResult.Err(DapError(DapErrorKind.Correlation, "dap.prepared_foreign", "prepared request belongs to another protocol client")) }
            if (dispatchedPrepared.contains(request.requestKey)) { return DapResult.Err(DapError(DapErrorKind.Correlation, "dap.prepared_reused", "prepared request was already dispatched")) }
            dispatchedPrepared.add(request.requestKey); pending.add(item)
            if (discardPreparedAfterDispatch) {
                // The caller still owns the immutable request until dispatch
                // returns and its consumer finishes; only the private cache
                // reference is removed. The used-key tombstone is never evicted.
                match (preparedCalls.get(request.requestKey)) {
                    case Some(value) => preparedBytes -= value.retainedBytes; let _ = preparedCalls.remove(request.requestKey)
                    case None => ()
                }
            }
        } finally { stateLock.unlock() }
        match (writeBytes(request.framedBytes())) {
            case DapResult.Err(error) => release(item.sequence); return DapResult.Err(error)
            case DapResult.Ok(_) => ()
        }
        while (MonoTime.now() < deadline) {
            match (take(item.sequence)) { case Some(value) => return value; case None => sleep(Duration.millisecond) }
        }
        release(item.sequence)
        let error = DapError(DapErrorKind.Deadline, "dap.prepared_deadline", "prepared request expired after dispatch; its remote outcome is unknown")
        failAll(error); try { channel.abort() } catch (_: Exception) { () }
        DapResult.Err(error)
    }

    public func request(
        command: String,
        arguments: JsonNode,
        timeoutMillis!: Int64 = 30000
    ): DapResult<JsonNode> {
        if (timeoutMillis <= 0) {
            return DapResult.Err(DapError(DapErrorKind.Deadline, "dap.deadline_invalid", "deadline must be positive"))
        }
        let sequence = match (beginRequest(command, arguments)) {
            case DapResult.Ok(value) => value
            case DapResult.Err(error) => return DapResult.Err(error)
        }
        waitResponse(sequence, timeoutMillis: timeoutMillis)
    }

    public func beginRequest(command: String, arguments: JsonNode): DapResult<Int64> {
        let item: DapPendingRequest
        stateLock.lock()
        try {
            if (closed || closeError.isSome()) { return DapResult.Err(closedFailure()) }
            item = DapPendingRequest(nextSequence, command); nextSequence++
            pending.add(item)
        } finally { stateLock.unlock() }
        match (write(jsonObject([
            JsonObjectEntry("seq", jsonNumber(item.sequence.toString())),
            JsonObjectEntry("type", jsonString("request")),
            JsonObjectEntry("command", jsonString(command)),
            JsonObjectEntry("arguments", arguments)
        ]))) {
            case DapResult.Ok(_) => DapResult.Ok(item.sequence)
            case DapResult.Err(error) => release(item.sequence); DapResult.Err(error)
        }
    }

    public func waitResponse(requestSequence: Int64, timeoutMillis!: Int64 = 30000): DapResult<JsonNode> {
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
        let arguments = jsonObject([
            JsonObjectEntry("requestId", jsonNumber(requestSequence.toString()))
        ])
        let sequence: Int64
        stateLock.lock(); try { sequence = nextSequence; nextSequence++ } finally { stateLock.unlock() }
        // DAP cancel is a control request. Its response is intentionally not
        // correlated with an application waiter, so it must not occupy the
        // pending table.
        write(jsonObject([
            JsonObjectEntry("seq", jsonNumber(sequence.toString())),
            JsonObjectEntry("type", jsonString("request")),
            JsonObjectEntry("command", jsonString("cancel")),
            JsonObjectEntry("arguments", arguments)
        ]))
    }

    public func pendingCount(): Int64 { stateLock.lock(); try { pending.size } finally { stateLock.unlock() } }
    public func isClosed(): Bool { stateLock.lock(); try { closed } finally { stateLock.unlock() } }
    public func isAlive(): Bool {
        stateLock.lock(); try { !closed && closeError.isNone() } finally { stateLock.unlock() }
    }
    public func stderrSnapshot(): String { try { String.fromUtf8(stderr.snapshot()) } catch (_: Exception) { "" } }

    public func disconnect(arguments!: JsonNode = jsonObject([]), timeoutMillis!: Int64 = 3000): DapResult<Unit> {
        if (isClosed()) { return DapResult.Ok(()) }
        match (request("disconnect", arguments, timeoutMillis: timeoutMillis)) {
            case DapResult.Ok(_) => close()
            case DapResult.Err(error) => let _ = close(); DapResult.Err(error)
        }
    }

    public func terminate(arguments!: JsonNode = jsonObject([]), timeoutMillis!: Int64 = 3000): DapResult<Unit> {
        if (isClosed()) { return DapResult.Ok(()) }
        match (request("terminate", arguments, timeoutMillis: timeoutMillis)) {
            case DapResult.Ok(_) => DapResult.Ok(())
            case DapResult.Err(error) => DapResult.Err(error)
        }
    }

    public func close(): DapResult<Unit> {
        closeLock.lock()
        try {
            if (cleanupDone) { return DapResult.Ok(()) }
            stateLock.lock()
            try {
                closed = true
                closeError = Some(DapError(DapErrorKind.Cancelled, "dap.client_closed", "protocol client closed"))
                for (item in pending where item.result.isNone() && item.error.isNone()) { item.error = closeError }
            } finally { stateLock.unlock() }
            try { channel.abort(); channel.stop(0) } catch (_: Exception) {
                return DapResult.Err(DapError(DapErrorKind.Transport, "dap.cleanup_pending", "protocol channel cleanup is still owned"))
            }
            match (reader) { case Some(task) => try { task.get() } catch (_: Exception) {}; case None => () }
            match (stderrReader) { case Some(task) => try { task.get() } catch (_: Exception) {}; case None => () }
            try { channel.close() } catch (_: Exception) {
                return DapResult.Err(DapError(DapErrorKind.Transport, "dap.cleanup_pending", "protocol channel cleanup is still owned"))
            }
            stateLock.lock()
            try {
                for (item in pending) { match (item.frame) { case Some(value) => consumedFrames.add(value); case None => () } }
                pending.clear(); preparedCalls.clear(); preparedBytes = 0
            } finally { stateLock.unlock() }
            try { releaseConsumedResponses() } catch (_: Exception) {
                return DapResult.Err(DapError(DapErrorKind.Transport, "dap.cleanup_pending", "protocol frame cleanup is still owned"))
            }
            cleanupDone = true; DapResult.Ok(())
        } finally { closeLock.unlock() }
    }

    // Resource-only acknowledgment. Integrating callers coordinate all decoded
    // consumers and retain callback copies separately before releasing a batch.
    public func releaseConsumedResponses(): Unit {
        stateLock.lock()
        let old = try { let result = consumedFrames.toArray(); consumedFrames.clear(); result } finally { stateLock.unlock() }
        let retained = ArrayList<OwnedProtocolFrame>()
        for (frame in old) { try { frame.close() } catch (_: Exception) { retained.add(frame) } }
        if (!retained.isEmpty()) {
            stateLock.lock(); try { for (frame in retained) { consumedFrames.add(frame) } } finally { stateLock.unlock() }
            throw ProcessError(ProcessErrorKind.Io, "protocol consumer cleanup is still owned")
        }
    }
    private func readLoop(stream: InputStream): Unit {
        while (true) {
            if (isClosed()) { return }
            var owned: ?OwnedProtocolFrame = None; var retained = false
            try {
                let frame = try { readContentLengthFrame(stream, maxBodyBytes: maxFrameBytes, budget: frameBudget) }
                    catch (error: ProcessError) {
                        failAll(DapError(if (let ProcessErrorKind.Io <- error.kind) { DapErrorKind.Transport } else { DapErrorKind.Frame },
                            if (let ProcessErrorKind.Io <- error.kind) { "dap.transport_closed" } else { "dap.frame_invalid" }, "protocol frame cannot be received")); return
                    } catch (_: Exception) { failAll(DapError(DapErrorKind.Frame, "dap.frame_budget_exceeded", "protocol frame reservation rejected")); return }
                owned = Some(frame)
                try { frame.beforeDecode() } catch (_: Exception) {
                    failAll(DapError(DapErrorKind.Frame, "dap.frame_budget_exceeded", "protocol frame decode reservation rejected")); return
                }
                match (decodeDapBody(frame.bytes, maxFrameBytes, 128)) {
                    case DapResult.Ok(message) => retained = dispatch(message, frame)
                    case DapResult.Err(error) => failAll(error); return
                }
            } catch (_: Exception) { failAll(DapError(DapErrorKind.Protocol, "dap.callback_failed", "protocol callback failed")); return }
            finally { if (!retained) { match (owned) { case Some(value) => value.close(); case None => () } } }
        }
    }

    private func dispatch(message: JsonNode, frame: OwnedProtocolFrame): Bool {
        match (textField(message, "type")) {
            case "event" => eventHandler(textField(message, "event"), objectField(message, "body")); false
            case "request" => handleReverseRequest(message); false
            case "response" =>
                let requestSequence = integerField(message, "request_seq", -1)
                if (requestSequence < 1) { failAll(DapError(DapErrorKind.Protocol, "dap.response_sequence_invalid", "response request_seq is invalid")); return false }
                if (!boolField(message, "success", false)) {
                    settleError(requestSequence, DapError(DapErrorKind.Protocol, "dap.adapter_error",
                        if (textField(message, "message") == "") { "DAP request failed" } else { textField(message, "message") }), frame)
                } else { settleResult(requestSequence, objectField(message, "body"), frame) }
            case _ => failAll(DapError(DapErrorKind.Protocol, "dap.message_type_invalid", "unsupported DAP message type")); false
        }
    }

    private func handleReverseRequest(message: JsonNode): Unit {
        let requestSequence = integerField(message, "seq", 0)
        let command = textField(message, "command")
        let result = reverseHandler(command, objectField(message, "arguments"))
        let responseSequence: Int64
        stateLock.lock(); try { responseSequence = nextSequence; nextSequence++ } finally { stateLock.unlock() }
        let fields = ArrayList<JsonObjectEntry>()
        fields.add(JsonObjectEntry("seq", jsonNumber(responseSequence.toString())))
        fields.add(JsonObjectEntry("type", jsonString("response")))
        fields.add(JsonObjectEntry("request_seq", jsonNumber(requestSequence.toString())))
        fields.add(JsonObjectEntry("command", jsonString(command)))
        match (result) {
            case DapResult.Ok(body) => fields.add(JsonObjectEntry("success", jsonBool(true))); fields.add(JsonObjectEntry("body", body))
            case DapResult.Err(error) => fields.add(JsonObjectEntry("success", jsonBool(false))); fields.add(JsonObjectEntry("message", jsonString(error.message)))
        }
        let _ = write(jsonObject(fields.toArray()))
    }

    private func write(value: JsonNode): DapResult<Unit> { writeBytes(encodeDapMessage(value)) }
    private func writeBytes(bytes: Array<Byte>): DapResult<Unit> {
        writeLock.lock(); try {
            try { channel.write(bytes); channel.flush(); DapResult.Ok(()) }
            catch (_: Exception) { DapResult.Err(DapError(DapErrorKind.Transport, "dap.write_failed", "protocol channel write failed")) }
        } finally { writeLock.unlock() }
    }
    private func settleResult(sequence: Int64, value: JsonNode, frame: OwnedProtocolFrame): Bool { stateLock.lock(); try { for (item in pending where item.sequence == sequence && item.result.isNone() && item.error.isNone()) { if (frameBudget.isSome()) { item.frame = Some(frame) }; item.result = Some(value); return frameBudget.isSome() }; false } finally { stateLock.unlock() } }
    private func settleError(sequence: Int64, error: DapError, frame: OwnedProtocolFrame): Bool { stateLock.lock(); try { for (item in pending where item.sequence == sequence && item.result.isNone() && item.error.isNone()) { if (frameBudget.isSome()) { item.frame = Some(frame) }; item.error = Some(error); return frameBudget.isSome() }; false } finally { stateLock.unlock() } }
    private func take(sequence: Int64): ?DapResult<JsonNode> {
        stateLock.lock(); try {
            for (index in 0..pending.size where pending[index].sequence == sequence) {
                let item = pending[index]
                match (item.result) { case Some(value) => match (item.frame) { case Some(frame) => consumedFrames.add(frame); case None => () }; pending.remove(at: index); return Some(DapResult.Ok(value)); case None => () }
                match (item.error) { case Some(error) => match (item.frame) { case Some(frame) => consumedFrames.add(frame); case None => () }; pending.remove(at: index); return Some(DapResult.Err(error)); case None => return None }
            }
            match (closeError) {
                case Some(error) => Some(DapResult.Err(error))
                case None => Some(DapResult.Err(DapError(DapErrorKind.Correlation, "dap.request_unknown", "request is no longer pending")))
            }
        } finally { stateLock.unlock() }
    }
    private func release(sequence: Int64): Unit { stateLock.lock(); try { for (index in 0..pending.size where pending[index].sequence == sequence) { match (pending[index].frame) { case Some(frame) => consumedFrames.add(frame); case None => () }; pending.remove(at: index); return } } finally { stateLock.unlock() } }
    private func closedError(): DapError { closeError ?? DapError(DapErrorKind.Transport, "dap.client_closed", "DAP client is closed") }
    private func failAll(error: DapError): Unit { stateLock.lock(); try { if (!closed) { closeError = Some(error) }; for (item in pending where item.result.isNone() && item.error.isNone()) { item.error = Some(error) } } finally { stateLock.unlock() } }
    private func closedFailure(): DapError { match (closeError) { case Some(error) => error; case None => DapError(DapErrorKind.Transport, "dap.client_closed", "DAP client is closed") } }
}

func textField(value: JsonNode, name: String): String { match (value.field(name)) { case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { "" }; case None => "" } }
func integerField(value: JsonNode, name: String, fallback: Int64): Int64 { match (value.field(name)) { case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Number) { try { Int64.parse(item.asNumberText()) } catch (_: Exception) { fallback } } else { fallback }; case None => fallback } }
func boolField(value: JsonNode, name: String, fallback: Bool): Bool { match (value.field(name)) { case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Boolean) { item.asBool() } else { fallback }; case None => fallback } }
func objectField(value: JsonNode, name: String): JsonNode { match (value.field(name)) { case Some(item) => item; case None => jsonObject([]) } }
