package agent_product

import agent_client.*
import agent_app_protocol.*
import agent_core.*
import agent_domain.*
import agent_extensions.*
import agent_mcp.*
import agent_ports.*
import agent_runtime.*
import agent_skills.*
import agent_store.*
import model_adapters.*
import persistence_runtime.*
import run_control.*
import tool_runtime.*
import std.collection.*
import std.env.*
import std.convert.*
import std.fs.*
import std.sync.*
import agent_extension_runtime.*
import std.time.*

public class ProductConfig {
    public let settingsRoot: String
    public let stateRoot: String
    public let workspaceRoot: String
    public let fixture: Bool
    public let unsafeDirectLaunchForTests: Bool
    public let approvalMode: ApprovalMode
    public let approvalRoutingModeOverride: ?ApprovalRoutingMode
    public let modelOverride: String
    public let asyncEnabled: Bool
    public let wallTimeoutMillis: Int64
    public let modelAttemptRecovery: ModelAttemptRecoveryPolicy
    public let modelStreamFaultProfile: ?ModelStreamFaultProfile
    public let compactionOverride: ?ProductCompactionSettings
    public let startupMode: ProductStartupMode
    public let extensionSignatureVerifier: ?ExtensionPackageSignatureVerifier

    public init(
        settingsRoot!: String = defaultProductHome(),
        stateRoot!: String = defaultStateRoot(),
        workspaceRoot!: String = ".",
        fixture!: Bool = false,
        unsafeDirectLaunchForTests!: Bool = false,
        approvalMode!: ApprovalMode = ApprovalMode.AlwaysAsk,
        approvalRoutingModeOverride!: ?ApprovalRoutingMode = None,
        modelOverride!: String = "",
        asyncEnabled!: Bool = true,
        wallTimeoutMillis!: Int64 = 0,
        modelAttemptRecovery!: ModelAttemptRecoveryPolicy = ModelAttemptRecoveryPolicy(),
        modelStreamFaultProfile!: ?ModelStreamFaultProfile = None,
        compactionOverride!: ?ProductCompactionSettings = None,
        startupMode!: ProductStartupMode = ProductStartupMode.Full,
        extensionSignatureVerifier!: ?ExtensionPackageSignatureVerifier = None
    ) {
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
        this.asyncEnabled = asyncEnabled
        // 0 = no wall-clock limit (OMP behavior: a stream that keeps emitting
        // tokens is never cut off; only idle hangs are interrupted).
        this.wallTimeoutMillis = wallTimeoutMillis
        this.modelAttemptRecovery = modelAttemptRecovery
        this.modelStreamFaultProfile = modelStreamFaultProfile
        this.compactionOverride = compactionOverride
        this.startupMode = startupMode
        this.extensionSignatureVerifier = extensionSignatureVerifier
    }
}

// Local maintenance commands need the product's durable repositories and
// filesystem tools, but must not parse provider catalogs or start configured
// MCP children.  Full remains the only mode that can execute an agent turn.
public enum ProductStartupMode {
    | Full
    | LocalMaintenance
}

public class ProductIds <: IdGenerator {
    private let lock = Mutex()
    private var counter: Int64 = 0

    public init() {}

    public func nextRunId(): RunId {
        RunId(next("run"))
    }
    public func nextSessionId(): SessionId {
        SessionId(next("session"))
    }
    public func nextOperationId(): OperationId {
        OperationId(next("operation"))
    }

    private func next(prefix: String): String {
        lock.lock()
        try {
            counter += 1
            prefix + "-" + DateTime.nowUTC().toUnixTimeStamp().toMilliseconds().toString() + "-" + counter.toString()
        } finally {
            lock.unlock()
        }
    }
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

public class ProductRuntime {
    public let client: AgentClient
    public let ids: ProductIds
    public let workspace: LocalWorkspace
    public let model: String
    public let settingsRoot: String
    public let stateRoot: String
    public let asyncEnabled: Bool
    public let wallTimeoutMillis: Int64
    public let approvalSettings: ProductApprovalSettings
    public let compactionSettings: ProductCompactionSettings
    public var theme: String
    private let persistSettings: Bool
    private let sessionMetadata: SessionMetadataRepository
    private let runs: SqliteRunRepository
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let modelNames: Array<String>
    private let providerProfiles: Array<ProviderProfile>
    private let modelCatalog: Array<ModelCatalogEntry>
    private let processes: LocalProcessPort
    private let retryControl: RetryControl
    private let uriRouter: InternalUriRouter
    private let taskRuntime: ProductTaskRuntime
    private let askRuntime: AskRuntime
    private let goalRuntime: ProductGoalRuntime
    private let memoryRuntime: ProductMemoryRuntime
    private let skillRuntime: ProductSkillRuntime
    private let webSearchRuntime: ProductWebSearchRuntime
    private let compactionSummarizer: CompactionSummarizer
    private let approvalReviewer: ApprovalReviewer
    // Fixture-mode model probe: contracts observe the actual request
    // parameters (e.g. plan mode forces High thinking).
    public let fixtureProbe: ?FixtureModelPort
    public let vnext: ProductVnextControl
    private let extensions: ExtensionInstaller
    private let extensionRuntime: ExtensionRuntime
    private let mcpRuntime: ProductMcpRuntime
    private let vnextDatabase: SqliteDatabase
    private let threadRuntimes: ThreadRuntimeRegistry

