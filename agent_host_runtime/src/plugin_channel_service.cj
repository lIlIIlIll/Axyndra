package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.sync.*
import yjson.*
import yjson_support.*

// Temporary opt-in test diagnostics. Only stage and a bounded host error code
// are emitted: never messages, fields, paths, arguments or stream bytes.
func hostManagedJobIoDiagnostic(source: ?OperationRootSource, stage: String, error: AgentError): Unit {
    if (getVariable("AXYNDRA_DIAGNOSTIC_MANAGED_IO") != Some("1") || hostManagedJobSource(source).isNone()) { return }
    let code = error.code
    var valid = code.size > 0 && code.size <= 160
    for (byte in code.toArray()) {
        if (!((byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95 || byte == 46)) { valid = false }
    }
    println("MANAGED_IO_DIAGNOSTIC stage=" + stage + " code=" + if (valid) { code } else { "unrecognized" })
}

// This executor is registered once in the existing ToolCatalog. The manager
// locates an already active host-held invocation; plugin data never opens a
// channel, creates a lease or selects another process.
class HostManagedChannelWriter <: ToolExecutor {
    private let manager: HostPluginLifecycleManager
    init(manager: HostPluginLifecycleManager) { this.manager = manager }

    func descriptor(): ToolDescriptor {
        ToolDescriptor(ModelToolDefinition(HOST_CHANNEL_WRITE_TOOL,
            "Write one approved immutable byte intent to its owned service channel.",
            objectValue([ValueField("type", textValue("object"))])),
            Capability(CapabilityKind.ProcessSpawn), sideEffecting: true, hostServiceOnly: true, neverReplay: true,
            implementationVersion: HOST_CHANNEL_WRITE_FINGERPRINT,
            implementationFingerprint: HOST_CHANNEL_WRITE_FINGERPRINT,
            additionalCapabilityResolver: Some({ call => match (call.arguments.field("binding")) {
                case None => []
                case Some(binding) => match (channelServiceRequiredCapabilities(binding)) {
                    case Result.Ok(value) => value; case Result.Err(_) => []
                }
            } }),
            networkPolicyResolver: Some({ call => match (call.arguments.field("binding")) {
                case Some(binding) => match (binding.field("network")) {
                    case Some(policy) => parseNetworkPolicy(policy)
                    case None => hostLifecycleLeaseError("channel.binding_invalid")
                }
                case None => hostLifecycleLeaseError("channel.binding_invalid")
            } }),
            canonicalArgumentsResolver: Some({ _, call =>
                if (!httpIntentExactFields(call.arguments, ["binding", "intent"])) {
                    return hostLifecycleLeaseError("channel.arguments_invalid")
                }
                match (validateChannelServiceBinding(call.arguments.field("binding").getOrThrow())) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                }
                match (channelServiceIntentBytes(call.arguments.field("intent").getOrThrow(), call.arguments.field("binding").getOrThrow())) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                }
                Result.Ok(parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes: serviceProtocolLimits(call.arguments.field("binding").getOrThrow()).value().getOrThrow().canonicalBytes))
            }))
    }

    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        manager.writeInvocation(context, prepared)
    }
    public func cancel(_: RunId): Result<Unit> { Result.Ok(()) }
}

// Finite invocation-local protocol bookkeeping, with no background task or
// permission cache. The native host dispatches observer requests synchronously
// and returns its terminal result only after the callback has returned.
public class HostManagedChannelGate {
    private let lock = Mutex()
    private let ids = HashSet<String>()
    private var invocation = ""
    private var closed = false
    public func close(): Unit { lock.lock(); try { closed = true } finally { lock.unlock() } }
    public func isOpen(): Bool { lock.lock(); try { !closed } finally { lock.unlock() } }
    public func progress(id: String): Bool {
        lock.lock()
        try {
            if (closed || !hostValidPluginServiceIdentifier(id)) { return false }
            if (invocation == "") { invocation = id }
            invocation == id
        } finally { lock.unlock() }
    }
    public func accept(id: String, request: String): Bool {
        lock.lock()
        try {
            if (closed || !hostValidPluginServiceIdentifier(id) || !hostValidPluginServiceIdentifier(request) ||
                ids.contains(request) || ids.size >= 8192) { return false }
            if (invocation == "") { invocation = id }
            if (invocation != id) { return false }
            ids.add(request); true
        } finally { lock.unlock() }
    }
    public init() {}
}

