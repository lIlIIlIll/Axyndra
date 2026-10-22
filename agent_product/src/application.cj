package agent_product

import agent_plugin_registry.*

import agent_plugin_registry.{pluginImportError}

import yjson_support.*

import yjson.*

import agent_cli.*
import agent_core.*
import agent_runtime.*
import agent_store.RpcQueuedStoreFailure113
import agent_domain.*
import agent_extension_runtime.*
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
class ApplicationPluginSourceCommand {
    let source: ProductPluginSourceRequest
    let scope: ?PluginInstallScope

    init(source: ProductPluginSourceRequest, scope: ?PluginInstallScope) {
        this.source = source
        this.scope = scope
    }
}
public class ApplicationSession <: AgentInteractionSource & OwnedAgentEventSource {
    private let product: ProductRuntime
    private let router = CommandRouter()
    private let lock = Mutex()
    private var retirableSubscriptions113: ?ArrayList<ApplicationOwnedSubscription113> = None<ArrayList<ApplicationOwnedSubscription113>>
    private var unregisteredSubscription113: ?ApplicationOwnedSubscription113 = None<ApplicationOwnedSubscription113>
    private var retirableDispatchFrames113: Int64 = 0
    private var retirableCleanupFrames113: Int64 = 0
    private let subscribers = ArrayList<AgentEventSink>()
    private let ownedSubscribers = ArrayList<OwnedAgentEventSink>()
    private let ownedFailureSubscribers113 = ArrayList<?OwnedFailureEventSink113>()
    private let pendingOwnedFailureEvents113 = ArrayList<ApplicationOwnedFailureEventGroup113>()
    private var pendingCheckpointSlot113: ?ApplicationOwnedCheckpointSlot113 = None<ApplicationOwnedCheckpointSlot113>
    private let pendingOwnedEvents = ArrayList<OwnedAgentEvent>()
    private var legacyEventSubscribers: Int64 = 0
    private let queuedInteractions = ArrayList<QueuedInteraction>()
    private var sessionId: SessionId
    private var currentModel: String
    private var nextPluginCommandId: Int64 = 1
    private var activePluginCommandCancellation: ?CancellationSource = None
    private var activePluginCommandControl: ?ApplicationPluginCommandControl = None
    private var todoEditorSnapshot: ?ProductTodoEditorSnapshot = None
    private var todoEditorInvocation: ?ProductTodoInvocation = None
    private var todoEditorAction = ""
    private var todoEditorCompletion: ?ProductTodoEditorCompletion = None
    private var activeTodoInvocation: ?ProductTodoInvocation = None
    private var activeTodoSelection: ?ProductTodoSelection = None
    private var activeTodoResource: ?ProductWorkspaceInvocation = None
    private let todoResourceAncestors=ArrayList<ProductWorkspaceInvocation>()
    private let todoRetiredDocuments=ArrayList<ProductTodoInvocation>()
    private var activePluginContinuation: ?ProductContinuationOwner = None
    private var pluginContinuationControlled = false
    private var activePluginServiceStartup: ?ApplicationPluginServiceStartup = None
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
    private var currentRequestCancelling = false
    private var compactionSequence: Int64 = 0
    private var pendingApproval: ?ApprovalRequest = None
    private var pendingRecovery: ?AgentError = None
    private var pendingModelResume = false
    private var pendingContextBoundaryResume = false
    private let recentApprovalDenials = ArrayList<String>()
    private let bashLock = Mutex()
    private var currentBashInvocation: ?ProductNativeToolInvocation = None
    private var bashStarting=false
    private var bashCancellationRequested=false
    private var askInteractive = false
    private var planModeEnabled = false
    private var planWriteBaseline: Int64 = 0
    private var planCorrectionAttempted = false
    private var currentPlanTool = ""
    private var currentPlanVersion = ""
    private var currentPlanFingerprint = ""
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
        restoreWorkMode(this.sessionId)
        restoreQueuedInteractions()
        restorePendingContinuation()
    }

    // Changing the active view must not withdraw work owned by the source session.
    private func activateSession(value: SessionId): Result<Unit> {
        match(todoDocumentInvocation()){
            case Some(invocation)=>match(clearTodoTransfer(invocation)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case None=>()}
        let _ = cancelPluginCommandControl()
        let _ = abortBash()
        revokePluginContinuation()
        moveAskSurface(sessionId, value)
        lock.lock()
        try {
            sessionId = value
            todoEditorSnapshot=None<ProductTodoEditorSnapshot>
            todoEditorCompletion=None<ProductTodoEditorCompletion>
            queuedInteractions.clear()
            pendingRecovery = None
            restoreQueuedInteractions()
        } finally {
            lock.unlock()
        }
        restoreWorkMode(value)
        restorePendingContinuation()
        disableLoop()
        Result.Ok(())
    }

    private func restoreQueuedInteractions(): Unit {
        match (product.vnext.hasPendingRpcLocalProcessing113(ThreadId(sessionId.value))) {
            case Result.Err(error) => pendingRecovery = Some(error); return
            case Result.Ok(true) =>
                pendingRecovery = Some(AgentError(AgentErrorKind.RecoveryRequired,
                    "inbox.rpc_processing_recovery_required", "a local queued input began before restart and cannot be replayed"))
                return
            case Result.Ok(false) => ()
        }
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
        setCurrentRequest(Option<AgentRunRequest>.None)
        pendingApproval = None
        pendingModelResume = false
        pendingContextBoundaryResume = false
        let boundary = match (product.pendingContextBoundary(sessionId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => pendingRecovery = Some(error); return }
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
        if (boundary.isSome() && (approvalContinuation.isSome() || modelContinuation.isSome())) {
            pendingRecovery = Some(AgentError(AgentErrorKind.RecoveryRequired, "context.boundary_continuation_conflict",
                "context boundary conflicts with another pending execution")); return }
        if (boundary.isSome()) {
            let restored = match (product.contextBoundaryRequest(boundary.getOrThrow(), Some(this), ownedEvents: Some(ownedEventSink()))) {
                case Result.Ok(value) => value; case Result.Err(error) => pendingRecovery = Some(error); return }
            setCurrentRequest(Some(restored))
            pendingContextBoundaryResume = true
            currentModel = restored.model
            return
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
                let restored = match (product.continuationRequest(value, Some(this), ownedEvents: Some(ownedEventSink()))) {
                    case Result.Ok(request) => request
                    case Result.Err(error) => pendingRecovery = Some(error); return
                }
                setCurrentRequest(Some(restored))
                pendingApproval = Some(value.approval)
                currentModel = value.model
            case None => match (modelContinuation) {
                case Some(value) =>
                    let restored = match (product.continuationRequest(value, Some(this), ownedEvents: Some(ownedEventSink()))) {
                        case Result.Ok(request) => request
                        case Result.Err(error) => pendingRecovery = Some(error); return
                    }
                    setCurrentRequest(Some(restored))
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
        if (!pendingModelResume && !pendingContextBoundaryResume) { return Result.Ok(Option<ApplicationResponse>.None) }
        let request = match (currentRequestSnapshot()) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "run.startup_resume_request_missing",
                "startup model continuation has no reconstructed request"
            ))
        }
        let resumed = if (pendingContextBoundaryResume) { this.resumeContextBoundaryOwnedCheckpointApplication113(request, eventSink()) }
            else { this.resumeOwnedCheckpointApplication113(request, eventSink()) }
        match (resumed) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                setCurrentRequest(Option<AgentRunRequest>.None)
                pendingModelResume = false
                pendingContextBoundaryResume = false
                match (finishCompletedRun(snapshot, false)) {
                    case Result.Ok(value) => Result.Ok(Some(value))
                    case Result.Err(error) => Result.Err(error)
                }
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, approval)) =>
                pendingModelResume = false
                pendingContextBoundaryResume = false
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

    private func currentRequestSnapshot(): ?AgentRunRequest {
        lock.lock()
        try {
            currentRequest
        } finally {
            lock.unlock()
        }
    }

    private func setCurrentRequest(value: ?AgentRunRequest): Unit {
        lock.lock()
        try {
            currentRequest = value
            currentRequestCancelling = false
        } finally {
            lock.unlock()
        }
    }

    public func activeRunId(): String {
        match (currentRequestSnapshot()) {
            case Some(value) => value.runId.value
            case None => ""
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
        product.tools(threadId: Some(ThreadId(sessionId.value)))
    }

    public func activeTools(): Array<ModelToolDefinition> {
        if (planModeEnabled || vibeModeEnabled) {
            product.toolsFor(product.readonlyToolCapabilities(sessionId),
                threadId: Some(ThreadId(sessionId.value)))
        } else {
            product.tools(threadId: Some(ThreadId(sessionId.value)))
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

    public func bundledAgents(): Result<Array<ProductBundledAgentDefinition>> {
        queryProductWorkflowAgents(product, sessionId)
    }

    public func invokeWorkspaceTool(contribution: String, arguments: AgentValue): Result<ProductWorkspaceInvocation> {
        product.invokeWorkspaceTool(sessionId,contribution,arguments)
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

    public func uriSchemes(custody!: ?OwnedApplicationRegistryResponse161 = None): Array<String> {
        product.uriSchemes(custody: custody)
    }

    public func plugins(): OwnedPluginRecordList {
        product.pluginSnapshots()
    }

    // A persistent session selects its own Thread; callers cannot enumerate or
    // stop another Thread's retained services through this facade.
    public func pluginServiceStatuses(): Array<AgentValue> {
        lock.lock(); let target = try { sessionId } finally { lock.unlock() }
        let values = ArrayList<AgentValue>()
        for (value in product.pluginServiceStatuses() where lifecycleText(value, "target_thread_id") == target.value) {
            values.add(value)
        }
        values.toArray()
    }

    public func startPluginService(namespace: String, serviceId: String, route: String,
        approved!: Bool = false): Result<ToolInvocationResult> {
        // Approval is explicit even in a Yolo model session. No configuration
        // read, process creation or canonical Operation precedes this decision.
        if (!approved) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "plugin.service_approval_required",
                "review the operator lifecycle configuration and use --approve to start this session service"))
        }
        lock.lock()
        let startup = try {
            if (activePluginServiceStartup.isSome()) {
                return Result.Err(AgentError(AgentErrorKind.Conflict, "plugin.service_start_active",
                    "another service startup is active in this application session"))
            }
            let value = ApplicationPluginServiceStartup(sessionId, namespace, serviceId)
            activePluginServiceStartup = Some(value)
            value
        } finally { lock.unlock() }
        try {
            product.startPluginService(startup.target, namespace, serviceId, route,
                approvalDecision: ApprovalDecision.Approve, cancellation: startup.cancellation.token)
        } finally {
            lock.lock()
            try {
                if (activePluginServiceStartup.isSome() && refEq(activePluginServiceStartup.getOrThrow(), startup)) {
                    activePluginServiceStartup = None
                }
            } finally { lock.unlock() }
            startup.cancellation.close()
        }
    }

    private func cancelPluginServiceStartup(target!: ?SessionId = None, namespace!: String = "", serviceId!: String = ""): Unit {
        lock.lock(); let startup = try { activePluginServiceStartup } finally { lock.unlock() }
        match (startup) {
            case Some(value) => if ((target.isNone() || value.target.value == target.getOrThrow().value) &&
                (namespace == "" || value.namespace == namespace) && (serviceId == "" || value.serviceId == serviceId)) {
                let _ = value.cancellation.cancel()
            }
            case None => ()
        }
    }

    public func stopPluginService(namespace: String, serviceId: String): Result<Unit> {
        lock.lock(); let target = try { sessionId } finally { lock.unlock() }
        cancelPluginServiceStartup(target: Some(target), namespace: namespace, serviceId: serviceId)
        product.stopPluginService(target, namespace, serviceId)
    }

    public func closePluginServices(): Result<Unit> {
        lock.lock(); let target = try { sessionId } finally { lock.unlock() }
        cancelPluginServiceStartup(target: Some(target))
        product.stopPluginServices(target)
    }

    public func javascriptPluginCommands(): Array<ProductJavaScriptPluginCommand> {
        product.javascriptPluginCommands()

    public func javascriptPluginViews(): Array<ProductJavaScriptPluginView> {
        product.javascriptPluginViews()
    }
    }

    public func invokeJavaScriptPluginCommand(routeName: String, arguments: String,
        noticeSink: ProductJavaScriptPluginNoticeSink): Result<Unit> {
        match(invokeOwnedPluginCommand(routeName,arguments,noticeSink)){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(response)=>
                if(response.text!=""){noticeSink("info",response.text)}
                Result.Ok(())}
    }

    private func invokeOwnedPluginCommand(routeName: String, arguments: String,
        noticeSink: ProductJavaScriptPluginNoticeSink, todoSelection!: ?ProductTodoSelection = None): Result<ApplicationResponse> {
        let cancellation = CancellationSource()
        let commandId = takePluginCommandId()
        lock.lock()
        let target = try {
            if (activeTodoInvocation.isSome() || activePluginCommandCancellation.isSome() || currentRequest.isSome() || pendingApproval.isSome() || pendingRecovery.isSome()) {
                cancellation.close()
                return commandControlError("plugin.command_session_busy") }
            match(todoSelection){
                case Some(selected)=>if(sessionId.value!=selected.session.value){
                    cancellation.close();return productTodoFrontendError("todo.session_changed")}
                case None=>()}
            todoEditorCompletion=None<ProductTodoEditorCompletion>
            activePluginCommandCancellation = Some(cancellation)
            sessionId
        } finally { lock.unlock() }
        let scope = ProductPluginCommandScope(target, commandId, routeName, arguments, cancellation.token,
            { => match(pluginCommandCurrent(target,cancellation)){
                case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>match(todoSelection){case None=>Result.Ok(());case Some(value)=>value.current()}} },
            { => match(pluginContinuationSessionCurrent(target)){
                case Result.Err(error)=>Result.Err(error)
                case Result.Ok(_)=>match(todoSelection){case None=>Result.Ok(());case Some(value)=>value.current()}} },
            { proposal => preparePluginUserControl(target, proposal) })
        let control = ApplicationPluginCommandControl(product, scope, cancellation,
            { proposal, next => acceptPluginUserControl(target, cancellation, proposal, next) })
        lock.lock()
        try { activePluginCommandControl = Some(control) } finally { lock.unlock() }
        let result = control.invoke(routeName, arguments, noticeSink)
        finishPluginCommandControl(control)
        result
    }

    private func invokeOwnedGoalCommand(routeName: String, arguments: String,
        noticeSink: ProductJavaScriptPluginNoticeSink, selection: ProductGoalSelection, legacyBytes!: ?String = None): Result<ApplicationResponse> {
        let cancellation = CancellationSource()
        let commandId = takePluginCommandId()
        lock.lock()
        let target = try {
            if (activePluginCommandCancellation.isSome() || currentRequest.isSome() || pendingApproval.isSome() || pendingRecovery.isSome()) {
                cancellation.close()
                return commandControlError("plugin.command_session_busy") }
            if(sessionId.value!=selection.session.value){
                cancellation.close();return productGoalPresentationError("goal.selection_session_changed")}
            activePluginCommandCancellation = Some(cancellation)
            sessionId
        } finally { lock.unlock() }
        let scope = ProductPluginCommandScope(target, commandId, routeName, arguments, cancellation.token,
            { => match(pluginCommandCurrent(target,cancellation)){
                case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>
                    currentGoalCommandSelection(selection,legacyBytes)} },
            { => match(pluginContinuationSessionCurrent(target)){
                case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>
                    currentGoalCommandSelection(selection,legacyBytes)} },
            { proposal => preparePluginUserControl(target, proposal) })
        let control = ApplicationPluginCommandControl(product, scope, cancellation,
            { proposal, next => acceptPluginUserControl(target, cancellation, proposal, next) })
        lock.lock()
        try { activePluginCommandControl = Some(control) } finally { lock.unlock() }
        let result = control.invoke(routeName, arguments, noticeSink)
        finishPluginCommandControl(control)
        result
    }

    private func currentGoalCommandSelection(selection: ProductGoalSelection, legacyBytes: ?String): Result<Unit> {
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(legacyBytes){case None=>();case Some(expected)=>
            let value=match(product.legacyGoalForMigration(selection.session)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(value!=expected){return productGoalPresentationError("goal.legacy_changed")}}
        Result.Ok(())
    }

    private func goalCommand(arguments: String): Result<ApplicationResponse> {
        let target=id()
        let selection=match(selectProductGoal(product,target)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let canonical=match(product.goalState(target)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        // Current documents use the selected native command. Archived cold
        // bytes participate only in explicit migration or an empty document.
        if(arguments.trimAscii()!="migrate" && canonical.isSome()){
            return invokeOwnedGoalCommand(selection.route,arguments,{ _, _ => () },selection)}
        let legacyRaw=match(product.legacyGoalForMigration(target)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let legacy=try{parseUnifiedJson(legacyRaw,maxBytes:8388608,maxDepth:32)}
            catch(_:Exception){return productGoalPresentationError("goal.legacy_format_readonly")}
        let migrating=arguments.trimAscii()=="migrate"
        if(migrating){
            if(canonical.isSome() || legacy.unifiedKind==ValueKind.Null){
                return productGoalPresentationError("goal.legacy_migration_not_empty")}
            // Preserve and fingerprint the actual cold SQL bytes, including
            // whitespace/field order. A pending approval re-reads those bytes.
            let encoded=legacyRaw
            let payload=encodeAgentValue(objectValue([ValueField("legacy_document",textValue(encoded)),
                ValueField("legacy_sha256",textValue(modelPolicySha256Text(encoded)))]))
            // This explicitly bounded cold-format migration is a command
            // convenience, independent of the eight MiB canonical Doc limit.
            // Unsupported inputs remain read-only before any Root/write.
            if(payload.toArray().size>16384){return productGoalPresentationError("goal.legacy_format_readonly")}
            return invokeOwnedGoalCommand(selection.route,"migrate "+payload,{ _, _ => () },selection,legacyBytes:Some(encoded))
        }
        if(canonical.isNone() && legacy.unifiedKind!=ValueKind.Null){
            return productGoalPresentationError("goal.legacy_migration_required")}
        // Native business parsing runs through the original retained command
        // owner, approval and user-control participant. UI data creates no Root.
        invokeOwnedGoalCommand(selection.route,arguments,{ _, _ => () },selection)
    }

    private func pluginCommandCurrent(target: SessionId, cancellation: CancellationSource): Result<Unit> {
        lock.lock()
        try {
            if (sessionId.value != target.value || activePluginCommandCancellation.isNone() ||
                !refEq(activePluginCommandCancellation.getOrThrow(), cancellation)) {
                return commandControlError("plugin.command_session_changed") }
            cancellation.token.check()
        } finally { lock.unlock() }
    }
    private func pluginContinuationSessionCurrent(target: SessionId): Result<Unit> {
        lock.lock(); try {
            if (sessionId.value != target.value) { commandControlError("continuation.session_changed") }
            else { Result.Ok(()) }
        } finally { lock.unlock() }
    }
    private func preparePluginUserControl(target: SessionId, proposal: ProductCommandProposal): Result<String> {
        let raw = proposal.control().getOrThrow()
        lock.lock()
        let previous = try {
            if (sessionId.value != target.value) { return commandControlError("plugin.command_session_changed") }
            activePluginContinuation
        } finally { lock.unlock() }
        match (previous) {
            case Some(owner) =>
                if (owner.address.threadId.value == target.value && owner.address.namespace == proposal.binding.namespace &&
                    owner.address.documentKey == httpIntentText(raw, "document_key")) {
                    if (httpIntentText(raw, "action") == "pause" || httpIntentText(raw, "action") == "close") { owner.revoke() }
                    return Result.Ok(owner.prompt)
                }
            case None => () }
        Result.Ok("")
    }
    private func acceptPluginUserControl(target: SessionId, cancellation: CancellationSource,
        proposal: ProductCommandProposal, next: ?ProductContinuationOwner): Result<Unit> {
        if (proposal.control().isNone()) { return Result.Ok(()) }
        lock.lock()
        let update = try {
            if (sessionId.value != target.value || activePluginCommandCancellation.isNone() ||
                !refEq(activePluginCommandCancellation.getOrThrow(), cancellation) || cancellation.token.isCancelled()) {
                (false, Option<ProductContinuationOwner>.None)
            } else {
                let old = activePluginContinuation; activePluginContinuation = next; pluginContinuationControlled = true; (true, old)
            }
        } finally { lock.unlock() }
        if (!update[0]) {
            match (next) { case Some(value) => value.revoke(); case None => () }
            return commandControlError("plugin.command_session_changed") }
        match (update[1]) { case Some(value) => value.revoke(); case None => () }
        Result.Ok(())
    }
    private func finishPluginCommandControl(control: ApplicationPluginCommandControl): Unit {
        if (!control.isClosed()) { return }
        lock.lock()
        try {
            if (activePluginCommandControl.isSome() && refEq(activePluginCommandControl.getOrThrow(), control)) {
                activePluginCommandControl = None; activePluginCommandCancellation = None }
        } finally { lock.unlock() }
    }
    private func pluginCommandControl(): ?ApplicationPluginCommandControl {
        lock.lock(); try { activePluginCommandControl } finally { lock.unlock() }
    }
    private func cancelPluginCommandControl(): Result<Unit> {
        lock.lock()
        let actual = try { (activePluginCommandCancellation, activePluginCommandControl) } finally { lock.unlock() }
        match (actual[0]) { case Some(value) => let _ = value.cancel(); case None => () }
        match (actual[1]) {
            case Some(value) => let result = value.cancel(); finishPluginCommandControl(value); result
            case None => Result.Ok(()) }
    }
    public func cancelJavaScriptPluginCommand(): Unit { let _ = cancelPluginCommandControl() }

    private func revokePluginContinuation(): Unit {
        lock.lock(); let previous = try { let old = activePluginContinuation; activePluginContinuation = None; old } finally { lock.unlock() }
        match (previous) { case Some(value) => value.revoke(); case None => () }
    }

    private func takePluginCommandId(): String {
        lock.lock()
        try {
            let id = "plugin-command-" + nextPluginCommandId.toString()
            nextPluginCommandId += 1
            id
        } finally {
            lock.unlock()
        }
    }
    public func inspectPlugin(root: String): PluginRegistryResult<OwnedPluginPackageDescriptor> {
        product.inspectPlugin(root)
    }

    public func importLocalPlugin(root: String): PluginRegistryResult<ProductPluginRecord> {
        product.importLocalPlugin(root)
    }
    public func importLocalPlugin(root: String, scope: PluginInstallScope): PluginRegistryResult<ProductPluginRecord> {
        product.importLocalPlugin(root, scope)
    }

    public func importPluginSource(
        source: ProductPluginSourceRequest
    ): PluginRegistryResult<ProductPluginRecord> {
        product.importPluginSource(
            sessionId,
            source,
            approvalDecision: ApprovalDecision.Approve
        )
    }

    public func importPluginSource(
        source: ProductPluginSourceRequest,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        product.importPluginSource(
            sessionId,
            source,
            scope,
            approvalDecision: ApprovalDecision.Approve
        )
    }

    public func updatePluginSource(
        id: String,
        source: ProductPluginSourceRequest
    ): PluginRegistryResult<ProductPluginRecord> {
        product.updatePluginSource(
            id,
            sessionId,
            source,
            approvalDecision: ApprovalDecision.Approve
        )
    }

    public func updatePluginSource(
        id: String,
        source: ProductPluginSourceRequest,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        product.updatePluginSource(
            id,
            scope,
            sessionId,
            source,
            approvalDecision: ApprovalDecision.Approve
        )
    }

    public func setPluginEnabled(id: String, enabled: Bool): PluginRegistryResult<ProductPluginRecord> {
        product.setPluginEnabled(id, enabled)
    }

    public func setPluginEnabled(
        id: String,
        enabled: Bool,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        product.setPluginEnabled(id, enabled, scope)
    }

    public func pluginDoctor(custody!: ?OwnedApplicationRegistryResponse161 = None): Array<PluginRegistryOwnedError> {
        product.pluginDoctor(custody: custody)
    }
    public func updateLocalPlugin(id: String, root: String): PluginRegistryResult<ProductPluginRecord> {
        product.updateLocalPlugin(id, root)
    }

    public func rollbackPlugin(id: String): PluginRegistryResult<ProductPluginRecord> {
        product.rollbackPlugin(id)
    }

    public func uninstallPlugin(id: String): PluginRegistryResult<Unit> {
        product.uninstallPlugin(id)
    }

    public func updateLocalPlugin(
        id: String,
        root: String,
        scope: PluginInstallScope
    ): PluginRegistryResult<ProductPluginRecord> {
        product.updateLocalPlugin(id, root, scope)
    }

    public func rollbackPlugin(id: String, scope: PluginInstallScope): PluginRegistryResult<ProductPluginRecord> {
        product.rollbackPlugin(id, scope)
    }

    public func uninstallPlugin(id: String, scope: PluginInstallScope): PluginRegistryResult<Unit> {
        product.uninstallPlugin(id, scope)
    }

    public func garbageCollectPlugins(): PluginRegistryResult<OwnedRegistryTextList> {
        product.garbageCollectPlugins()
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

    public func todoPhases(): Result<Array<ProductTodoPhase>> {
        product.todoPhases(sessionId)
    }

    public func replaceTodoPhases(phases: Array<ProductTodoPhase>): Result<ApplicationResponse> {
        let target=todoSessionId()
        let selection=match(selectProductTodo(product,target)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let digest=match(product.todoDocumentDigest(target,selection)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        invokeTodoInput(selection,objectValue([ValueField("frontend_action",textValue("replace_phases")),
            ValueField("phases",encodeTodoPhases(phases)),ValueField("expected_digest",textValue(digest))]))
    }

    // The historical Unit API cannot report an uncommitted replacement as
    // success. The retained actual operation remains available to approval().
    public func setTodoPhases(phases: Array<ProductTodoPhase>): Result<Unit> {
        match(replaceTodoPhases(phases)){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(response)=>match(response.approval){
                case Some(request)=>Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                    "todo.approval_required","Todo replacement is awaiting document approval",
                    fields:[ErrorField("operation_id",request.operationId.value)]))
                case None=>Result.Ok(())}}
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

    public func setAutoRetry(enabled: Bool): Unit {
        product.setAutoRetry(enabled)
    }

    public func autoRetryEnabled(): Bool {
        product.autoRetryEnabled()
    }

    public func abortRetry(): Unit {
        match (currentRequestSnapshot()) {
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
        if (currentRequestSnapshot().isSome() || pendingApproval.isSome()) {
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
        currentModel = restored
        match(activateSession(value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(())
    }

    public func forkCurrent(): Result<SessionId> {
        let target = product.ids.nextSessionId()
        match (product.forkSession(sessionId, target)) {
            case Result.Ok(_) => match (product.setSessionModel(target, currentModel)) {
                case Result.Ok(_) =>
                    match(activateSession(target)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
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
        if (currentRequestSnapshot().isSome() || pendingApproval.isSome()) {
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
                match(activateSession(target)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(ApplicationBranchResult(target, text))
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func handoff(customInstructions!: String = ""): Result<ApplicationHandoffResult> {
        if (currentRequestSnapshot().isSome() || pendingApproval.isSome()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.session_busy",
                    "cannot hand off while an operation is active"
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
        let base = match (product.prepareRequest(
            prompt,
            sessionId: Some(temporary),
            modelOverride: currentModel,
            thinking: effectiveThinking(),
            userRequestedThinking: explicitRequestedThinking(),
            thinkingSource: requestedThinkingSource()
        )) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let request = handoffRunRequest(base)
        setCurrentRequest(Some(request))
        let outcome = try {
            this.startOwnedCheckpointApplication113(request, eventSink())
        } finally {
            setCurrentRequest(Option<AgentRunRequest>.None)
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
                match(activateSession(target)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(ApplicationHandoffResult(target, document))
            case Result.Err(error) => Result.Err(error)
        }
    }

    // The convenience API retains the actual native Direct owner. No process
    // reservation or service-startup approval can authorize this command.
    private func acquireBashInvocation(command: String, networkPolicy!: ?NetworkPolicy=None): Result<ProductNativeToolInvocation> {
        if(command.trimAscii()==""){
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,"application.bash_empty","bash command must not be empty"))}
        bashLock.lock()
        try{
            if(bashStarting || currentBashInvocation.isSome()){
                return Result.Err(AgentError(AgentErrorKind.Conflict,"application.bash_busy","bash command is already retained"))}
            bashStarting=true;bashCancellationRequested=false
        }finally{bashLock.unlock()}
        let target=id()
        let selected=product.acquireShellToolInvocation(target,networkPolicy:networkPolicy)
        bashLock.lock()
        try{
            bashStarting=false
            match(selected){
                case Result.Err(error)=>return Result.Err(error)
                case Result.Ok(value)=>
                    currentBashInvocation=Some(value)
                    if(bashCancellationRequested || id().value!=target.value){let _=value.cancel()}
                    Result.Ok(value)}
        }finally{bashLock.unlock()}
    }

    private func bashInvocation(): ?ProductNativeToolInvocation {
        bashLock.lock();try{currentBashInvocation}finally{bashLock.unlock()}
    }

    private func closeBashInvocation(actual: ProductNativeToolInvocation): Result<Unit> {
        match(actual.close()){
            case Result.Err(error)=>return Result.Err(error)
            case Result.Ok(_)=>()}
        bashLock.lock()
        try{
            if(currentBashInvocation.isSome() && refEq(currentBashInvocation.getOrThrow(),actual)){
                currentBashInvocation=None}
        }finally{bashLock.unlock()}
        Result.Ok(())
    }

    private func completedBashInvocation(actual: ProductNativeToolInvocation): Result<ProcessResult> {
        match(actual.approval()){
            case Some(approval)=>return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "application.bash_approval_required","the retained native command requires its own explicit decision",
                fields:[ErrorField("operation_id",approval.operationId.value),ErrorField("tool",approval.toolName)]))
            case None=>()}
        let result=match(actual.output()){
            case Result.Err(error)=>Result<ProcessResult>.Err(error)
            case Result.Ok(output)=>nativeShellProcessResult(output)}
        // Both success and execution error still own the actual output charge.
        // Failed cleanup keeps this same invocation reachable for a later ACK.
        match(closeBashInvocation(actual)){
            case Result.Err(error)=>return Result.Err(error)
            case Result.Ok(_)=>result}
    }

    private func executeAcquiredBash(arguments: AgentValue, actual: ProductNativeToolInvocation): Result<ProcessResult> {
        match(actual.start(arguments,
            ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1))){
            case Result.Err(error)=>actual.recordFailure(error)
            case Result.Ok(_)=>()}
        completedBashInvocation(actual)
    }

    public func executeBash(command: String, timeoutMillis!: Int64=10000,
        networkPolicy!: ?NetworkPolicy=None): Result<ProcessResult> {
        if(timeoutMillis<=0 || timeoutMillis>600000){
            return Result.Err(AgentError(AgentErrorKind.InvalidInput,"shell.invalid_timeout","native Shell command timeout must be 1..600000ms within the operator service ceilings"))}
        match(acquireBashInvocation(command,networkPolicy:networkPolicy)){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(actual)=>executeAcquiredBash(objectValue([
                ValueField("command",textValue(command)),ValueField("timeout_ms",integerValue(timeoutMillis))]),actual)}
    }

    public func executeBashAsync(command: String, complete: (Result<ProcessResult>) -> Unit): Result<Future<Unit>> {
        let actual=match(acquireBashInvocation(command)){
            case Result.Err(error)=>return Result.Err(error)
            case Result.Ok(value)=>value}
        // The actual owner is published before the task may start. Cancellation
        // never targets an unowned PID or a newly looked-up catalog descriptor.
        Result.Ok(spawn {
            let result=try{executeAcquiredBash(objectValue([ValueField("command",textValue(command)),ValueField("timeout_ms",integerValue(10000))]),actual)}catch(_:Exception){
                let error=AgentError(AgentErrorKind.RecoveryRequired,"application.bash_failed","native command retains canonical cleanup")
                actual.recordFailure(error)
                match(closeBashInvocation(actual)){
                    case Result.Err(closeError)=>Result<ProcessResult>.Err(closeError)
                    case Result.Ok(_)=>Result<ProcessResult>.Err(error)}}
            complete(result)
        })
    }

    private func decideBashInvocation(actual: ProductNativeToolInvocation, operationId: String,
        decision: ApprovalDecision): Result<ApplicationResponse> {
        let decided=actual.decide(operationId,decision)
        if(decided.isError() && actual.approval().isSome()){return Result.Err(decided.error().getOrThrow())}
        match(actual.approval()){
            case Some(value)=>return Result.Ok(ApplicationResponse(false,approval:Some(value)))
            case None=>()}
        match(completedBashInvocation(actual)){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(value)=>Result.Ok(ApplicationResponse(false,text:encodeAgentValue(objectValue([
                ValueField("stdout",textValue(value.stdout)),ValueField("stderr",textValue(value.stderr)),
                ValueField("exitCode",integerValue(value.exitCode)),ValueField("timedOut",boolValue(value.timedOut)),
                ValueField("workingDirectory",textValue(value.workingDirectory)),ValueField("truncated",boolValue(value.truncated))]))))}
    }

    public func abortBash(): Result<Unit> {
        bashLock.lock()
        let selected=try{bashCancellationRequested=true;currentBashInvocation}finally{bashLock.unlock()}
        match(selected){
            case None=>Result.Ok(())
            case Some(actual)=>
                match(actual.cancel()){
                    case Result.Err(error)=>return Result.Err(error)
                    case Result.Ok(_)=>()}
                closeBashInvocation(actual)}
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
        let guidance=match(activeWorkflowGuidance()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        product.dumpLlmRequest(
            sessionId,
            currentModel,
            effectiveThinking(),
            modeSystem: guidance.system,
            guide: guidance.guide,
            readOnly: planModeEnabled || vibeModeEnabled,
            workMode: workMode()
        )
    }

    public func frontendSlashDefinitions():Array<SlashCommandDefinition>{
        match(selectProductTodo(product,todoSessionId())){
            case Result.Ok(_)=>[productTodoSlashDefinition()]
            case Result.Err(_)=>[]}
    }

    public func todoMarkdown(): Result<String> {
        match(product.todoPhases(todoSessionId())){
            case Result.Err(error)=>Result.Err(error)
            case Result.Ok(phases)=>Result.Ok(productTodoDisplayMarkdown(phases))}
    }

    // Only opening an editor freezes its original native document digest.
    // Display refreshes cannot silently authorize an old buffer against a new revision.
    public func loadTodoEditor(): Result<String> {
        let result=readTodoMarkdown(true)
        if(result.isOk()){let _=takeTodoEditorCompletion()}
        result
    }

    private func readTodoMarkdown(forEditor: Bool): Result<String> {
        let selection=match(selectProductTodo(product,todoSessionId())){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let response=match(invokeTodoInput(selection,objectValue([ValueField("frontend_action",textValue("view"))]),editorAction:if(forEditor){"view"}else{""})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(response.approval.isSome()){return productTodoFrontendError("todo.view_approval_pending")}
        let shown=match(parseProductTodoFrontend(response.text,"view")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(forEditor){
            lock.lock();try{
                if(sessionId.value!=selection.session.value){return productTodoFrontendError("todo.session_changed")}
                todoEditorSnapshot=Some(ProductTodoEditorSnapshot(selection,httpIntentText(shown,"document_digest")))
            }finally{lock.unlock()}}
        Result.Ok(httpIntentText(shown,"markdown"))
    }

    public func replaceTodoMarkdown(markdown: String): Result<String> {
        lock.lock();let previous=try{todoEditorSnapshot}finally{lock.unlock()}
        let shown=match(previous){case None=>return productTodoFrontendError("todo.editor_read_required");case Some(value)=>value}
        if(shown.selection.session.value!=todoSessionId().value){return productTodoFrontendError("todo.session_changed")}
        match(shown.selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let response=match(invokeTodoInput(shown.selection,objectValue([ValueField("frontend_action",textValue("replace_markdown")),
            ValueField("text",textValue(markdown)),ValueField("expected_digest",textValue(shown.digest))]),editorAction:"replace_markdown")){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(response.approval.isSome()){return Result.Ok("Todo replacement is awaiting its document approval "+response.approval.getOrThrow().operationId.value)}
        let result=match(parseProductTodoFrontend(response.text,"replace_markdown")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        lock.lock();try{todoEditorSnapshot=Some(ProductTodoEditorSnapshot(shown.selection,httpIntentText(result,"document_digest")))}finally{lock.unlock()}
        let _=takeTodoEditorCompletion()
        Result.Ok("Saved the selected native Todo document.")
    }

    public func takeTodoEditorCompletion(): ?ProductTodoEditorCompletion {
        lock.lock();let selected=try{
            let value=(todoEditorCompletion,sessionId);todoEditorCompletion=None<ProductTodoEditorCompletion>;value
        }finally{lock.unlock()}
        match(selected[0]){
            case Some(value)=>if(value.current(selected[1]).isOk()){Some(value)}else{None<ProductTodoEditorCompletion>}
            case None=>None<ProductTodoEditorCompletion>}
    }

    private func todoSessionId(): SessionId {
        lock.lock();try{sessionId}finally{lock.unlock()}
    }

    private func invokeTodoInput(selection: ProductTodoSelection, input: AgentValue, editorAction!:String=""): Result<ApplicationResponse> {
        if(selection.session.value!=todoSessionId().value){return productTodoFrontendError("todo.session_changed")}
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock()
        try{
            if(sessionId.value!=selection.session.value){return productTodoFrontendError("todo.session_changed")}
            if(activeTodoSelection.isSome() || activeTodoInvocation.isSome() || activePluginCommandCancellation.isSome() || currentRequest.isSome() ||
                pendingApproval.isSome() || pendingRecovery.isSome()){
                return productTodoFrontendError("todo.session_busy")}
            activeTodoSelection=Some(selection)
            todoEditorCompletion=None<ProductTodoEditorCompletion>
        }finally{lock.unlock()}
        let cold: ?String=if(httpIntentText(input,"frontend_action")=="migrate"){
            Some(httpIntentText(input,"legacy_json"))}else{None}
        let invocation=ProductTodoInvocation(product,selection,"todo-"+takePluginCommandId(),{=>todoInvocationCurrent(selection,cold)})
        lock.lock();try{
            activeTodoInvocation=Some(invocation)
            if(editorAction!=""){
                todoEditorInvocation=Some(invocation);todoEditorAction=editorAction;todoEditorCompletion=None<ProductTodoEditorCompletion>}
        }finally{lock.unlock()}
        let result=invocation.start(input)
        if(result.isError()){
            let error=result.error().getOrThrow();let _=clearTodoDocument(invocation);return Result.Err(error)}
        todoDocumentResponse(invocation)
    }

    private func todoInvocationCurrent(selection: ProductTodoSelection,cold: ?String): Result<Unit> {
        match(todoDocumentCurrent(selection)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(cold){
            case Some(frozen)=>
                let actual=match(product.legacyTodoPayload(selection.session)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(actual!=frozen){return productTodoFrontendError("todo.migration_input_changed")}
            case None=>()}
        Result.Ok(())
    }
    private func todoDocumentCurrent(selection: ProductTodoSelection): Result<Unit> {
        lock.lock()
        let same=try{sessionId.value==selection.session.value && activeTodoSelection.isSome() &&
            refEq(activeTodoSelection.getOrThrow(),selection)}finally{lock.unlock()}
        if(!same){return productTodoFrontendError("todo.session_changed")}
        selection.current()
    }
    private func todoDocumentInvocation(): ?ProductTodoInvocation {
        lock.lock();try{activeTodoInvocation}finally{lock.unlock()}
    }
    private func clearTodoDocument(invocation: ProductTodoInvocation): Result<Unit> {
        // Retire the actual source owner only after its cleanup acknowledges.
        match(invocation.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock();try{
            if(activeTodoInvocation.isSome() && refEq(activeTodoInvocation.getOrThrow(),invocation)){
                activeTodoInvocation=None;activeTodoSelection=None}
            if(todoEditorInvocation.isSome() && refEq(todoEditorInvocation.getOrThrow(),invocation)){
                todoEditorInvocation=None<ProductTodoInvocation>;todoEditorAction=""}
            Result.Ok(())
        }finally{lock.unlock()}
    }
    private func todoDocumentResponse(invocation: ProductTodoInvocation): Result<ApplicationResponse> {
        match(invocation.approval()){
            case Some(approval)=>return Result.Ok(ApplicationResponse(false,text:"approval required",approval:Some(approval)))
            case None=>()}
        let output=invocation.output()
        match(output){
            case Result.Err(error)=>let _=clearTodoDocument(invocation);Result.Err(error)
            case Result.Ok(value)=>
                if(invocation.transferAction()!=""){
                    return Result.Ok(ApplicationResponse(false,text:value+"\nNo resource was accessed. Submit /todo resource to open its independent Root and review its own operation approval."))}
                lock.lock();let editor=try{
                    if(todoEditorInvocation.isSome() && refEq(todoEditorInvocation.getOrThrow(),invocation)){todoEditorAction}else{""}
                }finally{lock.unlock()}
                let presentation:?AgentValue=if(editor!=""){
                    match(parseProductTodoFrontend(value,editor)){case Result.Err(error)=>let _=clearTodoDocument(invocation);return Result.Err(error);case Result.Ok(parsed)=>Some(parsed)}
                }else{None<AgentValue>}
                match(presentation){case Some(shown)=>
                    match(invocation.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    lock.lock();try{
                        if(sessionId.value!=invocation.selection.session.value || activeTodoInvocation.isNone() ||
                            !refEq(activeTodoInvocation.getOrThrow(),invocation) || todoEditorInvocation.isNone() ||
                            !refEq(todoEditorInvocation.getOrThrow(),invocation)){
                            return productTodoFrontendError("todo.session_changed")}
                        // No later write can occupy the slot between retirement and publication.
                        activeTodoInvocation=None<ProductTodoInvocation>;activeTodoSelection=None<ProductTodoSelection>
                        todoEditorInvocation=None<ProductTodoInvocation>;todoEditorAction=""
                        todoEditorSnapshot=Some(ProductTodoEditorSnapshot(invocation.selection,httpIntentText(shown,"document_digest")))
                        todoEditorCompletion=Some(ProductTodoEditorCompletion(invocation,editor=="replace_markdown",httpIntentText(shown,"markdown"),httpIntentText(shown,"document_digest")))
                    }finally{lock.unlock()}
                    case None=>match(clearTodoDocument(invocation)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
                Result.Ok(ApplicationResponse(false,text:value))}
    }

    private func todoCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if(arguments.size==1 && arguments[0]=="resource"){return startTodoResource()}
        if(arguments.size==1 && arguments[0]=="commit"){return commitTodoImport()}
        let selection=match(selectProductTodo(product,todoSessionId())){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(!arguments.isEmpty() && ["import","export"].contains(arguments[0])){
            if(arguments.size>2){return productTodoFrontendError("todo.resource_arguments")}
            let target=if(arguments.size==1){"TODO.md"}else{arguments[1]}
            return invokeTodoInput(selection,objectValue([ValueField("frontend_action",textValue(arguments[0])),
                ValueField(if(arguments[0]=="import"){"reference"}else{"destination"},textValue(target))]))}
        if(arguments.size==1 && arguments[0]=="migrate"){
            let raw=match(product.legacyTodoPayload(selection.session)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            return invokeTodoInput(selection,objectValue([ValueField("frontend_action",textValue("migrate")),
                ValueField("legacy_json",textValue(raw)),ValueField("legacy_digest",textValue(modelPolicySha256Text(raw)))]))}
        let encoded=ArrayList<String>()
        for(argument in arguments){encoded.add(stringifyUnifiedJson(textValue(argument)))}
        var raw=""
        for(index in 0..encoded.size){if(index>0){raw+=" "};raw+=encoded[index]}
        invokeOwnedPluginCommand(selection.route,raw,{_,_=>()},todoSelection:Some(selection))
    }

    private func todoResourceInvocation(): ?ProductWorkspaceInvocation {
        lock.lock();try{activeTodoResource}finally{lock.unlock()}
    }
    private func startTodoResource(): Result<ApplicationResponse> {
        let parent=match(todoDocumentInvocation()){case None=>return productTodoFrontendError("todo.transfer_missing");case Some(value)=>value}
        match(todoDocumentCurrent(parent.selection)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let previous=todoResourceInvocation()
        let next=match(previous){case None=>parent.beginResource();case Some(value)=>value.beginResource()}
        let resource=match(next){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        lock.lock();try{
            match(previous){case Some(value)=>todoResourceAncestors.add(value);case None=>()}
            activeTodoResource=Some(resource)
        }finally{lock.unlock()}
        todoResourceResponse(parent,resource)
    }
    private func todoResourceResponse(parent: ProductTodoInvocation,resource: ProductWorkspaceInvocation): Result<ApplicationResponse> {
        match(resource.approval()){
            case Some(value)=>return Result.Ok(ApplicationResponse(false,text:"approval required",approval:Some(value)))
            case None=>()}
        let output=match(resource.output()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(parent.transferAction()=="import"){
            return Result.Ok(ApplicationResponse(false,text:stringifyUnifiedJson(output)+
                "\nIf this is a resource request, submit /todo resource again. A complete raw read may be submitted with /todo commit; this creates a distinct document Root and never inherits the resource permission."))}
        let text=stringifyUnifiedJson(output)
        match(clearTodoTransfer(parent)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(ApplicationResponse(false,text:text))
    }
    private func clearTodoTransfer(parent: ProductTodoInvocation): Result<Unit> {
        match(todoResourceInvocation()){
            case Some(value)=>match(value.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case None=>()}
        lock.lock();let ancestors=try{todoResourceAncestors.toArray()}finally{lock.unlock()}
        for(value in ancestors){match(value.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
        lock.lock();try{activeTodoResource=None;todoResourceAncestors.clear()}finally{lock.unlock()}
        match(cleanupRetiredTodoDocuments()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        clearTodoDocument(parent)
    }
    private func cleanupRetiredTodoDocuments(): Result<Unit> {
        lock.lock();let previous=try{todoRetiredDocuments.toArray()}finally{lock.unlock()}
        for(value in previous){
            match(value.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            lock.lock();try{
                var index:Int64=0
                while(index<todoRetiredDocuments.size){
                    if(refEq(todoRetiredDocuments[index],value)){todoRetiredDocuments.remove(at:index)}else{index+=1}}
            }finally{lock.unlock()}}
        Result.Ok(())
    }
    private func commitTodoImport(): Result<ApplicationResponse> {
        let parent=match(todoDocumentInvocation()){case None=>return productTodoFrontendError("todo.transfer_missing");case Some(value)=>value}
        let resource=match(todoResourceInvocation()){case None=>return productTodoFrontendError("todo.resource_read_required");case Some(value)=>value}
        match(todoDocumentCurrent(parent.selection)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let value=match(resource.output()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(result)=>result}
        let content=value.field("content") ?? nullValue()
        let truncated=value.field("truncated") ?? nullValue()
        if(content.unifiedKind!=ValueKind.Text || truncated.unifiedKind!=ValueKind.Boolean || truncated.asBool() ||
            value.field("returned_bytes").isNone() || value.field("bytes").isNone()){
            return productTodoFrontendError("todo.complete_raw_read_required")}
        let count=content.text.toArray().size
        let returned=try{Int64.parse(value.field("returned_bytes").getOrThrow().asNumberText())}catch(_:Exception){-1}
        let total=try{Int64.parse(value.field("bytes").getOrThrow().asNumberText())}catch(_:Exception){-1}
        if(count!=returned || returned!=total){return productTodoFrontendError("todo.complete_raw_read_required")}
        let digest=match(parent.importDigest()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(result)=>result}
        let input=objectValue([ValueField("frontend_action",textValue("replace_markdown")),ValueField("text",content),
            ValueField("expected_digest",textValue(digest))])
        // Keep both original charged results alive until the new ordinary
        // Root has frozen and copied its parameters. Its own ContextRead/CAS,
        // current tuple and approval are independent of those read Roots.
        let selection=parent.selection
        let next=ProductTodoInvocation(product,selection,"todo-"+takePluginCommandId(),{=>todoDocumentCurrent(selection)})
        lock.lock();try{
            todoRetiredDocuments.add(parent);activeTodoInvocation=Some(next)
        }finally{lock.unlock()}
        let result=next.start(input)
        match(resource.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock();let ancestors=try{todoResourceAncestors.toArray()}finally{lock.unlock()}
        for(value in ancestors){match(value.close()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
        lock.lock();try{activeTodoResource=None;todoResourceAncestors.clear()}finally{lock.unlock()}
        match(cleanupRetiredTodoDocuments()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(result){case Result.Err(error)=>let _=clearTodoDocument(next);Result.Err(error);case Result.Ok(_)=>todoDocumentResponse(next)}
    }

    public func approval(): ?ApprovalRequest {
        match(bashInvocation()){case Some(actual)=>match(actual.approval()){case Some(value)=>return Some(value);case None=>()};case None=>()}
        match(todoResourceInvocation()){
            case Some(value)=>match(value.approval()){case Some(request)=>return Some(request);case None=>()}
            case None=>()}
        match(todoDocumentInvocation()){case Some(value)=>return value.approval();case None=>()}
        match (pluginCommandControl()) { case Some(value) => return value.approval(); case None => () }
        pendingApproval
    }

    public func subscribe(sink: AgentEventSink): Unit {
        lock.lock()
        try {
            subscribers.add(sink)
            legacyEventSubscribers++
        } finally {
            lock.unlock()
        }
    }

    // Both callbacks belong to the same concrete observer. The ordinary
    // callback keeps existing small-event behavior; the owned callback must
    // explicitly retire the actual complete-result alias it receives.
    public func subscribeOwned(ordinary: AgentEventSink, owned: OwnedAgentEventSink,
        failures!: ?OwnedFailureEventSink113 = None<OwnedFailureEventSink113>): Unit {
        lock.lock()
        try { subscribers.add(ordinary); ownedSubscribers.add(owned); ownedFailureSubscribers113.add(failures) }
        finally { lock.unlock() }
    }

    public func subscribeRetirableOwned113(paid: LogicalJsonOwnerReservation,
        ordinary: AgentEventSink, owned: OwnedAgentEventSink,
        failures!: ?OwnedFailureEventSink113 = None<OwnedFailureEventSink113>): ApplicationOwnedSubscription113 {
        // Caller pays before constructing the callbacks supplied here.
        paid.ensureRetainedPeak(65536)
        lock.lock()
        try {
            if (unregisteredSubscription113.isSome() || retirableDispatchFrames113 != 0 || retirableCleanupFrames113 != 0) {
                throw IllegalStateException("an actual subscription registration or dispatch is still active")
            }
            let token = ApplicationOwnedSubscription113(paid, ordinary, owned, failures,
                subscribers.size, ownedSubscribers.size, ownedFailureSubscribers113.size)
            // A partial array/closure registration remains reachable here.
            // It is not claimed to have retired merely because add() throws.
            unregisteredSubscription113 = Some(token)
            subscribers.add({ event => token.emitOrdinary113(event) }); token.ordinaryInstalled = true
            ownedSubscribers.add(token); token.ownedInstalled = true
            ownedFailureSubscribers113.add(Some(token)); token.failureInstalled = true
            if (retirableSubscriptions113.isNone()) {
                retirableSubscriptions113 = Some(ArrayList<ApplicationOwnedSubscription113>())
            }
            retirableSubscriptions113.getOrThrow().add(token)
            unregisteredSubscription113 = None<ApplicationOwnedSubscription113>
            token
        } finally { lock.unlock() }
    }
    public func unsubscribeRetirableOwned113(token: ApplicationOwnedSubscription113): Bool {
        lock.lock()
        try {
            if (retirableDispatchFrames113 != 0 || retirableCleanupFrames113 != 0) { return false }
            match (unregisteredSubscription113) {
                case Some(_) =>
                    // A throwing array registration has no full helper-return
                    // witness. Its exact token/payment stays in this App slot.
                    return false
                case None => ()
            }
            match (retirableSubscriptions113) {
                case Some(actual) =>
                    for (index in 0..actual.size) {
                        if (refEq(actual[index], token)) {
                            if (!token.prepareAliasRemoval113()) { return false }
                            // Store the original token BEFORE fallible removal.
                            // Any throw keeps callbacks/payment reachable here.
                            unregisteredSubscription113 = Some(token)
                            removeRetirableAliasesLocked113(token)
                            actual.remove(at: index)
                            if (actual.isEmpty()) { retirableSubscriptions113 = None<ArrayList<ApplicationOwnedSubscription113>> }
                            token.commitAliasesRemoved113()
                            unregisteredSubscription113 = None<ApplicationOwnedSubscription113>
                            return true
                        }
                    }
                case None => ()
            }
            token.isRetired113()
        } finally { lock.unlock() }
    }
    private func removeRetirableAliasesLocked113(token: ApplicationOwnedSubscription113): Unit {
        if (token.failureInstalled) {
            ownedFailureSubscribers113.remove(at: token.failureIndex); token.failureInstalled = false
        }
        if (token.ownedInstalled) { ownedSubscribers.remove(at: token.ownedIndex); token.ownedInstalled = false }
        if (token.ordinaryInstalled) { subscribers.remove(at: token.ordinaryIndex); token.ordinaryInstalled = false }
        match (retirableSubscriptions113) {
            case Some(actual) => for (other in actual) {
                if (!refEq(other, token)) {
                    if (other.ownedIndex > token.ownedIndex) { other.ownedIndex-- }
                    if (other.failureIndex > token.failureIndex) { other.failureIndex-- }
                    if (other.ordinaryIndex > token.ordinaryIndex) { other.ordinaryIndex-- }
                }
            }
            case None => ()
        }
        match (unregisteredSubscription113) {
            case Some(other) => if (!refEq(other, token)) {
                if (other.ownedIndex > token.ownedIndex) { other.ownedIndex-- }
                if (other.failureIndex > token.failureIndex) { other.failureIndex-- }
                if (other.ordinaryIndex > token.ordinaryIndex) { other.ordinaryIndex-- }
            }
            case None => ()
        }
    }
    private func beginRetirableDispatch113(): ?ApplicationSubscriptionDispatchPayment113 {
        lock.lock()
        try {
            if (retirableDispatchFrames113 == Int64.Max) { throw IllegalStateException("subscription dispatch count overflow") }
            let count = subscriptionInvoiceAdd113(subscribers.size,
                subscriptionInvoiceAdd113(ownedSubscribers.size, ownedFailureSubscribers113.size))
            let peak = subscriptionInvoiceAdd113(8192, subscriptionInvoiceMultiply113(count, 512))
            let selected = match (retirableSubscriptions113) {
                case Some(actual) => if (actual.isEmpty()) { unregisteredSubscription113 } else { Some(actual[0]) }
                case None => unregisteredSubscription113
            }
            let payment = match (selected) {
                case Some(token) => Some(token.deriveDispatchPayment113(peak))
                case None => None<ApplicationSubscriptionDispatchPayment113>
            }
            retirableDispatchFrames113++
            payment
        } finally { lock.unlock() }
    }
    private func endRetirableDispatch113(paid: ?ApplicationSubscriptionDispatchPayment113): Unit {
        // The complete original dispatch helper and its copied target array
        // returned before this counter changes or this real child retires.
        lock.lock()
        try { retirableCleanupFrames113++; retirableDispatchFrames113-- }
        finally { lock.unlock() }
        try { retireSubscriptionDispatchHelper113(paid) }
        finally {
            lock.lock(); try { retirableCleanupFrames113-- } finally { lock.unlock() }
        }
    }
    private func retireSubscriptionDispatchHelper113(paid: ?ApplicationSubscriptionDispatchPayment113): Unit {
        match (paid) { case Some(actual) => actual.retireAfterHelper113(); case None => () }
    }

    public func ownedEventSink(): OwnedAgentEventSink {
        ApplicationOwnedEventSink113({ event => deliverOwnedEvent(event) },
            { value => deliverOwnedFailureEvent113(value) })
    }

    private func collectOwnedEventAcknowledgementsLocked(): Unit {
        var index: Int64 = 0
        while (index < pendingOwnedEvents.size) {
            if (pendingOwnedEvents[index].isAcknowledged()) { pendingOwnedEvents.remove(at: index) }
            else { index++ }
        }
    }
    private func deliverOwnedEvent(event: OwnedAgentEvent): Result<Unit> {
        let paid = beginRetirableDispatch113()
        try { deliverOwnedEventRetirableBody113(event) } finally { endRetirableDispatch113(paid) }
    }


    private func deliverOwnedEventRetirableBody113(event: OwnedAgentEvent): Result<Unit> {
        let targets = ArrayList<OwnedAgentEventSink>()
        lock.lock()
        try {
            collectOwnedEventAcknowledgementsLocked()
            // A failed writer/unknown observer remains in this actual Session.
            // A callback result or a new delivery never discards that debt.
            if (!pendingOwnedEvents.isEmpty()) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "event.delivery_ack_pending", "an actual event consumer has not retired its retained result")) }
            if (ownedSubscribers.size > (Int64.Max - 8192) / 256) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "event.delivery_size_overflow", "actual observer metadata extent cannot be represented")) }
            match (event.ensureAdditionalRetainedPeak(8192 + ownedSubscribers.size * 256)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            pendingOwnedEvents.add(event)
            if (legacyEventSubscribers != 0) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "event.observer_owned_contract_required", "a registered observer has no actual retained-result acknowledgement")) }
            for (observer in ownedSubscribers) { targets.add(observer) }
        } finally { lock.unlock() }
        for (observer in targets) {
            let child = match (event.fanout()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            lock.lock(); try { pendingOwnedEvents.add(child) } finally { lock.unlock() }
            match (observer.emit(child)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            if (!child.isAcknowledged()) {
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                    "event.delivery_ack_pending", "the actual observer still owns its complete-result alias")) }
        }
        match (event.closeAfterEventRetirement()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) =>
                lock.lock(); try { collectOwnedEventAcknowledgementsLocked() } finally { lock.unlock() }
                Result.Ok(()) }
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
                        InboxEntryId(queued.durableItemId)
                    )) {
                        case Result.Ok(_) =>
                            queuedInteractions.remove(at: index)
                            return Result.Ok(QueuedWithdrawal.Withdrawn(queued))
                        case Result.Err(error) => return Result.Err(error)
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

    // Optional DATA-only consumer preparation. Original queue/default APIs
    // stay unchanged. The callback receives only the selected UTF8 byte sum;
    // it cannot grant execution, persist a Source, or remove the entry itself.
    public func takeQueuedWithDataPayment113(result: Result<ApplicationResponse>,
        pay: (Int64) -> Result<Unit>): Result<?QueuedInteraction> {
        match (result) {
            case Result.Ok(response) => if (response.approval.isSome()) {
                return Result<?QueuedInteraction>.Ok(None<QueuedInteraction>) }
            case Result.Err(_) => ()
        }
        lock.lock()
        try {
            for (index in 0..queuedInteractions.size) {
                let next = queuedInteractions[index]
                if (next.kind != "steer" && next.kind != "follow_up") {
                    if (next.correlationId.size > Int64.Max - next.kind.size ||
                        next.correlationId.size + next.kind.size > Int64.Max - next.input.size) {
                        return Result<?QueuedInteraction>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                            "application.queued_data_extent_overflow", "queued data requires its paid consumer")) }
                    let bytes = next.correlationId.size + next.kind.size + next.input.size
                    match (pay(bytes)) {
                        case Result.Err(error) => return Result<?QueuedInteraction>.Err(error)
                        case Result.Ok(_) => () }
                    queuedInteractions.remove(at: index)
                    return Result<?QueuedInteraction>.Ok(Some(next))
                }
            }
            Result<?QueuedInteraction>.Ok(None<QueuedInteraction>)
        } finally { lock.unlock() }
    }

    // Only the RPC worker calls this after the complete handle/decide and
    // output helpers have returned. Core keeps its original same-Run follow-up
    // injection API; ordinary nextQueued never consumes those entries.
    public func takeRpcQueuedAtReturnedBoundaryWithDataPayment113(result: Result<ApplicationResponse>,
        pay: (Int64) -> Result<Unit>): Result<?QueuedInteraction> {
        match (result) {
            case Result.Ok(response) => if (response.approval.isSome()) {
                return Result<?QueuedInteraction>.Ok(None<QueuedInteraction>) }
            case Result.Err(_) => ()
        }
        lock.lock()
        try {
            collectOwnedFailureAcknowledgements113()
            let followUpBoundary = currentRequest.isNone() && !currentRequestCancelling &&
                pendingApproval.isNone() && pendingRecovery.isNone() &&
                !pendingModelResume && !pendingContextBoundaryResume &&
                pendingCheckpointSlot113.isNone() && pendingOwnedFailureEvents113.isEmpty()
            for (index in 0..queuedInteractions.size) {
                let next = queuedInteractions[index]
                if (next.kind != "steer" && (next.kind != "follow_up" || followUpBoundary)) {
                    if (next.correlationId.size > Int64.Max - next.kind.size ||
                        next.correlationId.size + next.kind.size > Int64.Max - next.input.size ||
                        next.correlationId.size + next.kind.size + next.input.size >
                            Int64.Max - next.durableItemId.size) {
                        return Result<?QueuedInteraction>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                            "application.queued_data_extent_overflow", "queued data requires its paid consumer")) }
                    // The exact queue object, including its durable identity,
                    // overlaps the old RPC prompt until the helper returns.
                    let bytes = next.correlationId.size + next.kind.size + next.input.size + next.durableItemId.size
                    match (pay(bytes)) {
                        case Result.Err(error) => return Result<?QueuedInteraction>.Err(error)
                        case Result.Ok(_) => () }
                    queuedInteractions.remove(at: index)
                    return Result<?QueuedInteraction>.Ok(Some(next))
                }
            }
            Result<?QueuedInteraction>.Ok(None<QueuedInteraction>)
        } finally { lock.unlock() }
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
            while (!queuedInteractions.isEmpty()) {
                let queued = queuedInteractions[0]
                match (product.vnext.rejectLaneInput(InboxEntryId(queued.durableItemId))) {
                    case Result.Ok(_) => queuedInteractions.remove(at: 0)
                    case Result.Err(error) =>
                        throw IllegalStateException(error.code + ": " + error.message)
                }
            }
        } finally {
            lock.unlock()
        }
    }

    private func reserveOwnedCheckpointSlot113(run: RunId): ?ApplicationOwnedCheckpointSlot113 {
        lock.lock()
        try {
            collectOwnedFailureAcknowledgements113()
            if (pendingCheckpointSlot113.isSome()) { return None<ApplicationOwnedCheckpointSlot113> }
            if (run.value.size > (Int64.Max - 16384) / 8) { return None<ApplicationOwnedCheckpointSlot113> }
            let paid = reserveNativeControlMetadata(16384 + run.value.size * 8)
            try {
                let slot = ApplicationOwnedCheckpointSlot113(run, paid)
                pendingCheckpointSlot113 = Some(slot)
                Some(slot)
            } catch (error: Exception) { paid.close(); throw error }
        } finally { lock.unlock() }
    }
    private func pendingCheckpointMarker113(): AgentError {
        lock.lock()
        try { match (pendingCheckpointSlot113) {
            case Some(slot) => slot.blockingMarker()
            case None => APPLICATION_OWNED_FAILURE_MARKER113 } }
        finally { lock.unlock() }
    }
    private func captureOwnedClientOutcome113(slot: ApplicationOwnedCheckpointSlot113,
        value: OwnedAgentRunResult113): Result<AgentRunOutcome> {
        lock.lock()
        try {
            match (pendingCheckpointSlot113) {
                case Some(current) => if (!refEq(current, slot)) {
                    throw IllegalStateException("reserved checkpoint slot identity changed") }
                case None => throw IllegalStateException("reserved checkpoint slot disappeared")
            }
            match (value) {
                case OwnedAgentRunResult113.Existing(original) =>
                    pendingCheckpointSlot113 = None<ApplicationOwnedCheckpointSlot113>
                    slot.retireMetadata(); return original
                case _ => match (slot.install(value)) {
                    case Result.Err(error) => return Result<AgentRunOutcome>.Err(error)
                    case Result.Ok(_) => () }
            }
            Result<AgentRunOutcome>.Err(slot.blockingMarker())
        } finally { lock.unlock() }
    }
    private func invokeOwnedCheckpointApplication113(run: RunId,
        invoke: () -> OwnedAgentRunResult113): Result<AgentRunOutcome> {
        let selected = try { reserveOwnedCheckpointSlot113(run) }
            catch (_: Exception) { return Result<AgentRunOutcome>.Err(APPLICATION_OWNED_FAILURE_MARKER113) }
        let slot = match (selected) {
            case Some(actual) => actual
            case None => return Result<AgentRunOutcome>.Err(pendingCheckpointMarker113()) }
        // The slot is already reserved under the Session lock; a concurrent
        // call cannot enter the real client or replace this invocation's data.
        let value = try { invoke() }
            catch (error: OwnedCanonicalPaidFailure113) { OwnedAgentRunResult113.Pending(error.takeConsumer()) }
            catch (_: Exception) { OwnedAgentRunResult113.Held }
        captureOwnedClientOutcome113(slot, value)
    }
    private func startOwnedCheckpointApplication113(request: AgentRunRequest, events: AgentEventSink): Result<AgentRunOutcome> {
        invokeOwnedCheckpointApplication113(request.runId,
            { => product.client.startOwnedCheckpointFailure113(request, events) })
    }
    private func resumeContextBoundaryOwnedCheckpointApplication113(request: AgentRunRequest,
        events: AgentEventSink): Result<AgentRunOutcome> {
        invokeOwnedCheckpointApplication113(request.runId,
            { => product.client.resumeContextBoundaryOwnedCheckpointFailure113(request, events) })
    }
    private func resumeOwnedCheckpointApplication113(request: AgentRunRequest, events: AgentEventSink): Result<AgentRunOutcome> {
        invokeOwnedCheckpointApplication113(request.runId,
            { => product.client.resumeOwnedCheckpointFailure113(request, events) })
    }
    private func decideOwnedCheckpointApplication113(request: AgentRunRequest, approval: ApprovalRequest,
        decision: ApprovalDecision, events: AgentEventSink): Result<AgentRunOutcome> {
        invokeOwnedCheckpointApplication113(request.runId,
            { => product.client.decideOwnedCheckpointFailure113(request, approval, decision, events) })
    }
    // The callback must register its actual paid delivery before true; on
    // false it retains no new alias. There is no ACK or raw error getter here.
    // A concurrent take/admit sees handingOff and cannot transfer twice.
    // Exact identity query only. No dynamic data copy, transfer or ACK.
    // A held or currently offered slot is still matched; an already moved
    // caller and fixed allocation-pressure metadata are not handoff keys.
    // The original reserved Session slot is the authority for this scalar
    // Run identity, including a Pending DATA caller without publication. Its
    // owner remains live under the SAME Session lock for this callback; no
    // Run alias may escape without the recipient first paying its own copy.
    public func withOwnedCheckpointRunIdentity113(marker: AgentError,
        consume: (RunId) -> Result<Unit>): Result<Bool> {
        lock.lock()
        try {
            let actual = match (pendingCheckpointSlot113) { case Some(value) => value; case None => return Result<Bool>.Ok(false) }
            if (!actual.matches(marker) || actual.isInvoking() || actual.isHandingOff()) { return Result<Bool>.Ok(false) }
            match (actual.withRunIdentity113(consume)) {
                case Result.Err(error) => Result<Bool>.Err(error)
                case Result.Ok(_) => Result<Bool>.Ok(true) }
        } finally { lock.unlock() }
    }

    public func hasOwnedCheckpointFailure113(marker: AgentError): Bool {
        if (product.hasOwnedMaintenanceFailure173(sessionId, marker)) { return true }
        lock.lock()
        try { match (pendingCheckpointSlot113) {
            case Some(slot) => slot.matches(marker) && !slot.isTransferred()
            case None => false } }
        finally { lock.unlock() }
    }
    public func admitOwnedCheckpointFailure113(marker: AgentError,
        accept: (OwnedAgentRunResult113) -> Bool): Bool {
        if (product.hasOwnedMaintenanceFailure173(sessionId, marker)) {
            return product.admitOwnedMaintenanceFailure173(sessionId, marker, accept) }
        var selected: ?ApplicationOwnedCheckpointSlot113 = None<ApplicationOwnedCheckpointSlot113>
        var offered: ?OwnedAgentRunResult113 = None<OwnedAgentRunResult113>
        lock.lock()
        try {
            match (pendingCheckpointSlot113) {
                case Some(slot) => if (slot.matches(marker)) {
                    offered = slot.beginHandoff(); if (offered.isSome()) { selected = Some(slot) } }
                case None => ()
            }
        } finally { lock.unlock() }
        if (selected.isNone()) { return false }
        var accepted = false
        try { accepted = accept(offered.getOrThrow()) }
        finally {
            lock.lock(); try { selected.getOrThrow().finishHandoff(accepted) } finally { lock.unlock() }
        }
        accepted
    }
    // Same reserved invocation and paid slot as the original admission.
    // A held poll only asks the real installed Core to refresh its existing
    // publication ACKs. It never starts/resumes/decides another execution.
    public func pollAndAdmitOwnedCheckpointFailure113(marker: AgentError,
        accept: (OwnedAgentRunResult113) -> Bool): Bool {
        collectOwnedCheckpointFailure113()
        if (product.hasOwnedMaintenanceFailure173(sessionId, marker)) {
            return product.admitOwnedMaintenanceFailure173(sessionId, marker, accept) }
        var selected: ?ApplicationOwnedCheckpointSlot113 = None<ApplicationOwnedCheckpointSlot113>
        lock.lock()
        try { match (pendingCheckpointSlot113) {
            case Some(slot) => if (slot.matches(marker) && slot.beginHeldPoll()) { selected = Some(slot) }
            case None => () } }
        finally { lock.unlock() }
        match (selected) {
            case Some(slot) =>
                // The handingOff flag keeps this real slot/run/owner alive
                // until the actual client call and all its frames return.
                let value = try { product.client.takeOwnedCheckpointFailure113(slot.getRunData113()) }
                    catch (failure: OwnedCanonicalPaidFailure113) { OwnedAgentRunResult113.Pending(failure.takeConsumer()) }
                    catch (_: Exception) { OwnedAgentRunResult113.Held }
                lock.lock()
                try {
                    match (pendingCheckpointSlot113) {
                        case Some(current) => if (!refEq(current, slot)) {
                            throw IllegalStateException("held checkpoint poll changed its reserved invocation") }
                        case None => throw IllegalStateException("held checkpoint poll lost its reserved invocation") }
                    if (!slot.isHandingOff() || slot.isTransferred() || !slot.isHeld()) {
                        throw IllegalStateException("held checkpoint poll changed its paid state") }
                    slot.finishHandoff(false)
                    match (value) {
                        case OwnedAgentRunResult113.Held => return false
                        case OwnedAgentRunResult113.Existing(_) => return false
                        case _ => let _ = slot.installHeldOutcome113(value)
                    }
                } finally { lock.unlock() }
            case None => () }
        // false or throw retains the actual installed value in this same
        // slot. This bool registers a consumer and never acknowledges one.
        admitOwnedCheckpointFailure113(marker, accept)
    }
    public func takeOwnedCheckpointFailure113(marker: AgentError): ?OwnedAgentRunResult113 {
        if (product.hasOwnedMaintenanceFailure173(sessionId, marker)) {
            return product.takeOwnedMaintenanceFailure173(sessionId, marker) }
        lock.lock()
        try {
            match (pendingCheckpointSlot113) {
                case Some(slot) => if (slot.matches(marker)) {
                    match (slot.beginHandoff()) {
                        case Some(value) => slot.finishHandoff(true); return Some(value)
                        case None => () }
                }
                case None => () }
            None<OwnedAgentRunResult113>
        } finally { lock.unlock() }
    }
    public func prepareOwnedCheckpointWave113(run: RunId,
        fund: (Int64)->Result<Unit>): (Bool, Int64, Int64) {
        match (fund(65536)) { case Result.Err(_) => return (false, 0, 0); case Result.Ok(_) => () }
        let events = ApplicationOwnedEventSink113({ event => deliverOwnedEvent(event) },
            { value => deliverOwnedFailureEvent113(value, waveRun113: Some(run)) })
        product.client.prepareOwnedCheckpointWave113(run, events: Some(events))
    }

    public func retireOwnedCheckpointProducerWitness113(run: RunId): Unit {
        product.client.retireOwnedCheckpointProducerWitness113(run)
    }

    public func takeOwnedCheckpointFailure113(run: RunId): OwnedAgentRunResult113 {
        collectOwnedCheckpointFailure113()
        var selected: ?ApplicationOwnedCheckpointSlot113 = None<ApplicationOwnedCheckpointSlot113>
        lock.lock()
        try {
            match (pendingCheckpointSlot113) {
                case Some(slot) => if (slot.matches(run)) {
                    if (slot.isInvoking() || slot.isHandingOff()) { return OwnedAgentRunResult113.Held }
                    if (!slot.isTransferred()) {
                        match (slot.beginHandoff()) {
                            case Some(value) => slot.finishHandoff(true); return value
                            case None =>
                                if (!slot.beginHeldPoll()) { return OwnedAgentRunResult113.Held }
                                selected = Some(slot)
                        }
                    }
                } else { return OwnedAgentRunResult113.Held }
                case None => ()
            }
        } finally { lock.unlock() }
        // Refresh actual Core ACK flags and a genuinely held outcome. This
        // polling path never invokes start/resume/decide or the observer again.
        let value = try { product.client.takeOwnedCheckpointFailure113(run) }
            catch (error: OwnedCanonicalPaidFailure113) { OwnedAgentRunResult113.Pending(error.takeConsumer()) }
            catch (_: Exception) { OwnedAgentRunResult113.Held }
        match (selected) {
            case Some(slot) =>
                lock.lock()
                try {
                    if (!slot.isTransferred() && slot.isHandingOff() && slot.isHeld()) {
                        slot.finishHandoff(false)
                        match (value) {
                            case OwnedAgentRunResult113.Existing(_) =>
                                pendingCheckpointSlot113 = None<ApplicationOwnedCheckpointSlot113>
                                slot.retireMetadata(); return value
                            case OwnedAgentRunResult113.Held => return value
                            case _ => match (slot.install(value)) {
                                case Result.Err(_) => return OwnedAgentRunResult113.Held
                                case Result.Ok(_) => () }
                        }
                        let actual = slot.beginHandoff().getOrThrow()
                        slot.finishHandoff(true); return actual
                    }
                    // A reserved held poll has no parallel caller admission.
                    throw IllegalStateException("held checkpoint poll changed identity")
                } finally { lock.unlock() }
            case None => value
        }
    }
    public func collectOwnedCheckpointFailure113(): Unit {
        product.collectOwnedMaintenanceFailures173()
        lock.lock(); try { collectOwnedFailureAcknowledgements113() } finally { lock.unlock() }
    }
    private func collectOwnedFailureAcknowledgements113(): Unit {
        var index: Int64 = 0
        while (index < pendingOwnedFailureEvents113.size) {
            let group = pendingOwnedFailureEvents113[index]
            let _ = group.settle()
            if (group.isRetired()) { pendingOwnedFailureEvents113.remove(at: index) }
            else { index++ }
        }
        match (pendingCheckpointSlot113) {
            case Some(slot) => if (slot.isConsumed()) {
                pendingCheckpointSlot113 = None<ApplicationOwnedCheckpointSlot113>
                slot.retireMetadata() }
            case None => ()
        }
    }
    private func acceptsOwnedCheckpointWave113(value: OwnedFailureRunPublication113, run: ?RunId): Bool {
        let actual = match (run) { case Some(selected) => selected; case None => return false }
        if (!value.matchesRun(actual)) { return false }
        for (group in pendingOwnedFailureEvents113) { if (!group.matchesRun113(actual)) { return false } }
        true
    }
    public func ownedCheckpointEventExpectation113(run: RunId, sequence: Int64): ?Bool {
        product.client.ownedCheckpointEventExpectation113(run, sequence)
    }

    private func deliverOwnedFailureEvent113(value: OwnedFailureRunPublication113,
        waveRun113!: ?RunId = None<RunId>): OwnedFailureEventAdmissionOutcome113 {
        let paid = beginRetirableDispatch113()
        try { deliverOwnedFailureEvent113RetirableBody113(value, waveRun113: waveRun113) } finally { endRetirableDispatch113(paid) }
    }

    private func deliverOwnedFailureEvent113RetirableBody113(value: OwnedFailureRunPublication113,
        waveRun113!: ?RunId = None<RunId>): OwnedFailureEventAdmissionOutcome113 {
        var targets: ?ArrayList<OwnedFailureEventAdmission113> = None<ArrayList<OwnedFailureEventAdmission113>>
        var selected: ?ApplicationOwnedFailureEventGroup113 = None<ApplicationOwnedFailureEventGroup113>
        lock.lock()
        try {
            collectOwnedFailureAcknowledgements113()
            if ((!pendingOwnedFailureEvents113.isEmpty() && !acceptsOwnedCheckpointWave113(value, waveRun113)) || legacyEventSubscribers != 0 ||
                ownedFailureSubscribers113.size != ownedSubscribers.size ||
                ownedFailureSubscribers113.size > (Int64.Max - 8192) / 512) {
                return OwnedFailureEventAdmissionOutcome113.Held }
            // Unknown sinks cannot admit this channel; no callback return,
            // thrown exception or error code is interpreted as acceptance.
            for (target in ownedFailureSubscribers113) {
                match (target) {
                    case Some(actual) => match (actual as OwnedFailureEventAdmission113) {
                        case None => return OwnedFailureEventAdmissionOutcome113.Held
                        case Some(_) => () }
                    case None => return OwnedFailureEventAdmissionOutcome113.Held }
            }
            let borrowed = value.withError({ _, fund => fund(coreOwnedWaveAppInvoice113(ownedFailureSubscribers113.size, pendingOwnedFailureEvents113.size, waveRun113.isSome())) })
            if (borrowed.isError()) { return OwnedFailureEventAdmissionOutcome113.Held }
            let actualTargets = ArrayList<OwnedFailureEventAdmission113>()
            for (target in ownedFailureSubscribers113) {
                actualTargets.add((target.getOrThrow() as OwnedFailureEventAdmission113).getOrThrow()) }
            targets = Some(actualTargets)
            let group = ApplicationOwnedFailureEventGroup113(value)
            selected = Some(group); pendingOwnedFailureEvents113.add(group)
        } finally { lock.unlock() }
        let group = selected.getOrThrow()
        for (target in targets.getOrThrow()) {
            let child = match (value.retainConsumer()) {
                case Result.Err(_) => return OwnedFailureEventAdmissionOutcome113.Held
                case Result.Ok(actual) => actual }
            group.add(child)
            let admitted = try { target.admitOwnedFailure113(child) }
                catch (_: Exception) { return OwnedFailureEventAdmissionOutcome113.Held }
            match (admitted) {
                case OwnedFailureEventAdmissionOutcome113.Accepted => ()
                case OwnedFailureEventAdmissionOutcome113.Failed(error) => return OwnedFailureEventAdmissionOutcome113.Failed(error)
                case OwnedFailureEventAdmissionOutcome113.Held => return OwnedFailureEventAdmissionOutcome113.Held }
        }
        group.finishDispatch()
        collectOwnedCheckpointFailure113()
        OwnedFailureEventAdmissionOutcome113.Accepted
    }

    // One original business implementation, with an explicit DATA payer.
    public func ownedRegistryCommand161(input: String): ?OwnedApplicationRegistryResponse161 {
        if (!productRegistryStartsWithSlash161(input)) { return None }
        let seed = plugins()
        let peak = if (input.size > (134217728 - 65536) / 64) {
            seed.close(); throw LogicalJsonPayloadError("registry response cannot fit the original shared capacity")
        } else { input.size * 64 + 65536 }
        let header = try { seed.deriveCopiedDataPayment(peak) } finally { seed.close() }
        let custody = OwnedApplicationRegistryResponse161(header, peak)
        var published = false
        try { published = prepareOwnedRegistryCommandFrame161(input, custody) }
        catch (error: LogicalJsonPayloadError) {
            // The entire private builder unwound before this known failure
            // can close unpublished DATA. No output or external response exists.
            custody.markProducerReturned161()
            custody.closeUnpublishedAfterBuilderReturned161()
            throw error
        }
        catch (error: Exception) { productRegistryHoldUnknownResponse161(custody); throw error }
        custody.markProducerReturned161()
        if (!published) { custody.closeUnpublishedAfterBuilderReturned161(); return None }
        Some(custody)
    }
    private func prepareOwnedRegistryCommandFrame161(input: String, custody: OwnedApplicationRegistryResponse161): Bool {
        match (router.route(input)) {
            case Result.Ok(RoutedInput.Command(ClientCommand.Builtin(name, arguments))) =>
                if (name != "plugins" && name != "extensions") { return false }
                if (!arguments.isEmpty() && arguments[0] == "service") { return false }
                custody.installResponse161(pluginsCommand(arguments, custody: Some(custody)))
                true
            case Result.Err(error) => custody.installResponse161(Result.Err(error)); true
            case _ => false
        }
    }

    // The caller pays before the borrowed current Session scalar is wrapped,
    // hashed or joined with the original queued identity. No Source is minted.
    public func prepareRpcQueuedInitiator113(value: QueuedInteraction,
        pay: (Int64) -> Result<Unit>): Result<QueuedRunInitiatorData113> {
        lock.lock()
        try {
            collectOwnedFailureAcknowledgements113()
            collectOwnedEventAcknowledgementsLocked()
            if (currentRequest.isSome() || currentRequestCancelling || pendingApproval.isSome() ||
                pendingRecovery.isSome() || pendingModelResume || pendingContextBoundaryResume ||
                pendingCheckpointSlot113.isSome() || !pendingOwnedFailureEvents113.isEmpty()) {
                return Result<QueuedRunInitiatorData113>.Err(AgentError(AgentErrorKind.Conflict,
                    "application.queued_boundary_changed", "the original returned RPC boundary changed")) }
            var bytes: Int64 = 0
            for (size in [sessionId.value.size, value.durableItemId.size, value.correlationId.size,
                value.kind.size, value.input.size]) {
                if (size > Int64.Max - bytes) { return Result<QueuedRunInitiatorData113>.Err(AgentError(
                    AgentErrorKind.RecoveryRequired, "application.queued_data_extent_overflow",
                    "queued data requires its paid consumer")) }
                bytes += size }
            match (pay(bytes)) { case Result.Err(error) => return Result<QueuedRunInitiatorData113>.Err(error)
                case Result.Ok(_) => () }
            let actual = QueuedRunInitiatorData113(InboxEntryId(value.durableItemId),
                ThreadId(sessionId.value), LaneId("main"), value.correlationId, value.kind, value.input)
            Result<QueuedRunInitiatorData113>.Ok(actual)
        } finally { lock.unlock() }
    }

    public func handleRpcQueuedAtReturnedBoundary113(value: QueuedInteraction,
        origin: QueuedRunInitiatorData113, allocate: (Int64) -> LogicalJsonOwnerReservation,
        capturePrimary: (AgentError) -> Unit, inputPayment: LogicalJsonOwnerReservation,
        retainStore: (RpcQueuedStoreFailure113) -> Unit): Result<ApplicationResponse> {
        if (value.durableItemId != origin.entryId.value || value.correlationId != origin.correlationId ||
            value.kind != origin.kind || value.input != origin.input || sessionId.value != origin.threadId.value) {
            let error = AgentError(AgentErrorKind.Conflict,
                "application.queued_origin_changed", "the queued input and actual Session no longer match")
            capturePrimary(error)
            return Result<ApplicationResponse>.Err(error) }
        // A prompt claims this exact row in the original canonical Turn TX.
        // A local command first reserves Processing, without a fake Step.
        let local = value.input.startsWith("/") || (planModeEnabled && isPlanApprovalPhrase(value.input))
        product.vnext.prepareActualRpcQueuedInput113(origin, local, allocate, retainStore)
        let result = if (local) { handle(value.input) } else {
            submit(value.input, queuedInitiator113: Some(origin), queuedInputPayment113: Some(inputPayment)) }
        match (result) {
            case Result.Err(error) =>
                if (hasOwnedCheckpointFailure113(error)) { return result }
                // Preserve all primary fields before a fallible settlement;
                // the caller's real same-bank node owns this independent share.
                capturePrimary(error)
            case Result.Ok(_) => () }
        product.vnext.completeReturnedRpcInput113(origin, local, result.isOk(), allocate, retainStore)
        result
    }

    // This query does not consume DATA. The original App aliases/true ACK
    // bookkeeping, and the actual persisted row, must BOTH be settled.
    public func rpcQueuedReferencesRetired113(origin: QueuedRunInitiatorData113,
        allocate: (Int64) -> LogicalJsonOwnerReservation,
        retainStore: (RpcQueuedStoreFailure113) -> Unit): Bool {
        lock.lock()
        try {
            collectOwnedFailureAcknowledgements113()
            collectOwnedEventAcknowledgementsLocked()
            match (currentRequest) {
                case Some(request) => match (request.queuedInitiator113) {
                    case Some(actual) => if (refEq(actual, origin)) { return false }
                    case None => () }
                case None => () }
            if (pendingCheckpointSlot113.isSome() || !pendingOwnedFailureEvents113.isEmpty()) { return false }
            product.vnext.actualRpcQueuedInputTerminal113(origin, allocate, retainStore)
        } finally { lock.unlock() }
    }

    public func handle(input: String): Result<ApplicationResponse> {
        let trimmed=input.trimAscii()
        if(trimmed=="/todo" || trimmed.startsWith("/todo ") || trimmed.startsWith("/todo\t") || trimmed.startsWith("/todo\n") || trimmed.startsWith("/todo\r")){
            let parsed=match(parseCommandInput(trimmed)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let arguments=ArrayList<String>()
            for(index in 1..parsed.tokens.size){arguments.add(parsed.tokens[index].value)}
            return todoCommand(arguments.toArray())
        }
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
        // Approving a displayed historical plan is a new frontend request.
        // Require a current actual selected contribution and a successful
        // canonical native plan before consuming Plan mode or human approval.
        let approvalGuidance=match(activeWorkflowGuidance()){
            case Result.Err(error)=>return PlanApprovalOutcome.NotConsumed(error);case Result.Ok(value)=>value}
        let review = match (latestPlanReview(true)) {
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
        match(approvalGuidance.validateCurrent()){
            case Result.Err(error)=>return PlanApprovalOutcome.NotConsumed(error);case Result.Ok(_)=>()}
        let currentBinding=product.vnext.publishedToolIdentity(approvalGuidance.planTool,
            threadId:Some(ThreadId(sessionId.value)))
        if(currentBinding.isNone() || currentBinding.getOrThrow().implementationVersion!=approvalGuidance.planVersion ||
            currentBinding.getOrThrow().implementationFingerprint!=approvalGuidance.planFingerprint){
            return PlanApprovalOutcome.NotConsumed(AgentError(AgentErrorKind.Conflict,
                "workflow.source_changed","selected plan contribution changed before approval was consumed"))}
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
        match(activateSession(target)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
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
        if (currentRequestSnapshot().isSome() || pendingApproval.isSome()) {
            return Result.Err(
                AgentError(
                    AgentErrorKind.Conflict,
                    "application.session_busy",
                    "cannot edit the plan while an operation is active"
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
        match(activeWorkflowGuidance()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(completedPlanCount(values,currentBinding:true)==0){return Result.Err(AgentError(
            AgentErrorKind.Conflict,"application.plan_approval_missing","No current completed native plan is available for editing."))}
        var targetIndex: Int64 = -1
        var index = values.size
        while (index > 0) {
            index -= 1
            if (planReviewContent(values[index], values, descriptiveHistory:false,currentBinding:true) != "") {
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
        let current = "Latest plan:\n\n" + planReviewContent(values[targetIndex], values,descriptiveHistory:false,currentBinding:true)
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

    public func submit(prompt: String, queuedInitiator113!: ?QueuedRunInitiatorData113 = None<QueuedRunInitiatorData113>,
        queuedInputPayment113!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>): Result<ApplicationResponse> {
        match (pendingRecovery) {
            case Some(error) => return Result.Err(error)
            case None => ()
        }
        if (pendingModelResume || pendingContextBoundaryResume) {
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
                case Result.Ok(values) => completedPlanCount(values)
                case Result.Err(error) => return Result.Err(error)
            }
        } else {
            0
        }
        planCorrectionAttempted = false
        let guidance=match(activeWorkflowGuidance()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let request = match (product.prepareRequest(
            prompt,
            sessionId: Some(match (queuedInitiator113) { case Some(value) => SessionId(value.threadId.value); case None => sessionId }),
            modelOverride: currentModel,
            thinking: effectiveThinking(),
            userRequestedThinking: explicitRequestedThinking(),
            thinkingSource: requestedThinkingSource(),
            interactions: Some(this),
            modeSystem: guidance.system,
            guide: guidance.guide,
            readOnly: planModeEnabled || vibeModeEnabled,
            queuedInitiator113: queuedInitiator113, queuedInputPayment113: queuedInputPayment113
        )) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        setCurrentRequest(Some(request))
        let clientResult = this.startOwnedCheckpointApplication113(request, eventSink())
        match (clientResult) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                setCurrentRequest(Option<AgentRunRequest>.None)
                finishCompletedRun(snapshot, true)
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, approval)) =>
                settleApproval(request, snapshot, approval, true)
            case Result.Err(error) =>
                setCurrentRequest(Option<AgentRunRequest>.None)
                Result.Err(error)
        }
    }

    public func decide(
        operationId: String,
        decision: ApprovalDecision
    ): Result<ApplicationResponse> {
        match(bashInvocation()){
            case Some(actual)=>match(actual.approval()){
                case Some(approval)=>if(approval.operationId.value==operationId){return decideBashInvocation(actual,operationId,decision)}
                case None=>()}
            case None=>()}
        match(todoResourceInvocation()){
            case Some(resource)=>
                let parent=match(todoDocumentInvocation()){case None=>return productTodoFrontendError("todo.transfer_missing");case Some(value)=>value}
                match(todoDocumentCurrent(parent.selection)){case Result.Err(error)=>let _=clearTodoTransfer(parent);return Result.Err(error);case Result.Ok(_)=>()}
                let result=resource.decide(operationId,decision)
                if(result.isError()){return Result.Err(result.error().getOrThrow())}
                return todoResourceResponse(parent,resource)
            case None=>()}
        match(todoDocumentInvocation()){
            case Some(invocation)=>
                let result=invocation.decide(operationId,decision)
                if(result.isError()){
                    let error=result.error().getOrThrow()
                    if(invocation.approval().isNone()){let _=clearTodoDocument(invocation)}
                    return Result.Err(error)}
                return todoDocumentResponse(invocation)
            case None=>()}
        match (pluginCommandControl()) {
            case Some(control) =>
                let result = control.decide(operationId, decision)
                finishPluginCommandControl(control)
                return result
            case None => ()
        }
        match (pendingRecovery) {
            case Some(error) => return Result.Err(error)
            case None => ()
        }
        let request = match (currentRequestSnapshot()) {
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
        match (this.decideOwnedCheckpointApplication113(
            request,
            sourced,
            decision,
            eventSink()
        )) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                setCurrentRequest(Option<AgentRunRequest>.None)
                pendingApproval = None
                finishCompletedRun(snapshot, false)
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, next)) => settleApproval(request, snapshot, next,
                false)
            case Result.Err(error) =>
                match (product.client.find(request.runId)) {
                    case Result.Ok(snapshot) => if (snapshot.status == RunState.WaitingApproval) {
                        pendingApproval = Some(approval)
                    } else {
                        setCurrentRequest(Option<AgentRunRequest>.None)
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
        lock.lock();try{todoEditorCompletion=None<ProductTodoEditorCompletion>}finally{lock.unlock()}
        match(todoDocumentInvocation()){
            case Some(invocation)=>match(clearTodoTransfer(invocation)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            case None=>()}
        lock.lock(); let startupTarget = try { sessionId } finally { lock.unlock() }
        cancelPluginServiceStartup(target: Some(startupTarget))
        match (cancelPluginCommandControl()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match(abortBash()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        revokePluginContinuation()
        if (isCompacting()) {
            match (product.cancelCompaction(sessionId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        lock.lock()
        let cancelling = try {
            currentRequestCancelling = currentRequest.isSome()
            currentRequest
        } finally { lock.unlock() }
        match (cancelling) {
            case Some(request) =>
                let _ = product.cancelApprovalReview(request.runId)
                match (product.client.cancel(request.runId)) {
                case Result.Ok(_) =>
                    setCurrentRequest(Option<AgentRunRequest>.None)
                    pendingApproval = None
                    Result.Ok(())
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
        previous: AgentRunRequest,
        snapshot: RunSnapshot,
        approval: ApprovalRequest,
        agentInvoked: Bool
    ): Result<ApplicationResponse> {
        // The returned card belongs to Core's latest sealed continuation, not
        // necessarily the context that the Application originally submitted.
        lock.lock()
        let request = try {
            if (!ownsApprovalRequest(previous)) { return staleApplicationApproval() }
            let refreshed = match (product.currentApprovalRequest(previous, snapshot, approval)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
            currentRequest = Some(refreshed)
            refreshed
        } finally { lock.unlock() }
        let mode = product.approvalSettings.mode
        if (mode == ApprovalRoutingMode.Manual) {
            match (publishPendingApproval(request, approval)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
            return approvalResponse(snapshot, approval, agentInvoked)
        }
        emitApprovalReviewEvent(snapshot, approval, "approval.reviewing", Option<ApprovalReview>.None)
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
                match (publishPendingApproval(request, reviewed)) {
                    case Result.Ok(_) => ()
                    case Result.Err(error) => return Result.Err(error)
                }
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

    // Called under the Application lock; reference identity also prevents an
    // older completion from overwriting a newly restored or switched request.
    private func ownsApprovalRequest(request: AgentRunRequest): Bool {
        !currentRequestCancelling && sessionId.value == request.sessionId.value &&
            match (currentRequest) { case Some(value) => refEq(value, request); case None => false }
    }

    private func publishPendingApproval(request: AgentRunRequest, approval: ApprovalRequest): Result<Unit> {
        lock.lock()
        try {
            if (!ownsApprovalRequest(request)) { return staleApplicationApproval() }
            match (product.persistPendingApproval(request, approval)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            pendingApproval = Some(approval)
            Result.Ok(())
        } finally { lock.unlock() }
    }

    private func continueAfterAutomaticDecision(
        request: AgentRunRequest,
        approval: ApprovalRequest,
        decision: ApprovalDecision,
        agentInvoked: Bool
    ): Result<ApplicationResponse> {
        lock.lock()
        let current = try { ownsApprovalRequest(request) } finally { lock.unlock() }
        if (!current) { return staleApplicationApproval() }
        match (this.decideOwnedCheckpointApplication113(request, approval, decision, eventSink())) {
            case Result.Ok(AgentRunOutcome.Completed(snapshot)) =>
                setCurrentRequest(Option<AgentRunRequest>.None)
                pendingApproval = None
                finishCompletedRun(snapshot, agentInvoked)
            case Result.Ok(AgentRunOutcome.AwaitingApproval(snapshot, next)) => settleApproval(request, snapshot, next,
                agentInvoked)
            case Result.Err(error) =>
                match (product.client.find(request.runId)) {
                    case Result.Ok(snapshot) => if (snapshot.status == RunState.WaitingApproval) {
                        pendingApproval = Some(approval)
                    } else {
                        setCurrentRequest(Option<AgentRunRequest>.None)
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
                currentModel = product.model
                match(activateSession(target)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                planModeEnabled = false
                vibeModeEnabled = false
                disableLoop()
                Result.Ok(target)
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func exitResponse(): Result<ApplicationResponse> {
        match (closePluginServices()) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => Result.Ok(ApplicationResponse(false, exitRequested: true))
        }
    }

    private func execute(command: ClientCommand): Result<ApplicationResponse> {
        match (command) {
            case ClientCommand.Help => Result.Ok(localResponse(commandHelp(frontendSlashDefinitions())))
            case ClientCommand.Exit => exitResponse()
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
            case "help" => Result.Ok(localResponse(commandHelp(frontendSlashDefinitions())))
            case "exit" | "quit" => exitResponse()
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
            case "goal" =>
                if (planModeEnabled) {
                    modeConflict("goal", "plan")
                } else if (vibeModeEnabled) {
                    modeConflict("goal", "vibe")
                } else {
                    goalCommand(joinCommandArguments(arguments))
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
            case "extensions" => pluginsCommand(arguments)
            case "plugins" => pluginsCommand(arguments)
            case "prompts" => promptsCommand(arguments)
            case "tree" => treeCommand(arguments)
            case "inspect" => inspectCommand(arguments)
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

    private func inspectCommand(arguments: Array<String>): Result<ApplicationResponse> {
        if (arguments.size > 2) { return invalidUsage("/inspect") }
        let runId = if (arguments.isEmpty()) {
            match (product.latestRunId(ThreadId(sessionId.value))) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        } else {
            RunId(arguments[0])
        }
        let beforeCursor = if (arguments.size < 2) {
            0
        } else {
            try {
                let value = Int64.parse(arguments[1])
                if (value < 0) { return invalidUsage("/inspect") }
                value
            } catch (_: Exception) {
                return invalidUsage("/inspect")
            }
        }
        match (product.runInspection(
            ThreadId(sessionId.value), runId, beforeCursor: beforeCursor, limit: 25
        )) {
            case Result.Ok(page) => Result.Ok(localResponse(renderRunInspection(page)))
            case Result.Err(error) => Result.Err(error)
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
        match(queryProductWorkflowGuidance(product,sessionId,"plan",product.toolsFor(
            CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),threadId:Some(ThreadId(sessionId.value))))){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>
                currentPlanTool=value.planTool;currentPlanVersion=value.planVersion;currentPlanFingerprint=value.planFingerprint}
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
        // Historical display remains available. A new approval requires a
        // current native binding and its exact successful canonical Receipt.
        if(requireStructured){
            match(activeWorkflowGuidance()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(completedPlanCount(values,currentBinding:true)==0){return Result.Ok(Option<String>.None)}
        }
        var index = values.size
        while (index > 0) {
            index -= 1
            let written = planReviewContent(values[index], values,descriptiveHistory:!requireStructured,currentBinding:requireStructured)
            if (written != "") {
                return Result.Ok(Some("Latest plan:\n\n" + written))
            }
        }
        if (requireStructured) {
            return Result.Ok(Option<String>.None)
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
        Result.Ok(Option<String>.None)
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
        match(queryProductWorkflowGuidance(product,sessionId,"vibe",product.toolsFor(
            CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),threadId:Some(ThreadId(sessionId.value))))){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
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
                    "- Ctrl+Z: suspend to the background\n" + "- Alt+L: reset the terminal display\n" +
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

    private func parsePluginSourceCommand(
        kindName: String,
        locator: String,
        pin: String,
        options: Array<String>
    ): PluginImportResult<ApplicationPluginSourceCommand> {
        let kind = match (kindName) {
            case "git" => PluginSourceKind.Git
            case "npm" => PluginSourceKind.Npm
            case _ => return pluginImportError("plugin.command_source_invalid", "source kind must be git or npm")
        }
        let isNpm = match (kind) {
            case PluginSourceKind.Npm => true
            case _ => false
        }
        var scope: ?PluginInstallScope = None
        var registryUrl = "https://registry.npmjs.org/"
        var registrySeen = false
        var index = 0
        while (index < options.size) {
            match (options[index]) {
                case "--scope" =>
                    if (scope.isSome() || index + 1 >= options.size) {
                        return pluginImportError("plugin.command_options_invalid", "scope must be specified once as user or workspace")
                    }
                    let parsedScope = match (options[index + 1]) {
                        case "user" => PluginInstallScope.User
                        case "workspace" => PluginInstallScope.Workspace
                        case _ => return pluginImportError("plugin.command_options_invalid", "scope must be user or workspace")
                    }
                    scope = Some(parsedScope)
                    index += 2
                case "--registry" =>
                    if (!isNpm || registrySeen || index + 1 >= options.size) {
                        return pluginImportError("plugin.command_options_invalid", "--registry is valid once for npm sources")
                    }
                    registryUrl = options[index + 1]
                    registrySeen = true
                    index += 2
                case _ => return pluginImportError("plugin.command_options_invalid", "unknown plugin source option: " + options[index])
            }
        }
        if (!isNpm) {
            PluginImportResult.Ok(ApplicationPluginSourceCommand(
                ProductPluginSourceRequest(kind, locator, revision: pin),
                scope
            ))
        } else {
            PluginImportResult.Ok(ApplicationPluginSourceCommand(
                ProductPluginSourceRequest(kind, locator, version: pin, registryUrl: registryUrl),
                scope
            ))
        }
    }

    private func pluginServiceCommand(arguments: Array<String>): Result<ApplicationResponse> {
        let usage = "/plugins service list | start <namespace> <service-id> <route> --approve | stop <namespace> <service-id>"
        if (arguments.size == 1 && arguments[0] == "list") {
            var text = "Session services:"
            let values = pluginServiceStatuses()
            if (values.isEmpty()) { text += "\nNo retained service instances in this Thread." }
            for (value in values) {
                text += "\n" + lifecycleText(value, "plugin") + " / " + lifecycleText(value, "service_id") +
                    " · " + lifecycleText(value, "state") + " · cleanup " +
                    (if (value.field("cleanup_acknowledged").getOrThrow().asBool()) { "acknowledged" } else { "retained" })
            }
            return Result.Ok(localResponse(text))
        }
        if (arguments.size >= 1 && arguments[0] == "start") {
            if (arguments.size != 4 && arguments.size != 5) { return invalidUsage(usage) }
            if (arguments.size == 5 && arguments[4] != "--approve") { return invalidUsage(usage) }
            match (startPluginService(arguments[1], arguments[2], arguments[3], approved: arguments.size == 5)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(ToolInvocationResult.Completed(value)) =>
                    if (value.isError) {
                        return Result.Err(AgentError(AgentErrorKind.Protocol, "plugin.service_start_failed",
                            "service startup failed; inspect its canonical Operation and Receipt"))
                    }
                    return Result.Ok(localResponse("Service started in this live session: " + arguments[1] + " / " + arguments[2]))
                case Result.Ok(_) => return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                    "plugin.service_start_not_completed", "service startup did not complete"))
            }
        }
        if (arguments.size == 3 && arguments[0] == "stop") {
            return match (stopPluginService(arguments[1], arguments[2])) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => Result.Ok(localResponse("Service stopped; cleanup acknowledged: " + arguments[1] + " / " + arguments[2]))
            }
        }
        invalidUsage(usage)
    }

    private func pluginsCommand(arguments: Array<String>, custody!: ?OwnedApplicationRegistryResponse161 = None): Result<ApplicationResponse> {
        if (!arguments.isEmpty() && arguments[0] == "service") { return pluginServiceCommand(arguments[1..]) }
        let usage = "/plugins [list|inspect <path> [--json]|import <path> [--scope user|workspace]|import git <locator> <commit> [--scope user|workspace]|import npm <name> <exact-version> [--registry <url>] [--scope user|workspace]|update <id> <path> [--scope user|workspace]|update <id> git <locator> <commit> [--scope user|workspace]|update <id> npm <name> <exact-version> [--registry <url>] [--scope user|workspace]|rollback <id> [--scope user|workspace]|uninstall <id> [--scope user|workspace]|enable <id> [--scope user|workspace]|disable <id> [--scope user|workspace]|doctor|gc|service list|service start <namespace> <service-id> <route> --approve|service stop <namespace> <service-id>]"
        if (arguments.isEmpty() || arguments[0] == "list") {
            if (arguments.size > 1) { return invalidUsage(usage) }
            let records = productRegistryRecords83(plugins(), custody: custody)
            var text = "Plugins:"
            if (records.isEmpty()) {
                text += "\nNo plugins are imported."
            } else {
                for (record in records) {
                    let sourceKind = match (record.sourceKind) {
                        case PluginSourceKind.Local => "local"
                        case PluginSourceKind.Git => "git"
                        case PluginSourceKind.Npm => "npm"
                    }
                    let scopeName = match (record.scope) {
                        case PluginInstallScope.User => "user"
                        case PluginInstallScope.Workspace => "workspace"
                    }
                    let sourceLock = match (record.sourceKind) {
                        case PluginSourceKind.Local => ""
                        case PluginSourceKind.Git => " · commit " + productRegistryCopyText83(record.copyText(PluginRecordText.RevisionLock), custody: custody)
                        case PluginSourceKind.Npm => " · version " + productRegistryCopyText83(record.copyText(PluginRecordText.VersionLock), custody: custody) + " · integrity " + productRegistryCopyText83(record.copyText(PluginRecordText.IntegrityLock), custody: custody)
                    }
                    text += "\n[" + (if (record.enabled) { "on" } else { "off" }) + "] " +
                        productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace), custody: custody) + "@" + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version), custody: custody) +
                        " · " + scopeName + " · " + sourceKind + " · sha256:" + productRegistryCopyText83(record.copyText(PluginRecordText.ContentLock), custody: custody) + " · " +
                        productRegistryCopyText83(record.copyText(PluginRecordText.Locator), custody: custody) + sourceLock
                }
            }
            let schemes = uriSchemes(custody: custody)
            if (schemes.isEmpty()) {
                text += "\nNo URI handlers are registered."
            } else {
                text += "\nRegistered URI schemes:"
                for (scheme in schemes) { text += " " + scheme }
            }
            return Result.Ok(localResponse(text))
        }
        let action = arguments[0]
        if (action == "inspect" && (arguments.size == 2 ||
            (arguments.size == 3 && arguments[2] == "--json"))) {
            match (inspectPlugin(arguments[1])) {
                case PluginRegistryResult.Ok(descriptor) =>
                    productRegistryKeepDescriptor161(descriptor, custody)
                    if (arguments.size == 3) {
                        return Result.Ok(localResponse(productRegistryCopyText83(descriptor.copyDiagnosticJson(), custody: custody)))
                    }
                    let family = match (descriptor.family) {
                        case PluginManifestFamily.Pi => "pi"
                        case PluginManifestFamily.Codex => "codex"
                        case PluginManifestFamily.Axyndra => "axyndra"
                    }
                    let ecosystem = match (descriptor.ecosystem) {
                        case PluginEcosystem.Pi => "pi"
                        case PluginEcosystem.Codex => "codex"
                        case PluginEcosystem.Axyndra => "axyndra"
                    }
                    var text = "Plugin " + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace), custody: custody) + " (" + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Id), custody: custody) + "@" + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Version), custody: custody) + ")"
                    text += "\nFamily: " + family + ", ecosystem: " + ecosystem
                    text += "\nCompatibility profile: " + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.CompatibilityProfile), custody: custody)
                    text += "\nEntry kind: " + pluginEntryKindName(descriptor.entryKind)
                    if (productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Entrypoint), custody: custody) != "") { text += "\nEntrypoint: " + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Entrypoint), custody: custody) }
                    text += "\nContributions:"
                    if (productRegistryContributions83(descriptor, custody: custody).isEmpty()) { text += " none declared" }
                    for (contribution in productRegistryContributions83(descriptor, custody: custody)) {
                        text += "\n- " + pluginContributionKindName(contribution.kind) + " " + productRegistryCopyText83(contribution.copyText(PluginContributionText.Name), custody: custody)
                    }
                    if (descriptor.entryKind == PluginEntryKind.LegacyProcess) {
                        text += "\nActivation: blocked; migrate legacy-process to native-executable"
                    }
                    text += "\nSource: " + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Source), custody: custody)
                    text += "\nDependencies:"
                    if (productRegistryDependencies83(descriptor, custody: custody).isEmpty()) { text += " none" }
                    for (dependency in productRegistryDependencies83(descriptor, custody: custody)) {
                        text += "\n- " + productRegistryCopyText83(dependency.copyText(PluginDependencyText.Name), custody: custody) + " " + productRegistryCopyText83(dependency.copyText(PluginDependencyText.VersionRange), custody: custody)
                        if (dependency.optional) { text += " (optional)" }
                        if (dependency.development) { text += " (development)" }
                    }
                    if (!productRegistryMissingDependencies83(descriptor, custody: custody).isEmpty()) {
                        text += "\nMissing required dependencies:"
                        for (dependency in productRegistryMissingDependencies83(descriptor, custody: custody)) { text += "\n- " + dependency }
                    }
                    if (!productRegistryCapabilities83(descriptor, custody: custody).isEmpty()) {
                        text += "\nRequested capabilities:"
                        for (capability in productRegistryCapabilities83(descriptor, custody: custody)) { text += "\n- " + capability }
                    }
                    if (productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.SdkRange), custody: custody) != "") { text += "\nSDK range: " + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.SdkRange), custody: custody) }
                    if (productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ProtocolRange), custody: custody) != "") { text += "\nProtocol range: " + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ProtocolRange), custody: custody) }
                    text += "\nComponents:"
                    for (component in productRegistryComponents83(descriptor, custody: custody)) {
                        let kind = match (component.kind) {
                            case PluginComponentKind.Skill => "skill"
                            case PluginComponentKind.Mcp => "mcp"
                            case PluginComponentKind.Prompt => "prompt"
                            case PluginComponentKind.Extension => "extension"
                            case PluginComponentKind.Hook => "hook"
                            case PluginComponentKind.Command => "command"
                            case PluginComponentKind.Theme => "theme"
                            case PluginComponentKind.HostedOnly => "hosted"
                        }
                        let status = match (component.status) {
                            case PluginComponentStatus.Supported => "supported"
                            case PluginComponentStatus.Blocked => "blocked"
                            case PluginComponentStatus.Unsupported => "unsupported"
                            case PluginComponentStatus.Unverified => "unverified"
                        }
                        text += "\n- " + kind + " " + productRegistryCopyText83(component.copyText(PluginComponentText.RelativePath), custody: custody) + " [" + status + "]"
                    }
                    return Result.Ok(localResponse(text))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody),
                        fields: [ErrorField("source", productRegistryErrorText83(error, PluginRegistryErrorText.Source, custody: custody)), ErrorField("field", productRegistryErrorText83(error, PluginRegistryErrorText.Field, custody: custody))]))
            }
        }
        if (action == "import" && arguments.size >= 4 &&
            (arguments[1] == "git" || arguments[1] == "npm")) {
            let parsed = match (parsePluginSourceCommand(
                arguments[1],
                arguments[2],
                arguments[3],
                arguments[4..]
            )) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) =>
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, error.message))
            }
            let imported = match (parsed.scope) {
                case Some(scope) => importPluginSource(parsed.source, scope)
                case None => importPluginSource(parsed.source)
            }
            match (imported) {
                case PluginRegistryResult.Ok(record) =>
                    let _ = productRegistryKeepRecord161(record, custody)
                    let pin = match (record.sourceKind) {
                        case PluginSourceKind.Git => " at commit " + productRegistryCopyText83(record.copyText(PluginRecordText.RevisionLock), custody: custody)
                        case PluginSourceKind.Npm => " at " + productRegistryCopyText83(record.copyText(PluginRecordText.VersionLock), custody: custody) + " (" + productRegistryCopyText83(record.copyText(PluginRecordText.IntegrityLock), custody: custody) + ")"
                        case PluginSourceKind.Local => ""
                    }
                    return Result.Ok(localResponse(
                        "Imported " + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Id), custody: custody) + "@" + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version), custody: custody) +
                            " from " + productRegistryCopyText83(record.copyText(PluginRecordText.Locator), custody: custody) + pin + " (disabled until enabled)."
                    ))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody)))
            }
        }
        if (action == "import" && (arguments.size == 2 ||
            (arguments.size == 4 && arguments[2] == "--scope"))) {
            let imported = if (arguments.size == 2) {
                importLocalPlugin(arguments[1])
            } else {
                match (arguments[3]) {
                    case "user" => importLocalPlugin(arguments[1], PluginInstallScope.User)
                    case "workspace" => importLocalPlugin(arguments[1], PluginInstallScope.Workspace)
                    case _ => return invalidUsage(usage)
                }
            }
            match (imported) {
                case PluginRegistryResult.Ok(record) =>
                    let _ = productRegistryKeepRecord161(record, custody)
                    let scopeName = match (record.scope) {
                        case PluginInstallScope.User => "user"
                        case PluginInstallScope.Workspace => "workspace"
                    }
                    return Result.Ok(localResponse("Imported " + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Id), custody: custody) + "@" + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version), custody: custody) +
                        " in " + scopeName + " scope (disabled until enabled)."))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody)))
            }
        }
        if (action == "update" && arguments.size >= 5 &&
            (arguments[2] == "git" || arguments[2] == "npm")) {
            let parsed = match (parsePluginSourceCommand(
                arguments[2],
                arguments[3],
                arguments[4],
                arguments[5..]
            )) {
                case PluginImportResult.Ok(value) => value
                case PluginImportResult.Err(error) =>
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, error.message))
            }
            let updated = match (parsed.scope) {
                case Some(scope) => updatePluginSource(arguments[1], parsed.source, scope)
                case None => updatePluginSource(arguments[1], parsed.source)
            }
            match (updated) {
                case PluginRegistryResult.Ok(record) =>
                    let _ = productRegistryKeepRecord161(record, custody)
                    let pin = match (record.sourceKind) {
                        case PluginSourceKind.Git => " at commit " + productRegistryCopyText83(record.copyText(PluginRecordText.RevisionLock), custody: custody)
                        case PluginSourceKind.Npm => " at " + productRegistryCopyText83(record.copyText(PluginRecordText.VersionLock), custody: custody) + " (" + productRegistryCopyText83(record.copyText(PluginRecordText.IntegrityLock), custody: custody) + ")"
                        case PluginSourceKind.Local => ""
                    }
                    return Result.Ok(localResponse(
                        "Updated " + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Id), custody: custody) + "@" + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version), custody: custody) +
                            " from " + productRegistryCopyText83(record.copyText(PluginRecordText.Locator), custody: custody) + pin + "."
                    ))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody)))
            }
        }
        if (action == "update" && (arguments.size == 3 ||
            (arguments.size == 5 && arguments[3] == "--scope"))) {
            let updated = if (arguments.size == 3) {
                updateLocalPlugin(arguments[1], arguments[2])
            } else {
                match (arguments[4]) {
                    case "user" => updateLocalPlugin(arguments[1], arguments[2], PluginInstallScope.User)
                    case "workspace" => updateLocalPlugin(arguments[1], arguments[2], PluginInstallScope.Workspace)
                    case _ => return invalidUsage(usage)
                }
            }
            match (updated) {
                case PluginRegistryResult.Ok(record) =>
                    let _ = productRegistryKeepRecord161(record, custody)
                    return Result.Ok(localResponse("Updated " + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Id), custody: custody) + "@" + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version), custody: custody) + "."))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody)))
            }
        }
        if (action == "rollback" && (arguments.size == 2 ||
            (arguments.size == 4 && arguments[2] == "--scope"))) {
            let rolledBack = if (arguments.size == 2) {
                rollbackPlugin(arguments[1])
            } else {
                match (arguments[3]) {
                    case "user" => rollbackPlugin(arguments[1], PluginInstallScope.User)
                    case "workspace" => rollbackPlugin(arguments[1], PluginInstallScope.Workspace)
                    case _ => return invalidUsage(usage)
                }
            }
            match (rolledBack) {
                case PluginRegistryResult.Ok(record) =>
                    let _ = productRegistryKeepRecord161(record, custody)
                    return Result.Ok(localResponse("Rolled back " + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Id), custody: custody) + "@" + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Version), custody: custody) + "."))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody)))
            }
        }
        if (action == "uninstall" && (arguments.size == 2 ||
            (arguments.size == 4 && arguments[2] == "--scope"))) {
            let uninstalled = if (arguments.size == 2) {
                uninstallPlugin(arguments[1])
            } else {
                match (arguments[3]) {
                    case "user" => uninstallPlugin(arguments[1], PluginInstallScope.User)
                    case "workspace" => uninstallPlugin(arguments[1], PluginInstallScope.Workspace)
                    case _ => return invalidUsage(usage)
                }
            }
            match (uninstalled) {
                case PluginRegistryResult.Ok(_) =>
                    return Result.Ok(localResponse("Uninstalled plugin " + arguments[1] + "."))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody)))
            }
        }
        if ((action == "enable" || action == "disable") && (arguments.size == 2 ||
            (arguments.size == 4 && arguments[2] == "--scope"))) {
            let enabled = action == "enable"
            let changed = if (arguments.size == 2) {
                setPluginEnabled(arguments[1], enabled)
            } else {
                match (arguments[3]) {
                    case "user" => setPluginEnabled(arguments[1], enabled, PluginInstallScope.User)
                    case "workspace" => setPluginEnabled(arguments[1], enabled, PluginInstallScope.Workspace)
                    case _ => return invalidUsage(usage)
                }
            }
            match (changed) {
                case PluginRegistryResult.Ok(record) =>
                    let _ = productRegistryKeepRecord161(record, custody)
                    return Result.Ok(localResponse("Plugin " + productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Id), custody: custody) + " is now " +
                        (if (record.enabled) { "enabled" } else { "disabled" }) + "."))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody)))
            }
        }
        if (action == "doctor" && arguments.size == 1) {
            let errors = pluginDoctor(custody: custody)
            var text = "Plugin doctor:"
            if (errors.isEmpty()) { text += "\nNo plugin issues detected." }
            for (error in errors) { text += "\n- " + error.code + ": " + productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody) }
            return Result.Ok(localResponse(text))
        }
        if (action == "gc" && arguments.size == 1) {
            match (garbageCollectPlugins()) {
                case PluginRegistryResult.Ok(paths) =>
                    productRegistryKeepTextList161(paths, custody)
                    return Result.Ok(localResponse("Garbage-collected " + paths.size.toString() + " plugin generations."))
                case PluginRegistryResult.Err(error) =>
                    productRegistryKeepError161(error, custody)
                    return Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, productRegistryErrorText83(error, PluginRegistryErrorText.Message, custody: custody)))
            }
        }
        invalidUsage(usage)
    }

    private func promptsCommand(arguments: Array<String>): Result<ApplicationResponse> {
        let usage = "/prompts [list|run <namespace/path> [arguments...]]"
        if (arguments.isEmpty() || arguments[0] == "list") {
            if (arguments.size > 1) { return invalidUsage(usage) }
            let names = product.pluginPromptTemplates()
            var text = "Prompt templates:"
            if (names.isEmpty()) {
                text += "\nNo enabled prompt templates."
            } else {
                for (name in names) { text += "\n- " + name }
            }
            return Result.Ok(localResponse(text))
        }
        if (arguments[0] != "run" || arguments.size < 2) { return invalidUsage(usage) }
        match (product.renderPluginPromptTemplate(arguments[1], arguments[2..])) {
            case PluginImportResult.Ok(prompt) => submit(prompt)
            case PluginImportResult.Err(error) =>
                Result.Err(AgentError(AgentErrorKind.InvalidInput, error.code, error.message))
        }
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
                    (match (currentRequestSnapshot()) {
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
            localResponse("settings: " + product.settingsRoot + "/config.yml" +
                " model=" + currentModel +
                " theme=" + theme +
                " shell.network_mode=" + shellNetworkModeName(product.shellNetworkMode) +
                " sandbox.ca_bundle=" + if (product.sandboxCaBundle == "") {
                    "(not set)"
                } else {
                    product.sandboxCaBundle
                })
        )
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
            case Result.Ok(removed) =>
                Result.Ok(localResponse("compacted messages: " + removed.toString()))
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
        { event =>
            let paid = beginRetirableDispatch113()
            try { invokeRetirableOrdinary113(event, paid) } finally { endRetirableDispatch113(paid) }
        }
    }
    private func invokeRetirableOrdinary113(event: AgentEvent, paid: ?ApplicationSubscriptionDispatchPayment113): Unit {
        eventSinkRetirableBody113(paid)(event)
    }
    


    private func eventSinkRetirableBody113(paid: ?ApplicationSubscriptionDispatchPayment113): AgentEventSink {
        {
            event =>
                let targets = ArrayList<AgentEventSink>()
                lock.lock()
                try {
                    match (paid) { case Some(actual) => actual.ensureBeforeSnapshot113(
                        subscriptionInvoiceAdd113(8192, subscriptionInvoiceMultiply113(subscribers.size, 512)))
                        case None => () }
                    for (subscriber in subscribers) {
                        targets.add(subscriber)
                    }
                } finally {
                    lock.unlock()
                }
                for (target in targets) { target(event) }
                let planEvent=planCompletionEvent(event,planHistoryTool())
                match(planEvent){case Some(value)=>for(target in targets){target(value)};case None=>()}
        }
    }

    // Presentation projection only; original generic Core event stays intact.
    private func planCompletionEvent(event: AgentEvent, name: String): ?AgentEvent {
        match(event.payload){case AgentEventPayload.Extension(AgentEventKind.Tool,detail)=>
            let selectedName=httpIntentText(detail,"name")
            if(httpIntentText(detail,"code")!="tool.execution_completed" || !(if(name!=""){selectedName==name}else{productPlanToolHistoryNameMatches205(product,selectedName)}) ||
                httpIntentText(detail,"receipt_id")=="" || detail.field("is_error").isNone() ||
                detail.field("is_error").getOrThrow().asBool()){return None}
            let arguments=match(product.vnext.completedDataToolArguments(ThreadId(sessionId.value),event.meta.runId,
                httpIntentText(detail,"receipt_id"),httpIntentText(detail,"call_id"),selectedName)){
                case Result.Err(_)=>return None;case Result.Ok(value)=>value}
            let body=httpIntentText(arguments,"content").trimAscii()
            if(body==""){return None}
            Some(AgentEvent(event.meta,AgentEventPayload.Extension(AgentEventKind.Transcript,objectValue([
                ValueField("code",textValue("plan.updated")),ValueField("id",textValue(httpIntentText(detail,"call_id"))),
                ValueField("body",textValue(body))]))))
            case _=>None}
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
            if (completedPlanCount(messages) <= planWriteBaseline) {
                if (planCorrectionAttempted) {
                    return Result.Err(missingPlanError())
                }
                planCorrectionAttempted = true
                let guidance=match(activeWorkflowGuidance()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                let correction = match (product.prepareRequest(
                    guidance.correction,
                    sessionId: Some(sessionId),
                    modelOverride: currentModel,
                    thinking: effectiveThinking(),
                    userRequestedThinking: explicitRequestedThinking(),
                    thinkingSource: requestedThinkingSource(),
                    interactions: Some(this),
                    modeSystem: guidance.system,
                    guide: guidance.guide,
                    readOnly: true
                )) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
                setCurrentRequest(Some(correction))
                match (this.startOwnedCheckpointApplication113(correction, eventSink())) {
                    case Result.Ok(AgentRunOutcome.Completed(next)) =>
                        setCurrentRequest(Option<AgentRunRequest>.None)
                        snapshot = next
                    case Result.Ok(AgentRunOutcome.AwaitingApproval(waiting, approval)) => return settleApproval(
                        correction,
                        waiting,
                        approval,
                        agentInvoked
                    )
                    case Result.Err(error) =>
                        setCurrentRequest(Option<AgentRunRequest>.None)
                        return Result.Err(error)
                }
                let correctedMessages = match (product.messages(sessionId)) {
                    case Result.Ok(values) => values
                    case Result.Err(error) => return Result.Err(error)
                }
                if (completedPlanCount(correctedMessages) <= planWriteBaseline) {
                    return Result.Err(missingPlanError())
                }
            }
            completedPlanReview = match (latestPlanReview(true)) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
        }
        while (true) {
            lock.lock()
            let pluginContinuation = try { (pluginContinuationControlled, activePluginContinuation) } finally { lock.unlock() }
            if (pluginContinuation[0]) {
                let owner = match (pluginContinuation[1]) { case Some(value) => value; case None => break }
                let guidance=match(activeWorkflowGuidance()){case Result.Err(error)=>owner.revoke();return Result.Err(error);case Result.Ok(value)=>value}
                let request = match (product.prepareRequest(owner.prompt, sessionId: Some(sessionId), modelOverride: currentModel,
                    thinking: effectiveThinking(), userRequestedThinking: explicitRequestedThinking(), thinkingSource: requestedThinkingSource(),
                    interactions: Some(this), modeSystem: guidance.system, readOnly: planModeEnabled || vibeModeEnabled)) {
                    case Result.Err(error) => owner.revoke(); return Result.Err(error); case Result.Ok(value) => value }
                let continuation = match (product.preparePluginContinuation(owner, request)) {
                    case Result.Err(error) =>
                        owner.revoke()
                        // Exhaustion/revocation/data changes stop future admission;
                        // they never rewrite the completed Run or mint a retry.
                        if (error.kind == AgentErrorKind.PermissionDenied) { break }
                        return Result.Err(error)
                    case Result.Ok(value) => value }
                setCurrentRequest(Some(request))
                let outcome = try { product.client.startContinuation(continuation, eventSink()) } finally { owner.releaseAdmission() }
                match (outcome) {
                    case Result.Ok(AgentRunOutcome.Completed(next)) => setCurrentRequest(Option<AgentRunRequest>.None); snapshot = next; continue
                    case Result.Ok(AgentRunOutcome.AwaitingApproval(waiting, approval)) => return settleApproval(request, waiting, approval, agentInvoked)
                    case Result.Err(error) => setCurrentRequest(Option<AgentRunRequest>.None); owner.revoke(); return Result.Err(error) }
            }
            // Only a retained actual user-approved PluginContinuationOwner
            // may admit another Run. A goal presentation is data only.
            break
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

    // New selected native plans are read only through their actual completed
    // canonical Receipt/result. Failed/unknown ToolCalls cannot satisfy Plan.
    // User review edits and legacy plan text remain descriptive history only.
    private func planReviewContent(message: ModelMessage, messages: Array<ModelMessage>,
        descriptiveHistory!: Bool = true, currentBinding!: Bool = false): String {
        if(message.role==ModelRole.User){return planWriteContent(message)}
        let name=planHistoryTool()
        var found=""
        for(block in message.blocks where block.kind==ModelBlockKind.ToolCall){
            if(descriptiveHistory && block.name=="plan_write") { found=planWriteContent(message) }
            else if((name!="" && block.name==name) || (name=="" && productPlanToolHistoryNameMatches205(product,block.name))){
                for(result in messages){
                    for(reply in result.blocks where reply.kind==ModelBlockKind.ToolResult &&
                        reply.callId==block.callId && reply.receiptId!="" && !reply.isError){
                        match(product.vnext.completedDataToolHistoryArguments(ThreadId(sessionId.value),
                            reply.receiptId,block.callId,block.name,version:if(currentBinding){currentPlanVersion}else{""},
                            fingerprint:if(currentBinding){currentPlanFingerprint}else{""})){
                            case Result.Ok(args)=>found=httpIntentText(args,"content").trimAscii()
                            case Result.Err(_)=>()
                        }
                    }
                }
            }
        }
        found
    }

    private func completedPlanCount(messages: Array<ModelMessage>,currentBinding!: Bool = false): Int64 {
        let name=planHistoryTool()
        var count:Int64=0
        for(message in messages){
            var selected=false
            for(block in message.blocks where block.kind==ModelBlockKind.ToolCall && ((name!="" && block.name==name) || (name=="" && productPlanToolHistoryNameMatches205(product,block.name)))){selected=true}
            if(selected && planReviewContent(message,messages,descriptiveHistory:false,currentBinding:currentBinding)!=""){count+=1}
        }
        count
    }

    private func planHistoryTool(): String {
        if(currentPlanTool!=""){return currentPlanTool}
        ""
    }

    private func activeWorkflowGuidance(): Result<ProductWorkflowGuidance> {
        let value=match(queryProductWorkflowGuidance(product,sessionId,workMode(),activeTools())){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(value.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(planModeEnabled){currentPlanTool=value.planTool;currentPlanVersion=value.planVersion;currentPlanFingerprint=value.planFingerprint}
        Result.Ok(value)
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

    private func nextCompactionSequence(): Int64 {
        lock.lock()
        try {
            compactionSequence += 1
            compactionSequence
        } finally {
            lock.unlock()
        }
    }

    private func emitCompactionEvents(report: ProductCompactionReport): Unit {
        if (report.removedMessages <= 0) {
            return
        }
        let runId = RunId("compaction-" + sessionId.value)
        let traceId = TraceId("compaction-" + sessionId.value)
        let sink = eventSink()
        sink(AgentEvent(
            EventMeta(
                nextCompactionSequence(),
                traceId,
                runId,
                occurredAtMillis: agentUtcMillis()
            ),
            AgentEventPayload.ContextCompacted(
                report.beforeTokens,
                report.afterTokens
            )
        ))
        if (report.summary != "") {
            sink(AgentEvent(
                EventMeta(
                    nextCompactionSequence(),
                    traceId,
                    runId,
                    occurredAtMillis: agentUtcMillis()
                ),
                AgentEventPayload.Extension(
                    AgentEventKind.Transcript,
                    objectValue([
                        ValueField("code", textValue("run.summary")),
                        ValueField("text", textValue(report.summary))
                    ])
                )
            ))
        }
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
        let result = try {
            product.compactSessionReport(sessionId, force: force)
        } finally {
            lock.lock()
            try {
                compacting = false
            } finally {
                lock.unlock()
            }
        }
        match (result) {
            case Result.Ok(report) =>
                emitCompactionEvents(report)
                Result.Ok(report.removedMessages)
            case Result.Err(error) => Result.Err(error)
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

// Descriptive parser for legacy plan history and explicit review edits.
// Current completion and approval use the actual canonical Receipt bridge.
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
        "Plan mode response did not produce a structured plan with the selected plan Tool after one corrective retry"
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
        contextSnapshot: base.contextSnapshot,
        contextWindow: base.contextWindow,
        providerSafetyMargin: base.providerSafetyMargin,
        executionLaneId: base.executionLaneId,
        ownedEvents: base.ownedEvents
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

func commandHelp(extraDefinitions:Array<SlashCommandDefinition>): String {
    var result = "Commands\n\n"
    result += "Type a command, or use Tab to complete it.\n"
    var group = ""
    for (command in presentedSlashCommandDefinitions(extraDefinitions)) {
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

func staleApplicationApproval<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Conflict, "application.approval_request_stale",
        "approval completion no longer belongs to the current Application request"))
}



private func coreOwnedWaveAppInvoice113(targets: Int64, groups: Int64, wave: Bool): Int64 {
    if (targets < 0 || groups < 0 || targets > (Int64.Max - 8192) / 512) {
        throw IllegalStateException("checkpoint target invoice overflow") }
    let amount = 8192 + targets * 512
    if (!wave) { return amount }
    if (groups > (Int64.Max - amount) / 512) { throw IllegalStateException("checkpoint pending group invoice overflow") }
    amount + groups * 512
}
