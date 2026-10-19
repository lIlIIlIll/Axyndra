package model_provider_runtime

import agent_domain.*
import agent_ports.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.sync.*

public let MODEL_PROVIDER_PROTOCOL = "axyndra.model-provider/v1"
public let MODEL_PROVIDER_SNAPSHOT = "axyndra.model-input/v1"

// Discovery describes support. Only the host's DispatchGate authorizes use.
// Credentials are opaque references; neither discovery nor prepare resolves them.
public class ModelProviderBinding {
    public let plugin: String
    public let packageDigest: String
    public let configurationDigest: String
    public let instanceIdentity: String
    public let contribution: String
    public let providerId: String
    public let model: String
    public let wireModel: String
    public let supportsImages: Bool
    public let supportsTools: Bool
    public let supportsStructuredOutput: Bool
    public let capabilityFingerprint: String
    private let modelCapabilities: ModelCapabilities
    private let encoded: String
    public let digest: String

    public init(plugin: String, packageDigest: String, configurationDigest: String,
        instanceIdentity: String, contribution: String, model: String, wireModel: String,
        capabilities: ModelExecutionCapabilitiesSnapshot,
        configuration!: AgentValue = objectValue([]), credentialRefs!: Array<String> = [],
        supportsImages!: Bool = false, supportsTools!: Bool = false,
        supportsStructuredOutput!: Bool = false, supportsParallelTools!: Bool = false,
        supportsPromptCache!: Bool = false, providerId!: String = "",
        contextWindowTokens!: ?Int64 = None) {
        for (value in [plugin, instanceIdentity, contribution, model, wireModel]) {
            providerIdentifier(value)
        }
        if (!packageDigest.startsWith("sha256:") || !providerDigest(packageDigest[7..]) ||
            !providerDigest(configurationDigest) || capabilities.modelId != model ||
            (capabilities.configurationDigest != "" && capabilities.configurationDigest != configurationDigest) ||
            configuration.unifiedKind != ValueKind.Object || credentialRefs.size > 16) {
            throw IllegalArgumentException("invalid model provider binding")
        }
        let refs = ArrayList<AgentValue>()
        let seen = HashSet<String>()
        for (reference in credentialRefs) {
            providerIdentifier(reference)
            if (seen.contains(reference)) { throw IllegalArgumentException("duplicate credential reference") }
            seen.add(reference)
            refs.add(textValue(reference))
        }
        this.plugin = plugin
        this.packageDigest = packageDigest
        this.configurationDigest = configurationDigest
        this.instanceIdentity = instanceIdentity
        let profileId = if (providerId == "") { contribution } else { providerId }
        providerIdentifier(profileId)
        this.contribution = contribution
        this.providerId = profileId
        this.model = model
        this.wireModel = wireModel
        this.supportsImages = supportsImages
        this.supportsTools = supportsTools
        this.supportsStructuredOutput = supportsStructuredOutput
        this.capabilityFingerprint = capabilities.capabilityFingerprint
        this.modelCapabilities = ModelCapabilities(toolCalling: supportsTools, parallelToolCalling: supportsParallelTools,
            reasoning: capabilities.thinking.mode != ThinkingControlMode.NoThinking, vision: supportsImages,
            structuredOutput: supportsStructuredOutput, promptCache: supportsPromptCache,
            contextWindowTokens: contextWindowTokens ?? capabilities.modelMaxOutputTokens, maxOutputTokens: capabilities.modelMaxOutputTokens,
            thinking: Some(capabilities.thinking))
        let encoded = objectValue([
            ValueField("plugin", textValue(plugin)), ValueField("package_digest", textValue(packageDigest)),
            ValueField("configuration_digest", textValue(configurationDigest)),
            ValueField("instance_identity", textValue(instanceIdentity)),
            ValueField("contribution", textValue(contribution)), ValueField("provider_id", textValue(profileId)),
            ValueField("model", textValue(model)),
            ValueField("wire_model", textValue(wireModel)),
            ValueField("execution_capabilities", modelProviderCapabilityValue(capabilities)),
            ValueField("context_window", integerValue(contextWindowTokens ?? capabilities.modelMaxOutputTokens)),
            ValueField("capabilities", textValue(canonicalModelCapabilitySnapshotPayload(capabilities.snapshotSchemaVersion, capabilities.modelId,
                capabilities.thinking, capabilities.modelMaxOutputTokens, capabilities.endpointMaxOutputTokens,
                configurationDigest: capabilities.configurationDigest))),
            ValueField("images", boolValue(supportsImages)), ValueField("tools", boolValue(supportsTools)),
            ValueField("structured_output", boolValue(supportsStructuredOutput)),
            ValueField("parallel_tools", boolValue(supportsParallelTools)), ValueField("prompt_cache", boolValue(supportsPromptCache)),
            ValueField("configuration", configuration), ValueField("credential_refs", listValue(refs.toArray()))
        ]).stringify()
        if (encoded.size > 65536) { throw IllegalArgumentException("model provider binding is too large") }
        this.encoded = encoded
        this.digest = modelPolicySha256Text(canonicalAgentValue(parseUnifiedJson(encoded)))
    }
    public func snapshot(): AgentValue { parseUnifiedJson(encoded) }
    public func validate(request: ModelRequest): Result<Unit> { modelCapabilities.validate(request) }
}