    init(
        client: AgentClient,
        ids: ProductIds,
        workspace: LocalWorkspace,
        model: String,
        settingsRoot: String,
        stateRoot: String,
        asyncEnabled: Bool,
        wallTimeoutMillis: Int64,
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
        retryControl: RetryControl,
        uriRouter: InternalUriRouter,
        taskRuntime: ProductTaskRuntime,
        askRuntime: AskRuntime,
        goalRuntime: ProductGoalRuntime,
        memoryRuntime: ProductMemoryRuntime,
        skillRuntime: ProductSkillRuntime,
        webSearchRuntime: ProductWebSearchRuntime,
        compactionSummarizer: CompactionSummarizer,
        approvalReviewer: ApprovalReviewer,
        extensions: ExtensionInstaller,
        extensionRuntime: ExtensionRuntime,
        mcpRuntime: ProductMcpRuntime,
        vnextDatabase: SqliteDatabase,
        threadRuntimes: ThreadRuntimeRegistry,
        vnext: ProductVnextControl,
        fixtureProbe!: ?FixtureModelPort = None
    ) {
        this.client = client
        this.ids = ids
        this.workspace = workspace
        this.model = model
        this.settingsRoot = settingsRoot
        this.stateRoot = stateRoot
        this.asyncEnabled = asyncEnabled
        this.wallTimeoutMillis = wallTimeoutMillis
        this.approvalSettings = approvalSettings
        this.compactionSettings = compactionSettings
        this.theme = theme
        this.persistSettings = persistSettings
        this.sessionMetadata = sessionMetadata
        this.runs = runs
        this.catalog = catalog
        this.pipeline = pipeline
        this.modelNames = modelNames
        this.providerProfiles = providerProfiles
        this.modelCatalog = modelCatalog
        this.processes = processes
        this.retryControl = retryControl
        this.uriRouter = uriRouter
        this.taskRuntime = taskRuntime
        this.askRuntime = askRuntime
        this.goalRuntime = goalRuntime
        this.memoryRuntime = memoryRuntime
        this.skillRuntime = skillRuntime
        this.webSearchRuntime = webSearchRuntime
        this.compactionSummarizer = compactionSummarizer
        this.approvalReviewer = approvalReviewer
        this.extensions = extensions
        this.extensionRuntime = extensionRuntime
        this.mcpRuntime = mcpRuntime
        this.vnextDatabase = vnextDatabase
        this.threadRuntimes = threadRuntimes
        this.vnext = vnext
        this.fixtureProbe = fixtureProbe
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
        skillStack!: SkillStackSnapshot = SkillStackSnapshot([], [])
    ): AgentRunRequest {
        let targetSession = match (sessionId) {
            case Some(value) => value
            case None => ids.nextSessionId()
        }
        let promptBuild = requestPromptBuild(
            targetSession,
            guide,
            modeSystem,
            memoryQuery: prompt
        )
        let resolvedSkillStack = skillRuntime.resolve(prompt, skillStack)
        let system = promptBuild.text
        let capabilities = requestCapabilities(readOnly)
        let selectedModel = if (modelOverride == "") {
            model
        } else {
            modelOverride
        }
        let requestCompaction = compactionSettings.resolvedForModel(selectedModel)
        let metadata = modelMetadata(selectedModel)
        let selectedCapabilities = match (metadata) {
            case Some(value) => configuredProductModelCapabilities(
                value,
                providerProfiles
            )
            case None => productModelCapabilities(ModelCatalogEntry(
                "unknown",
                thinking: if (fixtureProbe.isSome()) {
                    Some(ThinkingCapabilities(
                        ThinkingControlMode.Effort,
                        supportedLevels: canonicalNonOffThinkingLevels()
                    ))
                } else { None },
                // The fixture transport exposes the final ModelRequest to
                // contracts, including Product's stable-prefix cache key.
                promptCache: if (selectedModel == "fixture" && fixtureProbe.isSome()) {
                    Some(true)
                } else {
                    None
                }
            ))
        }
        let providerSafetyMargin: Int64 = 1024
        let providerContextWindow = selectedCapabilities.contextWindowTokens
        let contextLimit = match (metadata) {
            case Some(value) => match (value.contextWindow) {
                case Some(window) => min(
                    requestCompaction.maxInputTokens,
                    max(1, window - selectedCapabilities.maxOutputTokens - providerSafetyMargin)
                )
                case None => requestCompaction.maxInputTokens
            }
            case None => requestCompaction.maxInputTokens
        }
        let outputLimit = match (metadata) {
            case Some(_) => selectedCapabilities.maxOutputTokens
            case None => 100000
        }
        let endpointOutputLimit: ?Int64 = match (metadata) {
            case Some(value) => match (profileById(value.providerProfile)) {
                case Some(profile) => profile.endpointMaxOutputTokens
                case None => None
            }
            case None => None
        }
        let serviceTier = if (fastModeEnabled(targetSession)) {
            fastTierForModel(selectedModel)
        } else {
            ""
        }
        AgentRunRequest(
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
                endpointMaxOutputTokens: endpointOutputLimit
            )),
            capabilities: capabilities,
            interactions: interactions,
            autoRetry: retryControl.isEnabled(),
            serviceTier: serviceTier,
            pricing: match (metadata) {
                case Some(value) => value.pricing()
                case None => None
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
            toolContext: productToolContext(workspace.rootPath()),
            skillStack: resolvedSkillStack,
            contextWindow: providerContextWindow,
            providerSafetyMargin: providerSafetyMargin,
            budget: ResourceBudget(
                maxInputTokens: contextLimit,
                maxOutputTokens: outputLimit,
                maxWallMillis: wallTimeoutMillis,
                maxContextMessages: requestCompaction.requestMaxMessages
            )
        )
    }

    func directProcessSandboxEnabled(): Bool {
        processes.sandboxEnabled()
    }

    private func requestPromptBuild(
        sessionId: SessionId,
        guide: String,
        modeSystem: String,
        memoryQuery!: String = ""
    ): PromptBuild {
        let activeGoal = match (goalRuntime.activePrompt(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => ""
        }
        let memoryContext = if (memoryQuery.trimAscii() == "") {
            ""
        } else {
            match (memoryRuntime.contextFor(
                memoryQuery,
                sessionId,
                workspace.rootPath(),
                16384
            )) {
                case Result.Ok(value) => value
                // Automatic recall is optional context. A corrupt or
                // unavailable memory store must not block the user turn.
                case Result.Err(_) => ""
            }
        }
        buildProductPrompt(
            workspace.rootPath(),
            activeGoal,
            guide,
            modeSystem,
            memoryContext: memoryContext,
            skillMetadata: skillRuntime.metadata()
        )
    }

    private func requestSystem(
        sessionId: SessionId,
        guide: String,
        modeSystem: String
    ): String {
        requestPromptBuild(sessionId, guide, modeSystem).text
    }

    private func requestCapabilities(readOnly: Bool): CapabilitySet {
        if (readOnly) {
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)])
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

    public func finalizeGoalRun(sessionId: SessionId): Result<Unit> {
        goalRuntime.finalizeRun(sessionId)
    }

    public func pauseGoal(sessionId: SessionId): Result<Unit> {
        goalRuntime.pause(sessionId)
    }

    public func pauseRestoredGoal(sessionId: SessionId): Result<Unit> {
        goalRuntime.pauseRestoredActive(sessionId)
    }

    public func goalState(sessionId: SessionId): Result<?ProductGoalState> {
        goalRuntime.state(sessionId)
    }

    public func createGoal(
        sessionId: SessionId,
        objective: String
    ): Result<ProductGoalState> {
        goalRuntime.createGoal(sessionId, objective)
    }

    public func replaceGoal(
        sessionId: SessionId,
        objective: String
    ): Result<ProductGoalState> {
        goalRuntime.replaceGoal(sessionId, objective)
    }

