package agent_extension_runtime
  import process4cj.*
  import std.collection.*
  import std.convert.*
  import std.fs.*
  import std.io.*
  import std.sync.*
  import std.time.*
  import yjson.*
  import yjson_support.*
public let JAVASCRIPT_EXTENSION_PROTOCOL: String = "axyndra-js-host-v2"
public let JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES: Int64 = 262144
let JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES: Int64 = 256
let JAVASCRIPT_HOST_MAX_SERVICE_CALLS: Int64 = 32
func hostNowMillis(): Int64 { DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() }

public class JavaScriptHostError {
    public let code: String
    public let message: String
    public let detailJson: String

    public init(code: String, message: String, detailJson!: String = "null") {
        this.code = code
        this.message = message
        this.detailJson = detailJson
    }
}

public enum JavaScriptHostResult<T> {
    Ok(T) | Err(JavaScriptHostError)

    public func isOk(): Bool {
        match (this) {
            case Ok(_) => true
            case Err(_) => false
        }
    }
}

public class JavaScriptToolDescriptor {
    public let name: String
    public let description: String
    public let inputSchemaJson: String

    public init(name: String, description!: String = "", inputSchemaJson!: String = "{}") {
        this.name = name.trimAscii()
        this.description = description
        this.inputSchemaJson = inputSchemaJson
    }
}

public class JavaScriptCommandDescriptor {
    public let name: String
    public let description: String

    public init(name: String, description!: String = "") {
        this.name = name.trimAscii()
        this.description = description
    }
}
public class JavaScriptHookDescriptor {
    public let event: String
    public let index: Int64

    public init(event: String, index: Int64) {
        if ((event != "tool_call" && event != "tool_result") || index < 0 || index >= 32) {
            throw IllegalArgumentException("invalid JavaScript hook descriptor")
        }
        this.event = event
        this.index = index
    }

    public prop reference: String { get() { event + ":" + index.toString() } }
}
public class JavaScriptHostInvocationResult {
    public let invocationId: String
    public let resultJson: String
    public let isError: Bool

    public init(invocationId: String, resultJson: String, isError!: Bool = false) {
        this.invocationId = invocationId
        this.resultJson = resultJson
        this.isError = isError
    }
}

public interface JavaScriptHostObserver {
    func onProgress(invocationId: String, progressJson: String): JavaScriptHostResult<Unit>
    func onServiceRequest(
        invocationId: String,
        requestId: String,
        service: String,
        argumentsJson: String
    ): JavaScriptHostResult<String> {
        let _ = invocationId
        let _ = requestId
        let _ = service
        let _ = argumentsJson
        hostError(
            "extension.service_unsupported",
            "no host service adapter is configured for this extension invocation"
        )
    }
}
public interface JavaScriptHostProcessLauncher {
    func launch(command: ProcessCommand): JavaScriptHostResult<ManagedProcess>
}

public class JavaScriptHostInvocationIdentity {
    public let kind: String
    public let threadId: String
    public let runId: String
    public let epoch: Int64
    public let operationId: String
    public let callId: String
    public let commandId: String

    public init(
        threadId!: String,
        runId!: String,
        epoch!: Int64,
        operationId!: String,
        callId!: String,
        kind!: String = "tool",
        commandId!: String = ""
    ) {
        let normalizedKind = kind.trimAscii()
        let thread = threadId.trimAscii()
        let run = runId.trimAscii()
        let operation = operationId.trimAscii()
        let call = callId.trimAscii()
        let command = commandId.trimAscii()
        let toolIdentityInvalid = normalizedKind == "tool" &&
            (run == "" || operation == "" || call == "" || epoch < 1 || command != "")
        let commandIdentityInvalid = normalizedKind == "command" &&
            (command == "" || run != "" || operation != "" || call != "" || epoch != 0)
        let hookIdentityInvalid = normalizedKind == "hook" &&
            (run == "" || operation != "" || call == "" || epoch < 1 || command == "")
        if (thread == "" ||
            (normalizedKind != "tool" && normalizedKind != "command" && normalizedKind != "hook") ||
            toolIdentityInvalid || commandIdentityInvalid || hookIdentityInvalid ||
            thread.size > JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES ||
            run.size > JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES ||
            operation.size > JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES ||
            call.size > JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES ||
            command.size > JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES ||
            thread.contains("\u{0000}") || run.contains("\u{0000}") ||
            operation.contains("\u{0000}") || call.contains("\u{0000}") ||
            command.contains("\u{0000}")) {
            throw IllegalArgumentException("invalid JavaScript invocation identity")
        }
        this.kind = normalizedKind
        this.threadId = thread
        this.runId = run
        this.epoch = epoch
        this.operationId = operation
        this.callId = call
        this.commandId = command
    }
}

public class JavaScriptHostInvocationContext {
    public let cwd: String
    public let hasUI: Bool

    public init(cwd!: String = "", hasUI!: Bool = false) {
        if (cwd.size > 4096 || cwd.contains("\u{0000}")) {
            throw IllegalArgumentException("invalid JavaScript invocation context")
        }
        this.cwd = cwd
        this.hasUI = hasUI
    }
}

public enum JavaScriptHostLaunchProfile {
    ProtocolWorker | PiV0871
}
func isPiJavaScriptHostProfile(profile: JavaScriptHostLaunchProfile): Bool {
    match (profile) {
        case JavaScriptHostLaunchProfile.PiV0871 => true
        case JavaScriptHostLaunchProfile.ProtocolWorker => false
    }
}

public class JavaScriptHostLaunchRequest {
    public let profile: JavaScriptHostLaunchProfile
    public let runtime: String
    public let packageRoot: String
    public let entrypoint: String
    public let extensionId: String
    public let extensionVersion: String
    public let generation: UInt64
    public let grantedCapabilities: Array<String>
    public let maxFrameBytes: Int64
    public let defaultTimeoutMillis: Int64
    public let enforceNodePermissions: Bool