class HostManagedChannelInvocation <: HostManagedServiceInvocation {
    private let service: HostPluginManagedService
    private let lease: HostPluginLifecycleLease
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let bindingText: String
    private let broker: HostJavaScriptPluginServiceBroker
    private let gate = HostManagedChannelGate()
    private let artifacts: HostServiceArtifactSession
    let writeAttempted = AtomicBool(false)
    let writeFailed = AtomicBool(false)

    init(service: HostPluginManagedService, lease: HostPluginLifecycleLease,
        context: ToolInvocationContext, prepared: PreparedToolInvocation, binding: AgentValue,
        broker: HostJavaScriptPluginServiceBroker) {
        this.service = service; this.lease = lease; this.context = context
        this.prepared = prepared; this.bindingText = stringifyUnifiedJson(binding); this.broker = broker
        artifacts = HostServiceArtifactSession(lease, context, prepared, binding)
    }
    public func close(): Result<Unit> { gate.close(); artifacts.close() }
    public func owns(child: PreparedToolInvocation): Bool {
        gate.isOpen() && child.source.parentOperationId.isSome() &&
            child.source.parentOperationId.getOrThrow().value == prepared.operationId.value &&
            child.source.runId.value == context.runId.value && child.source.sessionId.value == context.sessionId.value &&
            child.source.epoch == context.epoch
    }
    public func executeChild(childContext: ToolInvocationContext, child: PreparedToolInvocation): Result<ToolResult> {
        writeChild(childContext, child)
    }
    public func finish(response: Result<HostJavaScriptPluginInvocationResult>): Result<ToolResult> {
        gate.close()
        match (response) {
            case Result.Err(error) =>
                hostManagedJobIoDiagnostic(prepared.source.operationRoot, "service-result", error)
                hostManagedChannelFailure(error, writeAttempted.load(),
                    callerCancelled: hostManagedChannelCallerCancelled(context),
                        readonlyParent: prepared.operationPlan.effectClass == OperationEffectClass.ReadOnly)
            case Result.Ok(value) =>
                if (!artifacts.terminalReady()) { return hostManagedChannelUnknown() }
                if (writeFailed.load()) {
                    if (hostManagedChannelCallerCancelled(context) && prepared.operationPlan.effectClass != OperationEffectClass.ReadOnly) { return hostLifecycleIoCancelled() }
                    return hostManagedChannelUnknown()
                }
                hostManagedChannelTerminal(prepared.call.callId, value, writeAttempted.load())
        }
    }
    private func binding(): AgentValue { parseUnifiedJson(bindingText, maxBytes: 196608) }
    private func validate(): Result<Unit> {
        let diagnosticStarted = hostChannelIoDiagnosticStart()
        try {

        if (!gate.isOpen() || context.cancellation.isCancelled()) { return hostLifecycleLeaseError("channel.invocation_closed") }
        service.validateInvocation(context, prepared, binding())
    
        } finally { hostChannelIoDiagnosticRecord(0, diagnosticStarted) }
    }

