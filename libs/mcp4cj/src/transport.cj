package mcp4cj

import yjson.*
import yjson_support.*
import jsonrpc4cj.*
import process4cj.*
import std.collection.*
import std.io.*
import std.sync.*
import std.time.*

public enum McpResult<T> {
    Ok(T) | Err(McpError)

    public func isOk(): Bool {
        match (this) { case Ok(_) => true; case Err(_) => false }
    }
}

public enum McpTransportKind <: Equatable<McpTransportKind> {
    Memory | Stdio | StreamableHttp

    public operator func ==(other: McpTransportKind): Bool {
        match (this) {
            case Memory => if (let Memory <- other) { true } else { false }
            case Stdio => if (let Stdio <- other) { true } else { false }
            case StreamableHttp => if (let StreamableHttp <- other) { true } else { false }
        }
    }
    public operator func !=(other: McpTransportKind): Bool { !(this == other) }
}

public enum McpLifecycleState <: Equatable<McpLifecycleState> {
    Created | Starting | Ready | Failed | Stopping | Stopped

    public operator func ==(other: McpLifecycleState): Bool {
        match (this) {
            case Created => if (let Created <- other) { true } else { false }
            case Starting => if (let Starting <- other) { true } else { false }
            case Ready => if (let Ready <- other) { true } else { false }
            case Failed => if (let Failed <- other) { true } else { false }
            case Stopping => if (let Stopping <- other) { true } else { false }
            case Stopped => if (let Stopped <- other) { true } else { false }
        }
    }
    public operator func !=(other: McpLifecycleState): Bool { !(this == other) }
}

public class McpLifecycle {
    private var current = McpLifecycleState.Created
    private let lock = Mutex()
    public init() {}
    public func state(): McpLifecycleState {
        lock.lock(); try { current } finally { lock.unlock() }
    }
    public func transition(next: McpLifecycleState): McpResult<Unit> {
        lock.lock()
        try {
            if (!validTransition(current, next)) {
                return McpResult.Err(McpError(
                    McpErrorKind.Lifecycle,
                    "mcp.lifecycle_transition_invalid",
                    "invalid MCP lifecycle transition from ${lifecycleName(current)} to ${lifecycleName(next)}"
                ))
            }
            current = next
            McpResult.Ok(())
        } finally { lock.unlock() }
    }
}

public class McpFramingConfig {
    public let maxFrameBytes: Int64
    public let requestTimeoutMillis: Int64
    public let gracefulShutdownMillis: Int64
    public let maxConcurrentRequests: Int64
    public init(
        maxFrameBytes!: Int64 = 8388608,
        requestTimeoutMillis!: Int64 = 30000,
        gracefulShutdownMillis!: Int64 = 3000,
        maxConcurrentRequests!: Int64 = 16
    ) {
        if (maxFrameBytes < 1024 || requestTimeoutMillis <= 0 || gracefulShutdownMillis < 0 ||
            maxConcurrentRequests <= 0) {
            throw IllegalArgumentException("invalid MCP framing limits")
        }
        this.maxFrameBytes = maxFrameBytes
        this.requestTimeoutMillis = requestTimeoutMillis
        this.gracefulShutdownMillis = gracefulShutdownMillis
        this.maxConcurrentRequests = maxConcurrentRequests
    }
}

public class McpStdioConfig {
    public let command: String
    public let arguments: Array<String>
    public let cwd: String
    public let environment: HashMap<String, String>
    public let framing: McpFramingConfig
    public init(
        command: String,
        arguments!: Array<String> = [],
        cwd!: String = "",
        environment!: HashMap<String, String> = HashMap<String, String>(),
        framing!: McpFramingConfig = McpFramingConfig()
    ) {
        if (command.trimAscii() == "" || command.indexOf("\n").isSome()) {
            throw IllegalArgumentException("MCP stdio command must be one executable")
        }
        for (argument in arguments where argument.indexOf("\u{0}").isSome()) {
            throw IllegalArgumentException("MCP stdio argument contains NUL")
        }
        this.command = command
        this.arguments = arguments
        this.cwd = cwd
        this.environment = environment
        this.framing = framing
    }
}

public interface McpTransport {
    func kind(): McpTransportKind
    func state(): McpLifecycleState
    func request(request: JsonRpcRequest): McpResult<JsonRpcResponse>
    func openSubscription(request: JsonRpcRequest): McpResult<McpSubscriptionHandle>
    func notify(notification: JsonRpcNotification): McpResult<Unit>
    func cancel(
        requestId: JsonRpcId,
        reason: String,
        meta: McpRequestMeta
    ): McpResult<Unit>
    func registerTools(tools: Array<McpTool>): McpResult<Unit>
    func close(): McpResult<Unit>
}