    public init(
        packageRoot: String,
        entrypoint: String,
        runtime!: String = "node",
        profile!: JavaScriptHostLaunchProfile = JavaScriptHostLaunchProfile.ProtocolWorker,
        extensionId!: String,
        extensionVersion!: String,
        generation!: UInt64 = 1u64,
        grantedCapabilities!: Array<String> = [],
        maxFrameBytes!: Int64 = JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES,
        defaultTimeoutMillis!: Int64 = 30000,
        enforceNodePermissions!: Bool = true
    ) {
        let normalizedId = extensionId.trimAscii()
        let normalizedVersion = extensionVersion.trimAscii()
        if (packageRoot.trimAscii() == "" || entrypoint.trimAscii() == "" ||
            runtime.trimAscii() == "" || normalizedId == "" || normalizedVersion == "" ||
            normalizedId.contains("\u{0000}") || normalizedVersion.contains("\u{0000}") ||
            normalizedId.size > JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES ||
            normalizedVersion.size > JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES ||
            generation == 0u64 || grantedCapabilities.size > 128 ||
            maxFrameBytes < 1024 || maxFrameBytes > 4194304 ||
            defaultTimeoutMillis < 1 || defaultTimeoutMillis > 600000 ||
            (isPiJavaScriptHostProfile(profile) && !enforceNodePermissions)) {
            throw IllegalArgumentException("invalid JavaScript extension host launch request")
        }
        let normalizedCapabilities = ArrayList<String>()
        for (capability in grantedCapabilities) {
            let normalized = capability.trimAscii()
            if (normalized == "" || normalized.size > JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES ||
                normalized.contains("\u{0000}") || normalizedCapabilities.contains(normalized)) {
                throw IllegalArgumentException("invalid JavaScript extension capability grant")
            }
            normalizedCapabilities.add(normalized)
        }
        this.profile = profile
        this.runtime = runtime.trimAscii()
        this.packageRoot = packageRoot.trimAscii()
        this.entrypoint = entrypoint.trimAscii()
        this.extensionId = normalizedId
        this.extensionVersion = normalizedVersion
        this.generation = generation
        this.grantedCapabilities = normalizedCapabilities.toArray()
        this.maxFrameBytes = maxFrameBytes
        this.defaultTimeoutMillis = defaultTimeoutMillis
        this.enforceNodePermissions = enforceNodePermissions
    }
}

public class JavaScriptExtensionHost {
    private let request: JavaScriptHostLaunchRequest
    private let process: ManagedProcess
    private let observer: ?JavaScriptHostObserver
    private let stateLock = Mutex()
    private let stderrDrain: Future<Unit>
    private var closed = false
    private var invocationActive = false
    private var nextInvocation: Int64 = 1
    private var toolsValue: Array<JavaScriptToolDescriptor>
    private var commandsValue: Array<JavaScriptCommandDescriptor>
    private var hooksValue: Array<JavaScriptHookDescriptor>

    init(
        request: JavaScriptHostLaunchRequest,
        process: ManagedProcess,
        tools: Array<JavaScriptToolDescriptor>,
        commands: Array<JavaScriptCommandDescriptor>,
        hooks: Array<JavaScriptHookDescriptor>,
        observer: ?JavaScriptHostObserver
    ) {
        this.request = request
        this.process = process
        this.toolsValue = tools
        this.commandsValue = commands
        this.hooksValue = hooks
        this.observer = observer
        let child = process
        this.stderrDrain = spawn { drain(child.stderr) }
    }

    public prop generation: UInt64 { get() { request.generation } }
    public prop extensionId: String { get() { request.extensionId } }
    public prop extensionVersion: String { get() { request.extensionVersion } }
    public prop tools: Array<JavaScriptToolDescriptor> { get() { toolsValue.clone() } }
    public prop commands: Array<JavaScriptCommandDescriptor> { get() { commandsValue.clone() } }
    public prop hooks: Array<JavaScriptHookDescriptor> { get() { hooksValue.clone() } }
    public prop isClosed: Bool {
        get() {
            stateLock.lock()
            try { closed } finally { stateLock.unlock() }
        }
    }