// Host-held authority, never reconstructed from an IPC payload. Implementations
// must validate the existing Core DispatchClaimed Attempt and active Run/epoch,
// operator grant, exact binding, and current credentials/network policy. This
// object neither creates nor terminalizes an Attempt. The host owns cancellation.
public type ModelProviderTaskJoin = () -> Result<Unit>

public class ModelProviderDispatch {
    public let attemptId: ModelAttemptId
    public let runId: RunId
    public let threadId: ThreadId
    public let epoch: Int64
    public let requestId: String
    public let bindingDigest: String
    public let inputDigest: String
    public let cancellation: CancellationToken
    private let localCancellation: CancellationSource
    private var current: ?(() -> Result<Unit>)
    private var cleanup: ?(() -> Unit)
    private var ownedTaskHandler: ?(String, Future<Unit>) -> Result<ModelProviderTaskJoin>
    private let closeLock = Mutex()
    private var closed = false
    private var callbackFrames159: Int64 = 0
    private var cleanupReturned159 = false

    public init(attemptId: ModelAttemptId, runId: RunId, threadId: ThreadId, epoch: Int64,
        requestId: String, bindingDigest: String, inputDigest: String,
        cancellation: CancellationToken, current: () -> Result<Unit>, cleanup!: () -> Unit = { => () },
        ownedTaskHandler!: ?(String, Future<Unit>) -> Result<ModelProviderTaskJoin> = None) {
        providerIdentifier(requestId)
        if (epoch < 1 || !providerDigest(bindingDigest) || !providerDigest(inputDigest)) {
            throw IllegalArgumentException("invalid model provider dispatch")
        }
        this.attemptId = attemptId; this.runId = runId; this.threadId = threadId
        this.epoch = epoch; this.requestId = requestId; this.bindingDigest = bindingDigest
        this.inputDigest = inputDigest
        let ownedCancellation = CancellationSource(parent: Some(cancellation))
        this.localCancellation = ownedCancellation; this.cancellation = ownedCancellation.token
        this.current = Some(current); this.cleanup = Some(cleanup); this.ownedTaskHandler = ownedTaskHandler
    }
    public func check(): Result<Unit> {
        let unavailable = { => closeLock.lock(); try { closed } finally { closeLock.unlock() } }()
        if (unavailable) { return providerFailure(AgentErrorKind.PermissionDenied,
            "model.provider_dispatch_closed", AttemptFailureKind.ProviderProtocolError) }
        if (cancellation.isCancelled()) { return providerFailure(AgentErrorKind.Cancelled,
            "model.provider_cancelled", AttemptFailureKind.UserCancelled) }
        closeLock.lock()
        try {
            if (closed || current.isNone()) { return providerFailure(AgentErrorKind.PermissionDenied,
                "model.provider_dispatch_closed", AttemptFailureKind.ProviderProtocolError) }
            if (callbackFrames159 == Int64.Max) { return providerFailure(AgentErrorKind.BudgetExceeded,
                "model.provider_dispatch_capacity", AttemptFailureKind.ProviderProtocolError) }
            callbackFrames159++
        } finally { closeLock.unlock() }
        try { invokeCurrentFrame159() } finally { finishCallbackFrame159() }
    }
    public func close(): Unit {
        let release = { => closeLock.lock(); try { if (closed) { false } else { closed = true; true } }
            finally { closeLock.unlock() } }()
        if (release) {
            // A throwing cleanup retains its original callbacks and payment.
            // No finally-only marker converts an unknown error into retirement.
            invokeCleanupFrame159()
            closeLock.lock()
            try { cleanupReturned159 = true; clearReturnedCallbacksLocked159() }
            finally { closeLock.unlock() }
        }
    }
    // Host ModelPort cancellation joins the exact object issued by its gate.
    // No identity-copying wrapper or plugin-provided cancellation authority.
    public func cancel(): Bool { localCancellation.cancel() }
    // Host composition binds this to the already claimed Run/epoch. A
    // descriptive dispatch with a successful current() callback is not enough.
    public func ownResourceTask(name: String, task: Future<Unit>): Result<ModelProviderTaskJoin> {
        match (check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (name == "" || name.size > 1024 || name.contains("\u{0}")) {
            return providerFailure(AgentErrorKind.InvalidInput, "model.resource_task_name", AttemptFailureKind.ProviderProtocolError)
        }
        closeLock.lock()
        try {
            if (closed || ownedTaskHandler.isNone()) { return providerFailure(AgentErrorKind.PermissionDenied,
                "model.resource_task_unowned", AttemptFailureKind.ProviderProtocolError) }
            if (callbackFrames159 == Int64.Max) { return providerFailure(AgentErrorKind.BudgetExceeded,
                "model.provider_dispatch_capacity", AttemptFailureKind.ProviderProtocolError) }
            callbackFrames159++
        } finally { closeLock.unlock() }
        try { invokeTaskFrame159(name, task) } finally { finishCallbackFrame159() }
    }
    private func invokeCurrentFrame159(): Result<Unit> {
        let selected = try { closeLock.lock(); current } finally { closeLock.unlock() }
        // This helper owns the only temporary reference copied from the field.
        // The caller decrements the borrow only after this entire frame returns.
        try { selected.getOrThrow()() } catch (_: Exception) {
            providerFailure(AgentErrorKind.PermissionDenied, "model.provider_authority_invalid",
                AttemptFailureKind.ProviderProtocolError)
        }
    }
    private func invokeTaskFrame159(name: String, task: Future<Unit>): Result<ModelProviderTaskJoin> {
        let selected = try { closeLock.lock(); ownedTaskHandler } finally { closeLock.unlock() }
        selected.getOrThrow()(name, task)
    }
    private func clearReturnedCallbacksLocked159(): Unit {
        if (!closed || !cleanupReturned159 || callbackFrames159 != 0) { return }
        current = None<() -> Result<Unit>>
        cleanup = None<() -> Unit>
        ownedTaskHandler = None<(String, Future<Unit>) -> Result<ModelProviderTaskJoin>>
    }
    private func finishCallbackFrame159(): Unit {
        closeLock.lock()
        try {
            if (callbackFrames159 <= 0) { throw IllegalStateException("provider callback borrow underflow") }
            callbackFrames159--
            clearReturnedCallbacksLocked159()
        } finally { closeLock.unlock() }
    }
    private func invokeCleanupFrame159(): Unit {
        let selected = try { closeLock.lock(); cleanup } finally { closeLock.unlock() }
        try { let _ = localCancellation.cancel() }
        finally {
            try { match (selected) { case Some(action) => action(); case None => () } }
            finally { localCancellation.close() }
        }
    }
    // DATA observation only: all copied callback frames have physically
    // returned and the dispatch no longer retains the request observation.
    // It does not prove that public identity strings, transport resources,
    // a caller's request, or a model reply have retired.
    public func inputCallbacksReturned159(): Bool {
        closeLock.lock()
        try { closed && cleanupReturned159 && callbackFrames159 == 0 &&
            current.isNone() && cleanup.isNone() && ownedTaskHandler.isNone() }
        finally { closeLock.unlock() }
    }
    public func identity(): AgentValue { objectValue([
        ValueField("attempt_id", textValue(attemptId.value)), ValueField("run_id", textValue(runId.value)),
        ValueField("thread_id", textValue(threadId.value)), ValueField("epoch", integerValue(epoch)),
        ValueField("request_id", textValue(requestId)), ValueField("binding_digest", textValue(bindingDigest)),
        ValueField("input_digest", textValue(inputDigest))
    ]) }
}

public interface ModelProviderDispatchGate {
    func open(request: ModelRequest, binding: ModelProviderBinding,
        snapshot: String): Result<ModelProviderDispatch>
}

// A concrete gate may opt into request-return accounting only after its
// original durable-read closures and every copied check/task helper returned.
// This is not an authority substitute for open/check or a resource ACK.
public interface ModelProviderReturningInputGate159 {
    func inputObservationReturned159(dispatch: ModelProviderDispatch): Bool
}

public type ModelProviderFrameSink = (AgentValue) -> Result<Unit>

// A transport is responsible for the existing sandbox/HTTP owner and cleanup
// ACK. It may not resolve credentials or open sockets before dispatch.check.
// Return only after callbacks quiesce; late callbacks are rejected regardless.
public interface ModelProviderEndpoint {
    // Host-selected framing allowance, never taken from an execution frame.
    func payloadLimits(dispatch: ModelProviderDispatch): ?ServicePayloadLimits { None }
    func execute(input: AgentValue, dispatch: ModelProviderDispatch,
        frames: ModelProviderFrameSink): Result<Unit>
    func cancel(requestId: String): Result<Unit>
}

public class MissingModelProviderPort <: ModelPort {
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        Result.Err(AgentError(AgentErrorKind.Configuration, "model.provider_plugin_missing",
            "install and authorize a ModelProvider contribution before inference"))
    }
}

