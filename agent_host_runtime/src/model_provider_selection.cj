package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import model_provider_runtime.*
import std.collection.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

class HostSelectedModelProvider {
    let grant: HostInstalledModelProviderGrant
    let factory: HostInstalledModelChannelFactory
    let endpoint: NativeModelProviderEndpoint
    let port: PluginModelPort
    init(grant: HostInstalledModelProviderGrant, factory: HostInstalledModelChannelFactory,
        endpoint: NativeModelProviderEndpoint, port: PluginModelPort) {
        this.grant = grant; this.factory = factory; this.endpoint = endpoint; this.port = port
    }
}

// Generic selection by exact contribution and explicit neutral capabilities.
// Catalog prices/UI remain independent; protocol lowering belongs to the package.
// The cache retains owned adapters/cleanup handles, not another plugin registry.
public open class HostInstalledModelPort <: ModelPort & ReturningModelInputPort159 & ReturningModelTranscriptPort159 {
    private let host: HostJavaScriptPluginHost
    private let settingsRoot: String
    private let database: SqliteDatabase
    private let runtimes: ThreadRuntimeRegistry
    private let processes: HostModelProcessLauncher
    private let artifacts: HostArtifactStore
    private let lock = Mutex()
    private var selected: ?HashMap<String, HostSelectedModelProvider> = Some(HashMap<String, HostSelectedModelProvider>())
    private var mappedModels: ?HashSet<String> = Some(HashSet<String>())
    private var modelFrames159: Int64 = 0
    private var modelClosing159 = false
    private var modelRetiring159 = false
    private var modelClosed159 = false
    private var modelIdentities159: ?HostModelSelectionIdentity159 = None<HostModelSelectionIdentity159>
    private let migrationDiagnostic: ?HostModelMigrationDiagnostic