    public func invoke(
        tool: String,
        argumentsJson: String,
        identity!: JavaScriptHostInvocationIdentity,
        context!: ?JavaScriptHostInvocationContext = None,
        cancellation!: CancellationToken = CancellationSource().token,
        timeoutMillis!: Int64 = 0,
        observer!: ?JavaScriptHostObserver = None
    ): JavaScriptHostResult<JavaScriptHostInvocationResult> {
        let name = tool.trimAscii()
        let isCommand = identity.kind == "command"
        let isHook = identity.kind == "hook"
        let descriptor = findTool(name)
        if (isCommand && !hasCommand(name)) {
            return hostError(
                "extension.command_not_registered",
                "command is not registered by the extension: " + name
            )
        }
        if (isHook && !hasHook(identity.commandId)) {
            return hostError(
                "extension.event_not_registered",
                "event handler is not registered by the extension"
            )
        }
        if (!isCommand && !isHook && (identity.kind != "tool" || descriptor.isNone())) {
            return hostError(
                "extension.tool_not_registered",
                "tool is not registered by the extension: " + name
            )
        }
        let arguments = try {
            parseUnifiedJson(argumentsJson, maxBytes: request.maxFrameBytes, maxDepth: 32)
        } catch (error: Exception) {
            return hostError("extension.arguments_invalid", error.message)
        }
        if (arguments.unifiedKind != UnifiedJsonKind.Object) {
            return hostError("extension.arguments_object_required", "invocation arguments must be an object")
        }
        let invocationId = match (beginInvocation()) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
        }
        let toolName = if (isCommand) { name } else if (isHook) {
            identity.commandId
        } else {
            descriptor.getOrThrow().name
        }
        let invocationObserver = match (observer) {
            case Some(value) => Some(value)
            case None => this.observer
        }
        let deadline = hostNowMillis() + if (timeoutMillis > 0) {
            min(timeoutMillis, request.defaultTimeoutMillis)
        } else {
            request.defaultTimeoutMillis
        }
        let finishSource = CancellationSource()
        let cancelAckSource = CancellationSource()
        let timeoutSource = CancellationSource()
        try {
            cancellation.check()
            let invokeEntries = invocationEnvelopeEntries(
                "invoke", request, invocationId, toolName, identity
            )
            invokeEntries.add(JsonObjectEntry("arguments", arguments))
            match (context) {
                case Some(value) => invokeEntries.add(JsonObjectEntry("context", jsonObject([
                    JsonObjectEntry("cwd", jsonString(value.cwd)),
                    JsonObjectEntry("has_ui", jsonBool(value.hasUI))
                ])))
                case None => ()
            }
            let invokeFrame = jsonObject(invokeEntries.toArray()).stringify()
            if (invokeFrame.size + 1 > request.maxFrameBytes) {
                return hostError("extension.arguments_too_large", "extension invocation frame exceeds the configured limit")
            }
            writeLine(invokeFrame)
            let timerFuture = spawn {
                while (!finishSource.token.isCancelled() &&
                    !cancellation.isCancelled() && hostNowMillis() < deadline) {
                    sleep(Duration.millisecond)
                }
                if (!finishSource.token.isCancelled()) {
                    let userCause = cancellation.cause()
                    let cause = match (userCause) {
                        case Some(value) => value
                        case None => CancellationCause(
                            CancellationKind.Deadline,
                            "extension.invocation_timeout",
                            "JavaScript extension invocation exceeded its deadline",
                            occurredAtMillis: hostNowMillis()
                        )
                    }
                    if (userCause.isNone()) {
                        let _ = timeoutSource.cancel(cause: Some(cause))
                    }
                    try {
                        let cancelEntries = invocationEnvelopeEntries(
                            "cancel", request, invocationId, toolName, identity
                        )
                        cancelEntries.add(JsonObjectEntry("reason", jsonString(cause.code)))
                        writeLine(jsonObject(cancelEntries.toArray()).stringify())
                    } catch (_: Exception) {}
                    let cancelDeadline = hostNowMillis() + 100
                    while (!finishSource.token.isCancelled() &&
                        !cancelAckSource.token.isCancelled() &&
                        process.isAlive() && hostNowMillis() < cancelDeadline) {
                        sleep(Duration.millisecond)
                    }
                    if (!finishSource.token.isCancelled() &&
                        !cancelAckSource.token.isCancelled() && process.isAlive()) {
                        let _ = process.cancel(cause)
                    }
                }
            }
            try {
                var progressCount = 0
                var serviceRequestCount: Int64 = 0
                let serviceRequestIds = ArrayList<String>()
                while (true) {
                    let message = readMessage(
                        finishSource.token,
                        deadline + 1100
                    )
                    let incomingType = textField(message, "type")
                    if (incomingType == "register_tool") {
                        closeAfterProtocolFailure()
                        return hostError(
                            "extension.tool_registration_unsupported",
                            "tool registration after the ready handshake is unsupported; the Run tool set is frozen"
                        )
                    }
                    if (!matchesInvocationEnvelope(
                        message, request, invocationId, toolName, identity
                    )) {
                        closeAfterProtocolFailure()
                        return hostError(
                            "extension.protocol_identity_mismatch",
                            "extension response does not match the active invocation"
                        )
                    }
                    let messageType = textField(message, "type")
                    if (messageType == "progress") {
                        if (!hasField(message, "progress")) {
                            closeAfterProtocolFailure()
                            return hostError("extension.protocol_progress_invalid", "progress frame omitted its payload")
                        }
                        progressCount += 1
                        if (progressCount > 128) {
                            closeAfterProtocolFailure()
                            return hostError("extension.protocol_progress_limit", "extension exceeded the progress-frame limit")
                        }
                        if (invocationCancellationCause(cancellation, timeoutSource).isNone()) {
                            match (invocationObserver) {
                                case Some(value) => match (value.onProgress(
                                    invocationId, fieldJson(message, "progress")
                                )) {
                                    case JavaScriptHostResult.Ok(_) => ()
                                    case JavaScriptHostResult.Err(error) =>
                                        closeAfterProtocolFailure()
                                        return JavaScriptHostResult.Err(error)
                                }
                                case None => ()
                            }
                        }
                        continue
                    }
                    if (messageType == "service_request") {
                        let requestId = textField(message, "request_id")
                        let service = textField(message, "service")
                        if (!validToolName(requestId) ||
                            !validToolName(service) || !isObjectField(message, "arguments")) {
                            closeAfterProtocolFailure()
                            return hostError(
                                "extension.protocol_service_invalid",
                                "service request requires a bounded id, name, and object arguments"
                            )
                        }
                        if (serviceRequestIds.contains(requestId)) {
                            closeAfterProtocolFailure()
                            return hostError(
                                "extension.protocol_service_duplicate",
                                "service request id was reused within one invocation"
                            )
                        }
                        serviceRequestIds.add(requestId)
                        serviceRequestCount += 1
                        if (serviceRequestCount > JAVASCRIPT_HOST_MAX_SERVICE_CALLS) {
                            closeAfterProtocolFailure()
                            return hostError(
                                "extension.protocol_service_limit",
                                "extension exceeded the per-invocation service request limit"
                            )
                        }
                        match (invocationCancellationCause(cancellation, timeoutSource)) {
                            case Some(cause) =>
                                closeForCancellation(cause)
                                return hostError(cause.code, cause.message)
                            case None => ()
                        }
                        let serviceResult = match (invocationObserver) {
                            case Some(value) => value.onServiceRequest(
                                invocationId,
                                requestId,
                                service,
                                fieldJson(message, "arguments")
                            )
                            case None => hostError<String>(
                                "extension.service_unsupported",
                                "no host service adapter is configured for this extension invocation"
                            )
                        }
                        let responseFrame = match (javascriptServiceResponseFrame(
                            request,
                            invocationId,
                            toolName,
                            identity,
                            requestId,
                            serviceResult
                        )) {
                            case JavaScriptHostResult.Ok(value) => value
                            case JavaScriptHostResult.Err(error) =>
                                closeAfterProtocolFailure()
                                return JavaScriptHostResult.Err(error)
                        }
                        writeLine(responseFrame)
                        continue
                    }
                    if (messageType == "cancelled") {
                        let cause = match (invocationCancellationCause(cancellation, timeoutSource)) {
                            case Some(value) => value
                            case None =>
                                closeAfterProtocolFailure()
                                return hostError("extension.protocol_unexpected_cancel", "extension cancelled an invocation without a host cancellation")
                        }
                        let _ = cancelAckSource.cancel()
                        closeForCancellation(cause)
                        return hostError(cause.code, cause.message)
                    }
                    if (messageType != "result" || !isBooleanField(message, "ok") ||
                        !hasField(message, "result")) {
                        closeAfterProtocolFailure()
                        return hostError(
                            "extension.protocol_unexpected_message",
                            "extension returned an invalid or unexpected protocol message"
                        )
                    }
                    match (invocationCancellationCause(cancellation, timeoutSource)) {
                        case Some(cause) =>
                            closeForCancellation(cause)
                            return hostError(cause.code, cause.message)
                        case None => ()
                    }
                    return JavaScriptHostResult.Ok(JavaScriptHostInvocationResult(
                        invocationId,
                        fieldJson(message, "result"),
                        isError: !boolField(message, "ok")
                    ))
                }
            } finally {
                let _ = finishSource.cancel()
                let _ = cancelAckSource.cancel()
                let _ = timerFuture.get()
            }
        } catch (error: ProcessError) {
            match (invocationCancellationCause(cancellation, timeoutSource)) {
                case Some(cause) =>
                    closeForCancellation(cause)
                    return hostError(cause.code, cause.message)
                case None =>
                    match (error.kind) {
                        case ProcessErrorKind.OutputLimit =>
                            return hostError("extension.protocol_frame_too_large", error.message)
                        case ProcessErrorKind.DeadlineExceeded =>
                            closeAfterProtocolFailure()
                            return hostError("extension.invocation_timeout", error.message)
                        case ProcessErrorKind.Frame =>
                            closeAfterProtocolFailure()
                            return hostError("extension.protocol_failed", error.message)
                        case _ =>
                            closeAfterProtocolFailure()
                            return hostError("extension.process_failed", error.message)
                    }
            }
        } catch (error: Exception) {
            closeAfterProtocolFailure()
            return hostError("extension.protocol_failed", error.message)
        } finally {
            let _ = finishSource.cancel()
            let _ = timeoutSource.cancel()
            let _ = cancelAckSource.cancel()
            finishSource.close()
            timeoutSource.close()
            cancelAckSource.close()
            endInvocation()
        }
        hostError("extension.protocol_failed", "extension invocation loop ended")
    }

    public func close(): Unit {
        if (!markClosed()) { return }
        if (invocationIsActive()) {
            let _ = process.terminate(force: true)
        } else {
            try {
                writeLine(jsonObject([
                    JsonObjectEntry("type", jsonString("close")),
                    JsonObjectEntry("protocol", jsonString(JAVASCRIPT_EXTENSION_PROTOCOL)),
                    JsonObjectEntry("extension_id", jsonString(request.extensionId)),
                    JsonObjectEntry("extension_version", jsonString(request.extensionVersion)),
                    JsonObjectEntry("generation", jsonNumber(request.generation.toString()))
                ]).stringify())
                let _ = process.closeInput()
            } catch (_: Exception) {}
            let closeDeadline = hostNowMillis() + 100
            while (process.isAlive() && hostNowMillis() < closeDeadline) {
                sleep(Duration.millisecond)
            }
            if (process.isAlive()) { let _ = process.terminate(force: true) }
        }
        releaseProcess()
    }

    func setTools(tools: Array<JavaScriptToolDescriptor>): Unit {
        toolsValue = tools
    }
    func setCommands(commands: Array<JavaScriptCommandDescriptor>): Unit {
        commandsValue = commands
    }
    func setHooks(hooks: Array<JavaScriptHookDescriptor>): Unit {
        hooksValue = hooks
    }
    func findTool(name: String): ?JavaScriptToolDescriptor {
        for (tool in toolsValue) {
            if (tool.name == name) { return Some(tool) }
        }
        None
    }
    func hasCommand(name: String): Bool {
        for (command in commandsValue) {
            if (command.name == name) { return true }
        }
        false
    }
    func hasHook(reference: String): Bool {
        for (hook in hooksValue) {
            if (hook.reference == reference) { return true }
        }
        false
    }
    func beginInvocation(): JavaScriptHostResult<String> {
        stateLock.lock()
        try {
            if (closed) {
                return hostError("extension.host_closed", "JavaScript extension host is closed")
            }
            if (invocationActive) {
                return hostError("extension.invocation_busy", "JavaScript extension host accepts one active invocation")
            }
            invocationActive = true
            let id = "invoke-" + nextInvocation.toString()
            nextInvocation += 1
            JavaScriptHostResult.Ok(id)
        } finally { stateLock.unlock() }
    }

    func endInvocation(): Unit {
        stateLock.lock()
        try { invocationActive = false } finally { stateLock.unlock() }
    }

    func invocationIsActive(): Bool {
        stateLock.lock()
        try { invocationActive } finally { stateLock.unlock() }
    }

    func markClosed(): Bool {
        stateLock.lock()
        try {
            if (closed) { return false }
            closed = true
            true
        } finally { stateLock.unlock() }
    }

    func closeAfterProtocolFailure(): Unit {
        if (!markClosed()) { return }
        let _ = process.terminate(force: true)
        releaseProcess()
    }

    func closeForCancellation(cause: CancellationCause): Unit {
        if (!markClosed()) { return }
        let _ = process.cancel(cause)
        releaseProcess()
    }

    func releaseProcess(): Unit {
        try { let _ = process.close() } catch (_: Exception) {}
        try { let _ = stderrDrain.get() } catch (_: Exception) {}
    }

    func writeLine(value: String): Unit {
        if (value.size + 1 > request.maxFrameBytes) {
            throw ProcessError(
                ProcessErrorKind.OutputLimit,
                "extension protocol frame exceeds the configured limit"
            )
        }
        process.writeStdin((value + "\n").toArray())
        process.flushInput()
    }

    func readMessage(cancellation: CancellationToken, deadline: Int64): JsonNode {
        let line = readLine(cancellation, deadline)
        try {
            let message = parseUnifiedJson(line, maxBytes: request.maxFrameBytes, maxDepth: 32)
            if (message.unifiedKind != UnifiedJsonKind.Object) {
                throw IllegalStateException("extension protocol frame must be a JSON object")
            }
            message
        } catch (error: Exception) {
            throw ProcessError(ProcessErrorKind.Frame, error.message)
        }
    }

    func readLine(cancellation: CancellationToken, deadline: Int64): String {
        let output = ArrayList<Byte>()
        let byte = Array<Byte>(1, repeat: 0)
        while (true) {
            cancellation.check()
            if (hostNowMillis() >= deadline) {
                throw ProcessError(ProcessErrorKind.DeadlineExceeded, "extension protocol read exceeded its deadline")
            }
            let count = process.stdout.read(byte)
            if (count <= 0) {
                throw ProcessError(ProcessErrorKind.Exit, "extension stdout closed before a response")
            }
            if (byte[0] == 10u8) { break }
            if (byte[0] == 13u8) { continue }
            output.add(byte[0])
            if (output.size > request.maxFrameBytes) {
                throw ProcessError(ProcessErrorKind.Frame, "extension protocol frame exceeds the configured limit")
            }
        }
        try {
            String.fromUtf8(output.toArray())
        } catch (error: Exception) {
            throw ProcessError(ProcessErrorKind.Frame, "extension protocol returned invalid UTF-8")
        }
    }
}


