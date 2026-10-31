package agent_product

import agent_plugin_registry.*

import agent_host_runtime
import agent_host_runtime.HostInstalledModelPort

import agent_plugin_registry.pluginScopeEquals

import agent_plugin_registry.{pluginImportError, pluginScopeEquals}

import yjson_support.*

import yjson.*

import agent_client.*
import agent_app_protocol.*
import agent_core.*
import agent_domain.*
import agent_domain as domain
import agent_ports.*
import agent_runtime.*
import agent_store.*
import model_fixture_runtime.FixtureModelPort
import persistence_runtime.*
import run_control.*
import tool_runtime.*
import sandbox4cj.*
import std.collection.*
import std.env.*
import std.convert.*
import std.fs.*
import std.io.*
import std.sync.*
import agent_extension_runtime.*
import std.time.*
import process4cj.*


let MODEL_COMPACTION_OVERVIEW_MARKER = "\nmodel-generated overview (non-authoritative):\n"

public class ProductConfig {
    public let settingsRoot: String
    public let stateRoot: String
    public let workspaceRoot: String
    public let fixture: Bool
    public let unsafeDirectLaunchForTests: Bool
    public let approvalMode: ApprovalMode
    public let approvalRoutingModeOverride: ?ApprovalRoutingMode
    public let modelOverride: String
    public let shellNetworkModeOverride: ?ShellNetworkMode
    public let asyncEnabled: Bool
    public let wallTimeoutMillis: Int64
    public let modelAttemptRecovery: ModelAttemptRecoveryPolicy
    public let modelStreamFaultProfile: ?ModelStreamFaultProfile
    public let compactionOverride: ?ProductCompactionSettings
    public let startupMode: ProductStartupMode
    public let distributionRoot: String
    public let extensionSignatureVerifier: ?ExtensionPackageSignatureVerifier
    public let fixtureTransactionCommitMonitor: ?(SqliteTransaction)->Unit
    public let fixtureDerivedSettlementFailureObserver: ?(String, String, String, String) -> Unit

    public init(
        settingsRoot!: String = defaultProductHome(),
        stateRoot!: String = defaultStateRoot(),
        workspaceRoot!: String = ".",
        fixture!: Bool = false,
        unsafeDirectLaunchForTests!: Bool = false,
        approvalMode!: ApprovalMode = ApprovalMode.AlwaysAsk,
        approvalRoutingModeOverride!: ?ApprovalRoutingMode = None,
        modelOverride!: String = "",
        shellNetworkModeOverride!: ?ShellNetworkMode = None,
        asyncEnabled!: Bool = true,
        wallTimeoutMillis!: Int64 = 0,
        modelAttemptRecovery!: ModelAttemptRecoveryPolicy = ModelAttemptRecoveryPolicy(),
        modelStreamFaultProfile!: ?ModelStreamFaultProfile = None,
        compactionOverride!: ?ProductCompactionSettings = None,
        startupMode!: ProductStartupMode = ProductStartupMode.Full,
        distributionRoot!: String = "",
        extensionSignatureVerifier!: ?ExtensionPackageSignatureVerifier = None,
        fixtureTransactionCommitMonitor!: ?(SqliteTransaction)->Unit = None,
        fixtureDerivedSettlementFailureObserver!: ?(String, String, String, String) -> Unit = None
    ) {
        if (fixtureTransactionCommitMonitor.isSome() && !fixture) {
            throw IllegalArgumentException("transaction commit instrumentation requires explicit fixture assembly") }
        this.fixtureTransactionCommitMonitor = fixtureTransactionCommitMonitor
        if (fixtureDerivedSettlementFailureObserver.isSome() && !fixture) {
            throw IllegalArgumentException("derived settlement instrumentation requires explicit fixture assembly") }
        this.fixtureDerivedSettlementFailureObserver = fixtureDerivedSettlementFailureObserver
        if (unsafeDirectLaunchForTests && !fixture) {
            throw IllegalArgumentException(
                "unsafe direct launch bypass is restricted to explicit fixture configuration"
            )
        }
        this.settingsRoot = settingsRoot
        this.stateRoot = stateRoot
        this.workspaceRoot = workspaceRoot
        this.fixture = fixture
        this.unsafeDirectLaunchForTests = unsafeDirectLaunchForTests
        this.approvalMode = approvalMode
        this.approvalRoutingModeOverride = approvalRoutingModeOverride
        this.modelOverride = modelOverride
        this.shellNetworkModeOverride = shellNetworkModeOverride
        this.asyncEnabled = asyncEnabled
        // 0 = no wall-clock limit (OMP behavior: a stream that keeps emitting
        // tokens is never cut off; only idle hangs are interrupted).
        this.wallTimeoutMillis = wallTimeoutMillis
        this.modelAttemptRecovery = modelAttemptRecovery
        this.modelStreamFaultProfile = modelStreamFaultProfile
        this.compactionOverride = compactionOverride
        this.startupMode = startupMode
        this.distributionRoot = distributionRoot
        this.extensionSignatureVerifier = extensionSignatureVerifier
    }
}

// Local maintenance commands need the product's durable repositories and
// filesystem tools, but must not parse provider catalogs or start configured
// managed plugin children. Full remains the only mode that can execute an agent turn.
public enum ProductStartupMode {
    | Full
    | LocalMaintenance
    | Owner
}

public type ProductIds = agent_host_runtime.HostIds



/** Encode bytes as unwrapped RFC 4648 Base64 for product-owned clipboard/RPC payloads. */
public func productBase64Bytes(bytes: Array<UInt8>): String {
    agent_host_runtime.hostBase64Bytes(bytes)
}

public class ProductClipboardCopy {
    public let osc52Base64: String
    public let nativeCopied: Bool

    public init(osc52Base64: String, nativeCopied: Bool) {
        this.osc52Base64 = osc52Base64
        this.nativeCopied = nativeCopied
    }
}

public class ProductSessionInfo {
    public let id: String
    public let name: String
    public let summary: String
    public let parentId: String
    public let model: String
    public let workMode: String
    public let updatedAt: Int64
    public let archived: Bool

    public init(id: String, name: String, summary: String, parentId: String, model: String, workMode: String,
        updatedAt: Int64, archived!: Bool = false) {
        this.id = id
        this.name = name
        this.summary = summary
        this.parentId = parentId
        this.model = model
        this.workMode = workMode
        this.updatedAt = updatedAt
        this.archived = archived
    }
}

public class ProductContextUsage {
    public let tokens: ?Int64
    public let contextWindow: ?Int64
    public let percent: ?Float64

    public init(
        tokens: ?Int64,
        contextWindow: ?Int64,
        percent: ?Float64
    ) {
        this.tokens = tokens
        this.contextWindow = contextWindow
        this.percent = percent
    }
}
public class ProductCompactionReport {
    public let removedMessages: Int64
    public let beforeTokens: Int64
    public let afterTokens: Int64
    public let summary: String

    public init(
        removedMessages: Int64,
        beforeTokens: Int64,
        afterTokens: Int64,
        summary: String
    ) {
        this.removedMessages = removedMessages
        this.beforeTokens = beforeTokens
        this.afterTokens = afterTokens
        this.summary = summary
    }
}


public class ProductRuntime {
    public let client: AgentClient
    private let contextReadCore: AgentCore
    public let ids: ProductIds
    public let workspace: LocalWorkspace
    public let model: String
    public let settingsRoot: String
    public let stateRoot: String
    public let asyncEnabled: Bool
    public let wallTimeoutMillis: Int64
    public let shellNetworkMode: ShellNetworkMode
    public let sandboxCaBundle: String
    public let approvalSettings: ProductApprovalSettings
    public let compactionSettings: ProductCompactionSettings
    public var theme: String
    private let unsafeDirectLaunchForTests: Bool
    private let persistSettings: Bool
    private let sessionMetadata: SessionMetadataRepository
    private let runs: SqliteRunRepository
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let modelNames: Array<String>
    private let providerProfiles: Array<ProviderProfile>
    private let modelCatalog: Array<ModelCatalogEntry>
    private let processes: LocalProcessPort
    private let codexHookRuntime: ProductCodexHookRuntime
    private let retryControl: ModelRetrySettings
    private let uriRouter: InternalUriRouter
    private let presentationArtifacts: ProductArtifactStore
    private let taskRuntime: ProductTaskRuntime
    private let askRuntime: AskRuntime
    private let pluginRuntime: ProductPluginRuntime
    private let nativeFrontendLock=Mutex()
    private let nativeFrontendInvocations=ArrayList<ProductNativeToolInvocation>()
    private var nativeFrontendsClosing=false
    private let managedPluginServiceLock = Mutex()
    private var managedPluginServices: ?ProductPluginLifecycleManager = None
    private var managedPluginServicesStopping = false
    private let escapedCopyDebtLock = Mutex()
    private var escapedCopyDebtClosed = false
    private var fixtureManagedCleanupObserver:?agent_host_runtime.HostManagedChannelCleanupObserver=None
    private let compactionSummarizer: CompactionSummarizer
    private let approvalReviewer: ApprovalReviewer
    // Fixture-mode model probe: contracts observe the actual request
    // parameters (e.g. plan mode forces High thinking).
    public let fixtureProbe: ?FixtureModelPort
    public let vnext: ProductVnextControl
    private let vnextDatabase: SqliteDatabase
    private let threadRuntimes: ThreadRuntimeRegistry
    private let installedModelInputOwner159: ?HostInstalledModelPort
    private var configuredModelSettings180: ?ToolContextDescriptor = None<ToolContextDescriptor>
    private var configuredModelSettingsPayment180: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    func freezeConfiguredModelSettings180(profile: ?ModelStreamFaultProfile, recovery: ModelAttemptRecoveryPolicy): Unit {
        match (profile) {
            case None => ()
            case Some(value) =>
                let paid = match (catalog.reserveRegistryData180(131072)) {
                    case Some(owner) => owner
                    case None => throw OwnedCanonicalDataFailure113(AgentError(AgentErrorKind.RecoveryRequired,
                        "model.controlled_fault_owner_missing", "configured fault profile has no original Registry DATA owner"))
                }
                configuredModelSettingsPayment180 = Some(paid)
                if (value.id.size > Int64.Max - value.partialText.size || value.id.size + value.partialText.size > (Int64.Max - 131072) / 128) {
                    throw LogicalJsonPayloadError("configured fault settings invoice overflow") }
                paid.ensureRetainedPeak(131072 + (value.id.size + value.partialText.size) * 128)
                let counters = ModelStreamFaultCounters180(paid)
                let options = ProductOperatorOptions180(modelStreamFaultProfile: profile,
                    modelAttemptRecovery: recovery, modelFaultCounters180: Some(counters))
                configuredModelSettings180 = Some(ToolContextDescriptor(executionSettings180: options.executionSettingsValue180(),
                    modelFaultCounters180: Some(counters)))
    }
    }
    private func requestToolContext180(options: ?ProductOperatorOptions180, inherited: ?ToolContextDescriptor): ToolContextDescriptor {
        let base = productToolContext(workspace.rootPath(), operatorOptions180: options)
        let source = if (inherited.isSome()) { inherited }
            else if (options.isSome()) { None<ToolContextDescriptor> } else { configuredModelSettings180 }
        match (source) { case Some(value) => ToolContextDescriptor(base, value.executionSettings180,
                modelFaultCounters180: value.modelFaultCounters180)
            case None => base }
    }


    init(
        client: AgentClient,
        contextReadCore: AgentCore,
        ids: ProductIds,
        workspace: LocalWorkspace,
        model: String,
        settingsRoot: String,
        stateRoot: String,
        asyncEnabled: Bool,
        wallTimeoutMillis: Int64,
        shellNetworkMode: ShellNetworkMode,
        sandboxCaBundle: String,
        approvalSettings: ProductApprovalSettings,
        compactionSettings: ProductCompactionSettings,
        theme: String,
        persistSettings: Bool,
        sessionMetadata: SessionMetadataRepository,
        runs: SqliteRunRepository,
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        modelNames: Array<String>,
        providerProfiles: Array<ProviderProfile>,
        modelCatalog: Array<ModelCatalogEntry>,
        processes: LocalProcessPort,
        codexHookRuntime: ProductCodexHookRuntime,
        retryControl: ModelRetrySettings,
        uriRouter: InternalUriRouter,
        presentationArtifacts: ProductArtifactStore,
        taskRuntime: ProductTaskRuntime,
        askRuntime: AskRuntime,
        pluginRuntime: ProductPluginRuntime,
        compactionSummarizer: CompactionSummarizer,
        approvalReviewer: ApprovalReviewer,
        vnextDatabase: SqliteDatabase,
        threadRuntimes: ThreadRuntimeRegistry,
        vnext: ProductVnextControl,
        fixtureProbe!: ?FixtureModelPort = None,
        unsafeDirectLaunchForTests!: Bool = false,
        installedModelInputOwner159!: ?HostInstalledModelPort = None
    ) {
        this.client = client
        this.contextReadCore = contextReadCore
        this.ids = ids
        this.workspace = workspace
        this.model = model
        this.settingsRoot = settingsRoot
        this.stateRoot = stateRoot
        this.asyncEnabled = asyncEnabled
        this.wallTimeoutMillis = wallTimeoutMillis
        this.shellNetworkMode = shellNetworkMode
        this.sandboxCaBundle = sandboxCaBundle
        this.approvalSettings = approvalSettings
        this.compactionSettings = compactionSettings
        this.theme = theme
        this.unsafeDirectLaunchForTests = unsafeDirectLaunchForTests
        this.persistSettings = persistSettings
        this.sessionMetadata = sessionMetadata
        this.runs = runs
        this.catalog = catalog
        this.pipeline = pipeline
        this.modelNames = modelNames
        this.providerProfiles = providerProfiles
        this.modelCatalog = modelCatalog
        this.processes = processes
        this.codexHookRuntime = codexHookRuntime
        this.retryControl = retryControl
        this.uriRouter = uriRouter
        this.presentationArtifacts = presentationArtifacts
        this.taskRuntime = taskRuntime
        this.askRuntime = askRuntime
        this.pluginRuntime = pluginRuntime
        this.compactionSummarizer = compactionSummarizer
        this.approvalReviewer = approvalReviewer
        this.vnextDatabase = vnextDatabase
        this.threadRuntimes = threadRuntimes
        this.installedModelInputOwner159 = installedModelInputOwner159
        this.vnext = vnext
        this.fixtureProbe = fixtureProbe
        productRegistryEscapedCopies83.beginProduct()
    }

