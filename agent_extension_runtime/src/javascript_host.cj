package agent_extension_runtime

import agent_domain.LogicalJsonOwnerReservation

import agent_domain.{OrdinaryToolPayloadLimits, ordinaryToolPayloadOffer, validOrdinaryToolPayloadOffer, AgentValue, toolInputAttachmentEvidenceValid, httpIntentText, readonlyDelegationInteger, canonicalAgentValue}

import agent_domain.{logicalJsonNodeCount, LogicalJsonFixedBufferReservation, contentPayloadLimitsValue, validContentPayloadLimits, CONTENT_PAYLOAD_INPUT_BYTES, CONTENT_PAYLOAD_RESULT_BYTES, CONTENT_PAYLOAD_MESSAGE_BYTES}
  import agent_sdk.*
  import agent_domain.{ServiceProtocolLimits, ServicePayloadLimits}
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
public let NATIVE_PLUGIN_PREPARE_MAX_INPUT_BYTES: Int64 = 16384
public let NATIVE_PLUGIN_PREPARE_MAX_OUTPUT_BYTES: Int64 = 65536
public let NATIVE_PLUGIN_PREPARE_MAX_TIMEOUT_MILLIS: Int64 = 5000
let JAVASCRIPT_HOST_MAX_IDENTITY_FIELD_BYTES: Int64 = 256
public let JAVASCRIPT_HOST_MAX_SERVICE_CALLS: Int64 = 32
func hostNowMillis(): Int64 { DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() }

public class JavaScriptHostError {
    public let code: String
    public let message: String
    public let detailJson: String
    // Host-only retained cleanup owner on a failed launch/handshake. It is
    // never serialized as diagnostic JSON and the host is already closed.
    public let cleanupHost: ?JavaScriptExtensionHost