public func startJavaScriptExtensionHostWithLauncher(
    request: JavaScriptHostLaunchRequest,
    launcher: JavaScriptHostProcessLauncher,
    observer!: ?JavaScriptHostObserver = None
): JavaScriptHostResult<JavaScriptExtensionHost> {
    let root = try {
        let path = Path(request.packageRoot).normalize()
        if (!exists(path)) {
            return hostError("extension.root_missing", "extension package root does not exist")
        }
        let info = FileInfo(path)
        if (!info.isDirectory() || info.isSymbolicLink()) {
            return hostError("extension.root_invalid", "extension package root must be a non-symlink directory")
        }
        canonicalize(path).toString()
    } catch (error: Exception) {
        return hostError("extension.root_invalid", error.message)
    }
    if (!validHostEntrypoint(request.entrypoint)) {
        return hostError("extension.entrypoint_invalid", "extension entrypoint must be package-relative")
    }
    if (request.runtime != "node" && !request.runtime.endsWith("/node")) {
        return hostError(
            "extension.runtime_unsupported",
            "the selected host only supports Node's permission-controlled runtime"
        )
    }
    let entrypoint = Path(root).join(request.entrypoint)
    if (!exists(entrypoint) || !FileInfo(entrypoint).isRegular()) {
        return hostError("extension.entrypoint_missing", "extension entrypoint does not exist")
    }
    let arguments = ArrayList<String>()
    if (request.enforceNodePermissions) {
        arguments.add("--permission")
        arguments.add("--allow-fs-read=" + root)
    }
    if (request.entrypoint.endsWith(".ts")) {
        arguments.add("--experimental-strip-types")
    }
    if (isPiJavaScriptHostProfile(request.profile)) {
        arguments.add("--input-type=module")
        arguments.add("--eval")
        arguments.add(piJavaScriptHostBootstrapSource())
        arguments.add("--")
        arguments.add(request.entrypoint)
    } else {
        arguments.add(request.entrypoint)
    }
    let environment = HashMap<String, String>()
    environment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
    environment["HOME"] = root
    environment["TMPDIR"] = root
    let command = ProcessCommand(
        request.runtime,
        arguments: arguments.toArray(),
        workingDirectory: root,
        environment: environment,
        maxOutputBytes: request.maxFrameBytes * 4,
        terminateProcessTree: true
    )
    let process = try {
        match (launcher.launch(command)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
        }
    } catch (error: Exception) {
        return hostError("extension.process_spawn_failed", error.message)
    }
    let host = JavaScriptExtensionHost(request, process, [], [], [], observer)
    let cancellation = CancellationSource()
    try {
        host.writeLine(jsonObject([
            JsonObjectEntry("type", jsonString("hello")),
            JsonObjectEntry("protocol", jsonString(JAVASCRIPT_EXTENSION_PROTOCOL)),
            JsonObjectEntry("extension_id", jsonString(request.extensionId)),
            JsonObjectEntry("extension_version", jsonString(request.extensionVersion)),
            JsonObjectEntry("generation", jsonNumber(request.generation.toString())),
            JsonObjectEntry("capabilities", jsonArray(request.grantedCapabilities.map({ value => jsonString(value) }))),
            JsonObjectEntry("max_frame_bytes", jsonNumber(request.maxFrameBytes.toString()))
        ]).stringify())
        let ready = host.readMessage(
            cancellation.token, hostNowMillis() + request.defaultTimeoutMillis
        )
        if (isPiJavaScriptHostProfile(request.profile) &&
            textField(ready, "type") == "error" &&
            textField(ready, "protocol") == JAVASCRIPT_EXTENSION_PROTOCOL &&
            textField(ready, "extension_id") == request.extensionId &&
            textField(ready, "extension_version") == request.extensionVersion &&
            numberField(ready, "generation") == request.generation.toString()) {
            let code = textField(ready, "code")
            let message = textField(ready, "message")
            let safeCode = if (code.startsWith("extension.pi_") && code.size <= 128) {
                code
            } else {
                "extension.pi_initialization_failed"
            }
            let safeMessage = if (message.size <= 512) { message } else {
                "Pi extension initialization failed"
            }
            host.closeAfterProtocolFailure()
            return hostError(safeCode, safeMessage)
        }
        if (textField(ready, "type") != "ready" ||
            textField(ready, "protocol") != JAVASCRIPT_EXTENSION_PROTOCOL ||
            textField(ready, "extension_id") != request.extensionId ||
            textField(ready, "extension_version") != request.extensionVersion ||
            numberField(ready, "generation") != request.generation.toString() ||
            !matchesGrantedCapabilities(ready, request.grantedCapabilities)) {
            host.closeAfterProtocolFailure()
            return hostError("extension.handshake_invalid", "extension ready message does not match the launch request")
        }
        let tools = parseTools(ready, request.maxFrameBytes)
        match (tools) {
            case JavaScriptHostResult.Err(error) =>
                host.closeAfterProtocolFailure()
                JavaScriptHostResult.Err(error)
            case JavaScriptHostResult.Ok(toolValues) =>
                match (parseCommands(ready)) {
                    case JavaScriptHostResult.Err(error) =>
                        host.closeAfterProtocolFailure()
                        JavaScriptHostResult.Err(error)
                    case JavaScriptHostResult.Ok(commandValues) =>
                        match (parseHooks(ready)) {
                            case JavaScriptHostResult.Err(error) =>
                                host.closeAfterProtocolFailure()
                                JavaScriptHostResult.Err(error)
                            case JavaScriptHostResult.Ok(hookValues) =>
                                if (toolValues.isEmpty() && commandValues.isEmpty() && hookValues.isEmpty()) {
                                    host.closeAfterProtocolFailure()
                                    return hostError(
                                        "extension.registration_empty",
                                        "Pi extension must register at least one tool, command, or supported event"
                                    )
                                }
                                host.setTools(toolValues)
                                host.setCommands(commandValues)
                                host.setHooks(hookValues)
                                JavaScriptHostResult.Ok(host)
                        }
                }
        }
    } catch (error: ProcessError) {
        host.closeAfterProtocolFailure()
        match (error.kind) {
            case ProcessErrorKind.Frame => hostError("extension.protocol_frame_too_large", error.message)
            case ProcessErrorKind.OutputLimit => hostError("extension.protocol_frame_too_large", error.message)
            case ProcessErrorKind.DeadlineExceeded => hostError("extension.handshake_timeout", error.message)
            case ProcessErrorKind.Exit => hostError("extension.process_failed", error.message)
            case _ => hostError("extension.handshake_failed", error.message)
        }
    } catch (error: Exception) {
        host.closeAfterProtocolFailure()
        hostError("extension.handshake_failed", error.message)
    } finally {
        cancellation.close()
    }
}

