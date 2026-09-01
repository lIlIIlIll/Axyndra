package agent_product

import yjson_support.*

import yjson.*

import agent_cli.*
import agent_core.*
import agent_domain.*
import agent_extensions.*
import persistence_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*

public enum ApplicationAction {
    NoAction
    | OpenProviderSetup
    | OpenModelSelector
    | OpenBranchSelector
}

public enum PlanApprovalOutcome {
    NotConsumed(AgentError)
    | Consumed(Result<ApplicationResponse>)
}

// Plan approval and approved-plan execution are two distinct lifecycle
// boundaries.  Consumers use this signal to retire an already-consumed
// review before the (potentially long-running) execution request finishes.
public type PlanApprovalConsumedSink = (String) -> Unit

public class ApplicationResponse {
    public let agentInvoked: Bool
    public let exitRequested: Bool
    public let text: String
    public let snapshot: ?RunSnapshot
    public let approval: ?ApprovalRequest
    public let action: ApplicationAction
    public let planReview: ?String

    public init(
        agentInvoked: Bool,
        exitRequested!: Bool = false,
        text!: String = "",
        snapshot!: ?RunSnapshot = None,
        approval!: ?ApprovalRequest = None,
        action!: ApplicationAction = ApplicationAction.NoAction,
        planReview!: ?String = None
    ) {
        this.agentInvoked = agentInvoked
        this.exitRequested = exitRequested
        this.text = text
        this.snapshot = snapshot
        this.approval = approval
        this.action = action
        this.planReview = planReview
    }
}

public class QueuedInteraction {
    public let correlationId: String
    public let kind: String
    public let input: String
    public let durableItemId: String

    public init(
        correlationId: String,
        kind: String,
        input: String,
        durableItemId: String
    ) {
        this.correlationId = correlationId
        this.kind = kind
        this.input = input
        this.durableItemId = durableItemId
    }
}

public enum QueuedWithdrawal {
    | Withdrawn(QueuedInteraction)
    | AlreadyDelivered
}

public class ApplicationBranchMessage {
    public let entryId: String
    public let text: String

    public init(entryId: String, text: String) {
        this.entryId = entryId
        this.text = text
    }
}

public class ApplicationBranchResult {
    public let sessionId: SessionId
    public let text: String

    public init(sessionId: SessionId, text: String) {
        this.sessionId = sessionId
        this.text = text
    }
}

public class ApplicationHandoffResult {
    public let sessionId: SessionId
    public let document: String

    public init(sessionId: SessionId, document: String) {
        this.sessionId = sessionId
        this.document = document
    }
}

public class ApplicationSession <: AgentInteractionSource {
    private let product: ProductRuntime
    private let router = CommandRouter()
    private let lock = Mutex()
    private let subscribers = ArrayList<AgentEventSink>()
    private let queuedInteractions = ArrayList<QueuedInteraction>()
    private var sessionId: SessionId
    private var currentModel: String
    private var currentThinking = ThinkingLevel.Medium
    private var thinkingExplicit = false

    // Plan mode raises the model default by two levels, with High as the floor.
    // An explicit user choice always has precedence.
    private func effectiveThinking(): ThinkingLevel {
        if (!planModeEnabled || thinkingExplicit) {
            return currentThinking
        }
        planModeThinking(currentThinking)
    }

    private func requestedThinkingSource(): ThinkingPreferenceSource {
        if (thinkingExplicit) {
            ThinkingPreferenceSource.ExplicitUser
        } else if (planModeEnabled) {
            ThinkingPreferenceSource.ModePreference
        } else {
            ThinkingPreferenceSource.ModelDefault
        }
    }

    private func explicitRequestedThinking(): ?ThinkingLevel {
        if (thinkingExplicit) { Some(currentThinking) } else { None }
    }
    private var steeringDelivery = QueueDeliveryMode.OneAtATime
    private var followUpDelivery = QueueDeliveryMode.OneAtATime
    private var currentInterruptMode = RunInterruptMode.Immediate
    private var autoCompaction = true
    private var compacting = false
    private var theme = "axyndra"
    private var currentRequest: ?AgentRunRequest = None
    private var pendingApproval: ?ApprovalRequest = None
    private var pendingRecovery: ?AgentError = None
    private var pendingModelResume = false
    private let recentApprovalDenials = ArrayList<String>()
    private var currentBashOperation: ?OperationId = None
    private var askInteractive = false
    private var planModeEnabled = false
    private var planWriteBaseline: Int64 = 0
    private var planCorrectionAttempted = false
    private var vibeModeEnabled = false
    private var loopModeEnabled = false
    private var loopPrompt = ""
    private var loopRemaining: Int64 = -1
    private var loopDeadlineMillis: Int64 = 0

