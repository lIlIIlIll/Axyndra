package agent_product

import std.collection.*
import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import agent_store.*
import agent_skills.*
import tool_runtime.*

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
    public let storageService: ServiceRegistry<String>

    init(
        database: SqliteDatabase,
        catalog: ToolCatalog,
        pipeline: ToolPipeline,
        ids: ProductIds,
        threadRuntimes: ThreadRuntimeRegistry,
        workspaceRoot: String
    ) {
        this.database = database
        this.catalog = catalog
        this.pipeline = pipeline
        this.ids = ids
        this.threadRuntimes = threadRuntimes
        this.workspaceRoot = workspaceRoot
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
        router.route(envelope, request, nowMillis)
    }

    public func validateIsolatedExtension(
        manifest: SignedExtensionPackageManifest,
        executionKind: ExtensionExecutionKind,
        generation: UInt64,
        capabilityCeiling: Array<String>,
        verifier: ExtensionPackageSignatureVerifier
    ): SafeLifecycleResult<IsolatedPluginLaunchRequest> {
        validateIsolatedPluginPackage(
            manifest, executionKind, generation, capabilityCeiling, verifier
        )
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