func parseTools(
    ready: JsonNode,
    maxFrameBytes: Int64
): JavaScriptHostResult<Array<JavaScriptToolDescriptor>> {
    let value = match (ready.field("tools")) {
        case Some(item) => item
        case None => return hostError("extension.tools_missing", "extension ready message omitted tools")
    }
    if (value.unifiedKind != UnifiedJsonKind.List) {
        return hostError("extension.tools_invalid", "extension tools must be an array")
    }
    let output = ArrayList<JavaScriptToolDescriptor>()
    for (item in value.items) {
        if (item.unifiedKind != UnifiedJsonKind.Object) {
            return hostError("extension.tool_invalid", "extension tool descriptor must be an object")
        }
        let name = textField(item, "name")
        if (name == "" || !validToolName(name)) {
            return hostError("extension.tool_name_invalid", "extension tool name is invalid")
        }
        for (existing in output) {
            if (existing.name == name) {
                return hostError("extension.tool_duplicate", "extension registered the same tool twice")
            }
        }
        let description = match (item.field("description")) {
            case Some(value) =>
                if (value.unifiedKind != UnifiedJsonKind.Text) {
                    return hostError("extension.tool_description_invalid", "extension tool description must be text")
                }
                value.text
            case None => ""
        }
        let schemaNode = match (item.field("input_schema")) {
            case Some(value) => value
            case None => return hostError("extension.tool_schema_invalid", "extension tool input schema is missing")
        }
        if (schemaNode.unifiedKind != UnifiedJsonKind.Object) {
            return hostError("extension.tool_schema_invalid", "extension tool input schema must be an object")
        }
        let schema = schemaNode.stringify()
        if (schema.size > maxFrameBytes) {
            return hostError("extension.tool_schema_too_large", "extension tool schema exceeds the configured limit")
        }
        match (validateUnifiedJsonSchema(schemaNode, jsonObject([]))) {
            case Some(violation) =>
                if (violation.keyword == "schema") {
                    return hostError("extension.tool_schema_invalid", violation.message)
                }
            case None => ()
        }
        output.add(JavaScriptToolDescriptor(name, description: description, inputSchemaJson: schema))
    }
    JavaScriptHostResult.Ok(output.toArray())
}

