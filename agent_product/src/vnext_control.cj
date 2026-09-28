package agent_product

import yjson_support.*

import yjson.*

import std.collection.*
import std.convert.*
import std.fs.*
import std.sync.*
import agent_domain.*
import agent_extension_runtime.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import agent_skills.*
import tool_runtime.*
import model_adapters.*

func codexHookGrantAllows(event: String, capabilities: Array<String>): Bool {
    let workspaceWriteGranted = capabilities.contains("workspace.write")
    if (event == "PreToolUse") { return workspaceWriteGranted }
    event == "PostToolUse" && (workspaceWriteGranted || capabilities.contains("workspace.read"))
}

// Explicit product-facing control surface for vNext facilities that are not
// implicit in a normal AgentCore request. These APIs keep persistence and
// capability checks in the production composition root instead of requiring
// callers to assemble test-only stores and runtimes.
public class ProductVnextControl {
    private let database: SqliteDatabase
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let ids: ProductIds
    private let threadRuntimes: ThreadRuntimeRegistry
    private let operations: OperationRuntimePort
    private let askRuntime: AskRuntime
    private let workspaceRoot: String
    private let settingsRoot: String
    private let managedPluginPackageRoots: Array<String>
    private let extensionSignatureVerifier: ?ExtensionPackageSignatureVerifier
    private let javascriptPluginLifecycleLock = Mutex()
    public let storageService: ServiceRegistry<String>
    public let isolatedPlugins: ProductIsolatedPluginHost
    public let javascriptPlugins: ProductJavaScriptPluginHost

    init(
        database: SqliteDatabase,
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        ids: ProductIds,
        threadRuntimes: ThreadRuntimeRegistry,
        operations: OperationRuntimePort,
        askRuntime: AskRuntime,
        workspaceRoot: String,
        settingsRoot: String,
        processes: ProcessPort,
        javascriptPlugins: ProductJavaScriptPluginHost,
        extensionSignatureVerifier!: ?ExtensionPackageSignatureVerifier = None
    ) {
        this.database = database
        this.catalog = catalog
        this.pipeline = pipeline
        this.ids = ids
        this.threadRuntimes = threadRuntimes
        this.operations = operations
        this.askRuntime = askRuntime
        this.workspaceRoot = workspaceRoot
        this.settingsRoot = settingsRoot
        let packageRoots = ArrayList<String>()
        if (settingsRoot.trimAscii() != "") {
            packageRoots.add(settingsRoot + "/plugins/packages")
        }
        this.managedPluginPackageRoots = packageRoots.toArray()
        this.extensionSignatureVerifier = extensionSignatureVerifier
        isolatedPlugins = ProductIsolatedPluginHost(
            processes, workspaceRoot,
            managedPackageRoots: packageRoots.toArray()
        )
        this.javascriptPlugins = javascriptPlugins
        storageService = ServiceRegistry<String>(ServiceKey<String>(
            "SemanticStore", 1u32, RealmKind.Host
        ))
        let _ = storageService.bind(ProductStorageServiceProvider())
    }

    public func createSharedHistoryLane(lane: LaneRecord): Result<Unit> {
        SqliteLaneTreeStore(database).createLane(lane)
    }

    public func bindLaneItem(
        itemId: ItemId,
        threadId: ThreadId,
        laneId: LaneId,
        parentItemId: ItemId
    ): Result<Unit> {
        SqliteLaneTreeStore(database).bindItem(itemId, threadId, laneId, parentItemId)
    }

    public func laneBranch(threadId: ThreadId, laneId: LaneId): Result<Array<ItemId>> {
        SqliteLaneTreeStore(database).branchItemIds(threadId, laneId)
    }

    public func readyLanes(
        threadId: ThreadId,
        afterLaneId!: String = "",
        limit!: Int64 = 64
    ): Result<Array<LaneId>> {
        SqliteLaneTreeStore(database).readyLaneIds(
            threadId, afterLaneId: afterLaneId, limit: limit
        )
    }

    public func acquireLaneRun(
        threadId: ThreadId,
        laneId: LaneId,
        runId: RunId,
        ownerId: String,
        nowMillis: Int64,
        leaseMillis!: Int64 = 30000
    ): Result<LaneRunAdmission> {
        SqliteLaneTreeStore(database).acquireLaneRun(
            threadId, laneId, runId, ownerId, nowMillis, leaseMillis
        )
    }

    public func renewLaneRun(
        admission: LaneRunAdmission,
        nowMillis: Int64,
        leaseMillis!: Int64 = 30000
    ): Result<LaneRunAdmission> {
        SqliteLaneTreeStore(database).renewLaneRun(
            admission, nowMillis, leaseMillis
        )
    }

    public func releaseLaneRun(
        admission: LaneRunAdmission,
        releasedAtMillis: Int64
    ): Result<Unit> {
        SqliteLaneTreeStore(database).releaseLaneRun(
            admission, releasedAtMillis
        )
    }