    func writeChild(childContext: ToolInvocationContext, child: PreparedToolInvocation): Result<ToolResult> {
        if (!owns(child) || !channelServiceChildAllowed(prepared.operationPlan, child.operationPlan)) {
            return hostLifecycleLeaseError("channel.child_mismatch")
        }
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let bytes = match (channelServiceIntentBytes(child.operationPlan.canonicalArguments.field("intent").getOrThrow(), binding())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        // Conservative evidence from the actual host executor after canonical
        // handoff, never a plugin claim. A failed write may have sent a prefix.
        writeAttempted.store(true)
        match (lease.writePreparedChild(context, childContext, child, binding())) {
            case Result.Err(error) =>
                hostManagedJobIoDiagnostic(child.source.operationRoot, "broker-write", error)
                // This fact comes from the actual canonical child executor,
                // never from a plugin terminal. Close this observer before
                // returning the failure so no later request can reuse it.
                writeFailed.store(true)
                gate.close()
                hostManagedChannelFailure(error, true, callerCancelled: hostManagedChannelCallerCancelled(context))
            case Result.Ok(_) => Result.Ok(ToolResult(child.call.callId,
                objectValue([ValueField("written_bytes", integerValue(bytes))])))
        }
    }

    public func onProgress(invocationId: String, progressJson: String): JavaScriptHostResult<Unit> {
        if (!gate.progress(invocationId)) { return hostPluginServiceError("channel.invocation_closed", "progress belongs to no active channel invocation") }
        match (validate()) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
        match (context.outputSink.emit(ToolOutputChunk(prepared.call.callId, ToolOutputChannel.Progress, progressJson))) {
            case Result.Ok(_) => JavaScriptHostResult.Ok(())
            case Result.Err(error) => hostPluginServiceAgentError(error)
        }
    }

    public func onServiceRequest(invocationId: String, requestId: String, name: String,
        argumentsJson: String): JavaScriptHostResult<String> {
        let diagnosticStarted = hostChannelIoDiagnosticStart()
        try {

        if (!gate.accept(invocationId, requestId)) {
            return hostPluginServiceError("channel.request_invalid", "channel request identity is closed, repeated or over budget")
        }
        match (validate()) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
        let args = match (hostJavascriptPluginDecodeValue(argumentsJson, maxBytes: 65536)) {
            case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
        }
        if (name == "process.channel.read") {
            let request = match (hostManagedChannelReadArguments(args)) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
            }
            let (stream, maxBytes, waitMillis, encoding) = request
            match (lease.invocationRead(context, prepared, binding(), stream, maxBytes, waitMillis)) {
                case Result.Err(error) => hostPluginServiceAgentError(error)
                case Result.Ok(value) => hostManagedChannelReadResult(value, encoding: encoding)
            }
        } else if (name == "process.channel.write") {
            // The existing broker reuses parent-slot lending, policy, derived
            // Operation admission, handoff, execution and durable settlement.
            let response = match (broker.execute(invocationId, requestId, name, argumentsJson)) {
                case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
                case JavaScriptHostResult.Ok(value) => value
            }
            try {
                let value = parseUnifiedJson(response, maxBytes: 65536)
                if (value.field("is_error").getOrThrow().asBool()) {
                    return hostPluginServiceError("channel.write_failed", "channel writer did not produce a successful Receipt")
                }
                let output = value.field("output").getOrThrow()
                let receipt = hostLifecycleText(value, "receipt_id")
                if (!httpIntentExactFields(output, ["written_bytes"]) || receipt == "") {
                    return hostPluginServiceError("channel.receipt_invalid", "channel writer result lacks its durable Receipt")
                }
                JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                    ValueField("written_bytes", output.field("written_bytes").getOrThrow()),
                    ValueField("receipt_id", textValue(receipt))])))
            } catch (_: Exception) { hostPluginServiceError("channel.receipt_invalid", "channel writer result is malformed") }
        } else if (name == "output.artifact") {
            // Content-only observation of this same executing call. It cannot
            // read a file, select another blob or admit any external effect.
            let result = artifacts.handle(args)
            match (validate()) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
            match (result) { case Result.Err(error) => hostPluginServiceAgentError(error)
                case Result.Ok(value) => JavaScriptHostResult.Ok(stringifyUnifiedJson(value)) }
        } else if (name == "file.plan.propose") {
            // This read-only child proposes an immutable plan; it cannot apply
            // a write or borrow the backend startup window as authorization.
            match (lease.verifyInvocationRoot(context, prepared, binding())) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => ()
            }
            let response = broker.execute(invocationId, requestId, name, argumentsJson)
            match (validate()) { case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => () }
            match (lease.verifyInvocationRoot(context, prepared, binding())) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(_) => ()
            }
            response
        } else {
            hostPluginServiceError("channel.service_unsupported", "active channel invocation supports exact writes, bounded reads and read-only file proposals")
        }
    
        } finally { hostChannelIoDiagnosticRecord(6, diagnosticStarted) }
    }
}