func parseCommands(
    ready: JsonNode
): JavaScriptHostResult<Array<JavaScriptCommandDescriptor>> {
    let value = match (ready.field("commands")) {
        case Some(item) => item
        case None => return JavaScriptHostResult.Ok([])
    }
    if (value.unifiedKind != UnifiedJsonKind.List || value.items.size > 64) {
        return hostError("extension.commands_invalid", "extension commands must be a list of at most 64 entries")
    }
    let output = ArrayList<JavaScriptCommandDescriptor>()
    for (item in value.items) {
        if (item.unifiedKind != UnifiedJsonKind.Object) {
            return hostError("extension.command_invalid", "extension command descriptor must be an object")
        }
        let name = textField(item, "name")
        if (!validCommandName(name)) {
            return hostError("extension.command_name_invalid", "extension command name is invalid")
        }
        for (existing in output) {
            if (existing.name == name) {
                return hostError("extension.command_duplicate", "extension registered a duplicate command name")
            }
        }
        let description = match (item.field("description")) {
            case Some(descriptionNode) =>
                if (descriptionNode.unifiedKind != UnifiedJsonKind.Text || descriptionNode.text.size > 8192) {
                    return hostError("extension.command_description_invalid", "extension command description must be bounded text")
                }
                descriptionNode.text
            case None => ""
        }
        output.add(JavaScriptCommandDescriptor(name, description: description))
    }
    JavaScriptHostResult.Ok(output.toArray())
}
func parseHooks(ready: JsonNode): JavaScriptHostResult<Array<JavaScriptHookDescriptor>> {
    let value = match (ready.field("hooks")) {
        case Some(item) => item
        case None => return JavaScriptHostResult.Ok([])
    }
    if (value.unifiedKind != UnifiedJsonKind.List || value.items.size > 64) {
        return hostError("extension.hooks_invalid", "extension hooks must be a list of at most 64 entries")
    }
    let output = ArrayList<JavaScriptHookDescriptor>()
    var toolCallCount: Int64 = 0
    var toolResultCount: Int64 = 0
    for (item in value.items) {
        if (item.unifiedKind != UnifiedJsonKind.Object || item.fields.size != 2) {
            return hostError("extension.hook_invalid", "extension hook descriptor must contain only event and index")
        }
        let event = textField(item, "event")
        let index = match (item.field("index")) {
            case Some(indexNode) => if (indexNode.unifiedKind == UnifiedJsonKind.Number) {
                try { Int64.parse(indexNode.asNumberText()) } catch (_: Exception) { -1 }
            } else { -1 }
            case None => -1
        }
        if (event == "tool_call") {
            toolCallCount += 1
            if (toolCallCount > 32) {
                return hostError("extension.hook_limit", "tool_call event exceeds the 32-handler limit")
            }
        } else if (event == "tool_result") {
            toolResultCount += 1
            if (toolResultCount > 32) {
                return hostError("extension.hook_limit", "tool_result event exceeds the 32-handler limit")
            }
        } else {
            return hostError("extension.hook_event_unsupported", "extension hook event is unsupported")
        }
        if (index < 0 || index >= 32) {
            return hostError("extension.hook_index_invalid", "extension hook index is outside its registration limit")
        }
        let hook = JavaScriptHookDescriptor(event, index)
        for (existing in output where existing.reference == hook.reference) {
            return hostError("extension.hook_duplicate", "extension registered a duplicate event handler")
        }
        output.add(hook)
    }
    JavaScriptHostResult.Ok(output.toArray())
}
func matchesGrantedCapabilities(ready: JsonNode, granted: Array<String>): Bool {
    let value = match (ready.field("capabilities")) {
        case Some(item) => item
        case None => return false
    }
    if (value.unifiedKind != UnifiedJsonKind.List || value.items.size != granted.size) {
        return false
    }
    let accepted = ArrayList<String>()
    for (item in value.items) {
        if (item.unifiedKind != UnifiedJsonKind.Text || !granted.contains(item.text) ||
            accepted.contains(item.text)) {
            return false
        }
        accepted.add(item.text)
    }
    accepted.size == granted.size
}