    public func enqueueLaneInput(entry: DurableInboxEntry): Result<Unit> {
        match (threadRuntimes.acquire(entry.threadId, workspaceRoot)) {
            case Result.Ok(_) => match (SqliteInboxStepStore(database).enqueue(entry)) {
                case Result.Ok(_) => Result.Ok(())
                case Result.Err(error) => Result.Err(error)
            }
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func rejectLaneInput(entryId: InboxEntryId): Result<Unit> {
        SqliteInboxStepStore(database).rejectQueued(entryId)
    }

    public func pendingLaneInputs(
        threadId: ThreadId,
        laneId!: LaneId = LaneId("main")
    ): Result<Array<DurableInboxEntry>> {
        SqliteInboxStepStore(database).pendingQueued(threadId, laneId)
    }

    public func forkThread(
        sourceThreadId: ThreadId,
        sourceLaneId: LaneId,
        forkItemId: ItemId,
        targetThreadId: ThreadId,
        targetWorkspaceId: String,
        createdAtMillis: Int64
    ): Result<Array<ItemId>> {
        SqliteLaneTreeStore(database).forkThread(
            sourceThreadId, sourceLaneId, forkItemId,
            targetThreadId, targetWorkspaceId, createdAtMillis
        )
    }

    public func createTeam(team: TeamRecord): Result<Unit> {
        SqliteTeamStore(database).createTeam(team)
    }

    public func addTeamMember(member: TeamMemberRecord): Result<Unit> {
        SqliteTeamStore(database).addMember(member)
    }

    public func addTeamTask(task: TeamTaskRecord): Result<Unit> {
        SqliteTeamStore(database).addTask(task)
    }

    public func claimTeamTask(
        taskId: TeamTaskId,
        memberId: TeamMemberId,
        expectedRevision: Int64,
        updatedAtMillis: Int64
    ): Result<TeamTaskRecord> {
        SqliteTeamStore(database).claimTask(
            taskId, memberId, expectedRevision, updatedAtMillis
        )
    }

    public func settleTeamTask(
        taskId: TeamTaskId,
        expectedRevision: Int64,
        status: TeamTaskStatus,
        workDebtId: String,
        updatedAtMillis: Int64
    ): Result<TeamTaskRecord> {
        SqliteTeamStore(database).settleTask(
            taskId, expectedRevision, status, workDebtId, updatedAtMillis
        )
    }

    public func sendTeamMessage(message: TeamMessageRecord): Result<Unit> {
        SqliteTeamStore(database).send(message)
    }

    public func teamMailbox(
        teamId: TeamId,
        recipient: TeamMemberId
    ): Result<Array<TeamMessageRecord>> {
        SqliteTeamStore(database).mailbox(teamId, recipient)
    }

    public func teamRoster(teamId: TeamId): Result<Array<TeamMemberRecord>> {
        SqliteTeamStore(database).roster(teamId)
    }

    public func teamTaskBoard(teamId: TeamId): Result<Array<TeamTaskRecord>> {
        SqliteTeamStore(database).taskBoard(teamId)
    }

 
    // Direct SDK, CLI, MCP, and extension hosts enter the same canonical
    // Thread/Run boundary as trusted control requests.
    // They never hand a raw ToolCall to ToolPipeline without a committed canonical source item.
    public func executeCanonicalTool(
        sessionId: SessionId,
        capabilities: CapabilitySet,
        call: ToolCall,
        skillStack!: SkillStackSnapshot = SkillStackSnapshot([], []),
        runId!: ?RunId = None
    ): Result<ToolInvocationResult> {
        executeCanonicalToolWithDecision(
            sessionId, capabilities, call, skillStack, runId, None
        )
    }

    private func executeCanonicalToolWithDecision(
        sessionId: SessionId,
        capabilities: CapabilitySet,
        call: ToolCall,
        skillStack: SkillStackSnapshot,
        runId: ?RunId,
        approvalDecision: ?ApprovalDecision,
        executionRoot!: String = "",
        trustedControl!: Bool = false
    ): Result<ToolInvocationResult> {
        if (call.name == "run_program") {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "program.committed_root_required",
                "run_program requires a canonical committed model ToolCall"
            ))
        }
        let effectiveRunId = match (runId) {
            case Some(value) => value
            case None => ids.nextRunId()
        }
        let runtime = match (threadRuntimes.acquire(
            ThreadId(sessionId.value), workspaceRoot
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (runtime.startTurn(
            SemanticTurnId("direct-tool-turn-" + effectiveRunId.value),
            effectiveRunId,
            ItemId("direct-tool-input-" + effectiveRunId.value),
            ThreadItemContent.UserMessage([
                ThreadMessagePart.Text("direct tool: " + call.name)
            ]),
            directControlModelLane(effectiveRunId, capabilities),
            skillStack,
            createdAtMillis: agentUtcMillis(),
            runBudgetSnapshot: objectValue([
                ValueField("run_kind", textValue("direct_tool")),
                ValueField("read_only", boolValue(false))
            ])
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let invocationRoot = if (executionRoot.trimAscii() == "") {
            workspaceRoot
        } else {
            executionRoot
        }
        let execution = ProductTrustedControlToolExecutor(pipeline, operations, runtime).invoke(
            ToolInvocationContext(
                effectiveRunId,
                sessionId,
                capabilities,
                toolContext: productToolContext(invocationRoot),
                skills: skillStack,
                trustedControl: trustedControl
            ),
            call,
            approvalDecision: approvalDecision
        )
        let terminal = match (execution) {
            case Result.Ok(ToolInvocationResult.Completed(_)) => RunState.Completed
            case _ => RunState.Failed
        }
        match (runtime.finish(
            terminal, 1000,
            reason: if (terminal == RunState.Completed) {
                "direct tool completed"
            } else {
                "direct tool did not complete"
            }
        )) {
            case Result.Ok(_) => execution
            case Result.Err(error) => Result.Err(error)
        }
    }

    // Plugin acquisition is a trusted host request, not a PTC capability.
    // Keep it synchronous, require an explicit frozen network policy, and
    // require one-time user approval before entering canonical execution.
    func executePluginAcquisitionControl(
        sessionId: SessionId,
        capabilities: CapabilitySet,
        call: ToolCall,
        stageRoot: String,
        approvalDecision!: ApprovalDecision
    ): Result<ToolInvocationResult> {
        match (approvalDecision) {
            case ApprovalDecision.Approve => ()
            case _ => return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "plugin.acquisition_approval_required",
                "plugin acquisition requires one-time user approval"
            ))
        }
        if (call.name != "plugin_acquisition") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "plugin.acquisition_tool_invalid",
                "plugin acquisition control must use the prepared internal acquisition tool"
            ))
        }
        match (call.arguments.field("command")) {
            case Some(value) =>
                if (value.unifiedKind != ValueKind.Text || value.text.trimAscii() == "") {
                    return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "plugin.acquisition_command_invalid",
                        "plugin acquisition command must be a non-empty string"
                    ))
                }
            case None => return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "plugin.acquisition_command_invalid",
                "plugin acquisition command is required"
            ))
        }
        let networkValue = match (call.arguments.field("network")) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "plugin.acquisition_network_required",
                "plugin acquisition requires an explicit network policy"
            ))
        }
        // Denied is valid for cache-only/offline acquisition; absence is not.
        match (parseNetworkPolicy(networkValue)) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        for (name in ["async", "pty"]) {
            match (call.arguments.field(name)) {
                case Some(value) =>
                    if (value.unifiedKind != ValueKind.Boolean || value.asBool()) {
                        return Result.Err(AgentError(
                            AgentErrorKind.InvalidInput,
                            "plugin.acquisition_execution_mode_invalid",
                            "plugin acquisition must use synchronous non-PTY execution"
                        ))
                    }
                case None => ()
            }
        }
        let acquisitionRoot = match (productPluginAcquisitionRoot(settingsRoot, workspaceRoot)) {
            case PluginImportResult.Ok(value) => value
            case PluginImportResult.Err(error) => return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                error.code,
                error.message
            ))
        }
        let normalizedStage = Path(stageRoot).normalize().toString()
        if (!normalizedStage.startsWith(acquisitionRoot + "/")) {
            return Result.Err(AgentError(
                AgentErrorKind.PermissionDenied,
                "plugin.acquisition_stage_unbound",
                "plugin acquisition stage is outside host-owned storage"
            ))
        }
        executeCanonicalToolWithDecision(
            sessionId,
            capabilities,
            call,
            SkillStackSnapshot([], []),
            None,
            Some(approvalDecision),
            executionRoot: acquisitionRoot,
            trustedControl: true
        )
    }
    public func discardInactiveThread(sessionId: SessionId): Result<Bool> {
        threadRuntimes.discardInactive(ThreadId(sessionId.value))
    }


    public func routeRemote(
        router: RemoteExecutionRouter,
        envelope: SignedRemoteCapabilityEnvelope,
        request: RemoteExecutionRequest,
        nowMillis: Int64
    ): Result<AgentValue> {
        if (request.operationId.value.trimAscii() == "" ||
            envelope.runId.value.trimAscii() == "") {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "remote.operation_identity_invalid",
                "remote dispatch requires a durable Operation identity"
            ))
        }
        let source = database.query(
            "SELECT runs.thread_id,operations.tool_call_item_id,items.payload," +
                "effect.reserved_result_item_id,effect.reserved_receipt_id " +
                "FROM operations JOIN runs ON runs.id=operations.run_id " +
                "JOIN items ON items.id=operations.tool_call_item_id " +
                "JOIN operation_effect_records effect ON effect.operation_id=operations.id " +
                "WHERE operations.id=? AND operations.run_id=? AND operations.state='prepared'",
            [
                SqlParameter.Text(request.operationId.value),
                SqlParameter.Text(envelope.runId.value)
            ]
        )
        if (source.size != 1) {
            return Result.Err(AgentError(
                AgentErrorKind.Conflict,
                "remote.operation_not_prepared",
                "remote dispatch requires one prepared durable Operation"
            ))
        }
        let callId = match (decodeStoredThreadContent(source[0].required(2))) {
            case ThreadItemContent.ToolCall(value, _, _) => value
            case _ => return Result.Err(AgentError(
                AgentErrorKind.RecoveryRequired,
                "remote.operation_source_invalid",
                "remote Operation source is not a canonical ToolCall"
            ))
        }
        let plan = match (operations.loadPlan(request.operationId, envelope.runId)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (operations.markExecuting(
            request.operationId, envelope.runId, plan, nowMillis, false
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let threadId = ThreadId(source[0].required(0))
        match (operations.markExecutionHandoff(
            request.operationId, envelope.runId, threadId, nowMillis
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let dispatch = router.route(envelope, request, nowMillis)
        let invocation: Result<ToolInvocationResult> = match (dispatch) {
            case Result.Ok(value) => Result.Ok(ToolInvocationResult.Completed(ToolResult(
                callId.value, value, receiptId: source[0].required(4)
            )))
            case Result.Err(error) => Result.Err(error)
        }
        let runtime = match (threadRuntimes.acquire(threadId, workspaceRoot)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        match (runtime.resolveOperation(
            ItemId(source[0].required(3)), request.operationId, callId, plan,
            OperationAttemptStage.Executing, invocation, source[0].required(4), nowMillis
        )) {
            case Result.Ok(_) => dispatch
            case Result.Err(error) => Result.Err(error)
        }
    }

    public func validateIsolatedExtension(
        manifest: SignedExtensionPackageManifest,
        executionKind: ExtensionExecutionKind,
        generation: UInt64,
        capabilityCeiling: Array<String>
    ): SafeLifecycleResult<IsolatedPluginLaunchRequest> {
        match (extensionSignatureVerifier) {
            case Some(verifier) => validateIsolatedPluginPackage(
                manifest, executionKind, generation, capabilityCeiling, verifier
            )
            case None => SafeLifecycleResult.Err(
                "extension signature trust root is not configured"
            )
        }
    }

    private func isManagedPluginSnapshot(root: String): Bool {
        let info = try { FileInfo(Path(root)) } catch (_: Exception) { return false }
        if (!info.isDirectory() || info.isSymbolicLink()) { return false }
        let canonicalRoot = try { canonicalize(Path(root)).toString() } catch (_: Exception) { return false }
        for (packageRoot in managedPluginPackageRoots) {
            let packageInfo = try { FileInfo(Path(packageRoot)) } catch (_: Exception) { continue }
            if (!packageInfo.isDirectory() || packageInfo.isSymbolicLink()) { continue }
            let canonicalPackageRoot = try {
                canonicalize(Path(packageRoot)).toString()
            } catch (_: Exception) {
                continue
            }
            if (canonicalRoot.startsWith(canonicalPackageRoot + "/")) { return true }
        }
        false
    }

    public func activateImportedPlugin(record: ProductPluginRecord): Result<Unit> {
        let descriptor = record.descriptor
        if (descriptor.ecosystem == PluginEcosystem.Pi ||
            descriptor.ecosystem == PluginEcosystem.Codex) {
            let root = descriptor.root.trimAscii()
            if (!isManagedPluginSnapshot(root)) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.root_outside_managed_store",
                    "Pi and Codex plugin snapshots must remain inside managed package storage"
                ))
            }
            if (descriptor.ecosystem == PluginEcosystem.Codex) {
                let handlers = ArrayList<ToolHookHandlerSnapshot>()
                for (declaration in descriptor.hookDeclarations) {
                    if (!codexHookGrantAllows(
                        declaration.event, descriptor.requestedCapabilities
                    )) { continue }
                    handlers.add(ToolHookHandlerSnapshot(
                        declaration.event,
                        descriptor.namespace,
                        descriptor.version,
                        descriptor.contentDigest,
                        root,
                        declaration.matcher,
                        declaration.command,
                        declaration.timeoutMillis
                    ))
                }
                match (catalog.registerHookHandlers(
                    descriptor.namespace, handlers.toArray()
                )) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => ()
                }
            }
            if (descriptor.entrypoint.trimAscii() == "") { return Result.Ok(()) }
            javascriptPluginLifecycleLock.lock()
            try {
                match (mountAndRegisterJavaScriptPlugin(
                    record,
                    javascriptPlugins,
                    catalog,
                    serviceRuntime: Some(ProductJavaScriptPluginServiceRuntime(catalog, pipeline, operations, askRuntime))
                )) {
                    case Result.Ok(_) => Result.Ok(())
                    case Result.Err(error) =>
                        let _ = catalog.unregisterHookHandlers(descriptor.namespace)
                        return Result.Err(error)
                }
            } finally {
                javascriptPluginLifecycleLock.unlock()
            }
        }
        if (descriptor.ecosystem != PluginEcosystem.Axyndra) {
            return Result.Ok(())
        }
        activateAxyndraImportedPlugin(record, false)
    }

    func restoreImportedPlugin(record: ProductPluginRecord): Result<Unit> {
        if (record.descriptor.ecosystem != PluginEcosystem.Axyndra) {
            return activateImportedPlugin(record)
        }
        activateAxyndraImportedPlugin(record, true)
    }

    private func activateAxyndraImportedPlugin(
        record: ProductPluginRecord,
        restoreExisting: Bool
    ): Result<Unit> {
        let descriptor = record.descriptor
        let root = descriptor.root.trimAscii()
        if (!isManagedPluginSnapshot(root)) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.root_outside_managed_store",
                "executable plugin snapshots must remain inside managed package storage"
            ))
        }
        for (capability in descriptor.requestedCapabilities) {
            if (capability != "workspace.read" && capability != "workspace.write" &&
                !capability.startsWith("network.access:")) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.capability_unsupported",
                    "executable plugin capability is outside the product ceiling"
                ))
            }
        }
        let manifest = SignedExtensionPackageManifest(
            descriptor.id,
            descriptor.version,
            if (descriptor.sdkRange == "") { "1.x" } else { descriptor.sdkRange },
            descriptor.protocolRange,
            descriptor.entrypoint,
            [],
            [],
            descriptor.requestedCapabilities,
            1u32,
            "restart-safe",
            descriptor.contentDigest,
            descriptor.signature
        )
        let launch = match (extensionSignatureVerifier) {
            case Some(verifier) => match (validateIsolatedPluginPackage(
                manifest,
                ExtensionExecutionKind.ProcessPlugin,
                1u64,
                descriptor.requestedCapabilities,
                verifier,
                packageRoot: root
            )) {
                case SafeLifecycleResult.Ok(value) => value
                case SafeLifecycleResult.Err(message) => return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.activation_rejected",
                    message
                ))
            }
            case None => return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.signature_trust_root_missing",
                "executable plugin activation requires a configured signature trust root"
            ))
        }
        let networkPolicy = match (isolatedPluginNetworkPolicy(launch)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let additionalCapabilities = isolatedPluginToolCapabilities(launch)
        let toolName = "plugin." + descriptor.namespace + ".invoke"
        let registered = catalog.register(
            ToolDescriptor(
                ModelToolDefinition(
                    toolName,
                    "Invoke isolated plugin " + descriptor.namespace,
                    objectValue([ValueField("type", textValue("object"))])
                ),
                Capability(CapabilityKind.ExtensionInvoke),
                sideEffecting: true,
                implementationVersion: descriptor.version,
                additionalCapabilities: additionalCapabilities,
                networkPolicyResolver: Some({_ => Result.Ok(networkPolicy)}),
                implementationFingerprint: descriptor.namespace + ":" + descriptor.contentDigest
            ),
            ProductPluginToolExecutor(isolatedPlugins, descriptor.id)
        )
        match (registered) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) =>
                let activated = if (restoreExisting) {
                    isolatedPlugins.restore(
                        descriptor.id,
                        launch.generation,
                        descriptor.contentDigest,
                        root
                    )
                } else {
                    isolatedPlugins.mountInitial(launch)
                }
                match (activated) {
                    case Result.Ok(_) => Result.Ok(())
                    case Result.Err(error) =>
                        let _ = catalog.unregister(toolName)
                        Result.Err(error)
                }
        }
    }

    public func close(): Result<Unit> {
        javascriptPluginLifecycleLock.lock()
        try {
            javascriptPlugins.close()
        } finally {
            javascriptPluginLifecycleLock.unlock()
        }
    }
    public func javascriptPluginCommands(): Array<ProductJavaScriptPluginCommand> {
        javascriptPlugins.commands()
    }

    public func invokeJavaScriptPluginCommand(
        routeName: String,
        arguments: String,
        sessionId: SessionId,
        commandId: String,
        cancellation: CancellationToken,
        noticeSink: ProductJavaScriptPluginNoticeSink
    ): Result<Unit> {
        if (arguments.size > JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES ||
            commandId.trimAscii() == "" || cancellation.isCancelled()) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "plugin.command_request_invalid",
                "plugin command request is invalid or already cancelled"
            ))
        }
        var target: ?ProductJavaScriptPluginCommand = None
        for (command in javascriptPlugins.commands()) {
            if (command.routeName == routeName) {
                target = Some(command)
                break
            }
        }
        let selected = match (target) {
            case Some(value) => value
            case None => return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "plugin.command_not_found",
                "plugin command is not registered"
            ))
        }
        let identity = JavaScriptHostInvocationIdentity(
            threadId: sessionId.value,
            runId: "",
            epoch: 0,
            operationId: "",
            callId: "",
            kind: "command",
            commandId: commandId
        )
        let argumentsJson = stringifyUnifiedJson(objectValue([
            ValueField("command_args", textValue(arguments))
        ]))
        let observer = ProductJavaScriptPluginServiceRuntime(
            catalog, pipeline, operations, askRuntime
        ).commandObserver(sessionId, commandId, cancellation, noticeSink)
        match (javascriptPlugins.invoke(
            selected.extensionId, selected.name, argumentsJson,
            identity: identity, cancellation: cancellation, cwd: workspaceRoot,
            hasUI: askRuntime.hasInteractive(sessionId), observer: Some(observer)
        )) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => if (value.isError) {
                let details = match (value.value.field("error")) {
                    case Some(item) => item
                    case None => return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "plugin.command_failed",
                        "plugin command reported an error"
                    ))
                }
                let code = pluginReceiptText(details, "code")
                let message = pluginReceiptText(details, "message")
                Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    if (code == "") { "plugin.command_failed" } else { code },
                    if (message == "") { "plugin command reported an error" } else { message }
                ))
            } else {
                Result.Ok(())
            }
        }
    }

    public func deactivateImportedPlugin(record: ProductPluginRecord): Result<Unit> {
        let descriptor = record.descriptor
        if (descriptor.ecosystem == PluginEcosystem.Pi ||
            descriptor.ecosystem == PluginEcosystem.Codex) {
            let _ = catalog.unregisterHookHandlers(descriptor.namespace)
            javascriptPluginLifecycleLock.lock()
            try {
                for (tool in javascriptPlugins.toolNames(descriptor.namespace)) {
                    let _ = catalog.unregister("plugin." + descriptor.namespace + "." + tool)
                }
                return javascriptPlugins.unmount(descriptor.namespace)
            } finally {
                javascriptPluginLifecycleLock.unlock()
            }
        }
        if (descriptor.ecosystem != PluginEcosystem.Axyndra) {
            return Result.Ok(())
        }
        let _ = catalog.unregister("plugin." + descriptor.namespace + ".invoke")
        match (isolatedPlugins.deactivate(descriptor.id)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => isolatedPlugins.cancelAll(descriptor.id)
        }
    }
    public func mountIsolatedExtension(
        launch: IsolatedPluginLaunchRequest
    ): Result<Unit> {
        isolatedPlugins.mountInitial(launch)
    }

    public func reloadIsolatedExtension(
        launch: IsolatedPluginLaunchRequest
    ): Result<Unit> {
        isolatedPlugins.reload(launch)
    }

    public func createEffectScope(owner: ComponentInstanceRef): EffectScope {
        EffectScope(owner)
    }

    public func adaptExtensionLifecycle(
        host: ExtensionLifecycleHost
    ): SafeExtensionLifecycleRuntime {
        SafeExtensionLifecycleRuntime(CompiledExtensionLifecycleAdapter(host))
    }
}