public func hostManagedChannelReadArguments(args: AgentValue): Result<(ProcessChannelStream, Int64, Int64, String)> {
    if (!httpIntentExactFields(args, ["stream", "max_bytes", "wait_ms"]) &&
        !httpIntentExactFields(args, ["stream", "max_bytes", "wait_ms", "encoding"])) {
        return hostLifecycleLeaseError("channel.read_arguments_invalid")
    }
    try {
        let encoding = match (args.field("encoding")) {
            case None => "hex"
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Text || !["hex", "base64"].contains(value.text)) {
                    return hostLifecycleLeaseError("channel.read_encoding_invalid") }
                value.text
        }
        let stream = match (hostLifecycleText(args, "stream")) {
            case "stdout" => ProcessChannelStream.Stdout
            case "stderr" => ProcessChannelStream.Stderr
            case _ => return hostLifecycleLeaseError("channel.read_stream_invalid")
        }
        let maxValue = args.field("max_bytes").getOrThrow(); let waitValue = args.field("wait_ms").getOrThrow()
        if (maxValue.unifiedKind != ValueKind.Number || waitValue.unifiedKind != ValueKind.Number) {
            return hostLifecycleLeaseError("channel.read_arguments_invalid")
        }
        let maxBytes = Int64.parse(maxValue.asNumberText()); let waitMillis = Int64.parse(waitValue.asNumberText())
        if (maxBytes < 1 || maxBytes > 65536 || waitMillis < 0 || waitMillis > 1000) {
            return hostLifecycleLeaseError("channel.read_bounds")
        }
        // Bound the encoded result below the original 64 KiB IPC limit.
        // Hex keeps its existing 16 KiB cap; canonical Base64 permits 32 KiB
        // (43692 encoded bytes) with room for the service-response envelope.
        let representationLimit: Int64 = if (encoding == "base64") { 32768 } else { 16384 }
        Result.Ok((stream, min(maxBytes, representationLimit), waitMillis, encoding))
    } catch (_: Exception) { hostLifecycleLeaseError("channel.read_arguments_invalid") }
}

public func hostManagedChannelReadResult(value: ProcessChannelRead, encoding!: String = "hex"): JavaScriptHostResult<String> {
        let diagnosticStarted = hostChannelIoDiagnosticStart()
        try {

    // Encoding is only a representation of bytes already returned through
    // the original current/SQL/lease/filter/meter path. HTTP callers retain
    // the default hex shape. Both representations remain below the same IPC
    // bound and do not alter the raw-output window or total-byte quota.
    let bytes = value.bytes
    let representationLimit: Int64 = if (encoding == "base64") { 32768 } else { 16384 }
    if (!["hex", "base64"].contains(encoding) || bytes.size > representationLimit) {
        return hostPluginServiceError("channel.read_result_invalid", "read result exceeds its selected representation or decoded bound") }
    hostChannelIoDiagnosticReadBytes(bytes.size)
    if (encoding == "base64") {
        return JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
            ValueField("bytes_base64", textValue(hostBase64Bytes(bytes))), ValueField("eof", boolValue(value.eof))]))) }
    let digits = "0123456789abcdef".toArray()
    let encoded = Array<Byte>(bytes.size * 2, repeat: 0)
    for (index in 0..bytes.size) {
        encoded[index * 2] = digits[Int64(bytes[index] / 16)]
        encoded[index * 2 + 1] = digits[Int64(bytes[index] % 16)]
    }
    JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
        ValueField("bytes_hex", textValue(String.fromUtf8(encoded))), ValueField("eof", boolValue(value.eof))])))

        } finally { hostChannelIoDiagnosticRecord(3, diagnosticStarted) }
    }

