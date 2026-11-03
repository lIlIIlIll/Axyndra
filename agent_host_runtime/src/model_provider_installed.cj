package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_ports.*
import model_provider_runtime.*
import process4cj as process
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// Selected by Product composition from the existing enabled-descriptor registry
// and services.json. This object describes operator authorization; only the
// DispatchGate's actual claimed Attempt authorizes opening either resource.
class HostInstalledModelProviderGrant {
    let host: HostJavaScriptPluginHost
    let generation: UInt64
    let descriptor: PluginPackageDescriptor
    let configuration: HostPluginHttpConfiguration
    let binding: ModelProviderBinding
    let cancellation = CancellationSource()
    private var registration: ?process.CancellationRegistration = None
    private let lock = Mutex()
    private var credentialRequest: ?String = None
    private var credentialDigest: ?String = None

    init(host: HostJavaScriptPluginHost, generation: UInt64, descriptor: PluginPackageDescriptor,
        configuration: HostPluginHttpConfiguration, binding: ModelProviderBinding) {
        this.host = host; this.generation = generation; this.descriptor = descriptor
        this.configuration = configuration; this.binding = binding
    }
    func arm(): Result<Unit> {
        // A retained cancellation callback needs only the signal, not this
        // grant's model name, descriptor or complete binding graph.
        let signal159 = cancellation
        match (host.observeServiceRevocation(binding.plugin, generation, { => let _ = signal159.cancel() })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => registration = Some(value)
        }
        verifyPackage()
    }
    // Pure frames belong to the already loaded native instance. Keep every
    // live authority/credential check here; re-read package bytes separately
    // at launch, HTTP effects and terminal acceptance boundaries.
    func current(): Result<Unit> {
        match (cancellation.token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (configuration.packageDigest != binding.packageDigest || configuration.digest != binding.configurationDigest) { return modelInstalledDenied() }
        match (configuration.stillCurrent()) { case Result.Err(error) => let _ = cancellation.cancel(); return Result.Err(error); case Result.Ok(_) => () }
        match (host.modelProviderDeclaration(binding.plugin, generation, binding.contribution)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => if (value.protocol != MODEL_PROVIDER_PROTOCOL) { return modelInstalledDenied() }
        }
        match (host.serviceInstanceIdentity(binding.plugin, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => if (value != binding.instanceIdentity) { return modelInstalledDenied() }
        }
        match (host.servicePackageData81(binding.plugin, generation)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => if (value.root != descriptor.root || value.entrypoint != descriptor.entrypoint ||
                value.contentDigest != binding.packageDigest || !value.requestedCapabilities.contains("network.http")) { return modelInstalledDenied() }
        }
        let request = { => lock.lock(); try { credentialRequest } finally { lock.unlock() } }()
        // First secret resolution is after actual DispatchClaimed. Subsequent
        // checks detect rotation and revoke this selected provider identity.
        match (request) { case None => (); case Some(text) =>
            let values = match (configuration.resolveCredentials(parseUnifiedJson(text, maxBytes: 196608))) {
                case Result.Err(error) => let _ = cancellation.cancel(); return Result.Err(error); case Result.Ok(value) => value }
            let digest = modelInstalledCredentialDigest(values)
            let expected = { => lock.lock(); try { credentialDigest } finally { lock.unlock() } }()
            if (expected != Some(digest)) { let _ = cancellation.cancel(); return modelInstalledDenied() }
        }
        Result.Ok(())
    }
    func verifyPackage(): Result<Unit> {
        match (current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let valid = try { match (host.registryPackageMatches81(descriptor.root, digest: Some(binding.packageDigest),
            entrypoint: Some(descriptor.entrypoint))) {
            case Result.Err(_) => false; case Result.Ok(value) => value
        } } catch (_: Exception) { false }
        if (!valid) { let _ = cancellation.cancel(); return modelInstalledDenied() }
        // A concurrent revoke/rotation during the full read still wins.
        current()
    }
    func resolve(request: AgentValue): Result<Array<HostPluginHttpCredentialValue>> {
        match (current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (canonicalAgentValue(request.field("credential_refs").getOrThrow()) !=
            canonicalAgentValue(binding.snapshot().field("credential_refs").getOrThrow())) { return modelInstalledDenied() }
        let projection = match (configuration.modelCredentialProjection(request)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let values = match (configuration.resolveCredentials(projection)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let digest = modelInstalledCredentialDigest(values)
        lock.lock()
        try {
            if (credentialDigest.isSome() && credentialDigest != Some(digest)) { return modelInstalledDenied() }
            credentialDigest = Some(digest); credentialRequest = Some(projection.stringify())
        } finally { lock.unlock() }
        Result.Ok(values)
    }
    func close(): Unit {
        let _ = cancellation.cancel()
        match (registration) { case Some(value) => value.dispose(); case None => () }
        cancellation.close()
    }
}
func modelInstalledCredentialDigest(values: Array<HostPluginHttpCredentialValue>): String {
    // Private comparison only: never a wire, log, artifact or durable field.
    modelPolicySha256Text(canonicalAgentValue(listValue(values.map { value => objectValue([
        ValueField("ref", textValue(value.ref)), ValueField("header", textValue(value.header)),
        ValueField("prefix", textValue(value.headerPrefix)), ValueField("value", textValue(value.secret))]) })))
}
func modelInstalledDenied<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.PermissionDenied, "model.provider_grant_changed",
        "installed ModelProvider or operator authorization is unavailable"))
}

class HostModelAttemptResources {
    let dispatch: ModelProviderDispatch
    let worker: ProcessResourceOwner
    let http: ProcessResourceOwner
    let lock = Mutex()
    var reader: ?HostHttpExchangeReader = None
    var debt: ?ModelProviderResourceDebt = None
    var workerOpening = true
    var opening = false
    var opened = false
    var eof = false
    var closed = false
    var closing = false
    init(dispatch: ModelProviderDispatch) {
        this.dispatch = dispatch
        this.worker = ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "model-worker")
        this.http = ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "model-http")
    }
}

class HostInstalledModelChannelFactory <: ModelProviderChannelFactory {
    private let grant: HostInstalledModelProviderGrant
    private let gate: HostModelProviderDispatchGate
    private let port: HostModelProcessLauncher
    private let artifacts: HostArtifactStore
    private let lock = Mutex()
    private let entries = HashMap<String, HostModelAttemptResources>()
    init(grant: HostInstalledModelProviderGrant, gate: HostModelProviderDispatchGate, port: HostModelProcessLauncher, artifacts: HostArtifactStore) {
        this.grant = grant; this.gate = gate; this.port = port; this.artifacts = artifacts
    }
    private func entry(dispatch: ModelProviderDispatch): Result<HostModelAttemptResources> {
        lock.lock()
        try { match (entries.get(dispatch.attemptId.value)) {
            case Some(value) => if (refEq(value.dispatch, dispatch)) { Result.Ok(value) } else { modelInstalledDenied() }
            case None => modelInstalledDenied()
        } } finally { lock.unlock() }
    }
    public func payloadLimits(dispatch: ModelProviderDispatch): ?ServicePayloadLimits {
        let _ = dispatch
        grant.configuration.payloadLimits
    }
    public func open(dispatch: ModelProviderDispatch): Result<ProcessChannel> {
        match (grant.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let owned = HostModelAttemptResources(dispatch)
        match (gate.verifyProcessOwner(dispatch, owned.worker)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (entries.contains(dispatch.attemptId.value) || entries.size >= 8) { return modelInstalledDenied() }
            entries[dispatch.attemptId.value] = owned
        } finally { lock.unlock() }
        let debt = ModelProviderResourceDebt(dispatch, { => releaseResources(owned) })
        owned.debt = Some(debt)
        match (debt.admit()) {
            case Result.Err(error) =>
                owned.lock.lock(); try { owned.workerOpening = false } finally { owned.lock.unlock() }
                lock.lock(); try { entries.remove(dispatch.attemptId.value) } finally { lock.unlock() }
                return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let result = try {
            let request = ProcessRequest(grant.descriptor.root + "/" + grant.descriptor.entrypoint,
                resourceOwner: Some(owned.worker), workingDirectory: grant.descriptor.root,
                filesystemRoot: grant.descriptor.root, sandboxMode: ProcessSandboxMode.IsolatedReadOnly,
                timeoutMillis: 0, networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)),
                processLimits: ExecutionResourceLimits(maxOutputBytes: 67108864))
            if (debt.isClosing()) { modelInstalledDenied<ProcessChannel>() }
            else {
                match (grant.verifyPackage()) {
                    case Result.Err(error) => Result<ProcessChannel>.Err(error)
                    case Result.Ok(_) => port.openClaimedModelChannel(request, HostInstalledModelProcessLaunchClaim(dispatch, gate), 67108864)
                }
            }
        } catch (_: Exception) {
            Result<ProcessChannel>.Err(AgentError(AgentErrorKind.Transport, "model.provider_launch_failed", "model worker launch failed"))
        } finally { owned.lock.lock(); try { owned.workerOpening = false } finally { owned.lock.unlock() } }
        if (result.isError()) { let _ = closeResources(dispatch); return result }
        match (grant.verifyPackage()) {
            case Result.Err(error) => let _ = closeResources(dispatch); return Result.Err(error)
            case Result.Ok(_) => ()
        }
        match (gate.verifyProcessOwner(dispatch, owned.worker)) {
            case Result.Err(error) => let _ = closeResources(dispatch); return Result.Err(error)
            case Result.Ok(_) => ()
        }
        result
    }
    public func validateCompletion(dispatch: ModelProviderDispatch): Result<Unit> {
        match (gate.verifyProcessOwner(dispatch, ProcessResourceOwner.ModelAttempt(dispatch.attemptId, "model-worker"))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        match (grant.verifyPackage()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        dispatch.check()
    }
    public func request(dispatch: ModelProviderDispatch, action: String, arguments: AgentValue): Result<AgentValue> {
        let owned = match (entry(dispatch)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (gate.verifyProcessOwner(dispatch, owned.http)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (grant.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (action == "open") { return openHttp(owned, arguments) }
        if (!httpIntentExactFields(arguments, [])) { return modelInstalledDenied() }
        let reader: ?HostHttpExchangeReader = { => owned.lock.lock(); try {
            if (owned.closing || owned.closed || owned.opening) { Option<HostHttpExchangeReader>.None } else { owned.reader }
        } finally { owned.lock.unlock() } }()
        if (reader.isNone()) { return modelInstalledDenied() }
        let active = reader.getOrThrow()
        if (action == "head") {
            let value = match (active.pollHead()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            return Result.Ok(match (value) { case None => nullValue(); case Some(head) => objectValue([
                ValueField("status", integerValue(head.status)), ValueField("content_type", textValue(head.contentType)),
                ValueField("retry_after", textValue(head.retryAfter))]) })
        }
        if (action == "read") {
            let value = match (active.readBody(16384)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (value.eof) { owned.lock.lock(); try { owned.eof = true } finally { owned.lock.unlock() } }
            return Result.Ok(objectValue([ValueField("bytes_hex", textValue(modelProviderHex(value.bytes))), ValueField("eof", boolValue(value.eof))]))
        }
        if (action == "close") {
            let eof = { => owned.lock.lock(); try { owned.eof } finally { owned.lock.unlock() } }()
            if (!eof) { let _ = active.close(); return modelInstalledDenied() }
            match (grant.verifyPackage()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (active.close()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (!active.closeAcknowledged()) { return modelInstalledDenied() }
            owned.lock.lock(); try { owned.closed = true } finally { owned.lock.unlock() }
            return Result.Ok(objectValue([ValueField("closed", boolValue(true))]))
        }
        modelInstalledDenied()
    }
    private func openHttp(owned: HostModelAttemptResources, arguments: AgentValue): Result<AgentValue> {
        if (!httpIntentExactFields(arguments, ["request"])) { return modelInstalledDenied() }
        let request = arguments.field("request").getOrThrow()
        // Only the provider's one inference POST is supported in this adapter.
        // Operator exact URL/method/ref grants still decide the destination.
        if (httpIntentText(request, "method") != "POST" || request.field("body_payload").isSome()) { return modelInstalledDenied() }
        let policy = match (grant.configuration.bindModelRequest(request)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let credentials = match (grant.resolve(request)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        var launchRequest = request
        var launchBody: ?Array<Byte> = None
        let maximum = match (grant.configuration.payloadLimits) { case Some(value) => value.maxWriteBytes; case None => 65536 }
        if (httpIntentText(request, "body_hex").size > 131072) {
            let payload = match (stageHostModelPayload(artifacts, owned.dispatch, gate, httpIntentText(request, "body_hex"), maximum)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            launchBody = match (readHostModelPayload(artifacts, owned.dispatch, gate, payload, maximum)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => Some(value) }
            let fields = ArrayList<ValueField>()
            for (field in request.fields where field.name != "body_hex") { fields.add(field) }
            fields.add(ValueField("body_payload", payload)); launchRequest = objectValue(fields.toArray())
        }
        owned.lock.lock()
        try {
            if (owned.opened || owned.opening || owned.closing) { return modelInstalledDenied() }
            owned.opened = true; owned.opening = true
        } finally { owned.lock.unlock() }
        try {
            // Large body staging is complete. Revalidate the installed bytes
            // immediately before the actual host-owned HTTP effect.
            match (grant.verifyPackage()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            match (gate.verifyProcessOwner(owned.dispatch, owned.http)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            let reader = match (port.openClaimedModelHttpExchange(owned.http, HostInstalledModelProcessLaunchClaim(owned.dispatch, gate), launchRequest,
                grant.descriptor.root, policy, credentials, ExecutionResourceLimits(maxOutputBytes: modelHttpWireMaximum(HOST_HTTP_STREAM_PAYLOAD_RESPONSE_MAX_BYTES) + 40960),
                payloadBody: launchBody, expanded: true)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            var unavailable = false
            owned.lock.lock(); try { owned.reader = Some(reader); unavailable = owned.closing } finally { owned.lock.unlock() }
            if (unavailable) { let _ = reader.close(); return modelInstalledDenied() }
            match (grant.verifyPackage()) { case Result.Err(error) => let _ = reader.close(); return Result.Err(error); case Result.Ok(_) => () }
            match (owned.dispatch.check()) { case Result.Err(error) => let _ = reader.close(); return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(objectValue([ValueField("opened", boolValue(true))]))
        } finally { owned.lock.lock(); try { owned.opening = false } finally { owned.lock.unlock() } }
    }
    public func cancelResources(dispatch: ModelProviderDispatch): Result<Unit> {
        let owned = match (entry(dispatch)) { case Result.Err(_) => return Result.Ok(()); case Result.Ok(value) => value }
        owned.lock.lock(); try { owned.closing = true } finally { owned.lock.unlock() }
        match (owned.debt) { case Some(debt) => debt.requestClose(); case None => () }
        let first = port.cancelResource(owned.worker); let second = port.cancelResource(owned.http)
        match (first) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; second
    }
    public func closeResources(dispatch: ModelProviderDispatch): Result<Unit> {
        let owned = match (entry(dispatch)) { case Result.Err(_) => return Result.Ok(()); case Result.Ok(value) => value }
        let result = closeOwnedResourceFrames159(owned)
        if (result.isOk()) {
            // The whole debt/Future helper returned and dropped its copies of
            // the debt before removing this factory's actual resource owner.
            lock.lock(); try { entries.remove(dispatch.attemptId.value) } finally { lock.unlock() }
        }
        result
    }
    private func closeOwnedResourceFrames159(owned: HostModelAttemptResources): Result<Unit> {
        let observation = { => owned.lock.lock(); try { (owned.debt, owned.closed) } finally { owned.lock.unlock() } }()
        let actual = match (observation[0]) {
            case Some(value) => value
            case None => return if (observation[1]) { Result.Ok(()) }
                else { Result<Unit>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "model.resource_task_unowned", "model resource task is unavailable")) }
        }
        match (actual.close()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!actual.inputResourceReferencesReturned159()) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "model.provider_cleanup_pending", "model resource cleanup observers are still active"))
        }
        owned.lock.lock()
        try {
            if (owned.workerOpening || owned.opening) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "model.provider_cleanup_pending", "model resource producer is still active"))
            }
            // The actual physical owner already acknowledged both resources.
            // These are this factory's private references, not public aliases.
            owned.reader = None<HostHttpExchangeReader>
            owned.debt = None<ModelProviderResourceDebt>
            owned.closed = true
        } finally { owned.lock.unlock() }
        Result.Ok(())
    }
    private func releaseResources(owned: HostModelAttemptResources): Result<Unit> {
        let _ = cancelResources(owned.dispatch)
        let pending = { => owned.lock.lock(); try { owned.workerOpening || owned.opening } finally { owned.lock.unlock() } }()
        let first = port.closeChannelResource(owned.worker); let second = port.closeChannelResource(owned.http)
        if (pending || first.isError() || second.isError() || port.hasActiveResource(owned.worker) || port.hasActiveResource(owned.http)) {
            return Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "model.provider_cleanup_pending", "model resources have not acknowledged cleanup"))
        }
        Result.Ok(())
    }
    func allInputReferencesReturned159(): Bool {
        lock.lock(); try { entries.isEmpty() } finally { lock.unlock() }
    }
    func retryCleanup(): Result<Unit> {
        let current = { => lock.lock(); try {
            let result = ArrayList<HostModelAttemptResources>(); for ((_, value) in entries) { result.add(value) }; result.toArray()
        } finally { lock.unlock() } }()
        var failure: ?AgentError = None
        for (entry in current) {
            let closing = { => entry.lock.lock(); try { entry.closing } finally { entry.lock.unlock() } }()
            if (closing) { match (closeResources(entry.dispatch)) { case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () } }
        }
        match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
    }
}
func modelProviderHex(bytes: Array<Byte>): String {
    let alphabet = "0123456789abcdef".toArray(); let result = ArrayList<Byte>()
    for (byte in bytes) { result.add(alphabet[Int64(byte / 16u8)]); result.add(alphabet[Int64(byte % 16u8)]) }
    String.fromUtf8(result.toArray())
}