func validHostEntrypoint(value: String): Bool {
    if (value == "" || value.startsWith("/") || value.contains("\\") ||
        value.contains("\u{0000}") || value.contains(":")) { return false }
    let parts = value.split("/")
    if (parts.isEmpty()) { return false }
    for (part in parts where part == "" || part == "." || part == "..") { return false }
    value.endsWith(".js") || value.endsWith(".mjs") || value.endsWith(".cjs") || value.endsWith(".ts")
}
func validCommandName(value: String): Bool {
    if (value == "" || value.size > 64) { return false }
    var first = true
    for (byte in value.toArray()) {
        let alphanumeric = (byte >= 48u8 && byte <= 57u8) ||
            (byte >= 97u8 && byte <= 122u8)
        if (!alphanumeric && byte != 45u8 && byte != 95u8) { return false }
        if (first && !alphanumeric) { return false }
        first = false
    }
    true
}
func validToolName(value: String): Bool {
    if (value == "" || value.size > 128) { return false }
    for (byte in value.toArray()) {
        if (!((byte >= 48u8 && byte <= 57u8) ||
            (byte >= 65u8 && byte <= 90u8) ||
            (byte >= 97u8 && byte <= 122u8) || byte == 45u8 || byte == 95u8 || byte == 46u8)) {
            return false
        }
    }
    true
}

func hostError<T>(code: String, message: String): JavaScriptHostResult<T> {
    JavaScriptHostResult.Err(JavaScriptHostError(code, message))
}

func textField(value: JsonNode, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Text) { item.text } else { "" }
        case None => ""
    }
}

func boolField(value: JsonNode, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => item.unifiedKind == UnifiedJsonKind.Boolean && item.boolValue
        case None => false
    }
}

func numberField(value: JsonNode, name: String): String {
    match (value.field(name)) {
        case Some(item) => if (item.unifiedKind == UnifiedJsonKind.Number) { item.numberText } else { "" }
        case None => ""
    }
}

func isObjectField(value: JsonNode, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => item.unifiedKind == UnifiedJsonKind.Object
        case None => false
    }
}

