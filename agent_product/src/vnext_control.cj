package agent_product

import std.collection.*
import std.sync.*
import agent_domain.*
import agent_extension_runtime.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import agent_skills.*
import tool_runtime.*
import model_adapters.*

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
    private let workspaceRoot: String
    private let extensionSignatureVerifier: ?ExtensionPackageSignatureVerifier
    public let storageService: ServiceRegistry<String>
    public let isolatedPlugins: ProductIsolatedPluginHost

    init(
        database: SqliteDatabase,
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        ids: ProductIds,
        threadRuntimes: ThreadRuntimeRegistry,
        workspaceRoot: String,
        processes: ProcessPort,
        extensionSignatureVerifier: ?ExtensionPackageSignatureVerifier
    ) {
        this.database = database
        this.catalog = catalog
        this.pipeline = pipeline
        this.ids = ids
        this.threadRuntimes = threadRuntimes
        this.workspaceRoot = workspaceRoot
        this.extensionSignatureVerifier = extensionSignatureVerifier
        isolatedPlugins = ProductIsolatedPluginHost(
            processes, workspaceRoot
        )
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

    // Program Mode remains opt-in and read-only until PTC evaluation is
    // explicitly accepted. Every Tool expression still crosses ToolPipeline,
    // so each child call owns its normal Operation and Receipt.
    public func executeReadOnlyToolProgram(
        programId: String,
        source: String,
        sessionId: SessionId,
        capabilities: CapabilitySet,
        limits!: ToolProgramLimits = ToolProgramLimits()
    ): Result<ToolProgramResult> {
        match (compileRestrictedToolProgram(programId, source)) {
            case Result.Ok(program) => executeProgramRun(
                program, sessionId, capabilities, limits
            )
            case Result.Err(error) => Result.Err(error)
        }
    }

    private func executeProgramRun(
        program: ToolProgramIR,
        sessionId: SessionId,
        capabilities: CapabilitySet,
        limits: ToolProgramLimits
    ): Result<ToolProgramResult> {
        let runId = ids.nextRunId()
        let runtime = match (threadRuntimes.acquire(
            ThreadId(sessionId.value), workspaceRoot
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        let turnId = SemanticTurnId("program-turn-" + runId.value)
        match (runtime.startTurn(
            turnId,
            runId,
            ItemId("program-input-" + runId.value),
            ThreadItemContent.UserMessage([
                ThreadMessagePart.Text(program.source)
            ]),
            programModelLane(runId, capabilities),
            SkillStackSnapshot([], []),
            createdAtMillis: agentUtcMillis(),
            runBudgetSnapshot: objectValue([
                ValueField("run_kind", textValue("programmatic")),
                ValueField("read_only", boolValue(true))
            ])
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let result = ToolProgramRuntime(
            ProductProgramSubOperationExecutor(
                catalog, pipeline, DurableOperationStore(database), runtime
            )
        ).execute(
            program,
            ToolInvocationContext(
                runId,
                sessionId,
                capabilities,
                toolContext: ToolContextDescriptor(
                    workspaceRoot: workspaceRoot,
                    cwd: workspaceRoot
                )
            ),
            limits: limits
        )
        let terminal = if (result.status == ToolProgramStatus.Completed) {
            RunState.Completed
        } else {
            RunState.Failed
        }
        match (runtime.finish(
            terminal, 1000, reason: if (result.errorCode == "") {
                "program completed"
            } else {
                result.errorCode
            }
        )) {
            case Result.Ok(_) => Result.Ok(result)
            case Result.Err(error) => Result.Err(error)
        }
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
        let operations = DurableOperationStore(database)
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

    public func invokeIsolatedExtension(
        extensionId: String,
        invocation: IsolatedPluginInvocation
    ): Result<AgentValue> {
        isolatedPlugins.invoke(extensionId, invocation)
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
    private let lock = Mutex()
    private let generations = ArrayList<ProductIsolatedPluginGeneration>()

    public init(
        processes: ProcessPort,
        workspaceRoot: String,
        wasmRuntime!: String = "wasmtime"
    ) {
        if (workspaceRoot.trimAscii() == "" || wasmRuntime.trimAscii() == "") {
            throw IllegalArgumentException("isolated plugin host configuration is invalid")
        }
        this.processes = processes
        this.workspaceRoot = workspaceRoot.trimAscii()
        this.wasmRuntime = wasmRuntime.trimAscii()
    }

    public func mountInitial(launch: IsolatedPluginLaunchRequest): Result<Unit> {
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

    public func invoke(
        extensionId: String,
        invocation: IsolatedPluginInvocation
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
            current.inFlight += 1u64
            selected = Some(current)
        } finally { lock.unlock() }
        let generation = selected.getOrThrow()
        try {
            execute(generation.launch, invocation)
        } finally {
            lock.lock()
            try {
                if (generation.inFlight > 0u64) { generation.inFlight -= 1u64 }
                if (generation.inFlight == 0u64 &&
                    generation.state == ExtensionLifecycleState.Draining) {
                    generation.state = ExtensionLifecycleState.Inactive
                }
            } finally { lock.unlock() }
        }
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
        invocation: IsolatedPluginInvocation
    ): Result<AgentValue> {
        if (launch.ambientAuthority) {
            return isolatedPluginError<AgentValue>(
                "extension.ambient_authority", "isolated plugin requested ambient authority"
            )
        }
        let payload = match (decodeAgentValue(invocation.payloadJson)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return isolatedPluginError<AgentValue>(
                "extension.invocation_payload_invalid", error.message
            )
        }
        let requestValue = objectValue([
            ValueField("protocol", textValue("axyndra-extension-v1")),
            ValueField("extension_id", textValue(launch.manifest.id)),
            ValueField("extension_version", textValue(launch.manifest.version)),
            ValueField("generation", integerValue(Int64(launch.generation))),
            ValueField("invocation_id", textValue(invocation.id)),
            ValueField("method", textValue(invocation.method)),
            ValueField("payload", payload)
        ])
        let packagedEntrypoint = workspaceRoot + "/" + launch.manifest.entrypoint
        let executable: String
        let arguments: Array<String>
        match (launch.executionKind) {
            case ExtensionExecutionKind.ProcessPlugin =>
                executable = packagedEntrypoint
                arguments = ["--axyndra-plugin-call", encodeAgentValue(requestValue)]
            case ExtensionExecutionKind.WasmComponent =>
                executable = wasmRuntime
                arguments = [
                    packagedEntrypoint, "--invoke", "axyndra_handle",
                    encodeAgentValue(requestValue)
                ]
            case _ => return isolatedPluginError<AgentValue>(
                "extension.execution_kind",
                "only process and WASM plugins use the isolated plugin host"
            )
        }
        let execution = processes.execute(ProcessRequest(
            executable,
            operationId: OperationId(
                "extension-" + launch.manifest.id + "-" + invocation.id
            ),
            arguments: arguments,
            workingDirectory: workspaceRoot,
            timeoutMillis: invocation.timeoutMillis,
            sandboxMode: if (launch.grantedCapabilities.contains("workspace.write")) {
                ProcessSandboxMode.WorkspaceReadWrite
            } else {
                ProcessSandboxMode.WorkspaceReadOnly
            },
            networkAccess: launch.grantedCapabilities.contains("network.access")
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
    init(launch: IsolatedPluginLaunchRequest) { this.launch = launch }
}

func isolatedPluginError<T>(code: String, message: String): Result<T> {
    Result.Err(AgentError(AgentErrorKind.Protocol, code, message))
}

class ProductProgramSubOperationExecutor <: ProgramSubOperationExecutor {
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let operations: DurableOperationStore
    private let runtime: AgentThreadRuntime

    init(
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        operations: DurableOperationStore,
        runtime: AgentThreadRuntime
    ) {
        this.catalog = catalog
        this.pipeline = pipeline
        this.operations = operations
        this.runtime = runtime
    }

    public func isReadOnly(call: ToolCall): Bool { catalog.isReadOnly(call) }

    public func invoke(
        context: ToolInvocationContext,
        call: ToolCall
    ): Result<ToolInvocationResult> {
        let prepared = match (pipeline.prepare(context, call)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(ToolPreparation.Ready(value)) => value
            case Result.Ok(ToolPreparation.NeedsApproval(_, request)) =>
                return Result.Ok(ToolInvocationResult.NeedsApproval(request))
            case Result.Ok(ToolPreparation.Completed(value)) =>
                return Result.Ok(ToolInvocationResult.Completed(value))
            case Result.Ok(ToolPreparation.Denied(value)) =>
                return Result.Ok(ToolInvocationResult.Denied(value))
        }
        let active = runtime.activeRun().getOrThrow()
        let before = runtime.threadSnapshot()
        let callItemId = ItemId(
            "program-tool-call-" + context.runId.value + "-" + call.callId
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
                ItemProvenance("tool_program", runId: Some(active.runId)),
                createdAtMillis: agentUtcMillis()
            )
        ))) {
            case SemanticCommitDecision.Committed(_, _) => ()
            case SemanticCommitDecision.Stale(reason) => return Result.Err(AgentError(
                AgentErrorKind.Conflict, reason.code, reason.message
            ))
            case SemanticCommitDecision.Rejected(error) => return Result.Err(error)
        }
        match (operations.prepareProgramSubOperation(
            prepared.operationId, context.runId, callItemId, prepared.operationPlan
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (operations.markExecuting(
            prepared.operationId,
            context.runId,
            prepared.operationPlan,
            agentUtcMillis(),
            false
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        match (operations.markExecutionHandoff(
            prepared.operationId,
            context.runId,
            ThreadId(context.sessionId.value),
            agentUtcMillis()
        )) {
            case Result.Ok(_) => ()
            case Result.Err(error) => return Result.Err(error)
        }
        let execution = pipeline.executePrepared(context, prepared)
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
            ItemId("program-tool-result-" + context.runId.value + "-" + call.callId),
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

func programModelLane(runId: RunId, capabilities: CapabilitySet): ModelLane {
    let entries = ArrayList<ToolSnapshotEntry>()
    // The actual permitted definitions are rechecked by ToolPipeline. This
    // snapshot records the read-only program's catalog identity for recovery.
    let _ = capabilities
    ModelLane(
        ModelLaneRole.Main,
        "program-runtime",
        "none",
        "tool-program-v1",
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
        "program-v1",
        "never",
        "none",
        ToolSetSnapshot("program-catalog-" + runId.value, entries.toArray()),
        "program-v1"
    )
}

class ProductStorageServiceProvider <: ServiceProvider<String> {
    public init() {}
    public func acquire(scope: ComponentScope): Result<ServiceLease<String>> {
        Result.Ok(ServiceLease("sqlite-vnext", scope, { => () }))
    }
}