    public func setGoalBudget(
        sessionId: SessionId,
        tokenBudget: ?Int64
    ): Result<ProductGoalState> {
        goalRuntime.setBudget(sessionId, tokenBudget)
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

    public func cancelCompaction(sessionId: SessionId): Result<Unit> {
        compactionSummarizer.cancel(sessionId)
    }

    public func tools(): Array<ModelToolDefinition> {
        catalog.definitions()
    }

    public func extensionSnapshots(): Array<ExtensionSnapshot> {
        extensions.snapshots()
    }

    public func extensionDiagnostics(): Array<ExtensionDiagnostic> {
        extensionRuntime.diagnostics()
    }

    public func mcpSnapshots(): Array<ProductMcpServerSnapshot> {
        mcpRuntime.snapshots()
    }

    public func mcpStatus(serverId: String): ?ProductMcpServerSnapshot {
        mcpRuntime.status(serverId)
    }

    public func cancelMcp(runId: RunId): Result<Unit> {
        mcpRuntime.cancel(runId)
    }

    public func closeMcp(): Result<Unit> {
        mcpRuntime.close()
    }

    public func close(): Result<Unit> {
        let extensionResult = extensionRuntime.shutdown()
        let taskResult = taskRuntime.close()
        let processResult = processes.close()
        let mcpResult = mcpRuntime.close()
        try {
            vnextDatabase.close()
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.Internal,
                "product.state_database_close_failed",
                error.message
            ))
        }
        match (extensionResult) {
            case ExtensionRuntimeResult.Err(error) => return Result.Err(extensionRuntimeAgentError(error))
            case ExtensionRuntimeResult.Ok(_) => ()
        }
        match (taskResult) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => match (processResult) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => mcpResult
            }
        }
    }

    public func mcpServer(options: ProductMcpServerOptions): McpServer {
        buildProductMcpServer(
            catalog,
            pipeline,
            ids,
            options,
            productToolContext(workspace.rootPath())
        )
    }

    public func setExtensionEnabled(
        extensionId: String,
        enabled: Bool
    ): Result<Unit> {
        let result = if (enabled) {
            extensionRuntime.activate(extensionId)
        } else {
            extensionRuntime.deactivate(extensionId)
        }
        match (result) {
            case ExtensionRuntimeResult.Ok(_) => Result.Ok(())
            case ExtensionRuntimeResult.Err(error) => Result.Err(extensionRuntimeAgentError(error))
        }
    }

    public func toolsFor(capabilities: CapabilitySet): Array<ModelToolDefinition> {
        catalog.definitionsFor(capabilities)
    }

    public func invokeLocalTool(
        sessionId: SessionId,
        name: String,
        arguments: AgentValue,
        skillStack!: SkillStackSnapshot = SkillStackSnapshot([], [])
    ): Result<ToolResult> {
        let callId = "cli-" + name + "-" + ids.nextOperationId().value
        let context = ToolInvocationContext(
            ids.nextRunId(),
            sessionId,
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
            ),
            toolContext: productToolContext(workspace.rootPath()),
            skills: skillStack
        )
        match (pipeline.invoke(
            context,
            ToolCall(callId, name, arguments)
        )) {
            case Result.Ok(ToolInvocationResult.Completed(result)) =>
                if (result.isError) {
                    Result.Err(productToolResultError(result))
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

    public func executePersistentShell(
        sessionId: SessionId,
        command: String,
        timeoutMillis!: Int64 = 30000
    ): Result<ProcessResult> {
        if (command.trimAscii() == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "shell.empty_command",
                    "shell command must not be empty"
                )
            )
        }
        processes.executeShell(
            sessionId,
            ProcessRequest(
                "/bin/bash",
                operationId: ids.nextOperationId(),
                arguments: [command],
                workingDirectory: workspace.rootPath(),
                timeoutMillis: max(1, timeoutMillis),
                sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
            )
        )
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

    public func uriSchemes(): Array<String> {
        uriRouter.schemes()
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
            case None => return ProductContextUsage(None, None, None)
        }
        let window = match (metadata.contextWindow) {
            case Some(value) => value
            case None => return ProductContextUsage(None, None, None)
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
                    case Result.Err(_) => return ProductContextUsage(None, Some(window), None)
                }
            }
            // Stats are an optimization for authoritative usage; if no usable
            // snapshot can be read, retain the deterministic projection
            // estimate instead of turning a healthy session into an error.
            case Result.Err(_) => match (modelContext(sessionId)) {
                case Result.Ok(messages) => estimateMessagesTokens(messages)
                case Result.Err(_) => return ProductContextUsage(None, Some(window), None)
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

    public func continuationRequest(
        value: RunContinuation,
        interactions: ?AgentInteractionSource
    ): AgentRunRequest {
        AgentRunRequest(
            value.runId,
            value.sessionId,
            value.model,
            value.prompt,
            system: value.system,
            thinking: value.thinking,
            userRequestedThinking: match (value.requestedPolicy) {
                case Some(policy) => policy.userRequestedThinking
                case None => None
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
            toolContext: productToolContext(workspace.rootPath()),
            skillStack: if (value.skillStackPayload.fields.isEmpty()) {
                SkillStackSnapshot([], [])
            } else { skillStackFromSnapshotValue(value.skillStackPayload) },
            contextWindow: value.contextWindow,
            providerSafetyMargin: value.providerSafetyMargin
        )
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
            skillStackPayload: skillStackSnapshotValue(request.skillStack),
            contextWindow: request.contextWindow,
            providerSafetyMargin: request.providerSafetyMargin,
            toolContextPayload: productToolContextValue(request.toolContext)
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

    public func executeBash(
        command: String,
        operationId: OperationId
    ): Result<ProcessResult> {
        // This is an explicitly user-authored application/RPC control command,
        // not a model tool invocation, so it does not mint an approval grant or
        // a ToolPipeline receipt. It still crosses the process boundary and
        // therefore must use the enforced product workspace sandbox.
        processes.execute(
            ProcessRequest(
                "/bin/bash",
                operationId: operationId,
                arguments: ["--noprofile", "--norc", "-lc", command],
                workingDirectory: workspace.rootPath(),
                timeoutMillis: 120000,
                sandboxMode: ProcessSandboxMode.WorkspaceReadWrite
            )
        )
    }

    public func abortBash(operationId: OperationId): Result<Unit> {
        processes.cancel(operationId)
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
        let capabilities = requestCapabilities(readOnly)
        for (definition in catalog.definitionsFor(capabilities)) {
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
        // Trusted UI boundary: clipboard staging is an explicit application
        // action over a product-owned file, never a model ToolCall. Native
        // display-server access cannot be represented by the workspace bwrap.
        let encoded = match (processes.execute(
            ProcessRequest(
                "/bin/sh",
                operationId: ids.nextOperationId(),
                arguments: [
                    "-c",
                    "base64 < \"$1\" | tr -d '\\n'",
                    "axyndra-clipboard",
                    path
                ],
                timeoutMillis: 5000
            )
        )) {
            case Result.Ok(result) =>
                if (result.exitCode == 0 && result.stdout.trimAscii() != "") {
                    result.stdout.trimAscii()
                } else {
                    try {
                        removeIfExists(path)
                    } catch (_: Exception) {}
                    return Result.Err(
                        AgentError(
                            AgentErrorKind.Internal,
                            "clipboard.base64_failed",
                            if (result.stderr.trimAscii() == "") {
                                "base64 produced no output"
                            } else {
                                result.stderr.trimAscii()
                            }
                        )
                    )
                }
            case Result.Err(error) =>
                try {
                    removeIfExists(path)
                } catch (_: Exception) {}
                return Result.Err(error)
        }
        let native = if (!nativeEnabled) {
            false
        } else {
            // Same trusted UI boundary as the deterministic base64 branch;
            // argv and the staged path are entirely product-authored.
            match (processes.execute(
                ProcessRequest(
                    "/bin/sh",
                    operationId: ids.nextOperationId(),
                    arguments: [
                        "-c",
                        "if command -v wl-copy >/dev/null 2>&1; then " + "wl-copy < \"$1\"; " +
                            "elif command -v xclip >/dev/null 2>&1; then " + "xclip -selection clipboard < \"$1\"; " +
                            "elif command -v xsel >/dev/null 2>&1; then " + "xsel --clipboard --input < \"$1\"; " +
                            "else exit 127; fi",
                        "axyndra-clipboard",
                        path
                    ],
                    timeoutMillis: 5000
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
        force!: Bool = true
    ): Result<Int64> {
        let messages = match (modelContext(sessionId)) {
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
        let tools = catalog.definitionsFor(productCapabilities())
        let estimated = estimateContextTokens(messages, tools: tools)
        let tokenTriggered = estimated >= compactionTriggerTokens(budget, policy)
        let messageTriggered = messages.size >= policy.emergencyMessageLimit
        let checkpointRetainIndex = activeCheckpointRetainIndex(messages)
        if ((!force && !tokenTriggered && !messageTriggered) ||
            (force && messages.size <= policy.keepRecentMessages)) {
            return Result.Ok(0)
        }

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
                return activeCheckpointCompactionError<Int64>()
            }
            return Result.Ok(0)
        }

        var compacted = compactedMessages(messages, removed, sessionId)
        while (removed < messages.size && estimateContextTokens(compacted, tools: tools) > target) {
            let next = findSafeCutPoint(messages, removed + 1)
            if (next <= removed ||
                (checkpointRetainIndex >= 0 && next > checkpointRetainIndex)) {
                break
            }
            removed = next
            compacted = compactedMessages(messages, removed, sessionId)
        }
        if (checkpointRetainIndex >= 0 &&
            estimateContextTokens(compacted, tools: tools) > target) {
            return activeCheckpointCompactionError<Int64>()
        }
        if (!isToolProtocolComplete(compacted)) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Protocol,
                    "session.compaction_protocol_invalid",
                    "compaction could not produce a complete tool protocol window"
                )
            )
        }
        match (saveCanonicalCheckpoint(
            sessionId,
            policy.keepRecentMessages,
            target,
            tools,
            settings,
            sessionModel
        )) {
            case Result.Ok(_) => Result.Ok(removed)
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func saveCanonicalCheckpoint(
        sessionId: SessionId,
        keepRecentItems: Int64,
        targetTokens: Int64,
        tools: Array<ModelToolDefinition>,
        settings: ProductCompactionSettings,
        sessionModel: String
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
        let checkpointRetainOrdinal = activeCheckpointRetainOrdinal(thread)
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
                return activeCheckpointCompactionError<Unit>()
            }
            return Result.Ok(())
        }
        let goal: ?ProductGoalState = match (goalState(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => None
        }
        let todos: Array<TodoPhase> = match (todoPhases(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(_) => []
        }
        let activeGoal = match (goal) {
            case Some(value) => value.objective
            case None => ""
        }
        var selected: ?ContextCheckpoint = None
        var inputLimitFallback: ?ContextCheckpoint = None
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
                None,
                prefix.toArray(),
                objectValue([]),
                0,
                false
            ))
            let deterministicSummary = compactionSummary(
                prefixMessages,
                goal: goal,
                todos: todos
            )
            let candidate = ContextCheckpoint(
                "checkpoint-" + sessionId.value + "-" + cover.toString() + "-" +
                    thread.thread.revision.toString(),
                thread.thread.id,
                cover,
                objectValue([
                    ValueField("deterministic_summary", textValue(deterministicSummary)),
                    ValueField("covered_items", integerValue(cover))
                ]),
                contextSourceDigest(thread, cover),
                "agent-product-v1",
                "agent-core",
                activeGoal: activeGoal
            )
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
                inputLimitFallback = Some(candidate)
            }
            if (projectedTokens <= targetTokens) {
                selected = Some(candidate)
                break
            }
            cover += 1
        }
        let deterministicCheckpoint = match (selected) {
            case Some(value) => value
            case None => match (inputLimitFallback) {
                case Some(value) => value
                case None => return activeCheckpointCompactionError<Unit>()
            }
        }
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
                    settings.summaryMaxOutputTokens
                ),
                deterministicSummary,
                settings.summaryTimeoutMillis,
                settings.summaryMaxOutputTokens
            )) {
                case Some(overview) =>
                    let candidate = ContextCheckpoint(
                        deterministicCheckpoint.id,
                        deterministicCheckpoint.threadId,
                        deterministicCheckpoint.coversThroughItemOrdinal,
                        objectValue([
                            ValueField(
                                "deterministic_summary",
                                textValue(compactionSummaryWithOverview(
                                    deterministicSummary, overview
                                ))
                            ),
                            ValueField(
                                "covered_items",
                                integerValue(deterministicCheckpoint.coversThroughItemOrdinal)
                            )
                        ]),
                        deterministicCheckpoint.sourceDigest,
                        deterministicCheckpoint.projectorVersion,
                        deterministicCheckpoint.laneCompatibility,
                        activeGoal: deterministicCheckpoint.activeGoal
                    )
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
                        checkpoint = candidate
                    }
                case None => ()
            }
        }
        SqliteContextCheckpointStore(vnextDatabase).save(
            checkpoint, thread, agentUtcMillis()
        )
    }

    private func compactionAccountingRequest(
        sessionId: SessionId,
        summaryModel: String,
        timeoutMillis: Int64,
        maxOutputTokens: Int64
    ): AgentRunRequest {
        let metadata = modelMetadata(summaryModel)
        let capabilities = match (metadata) {
            case Some(value) => configuredProductModelCapabilities(
                value,
                providerProfiles
            )
            case None => productModelCapabilities(ModelCatalogEntry(
                "unknown",
                promptCache: if (summaryModel == "fixture" && fixtureProbe.isSome()) {
                    Some(true)
                } else {
                    None
                }
            ))
        }
        AgentRunRequest(
            ids.nextRunId(),
            sessionId,
            summaryModel,
            "Generate the internal context compaction summary.",
            system: COMPACTION_SEMANTIC_SYSTEM_PROMPT,
            thinking: ThinkingLevel.Low,
            modelCapabilitiesSnapshot: Some(ModelExecutionCapabilitiesSnapshot(
                summaryModel,
                capabilities.thinking,
                capabilities.maxOutputTokens,
                endpointMaxOutputTokens: match (metadata) {
                    case Some(value) => match (profileById(value.providerProfile)) {
                        case Some(profile) => profile.endpointMaxOutputTokens
                        case None => None
                    }
                    case None => None
                }
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
                case None => None
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
            toolContext: productToolContext(workspace.rootPath()),
            budget: ResourceBudget(
                maxInputTokens: match (metadata) {
                    case Some(value) => match (value.contextWindow) {
                        case Some(limit) => limit
                        case None => compactionSettings.resolvedForModel(
                            summaryModel
                        ).maxInputTokens
                    }
                    case None => compactionSettings.resolvedForModel(
                        summaryModel
                    ).maxInputTokens
                },
                maxOutputTokens: max(1, maxOutputTokens),
                maxModelRequests: if (retryControl.isEnabled()) { 2 } else { 1 },
                maxWallMillis: max(1, timeoutMillis)
            )
        )
    }

    private func compactedMessages(
        messages: Array<ModelMessage>,
        removed: Int64,
        sessionId: SessionId,
        summary!: ?String = None
    ): Array<ModelMessage> {
        let summaryText = match (summary) {
            case Some(value) => value
            case None =>
                let goal: ?ProductGoalState = match (goalState(sessionId)) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => None
                }
                let todos: Array<TodoPhase> = match (todoPhases(sessionId)) {
                    case Result.Ok(value) => value
                    case Result.Err(_) => []
                }
                compactionSummary(
                    messages[0..removed],
                    goal: goal,
                    todos: todos
                )
        }
        let compacted = ArrayList<ModelMessage>()
        compacted.add(
            ModelMessage(
                ModelRole.User,
                [
                    ModelBlock(
                        ModelBlockKind.Text,
                        text: summaryText
                    )
                ]
            )
        )
        for (message in messages[removed..messages.size]) {
            compacted.add(message)
        }
        compacted.toArray()
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

    public func todoPhases(sessionId: SessionId): Result<Array<TodoPhase>> {
        match (sessionMetadata.todoPhases(sessionId)) {
            case Result.Ok(value) => decodeTodoPhases(value)
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func setTodoPhases(
        sessionId: SessionId,
        phases: Array<TodoPhase>
    ): Result<Unit> {
        sessionMetadata.setTodoPhases(
            sessionId,
            encodeTodoPhases(phases)
        )
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

    public func searchWeb(
        sessionId: SessionId,
        query: String,
        provider: String,
        recency: String,
        limit: ?Int64
    ): Result<ToolResult> {
        let fields = ArrayList<ValueField>()
        fields.add(ValueField("query", textValue(query)))
        if (recency != "") {
            fields.add(ValueField("recency", textValue(recency)))
        }
        match (limit) {
            case Some(value) => fields.add(ValueField("limit", integerValue(value)))
            case None => ()
        }
        let call = ToolCall(
            "cli-search-" + ids.nextOperationId().value,
            "web_search",
            objectValue(fields.toArray())
        )
        webSearchRuntime.executeSelected(
            ToolInvocationContext(
                ids.nextRunId(),
                sessionId,
                CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
                toolContext: productToolContext(workspace.rootPath())
            ),
            call,
            provider
        )
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
        retryControl.abort(requestId)
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
                transaction.execute("DELETE FROM tool_operation_intents")
                transaction.execute("DELETE FROM session_permission_grants")
                transaction.execute("DELETE FROM thread_metadata")
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
        let config = encodeProductSettings(
            configuredModel,
            asyncEnabled,
            theme: theme,
            approval: approvalSettings,
            compaction: compactionSettings
        )
        match (atomicConfigWrite(settingsRoot + "/config.yml", config)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
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
        Result.Ok(())
    }

    public func saveTheme(name: String): Result<Unit> {
        if (!persistSettings) {
            return Result.Ok(())
        }
        let settings = match (loadProductSettings(settingsRoot)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let saved = atomicConfigWrite(
            settingsRoot + "/config.yml",
            encodeProductSettings(
                settings.model,
                settings.asyncEnabled,
                theme: name,
                approval: settings.approval,
                compaction: settings.compaction
            )
        )
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

public func encodeTodoPhases(phases: Array<TodoPhase>): AgentValue {
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

public func decodeTodoPhases(value: AgentValue): Result<Array<TodoPhase>> {
    if (value.kind != ValueKind.List) {
        return invalidTodoData("todo phases must be a list")
    }
    let phases = ArrayList<TodoPhase>()
    for (phaseValue in value.items) {
        if (phaseValue.kind != ValueKind.Object) {
            return invalidTodoData("todo phase must be an object")
        }
        let name = match (phaseValue.field("name")) {
            case Some(field) =>
                if (field.kind != ValueKind.Text || field.text.trimAscii() == "") {
                    return invalidTodoData("todo phase name must be a non-empty string")
                }
                field.text
            case None => return invalidTodoData("todo phase name is required")
        }
        let taskValues = match (phaseValue.field("tasks")) {
            case Some(field) =>
                if (field.kind != ValueKind.List) {
                    return invalidTodoData("todo phase tasks must be a list")
                }
                field.items
            case None => return invalidTodoData("todo phase tasks are required")
        }
        let tasks = ArrayList<TodoItem>()
        for (taskValue in taskValues) {
            if (taskValue.kind != ValueKind.Object) {
                return invalidTodoData("todo task must be an object")
            }
            let content = match (taskValue.field("content")) {
                case Some(field) =>
                    if (field.kind != ValueKind.Text || field.text.trimAscii() == "") {
                        return invalidTodoData("todo task content must be a non-empty string")
                    }
                    field.text
                case None => return invalidTodoData("todo task content is required")
            }
            let status = match (taskValue.field("status")) {
                case Some(field) =>
                    if (field.kind != ValueKind.Text) {
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
                    if (field.kind != ValueKind.Text) {
                        return invalidTodoData("todo task blocker must be a string")
                    }
                    field.text
                case None => ""
            }
            tasks.add(TodoItem(content, status: status, blocker: blocker))
        }
        phases.add(TodoPhase(name, tasks.toArray()))
    }
    Result.Ok(phases.toArray())
}

func todoStatusName(status: TodoStatus): String {
    match (status) {
        case TodoStatus.Pending => "pending"
        case TodoStatus.InProgress => "in_progress"
        case TodoStatus.Completed => "completed"
        case TodoStatus.Abandoned => "abandoned"
        case TodoStatus.Blocked => "blocked"
    }
}

func todoStatusValue(value: String): ?TodoStatus {
    match (value) {
        case "pending" => Some(TodoStatus.Pending)
        case "in_progress" => Some(TodoStatus.InProgress)
        case "completed" => Some(TodoStatus.Completed)
        case "abandoned" => Some(TodoStatus.Abandoned)
        case "blocked" => Some(TodoStatus.Blocked)
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

let MODEL_COMPACTION_OVERVIEW_MARKER = "\nmodel-generated overview (non-authoritative):\n"

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

func authoritativeCompactionSummary(value: String): String {
    match (value.indexOf(MODEL_COMPACTION_OVERVIEW_MARKER)) {
        case Some(index) => value[..index]
        case None => value
    }
}

func compactionSummary(
    messages: Array<ModelMessage>,
    goal!: ?ProductGoalState = None,
    todos!: Array<TodoPhase> = []
): String {
    var users: Int64 = 0
    var assistants: Int64 = 0
    let excerpts = ArrayList<String>()
    let priorSummaries = ArrayList<String>()
    let tools = ArrayList<String>()
    let readFiles = ArrayList<String>()
    let modifiedFiles = ArrayList<String>()
    let createdFiles = ArrayList<String>()
    let commands = ArrayList<String>()
    let results = ArrayList<String>()
    let diagnostics = ArrayList<String>()
    for (message in messages) {
        if (message.role == ModelRole.User) {
            users += 1
        } else {
            assistants += 1
        }
        for (block in message.blocks) {
            if (block.kind == ModelBlockKind.Text || block.kind == ModelBlockKind.Reasoning) {
                if (block.text.startsWith("[Compacted session history]")) {
                    addUniqueLimited(
                        priorSummaries,
                        compactText(authoritativeCompactionSummary(block.text), 1600),
                        2
                    )
                } else if (excerpts.size < 6) {
                    let excerpt = compactText(block.text, 240)
                    if (excerpt != "") {
                        excerpts.add(if (message.role == ModelRole.User) { "user: " } else { "assistant: " } + excerpt)
                    }
                }
            }
            if (block.kind == ModelBlockKind.ToolCall) {
                addUniqueLimited(tools, block.name, 24)
                let path = argumentText(block.arguments, "path")
                if (path != "") {
                    if (block.name == "write" || block.name == "edit") {
                        addUniqueLimited(modifiedFiles, path, 24)
                    } else {
                        addUniqueLimited(readFiles, path, 24)
                    }
                }
                if (block.name == "edit") {
                    collectHashlinePaths(
                        argumentText(block.arguments, "input"),
                        modifiedFiles
                    )
                }
                let command = argumentText(block.arguments, "command")
                if (command != "") {
                    addUniqueLimited(commands, compactText(command, 240), 8)
                }
            }
            if (block.kind == ModelBlockKind.ToolResult) {
                let action = argumentText(block.arguments, "action")
                let path = argumentText(block.arguments, "path")
                if (path != "" && action == "create") {
                    addUniqueLimited(createdFiles, path, 24)
                } else if (path != "" && action == "overwrite") {
                    addUniqueLimited(modifiedFiles, path, 24)
                }
                let exitCode = argumentNumber(block.arguments, "exit_code")
                if (exitCode != "") {
                    addUniqueLimited(
                        results,
                        (if (block.name == "") { "command" } else { block.name }) + " exit " + exitCode,
                        10
                    )
                }
                let status = argumentText(block.arguments, "status")
                if (status != "") {
                    addUniqueLimited(results, block.name + ": " + compactText(status, 160), 10)
                }
                if (block.isError || (exitCode != "" && exitCode != "0")) {
                    let detail = firstNonEmpty([
                        argumentText(block.arguments, "stderr"),
                        argumentText(block.arguments, "error"),
                        block.text
                    ])
                    addUniqueLimited(
                        diagnostics,
                        (if (block.name == "") { "tool" } else { block.name }) + ": " +
                            if (detail == "") { "failed" } else { compactText(detail, 280) },
                        10
                    )
                }
            }
        }
    }
    var summary = "[Compacted session history]\n" + "messages: " + messages.size.toString() + " (user " +
        users.toString() + ", assistant " + assistants.toString() + ")"
    match (goal) {
        case Some(value) =>
            summary += "\ngoal:\n- objective: " + compactText(value.objective, 500) + "\n- status: " + value.status
        case None => ()
    }
    let unresolved = unresolvedTodos(todos)
    if (!unresolved.isEmpty()) {
        summary += "\nunresolved:"
        for (item in unresolved) {
            summary += "\n- " + item
        }
    }
    if (!priorSummaries.isEmpty()) {
        summary += "\nprior structured context:"
        for (value in priorSummaries) {
            summary += "\n---\n" + value
        }
    }
    if (!excerpts.isEmpty()) {
        summary += "\nkey excerpts:"
        for (excerpt in excerpts) {
            summary += "\n- " + excerpt
        }
    }
    if (!tools.isEmpty()) {
        summary += "\ntools: " + joinCompact(tools.toArray())
    }
    let files = mergedFileSummary(readFiles, modifiedFiles, createdFiles)
    if (files != "") {
        summary += "\nfiles:\n" + files
    }
    if (!commands.isEmpty()) {
        summary += "\nimportant commands:"
        for (command in commands) {
            summary += "\n- " + command
        }
    }
    if (!results.isEmpty()) {
        summary += "\ntool results:"
        for (result in results) {
            summary += "\n- " + result
        }
    }
    if (!diagnostics.isEmpty()) {
        summary += "\ndiagnostics:"
        for (diagnostic in diagnostics) {
            summary += "\n- " + diagnostic
        }
    }
    summary
}

func compactText(value: String, limit: Int64): String {
    let text = value.replace("\r", "").replace("\n", " ").trimAscii()
    if (text.size <= limit) {
        text
    } else {
        text[..limit] + "..."
    }
}

func argumentText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Text) {
                item.text
            } else {
                ""
            }
        case None => ""
    }
}

func argumentNumber(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(item) =>
            if (item.kind == ValueKind.Number) { item.number } else { "" }
        case None => ""
    }
}

func firstNonEmpty(values: Array<String>): String {
    for (value in values where value.trimAscii() != "") {
        return value
    }
    ""
}

func unresolvedTodos(phases: Array<TodoPhase>): Array<String> {
    let values = ArrayList<String>()
    for (phase in phases) {
        for (task in phase.tasks) {
            match (task.status) {
                case TodoStatus.Pending | TodoStatus.InProgress =>
                    addUniqueLimited(values, phase.name + ": " + compactText(task.content, 240), 16)
                case TodoStatus.Blocked =>
                    addUniqueLimited(
                        values,
                        phase.name + ": " + compactText(task.content, 200) + if (task.blocker == "") {
                            " [blocked]"
                        } else {
                            " [blocked: " + compactText(task.blocker, 160) + "]"
                        },
                        16
                    )
                case _ => ()
            }
        }
    }
    values.toArray()
}

func collectHashlinePaths(
    input: String,
    output: ArrayList<String>
): Unit {
    for (line in input.split("\n")) {
        if (line.startsWith("[") && line.endsWith("]")) {
            let separator = line.indexOf("#")
            match (separator) {
                case Some(index) =>
                    if (index > 1) {
                        addUniqueLimited(output, line[1..index], 24)
                    }
                case None => ()
            }
        }
    }
}

func mergedFileSummary(
    reads: ArrayList<String>,
    modifications: ArrayList<String>,
    creations: ArrayList<String>
): String {
    var result = ""
    for (path in reads) {
        let mode = if (containsValue(creations, path)) {
            "Created"
        } else if (containsValue(modifications, path)) {
            "RW"
        } else {
            "Read"
        }
        result += if (result == "") {
            ""
        } else {
            "\n"
        }
        result += "- " + path + " (" + mode + ")"
    }
    for (path in modifications where !containsValue(reads, path) && !containsValue(creations, path)) {
        result += if (result == "") {
            ""
        } else {
            "\n"
        }
        result += "- " + path + " (Write)"
    }
    for (path in creations where !containsValue(reads, path)) {
        result += if (result == "") { "" } else { "\n" }
        result += "- " + path + " (Created)"
    }
    result
}

func addUnique(values: ArrayList<String>, value: String): Unit {
    if (value != "" && !containsValue(values, value)) {
        values.add(value)
    }
}

func addUniqueLimited(
    values: ArrayList<String>,
    value: String,
    limit: Int64
): Unit {
    if (values.size < limit) {
        addUnique(values, value)
    }
}

func containsValue(values: ArrayList<String>, value: String): Bool {
    for (candidate in values where candidate == value) {
        return true
    }
    false
}

func joinCompact(values: Array<String>): String {
    var result = ""
    for (value in values) {
        if (result != "") {
            result += ", "
        }
        result += value
    }
    result
}

public func openProduct(config!: ProductConfig = ProductConfig()): Result<ProductRuntime> {
    let localMaintenance = match (config.startupMode) {
        case ProductStartupMode.LocalMaintenance => true
        case ProductStartupMode.Full => false
    }
    if (!config.fixture) {
        match (ensureProductLayout(config.settingsRoot)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let loadedSettings = if (config.fixture &&
        config.settingsRoot == defaultProductHome()) {
        // A fixture model must not accidentally inherit the developer's live
        // product configuration. Explicit fixture settings roots still load
        // the real config contract so policy/configuration behavior remains
        // testable without a real provider.
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
        approval: approvalSettings,
        compaction: match (config.compactionOverride) {
            case Some(value) => value
            case None => loadedSettings.compaction
        }
    )
    let loadedProfiles: Array<ProviderProfile> = if (config.fixture || localMaintenance) {
        []
    } else {
        match (loadProviderProfiles(config.settingsRoot)) {
            case Result.Ok(values) => values
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let loadedCatalog: Array<ModelCatalogEntry> = if (config.fixture || localMaintenance) {
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
    let vnextDatabase = match (openVnextDatabase(config.stateRoot + "/state.db")) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    let sessionMetadata = SqliteSessionMetadataRepository(vnextDatabase)
    let runs = SqliteRunRepository(vnextDatabase)
    let operations = SqliteToolOperationRepository(vnextDatabase)
    let audit = SqliteAuditRepository(vnextDatabase)
    let permissions = SqlitePermissionRepository(vnextDatabase)
    let threadRuntimes = SqliteThreadRuntimeRegistry(
        vnextDatabase,
        ContextProjector("agent-product-v1", ConservativeThreadTokenEstimator()),
        { => agentUtcMillis() }
    )
    let ids = ProductIds()
    let workspace = LocalWorkspace(config.workspaceRoot)
    let sandboxToolchain = configuredProductSandboxToolchain()
    let processes = LocalProcessPort(
        workspace,
        // Model-triggered process requests are fail-closed unless the
        // workspace sandbox is enabled. Fixture transports exercise the same
        // execution boundary instead of silently switching to host execution.
        sandboxEnabled: true,
        sandboxReadOnlyMounts: sandboxToolchain.mounts,
        sandboxPathEntries: sandboxToolchain.pathEntries
    )
    let artifactStore = ProductArtifactStore(
        config.stateRoot,
        database: Some(vnextDatabase)
    )
    let catalog = ToolCatalog()
    let uriRouter = InternalUriRouter()
    let taskRuntime = ProductTaskRuntime(
        asyncEnabled: settings.asyncEnabled,
        allowUnsafeDirectLaunchForTests: config.unsafeDirectLaunchForTests
    )
    let askRuntime = AskRuntime()
    let goalRuntime = ProductGoalRuntime(sessionMetadata, runs)
    let memoryRuntime = ProductMemoryRuntime(
        MemoryV3Repository(vnextDatabase),
        DiskManagedSkillRepository(config.settingsRoot),
        config.settingsRoot,
        workspace.rootPath()
    )
    let skillRuntime = ProductSkillRuntime(config.settingsRoot, workspace.rootPath())
    let webSearchRuntime = ProductWebSearchRuntime(
        CurlWebSearchTransport(processes),
        config.settingsRoot
    )
    let astEdits = AstEditRuntime(workspace, processes)
    let extensions = ExtensionInstaller(
        ProductExtensionOperationHost(
            workspace, processes, uriRouter, astEdits,
            webSearchRuntime: Some(webSearchRuntime)
        )
    )
    let extensionRuntime = ExtensionRuntime(
        ProductExtensionLifecycleHost(extensions, catalog)
    )
    // Validate and atomically activate compiled extensions before installing
    // product-local tools. ExtensionRuntime sorts providers by id, making the
    // resulting public tool order deterministic across startup environments.
    match (startBuiltInExtensionRuntime(extensionRuntime, true)) {
        case ExtensionRuntimeResult.Ok(_) => ()
        case ExtensionRuntimeResult.Err(error) => return Result.Err(extensionRuntimeAgentError(error))
    }
    match (installLocalToolsWithExtensions(
        catalog,
        workspace,
        processes,
        extensions,
        uriRouter: uriRouter,
        todoRepository: Some(sessionMetadata),
        taskRuntime: Some(taskRuntime),
        checkpointDatabase: Some(vnextDatabase),
        askRuntime: askRuntime,
        goalRuntime: Some(goalRuntime),
        memoryRuntime: Some(memoryRuntime),
        skillRuntime: Some(skillRuntime),
        artifactStore: Some(artifactStore),
        allowUnsafeDirectLaunchForTests: config.unsafeDirectLaunchForTests
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
    let retryControl = RetryControl()
    var fixtureProbe: ?FixtureModelPort = None
    let configuredPort: ModelPort = if (config.fixture) {
        let probe = FixtureModelPort()
        fixtureProbe = Some(probe)
        probe
    } else if (loadedProfiles.size > 0 && loadedCatalog.size > 0) {
        configuredProfileModelPort(
            loadedProfiles,
            loadedCatalog,
            config.settingsRoot
        )
    } else {
        UnconfiguredModelPort()
    }
    let effectiveModelPort: ModelPort = match (config.modelStreamFaultProfile) {
        case Some(profile) => FaultInjectingModelPort(configuredPort, profile)
        case None => configuredPort
    }
    let modelControl = ControlledModelPort(effectiveModelPort, runs: Some(runs))
    let core = AgentCore(
        modelControl,
        runs,
        pipeline,
        catalog,
        threadRuntimes: Some(threadRuntimes),
        operationRuntime: Some(DurableOperationStore(vnextDatabase)),
        modelDecisionRuntime: Some(SqliteModelDecisionStore(vnextDatabase)),
        contextManifestRuntime: Some(ProductContextManifestRuntime(vnextDatabase)),
        modelAttemptRecovery: config.modelAttemptRecovery
    )
    let service = CoreRunService(core, runs)
    let compactionSummarizer = ModelCompactionSummarizer(modelControl)
    let approvalReviewer = ApprovalReviewer(
        modelControl,
        approvalSettings,
        model,
        workspace.rootPath()
    )
    let mcpRuntime = if (config.fixture || localMaintenance) {
        emptyProductMcpRuntime()
    } else {
        match (startProductMcp(
            config.settingsRoot,
            workspace.rootPath(),
            catalog,
            extensions
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
    }
    let product = ProductRuntime(
        InProcessAgentClient(service),
        ids,
        workspace,
        model,
        config.settingsRoot,
        config.stateRoot,
        settings.asyncEnabled,
        config.wallTimeoutMillis,
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
        retryControl,
        uriRouter,
        taskRuntime,
        askRuntime,
        goalRuntime,
        memoryRuntime,
        skillRuntime,
        webSearchRuntime,
        compactionSummarizer,
        approvalReviewer,
        extensions,
        extensionRuntime,
        mcpRuntime,
        vnextDatabase,
        threadRuntimes,
        ProductVnextControl(
            vnextDatabase, catalog, pipeline, ids, threadRuntimes,
            workspace.rootPath(), processes, config.extensionSignatureVerifier
        ),
        fixtureProbe: fixtureProbe
    )
    taskRuntime.attach(product, ProductTaskPersistence(vnextDatabase))
    Result.Ok(product)
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

func openVnextDatabase(path: String): Result<SqliteDatabase> {
    try {
        Result.Ok(SqliteDatabase(path))
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

public func configuredProfileModelPort(
    profiles: Array<ProviderProfile>,
    catalog: Array<ModelCatalogEntry>,
    settingsRoot: String
): ModelPort {
    let runtimeProfiles = ArrayList<RuntimeProviderProfile>()
    for (profile in profiles) {
        runtimeProfiles.add(RuntimeProviderProfile(
            profile.id,
            profile.provider,
            profile.baseUrl,
            profile.apiKeyEnv,
            authentication: profile.authentication,
            credentialFile: credentialPath(settingsRoot, profile.id),
            timeoutMillis: profile.timeoutMillis,
            defaultHeaders: runtimeProviderHeaders(profile.defaultHeaders),
            endpointMaxOutputTokens: profile.endpointMaxOutputTokens
        ))
    }
    let runtimeModels = ArrayList<RuntimeModelDescriptor>()
    for (entry in catalog where entry.providerProfile != "") {
        match (findProviderProfile(profiles, entry.providerProfile)) {
            case Some(profile) => runtimeModels.add(RuntimeModelDescriptor(
                entry.displayId(), entry.providerProfile, entry.id,
                runtimeApiBinding(entry, profile),
                productModelCapabilities(
                    entry,
                    protocol: profile.protocol,
                    provider: profile.provider,
                    baseUrl: profile.baseUrl
                ),
                defaultHeaders: runtimeProviderHeaders(entry.defaultHeaders)
            ))
            case None => ()
        }
    }
    UnifiedModelRuntime(
        runtimeProfiles.toArray(), runtimeModels.toArray(), defaultLlmApiRegistry()
    )
}

func runtimeProviderHeaders(values: Array<ProviderDefaultHeader>): Array<ProviderHeader> {
    let headers = ArrayList<ProviderHeader>()
    for (value in values) { headers.add(ProviderHeader(value.name, value.value)) }
    headers.toArray()
}

func runtimeApiBinding(
    entry: ModelCatalogEntry,
    profile: ProviderProfile
): ModelApiBinding {
    let selectedDialect = if (entry.dialect != "") { entry.dialect } else { profile.dialect }
    let selectedApi = if (entry.apiId != "") { entry.apiId } else { match (profile.protocol) {
        case "messages" => "anthropic_messages"
        case "responses" => "openai_responses"
        case _ => "openai_chat_completions"
    } }
    match (selectedDialect) {
        case "anthropic_messages" => ModelApiBinding(
            LlmApiId.AnthropicMessages,
            TypedProviderDialect.AnthropicMessages(AnthropicMessagesDialect.Anthropic)
        )
        case "deepseek_messages" => ModelApiBinding(
            LlmApiId.AnthropicMessages,
            TypedProviderDialect.AnthropicMessages(AnthropicMessagesDialect.DeepSeek)
        )
        case "generic_messages" => ModelApiBinding(
            LlmApiId.AnthropicMessages,
            TypedProviderDialect.AnthropicMessages(AnthropicMessagesDialect.Generic)
        )
        case "openai_responses" => ModelApiBinding(
            LlmApiId.OpenAiResponses,
            TypedProviderDialect.OpenAiResponses(OpenAiResponsesDialect.OpenAi)
        )
        case "deepseek_chat" => ModelApiBinding(
            LlmApiId.OpenAiChatCompletions,
            TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.DeepSeek)
        )
        case "openai_chat" => ModelApiBinding(
            LlmApiId.OpenAiChatCompletions,
            TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.OpenAi)
        )
        case "generic_chat" => ModelApiBinding(
            LlmApiId.OpenAiChatCompletions,
            TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.Generic)
        )
        case _ => match (selectedApi) {
            // Legacy configs already carry an explicit protocol. The migration
            // selects only the generic dialect for that protocol and never
            // inspects provider names, model names, or endpoint URLs.
            case "anthropic_messages" => ModelApiBinding(
                LlmApiId.AnthropicMessages,
                TypedProviderDialect.AnthropicMessages(AnthropicMessagesDialect.Generic)
            )
            case "openai_responses" => ModelApiBinding(
                LlmApiId.OpenAiResponses,
                TypedProviderDialect.OpenAiResponses(OpenAiResponsesDialect.OpenAi)
            )
            case _ => ModelApiBinding(
                LlmApiId.OpenAiChatCompletions,
                TypedProviderDialect.OpenAiCompletions(OpenAiCompletionsDialect.Generic)
            )
        }
    }
}

func productModelCapabilities(
    entry: ModelCatalogEntry,
    protocol!: String = "",
    provider!: String = "",
    baseUrl!: String = ""
): ModelCapabilities {
    let _ = protocol
    let _ = provider
    let _ = baseUrl
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

func configuredProductModelCapabilities(
    entry: ModelCatalogEntry,
    profiles: Array<ProviderProfile>
): ModelCapabilities {
    for (profile in profiles where profile.id == entry.providerProfile) {
        return productModelCapabilities(
            entry,
            protocol: profile.protocol,
            provider: profile.provider,
            baseUrl: profile.baseUrl
        )
    }
    productModelCapabilities(entry)
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
            case Some(value) => value.kind == ValueKind.Boolean && value.boolean
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
            if (value.kind == ValueKind.Text && value.text != "") {
                value.text
            } else {
                fallback
            }
        case None => fallback
    }
}

class UnsupportedOAuthModelPort <: ModelPort {
    private let providerId: String

    init(providerId: String) {
        this.providerId = providerId
    }

    public func execute(
        _request: ModelRequest,
        _events: ModelEventSink
    ): Result<ModelReply> {
        let _ = _request
        let _ = _events
        oauthNotSupported(providerId)
    }

    public func cancel(_requestId: String): Result<Unit> {
        let _ = _requestId
        Result.Ok(())
    }
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
    objectValue([
        ValueField("workspace_root", textValue(value.workspaceRoot)),
        ValueField("cwd", textValue(value.cwd)),
        ValueField("environment", listValue(environment.toArray())),
        ValueField("services", listValue(services.toArray()))
    ])
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

class UnconfiguredModelPort <: ModelPort {
    public func execute(
        request: ModelRequest,
        events: ModelEventSink
    ): Result<ModelReply> {
        let _ = request
        let _ = events
        Result.Err(
            AgentError(
                AgentErrorKind.Configuration,
                "provider.not_configured",
                "no model provider is configured"
            )
        )
    }
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

func productToolContext(workspaceRoot: String): ToolContextDescriptor {
    ToolContextDescriptor(
        workspaceRoot: workspaceRoot,
        cwd: workspaceRoot,
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