public class HostManagedStartupObserver <: JavaScriptHostObserver {
    private let lease: HostPluginLifecycleLease
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let gate = HostManagedChannelGate()
    public init(lease: HostPluginLifecycleLease, context: ToolInvocationContext, prepared: PreparedToolInvocation) {
        this.lease = lease; this.context = context; this.prepared = prepared
    }
    public func close(): Unit { gate.close() }
    public func onProgress(invocationId: String, progressJson: String): JavaScriptHostResult<Unit> {
        if (!gate.progress(invocationId) || context.cancellation.isCancelled()) {
            return hostPluginServiceError("channel.startup_closed", "startup progress is no longer active")
        }
        match (context.outputSink.emit(ToolOutputChunk(prepared.call.callId, ToolOutputChannel.Progress, progressJson))) {
            case Result.Err(error) => hostPluginServiceAgentError(error); case Result.Ok(_) => JavaScriptHostResult.Ok(())
        }
    }
    public func onServiceRequest(invocationId: String, requestId: String, name: String,
        argumentsJson: String): JavaScriptHostResult<String> {
        if (!gate.accept(invocationId, requestId) || context.cancellation.isCancelled()) {
            return hostPluginServiceError("channel.startup_closed", "startup request is no longer active")
        }
        let args = match (hostJavascriptPluginDecodeValue(argumentsJson, maxBytes: 65536)) {
            case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
        }
        if (name == "process.channel.startup.write") {
            if (!httpIntentExactFields(args, ["bytes_hex"])) {
                return hostPluginServiceError("channel.startup_arguments_invalid", "startup write requires only bounded bytes")
            }
            let bytes = match (channelServiceWriteBytes(objectValue([ValueField("id", textValue("startup")),
                ValueField("bytes_hex", args.field("bytes_hex").getOrThrow())]))) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
            }
            match (lease.startupWrite(bytes)) {
                case Result.Err(error) => hostPluginServiceAgentError(error)
                case Result.Ok(_) => JavaScriptHostResult.Ok(stringifyUnifiedJson(objectValue([
                    ValueField("written_bytes", integerValue(bytes.size))])))
            }
        } else if (name == "process.channel.read") {
            let request = match (hostManagedChannelReadArguments(args)) {
                case Result.Err(error) => return hostPluginServiceAgentError(error); case Result.Ok(value) => value
            }
            let (stream, maxBytes, waitMillis, encoding) = request
            match (lease.startupRead(stream, maxBytes, waitMillis)) {
                case Result.Err(error) => hostPluginServiceAgentError(error)
                case Result.Ok(value) => hostManagedChannelReadResult(value, encoding: encoding)
            }
        } else { hostPluginServiceError("channel.startup_service_denied", "startup permits only its explicitly approved discovery channel") }
    }
}

func hostInvokeManagedProtocolStartup(host: HostJavaScriptPluginHost, endpoint: HostPinnedNativeServiceEndpoint,
    lease: HostPluginLifecycleLease, context: ToolInvocationContext, prepared: PreparedToolInvocation,
    configuration: AgentValue): Result<AgentValue> {
    if (!endpoint.generation.descriptor.requestedCapabilities.contains("process.channel")) {
        return hostLifecycleLeaseError("channel.capability_not_requested")
    }
    let observer = HostManagedStartupObserver(lease, context, prepared)
    try {
        match (host.invokeService(endpoint, stringifyUnifiedJson(objectValue([ValueField("action", textValue("start")),
            ValueField("configuration", configuration)])), JavaScriptHostInvocationIdentity(
            threadId: context.sessionId.value, runId: context.runId.value, epoch: context.epoch,
            operationId: prepared.operationId.value, callId: prepared.call.callId, kind: "service"), context,
            observer: Some(observer))) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => hostFreezeManagedProtocolStartupResponse(value,
                serviceProtocolLimits(prepared.operationPlan.canonicalArguments).value().getOrThrow().maxDirectoryBytes)
        }
    } finally { observer.close() }
}

// A completed wire response owns transport slots and allocation charges.
// Copy the bounded startup directory before retiring that response; the
// existing managed directory owner still validates and retains the copy.
func hostFreezeManagedProtocolStartupResponse(response: HostJavaScriptPluginInvocationResult,
    maximumDirectoryBytes: Int64): Result<AgentValue> {
    try {
        if (response.isError) { return hostLifecycleLeaseError("channel.startup_rejected") }
        Result.Ok(parseUnifiedJson(stringifyUnifiedJson(response.value), maxBytes: maximumDirectoryBytes))
    } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_directory_invalid") }
    finally { response.releasePayload() }
}