    func activateStartupPlugins(): Result<Unit> {
        for (record in productRegistryRecords83(pluginRuntime.startupEffectiveRecords())) {
            match (activateProductPlugin(record)) {
                case PluginRegistryResult.Ok(_) => ()
                case PluginRegistryResult.Err(activationError) =>
                    match (setPluginEnabled(
                        productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), false, record.scope
                    )) {
                        case PluginRegistryResult.Ok(_) => ()
                        case PluginRegistryResult.Err(persistenceError) =>
                            return Result.Err(AgentError(
                                AgentErrorKind.Configuration,
                                "plugin.startup_disable_failed",
                                "failed to persist startup quarantine for " +
                                    productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)) + ": " +
                                    persistenceError.code,
                                fields: [
                                    ErrorField("plugin", productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))),
                                    ErrorField("activation_error", activationError.code),
                                    ErrorField("persistence_error", persistenceError.code)
                                ]
                            ))
                    }
            }
        }
        Result.Ok(())
    }

    public func request(
        prompt: String,
        sessionId!: ?SessionId = None,
        modelOverride!: String = "",
        thinking!: ThinkingLevel = ThinkingLevel.Medium,
        userRequestedThinking!: ?ThinkingLevel = None,
        thinkingSource!: ThinkingPreferenceSource = ThinkingPreferenceSource.ModelDefault,
        interactions!: ?AgentInteractionSource = None,
        modeSystem!: String = "",
        guide!: String = "",
        readOnly!: Bool = false,
        contextSnapshot!: ?InvocationContextProjection = None,
        executionLaneId!: LaneId = LaneId("main")
    ): AgentRunRequest {
        match (prepareRequest(prompt, sessionId: sessionId, modelOverride: modelOverride, thinking: thinking, userRequestedThinking: userRequestedThinking, thinkingSource: thinkingSource, interactions: interactions, modeSystem: modeSystem, guide: guide, readOnly: readOnly, contextSnapshot: contextSnapshot, executionLaneId: executionLaneId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => throw ProductRequestPreparationError(error)
        }
    }

    public func prepareRequest(
        prompt: String,
        sessionId!: ?SessionId = None,
        modelOverride!: String = "",
        thinking!: ThinkingLevel = ThinkingLevel.Medium,
        userRequestedThinking!: ?ThinkingLevel = None,
        thinkingSource!: ThinkingPreferenceSource = ThinkingPreferenceSource.ModelDefault,
        interactions!: ?AgentInteractionSource = None,
        modeSystem!: String = "",
        guide!: String = "",
        readOnly!: Bool = false,
        contextSnapshot!: ?InvocationContextProjection = None,
        executionLaneId!: LaneId = LaneId("main"),
        queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>,
        operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>,
        callerCancellation180!: ?domain.CancellationToken = None<domain.CancellationToken>,
        inheritedModelSettings180!: ?ToolContextDescriptor = None<ToolContextDescriptor>
    ): Result<AgentRunRequest> {
        match (callerCancellation180) { case Some(token) => match (token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        let targetSession = match (sessionId) {
            case Some(value) => value
            case None => ids.nextSessionId()
        }
        let initializeContext = contextSnapshot.isNone() && hasInitialContextConfiguration(settingsRoot)
        if (initializeContext) {
            let selections = match (loadInitialContextSelections(settingsRoot, runtime: Some(pluginRuntime))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            match (preflightInitialContextSelections(vnext.javascriptPlugins, selections, prompt)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        let promptBuild = match (requestPromptBuildResult(
            targetSession,
            guide,
            modeSystem,
            memoryQuery: prompt
        )) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let resolvedContext = match (contextSnapshot) {
            case Some(value) => validatedContextSnapshot(value)
            case None => InvocationContextProjection()
        }
        let system = promptBuild.text
        let capabilities = requestCapabilities(readOnly, sessionId: Some(targetSession))
        let optionModel180 = match (operatorOptions180) { case Some(options) => options.modelOverride; case None => "" }
        let selectedModel = if (modelOverride != "") { modelOverride } else if (optionModel180 != "") { optionModel180 } else { model }

        let requestCompaction = compactionSettings.resolvedForModel(selectedModel)
        let metadata = modelMetadata(selectedModel)
        let neutral = productRequestModelPolicy(settingsRoot, selectedModel, fixtureProbe.isSome())
        let selectedCapabilities = if (fixtureProbe.isSome()) { match (metadata) {
            case Some(value) => productModelCapabilities(value)
            case None => productModelCapabilities(ModelCatalogEntry(
                "unknown",
                thinking: if (fixtureProbe.isSome()) {
                    Some(ThinkingCapabilities(
                        ThinkingControlMode.Effort,
                        supportedLevels: canonicalNonOffThinkingLevels()
                    ))
                } else { Option<ThinkingCapabilities>.None },
                // The fixture transport exposes the final ModelRequest to
                // contracts, including Product's stable-prefix cache key.
                promptCache: if (selectedModel == "fixture" && fixtureProbe.isSome()) {
                    Some(true)
                } else {
                    Option<Bool>.None
                }
            ))
        } } else { neutral.capabilities }
        let providerSafetyMargin: Int64 = 1024
        let providerContextWindow = selectedCapabilities.contextWindowTokens
        let contextLimit = if (fixtureProbe.isSome()) { match (metadata) {
            case Some(value) => match (value.contextWindow) {
                case Some(window) => min(
                    requestCompaction.maxInputTokens,
                    max(1, window - selectedCapabilities.maxOutputTokens - providerSafetyMargin)
                )
                case None => requestCompaction.maxInputTokens
            }
            case None => requestCompaction.maxInputTokens
        } } else { min(requestCompaction.maxInputTokens,
            max(1, providerContextWindow - selectedCapabilities.maxOutputTokens - providerSafetyMargin)) }
        let outputLimit = if (fixtureProbe.isSome()) { match (metadata) {
            case Some(_) => selectedCapabilities.maxOutputTokens
            case None => 100000
        } } else { selectedCapabilities.maxOutputTokens }
        let endpointOutputLimit: ?Int64 = if (fixtureProbe.isSome()) { match (metadata) {
            case Some(value) => match (profileById(value.providerProfile)) {
                case Some(profile) => profile.endpointMaxOutputTokens
                case None => None
            }
            case None => None
        } } else { neutral.endpointMaxOutput }
        let serviceTier = if (fastModeEnabled(targetSession)) {
            fastTierForModel(selectedModel)
        } else {
            ""
        }
        Result.Ok(AgentRunRequest(
            ids.nextRunId(),
            targetSession,
            selectedModel,
            prompt,
            system: system,
            thinking: thinking,
            userRequestedThinking: userRequestedThinking,
            thinkingSource: thinkingSource,
            modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot(
                selectedModel,
                selectedCapabilities.thinking,
                selectedCapabilities.maxOutputTokens,
                endpointMaxOutputTokens: endpointOutputLimit,
                configurationDigest: neutral.configurationDigest
            )),
            capabilities: capabilities,
            interactions: interactions,
            approvalModeOverride: match (operatorOptions180) { case Some(options) => Some(options.approvalMode); case None => None<ApprovalMode> },
            callerCancellation180: callerCancellation180,
            autoRetry: retryControl.isEnabled(),
            serviceTier: serviceTier,
            pricing: match (metadata) {
                case Some(value) => value.pricing()
                case None => Option<ModelPricing>.None
            },
            cachePolicy: if (selectedCapabilities.promptCache) {
                ModelCachePolicy.StablePrefix
            } else {
                ModelCachePolicy.Default
            },
            cacheKey: if (selectedCapabilities.promptCache) {
                promptBuild.stablePrefixHash
            } else {
                ""
            },
            parallelToolCalls: selectedCapabilities.parallelToolCalling,
            toolContext: requestToolContext180(operatorOptions180, inheritedModelSettings180),
            contextSnapshot: resolvedContext,
            initializeContext: initializeContext,
            contextWindow: providerContextWindow,
            providerSafetyMargin: providerSafetyMargin,
            executionLaneId: executionLaneId, queuedInitiator113: queuedInitiator113, queuedInputPayment113: queuedInputPayment113,
            budget: ResourceBudget(
                maxInputTokens: contextLimit,
                maxOutputTokens: outputLimit,
                maxWallMillis: match (operatorOptions180) { case Some(options) => if (options.wallTimeoutMillis > 0) { options.wallTimeoutMillis } else { wallTimeoutMillis }; case None => wallTimeoutMillis },
                maxContextMessages: requestCompaction.requestMaxMessages
            )
        ))
    }


    func directProcessSandboxEnabled(): Bool {
        processes.sandboxEnabled()
    }

    private func requestPromptBuildResult(
        sessionId: SessionId,
        guide: String,
        modeSystem: String,
        memoryQuery!: String = ""
    ): Result<PromptBuild> {
        // Request-time business context is contributed by the configured
        // Native ContextProvider through canonical InitialContextPreparation.
        // The initial ContextRead integration delta supplies its typed data.
        let _=memoryQuery
        let memoryContext=""
        Result.Ok(buildProductPrompt(
            workspace.rootPath(),
            "",
            guide,
            modeSystem,
            memoryContext: memoryContext
        ))
    }

    private func requestSystem(
        sessionId: SessionId,
        guide: String,
        modeSystem: String
    ): String {
        match (requestPromptBuildResult(sessionId, guide, modeSystem)) {
            case Result.Ok(value) => value.text
            case Result.Err(error) => throw ProductRequestPreparationError(error)
        }
    }

    func readonlyToolCapabilities(sessionId: SessionId): CapabilitySet {
        requestCapabilities(true, sessionId: Some(sessionId))
    }

    private func requestCapabilities(readOnly: Bool, sessionId!: ?SessionId=None): CapabilitySet {
        if (readOnly) {
            let values=ArrayList<Capability>([Capability(CapabilityKind.WorkspaceRead)])
            match(sessionId){case Some(thread)=>values.add(all:agent_host_runtime.hostReadonlyPluginCapabilities(
                vnext.javascriptPlugins,pluginRuntime.list(),catalog,settingsRoot,ThreadId(thread.value)));case None=>()}
            CapabilitySet(values: values.toArray())
        } else {
            CapabilitySet(
                values: [
                    Capability(CapabilityKind.WorkspaceRead),
                    Capability(CapabilityKind.WorkspaceWrite),
                    Capability(CapabilityKind.ProcessSpawn),
                    Capability(CapabilityKind.NetworkAccess),
                    Capability(CapabilityKind.ExtensionInvoke),
                    Capability(CapabilityKind.PeerMessage),
                    Capability(CapabilityKind.Delegate)
                ]
            )
        }
    }

    // Read-only selected Native goal data, independent of legacy metadata.
    // This projection never installs continuation permission or writes either
    // fact store; mutations use the actual independently approved document Root.
    public func selectedGoalPresentation(sessionId: SessionId): Result<?ProductGoalState> {
        let selection=match(selectProductGoal(this,sessionId)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let documents=SqlitePluginDocumentRepository(vnextDatabase)
        let snapshot=match(documents.read(ThreadId(sessionId.value),LaneId("main"),selection.namespace,"goal")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
            let raw=snapshot.encoded
            // Preserve the canonical document's existing eight MiB contract.
            let node=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32)
            let presentation: ?ProductGoalState=if(node.unifiedKind==ValueKind.Null){None}
                else{Some(ProductGoalState(node,modelPolicySha256Text(raw),selection))}
            match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let current=match(documents.read(ThreadId(sessionId.value),LaneId("main"),selection.namespace,"goal")){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let currentRaw=current.encoded
            if(currentRaw!=raw){return productGoalPresentationError("goal.presentation_changed")}
            Result.Ok(presentation)
        }catch(_:Exception){productGoalPresentationError("goal.presentation_invalid")}
    }

    public func goalState(sessionId: SessionId): Result<?ProductGoalState> {
        selectedGoalPresentation(sessionId)
    }

    // Cold legacy history is exposed only for explicit migration. No active
    // policy or continuation owner reads this metadata as current goal facts.
    func legacyGoalForMigration(sessionId: SessionId): Result<String> {
        sessionMetadata.legacyGoalBytes(sessionId)
    }

    public func applicationSession(sessionId!: ?SessionId = None): ApplicationSession {
        ApplicationSession(this, sessionId: sessionId)
    }

    public func compactionEnabled(): Bool {
        compactionSettings.enabled
    }

    public func reviewApproval(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        recentDenials!: Array<String> = []
    ): ApprovalReview {
        approvalReviewer.review(
            request,
            approval,
            recentDenials: recentDenials
        )
    }

    public func cancelApprovalReview(): Result<Unit> {
        approvalReviewer.cancel()
    }

    public func cancelApprovalReview(runId: RunId): Result<Unit> {
        approvalReviewer.cancel(runId)
    }

    // Package DATA linkage for the same installed registry. The caller must
    // already hold the actual paid query cell; this cannot grant a Source,
    // install an executor, fabricate a Run or admit any operation.
    func retainOwnedMaintenanceProducer173(value: NativeCheckpointRetentionHeld173): Unit {
        match (compactionSummarizer as InstalledCompactionSummarizer) {
            case Some(actual) => actual.retainCheckpointFailure173(value)
            case None => throw IllegalStateException("no installed maintenance DATA registry") }
    }

    // Installed-policy maintenance DATA shares, not a Core Run or cut.
    public func hasOwnedMaintenanceFailure173(session: SessionId, marker: AgentError): Bool {
        match (compactionSummarizer as OwnedCompactionMaintenanceFailureReader173) {
            case Some(actual) => actual.hasMaintenanceFailure173(session, marker); case None => false }
    }
    public func admitOwnedMaintenanceFailure173(session: SessionId, marker: AgentError,
        accept: (OwnedAgentRunResult113) -> Bool): Bool {
        match (compactionSummarizer as OwnedCompactionMaintenanceFailureReader173) {
            case Some(actual) => actual.admitMaintenanceFailure173(session, marker, accept); case None => false }
    }
    public func takeOwnedMaintenanceFailure173(session: SessionId, marker: AgentError): ?OwnedAgentRunResult113 {
        match (compactionSummarizer as OwnedCompactionMaintenanceFailureReader173) {
            case Some(actual) => actual.takeMaintenanceFailure173(session, marker); case None => None<OwnedAgentRunResult113> }
    }
    public func collectOwnedMaintenanceFailures173(): Unit {
        match (compactionSummarizer as OwnedCompactionMaintenanceFailureReader173) {
            case Some(actual) => actual.collectMaintenanceFailures173(); case None => () }
    }

    public func cancelCompaction(sessionId: SessionId): Result<Unit> {
        compactionSummarizer.cancel(sessionId)
    }

    public func tools(threadId!: ?ThreadId = None): Array<ModelToolDefinition> {
        catalog.definitions(threadId: threadId)
    }

    public func javascriptPluginCommands(): Array<ProductJavaScriptPluginCommand> {
        vnext.javascriptPluginCommands()
    }

    public func javascriptPluginViews(): Array<ProductJavaScriptPluginView> {
        vnext.javascriptPluginViews()
    }

    public func invokeJavaScriptPluginCommand(
        routeName: String,
        arguments: String,
        sessionId: SessionId,
        commandId: String,
        cancellation: domain.CancellationToken,
        noticeSink: ProductJavaScriptPluginNoticeSink
    ): Result<Unit> {
        vnext.invokeJavaScriptPluginCommand(
            routeName, arguments, sessionId, commandId, cancellation, noticeSink
        )
    }

    func invokeScopedPluginCommand(routeName: String, arguments: String, scope: ProductPluginCommandScope,
        noticeSink: ProductJavaScriptPluginNoticeSink): Result<Unit> {
        vnext.invokeScopedPluginCommand(routeName, arguments, scope, noticeSink)
    }

    func pluginCommandParticipant(scope: ProductPluginCommandScope, proposal: ProductCommandProposal): Result<?PluginDocumentCommitParticipant> {
        if (proposal.control().isNone() && !proposal.binding.allowsControl("continuation")) { return Result.Ok(Option<PluginDocumentCommitParticipant>.None) }
        // An explicit early proposal is still validated before creating a Run.
        // A deferred proposal is selected only after the canonical document read.
        if (proposal.control().isSome()) {
            match (createPluginCommandParticipant(scope, proposal)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        let participant = ProductCommandPreparationParticipant(scope, proposal,
            { resolved => createPluginCommandParticipant(scope, resolved) })
        match (scope.retainParticipant(participant)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        Result.Ok(Some(participant))
    }
    private func createPluginCommandParticipant(scope: ProductPluginCommandScope,
        proposal: ProductCommandProposal): Result<ProductCommandCommitParticipant> {
        let control = proposal.control().getOrThrow()
        match (scope.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let restriction = match (commandContinuationRestriction(proposal)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let previousPrompt = match (scope.prepareUserControl(proposal)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let address = ContinuationAllowanceAddress(ThreadId(scope.sessionId.value), LaneId("main"), proposal.binding.namespace,
            httpIntentText(control, "document_key"))
        let facts = ContinuationAllowanceRepository(runs)
        let expected = try { vnextDatabase.readTransaction<Result<?ContinuationAllowanceFacts>>({ tx => facts.readFacts(tx, address) }) }
            catch (_: Exception) { return commandControlError("continuation.accounting_unavailable") }
        let snapshot = match (expected) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let prompt = match (control.field("next_prompt")) { case Some(value) => value.text; case None => previousPrompt }
        if (httpIntentText(control, "action") == "set_budget" && prompt.trimAscii() == "") {
            // Updating persisted accounting cannot recover an absent live user
            // owner. An explicit resume supplies its own reviewed prompt.
            return commandControlError("continuation.live_prompt_missing") }
        let participant = ProductCommandCommitParticipant(facts, address, snapshot, proposal, scope.cancellation, prompt, restriction)
        Result.Ok(participant)
    }
    func acceptPluginCommandControl(scope: ProductPluginCommandScope, proposal: ProductCommandProposal): Result<?ProductContinuationOwner> {
        if (proposal.control().isNone()) { return Result.Ok(Option<ProductContinuationOwner>.None) }
        match (scope.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let retained = match (scope.committedParticipant()) { case Some(value) => value
            case None => return commandControlError("continuation.participant_missing") }
        let participant = match (retained.controlParticipant()) { case Result.Ok(Some(value)) => value
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(None) => return commandControlError("continuation.participant_missing") }
        let accepted = match (participant.accepted(vnextDatabase)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (!accepted.enabled || accepted.closed) { return Result.Ok(Option<ProductContinuationOwner>.None) }
        if (participant.nextPrompt.trimAscii() == "") { return commandControlError("continuation.live_prompt_missing") }
        let original = match (participant.completedDocument(vnextDatabase)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        Result.Ok(Some(ProductContinuationOwner(participant, original[0], original[1], accepted, participant.nextPrompt, vnextDatabase,
            ContinuationAllowanceRepository(runs), { => scope.continuationApplicationCurrent() })))
    }
    func preparePluginContinuation(owner: ProductContinuationOwner, request: AgentRunRequest): Result<AgentContinuationStart> {
        match (owner.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let prepared = match (contextReadCore.prepareContinuation(request)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        owner.prepare(prepared)
    }

    func executePluginCommandProposal(scope: ProductPluginCommandScope, proposal: ProductCommandProposal,
        owner: ProductDirectPreparationOwner, participant!: ?PluginDocumentCommitParticipant = None): Result<ToolInvocationResult> {
        match (scope.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        vnext.executeDeferredCanonicalTool(scope.sessionId, requestCapabilities(false), proposal.call(), owner,
            scope.cancellation, participant: participant, operatorOptions180: scope.operatorOptions180, callerCancellation180: scope.callerCancellation180)
    }

    // Explicit frontend maintenance entry. Installed/enabled plugin metadata
    // is only discovery data; canonical startup, approval and finite resources
    // are still enforced by the same lifecycle manager and ToolPipeline.
    public func startPluginService(targetThread: SessionId, namespace: String, serviceId: String, route: String,
        approvalDecision!: ApprovalDecision,
        budget!: ExecutionBudget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1),
        cancellation!: domain.CancellationToken = domain.CancellationSource().token,
        operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>,
        callerCancellation180!: ?domain.CancellationToken = None<domain.CancellationToken>
    ): Result<ToolInvocationResult> {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (callerCancellation180) { case Some(token) => match (token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        let record = match (pluginRuntime.get(namespace)) {
            case Some(value) => value
            case None => return pluginProcessError("plugin.not_found", "plugin is not installed")
        }
        if (!record.enabled || record.descriptor.entryKind != PluginEntryKind.NativeExecutable) {
            return pluginProcessError("plugin.service_unavailable", "an enabled native service plugin is required")
        }
        // Transport selection comes from the exact installed package's operator
        // configuration. A package may request both capabilities; neither one
        // selects a backend or substitutes for a current configuration grant.
        let httpConfiguration: ?ProductPluginHttpConfiguration = match (loadPluginHttpConfiguration(settingsRoot,
            productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)))) {
            case Result.Ok(value) => Some(value)
            case Result.Err(error) =>
                if (error.code == "plugin.http_configuration_missing") { None }
                else { return Result.Err(error) }
        }
        if (httpConfiguration.isSome()) {
            let transport = httpConfiguration.getOrThrow().configuration.field("transport")
            if (transport.isNone() || transport.getOrThrow().unifiedKind != ValueKind.Text || transport.getOrThrow().text != "http") {
                return pluginProcessError("plugin.service_transport_unsupported", "HTTP service configuration must explicitly select transport http")
            }
            if (!record.descriptor.hasCapability("network.http")) {
                return pluginProcessError("plugin.service_unavailable", "HTTP service requires its declared network.http capability")
            }
        }
        let channelConfiguration: ?ProductPluginLifecycleConfiguration = if (httpConfiguration.isNone()) {
            let selected = match (loadPluginLifecycleConfiguration(settingsRoot,
                productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest)), productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Root)))) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) => value
            }
            let transport = selected.configuration.field("transport")
            // Legacy generic channel configurations predate the selector but
            // already carry an exact operator executable and finite service grant.
            // An explicit selector must match that transport; never fall through
            // from an unsupported or malformed HTTP configuration.
            if (transport.isSome() && (transport.getOrThrow().unifiedKind != ValueKind.Text || !["stdio","managed_channel_owned"].contains(transport.getOrThrow().text))) {
                return pluginProcessError("plugin.service_transport_unsupported", "channel service configuration must select stdio or managed_channel_owned")
            }
            if (!record.descriptor.hasCapability("process.channel")) {
                return pluginProcessError("plugin.service_unavailable", "stdio service requires its declared process.channel capability")
            }
            Some(selected)
        } else { None }
        let generation = vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)))
        let manager = match (managedPluginServiceManager()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        let startupCaller180 = agent_host_runtime.HostCallerCancellation(cancellation, callerCancellation180)
        let context = ToolInvocationContext(RunId("service-scope"), targetThread, productCapabilities(),
            epoch: 1, cancellation: startupCaller180.token, toolContext: productToolContext(workspace.rootPath(), operatorOptions180: operatorOptions180), budget: budget)
        let maintenance = ThreadId(ids.nextSessionId().value)
        let started = try { if (httpConfiguration.isSome()) {
            manager.startHttpProtocol(vnext, context, maintenance, httpConfiguration.getOrThrow(),
                serviceId, route, generation, approvalDecision, budget: budget)
        } else if(channelConfiguration.getOrThrow().configuration.field("transport").isSome() &&
            channelConfiguration.getOrThrow().configuration.field("transport").getOrThrow().text=="managed_channel_owned"){
            manager.startOwnedChannelProtocol(vnext,context,maintenance,channelConfiguration.getOrThrow(),
                serviceId,route,generation,approvalDecision,budget:budget)
        } else {
            manager.startProtocol(vnext, context, maintenance, channelConfiguration.getOrThrow(),
                serviceId, route, generation, approvalDecision, budget: budget)
        } } finally { startupCaller180.close() }
        match (started) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => Result.Ok(value.outcome)
        }
    }

    public func refreshPluginService(targetThread: SessionId, namespace: String, serviceId: String,
        approvalDecision!: ApprovalDecision,
        budget!: ExecutionBudget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)): Result<ToolInvocationResult> {
        managedPluginServiceLock.lock()
        let selected = try { managedPluginServices } finally { managedPluginServiceLock.unlock() }
        let manager = match (selected) { case Some(value) => value; case None => return lifecycleLeaseError("plugin.service_not_active") }
        let context = ToolInvocationContext(RunId("service-refresh-scope"), targetThread, productCapabilities(),
            epoch: 1, toolContext: productToolContext(workspace.rootPath()), budget: budget)
        manager.refresh(vnext, context, namespace, serviceId, approvalDecision, budget)
    }

    public func stopPluginService(targetThread: SessionId, namespace: String, serviceId: String): Result<Unit> {
        managedPluginServiceLock.lock()
        let manager = try { managedPluginServices } finally { managedPluginServiceLock.unlock() }
        match (manager) {
            case Some(value) =>
                let deadline = MonoTime.now() + Duration.second * 2
                var result = value.stop(ThreadId(targetThread.value), namespace, serviceId)
                while (result.isError() && result.error().getOrThrow().code == "plugin.lifecycle_manager_cleanup_pending" && MonoTime.now() < deadline) {
                    sleep(Duration.millisecond * 25)
                    result = value.stop(ThreadId(targetThread.value), namespace, serviceId)
                }
                result
            case None => pluginProcessError("plugin.service_not_active", "service has no retained runtime instance")
        }
    }

    // Stops only the selected Thread. Cleanup remains owned after the bounded
    // wait; repeated calls can obtain the later acknowledgement.
    public func stopPluginServices(targetThread: SessionId): Result<Unit> {
        managedPluginServiceLock.lock()
        let manager = try { managedPluginServices } finally { managedPluginServiceLock.unlock() }
        match (manager) {
            case Some(value) =>
                let deadline = MonoTime.now() + Duration.second * 2
                var result = value.stopThread(ThreadId(targetThread.value))
                while (result.isError() && result.error().getOrThrow().code == "plugin.lifecycle_manager_cleanup_pending" && MonoTime.now() < deadline) {
                    sleep(Duration.millisecond * 25)
                    result = value.stopThread(ThreadId(targetThread.value))
                }
                result
            case None => Result.Ok(())
        }
    }

    public func pluginServiceStatuses(): Array<AgentValue> {
        managedPluginServiceLock.lock()
        let manager = try { managedPluginServices } finally { managedPluginServiceLock.unlock() }
        match (manager) { case Some(value) => value.statuses(); case None => [] }
    }

    func observeManagedCleanupForFixture(observer:agent_host_runtime.HostManagedChannelCleanupObserver):Result<Unit>{
        if(fixtureProbe.isNone()){return pluginProcessError("plugin.cleanup_observer_fixture_required","cleanup diagnostics require the actual fixture assembly")}
        managedPluginServiceLock.lock();try{
            if(managedPluginServices.isSome() || managedPluginServicesStopping || fixtureManagedCleanupObserver.isSome()){
                return pluginProcessError("plugin.cleanup_observer_already_started","cleanup diagnostics must be bound before the original manager starts")}
            fixtureManagedCleanupObserver=Some(observer);Result.Ok(())
        }finally{managedPluginServiceLock.unlock()}
    }
    private func managedPluginServiceManager(): Result<ProductPluginLifecycleManager> {
        managedPluginServiceLock.lock()
        try {
            if (managedPluginServicesStopping) {
                return pluginProcessError("plugin.service_runtime_closing", "plugin service runtime is closing")
            }
            match (managedPluginServices) {
                case Some(value) => Result.Ok(value)
                case None =>
                    match (vnext.createPluginLifecycleManager(processes, caBundle: sandboxCaBundle,
                        managedJobLauncher: Some({ context, prepared, acknowledged => taskRuntime.startManagedJob(vnext, context, prepared, acknowledged) }),
                        cleanupObserver:fixtureManagedCleanupObserver)) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(value) => managedPluginServices = Some(value); Result.Ok(value)
                    }
            }
        } finally { managedPluginServiceLock.unlock() }
    }

    private func closeManagedPluginServices(): Result<Unit> {
        managedPluginServiceLock.lock()
        let manager = try { managedPluginServicesStopping = true; managedPluginServices }
            finally { managedPluginServiceLock.unlock() }
        match (manager) {
            case None => Result.Ok(())
            case Some(value) =>
                let deadline = MonoTime.now() + Duration.second * 2
                var result = value.close()
                while (result.isError() && result.error().getOrThrow().code == "plugin.lifecycle_manager_cleanup_pending" && MonoTime.now() < deadline) {
                    sleep(Duration.millisecond * 25)
                    result = value.close()
                }
                result
        }
    }

    public func resolvePluginContext(namespace: String, provider: String, query: AgentValue,
        threadId: ThreadId, cancellation!: domain.CancellationToken, selectedIds!: Array<String> = []): Result<InvocationContextProjection> {
        resolveProductPluginContext(vnext.javascriptPlugins, namespace, provider, query, threadId,
            selectedIds, cancellation, ids.nextInvocationId())
    }

    // Resolves only a typed installed content contribution. This host API is
    // deliberately separate from plugin service payloads and does not grant
    // capabilities or replace any currently executing PreparedInvocation.
    public func queuePluginContextUpdate(threadId: ThreadId, runId: RunId, epoch: Int64,
        expectedDigest: String, namespace: String, provider: String, query: AgentValue,
        cancellation!: domain.CancellationToken, selectedIds!: Array<String> = []): Result<RunContextUpdate> {
        let runtime = match (threadRuntimes.acquire(threadId, workspace.rootPath())) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let before = match (runtime.activeRun()) { case Some(value) => value
            case None => return pluginProcessError("context.update_stale", "target Thread has no active Run") }
        if (before.runId.value != runId.value || before.epoch != epoch ||
            contextReadProjectionDigest(before.contextSnapshot) != expectedDigest || cancellation.isCancelled()) {
            return pluginProcessError("context.update_stale", "context update does not match the active Run") }
        let binding = match (vnext.javascriptPlugins.contentProviderBinding(namespace, provider, false)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let replacement = match (resolvePluginContext(namespace, provider, query, threadId,
            cancellation: cancellation, selectedIds: selectedIds)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let owner = namespace + "/context/" + provider
        let contributions = ArrayList<InvocationContextContribution>()
        for (item in before.contextSnapshot.contributions() where item.owner != owner) { contributions.add(item) }
        for (item in replacement.contributions()) {
            if (item.owner != owner) { return pluginProcessError("context.update_owner_invalid", "content contribution has a foreign owner") }
            contributions.add(item)
        }
        let data = InvocationContextProjection(contributions: contributions.toArray())
        let next = InvocationContextProjection(contributions: contributions.toArray(), sourceDigest:
            modelPolicySha256Text(canonicalAgentValue(contextSnapshotValue(data))))
        let host = vnext.javascriptPlugins
        runtime.queueContextSnapshot(runId, epoch, expectedDigest, next, validity: { =>
            if (cancellation.isCancelled()) { return pluginProcessError("context.update_source_stale", "context update caller withdrew") }
            match (host.servicePackage(namespace, binding.generation)) {
                case Result.Err(_) => pluginProcessError("context.update_source_stale", "content provider was revoked or replaced")
                case Result.Ok(value) => if (value.textEquals(PluginDescriptorText.ContentDigest, binding.digest)) { Result.Ok(()) }
                    else { pluginProcessError("context.update_source_stale", "content provider identity changed") }
            }
        })
    }

    public func queuePluginContextReadUpdate(threadId: ThreadId, runId: RunId, epoch: Int64,
        expectedDigest: String, namespace: String, provider: String, resources: AgentValue, query: AgentValue,
        cancellation!: domain.CancellationToken, selectedIds!: Array<String> = []): Result<ContextReadUpdate> {
        let runtime = match (threadRuntimes.acquire(threadId, workspace.rootPath())) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let before = match (runtime.activeRun()) { case Some(value) => value
            case None => return pluginProcessError("context.update_stale", "target Thread has no active Run") }
        if (before.runId.value != runId.value || before.epoch != epoch ||
            contextReadProjectionDigest(before.contextSnapshot) != expectedDigest || cancellation.isCancelled()) {
            return pluginProcessError("context.update_stale", "context resource request lost its active Run") }
        let prepared = match (productContextProviderRead(vnext.javascriptPlugins, namespace, provider,
            before, resources, query, cancellation, selectedIds, ids.nextInvocationId())) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        contextReadCore.queueContextReadUpdate(runId, epoch, expectedDigest, prepared.read, validity: prepared.validity)
    }

    public func readPluginContextResource(snapshot: InvocationContextProjection, owner: String,
        contribution: String, reference: String, threadId: ThreadId,
        cancellation!: domain.CancellationToken): Result<String> {
        readProductPluginContextResource(vnext.javascriptPlugins, snapshot, owner, contribution, reference,
            threadId, cancellation, ids.nextInvocationId())
    }

    func validateDistributionContext(encoded: String): Result<Unit> {
        match (parseInitialContextSelections(settingsRoot, encoded, Some(pluginRuntime))) {
            case Result.Ok(_) => Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func pluginSnapshots(): OwnedPluginRecordList {
        pluginRuntime.list()
    }

    public func inspectPlugin(root: String): PluginRegistryResult<OwnedPluginPackageDescriptor> {
        pluginRuntime.inspect(root)
    }

    public func importLocalPlugin(root: String): PluginRegistryResult<ProductPluginRecord> {
        importLocalPlugin(root, PluginInstallScope.User)
    }

    public func importLocalPlugin(root: String, scope: PluginInstallScope): PluginRegistryResult<ProductPluginRecord> {
        let descriptor = match (pluginRuntime.inspect(root)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        importProductPlugin(
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)),
            { => pluginRuntime.importLocal(root, scope) }
        )
    }

    /// First-install distribution assembly only. Publishing each import with
    /// its own writer fence rewrites the whole lock N times; this registers
    /// every default under ONE fence while keeping the same materialisation
    /// and content checks per package. Any failure rolls the batch back.
    public func importDistributionPluginsInFirstAssembly(
        roots: Array<String>,
        emptyRegistryBeforeImport: Bool
    ): PluginRegistryResult<Unit> {
        if (!emptyRegistryBeforeImport) {
            return productRegistryFailure83(pluginRuntime, "plugin.distribution_assembly_not_first",
                "distribution assembly requires an empty registry")
        }
        match (pluginRuntime.importLocalBatch(roots, PluginInstallScope.User)) {
            case PluginRegistryResult.Err(error) => PluginRegistryResult.Err(error)
            case PluginRegistryResult.Ok(_) => PluginRegistryResult.Ok(())
        }
    }


    public func importPluginSource(
        sessionId: SessionId,
        source: ProductPluginSourceRequest,
        approvalDecision!: ApprovalDecision
    ): PluginRegistryResult<ProductPluginRecord> {
        importPluginSource(
            sessionId,
            source,
            PluginInstallScope.User,
            approvalDecision: approvalDecision
        )
    }

    public func importPluginSource(
        sessionId: SessionId,
        source: ProductPluginSourceRequest,
        scope: PluginInstallScope,
        approvalDecision!: ApprovalDecision
    ): PluginRegistryResult<ProductPluginRecord> {
        let spec = match (productPluginSourceSpec(source, shellNetworkMode)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginRegistryResult.Err(pluginRuntime.ownedError(error.code, error.message))
        }
        if (pluginScopeEquals(scope, PluginInstallScope.Workspace) && workspace.rootPath().trimAscii() == "") {
            return productRegistryFailure83(pluginRuntime, "plugin.workspace_scope_missing", "workspace scope requires an identified workspace root")
        }
        match (pluginRuntime.cachedSource(spec, scope)) {
            case Some(record) => return PluginRegistryResult.Ok(record)
            case None => ()
        }
        let acquirer = ProductPluginSourceAcquirer(
            vnext, ids, workspace.rootPath(), settingsRoot
        )
        match (acquirer.acquire(sessionId, spec, approvalDecision)) {
            case PluginImportResult.Err(error) => PluginRegistryResult.Err(pluginRuntime.ownedError(error.code, error.message))
            case PluginImportResult.Ok(acquired) =>
                try {
                    let descriptor = match (pluginRuntime.inspect(acquired.packageRoot)) {
                        case PluginRegistryResult.Ok(value) => value
                        case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
                    }
                    importProductPlugin(
                        productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)),
                        { => pluginRuntime.importAcquiredSource(acquired, scope) }
                    )
                } finally {
                    acquirer.cleanup(acquired)
                }
        }
    }

    public func pluginDoctor(custody!: ?OwnedApplicationRegistryResponse161 = None): Array<PluginRegistryOwnedError> {
        let original = pluginRuntime.doctor()
        productRegistryKeepErrorList161(original, custody)
        let records = productRegistryRecords83(pluginRuntime.enabledEffectiveRecords(), custody: custody)
        let count = original.size + records.size
        if (count < 0 || count > (134217728 - 8192) / 256) { throw LogicalJsonPayloadError("registry copied data cannot fit the original shared capacity") }
        let payment = original.deriveCopiedDataPayment(count * 256 + 8192)
        productRegistryAdoptCopied161(payment, custody: custody, errors: Some(original))
        try {
            let errors = ArrayList<PluginRegistryOwnedError>()
            for (index in 0..original.size) { errors.add(productRegistryKeepOwnedError161(original.at(index), custody)) }
            for (record in records where record.descriptor.componentDependencyCount != 0) {
                let namespace = productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace), custody: custody)
                if (vnext.javascriptPlugins.instanceGeneration(namespace) == 0u64) {
                    errors.add(productRegistryKeepOwnedError161(record.ownedError("plugin.component_dependency_blocked",
                        namespace + " has no active dependency-bound instance; explicitly enable it after repairing dependencies"), custody))
                }
            }
            // original remains paid: these returned owned error handles still
            // share its backing. No list.close falsely retires those handles.
            errors.toArray()
        } finally { /* Returned error views still own this captured list. */ }
    }
    public func pluginPromptTemplates(): Array<String> {
        pluginRuntime.promptTemplateNames()
    }

    public func renderPluginPromptTemplate(
        identity: String,
        arguments: Array<String>
    ): PluginImportResult<String> {
        pluginRuntime.renderPromptTemplate(identity, arguments)
    }


    private func pluginDeactivationRestoreError(
        record: ProductPluginRecord,
        deactivationError: AgentError,
        restoreError: AgentError
    ): AgentError {
        AgentError(
            AgentErrorKind.Configuration,
            "plugin.deactivation_restore_failed",
            "plugin deactivation failed and its active components could not be restored",
            fields: [
                ErrorField("plugin", productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))),
                ErrorField("deactivation_error", deactivationError.code),
                ErrorField("restore_error", restoreError.code)
            ]
        )
    }

    private func restoreProductPlugin(
        record: ProductPluginRecord,
        restoreVnext!: Bool
    ): Result<Unit> {
        var restoreError: ?AgentError = None
        if (restoreVnext) {
            match (vnext.restoreImportedPlugin(record)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => restoreError = Some(error)
            }
        }
        codexHookRuntime.activatePlugin(record)
        match (restoreError) {
            case Some(error) => Result.Err(error)
            case None => Result.Ok(())
        }
    }

    private func deactivateProductPlugin(record: ProductPluginRecord): PluginRegistryResult<Unit> {
        codexHookRuntime.revokePlugin(record)
        match (vnext.deactivateImportedPlugin(record)) {
            case Result.Ok(_) => PluginRegistryResult.Ok(())
            case Result.Err(error) =>
                match (restoreProductPlugin(record, restoreVnext: true)) {
                    case Result.Ok(_) => productRegistryFailure83(pluginRuntime, error.code, error.message)
                    case Result.Err(restoreError) =>
                        let combined = pluginDeactivationRestoreError(record, error, restoreError)
                        productRegistryFailure83(pluginRuntime, combined.code, combined.message)
                }
        }
    }

    private func activateProductPlugin(record: ProductPluginRecord): PluginRegistryResult<Unit> {
        return activateProductPluginVerified(record, verifyContent: true)
    }

    // First-install assembly just verified every default package under one
    // writer fence, so re-hashing each dependency here would repeat the same
    // known-current bytes N times. Every other check still runs.
    private func activateProductPluginVerified(record: ProductPluginRecord,
        verifyContent!: Bool, serialize!: Bool = true): PluginRegistryResult<Unit> {
        match (pluginRuntime.checkComponentDependencies(record, verifyContent: verifyContent)) {
            // Keep the complete paid error, including source/field bytes. The
            // Registry result must not round-trip through an unowned Raw error.
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
            case PluginRegistryResult.Ok(_) => ()
        }
        match (vnext.activateImportedPluginWithLock(record, serialize: serialize)) {
            case Result.Err(error) => productRegistryFailure83(pluginRuntime, error.code, error.message)
            case Result.Ok(_) =>
                codexHookRuntime.activatePlugin(record)
                PluginRegistryResult.Ok(())
        }
    }

    // First-install distribution assembly only. Enabling each default one at a
    // time re-mounts every previously enabled plugin and repeats its handshake,
    // so N defaults cost O(N^2) resident generations. Publish every enable to
    // the Registry first, then mount each plugin exactly once through the same
    // activation path.
    public func enableDistributionPluginsInFirstAssembly(
        namespaces: Array<String>,
        emptyRegistryBeforeImport: Bool
    ): PluginRegistryResult<Unit> {
        // The caller observes emptiness BEFORE its own imports; re-checking
        // here would always see the just-registered defaults.
        if (!emptyRegistryBeforeImport) {
            return productRegistryFailure83(pluginRuntime, "plugin.distribution_assembly_not_first",
                "distribution assembly requires an empty registry")
        }
        // One writer fence for the whole batch: each plugin still verifies its
        // own dependencies and content against its own lock, but the fence
        // acquisition and full lock rewrite happen once instead of N times.
        match (pluginRuntime.setEnabledBatch(namespaces, true, PluginInstallScope.User)) {
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
            case PluginRegistryResult.Ok(_) => ()
        }
        // No concurrent reader exists here: the Product is not published yet
        // and the broker answers only `ping` until `frontend180` waits on this
        // assembly. Mounting independent packages can therefore overlap; any
        // failure still aborts the whole assembly and rolls the batch back.
        let records = productRegistryRecords83(pluginRuntime.startupEffectiveRecords())
        let width: Int64 = 3
        var index: Int64 = 0
        while (index < records.size) {
            var end = index + width
            if (end > records.size) { end = records.size }
            let futures = ArrayList<Future<PluginRegistryResult<Unit>>>()
            for (position in index..end) {
                let record = records[position]
                futures.add(spawn { => activateProductPluginVerified(record, verifyContent: false, serialize: false) })
            }
            for (future in futures) {
                match (future.get()) {
                    case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
                    case PluginRegistryResult.Ok(_) => ()
                }
            }
            index = end
        }
        PluginRegistryResult.Ok(())
    }

    private func importProductPlugin(
        namespace: String,
        operation: () -> PluginRegistryResult<ProductPluginRecord>
    ): PluginRegistryResult<ProductPluginRecord> {
        let effectiveBefore = pluginRuntime.get(namespace)
        let originalMounted = mountedProductPluginInstances()
        try {
        match (effectiveBefore) {
            case Some(previous) => if (previous.enabled) {
                match (deactivateProductPlugin(previous)) {
                    case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
                    case PluginRegistryResult.Ok(_) => ()
                }
            }
            case None => ()
        }
        let mounted = match (withdrawMountedProductPluginInstances()) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        try {
        match (operation()) {
            case PluginRegistryResult.Err(error) =>
                match (remountProductPluginInstances(originalMounted)) {
                    case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(error)
                    case PluginRegistryResult.Ok(_) => ()
                }
                match (effectiveBefore) {
                    case Some(previous) => if (previous.enabled && previous.descriptor.entryKind != PluginEntryKind.NativeExecutable) {
                        match (activateProductPlugin(previous)) {
                            case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                    }
                    case None => ()
                }
                PluginRegistryResult.Err(error)
            case PluginRegistryResult.Ok(record) =>
                let effectiveAfter = pluginRuntime.get(namespace)
                let effectiveChanged = match ((effectiveBefore, effectiveAfter)) {
                    case (Some(previous), Some(current)) =>
                        !pluginScopeEquals(previous.scope, current.scope) ||
                            !previous.sameText(PluginRecordText.ContentLock, current, PluginRecordText.ContentLock)
                    case (None, Some(_)) => true
                    case (Some(_), None) => true
                    case (None, None) => false
                }
                let activation = match (remountProductPluginInstances(if (effectiveChanged) { mounted } else { originalMounted })) {
                    case PluginRegistryResult.Err(error) => PluginRegistryResult<Unit>.Err(error)
                    case PluginRegistryResult.Ok(_) => match (effectiveAfter) {
                        case Some(active) => if (active.enabled && (effectiveChanged || active.descriptor.entryKind != PluginEntryKind.NativeExecutable)) {
                            activateProductPlugin(active)
                        } else { PluginRegistryResult<Unit>.Ok(()) }
                        case None => PluginRegistryResult<Unit>.Ok(())
                    }
                }
                match (activation) {
                    case PluginRegistryResult.Ok(_) => PluginRegistryResult.Ok(record)
                    case PluginRegistryResult.Err(error) =>
                        match (withdrawProductPluginInstances(mounted)) {
                            case PluginRegistryResult.Err(withdrawError) => return PluginRegistryResult.Err(withdrawError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        match (pluginRuntime.uninstall(namespace, record.scope)) {
                            case PluginRegistryResult.Err(rollbackError) =>
                                match (remountProductPluginInstances(mounted)) {
                                    case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(rollbackError)
                                    case PluginRegistryResult.Ok(_) => return PluginRegistryResult.Err(rollbackError)
                                }
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        match (remountProductPluginInstances(originalMounted)) {
                            case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        match (effectiveBefore) {
                            case Some(previous) => if (previous.enabled && previous.descriptor.entryKind != PluginEntryKind.NativeExecutable) {
                                match (activateProductPlugin(previous)) {
                                    case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                                    case PluginRegistryResult.Ok(_) => ()
                                }
                            }
                            case None => ()
                        }
                        PluginRegistryResult.Err(error)
                }
        }
        } finally { mounted.close() }
        } finally { originalMounted.close() }
    }
    private func replaceActiveProductPlugin(
        id: String,
        operation: () -> PluginRegistryResult<ProductPluginRecord>,
        restoreOnActivationFailure!: Bool = false
    ): PluginRegistryResult<ProductPluginRecord> {
        let current = match (pluginRuntime.resolveForMutation(id)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        replaceResolvedProductPlugin(id, current, operation, restoreOnActivationFailure: restoreOnActivationFailure)
    }

    public func updateLocalPlugin(id: String, root: String): PluginRegistryResult<ProductPluginRecord> {
        replaceActiveProductPlugin(id, { => pluginRuntime.updateLocal(id, root) }, restoreOnActivationFailure: true)
    }

    private func replaceActiveProductPluginInScope(
        id: String,
        scope: PluginInstallScope,
        operation: () -> PluginRegistryResult<ProductPluginRecord>,
        restoreOnActivationFailure!: Bool = false
    ): PluginRegistryResult<ProductPluginRecord> {
        let current = match (pluginRuntime.resolveForMutation(id, scope: Some(scope))) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        replaceResolvedProductPlugin(id, current, operation, restoreOnActivationFailure: restoreOnActivationFailure)
    }

    private func replaceResolvedProductPlugin(
        id: String,
        current: ProductPluginRecord,
        operation: () -> PluginRegistryResult<ProductPluginRecord>,
        restoreOnActivationFailure!: Bool
    ): PluginRegistryResult<ProductPluginRecord> {
        let effectiveBefore = pluginRuntime.get(id)
        let wasActive = match (effectiveBefore) {
            case Some(previous) => previous.enabled && previous.descriptor.sameText(PluginDescriptorText.Namespace, current.descriptor, PluginDescriptorText.Namespace) &&
                pluginScopeEquals(previous.scope, current.scope)
            case None => false
        }
        if (wasActive) {
            match (deactivateProductPlugin(current)) {
                case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
                case PluginRegistryResult.Ok(_) => ()
            }
        }
        let mounted = match (withdrawMountedProductPluginInstances()) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        try {
        match (operation()) {
            case PluginRegistryResult.Err(error) =>
                match (remountProductPluginInstances(mounted)) {
                    case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(error)
                    case PluginRegistryResult.Ok(_) => ()
                }
                if (wasActive) {
                    match (activateProductPlugin(current)) {
                        case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                        case PluginRegistryResult.Ok(_) => ()
                    }
                }
                PluginRegistryResult.Err(error)
            case PluginRegistryResult.Ok(record) =>
                let effectiveAfter = pluginRuntime.get(id)
                let shouldActivate = match (effectiveAfter) {
                    case Some(active) => active.enabled && active.descriptor.sameText(PluginDescriptorText.Namespace, record.descriptor, PluginDescriptorText.Namespace) &&
                        pluginScopeEquals(active.scope, record.scope)
                    case None => false
                }
                let activation = match (remountProductPluginInstances(mounted)) {
                    case PluginRegistryResult.Err(error) => PluginRegistryResult<Unit>.Err(error)
                    case PluginRegistryResult.Ok(_) => if (shouldActivate) { activateProductPlugin(effectiveAfter.getOrThrow()) } else { PluginRegistryResult<Unit>.Ok(()) }
                }
                match (activation) {
                    case PluginRegistryResult.Ok(_) => PluginRegistryResult.Ok(record)
                    case PluginRegistryResult.Err(error) =>
                        match (withdrawProductPluginInstances(mounted)) {
                            case PluginRegistryResult.Err(withdrawError) => return PluginRegistryResult.Err(withdrawError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        let rollback = if (restoreOnActivationFailure) {
                            pluginRuntime.rollback(id, current.scope)
                        } else { pluginRuntime.setEnabled(id, false, current.scope) }
                        match (rollback) {
                            case PluginRegistryResult.Err(rollbackError) =>
                                if (restoreOnActivationFailure) {
                                    match (pluginRuntime.setEnabled(id, false, current.scope)) {
                                        case PluginRegistryResult.Err(quarantineError) =>
                                            match (remountProductPluginInstances(mounted)) {
                                                case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(quarantineError)
                                                case PluginRegistryResult.Ok(_) => return PluginRegistryResult.Err(quarantineError)
                                            }
                                        case PluginRegistryResult.Ok(_) => ()
                                    }
                                }
                                // The durable writer's complete paid error is
                                // primary even if fresh reinspection also fails.
                                match (remountProductPluginInstances(mounted)) {
                                    case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(rollbackError)
                                    case PluginRegistryResult.Ok(_) => return PluginRegistryResult.Err(rollbackError)
                                }
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        match (remountProductPluginInstances(mounted)) {
                            case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        if (restoreOnActivationFailure && wasActive) {
                            match (pluginRuntime.get(id)) {
                                case Some(restored) => if (restored.enabled) {
                                    match (activateProductPlugin(restored)) {
                                        case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                                        case PluginRegistryResult.Ok(_) => ()
                                    }
                                }
                                case None => ()
                            }
                        }
                        PluginRegistryResult.Err(error)
                }
        }
        } finally { mounted.close() }
    }

    public func updateLocalPlugin(
        id: String,
        root: String,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        replaceActiveProductPluginInScope(
            id,
            scope,
            { => pluginRuntime.updateLocal(id, root, scope) },
            restoreOnActivationFailure: true
        )
    }

    public func rollbackPlugin(id: String, scope: PluginInstallScope): PluginRegistryResult<ProductPluginRecord> {
        replaceActiveProductPluginInScope(
            id,
            scope,
            { => pluginRuntime.rollback(id, scope) },
            restoreOnActivationFailure: true
        )
    }

    public func updatePluginSource(
        id: String,
        sessionId: SessionId,
        source: ProductPluginSourceRequest,
        approvalDecision!: ApprovalDecision
    ): PluginRegistryResult<ProductPluginRecord> {
        let current = match (pluginRuntime.resolveForMutation(id)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        updatePluginSourceInScope(id, current.scope, sessionId, source, approvalDecision)
    }

    public func updatePluginSource(
        id: String,
        scope: PluginInstallScope,
        sessionId: SessionId,
        source: ProductPluginSourceRequest,
        approvalDecision!: ApprovalDecision
    ): PluginRegistryResult<ProductPluginRecord> {
        updatePluginSourceInScope(id, scope, sessionId, source, approvalDecision)
    }

    private func updatePluginSourceInScope(
        id: String,
        scope: PluginInstallScope,
        sessionId: SessionId,
        source: ProductPluginSourceRequest,
        approvalDecision: ApprovalDecision
    ): PluginRegistryResult<ProductPluginRecord> {
        let current = match (pluginRuntime.resolveForMutation(id, scope: Some(scope))) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        let spec = match (productPluginSourceSpec(source, shellNetworkMode)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return PluginRegistryResult.Err(pluginRuntime.ownedError(error.code, error.message))
        }
        match (pluginRuntime.cachedSource(spec, scope, id: id)) {
            case Some(record) => return PluginRegistryResult.Ok(record)
            case None => ()
        }
        let acquirer = ProductPluginSourceAcquirer(
            vnext, ids, workspace.rootPath(), settingsRoot
        )
        match (acquirer.acquire(sessionId, spec, approvalDecision)) {
            case PluginImportResult.Err(error) => PluginRegistryResult.Err(pluginRuntime.ownedError(error.code, error.message))
            case PluginImportResult.Ok(acquired) =>
                try {
                    let descriptor = match (pluginRuntime.inspect(acquired.packageRoot)) {
                        case PluginRegistryResult.Ok(value) => value
                        case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
                    }
                    if (productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)) != productRegistryCopyText83(current.descriptor.copyText(PluginDescriptorText.Namespace))) {
                        return productRegistryFailure83(pluginRuntime, 
                            "plugin.update_id_mismatch",
                            "updated source package namespace does not match the imported plugin"
                        )
                    }
                    replaceActiveProductPluginInScope(
                        id,
                        scope,
                        { => pluginRuntime.updateAcquiredSource(id, acquired, scope) },
                        restoreOnActivationFailure: true
                    )
                } finally {
                    acquirer.cleanup(acquired)
                }
        }
    }

    public func rollbackPlugin(id: String): PluginRegistryResult<ProductPluginRecord> {
        replaceActiveProductPlugin(
            id,
            { => pluginRuntime.rollback(id) },
            restoreOnActivationFailure: true
        )
    }
    public func uninstallPlugin(id: String): PluginRegistryResult<Unit> {
        let current = match (pluginRuntime.resolveForMutation(id)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        uninstallPlugin(id, current.scope)
    }


    public func uninstallPlugin(id: String, scope: PluginInstallScope): PluginRegistryResult<Unit> {
        let current = match (pluginRuntime.resolveForMutation(id, scope: Some(scope))) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        let effectiveBefore = pluginRuntime.get(id)
        let wasEffective = match (effectiveBefore) {
            case Some(previous) => previous.descriptor.sameText(PluginDescriptorText.Namespace, current.descriptor, PluginDescriptorText.Namespace) &&
                pluginScopeEquals(previous.scope, current.scope)
            case None => false
        }
        let wasActive = wasEffective && current.enabled
        if (wasActive) {
            match (deactivateProductPlugin(current)) {
                case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
                case PluginRegistryResult.Ok(_) => ()
            }
        }
        let mounted = match (withdrawMountedProductPluginInstances()) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        try {
        match (pluginRuntime.uninstall(id, scope)) {
            case PluginRegistryResult.Err(error) =>
                match (remountProductPluginInstances(mounted)) {
                    case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(error)
                    case PluginRegistryResult.Ok(_) => ()
                }
                if (wasActive) {
                    match (activateProductPlugin(current)) {
                        case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                        case PluginRegistryResult.Ok(_) => ()
                    }
                }
                PluginRegistryResult.Err(error)
            case PluginRegistryResult.Ok(_) =>
                let activation = match (remountProductPluginInstances(mounted)) {
                    case PluginRegistryResult.Err(error) => PluginRegistryResult<Unit>.Err(error)
                    case PluginRegistryResult.Ok(_) => match (pluginRuntime.get(id)) {
                        case Some(active) => if (wasEffective && active.enabled) { activateProductPlugin(active) } else { PluginRegistryResult<Unit>.Ok(()) }
                        case None => PluginRegistryResult<Unit>.Ok(())
                    }
                }
                match (activation) {
                    case PluginRegistryResult.Ok(_) => PluginRegistryResult.Ok(())
                    case PluginRegistryResult.Err(error) =>
                        match (withdrawProductPluginInstances(mounted)) {
                            case PluginRegistryResult.Err(withdrawError) => return PluginRegistryResult.Err(withdrawError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        match (pluginRuntime.restoreRecord(current)) {
                            case PluginRegistryResult.Err(restoreError) =>
                                match (remountProductPluginInstances(mounted)) {
                                    case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(restoreError)
                                    case PluginRegistryResult.Ok(_) => return PluginRegistryResult.Err(restoreError)
                                }
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        match (remountProductPluginInstances(mounted)) {
                            case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        if (wasActive) {
                            match (activateProductPlugin(current)) {
                                case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                                case PluginRegistryResult.Ok(_) => ()
                            }
                        }
                        PluginRegistryResult.Err(error)
                }
        }
        } finally { mounted.close() }
    }

    public func garbageCollectPlugins(): PluginRegistryResult<OwnedRegistryTextList> {
        pluginRuntime.garbageCollect()
    }

    public func setPluginEnabled(id: String, enabled: Bool): PluginRegistryResult<ProductPluginRecord> {
        let current = match (pluginRuntime.resolveForMutation(id)) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        setPluginEnabled(id, enabled, current.scope)
    }

    public func setPluginEnabled(
        id: String,
        enabled: Bool,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        let target = match (pluginRuntime.resolveForMutation(id, scope: Some(scope))) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        let explicitDisableChange = pluginScopeEquals(scope, PluginInstallScope.User) &&
            !enabled && !target.explicitlyDisabled
        if (target.enabled == enabled && !explicitDisableChange &&
            (!enabled || target.descriptor.entryKind != PluginEntryKind.NativeExecutable ||
                vnext.javascriptPlugins.instanceGeneration(target.descriptor) != 0u64)) {
            return PluginRegistryResult.Ok(target)
        }
        let effectiveBefore = pluginRuntime.get(id)
        match (effectiveBefore) {
            case Some(previous) =>
                if (previous.enabled) {
                    match (deactivateProductPlugin(previous)) {
                        case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
                        case PluginRegistryResult.Ok(_) => ()
                    }
                }
            case None => ()
        }
        let mounted = match (withdrawMountedProductPluginInstances()) {
            case PluginRegistryResult.Ok(value) => value
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
        }
        try {
        match (pluginRuntime.setEnabled(id, enabled, scope)) {
            case PluginRegistryResult.Err(error) =>
                match (remountProductPluginInstances(mounted)) {
                    // A failed reinspection must not replace the durable
                    // writer rejection (including its paid source/field data).
                    // Leave those generations revoked and return failure.
                    case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(error)
                    case PluginRegistryResult.Ok(_) => ()
                }
                match (effectiveBefore) {
                    case Some(previous) => if (previous.enabled) {
                        match (activateProductPlugin(previous)) {
                            case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                    }
                    case None => ()
                }
                PluginRegistryResult.Err(error)
            case PluginRegistryResult.Ok(record) =>
                let activation = match (remountProductPluginInstances(mounted)) {
                    case PluginRegistryResult.Err(error) => PluginRegistryResult<Unit>.Err(error)
                    case PluginRegistryResult.Ok(_) => match (pluginRuntime.get(id)) {
                        case Some(active) => if (active.enabled) { activateProductPlugin(active) } else { PluginRegistryResult<Unit>.Ok(()) }
                        case None => PluginRegistryResult<Unit>.Ok(())
                    }
                }
                match (activation) {
                    case PluginRegistryResult.Ok(_) => PluginRegistryResult.Ok(record)
                    case PluginRegistryResult.Err(error) =>
                        match (withdrawProductPluginInstances(mounted)) {
                            case PluginRegistryResult.Err(withdrawError) => return PluginRegistryResult.Err(withdrawError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        match (pluginRuntime.restoreRecord(target)) {
                            case PluginRegistryResult.Err(restoreError) =>
                                match (remountProductPluginInstances(mounted)) {
                                    case PluginRegistryResult.Err(_) => return PluginRegistryResult.Err(restoreError)
                                    case PluginRegistryResult.Ok(_) => return PluginRegistryResult.Err(restoreError)
                                }
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        // Rollback publishes the lock again. Retire the failed
                        // publication's new generations before recapturing the
                        // same prior-mounted set from the restored Registry.
                        match (remountProductPluginInstances(mounted)) {
                            case PluginRegistryResult.Err(remountError) => return PluginRegistryResult.Err(remountError)
                            case PluginRegistryResult.Ok(_) => ()
                        }
                        match (effectiveBefore) {
                            case Some(previous) => if (previous.enabled) {
                                match (activateProductPlugin(previous)) {
                                    case PluginRegistryResult.Err(restoreError) => return PluginRegistryResult.Err(restoreError)
                                    case PluginRegistryResult.Ok(_) => ()
                                }
                            }
                            case None => ()
                        }
                        PluginRegistryResult.Err(error)
                }
        }
        } finally { mounted.close() }
    }

    private func mountedProductPluginInstances(): ProductMountedPluginInstances83 {
        // Freeze only actual live identities, in the paid Registry topological
        // order. Enabled-but-withdrawn dependents are deliberately excluded.
        productRegistryMountedInstances83(pluginRuntime.startupEffectiveRecords(), { record =>
            record.descriptor.entryKind == PluginEntryKind.NativeExecutable &&
                vnext.javascriptPlugins.instanceGeneration(record.descriptor) != 0u64 })
    }

    private func withdrawProductPluginInstances(records: ProductMountedPluginInstances83): PluginRegistryResult<Unit> {
        records.visit({ record => deactivateProductPlugin(record) })
    }

    private func withdrawMountedProductPluginInstances(): PluginRegistryResult<ProductMountedPluginInstances83> {
        let mounted = mountedProductPluginInstances()
        match (withdrawProductPluginInstances(mounted)) {
            case PluginRegistryResult.Err(error) =>
                let restored = remountProductPluginInstances(mounted)
                mounted.close()
                match (restored) {
                    case PluginRegistryResult.Err(restoreError) => PluginRegistryResult.Err(restoreError)
                    case PluginRegistryResult.Ok(_) => PluginRegistryResult.Err(error)
                }
            case PluginRegistryResult.Ok(_) => PluginRegistryResult.Ok(mounted)
        }
    }

    private func remountProductPluginInstances(records: ProductMountedPluginInstances83): PluginRegistryResult<Unit> {
        // Every durable publication, including rollback, revokes the full old
        // generation. Reuse canonical catalog revoke/mount and fresh fenced
        // captures; never adapt an old pin, prepared plan or approval.
        match (withdrawProductPluginInstances(records)) {
            case PluginRegistryResult.Err(error) => return PluginRegistryResult.Err(error)
            case PluginRegistryResult.Ok(_) => ()
        }
        records.visit({ record => activateProductPlugin(record) })
    }

    public func codexHookDiagnostics(): Array<String> {
        codexHookRuntime.diagnostics()
    }






    // Root uses this only after every original frontend Future/helper has
    // returned. It neither cancels persistent jobs nor acknowledges DATA.
    func hasOwnerLifetimeDebt180(): Bool {
        if (taskRuntime.hasOwnerLifetimeDebt180()) { return true }
        nativeFrontendLock.lock()
        try { if (!nativeFrontendInvocations.isEmpty()) { return true } }
        finally { nativeFrontendLock.unlock() }
        managedPluginServiceLock.lock()
        try {
            match (managedPluginServices) {
                case Some(value) => value.hasOwnerLifetimeDebt180()
                case None => false }
        } finally { managedPluginServiceLock.unlock() }
    }

    public func close(): Result<Unit> {
        if (taskRuntime.hasPluginChildDebt111()) {
            // This exact live continuation still needs the mounted Native
            // artifact and its original Registry custody to finish. Do not
            // enter the old unconditional Registry-close finally until the
            // actual child owners have settled; an error remains retryable.
            match(closeNativeFrontendInvocations()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(closeManagedPluginServices()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(taskRuntime.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        }
        try {
        match(closeNativeFrontendInvocations()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        // Do not tear down Store or native infrastructure while a managed
        // startup/invocation still owns cleanup. A later close can retry.
        match (closeManagedPluginServices()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let vnextResult = vnext.close()
        match (vnextResult) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let taskResult = taskRuntime.close()
        match (taskResult) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let processResult = processes.close()
        match (processResult) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (codexHookRuntime.closeHookGenerationData159g()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        // Closing OS resources alone is not consumer retirement. The concrete
        // input owner additionally requires all real API/Future/helper frames
        // to have returned and clears its own private caches before payment.
        match (installedModelInputOwner159) { case None => (); case Some(owner) =>
            match (owner.closeModelInputData159()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
        contextReadCore.collectReturnedModelInputs159()
        try {
            vnextDatabase.close()
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Internal,
                "product.state_database_close_failed",
                error.message
            ))
        }
        match (vnextResult) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        match (taskResult) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => match (processResult) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => Result.Ok(())
            }
        }
        } finally {
            // Every frame/callback of this Product has returned, so the copies
            // it made can no longer be read and their DATA debt retires. These
            // copied payments are children of the Registry metadata custody, so
            // they retire before that parent closes. A retried close() is not a
            // second retirement.
            escapedCopyDebtLock.lock()
            let retireDebt = try {
                if (escapedCopyDebtClosed) { false } else { escapedCopyDebtClosed = true; true }
            } finally { escapedCopyDebtLock.unlock() }
            if (retireDebt) { productRegistryEscapedCopies83.endProduct() }
            pluginRuntime.close()
        }
    }


    public func toolsFor(capabilities: CapabilitySet, threadId!: ?ThreadId = None): Array<ModelToolDefinition> {
        catalog.definitionsFor(capabilities, threadId: threadId)
    }

    func acquireNativeFrontendInvocation(selection: ProductSelectedNativeTool,
        operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>,
        callerCancellation180!: ?domain.CancellationToken = None<domain.CancellationToken>): Result<ProductNativeToolInvocation> {
        nativeFrontendLock.lock()
        try{
            if(nativeFrontendsClosing || nativeFrontendInvocations.size>=64){
                return selectedNativeToolError("plugin.frontend_cleanup_capacity")}
            let actual=ProductNativeToolInvocation(selection,operatorOptions180:operatorOptions180,callerCancellation180:callerCancellation180)
            nativeFrontendInvocations.add(actual)
            Result.Ok(actual)
        }finally{nativeFrontendLock.unlock()}
    }
    func releaseNativeFrontendInvocation(actual: ProductNativeToolInvocation): Unit {
        nativeFrontendLock.lock()
        try{
            for(index in 0..nativeFrontendInvocations.size where refEq(nativeFrontendInvocations[index],actual)){
                nativeFrontendInvocations.remove(at:index);return}
        }finally{nativeFrontendLock.unlock()}
    }
    private func closeNativeFrontendInvocations(): Result<Unit> {
        nativeFrontendLock.lock()
        let actual=try{nativeFrontendsClosing=true;nativeFrontendInvocations.toArray()}finally{nativeFrontendLock.unlock()}
        for(invocation in actual){match(invocation.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
        Result.Ok(())
    }
    func acquireShellToolInvocation(sessionId: SessionId, readOnly!: Bool=false,
        networkPolicy!: ?NetworkPolicy=None,
        operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>,
        callerCancellation180!: ?domain.CancellationToken = None<domain.CancellationToken>): Result<ProductNativeToolInvocation> {
        let selection=match(selectProductNativeFrontendTool(this,sessionId,if(readOnly){"shell-readonly"}else{"shell"},if(readOnly){"exec"}else{"bash"},networkPolicy:networkPolicy)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        acquireNativeFrontendInvocation(selection,operatorOptions180:operatorOptions180,callerCancellation180:callerCancellation180)
    }

    public func invokeShellTool(sessionId: SessionId, arguments: AgentValue,
        readOnly!: Bool=false, budget!: ExecutionBudget=ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1),
        operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>,
        callerCancellation180!: ?domain.CancellationToken = None<domain.CancellationToken>
    ): Result<ProductNativeToolInvocation> {
        let selection=match(selectProductNativeFrontendTool(this,sessionId,if(readOnly){"shell-readonly"}else{"shell"},if(readOnly){"exec"}else{"bash"})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let canonicalArguments=match(selection.shellArguments(arguments)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let invocation=match(acquireNativeFrontendInvocation(selection,operatorOptions180:operatorOptions180,callerCancellation180:callerCancellation180)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(invocation.start(canonicalArguments,budget)){
            case Result.Err(error)=>invocation.recordFailure(error);case Result.Ok(_)=>()}
        Result.Ok(invocation)
    }

    public func invokeProgramTool(sessionId: SessionId, code: String,
        budget!: ExecutionBudget=ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1),
        operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>,
        callerCancellation180!: ?domain.CancellationToken = None<domain.CancellationToken>
    ): Result<ProductNativeToolInvocation> {
        let selection=match(selectProductNativeFrontendTool(this,sessionId,"program","run")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let invocation=match(acquireNativeFrontendInvocation(selection,operatorOptions180:operatorOptions180,callerCancellation180:callerCancellation180)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(invocation.start(objectValue([ValueField("code",textValue(code))]),budget)){
            case Result.Err(error)=>invocation.recordFailure(error);case Result.Ok(_)=>()}
        Result.Ok(invocation)
    }

    public func invokeWorkspaceTool(sessionId: SessionId, contribution: String, arguments: AgentValue,
        operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>,
        callerCancellation180!: ?domain.CancellationToken = None<domain.CancellationToken>): Result<ProductWorkspaceInvocation> {
        let selection=match(selectProductWorkspaceTool(this,sessionId,contribution)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let invocation=ProductWorkspaceInvocation(this,selection,operatorOptions180:operatorOptions180,callerCancellation180:callerCancellation180)
        match(invocation.start(arguments)){
            case Result.Err(error)=>let _=invocation.close();Result.Err(error)
            case Result.Ok(_)=>Result.Ok(invocation)}
    }
    func nextWorkspaceCallId(): String { ids.nextOperationId().value }

    public func invokeLocalTool(
        sessionId: SessionId,
        name: String,
        arguments: AgentValue,
        contextSnapshot!: InvocationContextProjection = InvocationContextProjection(),
        operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>,
        callerCancellation180!: ?domain.CancellationToken = None<domain.CancellationToken>
    ): Result<ToolResult> {
        let callId = "cli-" + name + "-" + ids.nextOperationId().value
        let capabilities = CapabilitySet(
            values: [
                Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.WorkspaceWrite),
                Capability(CapabilityKind.ProcessSpawn),
                Capability(CapabilityKind.NetworkAccess),
                Capability(CapabilityKind.ExtensionInvoke),
                Capability(CapabilityKind.PeerMessage),
                Capability(CapabilityKind.Delegate)
            ]
        )
        match (vnext.executeCanonicalTool(
            sessionId,
            capabilities,
            ToolCall(callId, name, arguments),
            contextSnapshot: contextSnapshot, operatorOptions180: operatorOptions180, callerCancellation180: callerCancellation180
        )) {
            case Result.Ok(ToolInvocationResult.Completed(result)) =>
                if (result.isError) {
                    try { Result.Err(productToolResultError(result)) } finally { result.releasePayload() }
                } else {
                    Result.Ok(result)
                }
            case Result.Ok(ToolInvocationResult.NeedsApproval(approval)) => Result.Err(
                AgentError(
                    AgentErrorKind.PermissionDenied,
                    "cli.tool_approval_required",
                    "CLI tool invocation requires approval",
                    fields: [
                        ErrorField(
                            "operation_id",
                            approval.operationId.value
                        ),
                        ErrorField("tool", name)
                    ]
                )
            )
            case Result.Ok(ToolInvocationResult.Denied(denial)) => Result.Err(denial.reason)
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func registerTool(
        descriptor: ToolDescriptor,
        executor: ToolExecutor
    ): Result<Unit> {
        catalog.register(descriptor, executor)
    }

    public func unregisterTool(name: String): Bool {
        catalog.unregister(name)
    }

    public func registerUriHandler(
        scheme: String,
        handler: InternalUriHandler
    ): Result<Unit> {
        uriRouter.register(scheme, handler)
    }

    public func unregisterUriScheme(scheme: String): Bool {
        uriRouter.unregister(scheme)
    }

    public func uriSchemes(custody!: ?OwnedApplicationRegistryResponse161 = None): Array<String> {
        uriRouter.schemes(custody: custody)
    }

    public func setAskInteractive(
        sessionId: SessionId,
        enabled: Bool
    ): Unit {
        askRuntime.setInteractive(sessionId, enabled)
    }

    public func subscribeAsks(sink: ProductAskEventSink): Unit {
        askRuntime.subscribe(sink)
    }
    public func subscribeOwnerAsks180(sink: ProductAskEventSink): Int64 { askRuntime.subscribeOwnerAsks180(sink) }
    public func unsubscribeOwnerAsks180(id: Int64): Unit { askRuntime.unsubscribeOwnerAsks180(id) }

    public func pendingAsk(sessionId: SessionId): ?ProductAskRequest {
        askRuntime.current(sessionId)
    }

    public func answerAsk(
        sessionId: SessionId,
        requestId: String,
        resolution: ProductAskResolution
    ): Result<Unit> {
        askRuntime.resolve(sessionId, requestId, resolution)
    }

    public func subagents(sessionId: SessionId): Array<ProductSubagentSnapshot> {
        taskRuntime.activeSubagents(sessionId)
    }

    public func messageSubagent(
        rootSessionId: SessionId,
        subagentId: String,
        message: String
    ): Result<Unit> {
        taskRuntime.messageSubagent(
            rootSessionId,
            subagentId,
            message
        )
    }

    public func cancelSubagent(
        rootSessionId: SessionId,
        subagentId: String
    ): Result<Unit> {
        taskRuntime.cancelSubagent(rootSessionId, subagentId)
    }

    public func decideSubagentApproval(
        rootSessionId: SessionId,
        subagentId: String,
        decision: ApprovalDecision
    ): Result<Unit> {
        taskRuntime.decideSubagentApproval(
            rootSessionId,
            subagentId,
            decision
        )
    }

    public func allSubagents(sessionId: SessionId): Array<ProductSubagentSnapshot> {
        taskRuntime.allSubagents(sessionId)
    }

    public func asyncJobs(sessionId: SessionId): Array<ProductAsyncJobSnapshot> {
        taskRuntime.jobsFor(sessionId)
    }

    public func taskRecoveryWarnings(sessionId: SessionId): Array<String> {
        taskRuntime.recoveryWarningsForSession(sessionId)
    }

    public func waitForAsyncJobs(
        sessionId: SessionId,
        ids: Array<String>,
        timeoutMillis: Int64
    ): Array<ProductAsyncJobSnapshot> {
        taskRuntime.waitForJobs(sessionId, ids, timeoutMillis)
    }

    public func cancelAsyncJobs(
        sessionId: SessionId,
        ids: Array<String>
    ): Array<ProductAsyncJobSnapshot> {
        taskRuntime.cancelJobs(sessionId, ids)
    }

    public func subagentTranscript(
        sessionId: SessionId,
        subagentId!: String = "",
        sessionRef!: String = "",
        fromItem!: Int64 = 0
    ): Result<ProductSubagentTranscript> {
        taskRuntime.transcript(
            sessionId,
            subagentId: subagentId,
            sessionRef: sessionRef,
            fromItem: fromItem
        )
    }

    public func subscribeSubagents(sink: ProductSubagentEventSink): Int64 {
        taskRuntime.subscribe(sink)
    }

    public func subscribeAsyncJobs(sink: ProductAsyncJobEventSink): Int64 {
        taskRuntime.subscribeJobs(sink)
    }
    public func unsubscribeSubagents180(id: Int64): Unit { taskRuntime.unsubscribeSubagents180(id) }
    public func unsubscribeAsyncJobs180(id: Int64): Unit { taskRuntime.unsubscribeAsyncJobs180(id) }

    public func models(): Array<String> {
        modelNames
    }

    public func modelEntries(): Array<ModelCatalogEntry> {
        modelCatalog
    }

    public func modelMetadata(modelId: String): ?ModelCatalogEntry {
        for (entry in modelCatalog where entry.displayId() == modelId) {
            return Some(entry)
        }
        None
    }

    public func providers(): Array<ProviderProfile> {
        providerProfiles
    }

    public func modelProvider(modelId: String): String {
        for (entry in modelCatalog where entry.displayId() == modelId) {
            for (profile in providerProfiles where profile.id == entry.providerProfile) {
                return profile.provider
            }
            return entry.providerProfile
        }
        if (modelId == "fixture") {
            return "fixture"
        }
        providerIdForModel(modelId)
    }

    public func rawModelId(modelId: String): String {
        for (entry in modelCatalog where entry.displayId() == modelId) {
            return entry.id
        }
        modelId
    }

    public func resolveModel(
        provider: String,
        modelId: String
    ): Result<String> {
        let requestedProvider = provider.trimAscii()
        let requestedModel = modelId.trimAscii()
        if (requestedProvider == "" || requestedModel == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "model.selector_incomplete",
                    "provider and modelId are required"
                )
            )
        }
        for (entry in modelCatalog where entry.id == requestedModel) {
            for (profile in providerProfiles where profile.id == entry.providerProfile) {
                if (profile.id == requestedProvider || profile.provider == requestedProvider) {
                    return Result.Ok(entry.displayId())
                }
            }
        }
        if (modelCatalog.isEmpty() && requestedProvider == "fixture" && requestedModel == "fixture") {
            return Result.Ok("fixture")
        }
        Result.Err(
            AgentError(
                AgentErrorKind.InvalidInput,
                "model.unknown",
                "Model not found: " + requestedProvider + "/" + requestedModel,
                fields: [
                    ErrorField("provider", requestedProvider),
                    ErrorField("model", requestedModel)
                ]
            )
        )
    }

    public func providerAvailable(profileId: String): Bool {
        match (profileById(profileId)) {
            case Some(profile) => profile.authentication == "api-key"
            case None => false
        }
    }

    public func providerAuthenticated(profileId: String): Bool {
        let profile = match (profileById(profileId)) {
            case Some(value) => value
            case None => return false
        }
        match (getVariable(profile.apiKeyEnv)) {
            case Some(value) =>
                if (value.trimAscii() != "") {
                    return true
                }
            case None => ()
        }
        let path = match (providerCredentialPath(settingsRoot, profile.id)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return false
        }
        if (!exists(Path(path))) {
            return false
        }
        try {
            !String.fromUtf8(File.readFrom(path)).trimAscii().isEmpty()
        } catch (_: Exception) {
            false
        }
    }

    public func providerId(): String {
        providerIdForModel(model)
    }

    public func providerIdForModel(modelId: String): String {
        for (entry in modelCatalog where entry.displayId() == modelId) {
            if (entry.providerProfile != "") {
                return entry.providerProfile
            }
        }
        let separator = modelId.indexOf("/")
        match (separator) {
            case Some(index) =>
                if (index > 0) {
                    modelId[..index]
                } else {
                    ""
                }
            case None => ""
        }
    }

    public func fastModeEnabled(sessionId: SessionId): Bool {
        match (sessionMetadata.fastMode(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => false
        }
    }

    public func fastModeActive(
        sessionId: SessionId,
        modelId: String
    ): Bool {
        fastModeEnabled(sessionId) && fastTierForModel(modelId) != ""
    }

    public func setFastMode(
        sessionId: SessionId,
        modelId: String,
        enabled: Bool
    ): Result<Bool> {
        if (!enabled) {
            return match (sessionMetadata.setFastMode(sessionId, false)) {
                case Result.Ok(_) => Result.Ok(false)
                case Result.Err(error) => Result.Err(error)
            }
        }
        if (fastTierForModel(modelId) == "") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "model.fast_mode_unsupported",
                "Fast mode is unavailable for the current model.",
                fields: [ErrorField("model", modelId)]
            ))
        }
        match (sessionMetadata.setFastMode(sessionId, true)) {
            case Result.Ok(_) => Result.Ok(true)
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func contextUsage(
        sessionId: SessionId,
        modelId: String
    ): ProductContextUsage {
        let metadata = match (modelMetadata(modelId)) {
            case Some(value) => value
            case None => return ProductContextUsage(Option<Int64>.None, Option<Int64>.None, Option<Float64>.None)
        }
        let window = match (metadata.contextWindow) {
            case Some(value) => value
            case None => return ProductContextUsage(Option<Int64>.None, Option<Int64>.None, Option<Float64>.None)
        }
        let tokens = match (runs.stats(sessionId)) {
            // Provider usage is authoritative when at least one model request
            // has completed. It is persisted with the run snapshot, so this
            // remains stable across reopen and after conversation compaction.
            case Result.Ok(value) => if (value.modelRequests > 0) {
                value.lastInputTokens
            } else {
                match (modelContext(sessionId)) {
                    case Result.Ok(messages) => estimateMessagesTokens(messages)
                    case Result.Err(_) => return ProductContextUsage(Option<Int64>.None, Some(window), Option<Float64>.None)
                }
            }
            // Stats are an optimization for authoritative usage; if no usable
            // snapshot can be read, retain the deterministic projection
            // estimate instead of turning a healthy session into an error.
            case Result.Err(_) => match (modelContext(sessionId)) {
                case Result.Ok(messages) => estimateMessagesTokens(messages)
                case Result.Err(_) => return ProductContextUsage(Option<Int64>.None, Some(window), Option<Float64>.None)
            }
        }
        ProductContextUsage(
            Some(tokens),
            Some(window),
            // Match OMP: over-window usage remains visible as >100% instead
            // of being hidden by a display clamp.
            Some(Float64(tokens) * 100.0 / Float64(window))
        )
    }

    private func fastTierForModel(modelId: String): String {
        let entry = match (modelMetadata(modelId)) {
            case Some(value) => value
            case None => return ""
        }
        if (entry.fastServiceTier == "" || entry.providerProfile == "") {
            return ""
        }
        let profile = match (profileById(entry.providerProfile)) {
            case Some(value) => value
            case None => return ""
        }
        if (profile.protocol == "responses" || profile.protocol == "completions") {
            return entry.fastServiceTier
        }
        if (profile.protocol == "messages" && profile.provider.toAsciiLower() == "anthropic" &&
            entry.fastServiceTier == "priority") {
            return entry.fastServiceTier
        }
        ""
    }

    // Package-only paid DATA reader. The caller supplies its actual existing
    // allocation, and independently copies selected text before this Unit
    // loan returns. No Host/Registry lock is taken while SQLite holds its TX.
    func withTaskFinalText151(sessionId: SessionId,
        allocate: (Int64) -> LogicalJsonOwnerReservation, local: () -> Result<Unit>,
        consume: (String) -> Unit): Result<Unit> {
        productVisitTaskLastText151(vnextDatabase, sessionId, allocate, local, consume)
    }

    public func messages(sessionId: SessionId): Result<Array<ModelMessage>> {
        match (threadItems(sessionId)) {
            case Result.Ok(items) => Result.Ok(modelMessagesFromCanonicalItems(items))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func threadItems(sessionId: SessionId): Result<Array<ThreadItem>> {
        if (vnextDatabase.scalarInt(
            "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(sessionId.value)
        ) == 0) {
            return Result.Ok([])
        }
        try {
            Result.Ok(SqliteThreadCommitSink(vnextDatabase).loadThread(
                ThreadId(sessionId.value)
            ).items)
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "product.canonical_thread_unavailable",
                error.message,
                fields: [ErrorField("thread_id", sessionId.value)]
            ))
        }
    }

    private func canonicalThreadSnapshot(
        sessionId: SessionId
    ): Result<AgentThreadSnapshot> {
        if (vnextDatabase.scalarInt(
            "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(sessionId.value)
        ) == 0) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "product.thread_not_found",
                "canonical Thread does not exist",
                fields: [ErrorField("thread_id", sessionId.value)]
            ))
        }
        try {
            Result.Ok(SqliteThreadCommitSink(vnextDatabase).loadThread(
                ThreadId(sessionId.value)
            ))
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "product.canonical_thread_unavailable",
                error.message,
                fields: [ErrorField("thread_id", sessionId.value)]
            ))
        }
    }

    public func threadItemsPage(
        sessionId: SessionId,
        beforeOrdinal!: Int64 = 0,
        limit!: Int64 = 512
    ): Result<ThreadItemsPage> {
        try {
            Result.Ok(SqliteThreadPageStore(vnextDatabase).loadItemsPage(
                ThreadId(sessionId.value), beforeOrdinal, limit
            ))
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "product.thread_page_unavailable",
                error.message,
                fields: [ErrorField("thread_id", sessionId.value)]
            ))
        }
    }

    public func latestRunId(threadId: ThreadId): Result<RunId> {
        ProductRunInspectionProjection(vnextDatabase).latestRunId(threadId)
    }

    public func runInspection(
        threadId: ThreadId,
        runId: RunId,
        beforeCursor!: Int64 = 0,
        limit!: Int64 = 25
    ): Result<AppRunInspectionPage> {
        ProductRunInspectionProjection(vnextDatabase).inspect(
            threadId, runId, beforeCursor, limit
        )
    }

    // Stable process-local App Protocol read boundary. Frontends do not reach
    // into SQLite or ThreadStore directly; the same command/event pair can be
    // transported out of process later without changing canonical ownership.
    public func appCommand(command: AppCommand): Result<AppEvent> {
        match (command.payload) {
            case AppCommandPayload.LoadItemsPage(threadId, beforeOrdinal, limit) =>
                let page = try {
                    SqliteThreadPageStore(vnextDatabase).loadItemsPage(
                        threadId, beforeOrdinal, limit
                    )
                } catch (error: Exception) {
                    return Result.Err(AgentError(
                        AgentErrorKind.RecoveryRequired,
                        "product.app_items_page_unavailable",
                        error.message,
                        fields: [ErrorField("thread_id", threadId.value)]
                    ))
                }
                match (command.meta.expectedThreadRevision) {
                    case Some(expected) => if (expected != page.threadRevision) {
                        return Result.Err(AgentError(
                            AgentErrorKind.Conflict,
                            "product.app_thread_revision_changed",
                            "Thread revision changed before the command was applied",
                            fields: [
                                ErrorField("thread_id", threadId.value),
                                ErrorField("expected_revision", expected.toString()),
                                ErrorField("actual_revision", page.threadRevision.toString())
                            ]
                        ))
                    }
                    case None => ()
                }
                Result.Ok(AppEvent(
                    AppEventMeta(
                        command.meta.clientSequence,
                        threadId,
                        page.threadRevision
                    ),
                    AppEventPayload.ItemsPage(page)
                ))
            case AppCommandPayload.InspectRun(threadId, runId, beforeCursor, limit) =>
                match (runInspection(
                    threadId, runId, beforeCursor: beforeCursor, limit: limit
                )) {
                    case Result.Ok(page) => Result.Ok(AppEvent(
                        AppEventMeta(
                            command.meta.clientSequence,
                            threadId,
                            page.threadRevision
                        ),
                        AppEventPayload.RunInspection(page)
                    ))
                    case Result.Err(error) => Result.Err(error)
                }
            case _ => Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "product.app_command_not_supported",
                "the in-process App Protocol bridge does not implement this command yet"
            ))
        }
    }

    public func modelContext(sessionId: SessionId): Result<Array<ModelMessage>> {
        // Diagnostic callers receive a provider-neutral projection of durable
        // truth. Actual model requests are built by AgentThreadRuntime with
        // ModelLane and ContextCheckpoint snapshots.
        messages(sessionId)
    }

    // External task/MCP/job notifications enter canonical Thread truth through
    // its sole owner. No provider DTO projection is persisted here.
    public func appendExternalMessageOnce(
        sessionId: SessionId,
        receiptId: String,
        message: ModelMessage,
        source!: String = "async_result"
    ): Result<Bool> {
        if (message.role != ModelRole.User || message.blocks.size != 1 ||
            message.blocks[0].kind != ModelBlockKind.Text) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "product.external_message_shape_invalid",
                "external canonical input must be one user text block"
            ))
        }
        let runtime = match (threadRuntimes.acquire(
            ThreadId(sessionId.value), workspace.rootPath()
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let committed = match (runtime.appendExternalUserTextOnce(
            receiptId,
            message.blocks[0].text,
            source: source,
            createdAtMillis: agentUtcMillis()
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(committed)
    }

    public func pendingContinuation(sessionId: SessionId): Result<?RunContinuation> {
        runs.pendingContinuation(sessionId)
    }

    public func pendingRecoveryContinuation(
        sessionId: SessionId
    ): Result<?RunContinuation> {
        runs.pendingRecoveryContinuation(sessionId)
    }

    public func pendingContextBoundary(sessionId: SessionId): Result<?RunContextBoundary> {
        runs.pendingContextBoundary(sessionId)
    }
    public func contextBoundaryRequest(value: RunContextBoundary, interactions: ?AgentInteractionSource, ownedEvents!: ?OwnedAgentEventSink = None<OwnedAgentEventSink>): Result<AgentRunRequest> {
        try { Result.Ok(coreContextBoundaryRequestFromValue(contextBoundaryField(value.data(), "request"), interactions: interactions, ownedEvents: ownedEvents)) }
            catch (error: Exception) { Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "context.boundary_request_invalid", error.message)) }
    }

    public func continuationRequest(
        value: RunContinuation,
        interactions: ?AgentInteractionSource,
        toolContext!: ?ToolContextDescriptor = None,
        ownedEvents!: ?OwnedAgentEventSink = None<OwnedAgentEventSink>
    ): Result<AgentRunRequest> {
        try { Result.Ok(AgentRunRequest(
            value.runId,
            value.sessionId,
            value.model,
            value.prompt,
            system: value.system,
            thinking: value.thinking,
            userRequestedThinking: match (value.requestedPolicy) {
                case Some(policy) => policy.userRequestedThinking
                case None => Option<ThinkingLevel>.None
            },
            thinkingSource: match (value.requestedPolicy) {
                case Some(policy) => policy.thinkingSource
                case None => ThinkingPreferenceSource.ModelDefault
            },
            modelCapabilitiesSnapshot: value.modelCapabilitiesSnapshot,
            resolverVersion: value.resolverVersion,
            capabilities: value.capabilities,
            budget: value.budget,
            interactions: interactions,
            approvalModeOverride: productApprovalModeFromName(value.approvalMode),
            autoRetry: value.autoRetry,
            serviceTier: value.serviceTier,
            pricing: value.pricing,
            imageInputs: value.imageInputs,
            structuredOutput: value.structuredOutput,
            cachePolicy: value.cachePolicy,
            cacheKey: value.cacheKey,
            parallelToolCalls: value.parallelToolCalls,
            toolContext: match (toolContext) { case Some(value) => value
                case None => productToolContext(workspace.rootPath()) },
            contextSnapshot: if (value.contextSnapshotPayload.unifiedKind == ValueKind.Object && value.contextSnapshotPayload.fields.isEmpty()) {
                InvocationContextProjection()
            } else { contextSnapshotFromValue(value.contextSnapshotPayload) },
            contextWindow: value.contextWindow,
            providerSafetyMargin: value.providerSafetyMargin,
            executionLaneId: value.executionLaneId,
            ownedEvents: ownedEvents
        )) } catch (_: Exception) {
            Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "context.snapshot_unsupported_or_invalid",
                "durable recovery request contains an unsupported or invalid context snapshot"))
        }
    }

    // The Core may replace context at a canonical safe cut while the UI is
    // waiting on an earlier approval. Adopt its current request as data only;
    // never rewrite that continuation from the UI's pre-cut request.
    func currentApprovalRequest(previous: AgentRunRequest, snapshot: RunSnapshot,
        approval: ApprovalRequest): Result<AgentRunRequest> {
        if (snapshot.status != RunState.WaitingApproval || snapshot.runId.value != previous.runId.value ||
            snapshot.sessionId.value != previous.sessionId.value || approval.sessionId != previous.sessionId.value) {
            return pluginProcessError("application.approval_request_stale", "approval no longer belongs to this request") }
        let runtime = match (threadRuntimes.acquire(ThreadId(previous.sessionId.value), workspace.rootPath())) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let active = match (runtime.activeRun()) { case Some(value) => value
            case None => return pluginProcessError("application.approval_request_stale", "approval Run is no longer active") }
        if (active.runId.value != previous.runId.value || active.threadId.value != previous.sessionId.value ||
            active.state != RunState.WaitingApproval) {
            return pluginProcessError("application.approval_request_stale", "approval Run is not waiting") }
        let token = match (runtime.currentRunCancellationToken(previous.runId, active.epoch)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        match (token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let continuation = match (runs.continuation(previous.runId)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (continuation.kind != RunContinuationKind.WaitingApproval ||
            continuation.runId.value != previous.runId.value || continuation.sessionId.value != previous.sessionId.value ||
            continuation.approval.operationId.value != approval.operationId.value ||
            continuation.approval.sessionId != approval.sessionId || continuation.approval.callId != approval.callId ||
            continuation.approval.argumentHash != approval.argumentHash || continuation.approval.toolName != approval.toolName ||
            canonicalAgentValue(continuation.toolContextPayload) != canonicalAgentValue(productToolContextValue(previous.toolContext))) {
            return pluginProcessError("application.approval_request_stale", "approval differs from its canonical request") }
        try {
            let rows = vnextDatabase.query("SELECT c.payload,r.skill_snapshot FROM runs r " +
                "JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id " +
                "JOIN run_continuations c ON c.run_id=r.id JOIN operations o ON o.run_id=r.id " +
                "WHERE r.id=? AND r.thread_id=? AND r.epoch=? AND r.state='waiting_approval' " +
                "AND r.finished_at_millis IS NULL AND t.active_turn_id=turn.id AND turn.active_run_id=r.id " +
                "AND turn.state='active' AND o.id=? AND o.state='waiting_approval' AND c.phase='waiting_approval'",
                [SqlParameter.Text(previous.runId.value), SqlParameter.Text(previous.sessionId.value),
                    SqlParameter.Int64Value(active.epoch), SqlParameter.Text(approval.operationId.value)])
            if (rows.size != 1) { return pluginProcessError("application.approval_request_stale", "approval lost its durable owner") }
            let durable = decodeDurableRunContinuation(rows[0].required(0))
            let frozen = match (optionalRunRequestSnapshotFromDurableContinuation(durable)) { case Some(value) => value
                case None => return pluginProcessError("application.approval_request_stale", "approval request projection is missing") }
            if (durable.runId.value != previous.runId.value || durable.turnId.value != active.turnId.value ||
                durable.pendingOperationId.isNone() || durable.pendingOperationId.getOrThrow().value != approval.operationId.value ||
                durable.pendingApprovalId.isNone() || durable.pendingApprovalId.getOrThrow().value != "legacy-approval-" + approval.operationId.value ||
                canonicalAgentValue(frozen.field("skill_stack").getOrThrow()) != canonicalAgentValue(continuation.contextSnapshotPayload) ||
                canonicalAgentValue(decodeStoredValue(rows[0].required(1))) != canonicalAgentValue(continuation.contextSnapshotPayload) ||
                canonicalAgentValue(contextSnapshotValue(active.contextSnapshot)) != canonicalAgentValue(continuation.contextSnapshotPayload)) {
                return pluginProcessError("application.approval_request_stale", "approval context or epoch changed") }
        } catch (_: Exception) {
            return pluginProcessError("application.approval_request_stale", "approval durable binding is unavailable") }
        match (runtime.currentRunCancellationToken(previous.runId, active.epoch)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(current) => match (current.check()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        continuationRequest(continuation, previous.interactions, toolContext: Some(previous.toolContext))
    }

    public func persistPendingApproval(
        request: AgentRunRequest,
        approval: ApprovalRequest
    ): Result<Unit> {
        runs.saveContinuation(RunContinuation(
            request.runId,
            request.sessionId,
            request.model,
            request.prompt,
            approval,
            system: request.system,
            thinking: request.thinking,
            capabilities: request.capabilities,
            budget: request.budget,
            approvalMode: productApprovalModeName(request.approvalModeOverride),
            autoRetry: request.autoRetry,
            serviceTier: request.serviceTier,
            pricing: request.pricing,
            imageInputs: request.imageInputs,
            structuredOutput: request.structuredOutput,
            cachePolicy: request.cachePolicy,
            cacheKey: request.cacheKey,
            parallelToolCalls: request.parallelToolCalls,
            requestedPolicy: Some(request.requestedPolicy),
            modelCapabilitiesSnapshot: Some(request.modelCapabilitiesSnapshot),
            resolverVersion: request.resolverVersion,
            contextSnapshotPayload: contextSnapshotValue(request.contextSnapshot),
            contextWindow: request.contextWindow,
            providerSafetyMargin: request.providerSafetyMargin,
            toolContextPayload: productToolContextValue(request.toolContext),
            executionLaneId: request.executionLaneId
        ))
    }

    public func sessionReference(sessionId: SessionId): String {
        "thread://" + sessionId.value
    }

    public func replaceMessages(
        sessionId: SessionId,
        messages: Array<ModelMessage>
    ): Result<Unit> {
        try {
            SqliteThreadSeedStore(vnextDatabase).createCompleted(
                completedThreadSeedSnapshot(
                    ThreadId(sessionId.value),
                    workspace.rootPath(),
                    messages,
                    createdAtMillis: agentUtcMillis()
                )
            )
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "product.thread_seed_invalid",
                error.message,
                fields: [ErrorField("thread_id", sessionId.value)]
            ))
        }
    }

    public func removeConversation(sessionId: SessionId): Result<Bool> {
        let canonical = match (threadRuntimes.discardInactive(
            ThreadId(sessionId.value)
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        Result.Ok(canonical)
    }

    public func exportSessionHtml(
        sessionId: SessionId,
        outputPath: String
    ): Result<String> {
        let messages = match (messages(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var body = "<!doctype html><meta charset=\"utf-8\">" + "<title>axyndra session</title><main>"
        for (message in messages) {
            body += "<section><h2>" + if (message.role == ModelRole.User) {
                "User"
            } else {
                "Assistant"
            } + "</h2>"
            for (block in message.blocks) {
                body += "<pre>" + htmlEscape(block.text) + "</pre>"
            }
            body += "</section>"
        }
        body += "</main>"
        try {
            File.writeTo(outputPath, body.toArray())
            Result.Ok(outputPath)
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "session.export_failed",
                    error.message,
                    fields: [ErrorField("path", outputPath)]
                )
            )
        }
    }

    public func formatSessionDump(
        sessionId: SessionId,
        selectedModel: String,
        thinkingLevel: ThinkingLevel
    ): Result<String> {
        let messages = match (messages(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (messages.isEmpty()) {
            return Result.Ok("")
        }
        var text = "## Configuration\n\n" + "Model: " + providerIdForModel(selectedModel) + "/" + rawModelId(
            selectedModel) + "\n" + "Thinking Level: " + thinkingLevelName(thinkingLevel) + "\n\n"
        let definitions = tools()
        if (!definitions.isEmpty()) {
            text += "## Available Tools\n\n"
            for (definition in definitions) {
                text += "### " + definition.name + "\n\n" + definition.description + "\n\n" + "```json\n" +
                    encodeAgentValue(definition.inputSchema) + "\n```\n\n"
            }
        }
        for (message in messages) {
            text += formatDumpMessage(message)
        }
        Result.Ok(text.trimAscii())
    }

    public func formatSubagentTranscript(
        rootSessionId: SessionId,
        subagentId: String
    ): Result<String> {
        let transcript = match (taskRuntime.transcript(
            rootSessionId,
            subagentId: subagentId
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var text = ""
        for (message in transcript.messages) {
            text += formatDumpMessage(message)
        }
        Result.Ok(text.trimAscii())
    }

    public func dumpLlmRequest(
        sessionId: SessionId,
        selectedModel: String,
        thinkingLevel: ThinkingLevel,
        modeSystem!: String = "",
        guide!: String = "",
        readOnly!: Bool = false,
        workMode!: String = "none"
    ): Result<String> {
        let messages = match (modelContext(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let messageValues = ArrayList<AgentValue>()
        for (message in messages) {
            messageValues.add(dumpMessageValue(message))
        }
        let toolValues = ArrayList<AgentValue>()
        let capabilities = requestCapabilities(readOnly, sessionId: Some(sessionId))
        for (definition in catalog.definitionsFor(capabilities, threadId: Some(ThreadId(sessionId.value)))) {
            toolValues.add(
                objectValue(
                    [
                        ValueField("name", textValue(definition.name)),
                        ValueField(
                            "description",
                            textValue(definition.description)
                        ),
                        ValueField("inputSchema", definition.inputSchema)
                    ]
                )
            )
        }
        let system = requestSystem(sessionId, guide, modeSystem)
        let request = objectValue(
            [
                ValueField("kind", textValue("reconstructed_current_request")),
                ValueField(
                    "model",
                    objectValue(
                        [
                            ValueField(
                                "provider",
                                textValue(providerIdForModel(selectedModel))
                            ),
                            ValueField(
                                "id",
                                textValue(rawModelId(selectedModel))
                            )
                        ]
                    )
                ),
                ValueField(
                    "thinkingLevel",
                    textValue(thinkingLevelName(thinkingLevel))
                ),
                ValueField("workMode", textValue(workMode)),
                ValueField("system", textValue(system)),
                ValueField("messages", listValue(messageValues.toArray())),
                ValueField("tools", listValue(toolValues.toArray()))
            ]
        )
        let temporaryRoot = match (getVariable("TMPDIR")) {
            case Some(value) =>
                if (value.trimAscii() == "") {
                    "/tmp"
                } else {
                    value.trimAscii()
                }
            case None => "/tmp"
        }
        let path = temporaryRoot + "/axyndra-request-" + safeDumpFilePart(sessionId.value) + "-" + safeDumpFilePart(
            ids.nextOperationId().value) + ".json"
        try {
            File.writeTo(path, (encodeAgentValue(request) + "\n").toArray())
            Result.Ok(path)
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "session.dump_request_failed",
                    error.message,
                    fields: [ErrorField("path", path)]
                )
            )
        }
    }

    public func copyTextToClipboard(
        text: String,
        nativeEnabled!: Bool = true
    ): Result<ProductClipboardCopy> {
        if (text == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "clipboard.empty_text",
                    "clipboard text must not be empty"
                )
            )
        }
        let path = stateRoot + "/clipboard-" + safeDumpFilePart(ids.nextOperationId().value) + ".txt"
        try {
            File.writeTo(path, text.toArray())
        } catch (error: Exception) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Internal,
                    "clipboard.stage_failed",
                    error.message,
                    fields: [ErrorField("path", path)]
                )
            )
        }
        let encoded = productBase64Bytes(unsafe { text.rawData() })
        let native = if (!nativeEnabled) {
            false
        } else {
            // Same trusted UI boundary as the deterministic base64 branch;
            // argv and the staged path are entirely product-authored.
            // std.process captures child pipes; wl-copy forks a daemon, so
            // POSIX sh (including dash) only gets single-digit redirection
            // descriptors here; close that portable range before detaching.
            match (processes.execute(
                ProcessRequest(
                    "/bin/sh",
                    operationId: ids.nextOperationId(),
                    arguments: [
                        "-c",
                        "exec 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-; " +
                            "if command -v wl-copy >/dev/null 2>&1; then " + "setsid wl-copy < \"$1\" >/dev/null 2>&1; " +
                            "elif command -v xclip >/dev/null 2>&1; then " + "xclip -selection clipboard < \"$1\"; " +
                            "elif command -v xsel >/dev/null 2>&1; then " + "xsel --clipboard --input < \"$1\"; " +
                            "else exit 127; fi",
                        "axyndra-clipboard",
                        path
                    ],
                    timeoutMillis: 5000,
                    sandboxMode: ProcessSandboxMode.Host,
                    networkPolicy: Some(NetworkPolicy(NetworkPolicyMode.Denied)),
                    displayServerAccess: true
                )
            )) {
                case Result.Ok(result) => result.exitCode == 0
                case Result.Err(_) => false
            }
        }
        try {
            removeIfExists(path)
        } catch (_: Exception) {}
        Result.Ok(ProductClipboardCopy(encoded, native))
    }

    public func sessions(): Result<Array<SessionId>> {
        try {
            let values = ArrayList<SessionId>()
            for (row in vnextDatabase.query(
                "SELECT id FROM threads WHERE status='open' ORDER BY id"
            )) {
                values.add(SessionId(row.required(0)))
            }
            Result.Ok(values.toArray())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "product.thread_list_unavailable",
                error.message
            ))
        }
    }

    public func sessionInfo(sessionId: SessionId): Result<ProductSessionInfo> {
        var summary = match (sessionMetadata.summary(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => ""
        }
        if (summary == "") {
            // Existing sessions are migrated lazily. Once indexed, opening
            // the selector must not parse the full JSONL again: transcripts
            // can be megabytes long and this method runs once per session.
            let values = match (messages(sessionId)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            summary = sessionSummary(values)
            let _ = sessionMetadata.setSummary(sessionId, summary)
        }
        let indexedUpdatedAt = match (sessionMetadata.updatedAt(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => 0
        }
        var updatedAt = indexedUpdatedAt
        let itemRows = vnextDatabase.query(
            "SELECT COALESCE(MAX(created_at_millis),0) FROM items WHERE thread_id=" +
                sqliteText(sessionId.value)
        )
        if (!itemRows.isEmpty()) {
            updatedAt = max(updatedAt, Int64.parse(itemRows[0].required(0)))
        }
        // Persist only an actual migration/recovery change. The previous
        // unconditional atomic rewrite multiplied disk I/O by session count
        // every time /session or /tree opened.
        if (updatedAt > indexedUpdatedAt) {
            let _ = sessionMetadata.setUpdatedAt(sessionId, updatedAt)
        }
        Result.Ok(
            ProductSessionInfo(
                sessionId.value,
                sessionValueOr(sessionMetadata.name(sessionId)),
                summary,
                parentSessionId(sessionValueOr(sessionMetadata.parentSession(sessionId))),
                sessionValueOr(sessionMetadata.model(sessionId)),
                sessionValueOr(sessionMetadata.workMode(sessionId)),
                updatedAt
            )
        )
    }

    public func refreshSessionIndex(sessionId: SessionId): Result<Unit> {
        let existing = match (sessionMetadata.summary(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => ""
        }
        if (existing == "") {
            let messages = match (messages(sessionId)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            match (sessionMetadata.setSummary(sessionId, sessionSummary(messages))) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        sessionMetadata.setUpdatedAt(sessionId, DateTime.nowUTC().toUnixTimeStamp().toMilliseconds())
    }

    public func archiveSession(sessionId: SessionId): Result<Unit> {
        if (vnextDatabase.scalarInt(
            "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(sessionId.value)
        ) == 0) {
            return Result.Err(AgentError(AgentErrorKind.InvalidInput, "session.not_found", "session was not found"))
        }
        match (threadRuntimes.releaseInactive(ThreadId(sessionId.value))) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            vnextDatabase.execute(
                "UPDATE threads SET status='closed' WHERE id=" + sqliteText(sessionId.value)
            )
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "session.archive_commit_failed",
                error.message
            ))
        }
    }

    public func restoreSession(sessionId: SessionId): Result<Unit> {
        try {
            if (vnextDatabase.scalarInt(
                "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(sessionId.value) +
                    " AND status='closed'"
            ) == 0) {
                return Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    "session.archive_not_found",
                    "archived session was not found"
                ))
            }
            vnextDatabase.execute(
                "UPDATE threads SET status='open' WHERE id=" + sqliteText(sessionId.value)
            )
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "session.restore_commit_failed",
                error.message
            ))
        }
    }

    public func archivedSessions(): Array<String> {
        let values = ArrayList<String>()
        for (row in vnextDatabase.query(
            "SELECT id FROM threads WHERE status='closed' ORDER BY id"
        )) {
            values.add(row.required(0))
        }
        values.toArray()
    }

    public func archivedSessionInfo(sessionId: SessionId): Result<ProductSessionInfo> {
        if (vnextDatabase.scalarInt(
            "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(sessionId.value) +
                " AND status='closed'"
        ) == 0) {
            return Result.Err(
                AgentError(AgentErrorKind.InvalidInput, "session.archive_not_found", "archived session was not found"))
        }
        match (sessionInfo(sessionId)) {
            case Result.Ok(value) => Result.Ok(ProductSessionInfo(
                value.id, value.name, value.summary, value.parentId,
                value.model, value.workMode, value.updatedAt, archived: true
            ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func forkSession(
        source: SessionId,
        target: SessionId
    ): Result<Unit> {
        match (compactionSummarizer as OwnedCompletedThreadForkData173d) {
            case Some(installed) =>
                let scope = compactionSummarizer.openScope(source)
                try {
                    match (installed.forkCompletedThreadData173d(source, target, workspace.rootPath(), vnextDatabase, scope.token)) {
                        case Result.Err(error) => return Result<Unit>.Err(error)
                        case Result.Ok(_) => return sessionMetadata.copy(source, target)
                    }
                } finally { scope.close() }
            case None =>
                // Only the explicitly unsafe isolated oracle keeps the old
                // full-snapshot implementation. A normal missing/disabled
                // installed contribution must never silently take that path.
                if (!unsafeDirectLaunchForTests) {
                    return productPolicySelectionError<Unit>("compaction.structure_invalid") }
        }
        let snapshot = match (canonicalThreadSnapshot(source)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let checkpointStore = SqliteContextCheckpointStore(vnextDatabase)
        let sourceCheckpoint = checkpointStore.loadLatest(
            snapshot, "agent-product-v1", "agent-core"
        )
        let targetSnapshot = try {
            completedThreadCloneSnapshot(
                ThreadId(target.value), workspace.rootPath(), snapshot
            )
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "product.thread_fork_invalid",
                error.message,
                fields: [
                    ErrorField("source_thread_id", source.value),
                    ErrorField("target_thread_id", target.value)
                ]
            ))
        }
        match (SqliteThreadSeedStore(vnextDatabase).createCompleted(targetSnapshot)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (sourceCheckpoint) {
            case Some(value) =>
                let targetCheckpoint = ContextCheckpoint(
                    "checkpoint-" + target.value + "-" +
                        value.coversThroughItemOrdinal.toString() + "-" +
                        targetSnapshot.thread.revision.toString(),
                    targetSnapshot.thread.id,
                    value.coversThroughItemOrdinal,
                    value.structuredSummary,
                    contextSourceDigest(
                        targetSnapshot, value.coversThroughItemOrdinal
                    ),
                    value.projectorVersion,
                    value.laneCompatibility,
                    activeGoal: value.activeGoal,
                    durableNotes: value.durableNotes,
                    artifactReferences: value.artifactReferences
                )
                match (checkpointStore.save(
                    targetCheckpoint, targetSnapshot, agentUtcMillis()
                )) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
            case None => ()
        }
        sessionMetadata.copy(source, target)
    }

    public func branchSession(
        source: SessionId,
        target: SessionId,
        messages: Array<ModelMessage>
    ): Result<Unit> {
        match (replaceMessages(target, messages)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (sessionMetadata.copy(source, target)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        sessionMetadata.setParentSession(target, sessionReference(source))
    }

    public func compactSession(
        sessionId: SessionId,
        force!: Bool = true, operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>
    ): Result<Int64> {
        let scope = compactionSummarizer.openScope(sessionId)
        try { compactSessionWithScope(sessionId, force, scope.token, operatorOptions180) } finally { scope.close() }
    }
    private func compactSessionWithScope(sessionId: SessionId, force: Bool, cancellation: domain.CancellationToken, operatorOptions180: ?ProductOperatorOptions180): Result<Int64> {
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let messages = match (compactionContextMessages(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let storedSessionModel = match (sessionMetadata.model(sessionId)) {
            case Result.Ok(value) => value.trimAscii()
            case Result.Err(error) => return Result<Int64>.Err(error)
        }
        let sessionModel = if (storedSessionModel == "") {
            model
        } else {
            storedSessionModel
        }
        // Internal maintenance runs are first-class durable runs. Persist the
        // resolved default before accounting so provider/session attribution
        // never depends on an implicit in-memory fallback.
        if (storedSessionModel == "") {
            match (sessionMetadata.setModel(sessionId, sessionModel)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result<Int64>.Err(error)
            }
        }
        let settings = compactionSettings.resolvedForModel(sessionModel)
        let policy = ContextCompactionPolicy(
            triggerPercent: settings.triggerPercent,
            targetPercent: settings.targetPercent,
            emergencyMessageLimit: settings.emergencyMaxMessages,
            keepRecentTokens: settings.keepRecentTokens,
            keepRecentMessages: settings.keepRecentMessages,
            oversizedToolResultTokens: settings.oversizedToolResultTokens
        )
        let budget = ResourceBudget(
            maxInputTokens: settings.maxInputTokens,
            maxContextMessages: settings.requestMaxMessages
        )
        let tools = catalog.definitionsFor(productCapabilities(), threadId: Some(ThreadId(sessionId.value)))
        let estimated = estimateContextTokens(messages, tools: tools)
        let tokenTriggered = estimated >= compactionTriggerTokens(budget, policy)
        let messageTriggered = messages.size >= policy.emergencyMessageLimit
        if ((!force && !tokenTriggered && !messageTriggered) ||
            (force && messages.size <= policy.keepRecentMessages)) {
            return Result.Ok(0)
        }
        let checkpointRetainIndex = match (compactionSummarizer.checkpointRetainIndex173(sessionId, messages, cancellation)) {
            case Result.Err(error) => return Result<Int64>.Err(error); case Result.Ok(value) => value }

        let target = compactionTargetTokens(budget, policy)
        let fixed = estimateContextTokens([], tools: tools)
        // Hybrid overview is optional and must fit the same reserve; enabling
        // it must never move the deterministic history cut point.
        let summaryReserve = min(2048, max(128, target / 10))
        let recentBudget = min(
            policy.keepRecentTokens,
            max(0, target - fixed - summaryReserve)
        )
        var removed = if (tokenTriggered || estimated > target) {
            findRecentTokenCutPoint(messages, recentBudget)
        } else if (messageTriggered) {
            findSafeCutPoint(messages, max(0, messages.size - policy.emergencyMessageLimit / 2))
        } else {
            // Explicit /compact keeps the compatibility message-count behavior only
            // as a user-requested fallback; automatic compaction never uses
            // this path for short histories.
            findSafeCutPoint(messages, max(0, messages.size - policy.keepRecentMessages))
        }
        if (checkpointRetainIndex >= 0 && removed > checkpointRetainIndex) {
            removed = checkpointRetainIndex
        }
        if (removed <= 0) {
            if (checkpointRetainIndex == 0 && estimated > target) {
                return canonicalCheckpointRetentionFailure173<Int64>(compactionSummarizer.checkpointRetentionFailure173(sessionId, cancellation))
            }
            return Result.Ok(0)
        }

        var compacted = match (compactedMessages(messages, removed, sessionId, cancellation)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        try {
        while (removed < messages.size && estimateContextTokens(compacted.messages, tools: tools) > target) {
            let next = findSafeCutPoint(messages, removed + 1)
            if (next <= removed ||
                (checkpointRetainIndex >= 0 && next > checkpointRetainIndex)) {
                break
            }
            removed = next
            let nextValue = match (compactedMessages(messages, removed, sessionId, cancellation)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            compacted.close(); compacted = nextValue
        }
        if (checkpointRetainIndex >= 0 &&
            estimateContextTokens(compacted.messages, tools: tools) > target) {
            return canonicalCheckpointRetentionFailure173<Int64>(compactionSummarizer.checkpointRetentionFailure173(sessionId, cancellation))
        }
        if (!isToolProtocolComplete(compacted.messages)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Protocol,
                    "session.compaction_protocol_invalid",
                    "compaction could not produce a complete tool protocol window"
                )
            )
        }
        // The projection's consumers are finished. Do not retain a redundant
        // full summary while the separately checked canonical cut is built.
        compacted.close()
        match (saveCanonicalCheckpoint(
            sessionId,
            policy.keepRecentMessages,
            target,
            tools,
            settings,
            sessionModel,
            cancellation, operatorOptions180
        )) {
            case Result.Ok(_) => Result.Ok(removed)
            case Result.Err(error) => Result.Err(error)
        }
        } finally { compacted.close() }
    }
    public func latestCompactionSummary(sessionId: SessionId): String {
        let snapshot = match (canonicalThreadSnapshot(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return ""
        }
        let checkpoint = SqliteContextCheckpointStore(vnextDatabase).loadLatest(
            snapshot, "agent-product-v1", "agent-core"
        )
        match (checkpoint) {
            case Some(value) =>
                match (value.structuredSummary.field("deterministic_summary")) {
                    case Some(summary) =>
                        if (summary.unifiedKind == ValueKind.Text) { summary.text } else { "" }
                    case None => match (value.structuredSummary.field("summary")) {
                        case Some(summary) =>
                            if (summary.unifiedKind == ValueKind.Text) { summary.text } else { "" }
                        case None => ""
                    }
                }
            case None => ""
        }
    }
    public func compactSessionReport(
        sessionId: SessionId,
        force!: Bool = true, operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>
    ): Result<ProductCompactionReport> {
        let before = compactionTokenEstimate(sessionId)
        match (compactSession(sessionId, force: force, operatorOptions180: operatorOptions180)) {
            case Result.Ok(removed) =>
                let after = compactionTokenEstimate(sessionId)
                Result.Ok(ProductCompactionReport(
                    removed,
                    before,
                    after,
                    if (removed > 0) { latestCompactionSummary(sessionId) } else { "" }
                ))
            case Result.Err(error) => Result.Err(error)
        }
    }

    // Maintenance and its token report consume one checked checkpoint
    // projection, not modelContext's intentionally raw diagnostic history.
    private func compactionContextMessages(sessionId: SessionId): Result<Array<ModelMessage>> {
        let snapshot = match (canonicalThreadSnapshot(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) =>
                if (error.code == "product.thread_not_found") { return Result.Ok([]) }
                return Result.Err(error)
        }
        let checkpoint = SqliteContextCheckpointStore(vnextDatabase).loadLatest(
            snapshot, "agent-product-v1", "agent-core"
        )
        let messages = match (checkpoint) {
            case Some(value) =>
                let recent = ArrayList<ThreadItem>()
                for (item in snapshot.items where
                    item.ordinal > value.coversThroughItemOrdinal) {
                    recent.add(item)
                }
                modelMessagesFromProjection(ModelContextProjection(
                    snapshot.thread.revision, Some(value), recent.toArray(),
                    objectValue([]), 0, false
                ))
            case None => modelMessagesFromCanonicalItems(snapshot.items)
        }
        Result.Ok(messages)
    }

    private func compactionTokenEstimate(sessionId: SessionId): Int64 {
        let messages = match (compactionContextMessages(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => return 0
        }
        let tools = catalog.definitionsFor(productCapabilities(), threadId: Some(ThreadId(sessionId.value)))
        estimateContextTokens(messages, tools: tools)
    }
    private func saveCanonicalCheckpoint(
        sessionId: SessionId,
        keepRecentItems: Int64,
        targetTokens: Int64,
        tools: Array<ModelToolDefinition>,
        settings: ProductCompactionSettings,
        sessionModel: String,
        cancellation: domain.CancellationToken, operatorOptions180: ?ProductOperatorOptions180
    ): Result<Unit> {
        if (vnextDatabase.scalarInt(
            "SELECT COUNT(*) FROM threads WHERE id=" + sqliteText(sessionId.value)
        ) == 0) {
            // Imported or export-only transcripts have no canonical
            // Thread and are never promoted into vNext truth implicitly.
            return Result.Ok(())
        }
        let thread = try {
            SqliteThreadCommitSink(vnextDatabase).loadThread(
                ThreadId(sessionId.value)
            )
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "context.checkpoint_thread_load_failed",
                error.message
            ))
        }
        if (thread.thread.activeTurnId.isSome() ||
            thread.items.size <= max(1, keepRecentItems)) {
            return Result.Ok(())
        }
        let checkpointRetainOrdinal = match (compactionSummarizer.checkpointRetainOrdinal173(sessionId, thread.thread, vnextDatabase, cancellation)) {
            case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(value) => value }
        var cover = thread.items.size - max(1, keepRecentItems)
        if (checkpointRetainOrdinal >= 0 && cover > checkpointRetainOrdinal) {
            cover = checkpointRetainOrdinal
        }
        while (cover > 0 && validateContextCheckpointBoundary(
            thread, cover
        ).isError()) {
            cover -= 1
        }
        if (cover < 1) {
            if (checkpointRetainOrdinal == 0) {
                return canonicalCheckpointRetentionFailure173<Unit>(compactionSummarizer.checkpointRetentionFailure173(sessionId, cancellation))
            }
            return Result.Ok(())
        }
        let goal: ?ProductGoalState = match (goalState(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => None
        }
        let todos: Array<ProductTodoPhase> = match (todoPhases(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => []
        }
        let activeGoal = match (goal) {
            case Some(value) => value.objective
            case None => ""
        }
        var selected: ?ContextCheckpoint = None
        var inputLimitFallback: ?ContextCheckpoint = None
        var selectedPolicy: ?ProductCompactionStructure = None
        var fallbackPolicy: ?ProductCompactionStructure = None
        var combinedOwner: ?ProductPolicyValueLease = None
        var overviewOwner: ?ProductCompactionOverview = None
        try {
        while (cover < thread.items.size &&
            (checkpointRetainOrdinal < 0 || cover <= checkpointRetainOrdinal)) {
            if (validateContextCheckpointBoundary(thread, cover).isError()) {
                cover += 1
                continue
            }
            let prefix = ArrayList<ThreadItem>()
            let recent = ArrayList<ThreadItem>()
            for (item in thread.items) {
                if (item.ordinal <= cover) {
                    prefix.add(item)
                } else {
                    recent.add(item)
                }
            }
            let prefixMessages = modelMessagesFromProjection(ModelContextProjection(
                thread.thread.revision,
                Option<ContextCheckpoint>.None,
                prefix.toArray(),
                objectValue([]),
                0,
                false
            ))
            let structure = match (compactionSummarizer.structure(sessionId, prefixMessages,
                productCompactionGoalFacts(goal), encodeTodoPhases(todos), settings.summaryTimeoutMillis, Some(cancellation))) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            var keepStructure = false
            try {
            let deterministicSummary = structure.text
            let candidate = ContextCheckpoint(
                "checkpoint-" + sessionId.value + "-" + cover.toString() + "-" +
                    thread.thread.revision.toString(),
                thread.thread.id,
                cover,
                objectValue([
                    ValueField("deterministic_summary", textValue(deterministicSummary)),
                    ValueField("covered_items", integerValue(cover)),
                    ValueField("structured_policy", structure.provenance)
                ]),
                contextSourceDigest(thread, cover),
                "agent-product-v1",
                "agent-core",
                activeGoal: activeGoal
            )
            match (validateStoredContextCheckpoint(candidate)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let projected = modelMessagesFromProjection(ModelContextProjection(
                thread.thread.revision,
                Some(candidate),
                recent.toArray(),
                objectValue([]),
                0,
                false
            ))
            let projectedTokens = estimateContextTokens(projected, tools: tools)
            if (projectedTokens <= settings.maxInputTokens) {
                match (fallbackPolicy) { case Some(old) => old.close(); case None => () }
                inputLimitFallback = Some(candidate)
                fallbackPolicy = Some(structure); keepStructure = true
            }
            if (projectedTokens <= targetTokens) {
                selected = Some(candidate)
                selectedPolicy = Some(structure); keepStructure = true
                break
            }
            cover += 1
            } finally { if (!keepStructure) { structure.close() } }
        }
        let deterministicCheckpoint = match (selected) {
            case Some(value) => value
            case None => match (inputLimitFallback) {
                case Some(value) => value
                case None => return canonicalCheckpointRetentionFailure173<Unit>(compactionSummarizer.checkpointRetentionFailure173(sessionId, cancellation))
            }
        }
        let policyWitness = (if (selected.isSome()) { selectedPolicy } else { fallbackPolicy }).getOrThrow()
        let deterministicRecent = ArrayList<ThreadItem>()
        for (item in thread.items where item.ordinal >
            deterministicCheckpoint.coversThroughItemOrdinal) {
            deterministicRecent.add(item)
        }
        let deterministicTokens = estimateContextTokens(
            modelMessagesFromProjection(ModelContextProjection(
                thread.thread.revision,
                Some(deterministicCheckpoint),
                deterministicRecent.toArray(),
                objectValue([]),
                0,
                false
            )),
            tools: tools
        )
        let checkpointLimit = if (deterministicTokens <= targetTokens) {
            targetTokens
        } else {
            settings.maxInputTokens
        }
        var checkpoint = deterministicCheckpoint
        if (settings.summaryStrategy == "hybrid") {
            let deterministicSummary = deterministicCheckpoint.structuredSummary
                .field("deterministic_summary").getOrThrow().text
            let summaryModel = if (settings.summaryModel == "") {
                sessionModel
            } else {
                settings.summaryModel
            }
            match (compactionSummarizer.summarize(
                compactionAccountingRequest(
                    sessionId,
                    summaryModel,
                    settings.summaryTimeoutMillis,
                    settings.summaryMaxOutputTokens, operatorOptions180
                ),
                deterministicSummary,
                settings.summaryTimeoutMillis,
                settings.summaryMaxOutputTokens,
                Some(cancellation)
            )) {
                case Result.Ok(Some(overview)) =>
                    overviewOwner = Some(overview)
                    let combined = retainProductPolicyText([deterministicSummary, MODEL_COMPACTION_OVERVIEW_MARKER, overview.text])
                    var keepCombined = false
                    try {
                    let candidate = ContextCheckpoint(
                        deterministicCheckpoint.id,
                        deterministicCheckpoint.threadId,
                        deterministicCheckpoint.coversThroughItemOrdinal,
                        objectValue([
                            ValueField(
                                "deterministic_summary",
                                combined.value
                            ),
                            ValueField(
                                "covered_items",
                                integerValue(deterministicCheckpoint.coversThroughItemOrdinal)
                            ),
                            ValueField("overview_policy", overview.provenance),
                            ValueField("structured_policy", policyWitness.provenance)
                        ]),
                        deterministicCheckpoint.sourceDigest,
                        deterministicCheckpoint.projectorVersion,
                        deterministicCheckpoint.laneCompatibility,
                        activeGoal: deterministicCheckpoint.activeGoal
                    )
                    match (validateStoredContextCheckpoint(candidate)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    let recent = ArrayList<ThreadItem>()
                    for (item in thread.items where item.ordinal >
                        candidate.coversThroughItemOrdinal) {
                        recent.add(item)
                    }
                    let projected = modelMessagesFromProjection(ModelContextProjection(
                        thread.thread.revision,
                        Some(candidate),
                        recent.toArray(),
                        objectValue([]),
                        0,
                        false
                    ))
                    if (estimateContextTokens(projected, tools: tools) <= checkpointLimit) {
                        checkpoint = candidate; combinedOwner = Some(combined); keepCombined = true
                    }
                    } finally { if (!keepCombined) { combined.close(); overview.close(); overviewOwner = None } }
                case Result.Ok(None) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (policyWitness.validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        SqliteContextCheckpointStore(vnextDatabase).save(
            checkpoint, thread, agentUtcMillis()
        )
        } catch (_: Exception) { productPolicySelectionError("compaction.checkpoint_capacity") }
        finally {
            match (combinedOwner) { case Some(value) => value.close(); case None => () }
            match (overviewOwner) { case Some(value) => value.close(); case None => () }
            match (selectedPolicy) { case Some(value) => value.close(); case None => () }
            match (fallbackPolicy) { case Some(value) => value.close(); case None => () }
        }
    }

    private func compactionAccountingRequest(
        sessionId: SessionId,
        summaryModel: String,
        timeoutMillis: Int64,
        maxOutputTokens: Int64, operatorOptions180: ?ProductOperatorOptions180
    ): AgentRunRequest {
        let metadata = modelMetadata(summaryModel)
        let neutral = productRequestModelPolicy(settingsRoot, summaryModel, fixtureProbe.isSome())
        let capabilities = if (fixtureProbe.isSome()) { match (metadata) {
            case Some(value) => productModelCapabilities(value)
            case None => productModelCapabilities(ModelCatalogEntry(
                "unknown",
                promptCache: if (summaryModel == "fixture" && fixtureProbe.isSome()) {
                    Some(true)
                } else {
                    Option<Bool>.None
                }
            ))
        } } else { neutral.capabilities }
        AgentRunRequest(
            ids.nextRunId(),
            sessionId,
            summaryModel,
            "Generate the internal context compaction summary.",
            system: "",
            thinking: ThinkingLevel.Low,
            modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot(
                summaryModel,
                capabilities.thinking,
                capabilities.maxOutputTokens,
                endpointMaxOutputTokens: if (fixtureProbe.isSome()) { match (metadata) {
                    case Some(value) => match (profileById(value.providerProfile)) {
                        case Some(profile) => profile.endpointMaxOutputTokens
                        case None => Option<Int64>.None
                    }
                    case None => Option<Int64>.None
                } } else { neutral.endpointMaxOutput },
                configurationDigest: neutral.configurationDigest
            )),
            capabilities: CapabilitySet(),
            autoRetry: retryControl.isEnabled(),
            serviceTier: if (fastModeEnabled(sessionId)) {
                fastTierForModel(summaryModel)
            } else {
                ""
            },
            pricing: match (metadata) {
                case Some(value) => value.pricing()
                case None => Option<ModelPricing>.None
            },
            cachePolicy: if (capabilities.promptCache) {
                ModelCachePolicy.StablePrefix
            } else {
                ModelCachePolicy.Default
            },
            cacheKey: if (capabilities.promptCache) {
                "compaction-summary-v1:" + summaryModel
            } else {
                ""
            },
            parallelToolCalls: false,
            toolContext: requestToolContext180(operatorOptions180, None<ToolContextDescriptor>),
            budget: ResourceBudget(
                maxInputTokens: if (fixtureProbe.isSome()) { match (metadata) {
                    case Some(value) => match (value.contextWindow) {
                        case Some(limit) => limit
                        case None => compactionSettings.resolvedForModel(
                            summaryModel
                        ).maxInputTokens
                    }
                    case None => compactionSettings.resolvedForModel(
                        summaryModel
                    ).maxInputTokens
                } } else { min(capabilities.contextWindowTokens,
                    compactionSettings.resolvedForModel(summaryModel).maxInputTokens) },
                maxOutputTokens: max(1, maxOutputTokens),
                maxModelRequests: if (retryControl.isEnabled()) { 2 } else { 1 },
                maxWallMillis: max(1, timeoutMillis)
            )
        )
    }

    // Host embedders can use the installed pure policy for supplied history
    // facts. This creates no Run, model call, permission or checkpoint.
    // The caller must close the returned proposal after its final consumer.
    // Installed-policy DATA entry used by canonical tool fixtures and the
    // existing kernel executor. It grants no operation or cut authority.
    public func proposeCheckpointExecution(context: ToolInvocationContext, call: ToolCall,
        loadThread: () -> Result<AgentThreadSnapshot>, timestamp: () -> String): Result<ToolResult> {
        compactionSummarizer.checkpoint(context, call, loadThread, timestamp)
    }

    public func proposeContextSummary(sessionId: SessionId, messages: Array<ModelMessage>,
        cancellation!: ?domain.CancellationToken = None): Result<ProductCompactionStructure> {
        compactionSummarizer.structure(sessionId, messages, nullValue(), listValue([]), compactionSettings.summaryTimeoutMillis, cancellation)
    }

    private func compactedMessages(
        messages: Array<ModelMessage>, removed: Int64, sessionId: SessionId,
        cancellation: domain.CancellationToken
    ): Result<ProductCompactedMessages> {
        let goal: ?ProductGoalState = match (goalState(sessionId)) {
            case Result.Ok(value) => value; case Result.Err(_) => None }
        let todos: Array<ProductTodoPhase> = match (todoPhases(sessionId)) {
            case Result.Ok(value) => value; case Result.Err(_) => [] }
        let structure = match (compactionSummarizer.structure(sessionId, messages[0..removed],
            productCompactionGoalFacts(goal), encodeTodoPhases(todos), compactionSettings.summaryTimeoutMillis, Some(cancellation))) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        var retained = false
        try {
            match (structure.validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let compacted = ArrayList<ModelMessage>([ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: structure.text)])])
            for (message in messages[removed..messages.size]) { compacted.add(message) }
            let result = ProductCompactedMessages(compacted.toArray(), structure)
            retained = true; Result.Ok(result)
        } finally { if (!retained) { structure.close() } }
    }

    public func sessionName(sessionId: SessionId): Result<String> {
        sessionMetadata.name(sessionId)
    }

    public func sessionWorkspaceRoot(sessionId: SessionId): Result<String> {
        sessionMetadata.workspaceRoot(sessionId)
    }

    public func sessionCwd(sessionId: SessionId): Result<String> {
        sessionMetadata.workspaceCwd(sessionId)
    }

    public func setSessionWorkspace(
        sessionId: SessionId,
        cwd!: String = ""
    ): Result<Unit> {
        sessionMetadata.setWorkspaceBinding(
            sessionId,
            workspace.rootPath(),
            if (cwd.trimAscii() == "") { workspace.rootPath() } else { cwd }
        )
    }

    public func setSessionName(
        sessionId: SessionId,
        name: String
    ): Result<Unit> {
        sessionMetadata.setName(sessionId, name)
    }

    public func sessionModel(sessionId: SessionId): Result<String> {
        sessionMetadata.model(sessionId)
    }

    public func setSessionModel(
        sessionId: SessionId,
        model: String
    ): Result<Unit> {
        sessionMetadata.setModel(sessionId, model)
    }

    public func sessionParent(sessionId: SessionId): Result<String> {
        sessionMetadata.parentSession(sessionId)
    }

    public func setSessionParent(
        sessionId: SessionId,
        parentSession: String
    ): Result<Unit> {
        sessionMetadata.setParentSession(sessionId, parentSession)
    }

    public func sessionWorkMode(sessionId: SessionId): Result<String> {
        sessionMetadata.workMode(sessionId)
    }

    public func setSessionWorkMode(
        sessionId: SessionId,
        mode: String
    ): Result<Unit> {
        sessionMetadata.setWorkMode(sessionId, mode)
    }

    public func sessionDraft(sessionId: SessionId): Result<String> {
        sessionMetadata.draft(sessionId)
    }

    public func setSessionDraft(
        sessionId: SessionId,
        value: String
    ): Result<Unit> {
        sessionMetadata.setDraft(sessionId, value)
    }

    // This fixed internal adapter borrows the already composed artifact
    // store. It accepts the actual retained native-result owner, not a DTO,
    // Receipt string, database callback or plugin-provided text permission.
    func persistCompletedTodoExport(invocation: ProductTodoInvocation): Result<ProductArtifact> {
        let content=match(invocation.exportText()){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(invocation.selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let stored=presentationArtifacts.persistText(content)
        match(invocation.selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        stored
    }

    public func todoPhases(sessionId: SessionId): Result<Array<ProductTodoPhase>> {
        let selected=match(selectProductTodo(this,sessionId)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let snapshot=match(SqlitePluginDocumentRepository(vnextDatabase).read(ThreadId(sessionId.value),LaneId("main"),selected.namespace,"todo")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let decoded=match(snapshot.decode()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let result=decodeTodoPhases(if(decoded.unifiedKind==ValueKind.Null){listValue([])}else{decoded})
        match(selected.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        result
    }
    // Explicit migration data only. Current projections never fall back to
    // this preserved cold payload or write it alongside plugin_documents.
    func legacyTodoPayload(sessionId: SessionId): Result<String> {
        // Explicit cold migration data, never a fallback state or grant. Do
        // not silently decode/re-encode or write the preserved original row.
        try{
            let rows=vnextDatabase.query("SELECT todo_payload FROM thread_metadata WHERE thread_id=?",
                [SqlParameter.Text(sessionId.value)])
            if(rows.isEmpty()){return Result.Ok("[]")}
            if(rows.size!=1){return productTodoFrontendError("todo.migration_input_invalid")}
            let raw=rows[0].required(0)
            Result.Ok(if(raw==""){ "[]" }else{raw})
        }catch(_:Exception){productTodoFrontendError("todo.migration_input_unavailable")}
    }
    func todoDocumentDigest(sessionId: SessionId, selected: ProductTodoSelection): Result<String> {
        if(selected.session.value!=sessionId.value){return productTodoFrontendError("todo.session_changed")}
        match(selected.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let snapshot=match(SqlitePluginDocumentRepository(vnextDatabase).read(ThreadId(sessionId.value),LaneId("main"),selected.namespace,"todo")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(selected.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(modelPolicySha256Text(snapshot.encoded))
    }

    public func sessionRunStats(sessionId: SessionId): Result<SessionRunStats> {
        runs.stats(sessionId)
    }

    public func managedWorktrees(): Result<Array<ProductWorktreeEntry>> {
        ProductWorktreeRuntime(settingsRoot, processes).list()
    }

    public func clearManagedWorktrees(
        all: Bool,
        dryRun: Bool
    ): Result<ProductWorktreeClearResult> {
        ProductWorktreeRuntime(settingsRoot, processes).clear(
            all,
            dryRun
        )
    }

    public func garbageCollect(options: ProductGcOptions): Result<ProductGcResult> {
        ProductGcRuntime(vnextDatabase, threadRuntimes).run(options)
    }

    public func dashboardStats(): Result<ProductDashboardStats> {
        ProductStatsRuntime(
            runs,
            sessionMetadata,
            providerProfiles: providerProfiles,
            modelCatalog: modelCatalog
        ).snapshot()
    }

    public func listGrievances(
        limit: Int64,
        tool: String
    ): Result<ProductGrievanceList> {
        ProductGrievanceRuntime(settingsRoot).list(limit, tool)
    }

    public func cleanGrievances(
        id: ?Int64,
        tool: String,
        all: Bool
    ): Result<ProductGrievanceClean> {
        ProductGrievanceRuntime(settingsRoot).clean(id, tool, all)
    }

    public func listSshHosts(): Result<ProductSshHosts> {
        ProductSshRuntime(
            workspace.rootPath(),
            settingsRoot
        ).list()
    }

    public func addSshHost(
        scope: String,
        host: ProductSshHost
    ): Result<Unit> {
        ProductSshRuntime(
            workspace.rootPath(),
            settingsRoot
        ).add(scope, host)
    }

    public func removeSshHost(
        scope: String,
        name: String
    ): Result<Unit> {
        ProductSshRuntime(
            workspace.rootPath(),
            settingsRoot
        ).remove(scope, name)
    }

    public func setAutoRetry(enabled: Bool): Unit {
        retryControl.setEnabled(enabled)
    }

    public func autoRetryEnabled(): Bool {
        retryControl.isEnabled()
    }

    public func abortRetry(requestId: String): Unit {
        // AgentCore is the single retry authority. Cancelling the run also
        // interrupts an active provider request and prevents a later attempt.
        let _ = client.cancel(RunId(requestId))
    }

    public func archiveAndReset(label: String): Result<Unit> {
        let normalized = label.trimAscii()
        if (!validResetArchiveLabel(normalized)) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "persistence.archive_label_invalid",
                "archive label must contain only letters, digits, dot, dash, or underscore"
            ))
        }
        try {
            let rows = vnextDatabase.query("SELECT id FROM threads")
            for (row in rows) {
                match (threadRuntimes.releaseInactive(ThreadId(row.required(0)))) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
            }
            let archiveRoot = stateRoot + "/archives/" + normalized
            match (snapshotArchiveBlobs(vnextDatabase, stateRoot, archiveRoot + ".blobs")) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            vnextDatabase.backupTo(archiveRoot + ".state.db")
            vnextDatabase.transaction<Unit>({ transaction =>
                transaction.execute("DELETE FROM session_permission_grants")
                transaction.execute("DELETE FROM thread_metadata")
                // Metadata-backed plugin documents deliberately have no
                // Thread FK. Archive them first, then clear them atomically
                // with the rest of live state; reset must not revive old data.
                transaction.execute("DELETE FROM plugin_documents")
                transaction.execute("DELETE FROM audit_events")
                transaction.execute("DELETE FROM capability_grants")
                transaction.execute("DELETE FROM memories")
                transaction.execute("DELETE FROM memory_events")
                transaction.execute("DELETE FROM task_snapshots")
                transaction.execute("DELETE FROM artifacts")
                transaction.execute("DELETE FROM threads")
            })
            Result.Ok(())
        } catch (error: Exception) {
            Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "persistence.sqlite_reset_failed",
                error.message
            ))
        }
    }

    public func importSessionArchive(
        sourcePath: String,
        target: SessionId
    ): Result<SessionImportReport> {
        importConversationArchive(
            sourcePath,
            target,
            SqliteThreadSeedStore(vnextDatabase),
            workspace.rootPath()
        )
    }

    public func login(profileId!: String = ""): Result<String> {
        let selected = selectedProfileId(profileId)
        match (profileById(selected)) {
            case Some(profile) =>
                if (profile.authentication == "oauth") {
                    return oauthNotSupported(selected)
                }
            case None => ()
        }
        let environment = credentialEnvironmentFor(selected)
        if (environment == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "credential.provider_profile_unknown",
                    "provider profile is not configured",
                    fields: [ErrorField("provider", selected)]
                )
            )
        }
        let credential = match (getVariable(environment)) {
            case Some(value) =>
                if (value.trimAscii() == "") {
                    return missingLoginEnvironment(environment)
                }
                value
            case None => return missingLoginEnvironment(environment)
        }
        saveProviderCredential(settingsRoot, selected, credential)
    }

    public func logout(profileId!: String = ""): Result<Bool> {
        let selected = selectedProfileId(profileId)
        match (profileById(selected)) {
            case Some(profile) =>
                if (profile.authentication == "oauth") {
                    return oauthNotSupported(selected)
                }
            case None => ()
        }
        let path = match (providerCredentialPath(
            settingsRoot,
            selected
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        try {
            Result.Ok(removeIfExists(path))
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "credential.remove_failed",
                    error.message
                )
            )
        }
    }

    public func credentialEnv(profileId!: String = ""): String {
        credentialEnvironmentFor(selectedProfileId(profileId))
    }

    public func credential(profileId!: String = ""): Result<String> {
        let selected = selectedProfileId(profileId)
        let profile = match (profileById(selected)) {
            case Some(value) => value
            case None => return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "credential.provider_profile_unknown",
                    "provider profile is not configured",
                    fields: [ErrorField("provider", selected)]
                )
            )
        }
        if (profile.authentication == "oauth") {
            return oauthNotSupported(selected)
        }
        match (getVariable(profile.apiKeyEnv)) {
            case Some(value) =>
                if (value.trimAscii() != "") {
                    return Result.Ok(value.trimAscii())
                }
            case None => ()
        }
        let path = match (providerCredentialPath(
            settingsRoot,
            selected
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (!exists(Path(path))) {
            return missingLoginEnvironment(profile.apiKeyEnv)
        }
        try {
            let value = String.fromUtf8(File.readFrom(path)).trimAscii()
            if (value == "") {
                missingLoginEnvironment(profile.apiKeyEnv)
            } else {
                Result.Ok(value)
            }
        } catch (error: Exception) {
            Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "credential.read_failed",
                    error.message,
                    fields: [ErrorField("path", path)]
                )
            )
        }
    }

    public func configureProvider(
        profile: ProviderProfile,
        model: String,
        credential!: String = ""
    ): Result<Unit> {
        if (profile.dialect == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "config.provider_dialect_missing",
                "provider setup must persist an explicit wire dialect"
            ))
        }
        match (ensureProductLayout(settingsRoot)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (upsertProviderProfile(settingsRoot, profile)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (upsertModelCatalogEntry(
            settingsRoot,
            ModelCatalogEntry(
                model,
                providerProfile: profile.id,
                thinking: Some(configuredThinkingForDialect(profile.dialect))
            )
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let configuredModel = profile.id + "/" + model
        if (credential != "") {
            match (saveProviderCredential(
                settingsRoot,
                profile.id,
                credential
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        updateProductConfig(settingsRoot, [
            ProductConfigEdit("default_model", ProductConfigScalar.Text(configuredModel))
        ])
    }

    public func saveTheme(name: String): Result<Unit> {
        if (!persistSettings) {
            return Result.Ok(())
        }
        let saved = updateProductConfig(settingsRoot, [
            ProductConfigEdit("theme", ProductConfigScalar.Text(name))
        ])
        if (saved.isOk()) {
            theme = name
        }
        saved
    }

    private func selectedProfileId(requested: String): String {
        if (requested.trimAscii() != "") {
            return requested
        }
        providerId()
    }

    private func credentialEnvironmentFor(profileId: String): String {
        for (profile in providerProfiles where profile.id == profileId) {
            return profile.apiKeyEnv
        }
        ""
    }

    private func profileById(profileId: String): ?ProviderProfile {
        for (profile in providerProfiles where profile.id == profileId) {
            return Some(profile)
        }
        None
    }
}

func sessionValueOr(value: Result<String>): String {
    match (value) {
        case Result.Ok(text) => text.trimAscii()
        case Result.Err(_) => ""
    }
}

func parentSessionId(value: String): String {
    let normalized = value.trimAscii().replace("\\", "/")
    if (normalized == "") {
        return ""
    }
    let parts = normalized.split("/")
    if (parts.isEmpty()) {
        return ""
    }
    parts[parts.size - 1].removeSuffix(".jsonl")
}

func sessionSummary(messages: Array<ModelMessage>): String {
    for (message in messages) {
        match (message.role) {
            case ModelRole.Assistant => continue
            case ModelRole.User => ()
        }
        var value = redactApprovalText(messageText(message))
            .replace("\r", " ")
            .replace("\n", " ")
            .replace("\t", " ")
            .trimAscii()
        while (value.contains("  ")) {
            value = value.replace("  ", " ")
        }
        if (value == "" || value.startsWith("[Compacted session history]")) {
            continue
        }
        // Local slash commands are controls, not useful conversation titles.
        if (value.startsWith("/") && !value.contains(" ")) {
            continue
        }
        let runes = value.toRuneArray()
        if (runes.size > 160) {
            return String(runes[..159]) + "…"
        }
        return value
    }
    "Empty session"
}

public func encodeTodoPhases(phases: Array<ProductTodoPhase>): AgentValue {
    let encoded = ArrayList<AgentValue>()
    for (phase in phases) {
        let tasks = ArrayList<AgentValue>()
        for (task in phase.tasks) {
            let fields = ArrayList<ValueField>()
            fields.add(ValueField("content", textValue(task.content)))
            fields.add(
                ValueField(
                    "status",
                    textValue(todoStatusName(task.status))
                )
            )
            if (task.blocker != "") {
                fields.add(ValueField("blocker", textValue(task.blocker)))
            }
            tasks.add(objectValue(fields.toArray()))
        }
        encoded.add(
            objectValue(
                [
                    ValueField("name", textValue(phase.name)),
                    ValueField("tasks", listValue(tasks.toArray()))
                ]
            )
        )
    }
    listValue(encoded.toArray())
}

public func decodeTodoPhases(value: AgentValue): Result<Array<ProductTodoPhase>> {
    if (value.unifiedKind != ValueKind.List) {
        return invalidTodoData("todo phases must be a list")
    }
    let phases = ArrayList<ProductTodoPhase>()
    for (phaseValue in value.items) {
        if (phaseValue.unifiedKind != ValueKind.Object) {
            return invalidTodoData("todo phase must be an object")
        }
        let name = match (phaseValue.field("name")) {
            case Some(field) =>
                if (field.unifiedKind != ValueKind.Text || field.text.trimAscii() == "") {
                    return invalidTodoData("todo phase name must be a non-empty string")
                }
                field.text
            case None => return invalidTodoData("todo phase name is required")
        }
        let taskValues = match (phaseValue.field("tasks")) {
            case Some(field) =>
                if (field.unifiedKind != ValueKind.List) {
                    return invalidTodoData("todo phase tasks must be a list")
                }
                field.items
            case None => return invalidTodoData("todo phase tasks are required")
        }
        let tasks = ArrayList<ProductTodoItem>()
        for (taskValue in taskValues) {
            if (taskValue.unifiedKind != ValueKind.Object) {
                return invalidTodoData("todo task must be an object")
            }
            let content = match (taskValue.field("content")) {
                case Some(field) =>
                    if (field.unifiedKind != ValueKind.Text || field.text.trimAscii() == "") {
                        return invalidTodoData("todo task content must be a non-empty string")
                    }
                    field.text
                case None => return invalidTodoData("todo task content is required")
            }
            let status = match (taskValue.field("status")) {
                case Some(field) =>
                    if (field.unifiedKind != ValueKind.Text) {
                        return invalidTodoData("todo task status must be a string")
                    }
                    match (todoStatusValue(field.text)) {
                        case Some(status) => status
                        case None => return invalidTodoData("todo task status is invalid")
                    }
                case None => return invalidTodoData("todo task status is required")
            }
            let blocker = match (taskValue.field("blocker")) {
                case Some(field) =>
                    if (field.unifiedKind != ValueKind.Text) {
                        return invalidTodoData("todo task blocker must be a string")
                    }
                    field.text
                case None => ""
            }
            tasks.add(ProductTodoItem(content, status: status, blocker: blocker))
        }
        phases.add(ProductTodoPhase(name, tasks.toArray()))
    }
    Result.Ok(phases.toArray())
}

func todoStatusName(status: ProductTodoStatus): String {
    match (status) {
        case ProductTodoStatus.Pending => "pending"
        case ProductTodoStatus.InProgress => "in_progress"
        case ProductTodoStatus.Completed => "completed"
        case ProductTodoStatus.Abandoned => "abandoned"
        case ProductTodoStatus.Blocked => "blocked"
    }
}

func todoStatusValue(value: String): ?ProductTodoStatus {
    match (value) {
        case "pending" => Some(ProductTodoStatus.Pending)
        case "in_progress" => Some(ProductTodoStatus.InProgress)
        case "completed" => Some(ProductTodoStatus.Completed)
        case "abandoned" => Some(ProductTodoStatus.Abandoned)
        case "blocked" => Some(ProductTodoStatus.Blocked)
        case _ => None
    }
}

func invalidTodoData<T>(message: String): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "todo.invalid_phases",
            message
        )
    )
}

func productCapabilities(): CapabilitySet {
    CapabilitySet(
        values: [
            Capability(CapabilityKind.WorkspaceRead),
            Capability(CapabilityKind.WorkspaceWrite),
            Capability(CapabilityKind.ProcessSpawn),
            Capability(CapabilityKind.NetworkAccess),
            Capability(CapabilityKind.ExtensionInvoke),
            Capability(CapabilityKind.PeerMessage),
            Capability(CapabilityKind.Delegate)
        ]
    )
}


func activeCheckpointCompactionError<T>(): Result<T> {
    Result.Err(AgentError(
        AgentErrorKind.Conflict,
        "session.compaction_checkpoint_active",
        "active checkpoint history cannot fit the compaction target; call rewind before compacting again"
    ))
}

func compactionSummaryWithOverview(structuredSummary: String, overview: String): String {
    structuredSummary + MODEL_COMPACTION_OVERVIEW_MARKER + overview
}

public func openProduct(config!: ProductConfig = ProductConfig()): Result<ProductRuntime> {
    openProductAssembly180(config, None<ActualProcessBrokerRoot180>)
}
func openProductAssembly180(config: ProductConfig, ownerRoot180: ?ActualProcessBrokerRoot180): Result<ProductRuntime> {
    let localMaintenance = match (config.startupMode) {
        case ProductStartupMode.LocalMaintenance => true
        case ProductStartupMode.Owner => true
        case ProductStartupMode.Full => false
    }
    let ownerMode180 = match(config.startupMode) { case ProductStartupMode.Owner => true; case _ => false }
    if (!config.fixture) {
        match (ensureProductLayout(config.settingsRoot)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let isolateImplicitFixtureHome = if (config.fixture && config.settingsRoot == defaultProductHome()) {
        match (getVariable("AXYNDRA_HOME")) {
            case Some(value) => value.trimAscii() == ""
            case None => true
        }
    } else { false }
    let loadedSettings = if (isolateImplicitFixtureHome) {
        // A fixture must not accidentally inherit the developer's implicit
        // home. An explicit settings root or nonempty AXYNDRA_HOME is an
        // operator selection and uses the same supported config contract.
        ProductSettings()
    } else {
        match (loadProductSettings(config.settingsRoot)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let loadedApproval = loadedSettings.approval
    let approvalSettings = ProductApprovalSettings(
        mode: match (config.approvalRoutingModeOverride) {
            case Some(value) => value
            case None => loadedApproval.mode
        },
        failurePolicy: loadedApproval.failurePolicy,
        timeoutMillis: loadedApproval.timeoutMillis,
        logDecisions: loadedApproval.logDecisions,
        reviewerModel: loadedApproval.reviewerModel,
        reasoning: loadedApproval.reasoning,
        allowWorkspaceWrites: loadedApproval.allowWorkspaceWrites,
        askOnNetwork: loadedApproval.askOnNetwork,
        askOnOutsideWorkspaceWrite: loadedApproval.askOnOutsideWorkspaceWrite,
        askOnDestructiveCommands: loadedApproval.askOnDestructiveCommands
    )
    let settings = ProductSettings(
        model: chooseOverride(config.modelOverride, loadedSettings.model),
        asyncEnabled: config.asyncEnabled && loadedSettings.asyncEnabled,
        theme: loadedSettings.theme,
        shellNetworkMode: match (config.shellNetworkModeOverride) {
            case Some(value) => value
            case None => loadedSettings.shellNetworkMode
        },
        sandboxCaBundle: loadedSettings.sandboxCaBundle,
        approval: approvalSettings,
        compaction: match (config.compactionOverride) {
            case Some(value) => value
            case None => loadedSettings.compaction
        }
    )
    let loadedProfiles: Array<ProviderProfile> = if (config.fixture || (localMaintenance && !ownerMode180)) {
        []
    } else {
        match (loadProviderProfiles(config.settingsRoot)) {
            case Result.Ok(values) => values
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let loadedCatalog: Array<ModelCatalogEntry> = if (config.fixture || (localMaintenance && !ownerMode180)) {
        []
    } else {
        match (loadModelCatalog(config.settingsRoot)) {
            case Result.Ok(values) => values
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let model = if (config.fixture) {
        "fixture"
    } else {
        configuredModel(settings: settings)
    }
    if (!config.fixture && !localMaintenance) {
        match (validateProductConfiguration(
            model,
            loadedProfiles,
            loadedCatalog
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let configuredModels = if (config.fixture) {
        ["fixture"]
    } else {
        let values = ArrayList<String>()
        for (entry in loadedCatalog) {
            values.add(entry.displayId())
        }
        values.toArray()
    }
    let vnextDatabase = match (openVnextDatabase(config.stateRoot + "/state.db", monitor:config.fixtureTransactionCommitMonitor)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let sessionMetadata = SqliteSessionMetadataRepository(vnextDatabase)
    let runs = SqliteRunRepository(vnextDatabase)
    let operations = productOperationStore(vnextDatabase,
        derivedSettlementFailureObserver: config.fixtureDerivedSettlementFailureObserver)
    let audit = SqliteAuditRepository(vnextDatabase)
    let permissions = SqlitePermissionRepository(vnextDatabase)
    let threadRuntimes = SqliteThreadRuntimeRegistry(
        vnextDatabase,
        ContextProjector("agent-product-v1", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() },
        continuationVerifier: Some(SqliteContinuationRunVerifier(ContinuationAllowanceRepository(runs), requireDocumentPin: true,
            documentAllocation: Some({ bytes => reserveNativeDocumentPayload(bytes) })))
    )
    let ids = ProductIds()
    let workspace = LocalWorkspace(config.workspaceRoot)
    let sandboxCaBundle = match (resolveProductSandboxCaBundle(settings.sandboxCaBundle)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let processes = match (createProductProcessPort(workspace, sandboxCaBundle, config.settingsRoot)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let artifactStore = ProductArtifactStore(
        config.stateRoot,
        database: Some(vnextDatabase), operations: Some(operations)
    )
    let catalog = ToolCatalog()
    let uriRouter = InternalUriRouter()
    let taskRuntime = ProductTaskRuntime(
        asyncEnabled: settings.asyncEnabled,
        allowUnsafeDirectLaunchForTests: config.unsafeDirectLaunchForTests
    )
    let askRuntime = AskRuntime()
    let pluginRuntime = ProductPluginRuntime(config.settingsRoot, workspace.rootPath())
    var registryTransferred = false
    var builtProduct: ?ProductRuntime = None
    try {
    match (installProductToolGroups(
        catalog,
        workspace,
        processes,
        uriRouter: uriRouter,
        taskRuntime: Some(taskRuntime),
        checkpointDatabase: Option<SqliteDatabase>.None,
        askRuntime: askRuntime,
        artifactStore: Some(artifactStore),
        allowUnsafeDirectLaunchForTests: config.unsafeDirectLaunchForTests,
        shellNetworkMode: settings.shellNetworkMode,
        sandboxCaBundle: sandboxCaBundle
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerPluginAcquisitionTool(
        catalog,
        config.settingsRoot,
        workspace.rootPath(),
        sandboxCaBundle,
        settings.shellNetworkMode
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }

    let pipeline = ToolPipeline(
        catalog,
        operations,
        audit,
        ids,
        policy: DefaultCapabilityPolicy(
            mode: config.approvalMode,
            allowWorkspaceWrites: settings.approval.allowWorkspaceWrites,
            askOnNetwork: settings.approval.askOnNetwork
        ),
        permissions: permissions
    )
    match (catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "apply_file_plan",
                "Apply a previously generated immutable file plan through canonical approval. Revalidate every target immediately before its ordered write and report applied, conflict, not_started, failed_no_effect, or unknown items with a separate complete, no_effect, partial, or unknown effect summary; never describe the multi-file result as atomic.",
                objectSchema([
                    schemaProperty("plan_ref", "string"),
                    schemaProperty("plan_digest", "string")
                ], ["plan_ref", "plan_digest"])
            ),
            Capability(CapabilityKind.WorkspaceWrite),
            sideEffecting: true,
            implementationVersion: PRODUCT_FILE_APPLICATION_IMPLEMENTATION,
            implementationFingerprint: PRODUCT_FILE_APPLICATION_IMPLEMENTATION,
            capabilityResolver: Some({ call =>
                productFileApplicationPrimaryCapability(call, workspace)
            }),
            additionalCapabilityResolver: Some({ call =>
                productFileApplicationAdditionalCapabilities(call, workspace)
            }),
            approvalMetadataResolver: Some({ call =>
                productFilePlanApprovalMetadata(call.arguments, workspace.rootPath())
            }),
            networkPolicyResolver: Some({ _ =>
                Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
            }),
            canonicalArgumentsResolver: Some({ context, call =>
                canonicalizeProductFileApplicationPlan(
                    context, call, workspace, artifactStore, operationRuntime: Some(operations)
                )
            })
        ),
        ProductFilePlanApplicationExecutor(workspace, artifactStore, operationRuntime: Some(operations))
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (catalog.register(
        ToolDescriptor(
            ModelToolDefinition(
                "recover_file_plan",
                "Inspect an immutable file plan against actual workspace state after cancellation, failure, or unknown execution. Classify every item as applied, not_started, conflict, or unknown and, only when safe, create a fresh continuation plan that still requires a separate authorized apply_file_plan operation. Never roll back automatically.",
                objectSchema([
                    schemaProperty("plan_ref", "string"),
                    schemaProperty("plan_digest", "string")
                ], ["plan_ref", "plan_digest"])
            ),
            Capability(CapabilityKind.WorkspaceRead),
            implementationVersion: PRODUCT_FILE_RECOVERY_IMPLEMENTATION,
            implementationFingerprint: PRODUCT_FILE_RECOVERY_IMPLEMENTATION,
            capabilityResolver: Some({ call =>
                productFileRecoveryPrimaryCapability(call, workspace)
            }),
            additionalCapabilityResolver: Some({ call =>
                productFileRecoveryAdditionalCapabilities(call, workspace)
            }),
            networkPolicyResolver: Some({ _ =>
                Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied))
            }),
            canonicalArgumentsResolver: Some({ context, call =>
                canonicalizeProductFileRecoveryPlan(
                    context, call, workspace, artifactStore, operationRuntime: Some(operations)
                )
            })
        ),
        ProductFilePlanRecoveryExecutor(workspace, artifactStore, operationRuntime: Some(operations))
    )) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let retryControl = ModelRetrySettings()
    var fixtureProbe: ?FixtureModelPort = None
    let javascriptPlugins = ProductJavaScriptPluginHost(settingsRoot: config.settingsRoot, readViewStateRoot: config.stateRoot,
        documentBackends:{selected=>bindProductDocumentStorage(vnextDatabase,selected,workspace.rootPath(),config.settingsRoot,config.stateRoot)})
    match (javascriptPlugins.ownRegistry(pluginRuntime)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (javascriptPlugins.ownContextReadComponents({ => pluginRuntime.contextComponentSnapshot(
        ["skill", "mcp", "prompt", "extension", "hook", "command", "theme", "hosted"]) })) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    let configuredPort: ModelPort = if (config.fixture) {
        let probe = FixtureModelPort()
        fixtureProbe = Some(probe)
        probe
    } else {
        ProductInstalledModelPort(javascriptPlugins, config.settingsRoot, vnextDatabase, threadRuntimes,
            processes, loadedCatalog, loadedProfiles, artifactStore)
    }
    let modelControl = ControlledModelPort(configuredPort, runs: Some(runs))
    match (registerPluginHttpService(catalog, javascriptPlugins, operations, config.settingsRoot, sandboxCaBundle)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerPluginDocumentService(catalog)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (agent_host_runtime.hostRegisterPluginChildService111(catalog, javascriptPlugins, operations,
        ProductPluginChildBackend111(taskRuntime))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (registerPluginReadViewService(catalog, javascriptPlugins, operations, config.settingsRoot, processes)) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    match (registerProductContextRead(catalog, javascriptPlugins, operations,
        documentObserver: Some(ProductDocumentReadObserver(runs)), payloadArtifacts: Some(artifactStore))) {
        case Result.Err(error) => return Result.Err(error)
        case Result.Ok(_) => ()
    }
    match (registerProductContextResourceTool(catalog, javascriptPlugins, operations)) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
    }

    // Actual typed live-family executor preserves the original Catalog object.
    // Parent effect/resume loop activation is a separate dependent migration.
    match (agent_host_runtime.hostRegisterPluginLiveEffect(javascriptPlugins, operations, catalog,
        agent_host_runtime.HostLiveMemoryJournalNativeAbortEffectExecutor328(javascriptPlugins, operations))) {
        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
    }

    match (registerPluginReadOnlyProcessService(catalog, javascriptPlugins, operations, processes)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    match (registerPluginFilePlanService(catalog, javascriptPlugins, operations, workspace, artifactStore)) {
        case Result.Ok(_) => ()
        case Result.Err(error) => return Result.Err(error)
    }
    let codexHookRuntime = ProductCodexHookRuntime(processes, javascriptPlugins)
    let core = AgentCore(
        modelControl,
        runs,
        pipeline,
        catalog,
        threadRuntimes: Some(threadRuntimes),
        operationRuntime: Some(operations),
        modelDecisionRuntime: Some(SqliteModelDecisionStore(vnextDatabase)),
        contextManifestRuntime: Some(ProductContextManifestRuntime(vnextDatabase)),
        toolHooks: codexHookRuntime,
        initialContext: Some(ProductInitialContextPreparation(config.settingsRoot, javascriptPlugins, ids, pluginRuntime, operations)),
        modelAttemptRecovery: config.modelAttemptRecovery
    )
    let service = CoreRunService(core, runs)
    let compactionSummarizer = InstalledCompactionSummarizer(modelControl, javascriptPlugins, config.settingsRoot)
    if (config.fixture && config.unsafeDirectLaunchForTests) {
    match (installCheckpointTools(catalog, Some(vnextDatabase), summary: Some({ sessionId, messages, cancellation =>
        compactionSummarizer.structure(sessionId, messages, nullValue(), listValue([]), settings.compaction.summaryTimeoutMillis, Some(cancellation))
    }), policy: Some({ context: ToolInvocationContext, call: ToolCall,
        loadThread: () -> Result<AgentThreadSnapshot>, timestamp: () -> String =>
        compactionSummarizer.checkpoint(context, call, loadThread, timestamp)
    }), savePolicy: Some({ context: ToolInvocationContext, result: ToolResult,
        loadThread: () -> Result<AgentThreadSnapshot>,
        summary: (SessionId, Array<ModelMessage>, domain.CancellationToken) -> Result<ProductCompactionStructure>,
        consume: (AgentThreadSnapshot, Int64, String, AgentValue, () -> Result<Unit>) -> Result<Unit> =>
        compactionSummarizer.checkpointSave113(context, result, loadThread, summary, consume)
    }), ownedSavePolicy113: Some({ context: ToolInvocationContext, result: ToolResult,
        cursor: SqlitePaidCanonicalThreadCursor113, allocate: (Int64) -> LogicalJsonOwnerReservation,
        consume: ProductOwnedCheckpointProjectionConsumer113 =>
        compactionSummarizer.checkpointSaveOwned113(context, result, cursor, allocate,
            settings.compaction.summaryTimeoutMillis, consume)
    }))) {
        case Result.Ok(_) => (); case Result.Err(error) => return Result.Err(error)
    }
    }
    let approvalReviewer = ApprovalReviewer(
        modelControl,
        approvalSettings,
        model,
        workspace.rootPath()
    )
    let product = ProductRuntime(
        InProcessAgentClient(service),
        core,
        ids,
        workspace,
        model,
        config.settingsRoot,
        config.stateRoot,
        settings.asyncEnabled,
        config.wallTimeoutMillis,
        settings.shellNetworkMode,
        sandboxCaBundle,
        approvalSettings,
        settings.compaction,
        settings.theme,
        !config.fixture,
        sessionMetadata,
        runs,
        catalog,
        pipeline,
        configuredModels,
        loadedProfiles,
        loadedCatalog,
        processes,
        codexHookRuntime,
        retryControl,
        uriRouter,
        artifactStore,
        taskRuntime,
        askRuntime,
        pluginRuntime,
        compactionSummarizer,
        approvalReviewer,
        vnextDatabase,
        threadRuntimes,
        ProductVnextControl(
            vnextDatabase, catalog, pipeline, ids, threadRuntimes,
            operations,
            askRuntime,
            workspace.rootPath(), config.settingsRoot, processes, javascriptPlugins,
            extensionSignatureVerifier: config.extensionSignatureVerifier, payloadArtifacts: Some(artifactStore),
            canonicalSummaryTimeout173: settings.compaction.summaryTimeoutMillis
        ),
        fixtureProbe: fixtureProbe,
        unsafeDirectLaunchForTests: config.unsafeDirectLaunchForTests,
            installedModelInputOwner159: match (configuredPort) {
                case actual: HostInstalledModelPort => Some(actual)
                case _ => None<HostInstalledModelPort>
            }
    )
    builtProduct = Some(product)
    // The actual Root reaches the complete Product and finishes its existing
    // supervisor storage initialization before any startup plugin activation.
    match (ownerRoot180) { case Some(owner) => product.vnext.bindCanonicalOwner180(owner, product, config); case None => () }
    product.freezeConfiguredModelSettings180(config.modelStreamFaultProfile, config.modelAttemptRecovery)
    match (product.activateStartupPlugins()) {
        case Result.Ok(_) => ()
        case Result.Err(error) =>
            let _ = product.close()
            return Result.Err(error)
    }
    if ((!localMaintenance || ownerMode180) && config.distributionRoot != "") {
        match (applyProductDistributionDefaults(product, config.distributionRoot)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => let _ = product.close(); return Result.Err(error)
        }
    }
    taskRuntime.attach(product, ProductTaskPersistence(vnextDatabase), ownerRoot180: ownerRoot180)
    registryTransferred = true
    Result.Ok(product)
    } finally {
        if (!registryTransferred) {
            // The actual Product attempts physical cleanup first. Registry's
            // root state closes even when worker ACK remains pending; those
            // real pins/fences still retain their own custody tokens.
            match (builtProduct) { case Some(value) => let _ = value.close(); case None => () }
            pluginRuntime.close()
        }
    }
}

func validResetArchiveLabel(value: String): Bool {
    if (value == "" || value.size > 96) { return false }
    for (byte in value.toArray()) {
        let letter = (byte >= UInt8(65) && byte <= UInt8(90)) ||
            (byte >= UInt8(97) && byte <= UInt8(122))
        let digit = byte >= UInt8(48) && byte <= UInt8(57)
        if (!letter && !digit && byte != UInt8(45) && byte != UInt8(46) &&
            byte != UInt8(95)) {
            return false
        }
    }
    true
}

func snapshotArchiveBlobs(
    database: SqliteDatabase,
    stateRoot: String,
    archiveRoot: String
): Result<Unit> {
    try {
        let rows = database.query(
            "SELECT hash,relative_path FROM artifacts ORDER BY hash"
        )
        if (rows.isEmpty()) { return Result.Ok(()) }
        if (exists(Path(archiveRoot))) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "persistence.archive_blobs_exist",
                "artifact archive already exists",
                fields: [ErrorField("path", archiveRoot)]
            ))
        }
        Directory.create(archiveRoot, recursive: true)
        for (row in rows) {
            let hash = row.required(0).toAsciiLower()
            let relative = row.required(1)
            if (artifactHash("blob:sha256:" + hash).isError() ||
                relative != "blobs/" + hash + ".txt") {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "persistence.archive_artifact_metadata_invalid",
                    "artifact metadata cannot be archived safely",
                    fields: [ErrorField("hash", hash), ErrorField("path", relative)]
                ))
            }
            let source = stateRoot + "/" + relative
            let bytes = File.readFrom(source)
            if (artifactSha256(bytes) != hash) {
                return Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "persistence.archive_artifact_corrupt",
                    "artifact content does not match its durable hash",
                    fields: [ErrorField("hash", hash), ErrorField("path", source)]
                ))
            }
            File.writeTo(archiveRoot + "/" + hash + ".txt", bytes)
        }
        Result.Ok(())
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "persistence.archive_artifact_snapshot_failed",
            error.message,
            fields: [ErrorField("path", archiveRoot)]
        ))
    }
}

func openVnextDatabase(path: String, monitor!: ?(SqliteTransaction)->Unit = None): Result<SqliteDatabase> {
    try {
        Result.Ok(SqliteDatabase(path,transactionCommitMonitor:monitor))
    } catch (error: Exception) {
        Result.Err(AgentError(
            AgentErrorKind.RecoveryRequired,
            "product.state_database_open_failed",
            error.message,
            fields: [ErrorField("path", path)]
        ))
    }
}

func htmlEscape(value: String): String {
    value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}

func validateProductConfiguration(
    model: String,
    profiles: Array<ProviderProfile>,
    catalog: Array<ModelCatalogEntry>
): Result<Unit> {
    if (model == "unconfigured" && profiles.size == 0 && catalog.size == 0) {
        return Result.Ok(())
    }
    if (model == "unconfigured") {
        return Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "config.default_model_missing",
                "config.yml must define default_model"
            )
        )
    }
    if (profiles.size == 0) {
        return Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "config.providers_missing",
                "providers.yml must define at least one provider profile"
            )
        )
    }
    if (catalog.size == 0) {
        return Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "config.models_missing",
                "models.yml must define at least one model"
            )
        )
    }
    var defaultFound = false
    for (entry in catalog) {
        if (entry.providerProfile == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "config.model_provider_missing",
                    "every model must reference a provider profile",
                    fields: [ErrorField("model", entry.id)]
                )
            )
        }
        let configuredProfile = findProviderProfile(
            profiles,
            entry.providerProfile
        )
        if (configuredProfile.isNone()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "config.model_provider_unknown",
                    "model references an unknown provider profile",
                    fields: [
                        ErrorField("model", entry.id),
                        ErrorField("provider", entry.providerProfile)
                    ]
                )
            )
        }
        let profile = configuredProfile.getOrThrow()
        if (profile.dialect == "") {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "config.provider_dialect_missing",
                "every provider profile must declare its wire dialect",
                fields: [ErrorField("provider", profile.id)]
            ))
        }
        if (entry.thinking.isNone()) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "config.model_thinking_capability_missing",
                "every model must declare thinking capability explicitly",
                fields: [ErrorField("model", entry.id)]
            ))
        }
        if (entry.displayId() == model) {
            defaultFound = true
        }
    }
    if (!defaultFound) {
        return Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "config.default_model_unknown",
                "default_model is not present in models.yml",
                fields: [ErrorField("model", model)]
            )
        )
    }
    Result.Ok(())
}

func chooseOverride(value: String, fallback: String): String {
    if (value.trimAscii() == "") {
        fallback
    } else {
        value
    }
}

func productModelCapabilities(
    entry: ModelCatalogEntry,
    protocol!: String = "",
    provider!: String = "",
    baseUrl!: String = "",
    dialect!: String = ""
): ModelCapabilities {
    let _ = protocol
    let _ = provider
    let _ = baseUrl
    let _ = dialect
    let contextWindow = match (entry.contextWindow) {
        case Some(value) => value
        case None => 128000
    }
    let maxOutput = match (entry.maxOutputTokens) {
        case Some(value) => value
        case None => min(contextWindow, 16384)
    }
    var vision = false
    match (entry.inputModalities) {
        case Some(values) =>
            for (value in values where value.toAsciiLower() == "image") {
                vision = true
            }
        case None => ()
    }
    ModelCapabilities(
        toolCalling: true,
        // Fixture/UI metadata only. Production policy comes from the explicit
        // versioned neutral operator mapping, never a provider or dialect name.
        parallelToolCalling: true,
        reasoning: match (productThinkingCapabilities(entry).mode) {
            case ThinkingControlMode.NoThinking => false
            case _ => true
        },
        vision: vision,
        structuredOutput: match (entry.structuredOutput) {
            case Some(value) => value
            case None => false
        },
        promptCache: match (entry.promptCache) {
            case Some(value) => value
            // Cache support is a model capability. Absence is conservative;
            // provider names and endpoint URLs are never capability probes.
            case None => false
        },
        contextWindowTokens: contextWindow,
        maxOutputTokens: maxOutput,
        thinking: Some(productThinkingCapabilities(entry))
    )
}

func productThinkingCapabilities(entry: ModelCatalogEntry): ThinkingCapabilities {
    match (entry.thinking) {
        case Some(value) => return value
        case None => ()
    }
    ThinkingCapabilities(ThinkingControlMode.NoThinking)
}

func productToolResultError(result: ToolResult): AgentError {
    let code = productToolResultText(
        result,
        "error",
        "tool.execution_failed"
    )
    let kind = match (productToolResultText(result, "error_kind", "provider")) {
        case "configuration" => AgentErrorKind.Configuration
        case "authentication" => AgentErrorKind.Authentication
        case "permission_denied" => AgentErrorKind.PermissionDenied
        case "invalid_input" => AgentErrorKind.InvalidInput
        case "rate_limited" => AgentErrorKind.RateLimited
        case "timeout" => AgentErrorKind.Timeout
        case "transport" => AgentErrorKind.Transport
        case "protocol" => AgentErrorKind.Protocol
        case "cancelled" => AgentErrorKind.Cancelled
        case "budget_exceeded" => AgentErrorKind.BudgetExceeded
        case "conflict" => AgentErrorKind.Conflict
        case "recovery_required" => AgentErrorKind.RecoveryRequired
        case "internal" => AgentErrorKind.Internal
        case _ => AgentErrorKind.Provider
    }
    AgentError(
        kind,
        code,
        productToolResultText(result, "message", code),
        retryable: match (result.output.field("retryable")) {
            case Some(value) => value.unifiedKind == ValueKind.Boolean && value.asBool()
            case None => false
        }
    )
}

func productToolResultText(
    result: ToolResult,
    name: String,
    fallback: String
): String {
    match (result.output.field(name)) {
        case Some(value) =>
            if (value.unifiedKind == ValueKind.Text && value.text != "") {
                return value.text
            }
        case None => ()
    }
    // The JavaScript protocol preserves a structured error object in the
    // canonical Receipt. Project its diagnostic without changing that fact.
    if (name == "error" || name == "message") {
        match (result.output.field("error")) {
            case Some(error) =>
                let member = if (name == "error") { "code" } else { "message" }
                match (error.field(member)) {
                    case Some(value) =>
                        if (value.unifiedKind == ValueKind.Text && value.text != "") {
                            return value.text
                        }
                    case None => ()
                }
            case None => ()
        }
    }
    fallback
}

func oauthNotSupported<T>(providerId: String): Result<T> {
    Result.Err(
        AgentError(
            AgentErrorKind.Configuration,
            "oauth_not_supported",
            "OAuth authentication is not implemented in Phase 1",
            fields: [ErrorField("provider", providerId)]
        )
    )
}

func findProviderProfile(
    profiles: Array<ProviderProfile>,
    id: String
): ?ProviderProfile {
    for (profile in profiles where profile.id == id) {
        return Some(profile)
    }
    None
}

func productToolContextValue(value: ToolContextDescriptor): AgentValue {
    let environment = ArrayList<AgentValue>()
    for (entry in value.environment.entries()) {
        environment.add(objectValue([
            ValueField("name", textValue(entry.name)),
            ValueField("value", textValue(entry.value))
        ]))
    }
    let services = ArrayList<AgentValue>()
    for (service in value.services.descriptors()) {
        services.add(objectValue([
            ValueField("kind", textValue(match (service.kind) {
                case ToolServiceKind.Workspace => "workspace"
                case ToolServiceKind.Process => "process"
                case ToolServiceKind.Conversation => "conversation"
                case ToolServiceKind.Artifact => "artifact"
                case ToolServiceKind.Memory => "memory"
                case ToolServiceKind.Task => "task"
                case ToolServiceKind.Extension => "extension"
                case ToolServiceKind.Custom => "custom"
            })),
            ValueField("name", textValue(service.name)),
            ValueField("version", textValue(service.version))
        ]))
    }
    let fields = ArrayList<ValueField>([
        ValueField("workspace_root", textValue(value.workspaceRoot)),
        ValueField("cwd", textValue(value.cwd)),
        ValueField("environment", listValue(environment.toArray())),
        ValueField("services", listValue(services.toArray()))])
    if (value.executionSettings180.unifiedKind != ValueKind.Null) { fields.add(ValueField("execution_settings", value.executionSettings180)) }
    objectValue(fields.toArray())
}

func credentialPath(root: String, providerId: String): String {
    root + "/credentials/" + safeCredentialName(if (providerId == "") {
        "configured"
    } else {
        providerId
    }) + ".key"
}

func safeCredentialName(value: String): String {
    let output = ArrayList<Byte>()
    for (byte in unsafe { value.rawData() }) {
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') || (byte >= b'0' && byte <= b'9') ||
            byte == b'-' || byte == b'_') {
            output.add(byte)
        } else {
            output.add(b'_')
        }
    }
    if (output.isEmpty()) {
        "configured"
    } else {
        String.fromUtf8(output.toArray())
    }
}

func missingLoginEnvironment(name: String): Result<String> {
    Result.Err(
        AgentError(
            AgentErrorKind.Configuration,
            "credential.environment_missing",
            "set " + name + " before running /login",
            fields: [ErrorField("environment", name)]
        )
    )
}

func formatDumpMessage(message: ModelMessage): String {
    var text = ""
    var headingWritten = false
    for (block in message.blocks) {
        match (block.kind) {
            case ModelBlockKind.ToolResult =>
                text += "### Tool Result: " + if (block.name == "") {
                    "unknown"
                } else {
                    block.name
                } + "\n\n"
                if (block.callId != "") {
                    text += "Call ID: " + block.callId + "\n\n"
                }
                if (block.isError) {
                    text += "(error)\n\n"
                }
                text += "```\n" + block.text + "\n```\n\n"
            case ModelBlockKind.ToolCall =>
                if (!headingWritten) {
                    text += dumpRoleHeading(message.role)
                    headingWritten = true
                }
                text += "### Tool Call: " + if (block.name == "") {
                    "unknown"
                } else {
                    block.name
                } + "\n\n"
                if (block.callId != "") {
                    text += "Call ID: " + block.callId + "\n\n"
                }
                text += "```json\n" + encodeAgentValue(block.arguments) + "\n```\n\n"
            case ModelBlockKind.Reasoning =>
                if (!headingWritten) {
                    text += dumpRoleHeading(message.role)
                    headingWritten = true
                }
                if (block.text.trimAscii() != "") {
                    text += "<thinking>\n" + block.text + "\n</thinking>\n\n"
                }
            case ModelBlockKind.Refusal =>
                if (!headingWritten) {
                    text += dumpRoleHeading(message.role)
                    headingWritten = true
                }
                text += "<refusal>\n" + block.text + "\n</refusal>\n\n"
            case ModelBlockKind.Error =>
                if (!headingWritten) {
                    text += dumpRoleHeading(message.role)
                    headingWritten = true
                }
                text += "<error>\n" + block.text + "\n</error>\n\n"
            case ModelBlockKind.Text | ModelBlockKind.Unknown =>
                if (!headingWritten) {
                    text += dumpRoleHeading(message.role)
                    headingWritten = true
                }
                if (block.text != "") {
                    text += block.text + "\n\n"
                }
            case ModelBlockKind.Image =>
                if (!headingWritten) {
                    text += dumpRoleHeading(message.role)
                    headingWritten = true
                }
                text += "<image input>\n\n"
        }
    }
    if (!headingWritten && text == "") {
        text = dumpRoleHeading(message.role)
    }
    text
}

func dumpRoleHeading(role: ModelRole): String {
    match (role) {
        case ModelRole.User => "## User\n\n"
        case ModelRole.Assistant => "## Assistant\n\n"
    }
}

func dumpMessageValue(message: ModelMessage): AgentValue {
    let blocks = ArrayList<AgentValue>()
    for (block in message.blocks) {
        blocks.add(
            objectValue(
                [
                    ValueField("type", textValue(dumpBlockKindName(block.kind))),
                    ValueField("text", textValue(block.text)),
                    ValueField("callId", textValue(block.callId)),
                    ValueField("name", textValue(block.name)),
                    ValueField("arguments", block.arguments),
                    ValueField("isError", boolValue(block.isError))
                ]
            )
        )
    }
    objectValue(
        [
            ValueField(
                "role",
                textValue(match (message.role) {
                    case ModelRole.User => "user"
                    case ModelRole.Assistant => "assistant"
                })
            ),
            ValueField("content", listValue(blocks.toArray()))
        ]
    )
}

func dumpBlockKindName(kind: ModelBlockKind): String {
    match (kind) {
        case ModelBlockKind.Text => "text"
        case ModelBlockKind.Image => "image"
        case ModelBlockKind.Reasoning => "thinking"
        case ModelBlockKind.ToolCall => "toolCall"
        case ModelBlockKind.ToolResult => "toolResult"
        case ModelBlockKind.Refusal => "refusal"
        case ModelBlockKind.Error => "error"
        case ModelBlockKind.Unknown => "unknown"
    }
}

func thinkingLevelName(level: ThinkingLevel): String {
    match (level) {
        case ThinkingLevel.Off => "off"
        case ThinkingLevel.Minimal => "minimal"
        case ThinkingLevel.Low => "low"
        case ThinkingLevel.Medium => "medium"
        case ThinkingLevel.High => "high"
        case ThinkingLevel.XHigh => "xhigh"
        case ThinkingLevel.Max => "max"
    }
}

func productApprovalModeName(value: ?ApprovalMode): String {
    match (value) {
        case None => ""
        case Some(ApprovalMode.AlwaysAsk) => "always_ask"
        case Some(ApprovalMode.Write) => "write"
        case Some(ApprovalMode.Yolo) => "yolo"
    }
}

func productApprovalModeFromName(value: String): ?ApprovalMode {
    match (value) {
        case "always_ask" => Some(ApprovalMode.AlwaysAsk)
        case "write" => Some(ApprovalMode.Write)
        case "yolo" => Some(ApprovalMode.Yolo)
        case _ => None
    }
}

func safeDumpFilePart(value: String): String {
    let output = ArrayList<Byte>()
    for (byte in unsafe { value.rawData() }) {
        if ((byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') || (byte >= b'0' && byte <= b'9') ||
            byte == b'-' || byte == b'_') {
            output.add(byte)
        } else {
            output.add(b'_')
        }
    }
    if (output.isEmpty()) {
        "session"
    } else {
        String.fromUtf8(output.toArray())
    }
}

public func configuredModel(settings!: ProductSettings = ProductSettings()): String {
    envOr(
        "AXYNDRA_MODEL",
        if (settings.model == "") {
            "unconfigured"
        } else {
            settings.model
        }
    )
}

public func defaultProductHome(): String {
    match (getVariable("AXYNDRA_HOME")) {
        case Some(value) =>
            if (value.trimAscii() == "") {
                homeDirectory() + "/.axyndra"
            } else {
                value
            }
        case None => homeDirectory() + "/.axyndra"
    }
}

public func defaultStateRoot(): String {
    defaultProductHome() + "/sessions"
}

func homeDirectory(): String {
    match (getVariable("HOME")) {
        case Some(value) =>
            if (value.trimAscii() == "") {
                "."
            } else {
                value
            }
        case None => "."
    }
}

func envOr(name: String, fallback: String): String {
    match (getVariable(name)) {
        case Some(value) =>
            if (value.trimAscii() == "") {
                fallback
            } else {
                value
            }
        case None => fallback
    }
}

func productToolContext(workspaceRoot: String, operatorOptions180!: ?ProductOperatorOptions180 = None<ProductOperatorOptions180>): ToolContextDescriptor {
    ToolContextDescriptor(
        workspaceRoot: workspaceRoot,
        cwd: workspaceRoot,
        executionSettings180: match (operatorOptions180) { case Some(options) => options.executionSettingsValue180(); case None => nullValue() },
        modelFaultCounters180: match (operatorOptions180) { case Some(options) => options.modelFaultCounters180; case None => None<ModelStreamFaultCounters180> },
        environment: productToolEnvironment(),
        services: ToolServiceView(descriptors: [
            ToolServiceDescriptor(ToolServiceKind.Workspace, "local-workspace"),
            ToolServiceDescriptor(ToolServiceKind.Process, "local-process"),
            ToolServiceDescriptor(ToolServiceKind.Conversation, "session-conversation"),
            ToolServiceDescriptor(ToolServiceKind.Artifact, "product-artifact"),
            ToolServiceDescriptor(ToolServiceKind.Memory, "product-memory"),
            ToolServiceDescriptor(ToolServiceKind.Task, "product-task"),
            ToolServiceDescriptor(ToolServiceKind.Extension, "product-extension")
        ])
    )
}

func productToolEnvironment(): ToolEnvironmentView {
    let values = ArrayList<ToolEnvironmentEntry>()
    // Only non-secret presentation hints cross into ToolInvocationContext.
    // Provider credentials and the rest of the host environment stay private
    // to their owning adapters.
    for (name in ["TERM", "COLORTERM", "NO_COLOR"]) {
        match (getVariable(name)) {
            case Some(value) => if (!value.contains("\u{0000}")) {
                values.add(ToolEnvironmentEntry(name, value))
            }
            case None => ()
        }
    }
    ToolEnvironmentView(entries: values.toArray())
}

func productCompactionGoalFacts(goal: ?ProductGoalState): AgentValue {
    match (goal) {
        case Some(value) => objectValue([ValueField("objective", textValue(value.objective)), ValueField("status", textValue(value.status))])
        case None => nullValue()
    }
}