    public init(product: ProductRuntime, sessionId!: ?SessionId = None) {
        this.product = product
        this.theme = product.theme
        this.autoCompaction = product.compactionEnabled()
        this.sessionId = match (sessionId) {
            case Some(value) => value
            case None => product.ids.nextSessionId()
        }
        var migrateModel = false
        this.currentModel = match (product.sessionModel(this.sessionId)) {
            case Result.Ok(value) =>
                if (value == "") {
                    migrateModel = true
                    product.model
                } else {
                    value
                }
            case Result.Err(error) =>
                pendingRecovery = Some(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "session.model_metadata_recovery_failed",
                    error.message,
                    fields: [ErrorField("session_id", this.sessionId.value)]
                ))
                product.model
        }
        // Older sessions have no model metadata. Persisting the resolved
        // default here migrates them lazily without a separate schema pass.
        if (migrateModel) {
            let _ = product.setSessionModel(this.sessionId, this.currentModel)
        }
        let _ = product.pauseRestoredGoal(this.sessionId)
        restoreWorkMode(this.sessionId)
        restoreQueuedInteractions()
        restorePendingContinuation()
    }

    private func restoreQueuedInteractions(): Unit {
        match (product.vnext.pendingLaneInputs(ThreadId(sessionId.value))) {
            case Result.Ok(entries) =>
                for (entry in entries) {
                    let correlation = applicationInboxText(
                        entry.payload, "correlation_id"
                    )
                    let kind = applicationInboxText(entry.payload, "kind")
                    let text = applicationInboxText(entry.payload, "text")
                    if (correlation != "" && kind != "" && text != "") {
                        queuedInteractions.add(QueuedInteraction(
                            correlation, kind, text, entry.id.value
                        ))
                    } else {
                        pendingRecovery = Some(AgentError(
                            AgentErrorKind.RecoveryRequired,
                            "inbox.queued_payload_corrupt",
                            "durable queued interaction is missing required fields",
                            fields: [
                                ErrorField("session_id", sessionId.value),
                                ErrorField("inbox_entry_id", entry.id.value)
                            ]
                        ))
                        return
                    }
                }
            case Result.Err(error) => pendingRecovery = Some(AgentError(
                AgentErrorKind.RecoveryRequired,
                "inbox.queued_restore_failed",
                error.message,
                fields: [ErrorField("session_id", sessionId.value)]
            ))
        }
    }

    private func restorePendingContinuation(): Unit {
        currentRequest = None
        pendingApproval = None
        pendingModelResume = false
        let approvalContinuation: ?RunContinuation = match (product.pendingContinuation(sessionId)) {
            case Result.Ok(Some(value)) =>
                Some(value)
            case Result.Ok(None) => None
            case Result.Err(error) => pendingRecovery = Some(error); None
        }
        let modelContinuation: ?RunContinuation = match (product.pendingRecoveryContinuation(sessionId)) {
            case Result.Ok(Some(value)) => Some(value)
            case Result.Ok(None) => None
            case Result.Err(error) => pendingRecovery = Some(error); None
        }
        if (approvalContinuation.isSome() && modelContinuation.isSome()) {
            pendingRecovery = Some(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.pending_continuation_conflict",
                "session has both approval and model execution continuations"
            ))
            return
        }
        match (approvalContinuation) {
            case Some(value) =>
                currentRequest = Some(product.continuationRequest(value, Some(this)))
                pendingApproval = Some(value.approval)
                currentModel = value.model
            case None => match (modelContinuation) {
                case Some(value) =>
                    currentRequest = Some(product.continuationRequest(value, Some(this)))
                    pendingModelResume = true
                    currentModel = value.model
                case None => ()
            }
        }
    }

    // Must be called by every interactive surface before accepting new input.
    // The method is idempotent: after one successful resume there is no pending
    // model checkpoint left to dispatch again.
    public func resumeStartup(): Result<?ApplicationResponse> {
        match (pendingRecovery) {
            case Some(error) => return Result.Err(error)
            case None => ()
        }
        if (!pendingModelResume) { return Result.Ok(None) }
        let request = match (currentRequest) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.startup_resume_request_missing",
                "startup model continuation has no reconstructed request"
            ))
        }
        match (product.client.resume(request, eventSink())) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                currentRequest = None
                pendingModelResume = false
                match (finishCompletedRun(snapshot, false)) {
                    case Result.Ok(value) => Result.Ok(Some(value))
                    case Result.Err(error) => Result.Err(error)
                }
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, approval)) =>
                pendingModelResume = false
                match (settleApproval(request, snapshot, approval, false)) {
                    case Result.Ok(value) => Result.Ok(Some(value))
                    case Result.Err(error) => Result.Err(error)
                }
            case Result.Err(error) =>
                pendingRecovery = Some(error)
                Result.Err(error)
        }
    }

    public func id(): SessionId {
        sessionId
    }

    public func model(): String {
        currentModel
    }

    public func activeRunId(): String {
        lock.lock()
        try {
            match (currentRequest) {
                case Some(value) => value.runId.value
                case None => ""
            }
        } finally {
            lock.unlock()
        }
    }

    public func fastModeEnabled(): Bool {
        product.fastModeEnabled(sessionId)
    }

    public func fastModeActive(): Bool {
        product.fastModeActive(sessionId, currentModel)
    }

    public func setFastMode(enabled: Bool): Result<Bool> {
        product.setFastMode(sessionId, currentModel, enabled)
    }

    public func contextUsage(): ProductContextUsage {
        product.contextUsage(sessionId, currentModel)
    }

    public func currentTheme(): String {
        theme
    }

    public func themes(): Result<Array<ProductThemeDefinition>> {
        loadProductThemes(product.settingsRoot)
    }

    public func thinking(): ThinkingLevel {
        currentThinking
    }

    public func setThinking(value: ThinkingLevel): Unit {
        currentThinking = value
        thinkingExplicit = true
    }

    public func models(): Array<String> {
        product.models()
    }

    public func modelEntries(): Array<ModelCatalogEntry> {
        product.modelEntries()
    }

    public func modelMetadata(modelId: String): ?ModelCatalogEntry {
        product.modelMetadata(modelId)
    }

    public func providers(): Array<ProviderProfile> {
        product.providers()
    }

    public func modelProvider(modelId: String): String {
        product.modelProvider(modelId)
    }

    public func rawModelId(modelId: String): String {
        product.rawModelId(modelId)
    }

    public func resolveModel(
        provider: String,
        modelId: String
    ): Result<String> {
        product.resolveModel(provider, modelId)
    }

    public func providerAvailable(profileId: String): Bool {
        product.providerAvailable(profileId)
    }

    public func providerAuthenticated(profileId: String): Bool {
        product.providerAuthenticated(profileId)
    }

    public func tools(): Array<ModelToolDefinition> {
        product.tools()
    }

    public func activeTools(): Array<ModelToolDefinition> {
        if (planModeEnabled || vibeModeEnabled) {
            product.toolsFor(CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]))
        } else {
            product.tools()
        }
    }

    public func workMode(): String {
        if (planModeEnabled) {
            "plan"
        } else if (vibeModeEnabled) {
            "vibe"
        } else {
            "none"
        }
    }

    public func loopEnabled(): Bool {
        loopModeEnabled
    }

    public func configRoot(): String {
        product.settingsRoot
    }

    public func stateRoot(): String {
        product.stateRoot
    }

    public func workspaceRoot(): String {
        product.workspace.rootPath()
    }

    public func bundledAgents(): Array<ProductBundledAgentDefinition> {
        bundledProductAgents()
    }

    public func invokeLocalTool(
        name: String,
        arguments: AgentValue
    ): Result<ToolResult> {
        product.invokeLocalTool(sessionId, name, arguments)
    }

    public func registerTool(
        descriptor: ToolDescriptor,
        executor: ToolExecutor
    ): Result<Unit> {
        product.registerTool(descriptor, executor)
    }

    public func unregisterTool(name: String): Bool {
        product.unregisterTool(name)
    }

    public func registerUriHandler(
        scheme: String,
        handler: InternalUriHandler
    ): Result<Unit> {
        product.registerUriHandler(scheme, handler)
    }

    public func unregisterUriScheme(scheme: String): Bool {
        product.unregisterUriScheme(scheme)
    }

    public func uriSchemes(): Array<String> {
        product.uriSchemes()
    }

    public func extensions(): Array<ExtensionSnapshot> {
        product.extensionSnapshots()
    }

    public func mcpServers(): Array<ProductMcpServerSnapshot> {
        product.mcpSnapshots()
    }

    public func setExtensionEnabled(
        extensionId: String,
        enabled: Bool
    ): Result<Unit> {
        product.setExtensionEnabled(extensionId, enabled)
    }

    public func setAskInteractive(enabled: Bool): Unit {
        askInteractive = enabled
        product.setAskInteractive(sessionId, enabled)
    }

    public func subscribeAsks(sink: ProductAskEventSink): Unit {
        product.subscribeAsks({
            request => if (request.sessionId.value == sessionId.value) {
                sink(request)
            }
        })
    }

    public func pendingAsk(): ?ProductAskRequest {
        product.pendingAsk(sessionId)
    }

    public func answerAsk(
        requestId: String,
        resolution: ProductAskResolution
    ): Result<Unit> {
        product.answerAsk(sessionId, requestId, resolution)
    }

    public func subagents(): Array<ProductSubagentSnapshot> {
        product.subagents(sessionId)
    }

    public func allSubagents(): Array<ProductSubagentSnapshot> {
        product.allSubagents(sessionId)
    }

    public func asyncJobs(): Array<ProductAsyncJobSnapshot> {
        product.asyncJobs(sessionId)
    }

    public func waitForAsyncJobs(
        ids: Array<String>,
        timeoutMillis!: Int64 = 30000
    ): Array<ProductAsyncJobSnapshot> {
        product.waitForAsyncJobs(
            sessionId,
            ids,
            timeoutMillis
        )
    }

    public func cancelAsyncJobs(ids: Array<String>): Array<ProductAsyncJobSnapshot> {
        product.cancelAsyncJobs(sessionId, ids)
    }

    public func subagentTranscript(
        subagentId!: String = "",
        sessionRef!: String = "",
        fromItem!: Int64 = 0
    ): Result<ProductSubagentTranscript> {
        product.subagentTranscript(
            sessionId,
            subagentId: subagentId,
            sessionRef: sessionRef,
            fromItem: fromItem
        )
    }

    public func messageSubagent(
        subagentId: String,
        message: String
    ): Result<Unit> {
        product.messageSubagent(sessionId, subagentId, message)
    }

    public func cancelSubagent(subagentId: String): Result<Unit> {
        product.cancelSubagent(sessionId, subagentId)
    }

    public func subscribeSubagents(sink: ProductSubagentEventSink): Int64 {
        product.subscribeSubagents(sink)
    }

    public func subscribeAsyncJobs(sink: ProductAsyncJobEventSink): Int64 {
        product.subscribeAsyncJobs(sink)
    }

    public func providerId(): String {
        product.providerIdForModel(currentModel)
    }

    public func messages(): Result<Array<ModelMessage>> {
        product.messages(sessionId)
    }

    public func sessionRef(): String {
        product.sessionReference(sessionId)
    }

    public func name(): Result<String> {
        product.sessionName(sessionId)
    }

    public func draft(): Result<String> {
        product.sessionDraft(sessionId)
    }

    public func setDraft(value: String): Result<Unit> {
        product.setSessionDraft(sessionId, value)
    }

    public func setName(value: String): Result<Unit> {
        product.setSessionName(sessionId, value)
    }

    public func parentSession(): Result<String> {
        product.sessionParent(sessionId)
    }

    public func loginProvider(profileId: String): Result<String> {
        product.login(profileId: profileId)
    }

    public func todoPhases(): Result<Array<TodoPhase>> {
        product.todoPhases(sessionId)
    }

    public func setTodoPhases(phases: Array<TodoPhase>): Result<Unit> {
        product.setTodoPhases(sessionId, phases)
    }

    public func runStats(): Result<SessionRunStats> {
        product.sessionRunStats(sessionId)
    }

    public func managedWorktrees(): Result<Array<ProductWorktreeEntry>> {
        product.managedWorktrees()
    }

    public func clearManagedWorktrees(
        all: Bool,
        dryRun: Bool
    ): Result<ProductWorktreeClearResult> {
        product.clearManagedWorktrees(all, dryRun)
    }

    public func garbageCollect(options: ProductGcOptions): Result<ProductGcResult> {
        product.garbageCollect(options)
    }

    public func dashboardStats(): Result<ProductDashboardStats> {
        product.dashboardStats()
    }

    public func listGrievances(
        limit: Int64,
        tool: String
    ): Result<ProductGrievanceList> {
        product.listGrievances(limit, tool)
    }

    public func cleanGrievances(
        id: ?Int64,
        tool: String,
        all: Bool
    ): Result<ProductGrievanceClean> {
        product.cleanGrievances(id, tool, all)
    }

    public func listSshHosts(): Result<ProductSshHosts> {
        product.listSshHosts()
    }

    public func addSshHost(
        scope: String,
        host: ProductSshHost
    ): Result<Unit> {
        product.addSshHost(scope, host)
    }

    public func removeSshHost(
        scope: String,
        name: String
    ): Result<Unit> {
        product.removeSshHost(scope, name)
    }

    public func searchWeb(
        query: String,
        provider: String,
        recency: String,
        limit: ?Int64
    ): Result<ToolResult> {
        product.searchWeb(
            sessionId,
            query,
            provider,
            recency,
            limit
        )
    }

    public func setAutoRetry(enabled: Bool): Unit {
        product.setAutoRetry(enabled)
    }

    public func autoRetryEnabled(): Bool {
        product.autoRetryEnabled()
    }

    public func abortRetry(): Unit {
        match (currentRequest) {
            case Some(request) => product.abortRetry(request.runId.value)
            case None => ()
        }
    }

    public func setAutoCompaction(enabled: Bool): Unit {
        autoCompaction = enabled
    }

    public func autoCompactionEnabled(): Bool {
        autoCompaction
    }

    public func isCompacting(): Bool {
        lock.lock()
        try {
            compacting
        } finally {
            lock.unlock()
        }
    }

    public func selectModel(value: String): Result<Unit> {
        if (value.trimAscii() == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "application.model_empty",
                    "model id must not be empty"
                )
            )
        }
        match (product.setSessionModel(sessionId, value)) {
            case Result.Ok(_) =>
                currentModel = value
                Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func switchSession(value: SessionId): Result<Unit> {
        if (currentRequest.isSome() || pendingApproval.isSome()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.session_busy",
                    "cannot switch sessions while an operation is active"
                )
            )
        }
        let restored = match (product.sessionModel(value)) {
            case Result.Ok(model) =>
                if (model == "") {
                    product.model
                } else {
                    model
                }
            case Result.Err(error) => return Result.Err(error)
        }
        if (restored == product.model) {
            match (product.setSessionModel(value, restored)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        match (product.pauseGoal(sessionId)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (product.pauseRestoredGoal(value)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        moveAskSurface(sessionId, value)
        sessionId = value
        currentModel = restored
        restoreWorkMode(value)
        restorePendingContinuation()
        disableLoop()
        Result.Ok(())
    }

    public func forkCurrent(): Result<SessionId> {
        let target = product.ids.nextSessionId()
        match (product.forkSession(sessionId, target)) {
            case Result.Ok(_) => match (product.setSessionModel(target, currentModel)) {
                case Result.Ok(_) =>
                    moveAskSurface(sessionId, target)
                    sessionId = target
                    restoreWorkMode(target)
                    Result.Ok(target)
                case Result.Err(error) => Result.Err(error)
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func branchMessages(): Result<Array<ApplicationBranchMessage>> {
        let messages = match (product.messages(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let values = ArrayList<ApplicationBranchMessage>()
        for (index in 0..messages.size) {
            let message = messages[index]
            if (message.role != ModelRole.User) {
                continue
            }
            let text = userMessageText(message)
            if (text == "") {
                continue
            }
            values.add(
                ApplicationBranchMessage(
                    branchEntryId(sessionId, index, messages.size),
                    text
                )
            )
        }
        Result.Ok(values.toArray())
    }

    public func branchAt(entryId: String): Result<ApplicationBranchResult> {
        if (currentRequest.isSome() || pendingApproval.isSome()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.session_busy",
                    "cannot branch while an operation is active"
                )
            )
        }
        let messages = match (product.messages(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let selected = parseBranchEntryId(
            entryId,
            sessionId,
            messages.size
        )
        let index = match (selected) {
            case Some(value) => value
            case None => return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "session.branch_entry_invalid",
                    "Invalid entry ID for branching"
                )
            )
        }
        if (index < 0 || index >= messages.size || messages[index].role != ModelRole.User) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "session.branch_entry_invalid",
                    "Invalid entry ID for branching"
                )
            )
        }
        let text = userMessageText(messages[index])
        if (text == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "session.branch_entry_invalid",
                    "Invalid entry ID for branching"
                )
            )
        }
        let prefix = ArrayList<ModelMessage>()
        for (position in 0..index) {
            prefix.add(messages[position])
        }
        let target = product.ids.nextSessionId()
        match (product.branchSession(
            sessionId,
            target,
            prefix.toArray()
        )) {
            case Result.Ok(_) =>
                moveAskSurface(sessionId, target)
                sessionId = target
                restoreWorkMode(target)
                currentRequest = None
                pendingApproval = None
                clearQueued()
                Result.Ok(ApplicationBranchResult(target, text))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func handoff(customInstructions!: String = ""): Result<ApplicationHandoffResult> {
        if (currentRequest.isSome() || pendingApproval.isSome()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.session_busy",
                    "Cannot hand off while a response is in progress"
                )
            )
        }
        let sourceSession = sessionId
        let sourceMessages = match (product.messages(sourceSession)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (sourceMessages.size < 2) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "session.handoff_empty",
                    "Nothing to hand off (no messages yet)"
                )
            )
        }

        let temporary = product.ids.nextSessionId()
        match (product.replaceMessages(temporary, sourceMessages)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let prompt = handoffPrompt(customInstructions)
        let base = product.request(
            prompt,
            sessionId: Some(temporary),
            modelOverride: currentModel,
            thinking: effectiveThinking(),
            userRequestedThinking: explicitRequestedThinking(),
            thinkingSource: requestedThinkingSource()
        )
        let request = handoffRunRequest(base)
        currentRequest = Some(request)
        let outcome = try {
            product.client.start(request, eventSink())
        } finally {
            currentRequest = None
        }
        let document = match (outcome) {
            case Result.Ok(AgentRunOutcome.Completed(_)) => match (product.messages(temporary)) {
                case Result.Ok(messages) => lastAssistantText(messages)
                case Result.Err(error) =>
                    let _ = product.removeConversation(temporary)
                    return Result.Err(error)
            }
            case Result.Ok(AgentRunOutcome.AwaitingApproval(_, _)) =>
                let _ = product.removeConversation(temporary)
                return Result.Err(
                    AgentError(
                        AgentErrorKind.Conflict,
                        "session.handoff_tool_call",
                        "handoff generation attempted to call a tool"
                    )
                )
            case Result.Err(error) =>
                let _ = product.removeConversation(temporary)
                return Result.Err(error)
        }
        let _ = product.removeConversation(temporary)
        if (document.trimAscii() == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Provider,
                    "session.handoff_empty_response",
                    "handoff generation returned no text"
                )
            )
        }

        let target = product.ids.nextSessionId()
        match (product.setSessionParent(
            target,
            product.sessionReference(sourceSession)
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (product.setSessionModel(target, currentModel)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (product.replaceMessages(
            target,
            [
                ModelMessage(
                    ModelRole.User,
                    [
                        ModelBlock(
                            ModelBlockKind.Text,
                            text: handoffContext(document)
                        )
                    ]
                )
            ]
        )) {
            case Result.Ok(_) =>
                moveAskSurface(sessionId, target)
                sessionId = target
                restoreWorkMode(target)
                pendingApproval = None
                Result.Ok(ApplicationHandoffResult(target, document))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func executeBash(command: String): Result<ProcessResult> {
        if (command.trimAscii() == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "application.bash_empty",
                    "bash command must not be empty"
                )
            )
        }
        let operationId = product.ids.nextOperationId()
        currentBashOperation = Some(operationId)
        let result = product.executeBash(command, operationId)
        currentBashOperation = None
        result
    }

    public func abortBash(): Result<Unit> {
        match (currentBashOperation) {
            case Some(operationId) => product.abortBash(operationId)
            case None => Result.Ok(())
        }
    }

    public func exportHtml(outputPath: String): Result<String> {
        product.exportSessionHtml(sessionId, outputPath)
    }

    public func formatSessionDump(): Result<String> {
        product.formatSessionDump(
            sessionId,
            currentModel,
            currentThinking
        )
    }

    public func dumpLlmRequest(): Result<String> {
        product.dumpLlmRequest(
            sessionId,
            currentModel,
            effectiveThinking(),
            modeSystem: activeModeSystem(),
            guide: capabilityGuide(),
            readOnly: planModeEnabled || vibeModeEnabled,
            workMode: workMode()
        )
    }

    public func todoMarkdown(): Result<String> {
        todoMarkdownForSession(product, sessionId)
    }

    public func replaceTodoMarkdown(markdown: String): Result<String> {
        replaceTodoMarkdownForSession(product, sessionId, markdown)
    }

    public func approval(): ?ApprovalRequest {
        pendingApproval
    }

    public func subscribe(sink: AgentEventSink): Unit {
        lock.lock()
        try {
            subscribers.add(sink)
        } finally {
            lock.unlock()
        }
    }

    public func enqueue(
        correlationId: String,
        kind: String,
        input: String
    ): Result<Unit> {
        let prompt = input.trimAscii()
        if (prompt == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "application.empty_queued_input",
                    "queued input must not be empty"
                )
            )
        }
        let effectiveCorrelation = if (correlationId == "") {
            "queued-" + product.ids.nextOperationId().value
        } else {
            correlationId
        }
        lock.lock()
        try {
            for (queued in queuedInteractions where
                queued.correlationId == effectiveCorrelation) {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.Conflict,
                        "application.duplicate_queue_correlation_id",
                        "queued input correlation id must be unique"
                    )
                )
            }
            let durableItemId = applicationInboxEntryId(
                sessionId, LaneId("main"), effectiveCorrelation
            )
            match (product.vnext.enqueueLaneInput(DurableInboxEntry(
                InboxEntryId(durableItemId),
                ThreadId(sessionId.value), LaneId("main"),
                applicationInboxKind(kind),
                objectValue([
                    ValueField("correlation_id", textValue(effectiveCorrelation)),
                    ValueField("kind", textValue(kind)),
                    ValueField("text", textValue(prompt))
                ]),
                createdAtMillis: agentUtcMillis()
            ))) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            queuedInteractions.add(
                QueuedInteraction(
                    effectiveCorrelation,
                    kind,
                    prompt,
                    durableItemId
                )
            )
            Result.Ok(())
        } finally {
            lock.unlock()
        }
    }

    public func withdrawQueued(correlationId: String): Result<QueuedWithdrawal> {
        if (correlationId == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "application.empty_queue_correlation_id",
                    "queued input correlation id must not be empty"
                )
            )
        }
        lock.lock()
        try {
            for (index in 0..queuedInteractions.size) {
                let queued = queuedInteractions[index]
                if (queued.correlationId == correlationId) {
                    match (product.vnext.rejectLaneInput(
                        InboxEntryId(applicationInboxEntryId(
                            sessionId, LaneId("main"), correlationId
                        ))
                    )) {
                        case Result.Ok(_) =>
                            queuedInteractions.remove(at: index)
                            return Result.Ok(QueuedWithdrawal.Withdrawn(queued))
                        case Result.Err(_) =>
                            return Result.Ok(QueuedWithdrawal.AlreadyDelivered)
                    }
                }
            }
            Result.Ok(QueuedWithdrawal.AlreadyDelivered)
        } finally {
            lock.unlock()
        }
    }

    public func setSteeringMode(value: QueueDeliveryMode): Unit {
        lock.lock()
        try {
            steeringDelivery = value
        } finally {
            lock.unlock()
        }
    }

    public func steeringMode(): QueueDeliveryMode {
        lock.lock()
        try {
            steeringDelivery
        } finally {
            lock.unlock()
        }
    }

    public func setFollowUpMode(value: QueueDeliveryMode): Unit {
        lock.lock()
        try {
            followUpDelivery = value
        } finally {
            lock.unlock()
        }
    }

    public func followUpMode(): QueueDeliveryMode {
        lock.lock()
        try {
            followUpDelivery
        } finally {
            lock.unlock()
        }
    }

    public func setInterruptMode(value: RunInterruptMode): Unit {
        lock.lock()
        try {
            currentInterruptMode = value
        } finally {
            lock.unlock()
        }
    }

    public func interruptMode(): RunInterruptMode {
        lock.lock()
        try {
            currentInterruptMode
        } finally {
            lock.unlock()
        }
    }

    public func takeSteering(): Array<AgentQueuedInput> {
        takeAgentInputs("steer", steeringMode())
    }

    public func hasSteering(): Bool {
        lock.lock()
        try {
            for (value in queuedInteractions where value.kind == "steer") {
                return true
            }
            false
        } finally {
            lock.unlock()
        }
    }

    public func takeFollowUps(): Array<AgentQueuedInput> {
        takeAgentInputs("follow_up", followUpMode())
    }

    public func nextQueued(): ?QueuedInteraction {
        lock.lock()
        try {
            for (index in 0..queuedInteractions.size) {
                let next = queuedInteractions[index]
                if (next.kind != "steer" && next.kind != "follow_up") {
                    queuedInteractions.remove(at: index)
                    return Some(next)
                }
            }
            None
        } finally {
            lock.unlock()
        }
    }

    public func takeQueuedAtSafeBoundary(result: Result<ApplicationResponse>): ?QueuedInteraction {
        match (result) {
            case Result.Ok(response) =>
                if (response.approval.isSome()) {
                    return None
                }
            case Result.Err(_) => ()
        }
        nextQueued()
    }

    public func queuedCount(): Int64 {
        lock.lock()
        try {
            queuedInteractions.size
        } finally {
            lock.unlock()
        }
    }

    public func clearQueued(): Unit {
        lock.lock()
        try {
            queuedInteractions.clear()
        } finally {
            lock.unlock()
        }
    }

    public func handle(input: String): Result<ApplicationResponse> {
        match (router.route(input)) {
            case Result.Ok(RoutedInput.Prompt(prompt)) => if (planModeEnabled && isPlanApprovalPhrase(prompt)) {
                flattenPlanApprovalOutcome(
                    approveLatestPlanInternal("", "", "natural-language", true)
                )
            } else {
                submit(prompt)
            }
            case Result.Ok(RoutedInput.Command(command)) => execute(command)
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func approveLatestPlan(
        expectedHash!: String = "",
        feedback!: String = "",
        contextMode!: String = "keep"
    ): Result<ApplicationResponse> {
        flattenPlanApprovalOutcome(
            approveLatestPlanInternal(
                expectedHash,
                feedback,
                "plan-review",
                false,
                contextMode: contextMode
            )
        )
    }

    public func approveLatestPlanForReview(
        expectedHash!: String = "",
        feedback!: String = "",
        contextMode!: String = "keep",
        onConsumed!: ?PlanApprovalConsumedSink = None
    ): PlanApprovalOutcome {
        approveLatestPlanInternal(
            expectedHash,
            feedback,
            "plan-review",
            false,
            contextMode: contextMode,
            onConsumed: onConsumed
        )
    }

    private func flattenPlanApprovalOutcome(outcome: PlanApprovalOutcome): Result<ApplicationResponse> {
        match (outcome) {
            case PlanApprovalOutcome.NotConsumed(error) => Result.Err(error)
            case PlanApprovalOutcome.Consumed(result) => result
        }
    }

    private func approveLatestPlanInternal(
        expectedHash: String,
        feedback: String,
        source: String,
        requireStructured: Bool,
        contextMode!: String = "keep",
        onConsumed!: ?PlanApprovalConsumedSink = None
    ): PlanApprovalOutcome {
        if (pendingApproval.isSome()) {
            return PlanApprovalOutcome.NotConsumed(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.approval_pending",
                    "resolve the pending approval before approving a plan"
                )
            )
        }
        if (!planModeEnabled) {
            return PlanApprovalOutcome.NotConsumed(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.plan_mode_inactive",
                    "Plan mode is not active."
                )
            )
        }
        let review = match (latestPlanReview(requireStructured)) {
            case Result.Ok(Some(value)) => value
            case Result.Ok(None) => return PlanApprovalOutcome.NotConsumed(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.plan_approval_missing",
                    "No structured plan is available for approval."
                )
            )
            case Result.Err(error) => return PlanApprovalOutcome.NotConsumed(error)
        }
        let actualHash = planReviewHash(review)
        if (expectedHash != "" && expectedHash != actualHash) {
            return PlanApprovalOutcome.NotConsumed(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.plan_changed",
                    "plan changed since review opened; reopen /plan-review",
                    fields: [ErrorField("current_hash", actualHash)]
                )
            )
        }
        let mode = contextMode.trimAscii().toAsciiLower()
        if (mode != "fresh" && mode != "compact" && mode != "keep") {
            return PlanApprovalOutcome.NotConsumed(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "application.plan_context_mode_invalid",
                    "plan execution context must be fresh, compact, or keep",
                    fields: [ErrorField("context_mode", contextMode)]
                )
            )
        }
        match (setWorkMode("")) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return PlanApprovalOutcome.NotConsumed(error)
        }
        // From this point the reviewed plan cannot be retried: Plan mode has
        // been consumed even if context preparation or execution later fails.
        // Surface that boundary before doing either potentially slow step.
        match (onConsumed) {
            case Some(sink) => sink(actualHash)
            case None => ()
        }
        if (mode == "fresh") {
            match (startFreshPlanExecutionSession()) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return PlanApprovalOutcome.Consumed(Result.Err(error))
            }
        } else if (mode == "compact") {
            match (runCompaction(true)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return PlanApprovalOutcome.Consumed(Result.Err(error))
            }
        }
        let note = feedback.trimAscii()
        PlanApprovalOutcome.Consumed(
            submit(
                "[plan-review approved hash=" + actualHash + " source=" + source + "] " +
                    "Execute the approved plan now.\n\n<approved-plan>\n" + stripPlanReviewPrefix(review) +
                    "\n</approved-plan>" + if (note == "") {
                        ""
                    } else {
                        "\n\nReviewer note: " + note
                    }
            )
        )
    }

    private func startFreshPlanExecutionSession(): Result<Unit> {
        let source = sessionId
        let target = product.ids.nextSessionId()
        match (product.setSessionParent(target, product.sessionReference(source))) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (product.setSessionModel(target, currentModel)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        moveAskSurface(source, target)
        sessionId = target
        currentRequest = None
        pendingApproval = None
        clearQueued()
        planModeEnabled = false
        vibeModeEnabled = false
        disableLoop()
        Result.Ok(())
    }

    public func updateLatestPlan(
        expectedHash: String,
        content: String
    ): Result<String> {
        if (!planModeEnabled) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.plan_mode_inactive",
                    "Plan mode is not active."
                )
            )
        }
        if (currentRequest.isSome() || pendingApproval.isSome()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.session_busy",
                    "wait for the active turn before editing the plan"
                )
            )
        }
        let updatedContent = content.trimAscii()
        if (updatedContent == "") {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "application.plan_empty",
                    "the reviewed plan must not be empty"
                )
            )
        }
        let values = match (messages()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var targetIndex: Int64 = -1
        var index = values.size
        while (index > 0) {
            index -= 1
            if (planWriteContent(values[index]) != "") {
                targetIndex = index
                break
            }
        }
        if (targetIndex < 0) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.plan_approval_missing",
                    "No structured plan is available for editing."
                )
            )
        }
        let current = "Latest plan:\n\n" + planWriteContent(values[targetIndex])
        if (expectedHash != "" && planReviewHash(current) != expectedHash) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.plan_changed",
                    "plan changed since review opened; reopen /plan-review"
                )
            )
        }
        // This is a user-authorized semantic edit, not a model ToolCall. Commit
        // it through the Thread owner as external user input rather than
        // fabricating an Operation that never executed.
        let receiptId = "plan-review-edit-" + product.ids.nextOperationId().value
        match (product.appendExternalMessageOnce(
            sessionId,
            receiptId,
            ModelMessage(ModelRole.User, [ModelBlock(
                ModelBlockKind.Text,
                text: planReviewEditText(updatedContent)
            )]),
            source: "plan_review"
        )) {
            case Result.Ok(_) => Result.Ok("Latest plan:\n\n" + updatedContent)
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func submit(prompt: String): Result<ApplicationResponse> {
        match (pendingRecovery) {
            case Some(error) => return Result.Err(error)
            case None => ()
        }
        if (pendingModelResume) {
            return match (resumeStartup()) {
                case Result.Ok(Some(value)) => Result.Ok(value)
                case Result.Ok(None) => Result.Err(AgentError(
                    AgentErrorKind.RecoveryRequired,
                    "run.startup_resume_incomplete",
                    "startup recovery completed without an application response"
                ))
                case Result.Err(error) => Result.Err(error)
            }
        }
        if (pendingApproval.isSome()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.approval_pending",
                    "resolve the pending approval before starting another turn"
                )
            )
        }
        let normalizedPrompt = prompt.trimAscii()
        if (loopModeEnabled && loopPrompt == "") {
            loopPrompt = normalizedPrompt
        }
        if (loopModeEnabled && loopPrompt == normalizedPrompt && loopRemaining > 0) {
            loopRemaining -= 1
        }
        planWriteBaseline = if (planModeEnabled) {
            match (product.messages(sessionId)) {
                case Result.Ok(values) => planWriteCount(values)
                case Result.Err(error) => return Result.Err(error)
            }
        } else {
            0
        }
        planCorrectionAttempted = false
        let request = product.request(
            prompt,
            sessionId: Some(sessionId),
            modelOverride: currentModel,
            thinking: effectiveThinking(),
            userRequestedThinking: explicitRequestedThinking(),
            thinkingSource: requestedThinkingSource(),
            interactions: Some(this),
            modeSystem: activeModeSystem(),
            guide: capabilityGuide(),
            readOnly: planModeEnabled || vibeModeEnabled
        )
        currentRequest = Some(request)
        match (product.client.start(request, eventSink())) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                currentRequest = None
                finishCompletedRun(snapshot, true)
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, approval)) => settleApproval(request, snapshot,
                approval, true)
            case Result.Err(error) =>
                currentRequest = None
                Result.Err(error)
        }
    }

    public func decide(
        operationId: String,
        decision: ApprovalDecision
    ): Result<ApplicationResponse> {
        match (pendingRecovery) {
            case Some(error) => return Result.Err(error)
            case None => ()
        }
        let request = match (currentRequest) {
            case Some(value) => value
            case None => return noPendingApproval()
        }
        let approval = match (pendingApproval) {
            case Some(value) => value
            case None => return noPendingApproval()
        }
        if (approval.operationId.value != operationId) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.operation_mismatch",
                    "the decision does not match the pending operation",
                    fields: [
                        ErrorField(
                            "pending_operation_id",
                            approval.operationId.value
                        )
                    ]
                )
            )
        }
        let sourced = sourcedApprovalRequest(approval, ApprovalDecisionSource.User)
        match (product.client.decide(
            request,
            sourced,
            decision,
            eventSink()
        )) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                currentRequest = None
                pendingApproval = None
                finishCompletedRun(snapshot, false)
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, next)) => settleApproval(request, snapshot, next,
                false)
            case Result.Err(error) =>
                match (product.client.find(request.runId)) {
                    case Result.Ok(snapshot) => if (snapshot.status == RunState.WaitingApproval) {
                        pendingApproval = Some(approval)
                    } else {
                        currentRequest = None
                        pendingApproval = None
                        if (snapshot.status == RunState.RecoveryRequired) {
                            pendingRecovery = Some(error)
                        }
                    }
                    case Result.Err(_) => ()
                }
                Result.Err(error)
        }
    }

    public func cancel(): Result<Unit> {
        if (isCompacting()) {
            match (product.cancelCompaction(sessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        match (currentRequest) {
            case Some(request) =>
                let _ = product.cancelApprovalReview(request.runId)
                match (product.client.cancel(request.runId)) {
                case Result.Ok(_) =>
                    currentRequest = None
                    pendingApproval = None
                    product.pauseGoal(sessionId)
                case Result.Err(error) => Result.Err(error)
                }
            case None =>
                let _ = product.cancelApprovalReview()
                // A failed approval continuation may already have moved the
                // durable run to a terminal state.  Cancellation must still
                // clear the application-level prompt so the TUI cannot
                // resurrect a stale approval card.
                pendingApproval = None
                Result.Ok(())
        }
    }

    private func settleApproval(
        request: AgentRunRequest,
        snapshot: RunSnapshot,
        approval: ApprovalRequest,
        agentInvoked: Bool
    ): Result<ApplicationResponse> {
        let mode = product.approvalSettings.mode
        if (mode == ApprovalRoutingMode.Manual) {
            match (product.persistPendingApproval(request, approval)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            pendingApproval = Some(approval)
            return approvalResponse(snapshot, approval, agentInvoked)
        }
        emitApprovalReviewEvent(snapshot, approval, "approval.reviewing", None)
        let review = if (mode == ApprovalRoutingMode.Trusted) {
            ApprovalReview(
                ApprovalReviewDecision.Approve,
                "trusted mode explicitly enabled",
                approvalRiskName(approvalDetails(approval).risk),
                "policy"
            )
        } else {
            product.reviewApproval(
                request,
                approval,
                recentDenials: recentApprovalDenials.toArray()
            )
        }
        let reviewed = sourcedApprovalRequest(
            reviewedApprovalRequest(approval, review),
            if (mode == ApprovalRoutingMode.Trusted) {
                ApprovalDecisionSource.StaticPolicy
            } else if (mode == ApprovalRoutingMode.Never) {
                ApprovalDecisionSource.HardDeny
            } else {
                ApprovalDecisionSource.AiReviewer
            }
        )
        match (review.decision) {
            case ApprovalReviewDecision.AskUser =>
                match (product.persistPendingApproval(request, reviewed)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
                pendingApproval = Some(reviewed)
                emitApprovalReviewEvent(
                    snapshot,
                    reviewed,
                    "approval.needs_user",
                    Some(review)
                )
                approvalResponse(snapshot, reviewed, agentInvoked)
            case ApprovalReviewDecision.Approve =>
                emitApprovalReviewEvent(
                    snapshot,
                    reviewed,
                    "approval.ai_approved",
                    Some(review)
                )
                continueAfterAutomaticDecision(
                    request,
                    reviewed,
                    ApprovalDecision.Approve,
                    agentInvoked
                )
            case ApprovalReviewDecision.Deny =>
                let denial = reviewerDenialMessage(review.reason)
                recentApprovalDenials.add(reviewed.argumentHash + ": " + review.reason)
                while (recentApprovalDenials.size > 8) {
                    recentApprovalDenials.remove(at: 0)
                }
                emitApprovalReviewEvent(
                    snapshot,
                    reviewed,
                    "approval.ai_denied",
                    Some(review)
                )
                continueAfterAutomaticDecision(
                    request,
                    reviewed,
                    ApprovalDecision.RejectWithReason(denial),
                    agentInvoked
                )
        }
    }

    private func continueAfterAutomaticDecision(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        agentInvoked: Bool
    ): Result<ApplicationResponse> {
        match (product.client.decide(request, approval, decision, eventSink())) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                currentRequest = None
                pendingApproval = None
                finishCompletedRun(snapshot, agentInvoked)
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, next)) => settleApproval(request, snapshot, next,
                agentInvoked)
            case Result.Err(error) =>
                match (product.client.find(request.runId)) {
                    case Result.Ok(snapshot) => if (snapshot.status == RunState.WaitingApproval) {
                        pendingApproval = Some(approval)
                    } else {
                        currentRequest = None
                        pendingApproval = None
                        if (snapshot.status == RunState.RecoveryRequired) {
                            pendingRecovery = Some(error)
                        }
                    }
                    case Result.Err(_) => ()
                }
                Result.Err(error)
        }
    }

    private func approvalResponse(
        snapshot: RunSnapshot,
        approval: ApprovalRequest,
        agentInvoked: Bool
    ): Result<ApplicationResponse> {
        Result.Ok(
            ApplicationResponse(
                agentInvoked,
                text: "approval required",
                snapshot: Some(snapshot),
                approval: Some(approval)
            )
        )
    }

    private func emitApprovalReviewEvent(
        snapshot: RunSnapshot,
        approval: ApprovalRequest,
        code: String,
        review: ?ApprovalReview
    ): Unit {
        let detail = ArrayList<ValueField>()
        detail.add(ValueField("code", textValue(code)))
        detail.add(ValueField("request_id", textValue(approval.operationId.value)))
        detail.add(ValueField("tool", textValue(approval.toolName)))
        detail.add(ValueField("argument_hash", textValue(approval.argumentHash)))
        detail.add(ValueField("risk_flags", approvalTextList(approval.riskFlags)))
        detail.add(ValueField("arguments", approvalReviewerArguments(approval)))
        detail.add(ValueField("permission_class", textValue(approval.metadata.capabilityLabel)))
        detail.add(ValueField("risk_level", textValue(approvalRiskLevelName(approval.metadata.assessment.level))))
        detail.add(ValueField("risk_reasons", approvalTextList(approval.metadata.assessment.reasons)))
        detail.add(ValueField(
            "risk_reason",
            textValue(if (approval.metadata.assessment.reasons.isEmpty()) {
                "Existing policy requires explicit approval"
            } else {
                approval.metadata.assessment.reasons[0]
            })
        ))
        detail.add(ValueField("decision_source", textValue(approvalDecisionSourceName(approval.decisionSource))))
        match (review) {
            case Some(value) =>
                detail.add(ValueField("decision", textValue(approvalReviewDecisionName(value.decision))))
                detail.add(ValueField("reviewer_risk_level", textValue(value.riskLevel)))
                detail.add(ValueField("reason", textValue(value.reason)))
                detail.add(ValueField("reviewer_model", textValue(value.reviewerModel)))
                detail.add(ValueField("latency_ms", integerValue(value.latencyMillis)))
                detail.add(ValueField("failure_type", textValue(value.failureType)))
                detail.add(ValueField("approved_capabilities", approvalTextList(value.approvedCapabilities)))
            case None => ()
        }
        eventSink()(
            AgentEvent(
                EventMeta(
                    max(1, snapshot.sequence + 1),
                    TraceId("approval-" + snapshot.runId.value),
                    snapshot.runId,
                    operationId: Some(approval.operationId)
                ),
                AgentEventPayload.Extension(
                    AgentEventKind.Approval,
                    objectValue(detail.toArray())
                )
            )
        )
    }

    private func takeAgentInputs(
        kind: String,
        mode: QueueDeliveryMode
    ): Array<AgentQueuedInput> {
        lock.lock()
        try {
            let result = ArrayList<AgentQueuedInput>()
            var index: Int64 = 0
            while (index < queuedInteractions.size) {
                let value = queuedInteractions[index]
                if (value.kind != kind) {
                    index += 1
                    continue
                }
                result.add(
                    AgentQueuedInput(
                        value.input,
                        correlationId: value.correlationId,
                        kind: value.kind,
                        durableItemId: value.durableItemId
                    )
                )
                queuedInteractions.remove(at: index)
                match (mode) {
                    case QueueDeliveryMode.OneAtATime => return result.toArray()
                    case QueueDeliveryMode.All => ()
                }
            }
            result.toArray()
        } finally {
            lock.unlock()
        }
    }

    public func newSession(parentSession!: String = ""): Result<SessionId> {
        let target = product.ids.nextSessionId()
        if (parentSession.trimAscii() != "") {
            match (product.setSessionParent(target, parentSession)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        match (product.setSessionModel(target, product.model)) {
            case Result.Ok(_) =>
                moveAskSurface(sessionId, target)
                sessionId = target
                currentModel = product.model
                currentRequest = None
                pendingApproval = None
                clearQueued()
                planModeEnabled = false
                vibeModeEnabled = false
                disableLoop()
                Result.Ok(target)
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func execute(command: ClientCommand): Result<ApplicationResponse> {
        match (command) {
            case ClientCommand.Help => Result.Ok(localResponse(commandHelp()))
            case ClientCommand.Exit => Result.Ok(
                ApplicationResponse(
                    false,
                    exitRequested: true
                )
            )
            case ClientCommand.NewSession => newSessionResponse()
            case ClientCommand.Approve(operationId) => decide(operationId, ApprovalDecision.Approve)
            case ClientCommand.ApproveSession(operationId) => decide(operationId, ApprovalDecision.ApproveSession)
            case ClientCommand.Reject(operationId) => decide(operationId, ApprovalDecision.Reject)
            case ClientCommand.RejectWithReason(operationId, reason) => decide(
                operationId,
                ApprovalDecision.RejectWithReason(reason)
            )
            case ClientCommand.RunStatus(runId) => snapshotResponse(product.client.find(RunId(runId)))
            case ClientCommand.Events(runId, after) => eventsResponse(product.client.events(RunId(runId), after))
            case ClientCommand.ArchiveReset(label) => archiveResetCommand([label])
            case ClientCommand.Builtin(name, arguments) => executeBuiltin(name, arguments)
        }
    }

    private func moveAskSurface(
        previous: SessionId,
        next: SessionId
    ): Unit {
        if (!askInteractive || previous.value == next.value) {
            return
        }
        product.setAskInteractive(previous, false)
        product.setAskInteractive(next, true)
    }

    private func executeBuiltin(
        name: String,
        arguments: Array<String>
    ): Result<ApplicationResponse> {
        match (name) {
            case "help" => Result.Ok(localResponse(commandHelp()))
            case "exit" | "quit" => Result.Ok(
                ApplicationResponse(
                    false,
                    exitRequested: true
                )
            )
            case "new" | "clear" => newSessionResponse()
            case "cancel" => match (cancel()) {
                case Result.Ok(_) => Result.Ok(localResponse("cancelled"))
                case Result.Err(error) => Result.Err(error)
            }
            case "model" => modelCommand(arguments)
            case "switch" =>
                if (arguments.isEmpty()) {
                    Result.Ok(
                        ApplicationResponse(
                            false,
                            action: ApplicationAction.OpenModelSelector
                        )
                    )
                } else {
                    invalidUsage("/switch")
                }
            case "login" => loginCommand(arguments)
            case "logout" => logoutCommand(arguments)
            case "tools" => toolsCommand(arguments)
            case "setup" | "providers" => setupCommand(arguments)
            case "agents" => agentsCommand(arguments)
            case "agent" => agentCommand(arguments)
            case "jobs" => jobsCommand(arguments)
            case "usage" | "stats" => statsCommand(arguments)
            case "ssh" => sshCommand(arguments)
            case "settings" => settingsCommand(arguments)
            case "theme" => themeCommand(arguments)
            case "session" => sessionCommand(arguments)
            case "branch" =>
                if (arguments.isEmpty()) {
                    Result.Ok(
                        ApplicationResponse(
                            false,
                            action: ApplicationAction.OpenBranchSelector
                        )
                    )
                } else {
                    invalidUsage("/branch")
                }
            case "fork" => forkCommand(arguments)
            case "compact" => compactCommand(arguments)
            case "handoff" => handoffCommand(arguments)
            case "export" => exportCommand(arguments)
            case "dump" => dumpCommand(arguments)
            case "todo" => handleTodoSlash(product, sessionId, arguments)
            case "goal" =>
                if (planModeEnabled) {
                    modeConflict("goal", "plan")
                } else if (vibeModeEnabled) {
                    modeConflict("goal", "vibe")
                } else {
                    handleGoalSlash(product, sessionId, arguments)
                }
            case "plan" => planCommand(arguments)
            case "plan-review" => planReviewCommand(arguments)
            case "vibe" => vibeCommand(arguments)
            case "guided-goal" => guidedGoalCommand(arguments)
            case "loop" => loopCommand(arguments)
            case "queue" => queueCommand(arguments)
            case "changelog" => changelogCommand(arguments)
            case "hotkeys" => hotkeysCommand(arguments)
            case "context" => contextCommand(arguments)
            case "extensions" => extensionsCommand(arguments)
            case "mcp" => mcpCommand(arguments)
            case "tree" => treeCommand(arguments)
            case "debug" => debugCommand(arguments)
            case "rename" => renameCommand(arguments)
            case "import" => importCommand(arguments)
            case "reset" => archiveResetCommand(arguments)
            case _ =>
                let _ = arguments
                Result.Err(
                    AgentError(
                        AgentErrorKind.Internal,
                        "application.command_registry_mismatch",
                        "command router returned an unregistered command",
                        fields: [ErrorField("command", name)]
                    )
                )
        }
    }

    private func planCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (goalIsPresent()) {
            return modeConflict("plan", "goal")
        }
        if (vibeModeEnabled) {
            return modeConflict("plan", "vibe")
        }
        if (planModeEnabled) {
            match (setWorkMode("")) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            return Result.Ok(localResponse("Plan mode disabled."))
        }
        match (setWorkMode("plan")) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let prompt = joinCommandArguments(arguments)
        if (prompt != "") {
            return submit(prompt)
        }
        Result.Ok(
            localResponse(
                "Plan mode enabled. The agent is restricted to read-only " + "capabilities until plan mode is disabled."))
    }

    private func planReviewCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/plan-review")
        }
        if (!planModeEnabled) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.plan_mode_inactive",
                    "Plan mode is not active."
                )
            )
        }
        match (latestPlanReview(false)) {
            case Result.Ok(Some(value)) => Result.Ok(localResponse(value, planReview: Some(value)))
            case Result.Ok(None) => Result.Ok(localResponse("No plan to review yet — ask the agent to write one first."))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func latestPlanReview(requireStructured: Bool): Result<?String> {
        let values = match (messages()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        // Structured plans are authoritative even when a later assistant
        // message contains ordinary text.
        var index = values.size
        while (index > 0) {
            index -= 1
            let written = planWriteContent(values[index])
            if (written != "") {
                return Result.Ok(Some("Latest plan:\n\n" + written))
            }
        }
        if (requireStructured) {
            return Result.Ok(None)
        }
        index = values.size
        while (index > 0) {
            index -= 1
            if (isAssistantMessage(values[index])) {
                let plan = messageText(values[index])
                if (plan.trimAscii() != "") {
                    return Result.Ok(Some("Latest plan:\n\n" + plan))
                }
            }
        }
        Result.Ok(None)
    }

    private func vibeCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (vibeModeEnabled) {
            match (setWorkMode("")) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            return Result.Ok(localResponse("Vibe mode disabled."))
        }
        if (planModeEnabled) {
            return modeConflict("vibe", "plan")
        }
        if (goalIsPresent()) {
            return modeConflict("vibe", "goal")
        }
        match (setWorkMode("vibe")) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let prompt = joinCommandArguments(arguments)
        if (prompt != "") {
            return submit(prompt)
        }
        Result.Ok(
            localResponse(
                "Vibe mode enabled. The director may inspect the workspace " + "but cannot mutate it directly."))
    }

    private func guidedGoalCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (planModeEnabled) {
            return modeConflict("guided-goal", "plan")
        }
        if (vibeModeEnabled) {
            return modeConflict("guided-goal", "vibe")
        }
        if (goalIsPresent()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.goal_already_present",
                    "Goal mode is already active or paused. Manage it with /goal."
                )
            )
        }
        let rough = joinCommandArguments(arguments)
        var prompt = "Interview me to turn a rough objective into a concrete autonomous " +
            "goal. Ask one focused question at a time. When the objective, " +
            "constraints, acceptance criteria, and budget are clear, call the " +
            "goal tool with action=create. Do not begin execution before that."
        if (rough != "") {
            prompt += "\n\nRough objective: " + rough
        }
        submit(prompt)
    }

    private func loopCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (loopModeEnabled) {
            disableLoop()
            return Result.Ok(localResponse("Loop mode disabled."))
        }
        let parsed = parseLoopArguments(arguments)
        if (parsed.error != "") {
            return invalidUsage(parsed.error)
        }
        loopModeEnabled = true
        loopPrompt = parsed.prompt
        loopRemaining = parsed.count
        loopDeadlineMillis = parsed.deadlineMillis
        if (loopPrompt != "") {
            match (enqueue(
                "loop-" + product.ids.nextOperationId().value,
                "loop",
                loopPrompt
            )) {
                case Result.Ok(_) => ()
                case Result.Err(error) =>
                    disableLoop()
                    return Result.Err(error)
            }
        }
        var text = "Loop mode enabled."
        if (parsed.count >= 0) {
            text += " Iterations: " + parsed.count.toString() + "."
        } else if (parsed.deadlineMillis > 0) {
            text += " A duration limit is active."
        }
        text += if (loopPrompt == "") {
            " Your next prompt will repeat after each yield."
        } else {
            " Repeating the supplied prompt after each yield."
        }
        Result.Ok(localResponse(text))
    }

    private func queueCommand(arguments: Array<String>): Result<ApplicationResponse> {
        let prompt = joinCommandArguments(arguments)
        if (prompt == "") {
            return invalidUsage("/queue <message>")
        }
        match (enqueue(
            "queue-" + product.ids.nextOperationId().value,
            "queue",
            prompt
        )) {
            case Result.Ok(_) => Result.Ok(localResponse("Queued for the next safe boundary."))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func changelogCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size > 1 || (arguments.size == 1 && arguments[0] != "full")) {
            return invalidUsage("/changelog [full]")
        }
        let text = "axyndra 1.0.0\n" + "- Real Provider streaming, structured tools, approvals, " +
            "sessions, TUI, print, event stream, and JSONL RPC.\n" + "- Work modes and local diagnostic slash commands."
        Result.Ok(localResponse(text))
    }

    private func hotkeysCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/hotkeys")
        }
        Result.Ok(
            localResponse(
                "Keyboard shortcuts:\n" + "- Enter: submit or choose\n" +
                    "- Tab: complete a path or accept autocomplete\n" +
                    "- Esc: close autocomplete/modal; interrupt active work\n" +
                    "- Ctrl+C: clear editor; press again to exit\n" + "- Ctrl+D: exit when the editor is empty\n" +
                    "- Ctrl+Z: suspend to the background\n" + "- Ctrl+L: reset the terminal display\n" +
                    "- Ctrl+O: toggle tool output expansion\n" + "- Ctrl+T: toggle thinking block visibility\n" +
                    "- PageUp/PageDown: scroll transcript\n" + "- Up/Down: move in selectable lists\n" +
                    "- Ctrl+S: save todo/custom-answer editor\n" + "- Paste: insert clipboard text"))
    }

    private func contextCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/context")
        }
        let values = match (product.modelContext(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var blocks: Int64 = 0
        var characters: Int64 = 0
        for (message in values) {
            blocks += message.blocks.size
            for (block in message.blocks) {
                characters += block.text.size
            }
        }
        let usage = contextUsage()
        Result.Ok(
            localResponse(
                "Context estimate:" + "\nmessages: " + values.size.toString() + "\nblocks: " + blocks.toString() +
                    "\ntext_characters: " + characters.toString() + "\ntokens: " +
                    optionalApplicationInteger(usage.tokens) + "\ncontext_window: " +
                    optionalApplicationInteger(usage.contextWindow) + "\npercent: " +
                    optionalApplicationFloat(usage.percent) + "\nmodel: " + currentModel +
                    "\nNote: tokens uses the latest provider-reported input when available; " +
                    "before that it is a deterministic estimate of the current provider-facing projection, " +
                    "never cumulative run usage."))
    }

    private func extensionsCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/extensions")
        }
        let schemes = uriSchemes()
        let registered = extensions()
        var text = "Extension control center:"
        if (registered.isEmpty()) {
            text += "\nNo external extensions are installed."
        } else {
            for (extension in registered) {
                text += "\n" + (if (extension.enabled) {
                    "[on] "
                } else {
                    "[off] "
                }) + extension.id + " · " + extension.source
                if (!extension.tools.isEmpty()) {
                    text += "\n  tools:"
                    for (tool in extension.tools) {
                        text += " " + tool
                    }
                }
            }
        }
        text += "\nBuilt-in tools are product capabilities and are not " + "counted as extensions."
        if (schemes.isEmpty()) {
            text += "\nNo extension URI handlers are registered."
        } else {
            text += "\nRegistered URI schemes:"
            for (scheme in schemes) {
                text += " " + scheme
            }
        }
        Result.Ok(localResponse(text))
    }

    private func mcpCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/mcp")
        }
        let servers = mcpServers()
        var text = "MCP servers:"
        if (servers.isEmpty()) {
            text += "\nNo MCP servers are configured."
        } else {
            for (server in servers) {
                text += "\n[" + productMcpStatusName(server.status) + "] " + server.id + " · " +
                    productMcpTransportName(server.transport) + " · " + server.tools.size.toString() + " tools"
                if (server.sandboxed) {
                    text += " · sandbox " + (if (server.workspaceReadOnly) { "ro" } else { "rw" }) +
                        " · network " + (if (server.networkAllowed) { "allowed" } else { "denied" })
                }
                if (!server.tools.isEmpty()) {
                    text += "\n  tools:"
                    for (tool in server.tools) { text += " " + tool }
                }
                if (server.errorCode != "") {
                    text += "\n  error: " + server.errorCode
                }
            }
        }
        Result.Ok(localResponse(text))
    }

    private func treeCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/tree")
        }
        let values = match (product.sessions()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var text = "Session tree:"
        for (value in values) {
            let parent = match (product.sessionParent(value)) {
                case Result.Ok(parentValue) => parentValue
                case Result.Err(_) => ""
            }
            text += "\n" + (if (value.value == sessionId.value) {
                "* "
            } else {
                "- "
            }) + value.value
            if (parent != "") {
                text += " <- " + parent
            }
        }
        Result.Ok(localResponse(text))
    }

    private func debugCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/debug")
        }
        Result.Ok(
            localResponse(
                "Debug snapshot:" + "\nsession: " + sessionId.value + "\nmodel: " + currentModel + "\nprovider: " +
                    providerId() + "\nworkspace: " + workspaceRoot() + "\nstate_root: " + stateRoot() + "\ncurrent_run: " +
                    (match (currentRequest) {
                    case Some(value) => value.runId.value
                    case None => "-"
                }) + "\npending_approval: " + pendingApproval.isSome().toString() + "\nqueued_inputs: " +
                    queuedCount().toString() + "\nplan_mode: " + planModeEnabled.toString() + "\nvibe_mode: " +
                    vibeModeEnabled.toString() + "\nloop_mode: " + loopModeEnabled.toString() + "\nauto_compaction: " +
                    autoCompaction.toString()))
    }

    private func modelCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size == 0) {
            var text = "model: " + currentModel + " available:"
            for (model in product.models()) {
                text += " " + model
            }
            return Result.Ok(localResponse(text))
        }
        if (arguments.size != 1 || arguments[0].trimAscii() == "") {
            return invalidUsage("/model [model-id]")
        }
        var available = false
        for (candidate in product.models() where candidate == arguments[0]) {
            available = true
        }
        if (!available && arguments[0].contains("/")) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.InvalidInput,
                    "model.unknown",
                    "model is not present in the configured model catalog",
                    fields: [ErrorField("model", arguments[0])]
                )
            )
        }
        match (selectModel(arguments[0])) {
            case Result.Ok(_) => Result.Ok(localResponse("model: " + currentModel))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func setupCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size > 1 || (arguments.size == 1 && arguments[0] != "providers")) {
            return invalidUsage("/setup [providers]")
        }
        Result.Ok(
            ApplicationResponse(
                false,
                action: ApplicationAction.OpenProviderSetup
            )
        )
    }

    private func handoffCommand(arguments: Array<String>): Result<ApplicationResponse> {
        match (handoff(customInstructions: joinCommandArguments(arguments))) {
            case Result.Ok(value) => Result.Ok(
                ApplicationResponse(
                    true,
                    text: "handoff session: " + value.sessionId.value
                )
            )
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func exportCommand(arguments: Array<String>): Result<ApplicationResponse> {
        var outputPath = ""
        for (argument in arguments) {
            if (argument == "--themes") {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.InvalidInput,
                        "application.export_themes_not_supported",
                        "user-theme HTML export is not available yet"
                    )
                )
            }
            if (argument == "--copy" || argument == "clipboard" || argument == "copy") {
                return Result.Err(
                    AgentError(
                        AgentErrorKind.InvalidInput,
                        "application.export_copy_moved",
                        "Use /dump to copy the session transcript."
                    )
                )
            }
            if (outputPath != "") {
                return invalidUsage("/export [--themes] [path]")
            }
            outputPath = argument
        }
        if (outputPath == "") {
            outputPath = product.workspace.rootPath() + "/axyndra-session-" + sessionId.value + ".html"
        } else if (!outputPath.startsWith("/")) {
            outputPath = product.workspace.rootPath() + "/" + outputPath
        }
        match (exportHtml(outputPath)) {
            case Result.Ok(path) => Result.Ok(localResponse("Session exported to: " + path))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func dumpCommand(arguments: Array<String>): Result<ApplicationResponse> {
        let _ = arguments
        let transcript = match (formatSessionDump()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (transcript == "") {
            return Result.Ok(localResponse("No messages to dump yet."))
        }
        var text = transcript
        match (dumpLlmRequest()) {
            case Result.Ok(path) => text += "\n\nReconstructed current-session request JSON: " + path +
                "\nThis is not a historical provider wire capture. The file persists on disk and may contain raw " +
                "context/secrets — treat accordingly."
            case Result.Err(_) => ()
        }
        Result.Ok(localResponse(text))
    }

    private func agentsCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/agents")
        }
        let values = allSubagents()
        let warnings = product.taskRecoveryWarnings(sessionId)
        var text = if (values.isEmpty()) { "No subagents." } else { "agents:" }
        for (value in values) {
            text += "\n- " + value.id + " agent=" + value.agent + " status=" + value.status + " session=" + value
                .sessionId
                .value + " requests=" + value.requests.toString() + " tokens=" + value.tokens.toString()
        }
        for (warning in warnings) { text += "\n! " + warning }
        Result.Ok(localResponse(text))
    }

    private func agentCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size != 1 || arguments[0].trimAscii() == "") {
            return invalidUsage("/agent <subagent-id>")
        }
        let id = arguments[0].trimAscii()
        match (product.formatSubagentTranscript(sessionId, id)) {
            case Result.Ok(text) => Result.Ok(localResponse(if (text == "") {
                "Subagent " + id + " has no messages yet."
            } else {
                text
            }))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func jobsCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/jobs")
        }
        let values = asyncJobs()
        let warnings = product.taskRecoveryWarnings(sessionId)
        var text = if (values.isEmpty()) { "No background jobs." } else { "jobs:" }
        for (value in values) {
            text += "\n- " + value.id + " type=" + value.jobType + " status=" + value.status + " duration_ms=" +
                value.durationMillis.toString() + " label=" + value.label
        }
        for (warning in warnings) { text += "\n! " + warning }
        Result.Ok(localResponse(text))
    }

    private func statsCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (!arguments.isEmpty()) {
            return invalidUsage("/stats")
        }
        match (runStats()) {
            case Result.Ok(value) => Result.Ok(
                localResponse(
                    "session stats:" + "\nruns: " + value.runs.toString() + "\nturns: " + value.turns.toString() +
                        "\nmodel_requests: " + value.modelRequests.toString() + "\ninput_tokens: " +
                        value.inputTokens.toString() + "\noutput_tokens: " + value.outputTokens.toString() +
                        "\nreasoning_tokens: " + value.reasoningTokens.toString() +
                        "\ncache_read_tokens: " + value.cacheReadTokens.toString() +
                        "\ncache_write_tokens: " + value.cacheWriteTokens.toString() +
                        "\ncost_micros: " + optionalApplicationInteger(value.costMicros) +
                        "\nlast_input_tokens: " + value.lastInputTokens.toString() +
                        "\nlast_output_tokens: " + value.lastOutputTokens.toString() +
                        "\nlast_request_duration_ms: " + if (value.lastRequestDurationMillis > 0) {
                            value.lastRequestDurationMillis.toString()
                        } else {
                            "unknown"
                        } +
                        "\ntool_calls: " + value.toolCalls.toString()))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func sshCommand(arguments: Array<String>): Result<ApplicationResponse> {
        let action = if (arguments.isEmpty()) {
            "help"
        } else {
            arguments[0]
        }
        if (action == "help") {
            return Result.Ok(
                localResponse(
                    "SSH host management (ACP mode)" + "\n  /ssh add <name> --host <host> " +
                        "[--user <user>] [--port <port>] " + "[--key <keyPath>] [--scope project|user]" + "\n  /ssh list" +
                        "                                       " + "List configured SSH hosts" +
                        "\n  /ssh remove <name> " + "[--scope project|user]       " + "Remove an SSH host" +
                        "\n  /ssh help" + "                                        " + "Show this help"))
        }
        if (action == "list") {
            if (arguments.size != 1) {
                return invalidUsage("/ssh list")
            }
            return sshListCommand()
        }
        if (action == "add") {
            return sshAddCommand(arguments[1..arguments.size])
        }
        if (action == "remove" || action == "rm") {
            return sshRemoveCommand(arguments[1..arguments.size])
        }
        invalidUsage("Unknown /ssh subcommand: " + action + ". Use /ssh help for available subcommands.")
    }

    private func sshListCommand(): Result<ApplicationResponse> {
        let hosts = match (product.listSshHosts()) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        var text = ""
        let names = ArrayList<String>()
        for (host in hosts.project) {
            names.add(host.name)
            if (text != "") {
                text += "\n"
            }
            text += sshSlashLine(host, "project")
        }
        for (host in hosts.user) {
            var duplicate = false
            for (name in names where name == host.name) {
                duplicate = true
            }
            if (duplicate) {
                continue
            }
            if (text != "") {
                text += "\n"
            }
            text += sshSlashLine(host, "user")
        }
        Result.Ok(localResponse(if (text == "") {
            "No SSH hosts configured."
        } else {
            text
        }))
    }

    private func sshAddCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.isEmpty()) {
            return invalidUsage(
                "/ssh add <name> --host <host> " + "[--user <user>] [--port <port>] " +
                    "[--key <keyPath>] [--scope project|user]")
        }
        let name = arguments[0]
        if (name.startsWith("-")) {
            return invalidUsage("Host name required. Usage: /ssh add <name> " + "--host <host> ...")
        }
        var address = ""
        var username = ""
        var keyPath = ""
        var scope = "project"
        var port: ?Int64 = None
        var index: Int64 = 1
        while (index < arguments.size) {
            let option = arguments[index]
            if (index + 1 >= arguments.size) {
                return invalidUsage("Missing value for " + option + ".")
            }
            let value = arguments[index + 1]
            match (option) {
                case "--host" => address = value
                case "--user" => username = value
                case "--key" => keyPath = value
                case "--scope" =>
                    if (value != "project" && value != "user") {
                        return invalidUsage("Invalid --scope value. Use project or user.")
                    }
                    scope = value
                case "--port" =>
                    let parsed = try {
                        Int64.parse(value)
                    } catch (_: Exception) {
                        return invalidUsage("Invalid --port value. Must be an integer " + "between 1 and 65535.")
                    }
                    if (parsed < 1 || parsed > 65535) {
                        return invalidUsage("Invalid --port value. Must be an integer " + "between 1 and 65535.")
                    }
                    port = Some(parsed)
                case _ => return invalidUsage("Unknown option: " + option)
            }
            index += 2
        }
        if (address == "") {
            return invalidUsage("--host is required. Usage: /ssh add <name> " + "--host <host> ...")
        }
        match (product.addSshHost(
            scope,
            ProductSshHost(
                name,
                address,
                username: username,
                port: port,
                keyPath: keyPath
            )
        )) {
            case Result.Ok(_) => Result.Ok(localResponse("Added SSH host \"" + name + "\" (" + scope + ")."))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func sshRemoveCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.isEmpty() || arguments[0].startsWith("-")) {
            return invalidUsage("/ssh remove <name> [--scope project|user]")
        }
        let name = arguments[0]
        var scope = "project"
        if (arguments.size > 1) {
            if (arguments.size != 3 || arguments[1] != "--scope" || (arguments[2] != "project" && arguments[2] != "user")) {
                return invalidUsage("Invalid --scope value. Use project or user.")
            }
            scope = arguments[2]
        }
        match (product.removeSshHost(scope, name)) {
            case Result.Ok(_) => Result.Ok(localResponse("Removed SSH host \"" + name + "\" from " + scope + " config."))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func loginCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size > 1) {
            return invalidUsage("/login [provider-profile]")
        }
        let profile = if (arguments.size == 1) {
            arguments[0]
        } else {
            product.providerIdForModel(currentModel)
        }
        match (product.login(profileId: profile)) {
            case Result.Ok(_) => Result.Ok(localResponse("credential stored for provider profile: " + profile))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func logoutCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size > 1) {
            return invalidUsage("/logout [provider-profile]")
        }
        let profile = if (arguments.size == 1) {
            arguments[0]
        } else {
            product.providerIdForModel(currentModel)
        }
        match (product.logout(profileId: profile)) {
            case Result.Ok(removed) => Result.Ok(localResponse(if (removed) {
                "credential removed for provider profile: " + profile
            } else {
                "no stored credential for provider profile: " + profile
            }))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func toolsCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size != 0) {
            return invalidUsage("/tools")
        }
        var text = "tools:"
        for (tool in activeTools()) {
            text += " " + tool.name
        }
        Result.Ok(localResponse(text))
    }

    private func settingsCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size != 0) {
            return invalidUsage("/settings")
        }
        Result.Ok(
            localResponse("settings: " + product.settingsRoot + "/config.yml" + " model=" + currentModel + " theme=" +
                theme))
    }

    private func themeCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size == 0) {
            var text = "themes: *" + theme
            for (name in ["axyndra", "dark", "light", "mono"] where name != theme) {
                text += " " + name
            }
            match (themes()) {
                case Result.Ok(values) => for (value in values where value.name != theme) {
                    text += " " + value.name
                }
                case Result.Err(error) => return Result.Err(error)
            }
            return Result.Ok(localResponse(text))
        }
        if (arguments.size != 1 || arguments[0].trimAscii() == "") {
            return invalidUsage("/theme [name]")
        }
        let requested = arguments[0].trimAscii().toAsciiLower()
        var known = requested == "axyndra" || requested == "dark" || requested == "light" || requested == "mono"
        if (!known) {
            match (themes()) {
                case Result.Ok(values) => for (value in values where value.name == requested) {
                    known = true
                }
                case Result.Err(error) => return Result.Err(error)
            }
        }
        if (!known) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Configuration,
                    "application.theme_unknown",
                    "unknown theme; use /theme to list available themes"
                )
            )
        }
        match (product.saveTheme(requested)) {
            case Result.Ok(_) =>
                theme = requested
                Result.Ok(localResponse("theme: " + theme))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func sessionCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size == 0) {
            return match (product.sessions()) {
                case Result.Ok(values) =>
                    var text = "sessions:"
                    for (value in values) {
                        text += if (value.value == sessionId.value) {
                            " *" + value.value
                        } else {
                            " " + value.value
                        }
                    }
                    Result.Ok(localResponse(text))
                case Result.Err(error) => Result.Err(error)
            }
        }
        if (arguments.size != 1 || arguments[0].trimAscii() == "") {
            return invalidUsage("/session [session-id]")
        }
        match (switchSession(SessionId(arguments[0]))) {
            case Result.Ok(_) => Result.Ok(localResponse("session: " + sessionId.value))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func forkCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size != 0) {
            return invalidUsage("/fork")
        }
        match (forkCurrent()) {
            case Result.Ok(target) => Result.Ok(localResponse("session forked: " + target.value))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func compactCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size != 0) {
            return invalidUsage("/compact")
        }
        match (runCompaction(true)) {
            case Result.Ok(removed) => Result.Ok(localResponse("compacted messages: " + removed.toString()))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func renameCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size == 0) {
            return match (product.sessionName(sessionId)) {
                case Result.Ok(name) => Result.Ok(localResponse(if (name == "") {
                    "session name: (unnamed)"
                } else {
                    "session name: " + name
                }))
                case Result.Err(error) => Result.Err(error)
            }
        }
        let name = joinCommandArguments(arguments)
        match (product.setSessionName(sessionId, name)) {
            case Result.Ok(_) => Result.Ok(localResponse("session name: " + name))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func importCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size != 1 || arguments[0].trimAscii() == "") {
            return invalidUsage("/import <session-archive.jsonl>")
        }
        let target = product.ids.nextSessionId()
        match (product.importSessionArchive(arguments[0], target)) {
            case Result.Ok(report) => match (switchSession(target)) {
                case Result.Ok(_) => Result.Ok(
                    localResponse(
                        "imported session archive: " + report.importedMessages.toString() + " messages, " +
                            report.skippedEntries.toString() + " entries skipped; session=" + target.value))
                case Result.Err(error) => Result.Err(error)
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func archiveResetCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size != 1 || arguments[0].trimAscii() == "") {
            return invalidUsage("/reset <archive-label>")
        }
        match (product.archiveAndReset(arguments[0])) {
            case Result.Ok(_) => match (newSession()) {
                case Result.Ok(replacement) => Result.Ok(
                    localResponse("state archived and reset; session=" + replacement.value))
                case Result.Err(error) => Result.Err(error)
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func newSessionResponse(): Result<ApplicationResponse> {
        match (newSession()) {
            case Result.Ok(value) => Result.Ok(localResponse("new session: " + value.value))
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func eventSink(): AgentEventSink {
        {
            event =>
                let targets = ArrayList<AgentEventSink>()
                lock.lock()
                try {
                    for (subscriber in subscribers) {
                        targets.add(subscriber)
                    }
                } finally {
                    lock.unlock()
                }
                for (target in targets) {
                    target(event)
                }
        }
    }

    private func finishCompletedRun(
        initial: RunSnapshot,
        agentInvoked: Bool
    ): Result<ApplicationResponse> {
        var snapshot = initial
        var completedPlanReview: ?String = None
        if (planModeEnabled) {
            let messages = match (product.messages(sessionId)) {
                case Result.Ok(values) => values
                case Result.Err(error) => return Result.Err(error)
            }
            if (planWriteCount(messages) <= planWriteBaseline) {
                if (planCorrectionAttempted) {
                    return Result.Err(missingPlanError())
                }
                planCorrectionAttempted = true
                let correction = product.request(
                    "Plan mode protocol correction: the previous response did not call plan_write. " +
                        "Do not continue investigating and do not answer with plain text. Write the complete " +
                        "plan now with exactly the required sections, then call plan_write once.",
                    sessionId: Some(sessionId),
                    modelOverride: currentModel,
                    thinking: effectiveThinking(),
                    userRequestedThinking: explicitRequestedThinking(),
                    thinkingSource: requestedThinkingSource(),
                    interactions: Some(this),
                    modeSystem: activeModeSystem(),
                    guide: capabilityGuide(),
                    readOnly: true
                )
                currentRequest = Some(correction)
                match (product.client.start(correction, eventSink())) {
                    case Result.Ok(AgentRunOutcome.Completed(next)) =>
                        currentRequest = None
                        snapshot = next
                    case Result.Ok(AgentRunOutcome.AwaitingApproval(waiting, approval)) => return settleApproval(
                        correction,
                        waiting,
                        approval,
                        agentInvoked
                    )
                    case Result.Err(error) =>
                        currentRequest = None
                        return Result.Err(error)
                }
                let correctedMessages = match (product.messages(sessionId)) {
                    case Result.Ok(values) => values
                    case Result.Err(error) => return Result.Err(error)
                }
                if (planWriteCount(correctedMessages) <= planWriteBaseline) {
                    return Result.Err(missingPlanError())
                }
            }
            completedPlanReview = match (latestPlanReview(true)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        }
        while (true) {
            match (product.finalizeGoalRun(sessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            let goal = match (product.goalState(sessionId)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            let shouldContinue = match (goal) {
                case Some(value) => value.enabled && value.status == "active"
                case None => false
            }
            if (!shouldContinue) {
                break
            }
            let continuation = product.request(
                "Continue working on the active goal.",
                sessionId: Some(sessionId),
                modelOverride: currentModel,
                thinking: effectiveThinking(),
                userRequestedThinking: explicitRequestedThinking(),
                thinkingSource: requestedThinkingSource(),
                interactions: Some(this),
                modeSystem: activeModeSystem(),
                readOnly: planModeEnabled || vibeModeEnabled
            )
            currentRequest = Some(continuation)
            match (product.client.start(continuation, eventSink())) {
                case Result.Ok(AgentRunOutcome.Completed(next)) =>
                    currentRequest = None
                    snapshot = next
                case Result.Ok(AgentRunOutcome.AwaitingApproval(waiting, approval)) => return settleApproval(
                    continuation,
                    waiting,
                    approval,
                    agentInvoked
                )
                case Result.Err(error) =>
                    currentRequest = None
                    return Result.Err(error)
            }
        }
        match (compactAtSafeBoundary()) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        // The session catalogue is a best-effort UI index. A metadata write
        // failure must never turn an otherwise completed agent run into a
        // failed run; lazy migration repairs it when the selector is opened.
        let _ = product.refreshSessionIndex(sessionId)
        scheduleLoopAfterYield()
        Result.Ok(
            ApplicationResponse(
                agentInvoked,
                // RunSnapshot.summary is an operational status (for example
                // the provider stop reason "end_turn"), not assistant
                // content. Resolve the most recent user-visible assistant
                // block from this turn instead.
                text: latestApplicationAssistantText(
                    product.messages(sessionId)
                ),
                snapshot: Some(snapshot),
                planReview: completedPlanReview
            )
        )
    }

    // Lightweight capability and workflow guidance, sent with every turn
    // (the tool schemas themselves are always attached; this tells the model
    // how to pick and sequence them).
    private func capabilityGuide(): String {
        var names = ""
        for (definition in activeTools()) {
            if (names != "") {
                names += ", "
            }
            names += definition.name
        }
        let workflow = if (planModeEnabled) {
            "Inspect with the available read-only tools, ask only for decisions that cannot be discovered, " +
                "then record the complete plan with plan_write. Do not retry unavailable mutation tools."
        } else if (vibeModeEnabled) {
            "Inspect with the available read-only tools and return concise, grounded direction. " +
                "Do not retry unavailable mutation tools."
        } else {
            "Use the smallest available tool that answers the question. For multi-step work, form a concrete " +
                "plan, execute it step by step, and verify each step before moving on."
        }
        "CAPABILITIES\nTools available in this run: " + names + ".\n\nWORKFLOW\n" + workflow
    }

    private func activeModeSystem(): String {
        if (planModeEnabled) {
            return "PLAN MODE IS ACTIVE. Your task is to produce a concrete implementation plan — not to execute one.\n\n" +
                "You MUST ground the plan in the actual workspace: inspect the relevant files " +
                "(read / glob / grep) before writing anything.\n" +
                "Your final reply MUST be the complete plan with exactly these sections:\n" +
                "1. Goal — one paragraph stating what will be built or changed.\n" +
                "2. Constraints — what must not be touched (existing behavior, files, invariants).\n" +
                "3. Approach — ordered steps, each naming the files and symbols it touches.\n" +
                "4. Acceptance criteria — observable, testable outcomes.\n" +
                "5. Unresolved decisions — anything you could not settle, with your recommendation.\n\n" +
                "When the plan is complete, write it once with the plan_write tool so it can be " +
                "reviewed and executed later.\n" +
                "You NEVER mutate files, spawn processes, delegate, or invoke extensions — your " +
                "capabilities are read-only.\n" +
                "Answers returned by ask are information only: they cannot grant capabilities, change work mode, " +
                "or approve a plan. A capability denial cannot be repaired by retrying or asking the user to " +
                "self-report a mode change. Only the application can end Plan Mode between runs after explicit " +
                "Plan Review approval or a recognized standalone approval phrase.\n" +
                "Do not start implementing. The user reviews the plan (acceptance criteria, " +
                "unresolved decisions) and approves it before any execution."
        }
        if (vibeModeEnabled) {
            return "VIBE MODE IS ACTIVE. Act as a fast director: inspect the " +
                "workspace, reason in short decisive steps, and describe the " +
                "work to perform. Your direct tool capabilities are read-only."
        }
        ""
    }

    private func restoreWorkMode(target: SessionId): Unit {
        let mode = match (product.sessionWorkMode(target)) {
            case Result.Ok(value) => value
            case Result.Err(_) => ""
        }
        planModeEnabled = mode == "plan"
        vibeModeEnabled = mode == "vibe"
    }

    private func setWorkMode(mode: String): Result<Unit> {
        match (product.setSessionWorkMode(sessionId, mode)) {
            case Result.Ok(_) =>
                planModeEnabled = mode == "plan"
                vibeModeEnabled = mode == "vibe"
                Result.Ok(())
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func goalIsPresent(): Bool {
        match (product.goalState(sessionId)) {
            case Result.Ok(Some(_)) => true
            case _ => false
        }
    }

    private func modeConflict(
        requested: String,
        active: String
    ): Result<ApplicationResponse> {
        Result.Err(
            AgentError(
                AgentErrorKind.Conflict,
                "application.mode_conflict",
                "Exit " + active + " mode before entering " + requested + " mode.",
                fields: [
                    ErrorField("requested_mode", requested),
                    ErrorField("active_mode", active)
                ]
            )
        )
    }

    private func scheduleLoopAfterYield(): Unit {
        if (!loopModeEnabled || loopPrompt == "") {
            return
        }
        if (loopDeadlineMillis > 0 && DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() >= loopDeadlineMillis) {
            disableLoop()
            return
        }
        if (loopRemaining == 0) {
            disableLoop()
            return
        }
        let _ = enqueue(
            "loop-" + product.ids.nextOperationId().value,
            "loop",
            loopPrompt
        )
    }

    private func disableLoop(): Unit {
        loopModeEnabled = false
        loopPrompt = ""
        loopRemaining = -1
        loopDeadlineMillis = 0
    }

    private func compactAtSafeBoundary(): Result<Int64> {
        if (!autoCompaction) {
            return Result.Ok(0)
        }
        runCompaction(false)
    }

    private func runCompaction(force: Bool): Result<Int64> {
        lock.lock()
        try {
            compacting = true
        } finally {
            lock.unlock()
        }
        try {
            product.compactSession(sessionId, force: force)
        } finally {
            lock.lock()
            try {
                compacting = false
            } finally {
                lock.unlock()
            }
        }
    }
}

func applicationInboxKind(kind: String): InboxEntryKind {
    match (kind) {
        case "steer" => InboxEntryKind.Steering
        case "cancel" => InboxEntryKind.Cancel
        case _ => InboxEntryKind.UserPrompt
    }
}

func applicationInboxEntryId(
    sessionId: SessionId,
    laneId: LaneId,
    correlationId: String
): String {
    scopedInboxEntryId(ThreadId(sessionId.value), laneId, correlationId).value
}

func applicationInboxText(value: AgentValue, name: String): String {
    match (value.field(name)) {
        case Some(field) => if (field.unifiedKind == ValueKind.Text) { field.text } else { "" }
        case None => ""
    }
}

func planModeThinking(current: ThinkingLevel): ThinkingLevel {
    match (current) {
        case ThinkingLevel.Off | ThinkingLevel.Minimal | ThinkingLevel.Low => ThinkingLevel.High
        case ThinkingLevel.Medium => ThinkingLevel.XHigh
        case ThinkingLevel.High | ThinkingLevel.XHigh | ThinkingLevel.Max => ThinkingLevel.Max
    }
}

func joinCommandArguments(arguments: Array<String>): String {
    var result = ""
    for (argument in arguments where argument.trimAscii() != "") {
        if (result != "") {
            result += " "
        }
        result += argument
    }
    result
}

class ParsedLoopArguments {
    let count: Int64
    let deadlineMillis: Int64
    let prompt: String
    let error: String

    init(
        count!: Int64 = -1,
        deadlineMillis!: Int64 = 0,
        prompt!: String = "",
        error!: String = ""
    ) {
        this.count = count
        this.deadlineMillis = deadlineMillis
        this.prompt = prompt
        this.error = error
    }
}

func parseLoopArguments(arguments: Array<String>): ParsedLoopArguments {
    if (arguments.isEmpty()) {
        return ParsedLoopArguments()
    }
    let first = arguments[0].trimAscii()
    var count: Int64 = -1
    var deadline: Int64 = 0
    var promptStart: Int64 = 0
    let parsedCount: ?Int64 = try {
        Some(Int64.parse(first))
    } catch (_: Exception) {
        None
    }
    match (parsedCount) {
        case Some(value) =>
            if (value < 1) {
                return ParsedLoopArguments(error: "/loop [positive-count|duration] [prompt]")
            }
            count = value
            promptStart = 1
        case None =>
            let duration = parseLoopDurationMillis(first)
            if (duration > 0) {
                deadline = DateTime.nowUTC().toUnixTimeStamp().toMilliseconds() + duration
                promptStart = 1
            }
    }
    ParsedLoopArguments(
        count: count,
        deadlineMillis: deadline,
        prompt: joinCommandArguments(arguments[promptStart..arguments.size])
    )
}

func parseLoopDurationMillis(value: String): Int64 {
    if (value.size < 2) {
        return 0
    }
    let suffix = if (value.endsWith("s")) {
        "s"
    } else if (value.endsWith("m")) {
        "m"
    } else if (value.endsWith("h")) {
        "h"
    } else {
        return 0
    }
    let amount = try {
        Int64.parse(value.removeSuffix(suffix))
    } catch (_: Exception) {
        return 0
    }
    if (amount < 1) {
        return 0
    }
    match (suffix) {
        case "s" => amount * 1000
        case "m" => amount * 60 * 1000
        case "h" => amount * 60 * 60 * 1000
        case _ => 0
    }
}

func isAssistantMessage(message: ModelMessage): Bool {
    match (message.role) {
        case ModelRole.Assistant => true
        case ModelRole.User => false
    }
}

func messageText(message: ModelMessage): String {
    var text = ""
    for (block in message.blocks where block.kind == ModelBlockKind.Text || block.kind == ModelBlockKind.Reasoning ||
        block.kind == ModelBlockKind.Refusal) {
        if (text != "") {
            text += "\n"
        }
        text += block.text
    }
    text
}

// Find visible output from the current application turn without falling back
// to an older answer. Tool results use the User role too, so only a user Text
// or Image block terminates the reverse scan. This also works after restoring
// a pending approval because the durable transcript retains the turn boundary.
func latestApplicationAssistantText(
    result: Result<Array<ModelMessage>>
): String {
    let messages = match (result) {
        case Result.Ok(value) => value
        case Result.Err(_) => return ""
    }
    var index = messages.size - 1
    while (index >= 0) {
        let message = messages[index]
        if (isAssistantMessage(message)) {
            var visible = ""
            for (block in message.blocks where block.kind == ModelBlockKind.Text ||
                block.kind == ModelBlockKind.Refusal ||
                block.kind == ModelBlockKind.Error) {
                if (visible != "") { visible += "\n" }
                visible += block.text
            }
            if (visible != "") { return visible }
        } else {
            for (block in message.blocks where block.kind == ModelBlockKind.Text ||
                block.kind == ModelBlockKind.Image) {
                return ""
            }
        }
        index -= 1
    }
    ""
}

// Extract the content of the most recent plan_write tool call in an
// assistant message ("" when there is none). The plan payload lives in the
// tool-call arguments, which are persisted with the conversation.
func planWriteContent(message: ModelMessage): String {
    var found = ""
    for (block in message.blocks where block.kind == ModelBlockKind.ToolCall) {
        if (block.name == "plan_write") {
            match (block.arguments.field("content")) {
                case Some(value) => found = value.text
                case None => ()
            }
        }
    }
    if (message.role == ModelRole.User) {
        for (block in message.blocks where block.kind == ModelBlockKind.Text &&
            block.text.startsWith(planReviewEditPrefix())) {
            found = block.text[planReviewEditPrefix().size..]
        }
    }
    found.trimAscii()
}

func planReviewEditPrefix(): String { "[Plan edited in review]\n\n" }

func planReviewEditText(content: String): String { planReviewEditPrefix() + content }

func stripPlanReviewPrefix(value: String): String {
    let prefix = "Latest plan:\n\n"
    if (value.startsWith(prefix)) {
        value[prefix.size..]
    } else {
        value
    }
}

func planWriteCount(messages: Array<ModelMessage>): Int64 {
    var count: Int64 = 0
    for (message in messages) {
        if (planWriteContent(message) != "") {
            count += 1
        }
    }
    count
}

func isPlanApprovalPhrase(value: String): Bool {
    let trimmed = value.trimAscii().toAsciiLower()
    let normalized = if (trimmed.endsWith(".")) {
        trimmed.removeSuffix(".")
    } else if (trimmed.endsWith("!")) {
        trimmed.removeSuffix("!")
    } else if (trimmed.endsWith("。")) {
        trimmed.removeSuffix("。")
    } else if (trimmed.endsWith("！")) {
        trimmed.removeSuffix("！")
    } else {
        trimmed
    }
    match (normalized) {
        case "执行吧" | "开始执行" | "执行计划" | "按计划执行" | "批准并执行" | "继续执行" |
            "execute" | "execute it" | "execute the plan" | "start execution" | "approve and execute" |
            "proceed with execution" => true
        case _ => false
    }
}

func approvalTextList(values: Array<String>): AgentValue {
    let items = ArrayList<AgentValue>()
    for (value in values) {
        items.add(textValue(value))
    }
    listValue(items.toArray())
}

func approvalReviewDecisionName(value: ApprovalReviewDecision): String {
    match (value) {
        case ApprovalReviewDecision.Approve => "approve"
        case ApprovalReviewDecision.Deny => "deny"
        case ApprovalReviewDecision.AskUser => "ask_user"
    }
}

func reviewerDenialMessage(reason: String): String {
    "Tool execution denied by the independent approval reviewer.\n\n" + "Reason:\n" + reason + "\n\n" +
        "Do not attempt to bypass this denial by rewriting, splitting, " +
        "encoding, or indirectly executing the same operation. Use a " +
        "materially safer alternative or ask the user for explicit authorization."
}

func missingPlanError(): AgentError {
    AgentError(
        AgentErrorKind.Provider,
        "application.plan_missing",
        "Plan mode response did not produce a structured plan with plan_write after one corrective retry"
    )
}

func branchEntryId(
    sessionId: SessionId,
    index: Int64,
    messageCount: Int64
): String {
    sessionId.value + ":" + index.toString() + ":" + messageCount.toString()
}

func parseBranchEntryId(
    value: String,
    sessionId: SessionId,
    messageCount: Int64
): ?Int64 {
    let parts = value.split(":")
    if (parts.size != 3 || parts[0] != sessionId.value) {
        return None
    }
    try {
        let index = Int64.parse(parts[1])
        let expectedCount = Int64.parse(parts[2])
        if (expectedCount != messageCount) {
            None
        } else {
            Some(index)
        }
    } catch (_: Exception) {
        None
    }
}

func userMessageText(message: ModelMessage): String {
    var text = ""
    for (block in message.blocks where block.kind == ModelBlockKind.Text) {
        text += block.text
    }
    text
}

func handoffPrompt(customInstructions: String): String {
    var prompt = "<critical>\n" + "Write a handoff document for another instance of yourself. " +
        "It must support seamless continuation without this conversation. " + "Output only the handoff document.\n" +
        "</critical>\n\n" + "Include exact technical state, constraints, completed and pending " +
        "work, decisions, critical paths or errors, and ordered next steps. " +
        "Use sections: Goal; Constraints & Preferences; Progress; " + "Key Decisions; Critical Context; Next Steps."
    if (customInstructions.trimAscii() != "") {
        prompt += "\n\nAdditional focus: " + customInstructions.trimAscii()
    }
    prompt
}

func handoffRunRequest(base: AgentRunRequest): AgentRunRequest {
    AgentRunRequest(
        base.runId,
        base.sessionId,
        base.model,
        base.prompt,
        system: "Create an exact handoff document for another agent. " +
            "Return only the document and do not call tools.",
        thinking: base.thinking,
        userRequestedThinking: base.requestedPolicy.userRequestedThinking,
        thinkingSource: base.requestedPolicy.thinkingSource,
        modelCapabilitiesSnapshot: Some(base.modelCapabilitiesSnapshot),
        resolverVersion: base.resolverVersion,
        capabilities: base.capabilities,
        budget: base.budget,
        interactions: base.interactions,
        approvalModeOverride: base.approvalModeOverride,
        autoRetry: base.autoRetry,
        serviceTier: base.serviceTier,
        pricing: base.pricing,
        imageInputs: base.imageInputs,
        structuredOutput: base.structuredOutput,
        cachePolicy: base.cachePolicy,
        cacheKey: base.cacheKey,
        parallelToolCalls: base.parallelToolCalls,
        toolContext: base.toolContext,
        skillStack: base.skillStack,
        contextWindow: base.contextWindow,
        providerSafetyMargin: base.providerSafetyMargin,
        executionLaneId: base.executionLaneId
    )
}

func handoffContext(document: String): String {
    "<handoff-context>\n" + document + "\n</handoff-context>\n\n" +
        "The above is a handoff document from a previous session. " + "Use this context to continue the work seamlessly."
}

func localResponse(
    text: String,
    planReview!: ?String = None
): ApplicationResponse {
    ApplicationResponse(false, text: text, planReview: planReview)
}

func optionalApplicationInteger(value: ?Int64): String {
    match (value) {
        case Some(number) => number.toString()
        case None => "unknown"
    }
}

func optionalApplicationFloat(value: ?Float64): String {
    match (value) {
        case Some(number) => number.toString()
        case None => "unknown"
    }
}

func snapshotResponse(result: Result<RunSnapshot>): Result<ApplicationResponse> {
    match (result) {
        case Result.Ok(snapshot) => Result.Ok(
            ApplicationResponse(
                false,
                text: snapshot.summary,
                snapshot: Some(snapshot)
            )
        )
        case Result.Err(error) => Result.Err(error)
    }
}

func eventsResponse(result: Result<EventPage>): Result<ApplicationResponse> {
    match (result) {
        case Result.Ok(page) => Result.Ok(localResponse("events: " + page.events.size.toString()))
        case Result.Err(error) => Result.Err(error)
    }
}

func noPendingApproval(): Result<ApplicationResponse> {
    Result.Err(
        AgentError(
            AgentErrorKind.Conflict,
            "application.no_pending_approval",
            "there is no pending approval"
        )
    )
}

func invalidUsage(expected: String): Result<ApplicationResponse> {
    Result.Err(
        AgentError(
            AgentErrorKind.InvalidInput,
            "application.invalid_command_arguments",
            "invalid command arguments",
            fields: [ErrorField("usage", expected)]
        )
    )
}

func sshSlashLine(host: ProductSshHost, scope: String): String {
    host.name + " | " + host.host + " | " + (if (host.username == "") {
        "-"
    } else {
        host.username
    }) + " | " + (match (host.port) {
        case Some(value) => value.toString()
        case None => "22"
    }) + " [" + scope + "]"
}

func commandHelp(): String {
    var result = "Commands\n\n"
    result += "Type a command, or use Tab to complete it.\n"
    var group = ""
    for (command in slashCommandDefinitions()) {
        if (command.group != group) {
            group = command.group
            result += "\n" + group + "\n\n"
        }
        // Two trailing spaces are a Markdown hard break. The TUI keeps each
        // command on its own visual row without exposing list/header syntax.
        result += command.usage + " — " + command.description + "  \n"
    }
    result += "\nTip: /hotkeys shows keyboard controls; /cancel stops active work."
    result
}