    public init(code: String, message: String, detailJson!: String = "null",
        cleanupHost!: ?JavaScriptExtensionHost = None) {
        this.code = code
        this.message = message
        this.detailJson = detailJson
        this.cleanupHost = cleanupHost
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
    public let executionProfile: PluginToolExecutionProfile
    public let inputAttachmentField: String
    public let inputAttachmentMaxBytes: Int64

    public init(name: String, description!: String = "", inputSchemaJson!: String = "{}",
        executionProfile!: PluginToolExecutionProfile = PluginToolExecutionProfile.Brokered,
        inputAttachmentField!: String = "", inputAttachmentMaxBytes!: Int64 = 0) {
        this.name = name.trimAscii()
        this.description = description
        this.inputSchemaJson = inputSchemaJson
        if (!validPluginInputAttachmentDeclaration(inputAttachmentField, inputAttachmentMaxBytes) ||
            (inputAttachmentField != "" && executionProfile != PluginToolExecutionProfile.Brokered)) {
            throw IllegalArgumentException("input attachment metadata belongs only to a brokered native Tool")
        }
        this.inputAttachmentField = inputAttachmentField; this.inputAttachmentMaxBytes = inputAttachmentMaxBytes
        this.executionProfile = executionProfile
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
    private let payloadLock = Mutex()
    private var payloadRelease: ?(() -> Unit) = None
    func retainPayload(release: () -> Unit): Unit { payloadLock.lock(); try { payloadRelease = Some(release) } finally { payloadLock.unlock() } }
    public func releasePayload(): Unit {
        payloadLock.lock()
        let release = try { let value = payloadRelease; payloadRelease = None; value } finally { payloadLock.unlock() }
        match (release) { case Some(value) => value(); case None => () }
    }

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

// An inert trusted host gate around one physical request write only. The
// runtime never interprets registry metadata and holds no gate while waiting
// for a worker response. Cancellation and close traffic remain ungated.
public interface JavaScriptHostDispatchLease { func close(): Unit }
public interface JavaScriptHostDispatchFence {
    func enter(): JavaScriptHostResult<JavaScriptHostDispatchLease>
}
// Optional DATA retirement contract. It cannot admit a process or request.
// Ordinary dispatch fences retain their original interface and behavior.
public interface JavaScriptHostRetirableDispatchData159 {
    func retireDispatchData159(): Unit
}
// Optional DATA-only payer from the actual resident Registry custody.
// This interface cannot authorize a launch, request write or Source.
public interface JavaScriptHostResidentMetadata159h {
    func deriveHookResidentMetadata159h(invoice: Int64): LogicalJsonOwnerReservation
}
class JavaScriptHostPipeAdmission <: ProcessWriteAdmission {
    private let fence: JavaScriptHostDispatchFence
    init(fence: JavaScriptHostDispatchFence) { this.fence = fence }
    public func check(): Unit { let held = enter(); held.close() }
    public func enter(): ProcessWriteLease {
        match (fence.enter()) {
            case JavaScriptHostResult.Err(error) => throw JavaScriptHostDispatchDenied(error)
            case JavaScriptHostResult.Ok(value) => JavaScriptHostPipeLease(value)
        }
    }
}
class JavaScriptHostPipeLease <: ProcessWriteLease {
    private let lease: JavaScriptHostDispatchLease
    init(lease: JavaScriptHostDispatchLease) { this.lease = lease }
    public func close(): Unit { lease.close() }
}
class JavaScriptHostDispatchDenied <: Exception {
    let error: JavaScriptHostError
    init(error: JavaScriptHostError) { super(error.message); this.error = error }
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
        let toolIdentityInvalid = (normalizedKind == "tool" || normalizedKind == "service") &&
            (run == "" || operation == "" || call == "" || epoch < 1 || command != "")
        let commandIdentityInvalid = normalizedKind == "command" &&
            (command == "" || run != "" || operation != "" || call != "" || epoch != 0)
        let hookIdentityInvalid = normalizedKind == "hook" &&
            (run == "" || operation != "" || call == "" || epoch < 1 || command == "")
        let prepareIdentityInvalid = (normalizedKind == "prepare" || normalizedKind == "service_prepare") &&
            (run == "" || operation != "" || call == "" || epoch < 1 || command != "")
        let contentKind = normalizedKind == "context_provider" || normalizedKind == "resource_provider" || normalizedKind == "provider"
        let contentIdentityInvalid = contentKind &&
            (run != "" || operation != "" || call == "" || epoch != 0 || command != "")
        if (thread == "" ||
            (normalizedKind != "tool" && normalizedKind != "command" && normalizedKind != "hook" && normalizedKind != "prepare" && normalizedKind != "service" && normalizedKind != "service_prepare" && !contentKind) ||
            toolIdentityInvalid || commandIdentityInvalid || hookIdentityInvalid || prepareIdentityInvalid || contentIdentityInvalid ||
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
    ProtocolWorker | PiV0871 | NativeExecutable
}
func isPiJavaScriptHostProfile(profile: JavaScriptHostLaunchProfile): Bool {
    match (profile) {
        case JavaScriptHostLaunchProfile.PiV0871 => true
        case JavaScriptHostLaunchProfile.ProtocolWorker => false
        case JavaScriptHostLaunchProfile.NativeExecutable => false
    }
}
public func isNativeExecutableHostProfile(profile: JavaScriptHostLaunchProfile): Bool {
    match (profile) {
        case JavaScriptHostLaunchProfile.NativeExecutable => true
        case _ => false
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
    public let contributions: Array<PluginContributionDefinition>
    public let maxFrameBytes: Int64
    public let serviceLimits: ?ServiceProtocolLimits
    public let payloadLimits: ?ServicePayloadLimits
    public let contentPayload: Bool
    public let ordinaryToolPayload: Bool
    public let providerSequence: Bool
    public let contextSequence: Bool
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
        enforceNodePermissions!: Bool = true,
        contributions!: Array<PluginContributionDefinition> = [],
        serviceLimits!: ?ServiceProtocolLimits = None,
        payloadLimits!: ?ServicePayloadLimits = None,
        contentPayload!: Bool = false, ordinaryToolPayload!: Bool = false, providerSequence!: Bool = false, contextSequence!: Bool = false
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
            defaultTimeoutMillis < 1 || defaultTimeoutMillis > (if (isNativeExecutableHostProfile(profile) && serviceLimits.isSome()) {
                max(600000, serviceLimits.getOrThrow().callTimeoutMillis)
            } else { 600000 }) ||
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
        if (isNativeExecutableHostProfile(profile)) {
            if (contributions.isEmpty() || contributions.size > 128) {
                throw IllegalArgumentException("native executable requires bounded typed contributions")
            }
            let seen = ArrayList<PluginContributionDefinition>()
            for (contribution in contributions) {
                if ((contribution.kind != PluginContributionKind.Tool && contribution.kind != PluginContributionKind.Command &&
                    contribution.kind != PluginContributionKind.View &&
                    contribution.kind != PluginContributionKind.Service && contribution.kind != PluginContributionKind.ModelProvider &&
                    contribution.kind != PluginContributionKind.ContextProvider && contribution.kind != PluginContributionKind.ResourceProvider && contribution.kind != PluginContributionKind.Provider) ||
                    (contribution.kind == PluginContributionKind.Tool && !validToolName(contribution.name)) ||
                    ((contribution.kind == PluginContributionKind.Command || contribution.kind == PluginContributionKind.View ||
                        contribution.kind == PluginContributionKind.Service ||
                        contribution.kind == PluginContributionKind.ModelProvider || contribution.kind == PluginContributionKind.ContextProvider ||
                        (contribution.kind == PluginContributionKind.ResourceProvider || contribution.kind == PluginContributionKind.Provider)) &&
                        !validCommandName(contribution.name))) {
                    throw IllegalArgumentException("native executable contribution is unsupported")
                }
                for (existing in seen where existing.kind == contribution.kind && existing.name == contribution.name) {
                    throw IllegalArgumentException("native executable contribution identity is duplicated")
                }
                seen.add(contribution)
            }
        }
        this.profile = profile
        this.runtime = runtime.trimAscii()
        this.packageRoot = packageRoot.trimAscii()
        this.entrypoint = entrypoint.trimAscii()
        this.extensionId = normalizedId
        this.extensionVersion = normalizedVersion
        this.generation = generation
        this.grantedCapabilities = normalizedCapabilities.toArray()
        this.contributions = contributions.clone()
        match (serviceLimits) {
            case Some(limits) => if (!isNativeExecutableHostProfile(profile) || !limits.isExplicit || maxFrameBytes != limits.maxFrameBytes) {
                throw IllegalArgumentException("service profile requires an exact native host launch binding")
            }
            case None => ()
        }
        if (payloadLimits.isSome() && (!isNativeExecutableHostProfile(profile) || serviceLimits.isNone())) {
            throw IllegalArgumentException("logical payloads require a host-pinned explicit Native Service profile")
        }
        if (contentPayload) {
            var declared = false
            for (entry in contributions where entry.kind == PluginContributionKind.ContextProvider ||
                (entry.kind == PluginContributionKind.ResourceProvider || entry.kind == PluginContributionKind.Provider)) { declared = true }
            if (!isNativeExecutableHostProfile(profile) || !declared) {
                throw IllegalArgumentException("content payloads require an inspected native content contribution") }
        }
        if (ordinaryToolPayload) {
            var declared = false
            for (entry in contributions where entry.kind == PluginContributionKind.Tool) { declared = true }
            if (!isNativeExecutableHostProfile(profile) || !declared) {
                throw IllegalArgumentException("ordinary Tool payload requires an inspected native Tool contribution") }
        }
        this.ordinaryToolPayload = ordinaryToolPayload
        if (providerSequence) {
            var declared = false
            for (entry in contributions where entry.kind == PluginContributionKind.Provider) { declared = true }
            if (!isNativeExecutableHostProfile(profile) || !contentPayload || !declared ||
                !normalizedCapabilities.isEmpty() || serviceLimits.isSome() || payloadLimits.isSome()) {
                throw IllegalArgumentException("provider sequence requires a capability-free native content worker") }
        }
        if (contextSequence) {
            var declared = false
            for (entry in contributions where entry.kind == PluginContributionKind.ContextProvider) { declared = true }
            if (!isNativeExecutableHostProfile(profile) || !contentPayload || !declared || providerSequence || ordinaryToolPayload ||
                !normalizedCapabilities.isEmpty() || serviceLimits.isSome() || payloadLimits.isSome()) {
                throw IllegalArgumentException("context sequence requires its own capability-free typed native content worker") }
        }
        this.contextSequence = contextSequence
        this.providerSequence = providerSequence
        this.contentPayload = contentPayload
        this.payloadLimits = payloadLimits
        this.serviceLimits = serviceLimits
        this.maxFrameBytes = maxFrameBytes
        this.defaultTimeoutMillis = defaultTimeoutMillis
        this.enforceNodePermissions = enforceNodePermissions
    }
}

public class JavaScriptExtensionHost {
    private var dispatchFence: ?JavaScriptHostDispatchFence
    private var dispatchWriteFrames159: Int64 = 0
    private var dispatchDataCollecting159 = false
    private var dispatchDataRetirementPending159 = false
    private let request: JavaScriptHostLaunchRequest
    private let process: ManagedProcess
    private let observer: ?JavaScriptHostObserver
    private let stateLock = Mutex()
    private let payloadBudget = NativePayloadProcessBudget()
    // Only this host reads stdout. Carry bytes survive physical line boundaries
    // and stay charged until the actual reader/process cleanup acknowledgement.
    private let readLock = Mutex()
    private var readBuffer: Array<Byte> = []
    private var readBufferOffset: Int64 = 0
    private var readBufferCount: Int64 = 0
    private var readBufferClosed = false
    private var readBufferCharge: ?LogicalJsonFixedBufferReservation = None
    private var stderrDrain: ?Future<Unit> = None
    // One retained native cleanup owner. A signal acknowledgement does not
    // release the process, its streams, or the stderr task.
    private let cleanupLock = Mutex()
    private var cleanupStarted = false
    private var cleanupFuture: ?Future<Unit> = None
    private let cleanupDone = AtomicBool(false)
    private let cleanupFailed = AtomicBool(false)
    private var closed = false
    private var invocationActive = false
    private var hookTimer159h: ?JavaScriptHookTimer159h = None<JavaScriptHookTimer159h>
    private var nextInvocation: Int64 = 1
    private var toolsValue: Array<JavaScriptToolDescriptor>
    private var commandsValue: Array<JavaScriptCommandDescriptor>
    private var hooksValue: Array<JavaScriptHookDescriptor>
    private var servicesValue: Array<PluginServiceDescriptor> = []
    private var modelProvidersValue: Array<PluginModelProviderDescriptor> = []
    private var contextProvidersValue: Array<PluginContentProviderDescriptor> = []
    private var resourceProvidersValue: Array<PluginContentProviderDescriptor> = []
    private var policyProvidersValue: Array<PluginContentProviderDescriptor> = []
    private var contentPayloadEnabled = false
    private var ordinaryToolPayloadEnabled = false

    init(
        request: JavaScriptHostLaunchRequest,
        process: ManagedProcess,
        tools: Array<JavaScriptToolDescriptor>,
        commands: Array<JavaScriptCommandDescriptor>,
        hooks: Array<JavaScriptHookDescriptor>,
        observer: ?JavaScriptHostObserver,
        dispatchFence!: ?JavaScriptHostDispatchFence = None
    ) {
        this.dispatchFence = dispatchFence
        this.request = request
        this.process = process
        this.toolsValue = tools
        this.commandsValue = commands
        this.hooksValue = hooks
        this.observer = observer
        let child = process
        // An allocation/scheduling failure after spawn must not lose native
        // ownership by throwing out of this constructor.
        try { this.stderrDrain = Some(spawn { drain(child.stderr) }) }
        catch (_: Exception) {}
    }

    public prop generation: UInt64 { get() { request.generation } }
    public prop processExited: Bool { get() { process.tryExit().isSome() } }
    func stderrReaderStarted(): Bool { stderrDrain.isSome() }
    public prop extensionId: String { get() { request.extensionId } }
    public prop extensionVersion: String { get() { request.extensionVersion } }
    public prop tools: Array<JavaScriptToolDescriptor> { get() { toolsValue.clone() } }
    public prop commands: Array<JavaScriptCommandDescriptor> { get() { commandsValue.clone() } }
    public prop hooks: Array<JavaScriptHookDescriptor> { get() { hooksValue.clone() } }
    public prop services: Array<PluginServiceDescriptor> { get() { servicesValue.clone() } }
    public prop modelProviders: Array<PluginModelProviderDescriptor> { get() { modelProvidersValue.clone() } }
    public prop contextProviders: Array<PluginContentProviderDescriptor> { get() { contextProvidersValue.clone() } }
    public prop resourceProviders: Array<PluginContentProviderDescriptor> { get() { resourceProvidersValue.clone() } }
    public prop policyProviders: Array<PluginContentProviderDescriptor> { get() { policyProvidersValue.clone() } }
    public prop isClosed: Bool {
        get() {
            stateLock.lock()
            try { closed } finally { stateLock.unlock() }
        }
    }

    private func captureHookTimerPayer159h(): ?JavaScriptHostResidentMetadata159h {
        stateLock.lock()
        try {
            match (dispatchFence) {
                case Some(value) => value as JavaScriptHostResidentMetadata159h
                case None => None<JavaScriptHostResidentMetadata159h>
            }
        } finally { stateLock.unlock() }
    }

    private func prepareHookTimer159h(identity: JavaScriptHostInvocationIdentity,
        invocationId: String, toolName: String): JavaScriptHookTimer159h {
        if (hookTimer159h.isNone()) {
            // The real dispatch adapter derives from the existing Registry
            // ledger before allocating a timer header. Never acquire a second
            // per-worker 16 MiB logical root or substitute a fixed I/O buffer.
            let payer = captureHookTimerPayer159h().getOrThrow()
            let paid = payer.deriveHookResidentMetadata159h(32768)
            hookTimer159h = Some(JavaScriptHookTimer159h(paid))
        }
        let actual = hookTimer159h.getOrThrow()
        actual.begin159h(identity, invocationId, toolName)
        actual
    }

    public func invoke(
        tool: String,
        argumentsJson: String,
        identity!: JavaScriptHostInvocationIdentity,
        context!: ?JavaScriptHostInvocationContext = None,
        cancellation!: CancellationToken = CancellationSource().token,
        timeoutMillis!: Int64 = 0,
        serviceRequestLimit!: Int64 = JAVASCRIPT_HOST_MAX_SERVICE_CALLS,
        toolPayloadLimits!: ?OrdinaryToolPayloadLimits = None,
        observer!: ?JavaScriptHostObserver = None, inputAttachment!: ?AgentValue = None
    ): JavaScriptHostResult<JavaScriptHostInvocationResult> {
        if (request.contextSequence && (identity.kind != "context_provider" || observer.isSome() || serviceRequestLimit != 0 ||
            toolPayloadLimits.isSome() || identity.runId != "" || identity.operationId != "" || identity.epoch != 0 || identity.callId == "")) {
            return hostError("extension.context_sequence_scope", "a context sequence worker requires exact parentless pure ContextProvider identity and zero callbacks")
        }
        if (request.providerSequence && (identity.kind != "provider" || observer.isSome() || serviceRequestLimit != 0)) {
            return hostError("extension.provider_sequence_scope", "a sequence worker only accepts pure Provider invocations without a broker")
        }
        let name = tool.trimAscii()
        let isCommand = identity.kind == "command"
        let isHook = identity.kind == "hook"
        let isContent = identity.kind == "context_provider" || identity.kind == "resource_provider" || identity.kind == "provider"
        let isPrepare = identity.kind == "prepare" || identity.kind == "service_prepare" || isContent
        let isService = identity.kind == "service" || identity.kind == "service_prepare"
        let physicalTransportRole: Int64 = if (!isService) { 0 } else if (isPrepare) { 1 } else { 2 }
        let payloadLimits: ?ServicePayloadLimits = if (isService && isNativeExecutableHostProfile(request.profile)) { request.payloadLimits } else { None }
        let contentPayload = isContent && contentPayloadEnabled
        if (toolPayloadLimits.isSome() && (identity.kind != "tool" || !isNativeExecutableHostProfile(request.profile) ||
            !ordinaryToolPayloadEnabled || toolPayloadLimits.getOrThrow().contribution != name)) {
            return hostError("extension.tool_payload_unsupported", "ordinary Tool profile requires its exact declared native contribution and host negotiation")
        }
        let payloadEnabled = payloadLimits.isSome() || contentPayload || toolPayloadLimits.isSome()
        let payloadMessageLimit = if (toolPayloadLimits.isSome()) { toolPayloadLimits.getOrThrow().maxMessageBytes }
            else if (contentPayload) { CONTENT_PAYLOAD_MESSAGE_BYTES }
            else { match (payloadLimits) { case Some(value) => value.maxMessageBytes; case None => request.maxFrameBytes } }
        let payloadResultLimit = if (toolPayloadLimits.isSome()) { toolPayloadLimits.getOrThrow().maxResultBytes }
            else if (contentPayload) { CONTENT_PAYLOAD_RESULT_BYTES }
            else { match (payloadLimits) { case Some(value) => if (isPrepare) { value.maxPrepareBytes } else { value.maxResultBytes }
                case None => request.maxFrameBytes } }
        let mayRaiseServiceLimit = identity.kind == "service" && isNativeExecutableHostProfile(request.profile)
        if (serviceRequestLimit < (if (isPrepare) { 0 } else { 1 }) ||
            serviceRequestLimit > (if (mayRaiseServiceLimit) { 8192 } else { JAVASCRIPT_HOST_MAX_SERVICE_CALLS })) {
            return hostError("extension.service_limit_invalid", "service request quota is outside the host-selected profile limit")
        }
        let descriptor = findTool(name)
        if (isContent) {
            var declared = false
            let providers = if (identity.kind == "provider") { policyProvidersValue }
                else if (identity.kind == "context_provider") { contextProvidersValue } else { resourceProvidersValue }
            for (provider in providers where provider.name == name) { declared = true }
            if (!isNativeExecutableHostProfile(request.profile) || !declared || serviceRequestLimit != 0) {
                return hostError("extension.content_provider_not_registered", "pure content query requires its exact typed declaration and zero services")
            }
        }
        if (isPrepare && !isNativeExecutableHostProfile(request.profile)) {
            return hostError("extension.prepare_unsupported", "pure preparation requires a native executable contribution")
        }
        if (isService && (!isNativeExecutableHostProfile(request.profile) || !hasService(name))) {
            return hostError("extension.service_not_registered", "service is not declared by this native endpoint")
        }
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
        if (!isCommand && !isHook && !isService && !isContent && ((!isPrepare && identity.kind != "tool") || descriptor.isNone())) {
            return hostError(
                "extension.tool_not_registered",
                "tool is not registered by the extension: " + name
            )
        }
        match (inputAttachment) { case Some(value) =>
            if (identity.kind != "tool" || !isNativeExecutableHostProfile(request.profile) || descriptor.isNone() ||
                !toolInputAttachmentEvidenceValid(value) || httpIntentText(value, "thread_id") != identity.threadId ||
                httpIntentText(value, "run_id") != identity.runId || readonlyDelegationInteger(value, "epoch") != identity.epoch ||
                httpIntentText(value, "operation_id") != identity.operationId || httpIntentText(value, "call_id") != identity.callId ||
                httpIntentText(value.field("profile").getOrThrow(), "field") != descriptor.getOrThrow().inputAttachmentField ||
                readonlyDelegationInteger(value.field("profile").getOrThrow(), "max_bytes") != descriptor.getOrThrow().inputAttachmentMaxBytes) {
                return hostError("extension.input_attachment_invalid", "input attachment does not belong to the actual declared ordinary Tool") }
            case None => () }
        let prepareInputLimit = if (isContent) { if (contentPayload) { CONTENT_PAYLOAD_INPUT_BYTES } else { min(196608, request.maxFrameBytes - 4096) } } else if (identity.kind == "service_prepare" && payloadLimits.isSome()) {
            payloadLimits.getOrThrow().maxInputBytes + 65536
        } else if (identity.kind == "service_prepare" && request.serviceLimits.isSome()) {
            request.serviceLimits.getOrThrow().prepareInputBytes
        } else { NATIVE_PLUGIN_PREPARE_MAX_INPUT_BYTES }
        let prepareOutputLimit = if (isContent) { if (contentPayload) { CONTENT_PAYLOAD_RESULT_BYTES } else { min(196608, request.maxFrameBytes - 4096) } } else if (identity.kind == "service_prepare" && payloadLimits.isSome()) {
            payloadLimits.getOrThrow().maxPrepareBytes
        } else if (identity.kind == "service_prepare" && request.serviceLimits.isSome()) {
            request.serviceLimits.getOrThrow().maxPrepareBytes
        } else { NATIVE_PLUGIN_PREPARE_MAX_OUTPUT_BYTES }
        if (isPrepare && argumentsJson.size > prepareInputLimit) {
            return hostError("extension.prepare_input_too_large", "pure preparation input exceeds its host-selected limit")
        }
        let invocationId = match (beginInvocation()) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
        }
        let toolName = if (isCommand || isService || isContent) { name } else if (isHook) {
            identity.commandId
        } else {
            descriptor.getOrThrow().name
        }
        let invocationObserver: ?JavaScriptHostObserver = if (isPrepare) { None } else { match (observer) {
            case Some(value) => Some(value)
            case None => this.observer
        } }
        let invocationCeiling = if (isService) { request.defaultTimeoutMillis } else { min(request.defaultTimeoutMillis, 600000) }
        let requestedTimeout = if (timeoutMillis > 0) { min(timeoutMillis, invocationCeiling) } else { invocationCeiling }
        let deadline = hostNowMillis() + if (isPrepare) {
            min(requestedTimeout, NATIVE_PLUGIN_PREPARE_MAX_TIMEOUT_MILLIS)
        } else { requestedTimeout }
        let finishSource = CancellationSource()
        let cancelAckSource = CancellationSource()
        let timeoutSource = CancellationSource()
        // invocationId is freshly host-minted under the existing single-worker
        // invocation lock. This window never comes from plugin JSON.
        let payloadWindow = "native-json-" + invocationId
        var receiver: ?NativePayloadReceiver = None
        var outgoingPayload: ?NativePayloadProcessReservation = None
        var payloadReturned = false
        var retainedResponseBytes: Int64 = 0
        var retainedResponseNodes: Int64 = 0
        var responseSequence: Int64 = 1
        try {
            cancellation.check()
            if (payloadEnabled) {
                let maximum = if (isPrepare) { prepareInputLimit } else if (toolPayloadLimits.isSome()) {
                    toolPayloadLimits.getOrThrow().maxInputBytes
                } else { payloadMessageLimit - 65536 }
                if (argumentsJson.size < 1 || argumentsJson.size > maximum) {
                    return hostError("extension.arguments_too_large", "arguments exceed the host-selected logical bound")
                }
                // Own the existing worker slot and all expanded JSON/copy
                // accounting before lexical scanning or parsing any input.
                outgoingPayload = Some(payloadBudget.acquire(argumentsJson.size + 65536))
                payloadCheckNodes(argumentsJson)
                outgoingPayload.getOrThrow().ensureDecoded(argumentsJson.size, logicalJsonNodeCount(argumentsJson))
            }
            let arguments = try {
                hostPhysicalTransportDiagnostic(1, physicalTransportRole, argumentsJson.size, { => parseUnifiedJson(argumentsJson, maxBytes: if (isPrepare) {
                    if (payloadEnabled) { prepareInputLimit } else { min(request.maxFrameBytes, prepareInputLimit) }
                } else { payloadMessageLimit }, maxDepth: 32) })
            } catch (error: Exception) {
                return hostError("extension.arguments_invalid", error.message)
            }
            if (arguments.unifiedKind != UnifiedJsonKind.Object) {
                return hostError("extension.arguments_object_required", "invocation arguments must be an object")
            }
            if (payloadEnabled) {
                receiver = Some(NativePayloadReceiver(payloadBudget,
                    min(payloadMessageLimit, payloadResultLimit + 65536),
                    payloadWindow, deadline, cancellation, physicalFrameBytes: request.maxFrameBytes,
                    allowServicePayloads: toolPayloadLimits.isSome() && identity.kind == "tool" && !isPrepare && isNativeExecutableHostProfile(request.profile),
                    servicePayloadMaximumBytes: if (toolPayloadLimits.isSome()) { payloadMessageLimit } else { 0 },
                    reserveMaximum: !isContent))
            }
            let invokeEntries = invocationEnvelopeEntries(
                "invoke", request, invocationId, toolName, identity
            )
            invokeEntries.add(JsonObjectEntry("arguments", arguments))
            match (inputAttachment) { case Some(value) => invokeEntries.add(JsonObjectEntry("input_attachment", value)); case None => () }
            if (payloadEnabled) { invokeEntries.add(JsonObjectEntry("payload_window", jsonString(payloadWindow))) }
            match (toolPayloadLimits) { case Some(value) => invokeEntries.add(JsonObjectEntry("tool_payload_limits", value.value())); case None => () }
            match (context) {
                case Some(value) => invokeEntries.add(JsonObjectEntry("context", jsonObject([
                    JsonObjectEntry("cwd", jsonString(value.cwd)),
                    JsonObjectEntry("has_ui", jsonBool(!isPrepare && value.hasUI))
                ])))
                case None => ()
            }
            let invokeFrame = hostPhysicalTransportDiagnostic(2, physicalTransportRole, argumentsJson.size, { => jsonObject(invokeEntries.toArray()).stringify() })
            let useLogicalPayload = invokeFrame.size + 1 > request.maxFrameBytes
            if (useLogicalPayload && (!payloadEnabled || invokeFrame.size > payloadMessageLimit)) {
                return hostError("extension.arguments_too_large", "extension invocation exceeds its approved transport envelope")
            }
            // Large service writes need the same pre-write watchdog as pure
            // prepare: an endpoint which never reads cannot retain the pipe.
            let guardedWrite = isPrepare || useLogicalPayload || payloadEnabled
            if (!guardedWrite) { writeInvocationLine(invokeFrame) }
            var timerFuture: ?Future<Unit> = None<Future<Unit>>
            let inputTimer159h: ?JavaScriptHookTimer159h = if ((isHook || identity.kind == "provider" ||
                ((identity.kind == "tool" || identity.kind == "prepare") && descriptor.isSome() &&
                    descriptor.getOrThrow().executionProfile == PluginToolExecutionProfile.DataOnly)) &&
                captureHookTimerPayer159h().isSome()) {
                Some(prepareHookTimer159h(identity, invocationId, toolName))
            } else { None<JavaScriptHookTimer159h> }
            match (inputTimer159h) {
                case Some(timerOwner159h) =>
                    timerOwner159h.installTimer159h({ =>
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
                    timerOwner159h.fundCancel159h(cause.code)
                    let cancelCode159h = String.fromUtf8(cause.code.toArray())
                    timerOwner159h.installCancel159h({ =>
                        try {
                            let cancelEntries = invocationEnvelopeEntries(
                                "cancel", request, invocationId, toolName, identity
                            )
                            cancelEntries.add(JsonObjectEntry("reason", jsonString(cancelCode159h)))
                            writeLine(jsonObject(cancelEntries.toArray()).stringify())
                        } catch (_: Exception) {}
                    })
                    // A pure preparation may stop reading its input. Its
                    // cancel write must not delay the bounded force cleanup.
                    if (guardedWrite) { timerOwner159h.startCancel159h() }
                    else { timerOwner159h.runCancelFrame159h() }
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
                    timerOwner159h.joinCancel159h()
                }
                    })
                    timerOwner159h.startTimer159h()
                case None =>
                    timerFuture = Some(spawn {
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
                    let sendCancel = { =>
                        try {
                            let cancelEntries = invocationEnvelopeEntries(
                                "cancel", request, invocationId, toolName, identity
                            )
                            cancelEntries.add(JsonObjectEntry("reason", jsonString(cause.code)))
                            writeLine(jsonObject(cancelEntries.toArray()).stringify())
                        } catch (_: Exception) {}
                    }
                    // A pure preparation may stop reading its input. Its
                    // cancel write must not delay the bounded force cleanup.
                    let cancelWrite: ?Future<Unit> = if (guardedWrite) {
                        Some(spawn { sendCancel() })
                    } else { sendCancel(); None }
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
                    match (cancelWrite) {
                        case Some(value) => let _ = value.get()
                        case None => ()
                    }
                }
                    })
            }
            try {
                // Start the preparation watchdog before a potentially blocked
                // stdin write. Other invocation kinds keep their prior order.
                if (useLogicalPayload) {
                    hostPhysicalTransportDiagnostic(3, physicalTransportRole, invokeFrame.size, { => writeNativePayload(request, invocationId, toolName, identity, payloadWindow,
                        invokeFrame, payloadMessageLimit, cancellation, deadline,
                        { frame => writeInvocationLine(frame) }) })
                } else if (guardedWrite) { hostPhysicalTransportDiagnostic(3, physicalTransportRole, invokeFrame.size, { => writeInvocationLine(invokeFrame) }) }
                var progressCount = 0
                var serviceRequestCount: Int64 = 0
                // Service-only quotas may be larger; duplicate detection must
                // remain linear overall, rather than scanning every prior id.
                let serviceRequestIds = HashSet<String>()
                let decodeReceiver = receiver
                let parseReservation: ?(String) -> Unit = if (payloadEnabled) {
                    Some({ text => decodeReceiver.getOrThrow().ensurePhysical(text) })
                } else { None }
                while (true) {
                    var message = hostPhysicalTransportDiagnostic(4, physicalTransportRole, 0, { => readMessage(
                        finishSource.token,
                        deadline + 1100,
                        maxFrameBytes: if (isPrepare) {
                            if (payloadEnabled) { request.maxFrameBytes } else { min(request.maxFrameBytes, prepareOutputLimit) }
                        } else { 0 }, payloadReserved: payloadEnabled, parseReservation: parseReservation
                    ) })
                    let incomingType = textField(message, "type")
                    if (incomingType == "result" && payloadEnabled && textField(message, "payload_window") != payloadWindow) {
                        closeAfterProtocolFailure()
                        return hostError("extension.protocol_identity_mismatch", "profile result differs from its invocation window")
                    }
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
                    if (textField(message, "type").startsWith("payload_")) {
                        let logical = match (receiver) { case Some(value) => value; case None =>
                            closeAfterProtocolFailure(); return hostError("extension.payload_unsupported", "logical payload is not enabled for this invocation") }
                        let physicalPayloadMessage = message
                        let expectedServicePayloadSequence = serviceRequestCount + 2
                        match (hostPhysicalTransportDiagnostic(5, physicalTransportRole, 0, { => logical.accept(physicalPayloadMessage,
                            serviceSequence: expectedServicePayloadSequence) })) { case None => continue; case Some(value) => message = value }
                        if (!matchesInvocationEnvelope(message, request, invocationId, toolName, identity) ||
                            textField(message, "payload_window") != payloadWindow) {
                            closeAfterProtocolFailure()
                            return hostError("extension.protocol_identity_mismatch", "logical result differs from its complete invocation identity")
                        }
                    } else if (receiver.isSome() && receiver.getOrThrow().pending && textField(message, "type") != "cancelled") {
                        closeAfterProtocolFailure()
                        return hostError("extension.payload_overlap", "normal frame interrupted a logical payload transfer")
                    }
                    let messageType = textField(message, "type")
                    if (isPrepare && (messageType == "progress" || messageType == "service_request")) {
                        closeAfterProtocolFailure()
                        return hostError("extension.prepare_effect_forbidden",
                            "pure preparation cannot emit progress or request host services")
                    }
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
                        if (serviceRequestCount > serviceRequestLimit) {
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
                        let physicalBrokerMessage = message
                        let serviceResult = match (invocationObserver) {
                            case Some(value) => hostPhysicalTransportDiagnostic(6, physicalTransportRole, 0, { => value.onServiceRequest(
                                invocationId,
                                requestId,
                                service,
                                fieldJson(physicalBrokerMessage, "arguments")
                            ) })
                            case None => hostError<String>(
                                "extension.service_unsupported",
                                "no host service adapter is configured for this extension invocation"
                            )
                        }
                        // Sub-results remain live in the plugin interpreter until this
                        // invocation terminates. Grow the existing outgoing allocation;
                        // never borrow a third process transfer or refund per callback.
                        let responseMaximum = match (toolPayloadLimits) { case Some(value) => value.maxServiceResponseBytes; case None => request.maxFrameBytes }
                        if (toolPayloadLimits.isSome()) {
                            match (serviceResult) { case JavaScriptHostResult.Ok(source) =>
                                if (source.size > responseMaximum) { closeAfterProtocolFailure(); return hostError("extension.service_result_too_large", "service result exceeds the selected ordinary Tool profile") }
                                retainedResponseBytes += source.size
                                retainedResponseNodes += logicalJsonNodeCount(source)
                                outgoingPayload.getOrThrow().ensureDecoded(argumentsJson.size + retainedResponseBytes + 65536,
                                    logicalJsonNodeCount(argumentsJson) + retainedResponseNodes)
                                case _ => () }
                        }
                        let responseFrame = match (hostPhysicalTransportDiagnostic(7, physicalTransportRole, 0, { => javascriptServiceResponseFrame(
                            request,
                            invocationId,
                            toolName,
                            identity,
                            requestId,
                            serviceResult,
                            resultMaximum: responseMaximum, messageMaximum: if (toolPayloadLimits.isSome()) { payloadMessageLimit } else { request.maxFrameBytes }
                        ) })) {
                            case JavaScriptHostResult.Ok(value) => value
                            case JavaScriptHostResult.Err(error) =>
                                closeAfterProtocolFailure()
                                return JavaScriptHostResult.Err(error)
                        }
                        responseSequence++
                        if (responseFrame.size + 1 > request.maxFrameBytes && toolPayloadLimits.isSome()) {
                            let physicalWriteSequence = responseSequence
                            hostPhysicalTransportDiagnostic(8, physicalTransportRole, responseFrame.size, { => writeNativeServicePayload(request, invocationId, toolName, identity, payloadWindow, physicalWriteSequence,
                                responseFrame, payloadMessageLimit, cancellation, deadline, { frame => writeInvocationLine(frame) }) })
                        } else { hostPhysicalTransportDiagnostic(8, physicalTransportRole, responseFrame.size, { => writeInvocationLine(responseFrame) }) }
                        match (receiver) { case Some(value) => value.clearCompletedServicePayload(); case None => () }
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
                    let physicalTerminalMessage = message
                    let resultJson = hostPhysicalTransportDiagnostic(9, physicalTransportRole, 0, { => fieldJson(physicalTerminalMessage, "result") })
                    if (payloadEnabled && resultJson.size >
                        payloadResultLimit) {
                        closeAfterProtocolFailure()
                        return hostError("extension.payload_result_limit", "logical result exceeds its approved bound")
                    }
                    let result = JavaScriptHostInvocationResult(invocationId, resultJson, isError: !boolField(message, "ok"))
                    if (payloadEnabled) {
                        if (toolPayloadLimits.isSome()) {
                            outgoingPayload.getOrThrow().detachTransfer()
                            receiver.getOrThrow().detachTransfer()
                        }
                        let ownedOutgoing = outgoingPayload
                        let ownedReceiver = receiver
                        result.retainPayload({ =>
                            match (ownedOutgoing) { case Some(value) => value.close(); case None => () }
                            match (ownedReceiver) { case Some(value) => value.close(); case None => () }
                        })
                        payloadReturned = true
                    }
                    return JavaScriptHostResult.Ok(result)
                }
            } finally {
                let _ = finishSource.cancel()
                let _ = cancelAckSource.cancel()
                match (inputTimer159h) {
                    case Some(value) => value.joinTimer159h()
                    case None => let _ = timerFuture.getOrThrow().get(); timerFuture = None<Future<Unit>>
                }
            }
        } catch (error: JavaScriptHostDispatchDenied) {
            closeAfterProtocolFailure()
            return JavaScriptHostResult.Err(error.error)
        } catch (error: ProcessError) {
            match (invocationCancellationCause(cancellation, timeoutSource)) {
                case Some(cause) =>
                    closeForCancellation(cause)
                    return hostError(cause.code, cause.message)
                case None =>
                    match (error.kind) {
                        case ProcessErrorKind.OutputLimit =>
                            if (isPrepare) {
                                closeAfterProtocolFailure()
                                return hostError("extension.prepare_output_too_large", "pure preparation output exceeds its bounded frame limit")
                            }
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
            if (!payloadReturned) {
                match (outgoingPayload) { case Some(value) => value.close(); case None => () }
                match (receiver) { case Some(value) => value.close(); case None => () }
            }
            endInvocation()
        }
        hostError("extension.protocol_failed", "extension invocation loop ended")
    }

    public func close(): Unit {
        if (!markClosed()) { return }
        try {
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
        } catch (_: Exception) {
            // A native signal/query failure is not a reclamation ACK. Hand the
            // same process to owned cleanup and let sibling generations close.
        }
        releaseProcess()
    }

    // Never writes a close/cancel frame or waits for an invocation/writer lock.
    // Every possibly blocking native operation runs in the retained task.
    // This only requests teardown; awaitCleanup is the reclamation proof.
    public func requestAbort(): Unit {
        let _ = markClosed()
        cleanupLock.lock()
        try {
            if (cleanupStarted && !(cleanupDone.load() && cleanupFailed.load())) { return }
            cleanupStarted = true
            cleanupDone.store(false)
            cleanupFailed.store(false)
            try {
                cleanupFuture = Some(spawn { cleanupProcess() })
            } catch (_: Exception) {
                // Keep the process/host owner available for explicit retry.
                cleanupFailed.store(true)
                cleanupDone.store(true)
            }
        } finally { cleanupLock.unlock() }
    }

    public prop cleanupComplete: Bool {
        get() {
            cleanupLock.lock()
            try { cleanupDone.load() && !cleanupFailed.load() }
            finally { cleanupLock.unlock() }
        }
    }

    // The old cleanupComplete flag is set inside the worker. It is not used
    // as the DATA return witness: this opt-in collector joins the actual
    // Future in a separate helper, then clears our Future/fence references.
    public func collectCompletedDispatchData159(): Bool {
        stateLock.lock()
        let relevant = try {
            if (dispatchDataRetirementPending159) { return false }
            match (dispatchFence) {
                case None => return true
                case Some(value) => if ((value as JavaScriptHostRetirableDispatchData159).isNone()) { return true }
            }
            closed && !invocationActive && dispatchWriteFrames159 == 0
        } finally { stateLock.unlock() }
        if (!relevant) { return false }
        cleanupLock.lock()
        let selected = try {
            if (dispatchDataCollecting159 || !cleanupDone.load() || cleanupFailed.load() || cleanupFuture.isNone()) { return false }
            dispatchDataCollecting159 = true
            cleanupFuture.getOrThrow()
        } finally { cleanupLock.unlock() }
        try {
            if (!joinDispatchCleanup159(selected)) { return false }
            let retired = clearDispatchData159(selected)
            match (retired) {
                case None => false
                case Some(value) =>
                    try { value.retireDispatchData159() }
                    catch (_: Exception) { return false }
                    stateLock.lock()
                    try { dispatchDataRetirementPending159 = false }
                    finally { stateLock.unlock() }
                    true
            }
        } finally {
            cleanupLock.lock()
            try { dispatchDataCollecting159 = false } finally { cleanupLock.unlock() }
        }
    }
    private func joinDispatchCleanup159(value: Future<Unit>): Bool {
        try { value.get(); true } catch (_: Exception) { false }
    }
    private func clearDispatchData159(completed: Future<Unit>): ?JavaScriptHostRetirableDispatchData159 {
        stateLock.lock()
        try {
            if (!closed || invocationActive || dispatchWriteFrames159 != 0) { return None }
            let selected = match (dispatchFence) {
                case None => return None
                case Some(value) => match (value as JavaScriptHostRetirableDispatchData159) {
                    case Some(actual) => actual
                    case None => return None
                }
            }
            cleanupLock.lock()
            try {
                if (cleanupFuture.isNone() || !refEq(cleanupFuture.getOrThrow(), completed) ||
                    !cleanupDone.load() || cleanupFailed.load()) { return None }
                cleanupFuture = None
                dispatchFence = None
                dispatchDataRetirementPending159 = true
            } finally { cleanupLock.unlock() }
            Some(selected)
        } finally { stateLock.unlock() }
    }

    public func awaitCleanup(timeoutMillis!: Int64 = 1000): JavaScriptHostResult<Unit> {
        if (timeoutMillis < 0 || timeoutMillis > 2000) {
            return hostError("extension.cleanup_timeout_invalid", "cleanup wait must be within 0..2000 ms")
        }
        requestAbort()
        let deadline = MonoTime.now() + Duration.millisecond * timeoutMillis
        // Do not probe Future.tryGet: its task-completion lock may block.
        while (!cleanupDone.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
        cleanupLock.lock()
        try {
            if (cleanupFailed.load()) {
                return hostError("extension.cleanup_failed", "native endpoint cleanup failed and remains retained for retry")
            }
            if (!cleanupDone.load()) {
                return hostError("extension.cleanup_pending", "native endpoint cleanup remains owned and pending")
            }
            JavaScriptHostResult.Ok(())
        } finally { cleanupLock.unlock() }
    }

    private func cleanupProcess(): Unit {
        // This retained task is the owner even if a launch caller discards its
        // diagnostic error. Only termination/reclamation is retried, never a
        // worker launch, invocation, or protocol write.
        while (true) {
            var failed = false
            var released = false
            try {
                try { let _ = process.terminate(force: true) } catch (_: Exception) {}
                let forceAccepted = process.terminationRequested(force: true)
                for (input in [process.stdout, process.stderr]) {
                    try {
                        match (input as Resource) {
                            case Some(resource) => resource.close()
                            case None => failed = true
                        }
                    } catch (_: Exception) { failed = true }
                }
                if (forceAccepted) {
                    try { let _ = process.close(); released = true } catch (_: Exception) { failed = true }
                    // An interrupted read may throw; get still joins that
                    // completed task. It is not an outstanding reader.
                    try { match (stderrDrain) { case Some(value) => value.get(); case None => () } }
                    catch (_: Exception) {}
                } else { failed = true }
            } catch (_: Exception) { failed = true }
            if (released && !failed) {
                releaseReadBuffer()
                cleanupFailed.store(false)
                cleanupDone.store(true)
                return
            }
            cleanupFailed.store(true)
            sleep(Duration.millisecond * 100)
        }
    }

    func setServices(services: Array<PluginServiceDescriptor>): Unit { servicesValue = services.clone() }
    func setModelProviders(values: Array<PluginModelProviderDescriptor>): Unit { modelProvidersValue = values.clone() }
    func setPolicyProviders(values: Array<PluginContentProviderDescriptor>): Unit { policyProvidersValue = values.clone() }
    func acceptOrdinaryToolPayload(ready: JsonNode): Bool {
        let offered = ready.field("ordinary_tool_payload")
        if (offered.isNone()) { return true }
        if (!request.ordinaryToolPayload || !validOrdinaryToolPayloadOffer(offered.getOrThrow())) { return false }
        ordinaryToolPayloadEnabled = true
        true
    }

    func acceptContentPayload(ready: JsonNode): Bool {
        let offered = ready.field("content_payload_limits")
        if (offered.isNone() || offered.getOrThrow().unifiedKind == UnifiedJsonKind.Null) { return true }
        if (!request.contentPayload || !validContentPayloadLimits(offered.getOrThrow())) { return false }
        contentPayloadEnabled = true
        true
    }
    func setContentProviders(contexts: Array<PluginContentProviderDescriptor>, resources: Array<PluginContentProviderDescriptor>): Unit {
        contextProvidersValue = contexts.clone(); resourceProvidersValue = resources.clone()
    }
    func hasService(name: String): Bool {
        for (service in servicesValue where service.name == name) { return true }
        false
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
            if (nextInvocation < 1 || nextInvocation == Int64.Max) {
                return hostError("extension.invocation_sequence_exhausted", "host invocation sequence cannot wrap")
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
        requestAbort()
        releaseProcess()
    }

    func closeForCancellation(cause: CancellationCause): Unit {
        if (!markClosed()) { return }
        try { let _ = process.cancel(cause) } catch (_: Exception) {}
        // Keep teardown owned even when the synchronous cancellation attempt
        // throws. No invocation or external effect is replayed by cleanup.
        releaseProcess()
    }

    func releaseProcess(): Unit {
        let _ = awaitCleanup()
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

    func writeInvocationLine(value: String): Unit {
        stateLock.lock()
        let selected = try {
            if (dispatchWriteFrames159 == Int64.Max) {
                throw ProcessError(ProcessErrorKind.OutputLimit, "dispatch frame count exhausted")
            }
            dispatchWriteFrames159++
            dispatchFence
        } finally { stateLock.unlock() }
        try {
            match (selected) {
            case None => writeLine(value)
            case Some(fence) =>
                if (value.size + 1 > request.maxFrameBytes) { throw ProcessError(ProcessErrorKind.OutputLimit, "extension protocol frame exceeds the configured limit") }
                process.writeStdinAdmitted((value + "\n").toArray(), JavaScriptHostPipeAdmission(fence))
        }
        } finally {
            stateLock.lock()
            try { dispatchWriteFrames159-- } finally { stateLock.unlock() }
        }
    }

    func readMessage(cancellation: CancellationToken, deadline: Int64, maxFrameBytes!: Int64 = 0,
        payloadReserved!: Bool = false, parseReservation!: ?(String) -> Unit = None): JsonNode {
        let charge: ?NativePayloadProcessReservation = if ((request.payloadLimits.isSome() || request.contentPayload || request.ordinaryToolPayload) && !payloadReserved) { Some(payloadBudget.acquire(request.maxFrameBytes)) } else { None }
        try {
            let line = readLine(cancellation, deadline, maxFrameBytes: maxFrameBytes)
            try {
                if (request.payloadLimits.isSome() || request.contentPayload || request.ordinaryToolPayload) {
                    payloadCheckNodes(line)
                    match (charge) { case Some(value) => value.ensureDecoded(line.size, logicalJsonNodeCount(line)); case None => () }
                    match (parseReservation) { case Some(reserve) => reserve(line); case None => () }
                }
                let message = parseUnifiedJson(line, maxBytes: request.maxFrameBytes, maxDepth: 32)
                if (message.unifiedKind != UnifiedJsonKind.Object) {
                    throw IllegalStateException("extension protocol frame must be a JSON object")
                }
                message
            } catch (error: Exception) {
                throw ProcessError(ProcessErrorKind.Frame, error.message)
            }
        } finally { match (charge) { case Some(value) => value.close(); case None => () } }
    }

    func releaseReadBuffer(): Unit {
        readLock.lock()
        try {
            readBuffer = []; readBufferOffset = 0; readBufferCount = 0; readBufferClosed = true
            match (readBufferCharge) { case Some(value) => value.close(); case None => () }
            readBufferCharge = None
        } finally { readLock.unlock() }
    }

    func readLine(cancellation: CancellationToken, deadline: Int64, maxFrameBytes!: Int64 = 0): String {
        readLock.lock()
        try {
            if (readBufferClosed) { throw ProcessError(ProcessErrorKind.Exit, "extension stdout reader is closed") }
            if (readBufferCharge.isNone()) {
                let charge = nativePayloadOwnerBudget.acquireFixedBuffer(8192)
                try {
                    readBuffer = Array<Byte>(7936, repeat: 0)
                    readBufferCharge = Some(charge)
                } catch (error: Exception) { charge.close(); throw error }
            }
            let output = ArrayList<Byte>()
            var wireBytes: Int64 = 0
            while (true) {
                // Bound local work between cancellation/deadline checks. Do
                // not perform a UTC conversion and mutex query per wire byte.
                if (wireBytes % 256 == 0 || readBufferOffset == readBufferCount) {
                    cancellation.check()
                    if (hostNowMillis() >= deadline) {
                        throw ProcessError(ProcessErrorKind.DeadlineExceeded, "extension protocol read exceeded its deadline")
                    }
                }
                if (readBufferOffset == readBufferCount) {
                    readBufferCount = process.stdout.read(readBuffer)
                    readBufferOffset = 0
                    if (readBufferCount <= 0) {
                        throw ProcessError(ProcessErrorKind.Exit, "extension stdout closed before a response")
                    }
                    cancellation.check()
                    if (hostNowMillis() >= deadline) {
                        throw ProcessError(ProcessErrorKind.DeadlineExceeded, "extension protocol read exceeded its deadline")
                    }
                }
                // The original8192-byte payment covers7936 read bytes and
                // at most256 temporary slice bytes. No extra cache/owner.
                // Copy ordinary bytes once per original cancellation quantum.
                // Clip to the first violating byte of either original cap,
                // preserving exception precedence and the remaining cursor.
                var batchLimit = min(readBufferCount - readBufferOffset, 256 - wireBytes % 256)
                if (maxFrameBytes > 0) { batchLimit = min(batchLimit, max(1, maxFrameBytes - wireBytes + 1)) }
                batchLimit = min(batchLimit, max(1, request.maxFrameBytes - output.size + 1))
                let begin = readBufferOffset; var end = begin
                while (end < begin + batchLimit && readBuffer[end] != 10u8 && readBuffer[end] != 13u8) { end += 1 }
                let count = end - begin
                if (count > 0) {
                    readBufferOffset = end; wireBytes += count
                    if (maxFrameBytes > 0 && wireBytes > maxFrameBytes) {
                        throw ProcessError(ProcessErrorKind.OutputLimit, "extension protocol frame exceeds the invocation limit")
                    }
                    if (output.size + count > request.maxFrameBytes) {
                        throw ProcessError(ProcessErrorKind.Frame, "extension protocol frame exceeds the configured limit")
                    }
                    output.add(all: readBuffer[begin..end])
                    continue
                }
                let byte = readBuffer[readBufferOffset]; readBufferOffset += 1
                wireBytes += 1
                if (maxFrameBytes > 0 && wireBytes > maxFrameBytes) {
                    throw ProcessError(ProcessErrorKind.OutputLimit, "extension protocol frame exceeds the invocation limit")
                }
                if (byte == 10u8) {
                    cancellation.check()
                    if (hostNowMillis() >= deadline) {
                        throw ProcessError(ProcessErrorKind.DeadlineExceeded, "extension protocol read exceeded its deadline")
                    }
                    break
                }
                if (byte == 13u8) { continue }

            }
            try { String.fromUtf8(output.toArray()) }
            catch (_: Exception) { throw ProcessError(ProcessErrorKind.Frame, "extension protocol returned invalid UTF-8") }
        } finally { readLock.unlock() }
    }
}


public func startJavaScriptExtensionHostWithLauncher(
    request: JavaScriptHostLaunchRequest,
    launcher: JavaScriptHostProcessLauncher,
    observer!: ?JavaScriptHostObserver = None,
    cancellation!: ?CancellationToken = None,
    dispatchFence!: ?JavaScriptHostDispatchFence = None
): JavaScriptHostResult<JavaScriptExtensionHost> {
    match (cancellation) {
        case Some(value) => if (value.isCancelled()) { return hostError("extension.cancelled", "endpoint launch was cancelled before spawn") }
        case None => ()
    }
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
    let nativeExecutable = isNativeExecutableHostProfile(request.profile)
    if (!(if (nativeExecutable) { validIsolatedPluginEntrypoint(request.entrypoint) }
        else { validHostEntrypoint(request.entrypoint) })) {
        return hostError("extension.entrypoint_invalid", "extension entrypoint must be package-relative")
    }
    if (!nativeExecutable && request.runtime != "node" && !request.runtime.endsWith("/node")) {
        return hostError(
            "extension.runtime_unsupported",
            "the selected host only supports Node's permission-controlled runtime"
        )
    }
    let entrypoint = Path(root).join(request.entrypoint)
    if (!exists(entrypoint) || !FileInfo(entrypoint).isRegular()) {
        return hostError("extension.entrypoint_missing", "extension entrypoint does not exist")
    }
    // Every executable path component is checked before the launcher receives
    // it. The product launcher still owns the mandatory OS sandbox boundary.
    try {
        var current = Path(root)
        for (part in request.entrypoint.split("/")) {
            current = current.join(part)
            if (FileInfo(current).isSymbolicLink()) {
                return hostError("extension.entrypoint_invalid", "extension entrypoint must not traverse symbolic links")
            }
        }
        if (!canonicalize(entrypoint).toString().startsWith(root + "/")) {
            return hostError("extension.entrypoint_invalid", "extension entrypoint escapes package root")
        }
        if (nativeExecutable && !FileInfo(entrypoint).canExecute()) {
            return hostError("extension.entrypoint_not_executable", "native entrypoint is not executable")
        }
    } catch (error: Exception) {
        return hostError("extension.entrypoint_invalid", error.message)
    }
    let command = pluginHostProcessCommand(request, root)
    let process = try {
        match (launcher.launch(command)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => return JavaScriptHostResult.Err(error)
        }
    } catch (error: Exception) {
        return hostError("extension.process_spawn_failed", error.message)
    }
    startPluginHostHandshake(request, process, observer, cancellation, dispatchFence)
}

func pluginHostProcessCommand(request: JavaScriptHostLaunchRequest, root: String): ProcessCommand {
    let nativeExecutable = isNativeExecutableHostProfile(request.profile)
    let arguments = ArrayList<String>()
    if (!nativeExecutable && request.enforceNodePermissions) {
        arguments.add("--permission")
        arguments.add("--allow-fs-read=" + root)
    }
    if (!nativeExecutable && request.entrypoint.endsWith(".ts")) {
        arguments.add("--experimental-strip-types")
    }
    if (isPiJavaScriptHostProfile(request.profile)) {
        arguments.add("--input-type=module")
        arguments.add("--eval")
        arguments.add(piJavaScriptHostBootstrapSource())
        arguments.add("--")
        arguments.add(request.entrypoint)
    } else if (!nativeExecutable) {
        arguments.add(request.entrypoint)
    }
    let environment = HashMap<String, String>()
    environment["PATH"] = "/usr/local/bin:/usr/bin:/bin"
    environment["HOME"] = root
    environment["TMPDIR"] = root
    ProcessCommand(
        if (nativeExecutable) { Path(root).join(request.entrypoint).toString() } else { request.runtime },
        arguments: arguments.toArray(),
        workingDirectory: root,
        environment: environment,
        maxOutputBytes: request.maxFrameBytes * 4,
        terminateProcessTree: true
    )
}

func startPluginHostHandshake(
    request: JavaScriptHostLaunchRequest,
    process: ManagedProcess,
    observer: ?JavaScriptHostObserver,
    cancellation: ?CancellationToken,
    dispatchFence: ?JavaScriptHostDispatchFence
): JavaScriptHostResult<JavaScriptExtensionHost> {
    let host = JavaScriptExtensionHost(request, process, [], [], [], observer, dispatchFence: dispatchFence)
    let result = if (host.stderrReaderStarted()) { completePluginHostHandshake(request, host, cancellation) }
        else {
            host.requestAbort()
            hostError<JavaScriptExtensionHost>("extension.reader_start_failed", "native stderr reader ownership could not be initialized")
        }
    match (result) {
        case JavaScriptHostResult.Ok(value) => JavaScriptHostResult.Ok(value)
        case JavaScriptHostResult.Err(error) =>
            JavaScriptHostResult.Err(JavaScriptHostError(error.code, error.message, detailJson: error.detailJson,
                cleanupHost: if (host.cleanupComplete && host.collectCompletedDispatchData159()) { None } else { Some(host) }))
    }
}

// Optional extension is absent for legacy and non-policy peers, including
// mixed content workers; a strict third-party hello decoder sees its old shape.
func purePolicySequenceOffered(request: JavaScriptHostLaunchRequest): Bool {
    if (!request.contentPayload || !isNativeExecutableHostProfile(request.profile) ||
        !request.grantedCapabilities.isEmpty() || request.contributions.isEmpty()) { return false }
    if (request.providerSequence) { return true }
    for (entry in request.contributions where entry.kind != PluginContributionKind.Provider) { return false }
    true
}

func completePluginHostHandshake(request: JavaScriptHostLaunchRequest,
    host: JavaScriptExtensionHost, parentCancellation: ?CancellationToken): JavaScriptHostResult<JavaScriptExtensionHost> {
    let cancellation = CancellationSource(parent: parentCancellation)
    try {
        cancellation.token.check()
        let helloFields = ArrayList<JsonObjectEntry>([
            JsonObjectEntry("type", jsonString("hello")),
            JsonObjectEntry("protocol", jsonString(JAVASCRIPT_EXTENSION_PROTOCOL)),
            JsonObjectEntry("extension_id", jsonString(request.extensionId)),
            JsonObjectEntry("extension_version", jsonString(request.extensionVersion)),
            JsonObjectEntry("generation", jsonNumber(request.generation.toString())),
            JsonObjectEntry("capabilities", jsonArray(request.grantedCapabilities.map({ value => jsonString(value) }))),
            JsonObjectEntry("max_frame_bytes", jsonNumber(request.maxFrameBytes.toString())),
            JsonObjectEntry("service_protocol_limits", match (request.serviceLimits) {
                case Some(limits) => limits.toValue(); case None => jsonNull()
            }),
            JsonObjectEntry("content_payload_limits", if (request.contentPayload) { contentPayloadLimitsValue() } else { jsonNull() }),
            JsonObjectEntry("service_payload_limits", match (request.payloadLimits) {
                case Some(value) => value.toValue()
                case None => jsonNull()
            })
        ])
        if (purePolicySequenceOffered(request)) {
            helloFields.add(JsonObjectEntry("policy_sequence", jsonString(if (request.providerSequence) { "provider-invoke-i63-v1" } else { "invoke-i63-v1" })))
        }
        if (request.contextSequence) { helloFields.add(JsonObjectEntry("context_sequence", jsonString("context-invoke-i63-v1"))) }
        if (request.ordinaryToolPayload) { helloFields.add(JsonObjectEntry("ordinary_tool_payload", ordinaryToolPayloadOffer())) }
        host.writeInvocationLine(jsonObject(helloFields.toArray()).stringify())
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
        let services = match (parsePluginServices(ready)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) =>
                host.closeAfterProtocolFailure()
                return JavaScriptHostResult.Err(error)
        }
        if (!services.isEmpty() && !isNativeExecutableHostProfile(request.profile)) {
            host.closeAfterProtocolFailure()
            return hostError("extension.services_unsupported", "service routes require the native protocol profile")
        }
        let modelProviders = match (parsePluginModelProviders(ready)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => host.closeAfterProtocolFailure(); return JavaScriptHostResult.Err(error)
        }
        if (!modelProviders.isEmpty() && !isNativeExecutableHostProfile(request.profile)) {
            host.closeAfterProtocolFailure()
            return hostError("extension.model_providers_unsupported", "ModelProvider requires native typed profile")
        }
        let contextProviders = match (parsePluginContentProviders(ready, false)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => host.closeAfterProtocolFailure(); return JavaScriptHostResult.Err(error)
        }
        let resourceProviders = match (parsePluginContentProviders(ready, true)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => host.closeAfterProtocolFailure(); return JavaScriptHostResult.Err(error)
        }
        let policyProviders = match (parsePluginPolicyProviders(ready)) {
            case JavaScriptHostResult.Ok(value) => value
            case JavaScriptHostResult.Err(error) => host.closeAfterProtocolFailure(); return JavaScriptHostResult.Err(error)
        }
        if ((!contextProviders.isEmpty() || !resourceProviders.isEmpty() || !policyProviders.isEmpty()) && !isNativeExecutableHostProfile(request.profile)) {
            host.closeAfterProtocolFailure()
            return hostError("extension.content_providers_unsupported", "typed content providers require native isolation")
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
                                if (isNativeExecutableHostProfile(request.profile) &&
                                    !matchesNativePluginContributions(request.contributions, toolValues, commandValues, hookValues, services: services, modelProviders: modelProviders, contextProviders: contextProviders, resourceProviders: resourceProviders, policyProviders: policyProviders)) {
                                    host.closeAfterProtocolFailure()
                                    return hostError("extension.contributions_mismatch",
                                        "native ready contributions differ from the inspected package manifest")
                                }
                                if (toolValues.isEmpty() && commandValues.isEmpty() && hookValues.isEmpty() && services.isEmpty() && modelProviders.isEmpty() && contextProviders.isEmpty() && resourceProviders.isEmpty() && policyProviders.isEmpty()) {
                                    host.closeAfterProtocolFailure()
                                    return hostError(
                                        "extension.registration_empty",
                                        "extension must register a supported contribution"
                                    )
                                }
                                if (!host.acceptOrdinaryToolPayload(ready)) {
                                    host.closeAfterProtocolFailure()
                                    return hostError("extension.tool_payload_invalid", "ordinary Tool payload capability must exactly echo the host offer")
                                }
                                let contextSequence = ready.field("context_sequence") ?? jsonNull()
                                if (if (request.contextSequence) {
                                    contextSequence.unifiedKind != UnifiedJsonKind.Text || contextSequence.text != "context-invoke-i63-v1" ||
                                        contextProviders.isEmpty() || !validContentPayloadLimits(ready.field("content_payload_limits") ?? jsonNull()) ||
                                        (ready.field("policy_sequence") ?? jsonNull()).unifiedKind != UnifiedJsonKind.Null
                                } else { contextSequence.unifiedKind != UnifiedJsonKind.Null }) {
                                    host.closeAfterProtocolFailure()
                                    return hostError("extension.context_sequence_invalid", "context sequence must exactly echo its separate actual native host offer")
                                }
                                let sequence = ready.field("policy_sequence") ?? jsonNull()
                                let sequenceInvalid = if (request.providerSequence) {
                                    sequence.unifiedKind != UnifiedJsonKind.Text || sequence.text != "provider-invoke-i63-v1" ||
                                        policyProviders.isEmpty() || !validContentPayloadLimits(ready.field("content_payload_limits") ?? jsonNull())
                                } else {
                                    sequence.unifiedKind != UnifiedJsonKind.Null &&
                                        (!purePolicySequenceOffered(request) || sequence.unifiedKind != UnifiedJsonKind.Text ||
                                         sequence.text != "invoke-i63-v1" || policyProviders.isEmpty() || !toolValues.isEmpty() ||
                                         !commandValues.isEmpty() || !hookValues.isEmpty() || !services.isEmpty() ||
                                         !modelProviders.isEmpty() || !contextProviders.isEmpty() || !resourceProviders.isEmpty())
                                }
                                if (sequenceInvalid) {
                                    host.closeAfterProtocolFailure()
                                    return hostError("extension.policy_sequence_invalid", "pure policy sequence must match the exact native host offer")
                                }
                                if (!host.acceptContentPayload(ready)) {
                                    host.closeAfterProtocolFailure()
                                    return hostError("extension.content_payload_invalid", "content profile must exactly echo the inspected host offer")
                                }
                                host.setServices(services)
                                host.setModelProviders(modelProviders)
                                host.setContentProviders(contextProviders, resourceProviders)
                                host.setPolicyProviders(policyProviders)
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
            case ProcessErrorKind.Cancelled => hostError("extension.cancelled", "endpoint launch was cancelled")
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

func matchesNativePluginContributions(
    declared: Array<PluginContributionDefinition>,
    tools: Array<JavaScriptToolDescriptor>,
    commands: Array<JavaScriptCommandDescriptor>,
    hooks: Array<JavaScriptHookDescriptor>,
    services!: Array<PluginServiceDescriptor> = [],
    modelProviders!: Array<PluginModelProviderDescriptor> = [],
    contextProviders!: Array<PluginContentProviderDescriptor> = [],
    resourceProviders!: Array<PluginContentProviderDescriptor> = [],
    policyProviders!: Array<PluginContentProviderDescriptor> = []
): Bool {
    if (!hooks.isEmpty() || declared.size != tools.size + commands.size + services.size + modelProviders.size + contextProviders.size + resourceProviders.size + policyProviders.size) { return false }
    for (contribution in declared) {
        var found = false
        if (contribution.kind == PluginContributionKind.Tool) {
            for (tool in tools where tool.name == contribution.name &&
                tool.executionProfile == contribution.executionProfile &&
                tool.inputAttachmentField == contribution.inputAttachmentField &&
                tool.inputAttachmentMaxBytes == contribution.inputAttachmentMaxBytes) { found = true }
        } else if (contribution.kind == PluginContributionKind.Command) {
            for (command in commands where command.name == contribution.name) { found = true }
        } else if (contribution.kind == PluginContributionKind.Service) {
            for (service in services where service.name == contribution.name &&
                service.supportsPreparationReference == contribution.supportsPreparationReference) { found = true }
        } else if (contribution.kind == PluginContributionKind.ModelProvider) {
            for (provider in modelProviders where provider.name == contribution.name) { found = true }
        } else if (contribution.kind == PluginContributionKind.Provider) {
            for (provider in policyProviders where provider.name == contribution.name) { found = true }
        } else if (contribution.kind == PluginContributionKind.ContextProvider) {
            for (provider in contextProviders where provider.name == contribution.name) { found = true }
        } else if (contribution.kind == PluginContributionKind.ResourceProvider) {
            for (provider in resourceProviders where provider.name == contribution.name) { found = true }
        }
        if (!found) { return false }
    }
    true
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
        var profile = PluginToolExecutionProfile.Brokered
        match (item.field("execution_profile")) {
            case Some(value) =>
                if (value.unifiedKind != UnifiedJsonKind.Text || value.text != "data_only") {
                    return hostError("extension.tool_profile_invalid", "unknown Tool execution profile") }
                profile = PluginToolExecutionProfile.DataOnly
            case None => ()
        }
        if (nativeInputAttachmentFieldCount(item) > 1) { return hostError("extension.tool_attachment_invalid", "duplicate input attachment metadata") }
        let attachment = match (item.field("input_attachment")) {
            case Some(value) => match (nativeToolInputAttachmentMetadata(value)) {
                case Some(pair) => pair
                case None => return hostError("extension.tool_attachment_invalid", "input attachment metadata has an invalid field or limit") }
            case None => ("", 0i64)
        }
        if (attachment[0] != "" && profile != PluginToolExecutionProfile.Brokered) {
            return hostError("extension.tool_attachment_invalid", "data-only Tools cannot retain input artifacts")
        }
        output.add(JavaScriptToolDescriptor(name, description: description, inputSchemaJson: schema,
            executionProfile: profile, inputAttachmentField: attachment[0], inputAttachmentMaxBytes: attachment[1]))
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
    response: JavaScriptHostResult<String>,
    resultMaximum!: Int64 = 0, messageMaximum!: Int64 = 0
): JavaScriptHostResult<String> {
    let resultJson = match (response) {
        case JavaScriptHostResult.Err(error) => return javascriptServiceErrorFrame(
            request, invocationId, toolName, identity, requestId, error.code, error.message
        )
        case JavaScriptHostResult.Ok(source) => source
    }
    let result = try {
        parseUnifiedJson(resultJson, maxBytes: if (resultMaximum > 0) { resultMaximum } else { request.maxFrameBytes }, maxDepth: 32)
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
    if (frame.size + 1 > (if (messageMaximum > 0) { messageMaximum } else { request.maxFrameBytes })) {
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