// Both third-party execution kinds cross the same fail-closed ProcessPort.
// Process plugins execute their packaged binary directly; WASM components use
// a fixed host runtime and pass the packaged module as the first argument.
// Neither path inherits ambient environment or host filesystem authority.
public class ProductIsolatedPluginHost {
    private let processes: ProcessPort
    private let workspaceRoot: String
    private let wasmRuntime: String
    private let managedPackageRoots: Array<String>
    private let lock = Mutex()
    private let generations = ArrayList<ProductIsolatedPluginGeneration>()

    public init(
        processes: ProcessPort,
        workspaceRoot: String,
        wasmRuntime!: String = "wasmtime",
        managedPackageRoots!: Array<String> = []
    ) {
        if (workspaceRoot.trimAscii() == "" || wasmRuntime.trimAscii() == "" ||
            managedPackageRoots.isEmpty()) {
            throw IllegalArgumentException("isolated plugin host configuration is invalid")
        }
        this.processes = processes
        this.workspaceRoot = workspaceRoot.trimAscii()
        this.wasmRuntime = wasmRuntime.trimAscii()
        this.managedPackageRoots = managedPackageRoots.clone()
    }

    public func mountInitial(launch: IsolatedPluginLaunchRequest): Result<Unit> {
        if (!immutablePackageRoot(launch.packageRoot)) {
            return isolatedPluginError<Unit>(
                "extension.snapshot_unbound",
                "isolated plugin execution requires a host-owned package snapshot"
            )
        }
        lock.lock()
        try {
            if (currentLocked(launch.manifest.id).isSome()) {
                return isolatedPluginError<Unit>(
                    "extension.already_mounted", "isolated extension already has an active generation"
                )
            }
            generations.add(ProductIsolatedPluginGeneration(launch))
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func reload(launch: IsolatedPluginLaunchRequest): Result<Unit> {
        if (!immutablePackageRoot(launch.packageRoot)) {
            return isolatedPluginError<Unit>(
                "extension.snapshot_unbound",
                "isolated plugin execution requires a host-owned package snapshot"
            )
        }
        lock.lock()
        try {
            let old = match (currentLocked(launch.manifest.id)) {
                case Some(value) => value
                case None => return isolatedPluginError<Unit>(
                    "extension.not_mounted", "isolated extension has no active generation"
                )
            }
            if (launch.generation <= old.launch.generation) {
                return isolatedPluginError<Unit>(
                    "extension.generation_stale", "isolated extension generation must increase"
                )
            }
            // New admission becomes available before the old generation is
            // fenced, matching the no-gap generation reload contract.
            generations.add(ProductIsolatedPluginGeneration(launch))
            old.accepting = false
            old.state = ExtensionLifecycleState.Draining
            if (old.inFlight == 0u64) { old.state = ExtensionLifecycleState.Inactive }
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func deactivate(extensionId: String): Result<Unit> {
        lock.lock()
        try {
            for (record in generations where record.launch.manifest.id == extensionId.trimAscii() && record.accepting) {
                record.accepting = false
                record.state = if (record.inFlight == 0u64) {
                    ExtensionLifecycleState.Inactive
                } else {
                    ExtensionLifecycleState.Draining
                }
            }
            Result.Ok(())
        } finally { lock.unlock() }
    }
    func restore(
        extensionId: String,
        generation: UInt64,
        contentDigest: String,
        packageRoot: String
    ): Result<Unit> {
        let normalizedId = extensionId.trimAscii()
        lock.lock()
        try {
            if (currentLocked(normalizedId).isSome()) {
                return isolatedPluginError<Unit>(
                    "extension.already_mounted",
                    "isolated extension already has an active generation"
                )
            }
            let record = match (findLocked(normalizedId, generation)) {
                case Some(value) => value
                case None => return isolatedPluginError<Unit>(
                    "extension.restore_target_missing",
                    "isolated extension generation cannot be restored"
                )
            }
            if (record.launch.manifest.contentDigest != contentDigest ||
                record.launch.packageRoot != packageRoot) {
                return isolatedPluginError<Unit>(
                    "extension.restore_identity_mismatch",
                    "isolated extension restore identity does not match the mounted generation"
                )
            }
            record.accepting = true
            record.state = ExtensionLifecycleState.Active
            Result.Ok(())
        } finally { lock.unlock() }
    }


    public func invoke(
        extensionId: String,
        prepared: PreparedToolInvocation,
        processLimits!: ExecutionResourceLimits = ExecutionResourceLimits()
    ): Result<AgentValue> {
        var selected: ?ProductIsolatedPluginGeneration = None
        lock.lock()
        try {
            let current = match (currentLocked(extensionId.trimAscii())) {
                case Some(value) => value
                case None => return isolatedPluginError<AgentValue>(
                    "extension.not_active", "isolated extension has no admitting generation"
                )
            }
            processes.reserveOperation(prepared.operationId)
            current.inFlight += 1u64
            current.activeOperationIds.add(prepared.operationId)
            selected = Some(current)
        } finally { lock.unlock() }
        let generation = selected.getOrThrow()
        try {
            execute(generation.launch, prepared, processLimits)
        } finally {
            lock.lock()
            try {
                for (index in 0..generation.activeOperationIds.size) {
                    if (generation.activeOperationIds[index].value == prepared.operationId.value) {
                        generation.activeOperationIds.remove(at: index)
                        break
                    }
                }
                if (generation.inFlight > 0u64) { generation.inFlight -= 1u64 }
                if (generation.inFlight == 0u64 &&
                    generation.state == ExtensionLifecycleState.Draining) {
                    generation.state = ExtensionLifecycleState.Inactive
                }
            } finally {
                lock.unlock()
                processes.releaseOperation(prepared.operationId)
            }
        }
    }
    public func cancelAll(extensionId: String): Result<Unit> {
        let pending = ArrayList<OperationId>()
        lock.lock()
        try {
            for (record in generations where record.launch.manifest.id == extensionId.trimAscii()) {
                for (operationId in record.activeOperationIds) { pending.add(operationId) }
            }
        } finally { lock.unlock() }
        for (operationId in pending) {
            match (processes.cancel(operationId)) {
                case Result.Ok(_) => ()
                case Result.Err(error) => return Result.Err(error)
            }
        }
        Result.Ok(())
    }



    public func finishDrain(extensionId: String, generation: UInt64): Result<Unit> {
        lock.lock()
        try {
            let record = match (findLocked(extensionId.trimAscii(), generation)) {
                case Some(value) => value
                case None => return isolatedPluginError<Unit>(
                    "extension.generation_missing", "isolated extension generation is not mounted"
                )
            }
            if (record.state != ExtensionLifecycleState.Draining) {
                return isolatedPluginError<Unit>(
                    "extension.not_draining", "isolated extension generation is not draining"
                )
            }
            if (record.inFlight > 0u64) {
                record.state = ExtensionLifecycleState.Quarantined
                return isolatedPluginError<Unit>(
                    "extension.drain_timeout", "isolated extension still owns active invocations"
                )
            }
            record.state = ExtensionLifecycleState.Inactive
            Result.Ok(())
        } finally { lock.unlock() }
    }

    public func diagnostics(): Array<ExtensionGenerationDiagnostic> {
        lock.lock()
        try {
            let output = ArrayList<ExtensionGenerationDiagnostic>()
            for (record in generations) {
                output.add(ExtensionGenerationDiagnostic(
                    record.launch.manifest.id, record.launch.generation,
                    record.state, record.inFlight, record.accepting
                ))
            }
            output.toArray()
        } finally { lock.unlock() }
    }

    private func execute(
        launch: IsolatedPluginLaunchRequest,
        prepared: PreparedToolInvocation,
        processLimits: ExecutionResourceLimits
    ): Result<AgentValue> {
        if (launch.ambientAuthority) {
            return isolatedPluginError<AgentValue>(
                "extension.ambient_authority", "isolated plugin requested ambient authority"
            )
        }
        let operationPlan = prepared.operationPlan
        let sandboxMode = match (isolatedPluginSandboxMode(launch, operationPlan)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let payload = operationPlan.canonicalArguments
        let requestValue = objectValue([
            ValueField("protocol", textValue("axyndra-extension-v1")),
            ValueField("extension_id", textValue(launch.manifest.id)),
            ValueField("extension_version", textValue(launch.manifest.version)),
            ValueField("generation", integerValue(Int64(launch.generation))),
            ValueField("invocation_id", textValue(prepared.call.callId)),
            ValueField("method", textValue(prepared.call.name)),
            ValueField("payload", payload)
        ])
        let executionRoot = launch.packageRoot.trimAscii()
        if (executionRoot == "") {
            return isolatedPluginError<AgentValue>(
                "extension.snapshot_unbound",
                "isolated plugin execution requires a bound package snapshot"
            )
        }
        let inspected = match (inspectPluginPackage(executionRoot)) {
            case PluginPackageResult.Ok(value) => value
            case PluginPackageResult.Err(_) => return isolatedPluginError<AgentValue>(
                "extension.snapshot_stale",
                "isolated plugin package no longer matches its verified snapshot"
            )
        }
        if (inspected.id != launch.manifest.id ||
            inspected.version != launch.manifest.version ||
            inspected.entrypoint != launch.manifest.entrypoint ||
            inspected.contentDigest != launch.manifest.contentDigest ||
            inspected.signature != launch.manifest.signature ||
            inspected.root != executionRoot) {
            return isolatedPluginError<AgentValue>(
                "extension.snapshot_stale",
                "isolated plugin package no longer matches its verified snapshot"
            )
        }
        let packagedEntrypoint = executionRoot + "/" + launch.manifest.entrypoint
        let executable: String
        let arguments: Array<String>
        match (launch.executionKind) {
            case ExtensionExecutionKind.ProcessPlugin =>
                executable = packagedEntrypoint
                arguments = ["--axyndra-plugin-call", stringifyUnifiedJson(requestValue)]
            case ExtensionExecutionKind.WasmComponent =>
                executable = wasmRuntime
                arguments = [
                    packagedEntrypoint, "--invoke", "axyndra_handle",
                    stringifyUnifiedJson(requestValue)
                ]
            case _ => return isolatedPluginError<AgentValue>(
                "extension.execution_kind",
                "only process and WASM plugins use the isolated plugin host"
            )
        }
        let networkPolicy = operationPlan.networkPolicy
        let operationId = prepared.operationId
        let workspaceRead = sandboxMode != ProcessSandboxMode.IsolatedReadOnly
        let execution = processes.execute(ProcessRequest(
            executable,
            operationId: operationId,
            arguments: arguments,
            workingDirectory: executionRoot,
            timeoutMillis: 30000,
            sandboxMode: sandboxMode,
            filesystemRoot: if (workspaceRead) { "" } else { executionRoot },
            readOnlyMounts: if (workspaceRead) { [executionRoot] } else { [] },
            networkPolicy: Some(networkPolicy),
            processLimits: processLimits
        ))
        let result = match (execution) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (result.timedOut) {
            return isolatedPluginError<AgentValue>(
                "extension.timeout", "isolated plugin invocation timed out"
            )
        }
        if (result.truncated) {
            return isolatedPluginError<AgentValue>(
                "extension.output_truncated", "isolated plugin output exceeded its bound"
            )
        }
        if (result.exitCode != 0) {
            return isolatedPluginError<AgentValue>(
                "extension.exit_failure",
                "isolated plugin exited with code " + result.exitCode.toString()
            )
        }
        match (decodeAgentValue(result.stdout.trimAscii())) {
            case Result.Ok(value) => Result.Ok(value)
            case Result.Err(_) => isolatedPluginError<AgentValue>(
                "extension.protocol_invalid",
                "isolated plugin returned an invalid protocol document"
            )
        }
    }

    private func immutablePackageRoot(root: String): Bool {
        let info = try { FileInfo(Path(root)) } catch (_: Exception) { return false }
        if (!info.isDirectory() || info.isSymbolicLink()) { return false }
        let canonicalRoot = try { canonicalize(Path(root)).toString() } catch (_: Exception) { return false }
        let canonicalWorkspace = try {
            canonicalize(Path(workspaceRoot)).toString()
        } catch (_: Exception) {
            return false
        }
        if (canonicalRoot == canonicalWorkspace ||
            canonicalRoot.startsWith(canonicalWorkspace + "/")) { return false }
        for (packageRoot in managedPackageRoots) {
            let packageInfo = try { FileInfo(Path(packageRoot)) } catch (_: Exception) { continue }
            if (!packageInfo.isDirectory() || packageInfo.isSymbolicLink()) { continue }
            let canonicalPackageRoot = try {
                canonicalize(Path(packageRoot)).toString()
            } catch (_: Exception) {
                continue
            }
            if (canonicalPackageRoot == canonicalWorkspace ||
                canonicalPackageRoot.startsWith(canonicalWorkspace + "/")) { continue }
            if (canonicalRoot.startsWith(canonicalPackageRoot + "/")) { return true }
        }
        false
    }

    private func currentLocked(extensionId: String): ?ProductIsolatedPluginGeneration {
        var selected: ?ProductIsolatedPluginGeneration = None
        for (record in generations where record.launch.manifest.id == extensionId &&
            record.accepting && record.state == ExtensionLifecycleState.Active) {
            match (selected) {
                case None => selected = Some(record)
                case Some(value) => if (
                    record.launch.generation > value.launch.generation
                ) { selected = Some(record) }
            }
        }
        selected
    }

    private func findLocked(
        extensionId: String,
        generation: UInt64
    ): ?ProductIsolatedPluginGeneration {
        for (record in generations where record.launch.manifest.id == extensionId &&
            record.launch.generation == generation) { return Some(record) }
        None
    }
}

class ProductIsolatedPluginGeneration {
    let launch: IsolatedPluginLaunchRequest
    var state: ExtensionLifecycleState = ExtensionLifecycleState.Active
    var accepting: Bool = true
    var inFlight: UInt64 = 0u64
    let activeOperationIds = ArrayList<OperationId>()
    init(launch: IsolatedPluginLaunchRequest) { this.launch = launch }
}

func isolatedPluginError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Protocol, code, message))
}

func isolatedPluginNetworkError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.InvalidInput, code, message))
}