    public init(host: HostJavaScriptPluginHost, settingsRoot: String, database: SqliteDatabase,
        runtimes: ThreadRuntimeRegistry, processes: HostModelProcessLauncher, artifacts: HostArtifactStore,
        migrationDiagnostic!: ?HostModelMigrationDiagnostic = None) {
        this.host = host; this.settingsRoot = settingsRoot; this.database = database; this.runtimes = runtimes
        this.processes = processes; this.artifacts = artifacts; this.migrationDiagnostic = migrationDiagnostic
    }
    public func validatePolicySnapshot(model: String, snapshot: ?ModelExecutionCapabilitiesSnapshot): Result<Unit> {
        if (!beginModelFrame159()) { return modelInputPending159<Unit>() }
        try { validatePolicySnapshotFrame159(model, snapshot) } finally { endModelFrame159() }
    }
    private func validatePolicySnapshotFrame159(model: String, snapshot: ?ModelExecutionCapabilitiesSnapshot): Result<Unit> {
        let loaded = match (loadHostModelConfiguration(settingsRoot, model)) {
            case Result.Err(error) =>
                if (error.code == "model.provider_not_configured") {
                    match (unmapped(model)) { case Result.Err(missing) => return Result.Err(missing); case _ => () }
                }
                return Result.Err(error)
            case Result.Ok(value) => value
        }
        // These are mounted metadata lookups only. Do not choose/arm a provider,
        // inspect credential values, launch a worker or prepare HTTP here.
        let generation = host.instanceGeneration(loaded.namespace)
        let descriptor = match (host.servicePackageData81(loaded.namespace, generation)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (descriptor.contentDigest != loaded.packageDigest) { return modelInstalledDenied() }
        match (host.modelProviderDeclaration(loaded.namespace, generation,
            httpIntentText(loaded.mapping(), "contribution"))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (snapshot) {
            case None => ()
            case Some(value) =>
                let expected = ModelExecutionCapabilitiesSnapshot(model, loaded.policy.capabilities.thinking,
                    loaded.policy.capabilities.maxOutputTokens, endpointMaxOutputTokens: loaded.policy.endpointMaxOutput,
                    configurationDigest: loaded.policy.configurationDigest)
                // Recompute from actual fields: public array contents must not
                // be trusted merely because an old cached fingerprint matches.
                let payload = canonicalModelCapabilitySnapshotPayload(value.snapshotSchemaVersion, value.modelId,
                    value.thinking, value.modelMaxOutputTokens, value.endpointMaxOutputTokens,
                    configurationDigest: value.configurationDigest)
                if (value.modelId != model || value.configurationDigest != loaded.policy.configurationDigest ||
                    value.capabilityFingerprint != expected.capabilityFingerprint ||
                    modelPolicySha256Text(payload) != expected.capabilityFingerprint) {
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, "model.provider_input_invalid",
                        "Frozen model policy no longer matches the installed configuration"))
                }
        }
        // Dispatch still independently checks the current package, grant,
        // configuration, exact request and claimed Attempt at the I/O boundary.
        Result.Ok(())
    }
    private func beginModelFrame159(allowClosing!: Bool = false): Bool {
        lock.lock(); try {
            if (modelClosed159 || modelRetiring159 || (modelClosing159 && !allowClosing)) { return false }
            modelFrames159++; true
        } finally { lock.unlock() }
    }
    private func endModelFrame159(): Unit {
        lock.lock(); try { modelFrames159-- } finally { lock.unlock() }
    }
    private func modelInputPending159<T>(): Result<T> {
        Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "model.selection_cache_pending",
            "Model selection still has active consumers or retained provider observations"))
    }
    public func closeModelInputData159(): Result<Unit> {
        lock.lock()
        try {
            if (modelClosed159) { return Result.Ok(()) }
            modelClosing159 = true
            if (modelFrames159 != 0 || modelRetiring159) { return modelInputPending159<Unit>() }
            modelRetiring159 = true
        } finally { lock.unlock() }
        try {
            while (true) {
                match (retireSelectedProviderFrame159()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(more) => if (!more) { break }
                }
            }
            clearSelectionBackingsFrame159()
            while (true) {
                // The entire clearing helper drops node/string/cache aliases
                // before this separate caller closes the original-bank share.
                let paid = clearSelectionIdentityFrame159()
                match (paid) { case Some(value) => value.close(); case None => break }
            }
            lock.lock(); try { modelClosed159 = true } finally { lock.unlock() }
            Result.Ok(())
        } finally { lock.lock(); try { modelRetiring159 = false } finally { lock.unlock() } }
    }
    private func retireSelectedProviderFrame159(): Result<Bool> {
        let picked = { => lock.lock(); try {
            for ((_, value) in selected.getOrThrow()) { return Some(value) }
            None<HostSelectedModelProvider>
        } finally { lock.unlock() } }()
        let value = match (picked) { case Some(actual) => actual; case None => return Result.Ok(false) }
        // None of these calls holds the selection lock. They may only retry
        // already-closing resource cleanup, never inference or a Tool effect.
        match (value.endpoint.retryCleanup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (value.factory.retryCleanup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!value.endpoint.allInputReferencesReturned159() || !value.factory.allInputReferencesReturned159()) {
            return modelInputPending159<Bool>() }
        match (value.port.retireInputCache159()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        value.grant.close()
        lock.lock()
        try { selected.getOrThrow().remove(value.grant.binding.digest) } finally { lock.unlock() }
        Result.Ok(true)
    }
    private func clearSelectionBackingsFrame159(): Unit {
        lock.lock()
        try {
            selected = None<HashMap<String, HostSelectedModelProvider>>
            mappedModels = None<HashSet<String>>
        } finally { lock.unlock() }
    }
    private func clearSelectionIdentityFrame159(): ?LogicalJsonOwnerReservation {
        lock.lock()
        try {
            match (modelIdentities159) {
                case None => None<LogicalJsonOwnerReservation>
                case Some(value) =>
                    modelIdentities159 = value.next159
                    value.clearCacheReferences159()
            }
        } finally { lock.unlock() }
    }

    private func choose(model: String): Result<?HostSelectedModelProvider> {
        // Only an explicitly installed and currently granted contribution can
        // dispatch production inference. Legacy config remains metadata and
        // cannot authorize the old in-process wire adapter.
        let loaded = match (loadHostModelConfiguration(settingsRoot, model)) {
            case Result.Err(error) =>
                if (error.code == "model.provider_not_configured") { return unmapped(model) }
                return Result.Err(error)
            case Result.Ok(value) => value
        }
        try {
            let value = loaded.mapping()
            let namespace = loaded.namespace; let packageDigest = loaded.packageDigest
            let generation = host.instanceGeneration(namespace)
            let descriptor = match (host.servicePackageData81(namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (descriptor.contentDigest != packageDigest) { return modelInstalledDenied() }
            // Both transcript preparation and execution reach this producer.
            // Charge/copy before either long-lived cache can retain the name.
            // Payment refusal leaves those caches untouched; it grants no I/O.
            let selectedModel159 = copiedSelectionName159(model, descriptor)
            let instance = match (host.serviceInstanceIdentity(namespace, generation)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let configuration = match (loadHostPluginHttpConfiguration(settingsRoot, namespace, packageDigest)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (configuration.digest != loaded.policy.configurationDigest) { return modelInstalledDenied() }
            let capabilities = loaded.policy.capabilities
            let refs = match (hostPluginHttpStringList(value.field("credential_refs").getOrThrow(), 16)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(values) => values }
            let binding = ModelProviderBinding(namespace, packageDigest, configuration.digest, instance,
                httpIntentText(value, "contribution"), selectedModel159, httpIntentText(value, "wire_model"),
                ModelExecutionCapabilitiesSnapshot(selectedModel159, capabilities.thinking, capabilities.maxOutputTokens,
                    endpointMaxOutputTokens: loaded.policy.endpointMaxOutput,
                    configurationDigest: loaded.policy.configurationDigest),
                configuration: value.field("configuration").getOrThrow(), credentialRefs: refs,
                supportsImages: capabilities.vision, supportsTools: capabilities.toolCalling,
                supportsStructuredOutput: capabilities.structuredOutput, supportsParallelTools: capabilities.parallelToolCalling,
                supportsPromptCache: capabilities.promptCache, providerId: httpIntentText(value, "provider_id"),
                contextWindowTokens: Some(capabilities.contextWindowTokens))
            // Do not hold this lock during launch, provider execution or cleanup.
            // Selection itself performs bounded metadata validation only.
            lock.lock()
            try {
                match (selected.getOrThrow().get(binding.digest)) { case Some(found) => return Result.Ok(Some(found)); case None => () }
                if (selected.getOrThrow().size >= 64) { return modelInstalledDenied() }
                let grant = HostInstalledModelProviderGrant(host, generation, descriptor, configuration, binding)
                match (grant.arm()) { case Result.Err(error) => grant.close(); return Result.Err(error); case Result.Ok(_) => () }
                let gate = HostModelProviderDispatchGate(SqliteModelProviderDispatchReader(database), runtimes, binding,
                    HostInstalledModelCurrentAuthority(grant))
                let factory = HostInstalledModelChannelFactory(grant, gate, processes, artifacts)
                let endpoint = NativeModelProviderEndpoint(factory)
                let picked = HostSelectedModelProvider(grant, factory, endpoint, PluginModelPort(binding, gate, endpoint))
                selected.getOrThrow()[binding.digest] = picked
                Result.Ok(Some(picked))
            } finally { lock.unlock() }
        } catch (_: Exception) { modelInstalledDenied() }
    }
    private func unmapped(model: String): Result<?HostSelectedModelProvider> {
        lock.lock(); try {
            if (mappedModels.getOrThrow().contains(model)) { return modelInstalledDenied() }
            match (migrationDiagnostic) {
                case Some(diagnostic) => match (diagnostic.diagnose(model)) {
                    case Some(error) => return Result.Err(error); case None => () }
                case None => ()
            }
            Result.Err(AgentError(AgentErrorKind.Configuration, "model.provider_not_configured",
                "Select an installed ModelProvider contribution in plugins/services.json; legacy profiles do not grant inference"))
        } finally { lock.unlock() }
    }
    public func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        if (!beginModelFrame159()) { return None<String> }
        // The installed selection's concrete PluginModelPort owns the codec.
        try { transcriptSnapshotReturningFrame159(request, loan) } finally { endModelFrame159() }
    }
    private func transcriptSnapshotReturningFrame159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        match (choose(request.model)) {
            case Result.Err(_) => None<String>
            case Result.Ok(None) => loan.returnModelToolsFrame159(); None<String>
            case Result.Ok(Some(value)) => value.port.transcriptSnapshotReturning159(request, loan)
        }
    }
    public func transcriptSnapshot(request: ModelRequest): ?String {
        if (!beginModelFrame159()) { return None<String> }
        try { transcriptSnapshotFrame159(request) } finally { endModelFrame159() }
    }
    private func transcriptSnapshotFrame159(request: ModelRequest): ?String {
        match (choose(request.model)) {
            case Result.Err(_) => None
            case Result.Ok(None) => None
            case Result.Ok(Some(value)) => value.port.transcriptSnapshot(request)
        }
    }
    public func validateTranscriptSnapshot(snapshot: String): Bool {
        if (!beginModelFrame159()) { return false }
        try { validateTranscriptSnapshotFrame159(snapshot) } finally { endModelFrame159() }
    }
    private func validateTranscriptSnapshotFrame159(snapshot: String): Bool {
        try {
            let root = parseUnifiedJson(snapshot, maxBytes: 67108864)
            // Unsupported historic snapshots remain Store-readable; reopening must
            // not reinterpret their bytes through a new adapter or replay them.
            if (!installedModelSnapshotSchema(root)) { return false }
            let neutral = root.field("request").getOrThrow()
            let request = match (modelRequestFromSnapshotValue(neutral, "snapshot-validation")) {
                case Result.Err(_) => return false; case Result.Ok(value) => value }
            match (choose(request.model)) { case Result.Ok(Some(value)) => value.port.validateTranscriptSnapshot(snapshot); case _ => false }
        } catch (_: Exception) { false }
    }
    private func copiedSelectionName159(model: String, descriptor: PluginPackageDescriptor): String {
        lock.lock()
        try {
            var cursor = modelIdentities159
            while (cursor.isSome()) {
                let selected = cursor.getOrThrow()
                if (selected.matches159(model)) { return selected.text159() }
                cursor = selected.next159
            }
            if (!mappedModels.getOrThrow().contains(model) && mappedModels.getOrThrow().size >= 4096) {
                throw IllegalStateException("model identity cache reached its original capacity")
            }
            if (model.size > (Int64.Max - 8192) / 8) { throw IllegalArgumentException("model identity invoice overflow") }
            let paid = hostRegistryDeriveCopiedData159(descriptor, 8192 + 8 * model.size)
            let selected = HostModelSelectionIdentity159(paid)
            selected.next159 = modelIdentities159; modelIdentities159 = Some(selected)
            selected.copy159(model)
            mappedModels.getOrThrow().add(selected.text159())
            selected.text159()
        } finally { lock.unlock() }
    }
    public func executeReturningInput159(request: ModelRequest, events: ModelEventSink,
        funding: ModelInputDataBudget159): ModelInputReturn159 {
        if (!beginModelFrame159()) { return ModelInputReturn159.Held(modelInputPending159<ModelReply>()) }
        try { executeReturningInput159Frame159(request, events, funding) } finally { endModelFrame159() }
    }
    private func executeReturningInput159Frame159(request: ModelRequest, events: ModelEventSink,
        funding: ModelInputDataBudget159): ModelInputReturn159 {
        // choose pays its own persistent identity copy for transcript and
        // execution alike; funding below belongs only to this actual request.
        match (choose(request.model)) {
            case Result.Err(error) => ModelInputReturn159.Held(Result<ModelReply>.Err(error))
            case Result.Ok(None) => ModelInputReturn159.Held(Result<ModelReply>.Err(
                AgentError(AgentErrorKind.Configuration, "model.provider_not_configured",
                    "An installed ModelProvider contribution is required")))
            case Result.Ok(Some(value)) =>
                match (value.endpoint.retryCleanup()) {
                    case Result.Err(error) => return ModelInputReturn159.Held(Result<ModelReply>.Err(error)); case Result.Ok(_) => () }
                match (value.factory.retryCleanup()) {
                    case Result.Err(error) => return ModelInputReturn159.Held(Result<ModelReply>.Err(error)); case Result.Ok(_) => () }
                value.port.executeReturningInput159(request, events, funding)
        }
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        if (!beginModelFrame159()) { return modelInputPending159<ModelReply>() }
        try { executeFrame159(request, events) } finally { endModelFrame159() }
    }
    private func executeFrame159(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        match (choose(request.model)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(None) => Result.Err(AgentError(AgentErrorKind.Configuration, "model.provider_not_configured",
                "An installed ModelProvider contribution is required"))
            case Result.Ok(Some(value)) =>
                // Retry only already-closing owners. Active Attempts remain
                // independent; cleanup failure does not release their capacity.
                match (value.endpoint.retryCleanup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                match (value.factory.retryCleanup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                value.port.execute(request, events)
        }
    }
    public func cancel(requestId: String): Result<Unit> {
        if (!beginModelFrame159(allowClosing: true)) { return modelInputPending159<Unit>() }
        try { cancelFrame159(requestId) } finally { endModelFrame159() }
    }
    private func cancelFrame159(requestId: String): Result<Unit> {
        let values = { => lock.lock(); try {
            let result = ArrayList<HostSelectedModelProvider>(); for ((_, value) in selected.getOrThrow()) { result.add(value) }; result.toArray()
        } finally { lock.unlock() } }()
        var failure: ?AgentError = None
        for (value in values) { match (value.port.cancel(requestId)) { case Result.Err(error) => failure = Some(error); case Result.Ok(_) => () } }
        match (failure) { case Some(error) => Result.Err(error); case None => Result.Ok(()) }
    }
}

// This predicate is intentionally format-only. Exact binding, current grant,
// request and Attempt checks remain in PluginModelPort and the actual gate.
public func installedModelSnapshotSchema(value: AgentValue): Bool {
    httpIntentText(value, "schema") == MODEL_PROVIDER_SNAPSHOT
}