class McpStdioPendingResponse {
    let id: JsonRpcId
    var response: ?JsonRpcResponse = None
    var error: ?McpError = None
    init(id: JsonRpcId) { this.id = id }
}

class StdioMcpSubscriptionHandle <: McpSubscriptionHandle {
    private let id: JsonRpcId
    private let cancelAction: (JsonRpcId) -> McpResult<Unit>
    private let lock = Mutex()
    private let queued = ArrayList<JsonRpcNotification>()
    private var accepted: ?McpSubscriptionFilter = None
    private var stopped = false
    private var failure: ?McpError = None
    init(id: JsonRpcId, cancelAction: (JsonRpcId) -> McpResult<Unit>) {
        this.id = id; this.cancelAction = cancelAction
    }
    public func subscriptionId(): JsonRpcId { id }
    public func acknowledged(): McpSubscriptionFilter {
        while (true) {
            lock.lock(); try {
                match (accepted) { case Some(value) => return value; case None => () }
                match (failure) { case Some(error) => throw error; case None => () }
                if (stopped) { throw IllegalStateException("MCP subscription closed before acknowledgement") }
            } finally { lock.unlock() }
            sleep(Duration.millisecond * 5)
        }
        McpSubscriptionFilter()
    }
    public func next(): McpResult<?JsonRpcNotification> {
        while (true) {
            lock.lock(); try {
                if (!queued.isEmpty()) {
                    let value = queued[0]; queued.remove(at: 0); return McpResult.Ok(Some(value))
                }
                match (failure) { case Some(error) => return McpResult.Err(error); case None => () }
                if (stopped) { return McpResult.Ok(None) }
            } finally { lock.unlock() }
            sleep(Duration.millisecond * 5)
        }
        McpResult.Ok(None)
    }
    public func close(): McpResult<Unit> {
        lock.lock(); try { if (stopped) { return McpResult.Ok(()) }; stopped = true } finally { lock.unlock() }
        cancelAction(id)
    }
    func acknowledge(value: McpSubscriptionFilter): Unit {
        lock.lock(); try { if (!stopped) { accepted = Some(value) } } finally { lock.unlock() }
    }
    func push(value: JsonRpcNotification): Unit {
        lock.lock(); try { if (!stopped) { queued.add(value) } } finally { lock.unlock() }
    }
    func complete(): Unit { lock.lock(); try { stopped = true } finally { lock.unlock() } }
    func fail(error: McpError): Unit { lock.lock(); try { failure = Some(error); stopped = true } finally { lock.unlock() } }
    func ready(): Bool { lock.lock(); try { accepted.isSome() || stopped } finally { lock.unlock() } }
    func failureSnapshot(): ?McpError { lock.lock(); try { failure } finally { lock.unlock() } }
    func acknowledgedSnapshot(): Bool { lock.lock(); try { accepted.isSome() } finally { lock.unlock() } }
}

public class StdioMcpTransport <: McpTransport {
    private let config: McpStdioConfig
    private let process: ManagedProcess
    private let lifecycle = McpLifecycle()
    private let requestLock = Mutex()
    private let writerLock = Mutex()
    private let pendingLock = Mutex()
    private let pending = ArrayList<McpStdioPendingResponse>()
    private let subscriptions = ArrayList<StdioMcpSubscriptionHandle>()
    private let stderrBytes = BoundedByteBuffer(65536)
    private let stderrDrain: Future<Unit>
    private var stdoutDrain: ?Future<Unit> = None

    init(config: McpStdioConfig, process: ManagedProcess) {
        this.config = config
        this.process = process
        let _ = lifecycle.transition(McpLifecycleState.Starting)
        let _ = lifecycle.transition(McpLifecycleState.Ready)
        let stderr = process.stderr
        let captured = stderrBytes
        stderrDrain = spawn {
            let buffer = Array<Byte>(4096, repeat: 0)
            while (true) {
                let count = try { stderr.read(buffer) } catch (_: Exception) { return }
                if (count <= 0) { return }
                let _ = captured.append(buffer, count: count)
            }
        }
        stdoutDrain = Some(spawn { readPump() })
    }

    public func kind(): McpTransportKind { McpTransportKind.Stdio }
    public func state(): McpLifecycleState { lifecycle.state() }