func isolatedPluginEgressRule(value: String): Result<NetworkEgressRule> {
    let endpoint = value.trimAscii()
    let host: String
    let portText: String
    if (endpoint.startsWith("[")) {
        let close = match (endpoint.indexOf("]")) {
            case Some(index) => index
            case None => return isolatedPluginNetworkError<NetworkEgressRule>(
                "extension.network_rule_invalid",
                "network.access rule has an invalid IPv6 host"
            )
        }
        let suffix = endpoint[close + 1..]
        if (close <= 1 || !suffix.startsWith(":")) {
            return isolatedPluginNetworkError<NetworkEgressRule>(
                "extension.network_rule_invalid",
                "network.access rule must use [host]:port"
            )
        }
        host = endpoint[1..close]
        portText = suffix[1..]
    } else {
        let parts = endpoint.split(":")
        if (parts.size != 2 || parts[0] == "" || parts[1] == "") {
            return isolatedPluginNetworkError<NetworkEgressRule>(
                "extension.network_rule_invalid",
                "network.access rule must use host:port"
            )
        }
        host = parts[0]
        portText = parts[1]
    }
    let port: UInt16
    try {
        let parsed = Int64.parse(portText)
        if (parsed < 1 || parsed > 65535 || parsed.toString() != portText) {
            return isolatedPluginNetworkError<NetworkEgressRule>(
                "extension.network_rule_invalid",
                "network.access rule has an invalid port"
            )
        }
        port = UInt16(parsed)
    } catch (_: Exception) {
        return isolatedPluginNetworkError<NetworkEgressRule>(
            "extension.network_rule_invalid",
            "network.access rule has an invalid port"
        )
    }
    try {
        Result.Ok(NetworkEgressRule(host, port))
    } catch (error: Exception) {
        isolatedPluginNetworkError<NetworkEgressRule>(
            "extension.network_rule_invalid",
            error.message
        )
    }
}