func javascriptServiceErrorFrame(
    request: JavaScriptHostLaunchRequest,
    invocationId: String,
    toolName: String,
    identity: JavaScriptHostInvocationIdentity,
    requestId: String,
    code: String,
    message: String
): JavaScriptHostResult<String> {
    let safeCode = if (validToolName(code) && code.size <= 128) {
        code
    } else {
        "extension.service_failed"
    }
    let safeMessage = if (message.size <= 512) { message } else { "host service request failed" }
    let entries = invocationEnvelopeEntries(
        "service_response", request, invocationId, toolName, identity
    )
    entries.add(JsonObjectEntry("request_id", jsonString(requestId)))
    entries.add(JsonObjectEntry("ok", jsonBool(false)))
    entries.add(JsonObjectEntry("error", jsonObject([
        JsonObjectEntry("code", jsonString(safeCode)),
        JsonObjectEntry("message", jsonString(safeMessage))
    ])))
    let frame = jsonObject(entries.toArray()).stringify()
    if (frame.size + 1 > request.maxFrameBytes) {
        return hostError(
            "extension.protocol_service_response_too_large",
            "service error response exceeds the configured frame limit"
        )
    }
    JavaScriptHostResult.Ok(frame)
}

func javascriptServiceResponseFrame(
    request: JavaScriptHostLaunchRequest,
    invocationId: String,
    toolName: String,
    identity: JavaScriptHostInvocationIdentity,
    requestId: String,
    response: JavaScriptHostResult<String>
): JavaScriptHostResult<String> {
    let resultJson = match (response) {
        case JavaScriptHostResult.Err(error) => return javascriptServiceErrorFrame(
            request, invocationId, toolName, identity, requestId, error.code, error.message
        )
        case JavaScriptHostResult.Ok(source) => source
    }
    let result = try {
        parseUnifiedJson(resultJson, maxBytes: request.maxFrameBytes, maxDepth: 32)
    } catch (_: Exception) {
        return javascriptServiceErrorFrame(
            request,
            invocationId,
            toolName,
            identity,
            requestId,
            "extension.service_result_invalid",
            "host service returned invalid JSON"
        )
    }
    let entries = invocationEnvelopeEntries(
        "service_response", request, invocationId, toolName, identity
    )
    entries.add(JsonObjectEntry("request_id", jsonString(requestId)))
    entries.add(JsonObjectEntry("ok", jsonBool(true)))
    entries.add(JsonObjectEntry("result", result))
    let frame = jsonObject(entries.toArray()).stringify()
    if (frame.size + 1 > request.maxFrameBytes) {
        return javascriptServiceErrorFrame(
            request,
            invocationId,
            toolName,
            identity,
            requestId,
            "extension.service_result_too_large",
            "host service result exceeds the configured frame limit"
        )
    }
    JavaScriptHostResult.Ok(frame)
}
func fieldJson(value: JsonNode, name: String): String {
    match (value.field(name)) {
        case Some(item) => item.stringify()
        case None => "null"
    }
}

func invocationEnvelopeEntries(
    messageType: String,
    request: JavaScriptHostLaunchRequest,
    invocationId: String,
    toolName: String,
    identity: JavaScriptHostInvocationIdentity
): ArrayList<JsonObjectEntry> {
    let entries = ArrayList<JsonObjectEntry>()
    entries.add(JsonObjectEntry("type", jsonString(messageType)))
    entries.add(JsonObjectEntry("protocol", jsonString(JAVASCRIPT_EXTENSION_PROTOCOL)))
    entries.add(JsonObjectEntry("extension_id", jsonString(request.extensionId)))
    entries.add(JsonObjectEntry("extension_version", jsonString(request.extensionVersion)))
    entries.add(JsonObjectEntry("generation", jsonNumber(request.generation.toString())))
    entries.add(JsonObjectEntry("id", jsonString(invocationId)))
    entries.add(JsonObjectEntry("tool", jsonString(toolName)))
    entries.add(JsonObjectEntry("kind", jsonString(identity.kind)))
    entries.add(JsonObjectEntry("command_id", jsonString(identity.commandId)))
    entries.add(JsonObjectEntry("thread_id", jsonString(identity.threadId)))
    entries.add(JsonObjectEntry("run_id", jsonString(identity.runId)))
    entries.add(JsonObjectEntry("epoch", jsonNumber(identity.epoch.toString())))
    entries.add(JsonObjectEntry("operation_id", jsonString(identity.operationId)))
    entries.add(JsonObjectEntry("call_id", jsonString(identity.callId)))
    entries
}

func matchesInvocationEnvelope(
    value: JsonNode,
    request: JavaScriptHostLaunchRequest,
    invocationId: String,
    toolName: String,
    identity: JavaScriptHostInvocationIdentity
): Bool {
    textField(value, "protocol") == JAVASCRIPT_EXTENSION_PROTOCOL &&
    textField(value, "extension_id") == request.extensionId &&
    textField(value, "extension_version") == request.extensionVersion &&
    numberField(value, "generation") == request.generation.toString() &&
    textField(value, "id") == invocationId &&
    textField(value, "tool") == toolName &&
    (textField(value, "kind") == identity.kind ||
        (identity.kind == "tool" && textField(value, "kind") == "")) &&
    (textField(value, "command_id") == identity.commandId ||
        (identity.kind == "tool" && textField(value, "command_id") == "")) &&
    textField(value, "thread_id") == identity.threadId &&
    textField(value, "run_id") == identity.runId &&
    numberField(value, "epoch") == identity.epoch.toString() &&
    textField(value, "operation_id") == identity.operationId &&
    textField(value, "call_id") == identity.callId
}

func invocationCancellationCause(
    cancellation: CancellationToken,
    timeoutSource: CancellationSource
): ?CancellationCause {
    match (cancellation.cause()) {
        case Some(cause) => Some(cause)
        case None => timeoutSource.token.cause()
    }
}

func hasField(value: JsonNode, name: String): Bool {
    value.field(name).isSome()
}

func isBooleanField(value: JsonNode, name: String): Bool {
    match (value.field(name)) {
        case Some(item) => item.unifiedKind == UnifiedJsonKind.Boolean
        case None => false
    }
}