func hostManagedChannelUnknown<T>(observed!: ?AgentValue = None): Result<T> {
    var observation: ?OperationObservation = None
    match (observed) {
        case Some(value) =>
            // Only an already correlated terminal response reaches this helper.
            // It has passed the endpoint's output filter. Observations never
            // authorize effects, prove completion, or change replay policy.
            let encoded = stringifyUnifiedJson(value)
            if (encoded.size <= 65536) {
                try { observation = Some(OperationObservation(encoded)) }
                catch (_: Exception) { observation = Some(hostOperationOmittedObservation(encoded)) }
            } else { observation = Some(hostOperationOmittedObservation(encoded)) }
        case None => ()
    }
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plugin.service_outcome_unknown",
        "service invocation has no verifiable completion; reconcile it without replay", retryable: false,
        fallbackAllowed: false, observation: observation))
}
func hostOperationOmittedObservation(encoded: String): OperationObservation {
    // Larger full observations need the separately controlled artifact path.
    // Explicit omission metadata cannot be mistaken for retained full output.
    OperationObservation(stringifyUnifiedJson(objectValue([
        ValueField("omitted", boolValue(true)), ValueField("encoded_bytes", integerValue(encoded.size)),
        ValueField("encoded_sha256", textValue(modelPolicySha256Text(encoded))),
        ValueField("reason", textValue("observation_inline_limit"))])))
}
public func hostManagedChannelCallerCancelled(context: ToolInvocationContext): Bool {
    context.cancellation.isCancelled() ||
        (context.budget.deadlineMillis > 0 && agentUtcMillis() >= context.budget.deadlineMillis)
}

public func hostManagedChannelFailure<T>(error: AgentError, wrote: Bool, callerCancelled!: Bool = false, readonlyParent!: Bool = false): Result<T> {
    // A transport/lease revocation also cancels its endpoint token. That alone
    // is not caller cancellation and cannot turn an already written request
    // into a known cancelled effect. Only the actual root token/budget proves
    // caller cancellation; durable Executing receipts remain conservative.
    if (wrote && readonlyParent) { return hostManagedChannelUnknown() }
    if (error.kind == AgentErrorKind.Cancelled && callerCancelled) { return Result.Err(error) }
    if (wrote) { hostManagedChannelUnknown() } else { Result.Err(error) }
}
public func hostManagedChannelTerminal(callId: String, response: HostJavaScriptPluginInvocationResult,
    wrote: Bool): Result<ToolResult> {
    let value = response.value
    if (!httpIntentExactFields(value, ["schema", "status", "result", "error", "retry_safe"]) ||
        hostLifecycleText(value, "schema") != "axyndra.service-call-result/v1") {
        return hostManagedChannelFailure(AgentError(AgentErrorKind.Protocol, "channel.terminal_invalid",
            "service result omitted its bounded terminal envelope"), wrote)
    }
    let retry = value.field("retry_safe").getOrThrow()
    let error = value.field("error").getOrThrow()
    let status = hostLifecycleText(value, "status")
    if (retry.unifiedKind != ValueKind.Boolean || retry.asBool() ||
        (error.unifiedKind != ValueKind.Null && (error.unifiedKind != ValueKind.Text ||
            error.text.trimAscii() == "" || error.text.size > 256)) ||
        response.isError != (error.unifiedKind != ValueKind.Null) ||
        ((status == "input_required" || status == "unknown") && !response.isError)) {
        return hostManagedChannelFailure(AgentError(AgentErrorKind.Protocol, "channel.terminal_invalid",
            "service terminal fields are invalid"), wrote)
    }
    match (status) {
        case "complete" => Result.Ok(ToolResult(callId, value, isError: response.isError))
        case "input_required" =>
            // Keep the bounded remote outcome available for inspection. No
            // continuation token grants another write or creates a local wait.
            Result.Ok(ToolResult(callId, value, isError: true))
        case "unknown" => hostManagedChannelUnknown(observed: Some(value))
        case _ => hostManagedChannelFailure(AgentError(AgentErrorKind.Protocol, "channel.terminal_invalid",
            "service terminal status is not supported"), wrote)
    }
}