func isolatedPluginToolCapabilities(
    launch: IsolatedPluginLaunchRequest
): Array<Capability> {
    let values = ArrayList<Capability>()
    if (launch.grantedCapabilities.contains("workspace.write")) {
        values.add(Capability(CapabilityKind.WorkspaceWrite))
    } else if (launch.grantedCapabilities.contains("workspace.read")) {
        values.add(Capability(CapabilityKind.WorkspaceRead))
    }
    values.toArray()
}

func isolatedPluginPlanHasCapability(
    plan: NormalizedOperationPlan,
    kind: CapabilityKind
): Bool {
    for (capability in plan.requiredCapabilities where capability.kind == kind) {
        return true
    }
    false
}

func isolatedPluginNetworkPoliciesMatch(
    expected: NetworkPolicy,
    prepared: NetworkPolicy
): Bool {
    if (expected.mode != prepared.mode || expected.egress.size != prepared.egress.size ||
        expected.publish.size != prepared.publish.size) {
        return false
    }
    for (index in 0..expected.egress.size) {
        let left = expected.egress[index]
        let right = prepared.egress[index]
        if (left.host != right.host || left.port != right.port ||
            left.privateAddresses != right.privateAddresses) {
            return false
        }
    }
    for (index in 0..expected.publish.size) {
        let left = expected.publish[index]
        let right = prepared.publish[index]
        if (left.hostPort != right.hostPort || left.targetPort != right.targetPort) {
            return false
        }
    }
    true
}