    public func request(request: JsonRpcRequest): McpResult<JsonRpcResponse> {
        requestLock.lock()
        try {
            if (state() != McpLifecycleState.Ready) {
                return mcpFailure<JsonRpcResponse>(McpErrorKind.Transport, "mcp.stdio_not_ready", "MCP stdio transport is not ready")
            }
            let waiting = McpStdioPendingResponse(request.id)
            pendingLock.lock(); try { pending.add(waiting) } finally { pendingLock.unlock() }
            match (write(JsonRpcEnvelope.Request(request))) {
                case McpResult.Ok(_) => ()
                case McpResult.Err(error) => removePending(waiting); return McpResult.Err(error)
            }
            let deadline = MonoTime.now() + Duration.millisecond * config.framing.requestTimeoutMillis
            while (waiting.response.isNone() && waiting.error.isNone() && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 5)
            }
            removePending(waiting)
            match (waiting.response) {
                case Some(value) => McpResult.Ok(value)
                case None => match (waiting.error) {
                    case Some(error) => McpResult.Err(error)
                    case None =>
                    let error = McpError(
                        McpErrorKind.Deadline,
                        "mcp.stdio_timeout",
                        "MCP stdio request timed out",
                        retryable: false
                    )
                    let _ = process.terminate(force: true)
                    fail(error)
                }
            }
        } finally { requestLock.unlock() }
    }

    public func openSubscription(request: JsonRpcRequest): McpResult<McpSubscriptionHandle> {
        if (state() != McpLifecycleState.Ready || request.method != MCP_METHOD_SUBSCRIPTIONS_LISTEN) {
            return mcpFailure<McpSubscriptionHandle>(McpErrorKind.Protocol, "mcp.stdio_subscription_invalid", "invalid MCP stdio subscription request")
        }
        let metadata = mcpObject(request.params, "_meta")
        let handle = StdioMcpSubscriptionHandle(
            request.id,
            { id => closeSubscription(id, metadata) }
        )
        pendingLock.lock(); try { subscriptions.add(handle) } finally { pendingLock.unlock() }
        match (write(JsonRpcEnvelope.Request(request))) {
            case McpResult.Ok(_) => ()
            case McpResult.Err(error) => removeSubscription(handle); return McpResult.Err(error)
        }
        let deadline = MonoTime.now() + Duration.millisecond * config.framing.requestTimeoutMillis
        while (!handle.ready() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        if (!handle.ready()) {
            let _ = handle.close(); removeSubscription(handle)
            return mcpFailure<McpSubscriptionHandle>(McpErrorKind.Deadline, "mcp.stdio_subscription_ack_timeout", "MCP subscription acknowledgement timed out")
        }
        match (handle.failureSnapshot()) {
            case Some(error) => removeSubscription(handle); return McpResult.Err(error)
            case None => ()
        }
        if (!handle.acknowledgedSnapshot()) {
            removeSubscription(handle)
            return mcpFailure<McpSubscriptionHandle>(
                McpErrorKind.Protocol, "mcp.stdio_subscription_rejected",
                "MCP subscription closed before acknowledgement"
            )
        }
        McpResult.Ok(handle)
    }

    public func notify(notification: JsonRpcNotification): McpResult<Unit> {
        if (state() != McpLifecycleState.Ready) {
            return mcpFailure<Unit>(McpErrorKind.Transport, "mcp.stdio_not_ready", "MCP stdio transport is not ready")
        }
        write(JsonRpcEnvelope.Notification(notification))
    }

    public func cancel(
        requestId: JsonRpcId,
        reason: String,
        meta: McpRequestMeta
    ): McpResult<Unit> {
        notify(mcpCancellationNotification(requestId, reason, meta: meta))
    }
    public func registerTools(tools: Array<McpTool>): McpResult<Unit> {
        let _ = tools; McpResult.Ok(())
    }

    public func stderrSnapshot(): String {
        try { String.fromUtf8(stderrBytes.snapshot()) } catch (_: Exception) { "" }
    }

    public func close(): McpResult<Unit> {
        if (state() == McpLifecycleState.Stopped) { return McpResult.Ok(()) }
        if (state() != McpLifecycleState.Stopping) { let _ = lifecycle.transition(McpLifecycleState.Stopping) }
        let _ = process.terminate()
        let deadline = MonoTime.now() + Duration.millisecond * config.framing.gracefulShutdownMillis
        while (process.tryExit().isNone() && MonoTime.now() < deadline) {
            sleep(Duration.millisecond * 5)
        }
        if (process.tryExit().isNone()) { let _ = process.terminate(force: true) }
        let _ = process.wait()
        match (stdoutDrain) { case Some(value) => try { value.get() } catch (_: Exception) {}; case None => () }
        try { stderrDrain.get() } catch (_: Exception) {}
        let _ = process.close()
        let _ = lifecycle.transition(McpLifecycleState.Stopped)
        McpResult.Ok(())
    }

    private func write(envelope: JsonRpcEnvelope): McpResult<Unit> {
        writerLock.lock()
        try {
            let frame = encodeJsonRpc(envelope) + "\n"
            if (unsafe { frame.rawData().size } > config.framing.maxFrameBytes + 1) {
                return mcpFailure<Unit>(McpErrorKind.Protocol, "mcp.frame_too_large", "MCP stdio frame exceeds configured limit")
            }
            try {
                process.writeStdin(frame.toArray())
                process.flushInput()
                McpResult.Ok(())
            } catch (error: ProcessError) {
                fail(McpError(McpErrorKind.Transport, "mcp.stdio_write_failed", error.message))
            }
        } finally { writerLock.unlock() }
    }

    private func readPump(): Unit {
        while (state() == McpLifecycleState.Ready) {
            let line = try {
                match (readLineBounded(process.stdout, config.framing.maxFrameBytes, allowPartialAtEof: true)) {
                    case Some(value) => value
                    case None => failAll(McpError(McpErrorKind.Transport, "mcp.stdio_eof", "MCP stdio server closed")); return
                }
            } catch (error: Exception) {
                failAll(McpError(McpErrorKind.Transport, "mcp.stdio_read_failed", error.message)); return
            }
            let envelope = match (decodeJsonRpc(line, maxBytes: config.framing.maxFrameBytes)) {
                case JsonRpcResult.Ok(value) => value
                case JsonRpcResult.Err(error) => failAll(McpError(McpErrorKind.Protocol, error.code, error.message)); return
            }
            match (envelope) {
                case JsonRpcEnvelope.Response(response) => routeResponse(response)
                case JsonRpcEnvelope.Notification(notification) => routeNotification(notification)
                case JsonRpcEnvelope.Request(_) => failAll(McpError(McpErrorKind.Protocol, "mcp.stdio_server_request_unsupported", "MCP stdio server sent an unsupported reverse request")); return
            }
        }
    }

    private func routeResponse(response: JsonRpcResponse): Unit {
        pendingLock.lock(); try {
            for (item in pending where sameJsonRpcId(item.id, response.id)) { item.response = Some(response); return }
            for (item in subscriptions where sameJsonRpcId(item.subscriptionId(), response.id)) {
                match (response.payload) {
                    case JsonRpcResponsePayload.Success(_) => item.complete()
                    case JsonRpcResponsePayload.Failure(error) => match (remoteMcpError<Unit>(error)) {
                        case McpResult.Err(value) => item.fail(value)
                        case McpResult.Ok(_) => item.fail(McpError(
                            McpErrorKind.Protocol, "mcp.stdio_subscription_rejection_invalid",
                            "subscription rejection did not contain an error"
                        ))
                    }
                }
                return
            }
        } finally { pendingLock.unlock() }
    }

    private func routeNotification(notification: JsonRpcNotification): Unit {
        let id = subscriptionNotificationId(notification)
        match (id) {
            case Some(value) => pendingLock.lock(); try {
                for (item in subscriptions where sameJsonRpcId(item.subscriptionId(), value)) {
                    if (notification.method == MCP_NOTIFICATION_SUBSCRIPTION_ACKNOWLEDGED) {
                        match (decodeMcpSubscriptionFilter(notification.params)) {
                            case McpResult.Ok(filter) => item.acknowledge(filter)
                            case McpResult.Err(error) => item.fail(error)
                        }
                    } else { item.push(notification) }
                    return
                }
            } finally { pendingLock.unlock() }
            case None => ()
        }
    }

    private func failAll(error: McpError): Unit {
        pendingLock.lock(); try {
            for (item in pending) { item.error = Some(error) }
            for (item in subscriptions) { item.fail(error) }
        } finally { pendingLock.unlock() }
        if (state() == McpLifecycleState.Ready) { let _ = lifecycle.transition(McpLifecycleState.Failed) }
    }
    private func removePending(item: McpStdioPendingResponse): Unit {
        pendingLock.lock(); try { for (index in 0..pending.size where sameJsonRpcId(pending[index].id, item.id)) { pending.remove(at: index); return } } finally { pendingLock.unlock() }
    }
    private func removeSubscription(item: StdioMcpSubscriptionHandle): Unit {
        pendingLock.lock(); try { for (index in 0..subscriptions.size where sameJsonRpcId(subscriptions[index].subscriptionId(), item.subscriptionId())) { subscriptions.remove(at: index); return } } finally { pendingLock.unlock() }
    }
    private func closeSubscription(id: JsonRpcId, metadata: JsonNode): McpResult<Unit> {
        let result = notify(JsonRpcNotification(MCP_METHOD_CANCELLED, params: jsonObject([
            JsonObjectEntry("requestId", requestIdValue(id)),
            JsonObjectEntry("reason", jsonString("subscription closed by caller")),
            JsonObjectEntry("_meta", metadata)
        ])))
        pendingLock.lock(); try {
            for (index in 0..subscriptions.size where sameJsonRpcId(subscriptions[index].subscriptionId(), id)) {
                subscriptions.remove(at: index); break
            }
        } finally { pendingLock.unlock() }
        result
    }

    private func fail<T>(error: McpError): McpResult<T> {
        if (state() == McpLifecycleState.Ready) { let _ = lifecycle.transition(McpLifecycleState.Failed) }
        let _ = process.terminate(force: true)
        McpResult.Err(error)
    }
}