func providerIdentifier(value: String): Unit {
    if (value == "" || value.size > 256 || value.trimAscii() != value ||
        value.contains("\n") || value.contains("\r") || value.contains("\u{0}")) {
        throw IllegalArgumentException("invalid provider identity")
    }
}
func providerDigest(value: String): Bool {
    if (value.size != 64) { return false }
    for (r in value.runes()) { if (!((r >= r'0' && r <= r'9') || (r >= r'a' && r <= r'f'))) { return false } }
    true
}
func providerFailure<T>(kind: AgentErrorKind, code: String, failure: AttemptFailureKind): Result<T> {
    Result.Err(AgentError(kind, code, "model provider boundary rejected the exchange",
        retryable: false, fallbackAllowed: false, attemptFailure: Some(AttemptFailure(failure))))
}
func providerText(value: AgentValue, name: String): String {
    let item = providerField(value, name)
    if (item.unifiedKind != ValueKind.Text) { throw IllegalArgumentException("expected provider text") }
    item.text
}
func providerInt(value: AgentValue, name: String): Int64 {
    let item = providerField(value, name)
    if (item.unifiedKind != ValueKind.Number) { throw IllegalArgumentException("expected provider integer") }
    Int64.parse(item.asNumberText())
}
func providerBool(value: AgentValue, name: String): Bool {
    let item = providerField(value, name)
    if (item.unifiedKind != ValueKind.Boolean) { throw IllegalArgumentException("expected provider boolean") }
    item.asBool()
}
func providerField(value: AgentValue, name: String): AgentValue {
    match (value.field(name)) { case Some(item) => item
        case None => throw IllegalArgumentException("missing provider field") }
}
func providerExact(value: AgentValue, names: Array<String>): Unit {
    if (value.unifiedKind != ValueKind.Object || value.fields.size != names.size) {
        throw IllegalArgumentException("invalid provider object shape")
    }
    let seen = HashSet<String>()
    for (field in value.fields) {
        if (!names.contains(field.name) || seen.contains(field.name)) {
            throw IllegalArgumentException("unknown or duplicate provider field")
        }
        seen.add(field.name)
    }
}