func isolatedPluginSandboxMode(
    launch: IsolatedPluginLaunchRequest,
    plan: NormalizedOperationPlan
): Result<ProcessSandboxMode> {
    if (!isolatedPluginPlanHasCapability(plan, CapabilityKind.ExtensionInvoke)) {
        return Result.Err(AgentError(
            AgentErrorKind.PermissionDenied,
            "extension.plan_authority_missing",
            "prepared operation does not authorize isolated extension invocation"
        ))
    }
    let grantedWrite = launch.grantedCapabilities.contains("workspace.write")
    let grantedRead = grantedWrite || launch.grantedCapabilities.contains("workspace.read")
    let preparedWrite = isolatedPluginPlanHasCapability(plan, CapabilityKind.WorkspaceWrite)
    let preparedRead = preparedWrite ||
        isolatedPluginPlanHasCapability(plan, CapabilityKind.WorkspaceRead)
    let expectedNetwork = match (isolatedPluginNetworkPolicy(launch)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    if (grantedWrite != preparedWrite || grantedRead != preparedRead ||
        !isolatedPluginNetworkPoliciesMatch(expectedNetwork, plan.networkPolicy)) {
        return Result.Err(AgentError(
            AgentErrorKind.PermissionDenied,
            "extension.plan_authority_mismatch",
            "prepared operation authority does not match the mounted plugin grant"
        ))
    }
    if (preparedWrite) {
        Result.Ok(ProcessSandboxMode.WorkspaceReadWrite)
    } else if (preparedRead) {
        Result.Ok(ProcessSandboxMode.WorkspaceReadOnly)
    } else {
        Result.Ok(ProcessSandboxMode.IsolatedReadOnly)
    }
}
func isolatedPluginNetworkPolicy(
    launch: IsolatedPluginLaunchRequest
): Result<NetworkPolicy> {
    let prefix = "network.access:"
    let rules = ArrayList<NetworkEgressRule>()
    var requested = false
    for (capability in launch.grantedCapabilities) {
        if (capability == "network.access") {
            return isolatedPluginNetworkError<NetworkPolicy>(
                "extension.network_rules_missing",
                "network.access requires one or more explicit host:port rules"
            )
        }
        if (capability.startsWith(prefix)) {
            requested = true
            let rule = match (isolatedPluginEgressRule(capability[prefix.size..])) {
                case Result.Ok(value) => value
                case Result.Err(error) => return Result.Err(error)
            }
            rules.add(rule)
        }
    }
    if (!requested) { return Result.Ok(NetworkPolicy(NetworkPolicyMode.Denied)) }
    try {
        Result.Ok(NetworkPolicy(NetworkPolicyMode.Mediated, egress: rules.toArray()))
    } catch (error: Exception) {
        isolatedPluginNetworkError<NetworkPolicy>(
            "extension.network_rules_invalid",
            error.message
        )
    }
}




class ProductTrustedControlToolExecutor {
    private let pipeline: ToolPipeline
    private let operations: OperationRuntimePort
    private let runtime: AgentThreadRuntime

    init(
        pipeline: ToolPipeline,
        operations: OperationRuntimePort,
        runtime: AgentThreadRuntime
    ) {
        this.pipeline = pipeline
        this.operations = operations
        this.runtime = runtime
    }


    public func invoke(
        context: ToolInvocationContext,
        call: ToolCall,
        approvalDecision!: ?ApprovalDecision
    ): Result<ToolInvocationResult> {
        let prepared = match (pipeline.prepare(context, call)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(ToolPreparation.Ready(value)) => value
            case Result.Ok(ToolPreparation.NeedsApproval(value, request)) =>
                match (approvalDecision) {
                    case Some(_) => value
                    case None => return Result.Ok(ToolInvocationResult.NeedsApproval(request))
                }
            case Result.Ok(ToolPreparation.Completed(value)) =>
                return Result.Ok(ToolInvocationResult.Completed(value))
            case Result.Ok(ToolPreparation.Denied(value)) =>
                return Result.Ok(ToolInvocationResult.Denied(value))
        }
        let active = runtime.activeRun().getOrThrow()
        let before = runtime.threadSnapshot()
        let callItemId = ItemId(
            "direct-tool-call-" + context.runId.value + "-" + call.callId
        )
        match (runtime.commitResult(ResultEnvelope(
            before.thread.id,
            active.turnId,
            active.runId,
            active.epoch,
            before.nextResultSequence,
            ThreadItemDraft(
                callItemId,
                ThreadItemContent.ToolCall(
                    CanonicalToolCallId(call.callId), call.name, call.arguments
                ),
                ItemProvenance("direct_tool", runId: Some(active.runId)),
                createdAtMillis: agentUtcMillis()
            )
        ))) {
            case SemanticCommitDecision.Committed(_, _) => ()
            case SemanticCommitDecision.Stale(reason) => return Result.Err(AgentError(
                AgentErrorKind.Conflict, reason.code, reason.message
            ))
            case SemanticCommitDecision.Rejected(error) => return Result.Err(error)
        }
        match (operations.prepareTrustedControlOperation(
            prepared.operationId, context.runId, callItemId, prepared.operationPlan
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let execution: Result<ToolInvocationResult> = match (prepared.authorization) {
            case PreparedAuthorization.ApprovalRequired => match (approvalDecision) {
                case Some(decision) => match (operations.waitForApproval(
                    prepared.operationId, context.runId
                )) {
                    case Result.Err(error) => Result.Err(error)
                    case Result.Ok(_) => match (pipeline.authorize(
                        context,
                        prepared,
                        decision,
                        decisionSource: ApprovalDecisionSource.User
                    )) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(ToolAuthorization.Ready(authorized)) =>
                            pipeline.executePrepared(context, authorized)
                        case Result.Ok(ToolAuthorization.Completed(result)) =>
                            Result.Ok(ToolInvocationResult.Completed(result))
                        case Result.Ok(ToolAuthorization.Denied(denial)) =>
                            Result.Ok(ToolInvocationResult.Denied(denial))
                    }
                }
                case None => Result.Err(AgentError(
                    AgentErrorKind.Conflict,
                    "plugin.acquisition_approval_missing",
                    "prepared plugin acquisition reached execution without user approval"
                ))
            }
            case _ => pipeline.executePrepared(context, prepared)
        }
        let receiptId = match (execution) {
            case Result.Ok(ToolInvocationResult.Completed(value)) => if (
                value.receiptId == ""
            ) {
                "receipt-" + prepared.operationId.value
            } else {
                value.receiptId
            }
            case _ => "receipt-" + prepared.operationId.value
        }
        match (runtime.resolveOperation(
            ItemId("direct-tool-result-" + context.runId.value + "-" + call.callId),
            prepared.operationId,
            CanonicalToolCallId(call.callId),
            prepared.operationPlan,
            OperationAttemptStage.Executing,
            execution,
            receiptId,
            agentUtcMillis()
        )) {
            case Result.Ok(_) => execution
            case Result.Err(error) => Result.Err(error)
        }
    }
}

func mountAndRegisterJavaScriptPlugin(
    record: ProductPluginRecord,
    hostManager: ProductJavaScriptPluginHost,
    catalog: ToolCatalog,
    serviceRuntime!: ?ProductJavaScriptPluginServiceRuntime = None
): Result<Unit> {
    let descriptor = record.descriptor
    let tools = match (hostManager.mount(record)) {
        case Result.Ok(value) => value
        case Result.Err(error) => return Result.Err(error)
    }
    try {
        let additionalCapabilities = ArrayList<Capability>()
        let workspaceWriteGranted = descriptor.requestedCapabilities.contains("workspace.write")
        let workspaceReadGranted = workspaceWriteGranted ||
            descriptor.requestedCapabilities.contains("workspace.read")
        if (workspaceWriteGranted) {
            additionalCapabilities.add(Capability(CapabilityKind.WorkspaceWrite))
        } else if (workspaceReadGranted) {
            additionalCapabilities.add(Capability(CapabilityKind.WorkspaceRead))
        }
        let candidates = ArrayList<ToolCatalogRegistration>()
        for (tool in tools) {
            let schema = match (decodeAgentValue(
                tool.inputSchemaJson,
                maxBytes: JAVASCRIPT_EXTENSION_MAX_FRAME_BYTES
            )) {
                case Result.Ok(value) =>
                    if (value.unifiedKind != ValueKind.Object) {
                        let _ = hostManager.unmount(descriptor.namespace)
                        return Result.Err(AgentError(
                            AgentErrorKind.InvalidInput,
                            "plugin.tool_schema_invalid",
                            "extension tool input_schema must be an object"
                        ))
                    }
                    value
                case Result.Err(error) =>
                    let _ = hostManager.unmount(descriptor.namespace)
                    return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "plugin.tool_schema_invalid",
                        error.message
                    ))
            }
            let toolName = "plugin." + descriptor.namespace + "." + tool.name
            candidates.add(ToolCatalogRegistration(
                ToolDescriptor(
                    ModelToolDefinition(toolName, tool.description, schema),
                    Capability(CapabilityKind.ExtensionInvoke),
                    sideEffecting: true,
                    additionalCapabilities: additionalCapabilities.toArray(),
                    implementationVersion: descriptor.version,
                    implementationFingerprint: descriptor.namespace + ":" + descriptor.contentDigest
                ),
                ProductJavaScriptPluginToolExecutor(
                    hostManager,
                    descriptor.namespace,
                    tool.name,
                    serviceRuntime: serviceRuntime
                )
            ))
        }
        match (catalog.registerBatch(candidates.toArray())) {
            case Result.Err(error) =>
                let _ = hostManager.unmount(descriptor.namespace)
                Result.Err(error)
            case Result.Ok(_) =>
                if (descriptor.ecosystem == PluginEcosystem.Pi) {
                    let handlers = ArrayList<ToolHookHandlerSnapshot>()
                    for (hook in hostManager.hookDescriptors() where
                        hook.extensionId == descriptor.namespace) {
                        let event = if (hook.descriptor.event == "tool_call") {
                            if (!workspaceWriteGranted) { continue }
                            "PreToolUse"
                        } else if (hook.descriptor.event == "tool_result") {
                            if (!workspaceReadGranted) { continue }
                            "PostToolUse"
                        } else {
                            let _ = hostManager.unmount(descriptor.namespace)
                            return Result.Err(AgentError(
                                AgentErrorKind.InvalidInput,
                                "extension.pi_event_unsupported",
                                "Pi event registration is not supported"
                            ))
                        }
                        handlers.add(ToolHookHandlerSnapshot(
                            event, descriptor.namespace, descriptor.version,
                            descriptor.contentDigest, descriptor.root, "*",
                            "pi.event:" + hook.descriptor.reference, 30000
                        ))
                    }
                    if (!handlers.isEmpty()) {
                        match (catalog.registerHookHandlers(
                            descriptor.namespace, handlers.toArray()
                        )) {
                            case Result.Ok(_) => ()
                            case Result.Err(error) =>
                                for (tool in tools) {
                                    let _ = catalog.unregister(
                                        "plugin." + descriptor.namespace + "." + tool.name
                                    )
                                }
                                let _ = hostManager.unmount(descriptor.namespace)
                                return Result.Err(error)
                        }
                    }
                }
                Result.Ok(())
        }
    } catch (error: Exception) {
        let _ = catalog.unregisterHookHandlers(descriptor.namespace)
        for (tool in tools) {
            let _ = catalog.unregister("plugin." + descriptor.namespace + "." + tool.name)
        }
        let _ = hostManager.unmount(descriptor.namespace)
        Result.Err(AgentError(
            AgentErrorKind.Internal,
            "plugin.tool_registration_failed",
            error.message
        ))
    }
}

func directControlModelLane(runId: RunId, capabilities: CapabilitySet): ModelLane {
    let entries = ArrayList<ToolSnapshotEntry>()
    let _ = capabilities
    ModelLane(
        ModelLaneRole.Main,
        "direct-control",
        "none",
        "direct-control-v1",
        ModelLaneCapabilitiesSnapshot(
            streaming: false,
            tools: false,
            reasoning: false,
            structuredOutput: false,
            imageInput: false,
            promptCache: false,
            providerOpaqueState: false
        ),
        4096,
        1024,
        128,
        "direct-control-v1",
        "never",
        "none",
        ToolSetSnapshot("direct-control-catalog-" + runId.value, entries.toArray()),
        "direct-control-v1"
    )
}
class ProductStorageServiceProvider <: ServiceProvider<String> {
    public init() {}
    public func acquire(scope: ComponentScope): Result<ServiceLease<String>> {
        Result.Ok(ServiceLease("sqlite-vnext", scope, { => () }))
    }
}