public func openStdioMcpTransport(config: McpStdioConfig): McpResult<StdioMcpTransport> {
    try {
        McpResult.Ok(StdioMcpTransport(config, startProcess(ProcessCommand(
            config.command,
            arguments: config.arguments,
            workingDirectory: config.cwd,
            environment: config.environment
        ))))
    } catch (error: ProcessError) {
        mcpFailure<StdioMcpTransport>(McpErrorKind.Transport, "mcp.stdio_start_failed", error.message)
    }
}

// Generic console server for the newline-delimited MCP stdio transport.
// The supplied McpServer dispatches only through its generic host callback.
public class StdioMcpServer {
    private let server: McpServer
    private let framing: McpFramingConfig
    private let lifecycle = McpLifecycle()
    private let writerLock = Mutex()
    private let activeLock = Mutex()
    private let activeRequests = ArrayList<JsonRpcId>()
    private let activeSubscriptions = ArrayList<McpServerActiveSubscription>()
    private var output: ?OutputStream = None

    public init(server: McpServer, framing!: McpFramingConfig = McpFramingConfig()) {
        this.server = server; this.framing = framing
    }
    public func state(): McpLifecycleState { lifecycle.state() }

    public func serve(input: InputStream, output: OutputStream): McpResult<Unit> {
        this.output = Some(output)
        let _ = lifecycle.transition(McpLifecycleState.Starting)
        let _ = lifecycle.transition(McpLifecycleState.Ready)
        while (state() == McpLifecycleState.Ready) {
            let line = try {
                match (readLineBounded(input, framing.maxFrameBytes, allowPartialAtEof: true)) {
                    case Some(value) => value
                    case None => break
                }
            } catch (error: ProcessError) {
                return mcpFailure<Unit>(
                    if (let ProcessErrorKind.Io <- error.kind) { McpErrorKind.Transport } else { McpErrorKind.Protocol },
                    "mcp.stdio_read_failed",
                    error.message
                )
            }
            if (utf8ByteSize(line) > framing.maxFrameBytes) {
                writeConsole(JsonRpcResponse(jsonRpcNullId(), JsonRpcResponsePayload.Failure(JsonRpcError(
                    JSON_RPC_INVALID_REQUEST, "MCP stdio frame exceeds the configured byte limit"
                )))); continue
            }
            let envelope = match (decodeJsonRpc(line, maxBytes: framing.maxFrameBytes)) {
                case JsonRpcResult.Ok(value) => value
                case JsonRpcResult.Err(error) =>
                    writeConsole(JsonRpcResponse(jsonRpcNullId(), JsonRpcResponsePayload.Failure(JsonRpcError(error.rpcCode, error.message))))
                    continue
            }
            match (envelope) {
                case JsonRpcEnvelope.Request(request) => dispatchRequest(request)
                case JsonRpcEnvelope.Notification(notification) =>
                    if (notification.method == MCP_METHOD_CANCELLED) { closeServerSubscription(notification) }
                    let _ = server.handleNotification(notification)
                case JsonRpcEnvelope.Response(_) => ()
            }
        }
        let _ = lifecycle.transition(McpLifecycleState.Stopping)
        match (drainActiveRequests()) {
            case McpResult.Ok(_) => lifecycle.transition(McpLifecycleState.Stopped)
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    public func close(): McpResult<Unit> {
        let current = state()
        if (current == McpLifecycleState.Stopped) { return McpResult.Ok(()) }
        if (current == McpLifecycleState.Created) { let _ = lifecycle.transition(McpLifecycleState.Stopped); let _ = server.close(); return McpResult.Ok(()) }
        if (current != McpLifecycleState.Stopping) { let _ = lifecycle.transition(McpLifecycleState.Stopping) }
        match (drainActiveRequests()) {
            case McpResult.Ok(_) => let _ = server.close(); let _ = lifecycle.transition(McpLifecycleState.Stopped); McpResult.Ok(())
            case McpResult.Err(error) => McpResult.Err(error)
        }
    }

    private func dispatchRequest(request: JsonRpcRequest): Unit {
        if (!reserveActive(request.id)) {
            writeConsole(mcpFailureResponse(request.id, JSON_RPC_INTERNAL_ERROR, "MCP stdio server is at its concurrent request limit", data: jsonObject([
                JsonObjectEntry("code", jsonString("mcp.stdio_server_busy")),
                JsonObjectEntry("max_concurrent_requests", jsonNumber(framing.maxConcurrentRequests.toString()))
            ]))); return
        }
        if (request.method == MCP_METHOD_SUBSCRIPTIONS_LISTEN) {
            let _ = spawn { serveSubscription(request) }
        } else {
            let _ = spawn {
                try {
                    writeConsole(server.handleRequest(
                        request,
                        notificationSink: { notification =>
                            writeConsoleEnvelope(JsonRpcEnvelope.Notification(notification))
                        }
                    ))
                } finally { removeActive(request.id) }
            }
        }
    }
    private func writeConsole(response: JsonRpcResponse): Unit {
        writeConsoleEnvelope(JsonRpcEnvelope.Response(response))
    }
    private func writeConsoleEnvelope(envelope: JsonRpcEnvelope): Unit {
        writerLock.lock(); try {
            match (output) {
                case Some(stream) => stream.write((encodeJsonRpc(envelope) + "\n").toArray()); stream.flush()
                case None => ()
            }
        } finally { writerLock.unlock() }
    }
    private func serveSubscription(request: JsonRpcRequest): Unit {
        let source = match (server.openSubscription(request)) {
            case McpResult.Ok(value) => value
            case McpResult.Err(error) =>
                writeConsole(mcpFailureResponse(request.id, JSON_RPC_INVALID_PARAMS, error.message))
                removeActive(request.id); return
        }
        let active = McpServerActiveSubscription(request.id, source)
        activeLock.lock(); try { activeSubscriptions.add(active) } finally { activeLock.unlock() }
        let acknowledgement = tagMcpSubscriptionNotification(JsonRpcNotification(
            MCP_NOTIFICATION_SUBSCRIPTION_ACKNOWLEDGED,
            params: source.acknowledged().toValue()
        ), request.id)
        writeConsoleEnvelope(JsonRpcEnvelope.Notification(acknowledgement))
        try {
            while (!active.closed) {
                match (source.next()) {
                    case McpResult.Ok(Some(notification)) => writeConsoleEnvelope(JsonRpcEnvelope.Notification(
                        tagMcpSubscriptionNotification(notification, request.id)
                    ))
                    case McpResult.Ok(None) =>
                        writeConsole(mcpSuccessResponse(request.id, jsonObject([]), None)); return
                    case McpResult.Err(error) =>
                        writeConsole(mcpHostFailure(request.id, error)); return
                }
            }
        } finally {
            let _ = source.close(); removeServerSubscription(active); removeActive(request.id)
        }
    }
    private func closeServerSubscription(notification: JsonRpcNotification): Unit {
        let id = match (notification.params.field("requestId")) {
            case Some(value) => match (decodeMcpRequestId(value)) {
                case McpResult.Ok(found) => found
                case McpResult.Err(_) => return
            }
            case None => return
        }
        activeLock.lock(); try {
            for (item in activeSubscriptions where sameJsonRpcId(item.id, id)) {
                item.closed = true; let _ = item.source.close(); return
            }
        } finally { activeLock.unlock() }
    }
    private func removeServerSubscription(item: McpServerActiveSubscription): Unit {
        activeLock.lock(); try { for (index in 0..activeSubscriptions.size where sameJsonRpcId(activeSubscriptions[index].id, item.id)) { activeSubscriptions.remove(at: index); return } } finally { activeLock.unlock() }
    }
    private func reserveActive(id: JsonRpcId): Bool { activeLock.lock(); try { if (activeRequests.size >= framing.maxConcurrentRequests) { return false }; activeRequests.add(id); true } finally { activeLock.unlock() } }
    private func removeActive(id: JsonRpcId): Unit { activeLock.lock(); try { for (index in 0..activeRequests.size) { if (sameJsonRpcId(activeRequests[index], id)) { activeRequests.remove(at: index); return } } } finally { activeLock.unlock() } }
    private func activeSnapshot(): Array<JsonRpcId> { activeLock.lock(); try { activeRequests.toArray() } finally { activeLock.unlock() } }
    private func drainActiveRequests(): McpResult<Unit> {
        let subscriptions = activeSubscriptionSnapshot()
        for (item in subscriptions) { item.closed = true; let _ = item.source.close() }
        waitForActiveRequests(); let active = activeSnapshot()
        for (id in active) { let _ = server.handleNotification(JsonRpcNotification(MCP_METHOD_CANCELLED, params: jsonObject([
            JsonObjectEntry("requestId", requestIdValue(id)), JsonObjectEntry("reason", jsonString("MCP stdio server is closing"))
        ]))) }
        waitForActiveRequests()
        let remaining = activeSnapshot()
        if (!remaining.isEmpty()) {
            McpResult.Err(McpError(
                McpErrorKind.Deadline,
                "mcp.stdio_shutdown_incomplete",
                "MCP stdio server still has active requests after bounded shutdown",
                data: jsonObject([
                    JsonObjectEntry(
                        "active_requests",
                        jsonNumber(remaining.size.toString())
                    )
                ])
            ))
        } else { McpResult.Ok(()) }
    }
    private func activeSubscriptionSnapshot(): Array<McpServerActiveSubscription> {
        activeLock.lock(); try { activeSubscriptions.toArray() } finally { activeLock.unlock() }
    }
    private func waitForActiveRequests(): Unit {
        let deadline = MonoTime.now() + Duration.millisecond * framing.gracefulShutdownMillis
        while (!activeSnapshot().isEmpty() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
    }
}

class McpServerActiveSubscription {
    let id: JsonRpcId
    let source: McpSubscriptionSource
    var closed = false
    init(id: JsonRpcId, source: McpSubscriptionSource) { this.id = id; this.source = source }
}

public func mcpCancellationNotification(
    requestId: JsonRpcId,
    reason: String,
    meta!: ?McpRequestMeta = None
): JsonRpcNotification {
    let fields = ArrayList<JsonObjectEntry>()
    fields.add(JsonObjectEntry("requestId", requestIdValue(requestId)))
    fields.add(JsonObjectEntry("reason", jsonString(reason)))
    match (meta) {
        case Some(value) => fields.add(JsonObjectEntry("_meta", value.toValue()))
        case None => ()
    }
    JsonRpcNotification(MCP_METHOD_CANCELLED, params: jsonObject(fields.toArray()))
}

public func readMcpHttpBody(
    stream: InputStream,
    declaredSize: ?Int64,
    maxBytes: Int64
): McpResult<String> {
    if (maxBytes < 1) {
        return mcpFailure<String>(McpErrorKind.Protocol, "mcp.http_body_limit_invalid", "MCP HTTP body limit must be positive")
    }
    match (declaredSize) {
        case Some(value) => if (value < 0 || value > maxBytes) {
            return mcpFailure<String>(McpErrorKind.Protocol, "mcp.http_body_too_large", "MCP HTTP body exceeds configured limit")
        }
        case None => ()
    }
    let output = ArrayList<Byte>()
    let buffer = Array<Byte>(4096, repeat: 0)
    try {
        while (true) {
            let count = stream.read(buffer)
            if (count <= 0) { break }
            if (output.size + count > maxBytes) {
                return mcpFailure<String>(McpErrorKind.Protocol, "mcp.http_body_too_large", "MCP HTTP body exceeds configured limit")
            }
            for (index in 0..count) { output.add(buffer[index]) }
        }
        McpResult.Ok(String.fromUtf8(output.toArray()))
    } catch (error: Exception) {
        McpResult.Err(McpError(McpErrorKind.Transport, "mcp.http_body_read_failed", error.message))
    }
}

public func decodeMcpSseResponse(
    source: String,
    expectedId: JsonRpcId,
    maxEventBytes: Int64
): McpResult<JsonRpcResponse> {
    if (maxEventBytes < 1) {
        return mcpFailure<JsonRpcResponse>(McpErrorKind.Protocol, "mcp.http_sse_limit_invalid", "MCP SSE event limit must be positive")
    }
    var data = ""
    for (raw in source.replace("\r\n", "\n").replace("\r", "\n").split("\n")) {
        if (raw == "") {
            if (data != "") {
                match (decodeMcpSseData(data, expectedId, maxEventBytes)) {
                    case McpResult.Ok(Some(response)) => return McpResult.Ok(response)
                    case McpResult.Ok(None) => ()
                    case McpResult.Err(error) => return McpResult.Err(error)
                }
                data = ""
            }
            continue
        }
        if (raw.startsWith(":")) { continue }
        if (raw == "data") {
            if (data != "") { data += "\n" }
            continue
        }
        if (raw.startsWith("data:")) {
            var value = raw[5..]
            if (value.startsWith(" ")) { value = value[1..] }
            if (data != "") { data += "\n" }
            data += value
            if (utf8ByteSize(data) > maxEventBytes) {
                return mcpFailure<JsonRpcResponse>(McpErrorKind.Protocol, "mcp.http_sse_event_too_large", "MCP SSE data event exceeds configured limit")
            }
        }
    }
    if (data != "") {
        match (decodeMcpSseData(data, expectedId, maxEventBytes)) {
            case McpResult.Ok(Some(response)) => return McpResult.Ok(response)
            case McpResult.Ok(None) => ()
            case McpResult.Err(error) => return McpResult.Err(error)
        }
    }
    mcpFailure<JsonRpcResponse>(McpErrorKind.Protocol, "mcp.http_sse_response_missing", "MCP SSE stream ended without the matching JSON-RPC response")
}

func decodeMcpSseData(data: String, expectedId: JsonRpcId, maxBytes: Int64): McpResult<?JsonRpcResponse> {
    match (decodeJsonRpc(data, maxBytes: maxBytes)) {
        case JsonRpcResult.Err(error) => McpResult.Err(McpError(
            McpErrorKind.Protocol, error.code, error.message, rpcCode: Some(error.rpcCode)
        ))
        case JsonRpcResult.Ok(JsonRpcEnvelope.Response(response)) =>
            if (sameJsonRpcId(response.id, expectedId)) { McpResult.Ok(Some(response)) } else { McpResult.Ok(None) }
        case JsonRpcResult.Ok(JsonRpcEnvelope.Notification(_)) => McpResult.Ok(None)
        case JsonRpcResult.Ok(JsonRpcEnvelope.Request(_)) => mcpFailure<?JsonRpcResponse>(
            McpErrorKind.Protocol,
            "mcp.http_sse_reverse_request_unsupported",
            "MCP SSE response contained an unsupported reverse request"
        )
    }
}

func utf8ByteSize(value: String): Int64 { unsafe { value.rawData().size } }

func requestIdValue(id: JsonRpcId): JsonNode {
    match (id.kind) {
        case JsonRpcIdKind.Text => jsonString(id.value)
        case JsonRpcIdKind.Number => jsonNumber(id.value)
        case JsonRpcIdKind.Null => jsonNull()
    }
}

func subscriptionNotificationId(notification: JsonRpcNotification): ?JsonRpcId {
    let meta = mcpObject(notification.params, "_meta")
    match (meta.field(MCP_META_SUBSCRIPTION_ID)) {
        case Some(value) => match (decodeMcpRequestId(value)) {
            case McpResult.Ok(id) => Some(id)
            case McpResult.Err(_) => None
        }
        case None => None
    }
}

func mcpFailure<T>(kind: McpErrorKind, code: String, message: String): McpResult<T> {
    McpResult.Err(McpError(kind, code, message))
}

func validTransition(from: McpLifecycleState, to: McpLifecycleState): Bool {
    match (from) {
        case McpLifecycleState.Created => to == McpLifecycleState.Starting || to == McpLifecycleState.Stopped
        case McpLifecycleState.Starting => to == McpLifecycleState.Ready || to == McpLifecycleState.Failed || to == McpLifecycleState.Stopping
        case McpLifecycleState.Ready => to == McpLifecycleState.Failed || to == McpLifecycleState.Stopping
        case McpLifecycleState.Failed => to == McpLifecycleState.Starting || to == McpLifecycleState.Stopping
        case McpLifecycleState.Stopping => to == McpLifecycleState.Stopped
        case McpLifecycleState.Stopped => false
    }
}

func lifecycleName(value: McpLifecycleState): String {
    match (value) {
        case McpLifecycleState.Created => "created"
        case McpLifecycleState.Starting => "starting"
        case McpLifecycleState.Ready => "ready"
        case McpLifecycleState.Failed => "failed"
        case McpLifecycleState.Stopping => "stopping"
        case McpLifecycleState.Stopped => "stopped"
    }
}
