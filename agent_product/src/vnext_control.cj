package agent_product

import agent_plugin_registry.*

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
import agent_host_runtime.*
import agent_store.*
import tool_runtime.*

// Descriptive metadata only. Construction and use stay inside Product;
// no catalog, executor callback, source, admission or grant is exposed.
class ProductPublishedToolIdentity {
    public let implementationVersion: String
    public let implementationFingerprint: String

    init(implementationVersion: String, implementationFingerprint: String) {
        this.implementationVersion = implementationVersion
        this.implementationFingerprint = implementationFingerprint
    }
}

func codexHookGrantAllows(event: String, capabilities: Array<String>): Bool {
    let workspaceWriteGranted = capabilities.contains("workspace.write")
    if (event == "PreToolUse") { return workspaceWriteGranted }
    event == "PostToolUse" && (workspaceWriteGranted || capabilities.contains("workspace.read"))
}

// Explicit product-facing control surface for vNext facilities that are not
// implicit in a normal AgentCore request. These APIs keep persistence and
// capability checks in the production composition root instead of requiring
// callers to assemble test-only stores and runtimes.
public class ProductVnextControl <: HostServiceToolControl {
    private let database: SqliteDatabase
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let ids: ProductIds
    private let threadRuntimes: ThreadRuntimeRegistry
    private let canonicalTools: HostCanonicalToolGateway
    private let operations: OperationRuntimePort
    private let askRuntime: AskRuntime
    private let payloadArtifacts: ?ProductArtifactStore
    private let workspaceRoot: String
    private let settingsRoot: String
    private let canonicalSummaryTimeout173: Int64
    private let managedPluginPackageRoots: Array<String>
    private let extensionSignatureVerifier: ?ExtensionPackageSignatureVerifier
    private let javascriptPluginLifecycleLock = Mutex()
    private let stdioIngress: HostStdioIngressRuntime
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
        extensionSignatureVerifier!: ?ExtensionPackageSignatureVerifier = None,
        payloadArtifacts!: ?ProductArtifactStore = None,
        canonicalSummaryTimeout173!: Int64 = 5000
    ) {
        this.database = database
        this.catalog = catalog
        this.pipeline = pipeline
        this.ids = ids
        this.threadRuntimes = threadRuntimes
        this.operations = operations
        this.askRuntime = askRuntime; this.payloadArtifacts = payloadArtifacts
        this.workspaceRoot = workspaceRoot
        this.settingsRoot = settingsRoot
        this.canonicalSummaryTimeout173 = canonicalSummaryTimeout173
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
        canonicalTools = HostCanonicalToolGateway(database, catalog, pipeline, ids, threadRuntimes, operations,
            workspaceRoot, { root => productToolContext(root) }, { name => javascriptPlugins.readonlyDelegationTool(name) },
            { _ => Result<Unit>.Ok(()) })
        stdioIngress = HostStdioIngressRuntime(canonicalTools, threadRuntimes, ids, catalog,
            javascriptPlugins, settingsRoot, workspaceRoot, { root => productToolContext(root) })
        storageService = ServiceRegistry<String>(ServiceKey<String>(
            "SemanticStore", 1u32, RealmKind.Host
        ))
        let _ = storageService.bind(ProductStorageServiceProvider())
    }

    // Read-only current publication identity from this Product's sole catalog.
    // Preserve the exact name/thread active lookup, returning only two Strings.
    func publishedToolIdentity(name: String, threadId!: ?ThreadId = None): ?ProductPublishedToolIdentity {
        match (catalog.publishedDescriptor(name, threadId: threadId)) {
            case Some(value) => Some(ProductPublishedToolIdentity(
                value.implementationVersion, value.implementationFingerprint))
            case None => None
        }
    }

    // Internal composition seam: reuse the exact Store and catalog of this
    // Product. No plugin/RPC route exposes the factory or underlying registry.
    func createPluginLifecycleManager(processes: ProcessPort, caBundle!: String = "",
        managedJobLauncher!: ?ProductManagedJobLauncher = None,
        cleanupObserver!:?HostManagedChannelCleanupObserver=None): Result<ProductPluginLifecycleManager> {
        let services: HostJavaScriptPluginServiceRuntime = ProductJavaScriptPluginServiceRuntime(catalog, pipeline, operations, askRuntime,
            canonicalDatabase173: Some(database), canonicalSummaryTimeout173: canonicalSummaryTimeout173)
        hostCreatePluginLifecycleManager(database, catalog, javascriptPlugins, services, processes,
            payloadArtifacts: payloadArtifacts, caBundle: caBundle, managedJobLauncher: managedJobLauncher,installOwnedChannel:true,cleanupObserver:cleanupObserver)
    }

    // Real, finite, zero-effect parser ownership. No ToolCall, broker observer,
    // approval, hidden port or model request is created by this window.


    // Local operator entry. The generic owner alone reads stdin and owns the
    // connection; no MCP request can call this factory or supply a grant DTO.
    public func servePluginStdio(grantId: String): Result<Unit> {
        stdioIngress.servePluginStdio(grantId)
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

    func hasPendingRpcLocalProcessing113(threadId: ThreadId): Result<Bool> {
        SqliteInboxStepStore(database).hasPendingRpcLocalProcessing113(threadId)
    }
    func prepareActualRpcQueuedInput113(value: QueuedRunInitiatorData113, local: Bool,
        allocate: (Int64) -> LogicalJsonOwnerReservation,
        retain: (RpcQueuedStoreFailure113) -> Unit): Unit {
        SqliteInboxStepStore(database).prepareActualRpcQueuedInput113(value, local, allocate, retain)
    }
    func completeReturnedRpcInput113(value: QueuedRunInitiatorData113, local: Bool, accepted: Bool,
        allocate: (Int64) -> LogicalJsonOwnerReservation,
        retain: (RpcQueuedStoreFailure113) -> Unit): Unit {
        SqliteInboxStepStore(database).completeReturnedRpcInput113(value, local, accepted, allocate, retain)
    }
    func actualRpcQueuedInputTerminal113(value: QueuedRunInitiatorData113,
        allocate: (Int64) -> LogicalJsonOwnerReservation,
        retain: (RpcQueuedStoreFailure113) -> Unit): Bool {
        SqliteInboxStepStore(database).actualRpcQueuedInputTerminal113(value, allocate, retain)
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
        contextSnapshot!: InvocationContextProjection = InvocationContextProjection(),
        runId!: ?RunId = None,
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1)
    ): Result<ToolInvocationResult> {
        executeCanonicalToolWithDecision(
            sessionId, capabilities, call, contextSnapshot, runId, Option<ApprovalDecision>.None, budget: budget
        )
    }

    // Actual Application user owner only; neither RPC data nor plugin frames
    // can manufacture a retained Direct approval continuation.
    func executeDeferredCanonicalTool(sessionId: SessionId, capabilities: CapabilitySet, call: ToolCall,
        owner: ProductDirectPreparationOwner, cancellation: CancellationToken,
        participant!: ?PluginDocumentCommitParticipant = None,
        contextSnapshot!: InvocationContextProjection = InvocationContextProjection(),
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1)): Result<ToolInvocationResult> {
        match (owner.current()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        executeCanonicalToolWithDecision(sessionId, capabilities, call, contextSnapshot, Option<RunId>.None, Option<ApprovalDecision>.None,
            budget: budget, hostCallerCancellation: Some(cancellation), directPreparationOwner: Some(owner),
            commandParticipant: participant)
    }

    // Package-internal host service gateway. The caller supplies a dedicated
    // maintenance Thread, actual operator capabilities and an immutable origin.
    // This is not registered as a plugin service, RPC method or public CLI API.
    // Product presentation only: borrow the existing Store and exact durable
    // completed root Receipt. This does not execute, admit, or produce authority.
    func completedDataToolArguments(thread: ThreadId, run: RunId, receiptId: String,
        callId: String, name: String, version!: String = "", fingerprint!: String = ""): Result<AgentValue> {
        try {
            let rows=database.query("SELECT o.id FROM operations o JOIN runs r ON r.id=o.run_id " +
                "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id " +
                "AND e.tool_call_item_id=o.tool_call_item_id AND e.normalized_plan=o.normalized_plan " +
                "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state " +
                "JOIN items source ON source.id=o.tool_call_item_id AND source.kind='tool_call' " +
                "AND source.thread_id=r.thread_id AND source.turn_id=r.turn_id " +
                "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id " +
                "JOIN items result ON result.id=e.reserved_result_item_id AND result.thread_id=r.thread_id " +
                "AND result.turn_id=r.turn_id AND result.kind='tool_result' " +
                "WHERE receipt.id=? AND receipt.outcome='completed' AND o.state='committed' " +
                "AND r.thread_id=? AND r.id=? AND e.tool_id=? " +
                "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id) LIMIT 2",
                [SqlParameter.Text(receiptId),SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(name)])
            if(rows.size!=1){return Result.Err(AgentError(AgentErrorKind.Conflict,
                "application.plan_receipt_missing","plan presentation requires its exact completed canonical root"))}
            let plan=match(operations.loadPlan(OperationId(rows[0].required(0)),run)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(plan.toolName!=name || plan.effectClass!=OperationEffectClass.ReadOnly ||
                plan.requiredCapabilities.size!=1 || plan.requiredCapabilities[0].kind!=CapabilityKind.WorkspaceRead ||
                !networkPolicyModeIsDenied(plan.networkPolicy.mode)){
                return Result.Err(AgentError(AgentErrorKind.Conflict,"application.plan_receipt_changed",
                    "completed plan Tool no longer has its exact read-only presentation"))}
            let operation=OperationId(rows[0].required(0))
            let actualCall=match(operations.loadCall(operation,run)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(callId=="" || actualCall.callId!=callId || actualCall.name!=name ||
                canonicalAgentValue(actualCall.arguments)!=canonicalAgentValue(plan.canonicalArguments) ||
                (version!="" && (plan.implementation.toolVersion!=version ||
                    plan.implementation.implementationFingerprint!=fingerprint))){
                return Result.Err(AgentError(AgentErrorKind.Conflict,"application.plan_receipt_changed",
                    "plan presentation requires the same actual canonical call and selected implementation"))}
            let result=match(operations.loadCommittedToolResult(operation,run)){
                case Result.Err(error)=>return Result.Err(error)
                case Result.Ok(None)=>return Result.Err(AgentError(AgentErrorKind.Conflict,
                    "application.plan_receipt_missing","plan presentation requires its canonical result"))
                case Result.Ok(Some(value))=>value}
            try{
                if(result.callId!=callId || result.receiptId!=receiptId || result.isError){
                    return Result.Err(AgentError(AgentErrorKind.Conflict,"application.plan_receipt_changed",
                        "plan presentation requires its exact successful canonical result"))}
                Result.Ok(plan.canonicalArguments)
            }finally{result.releasePayload()}
        }catch(_:Exception){Result.Err(AgentError(AgentErrorKind.Conflict,"application.plan_receipt_missing",
            "plan presentation requires its exact completed canonical root"))}
    }

    // Historical UI lookup borrows the actual stored Run for a globally unique
    // completed Receipt; callers cannot invent a Run or use this as authority.
    func completedDataToolHistoryArguments(thread: ThreadId, receiptId: String,
        callId: String, name: String, version!: String = "", fingerprint!: String = ""): Result<AgentValue> {
        try {
            let rows=database.query("SELECT o.run_id FROM operations o JOIN runs r ON r.id=o.run_id " +
                "JOIN operation_receipts receipt ON receipt.operation_id=o.id " +
                "WHERE r.thread_id=? AND receipt.id=? AND receipt.outcome='completed' LIMIT 2",
                [SqlParameter.Text(thread.value),SqlParameter.Text(receiptId)])
            if(rows.size!=1){return Result.Err(AgentError(AgentErrorKind.Conflict,
                "application.plan_receipt_missing","plan history requires its actual completed root Receipt"))}
            completedDataToolArguments(thread,RunId(rows[0].required(0)),receiptId,callId,name,version:version,fingerprint:fingerprint)
        }catch(_:Exception){Result.Err(AgentError(AgentErrorKind.Conflict,"application.plan_receipt_missing",
            "plan history requires its actual completed root Receipt"))}
    }

    public func executeCanonicalHostServiceTool(sessionId: SessionId, origin: HostServiceOrigin,
        capabilities: CapabilitySet, call: ToolCall, approvalDecision: ?ApprovalDecision,
        budget: ExecutionBudget, callerCancellation: ?CancellationToken): Result<ToolInvocationResult> {
        executeHostServiceTool(sessionId, origin, capabilities, call, approvalDecision: approvalDecision,
            budget: budget, callerCancellation: callerCancellation)
    }

    public func executeHostServiceTool(
        sessionId: SessionId,
        origin: HostServiceOrigin,
        capabilities: CapabilitySet,
        call: ToolCall,
        approvalDecision!: ?ApprovalDecision = None,
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1),
        callerCancellation!: ?CancellationToken = None
    ): Result<ToolInvocationResult> {
        canonicalTools.executeHostServiceTool(sessionId, origin, capabilities, call,
            approvalDecision: approvalDecision, budget: budget,
            callerCancellation: callerCancellation)
    }

    // Package-private ingress gateway. A real ingress owner must first obtain
    // the sealed connection from host authentication/export policy; neither
    // request JSON nor persisted External origin can call this on its own.
    func executeExternalTool(connection: ExternalIngressConnection, request: ExternalRequestId,
        call: ToolCall, approvalDecision!: ?ApprovalDecision = None,
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1),
        receivedFrame!: ?ExternalReceivedFrame = None): Result<ToolInvocationResult> {
        canonicalTools.executeExternalTool(connection, request, call, approvalDecision: approvalDecision,
            budget: budget, receivedFrame: receivedFrame)
    }

    private func executeCanonicalToolWithDecision(
        sessionId: SessionId,
        capabilities: CapabilitySet,
        call: ToolCall,
        contextSnapshot: InvocationContextProjection,
        runId: ?RunId,
        approvalDecision: ?ApprovalDecision,
        executionRoot!: String = "",
        trustedControl!: Bool = false,
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1),
        hostServiceOrigin!: ?HostServiceOrigin = None,
        hostCallerCancellation!: ?CancellationToken = None,
        externalConnection!: ?ExternalIngressConnection = None,
        externalRequest!: ?ExternalRequestId = None,
        externalFrame!: ?ExternalReceivedFrame = None,
        directPreparationOwner!: ?ProductDirectPreparationOwner = None,
        commandParticipant!: ?PluginDocumentCommitParticipant = None
    ): Result<ToolInvocationResult> {
        let bindCommand: ?(RunId, Int64) -> Result<Unit> = match (commandParticipant) {
            case Some(participant) => Some({ actualRun, actualEpoch =>
                let actual = match (participant as ProductCommandPreparationParticipant) { case Some(value) => value
                    case None => return commandControlError<Unit>("plugin.command_participant_invalid") }
                actual.bindActualRun(actualRun, actualEpoch)
            })
            case None => None
        }
        canonicalTools.execute(sessionId, capabilities, call, contextSnapshot, runId, approvalDecision,
            executionRoot: executionRoot, trustedControl: trustedControl, budget: budget,
            hostServiceOrigin: hostServiceOrigin, hostCallerCancellation: hostCallerCancellation,
            externalConnection: externalConnection, externalRequest: externalRequest, externalFrame: externalFrame,
            directPreparationOwner: directPreparationOwner, commandParticipant: commandParticipant, commandControlAdmission159e: bindCommand)
    }

    func reserveManagedJob(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ManagedJobReservation> {
        if (prepared.source.operationRoot.isNone() || prepared.source.kind == PreparedInvocationSourceKind.Derived ||
            prepared.source.runId.value != context.runId.value || prepared.source.sessionId.value != context.sessionId.value ||
            prepared.source.epoch != context.epoch || !isManagedJobLaunchPlan(prepared.operationPlan)) {
            return lifecycleLeaseError("task.managed_job_source_required") }
        let runtime = match (threadRuntimes.acquire(ThreadId(context.sessionId.value), context.workspaceRoot)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        runtime.reserveManagedJob(prepared.source.operationRoot.getOrThrow(), prepared.operationId, prepared.operationPlan,
            operations, context.runId, context.epoch)
    }

    // Readiness is only a scheduling hint. reservation.claim() independently
    // proves exact launch output/Receipt and atomically consumes the seal.
    func managedJobLaunchReady(reservation: ManagedJobReservation): Result<Bool> {
        match (reservation.cancellationToken.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let binding = reservation.binding
        try {
            let rows = database.query("SELECT o.state,r.outcome FROM operations o LEFT JOIN operation_receipts r ON r.operation_id=o.id WHERE o.id=? AND o.run_id=?",
                [SqlParameter.Text(binding.parentOperationId.value), SqlParameter.Text(binding.parentRunId.value)])
            if (rows.size != 1) { return lifecycleLeaseError("task.managed_job_launch_missing") }
            let state = rows[0].required(0)
            if (state == "prepared" || state == "waiting_approval" || state == "executing") { return Result.Ok(false) }
            if (state != "committed" || rows[0][1] != Some("completed")) {
                return lifecycleLeaseError("task.managed_job_launch_failed") }
            Result.Ok(true)
        } catch (_: Exception) { lifecycleLeaseError("task.managed_job_launch_unavailable") }
    }

    func executeManagedJob(admission: ManagedJobAdmission, parent: ToolInvocationContext,
        budget: ExecutionBudget, operation: OperationId): ProductManagedJobExecution {
        let binding = admission.binding; let job = binding.declaration
        let execution = executeManagedJobRoot(admission, parent, budget, operation)
        let settled = try {
            let rows = database.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(job.runId.value)])
            var known = rows.size == 1 && ["completed", "failed", "cancelled"].contains(rows[0].required(0)) && budget.snapshot().activeTools == 0
            // Run cancellation can coexist with an Unknown mutation Receipt.
            // Physical cleanup ACK and a terminal Run never refund that debt.
            let effects = database.query("SELECT o.state,COALESCE(r.outcome,'') FROM operations o LEFT JOIN operation_receipts r " +
                "ON r.operation_id=o.id WHERE o.run_id=?", [SqlParameter.Text(job.runId.value)])
            for (effect in effects) {
                if (["prepared", "waiting_approval", "executing", "recovery_required", "unknown"].contains(effect.required(0)) ||
                    !["completed", "rejected", "cancelled", "timed_out", "failed"].contains(effect.required(1))) { known = false }
            }
            known
        } catch (_: Exception) { false }
        ProductManagedJobExecution(execution, budget.snapshot(), settled, operation)
    }

    private func executeManagedJobRoot(admission: ManagedJobAdmission, parent: ToolInvocationContext,
        budget: ExecutionBudget, operation: OperationId): Result<ToolInvocationResult> {
        let launch = admission.binding; let job = launch.declaration
        let runtime = match (threadRuntimes.acquire(job.threadId, parent.workspaceRoot)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let call = match (operations.loadCall(launch.parentOperationId, launch.parentRunId)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let frozenPlan = match (admission.frozenPlan()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let started = match (runtime.startManagedJobTurn(admission, SemanticTurnId("managed-turn-" + job.runId.value),
            ItemId("managed-input-" + job.runId.value), directControlModelLane(job.runId, parent.capabilities,
                threadId: Some(job.threadId)), parent.contextProjection, createdAtMillis: agentUtcMillis())) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let execution: Result<ToolInvocationResult> = try {
            match (runtime.commitManagedJobToolCall(admission, ItemId("managed-call-" + job.runId.value), operation,
                call, job.runId, started.epoch, createdAtMillis: agentUtcMillis())) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(root) =>
                    let context = ToolInvocationContext(job.runId, SessionId(job.threadId.value), parent.capabilities,
                        epoch: started.epoch, cancellation: root.externalCancellationToken.getOrThrow(),
                        toolContext: ToolContextDescriptor(workspaceRoot: parent.workspaceRoot, cwd: parent.cwd,
                            environment: parent.environment, services: parent.services), contextProjection: parent.contextProjection,
                        budget: budget, trustedControl: false)
                    // Persist the exact approved plan through the sealed Task
                    // admission before looking up its current executor. A stale
                    // directory refusal still produces a Prepared-stage fact.
                    match (operations.prepareDirectOperation(root, frozenPlan)) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(_) => match (pipeline.prepareManagedJob(context, root)) {
                            case Result.Err(error) =>
                                let rejected: Result<ToolInvocationResult> = Result.Err(error)
                                match (runtime.resolveOperation(ItemId("result-" + operation.value), operation,
                                    CanonicalToolCallId(call.callId), frozenPlan, OperationAttemptStage.Prepared, rejected,
                                    "receipt-" + operation.value, agentUtcMillis(),
                                    expectedRunId: Some(job.runId), expectedEpoch: Some(started.epoch))) {
                                    case Result.Err(settlement) => Result.Err(settlement)
                                    case Result.Ok(_) => rejected }
                            case Result.Ok(prepared) => ProductTrustedControlToolExecutor(pipeline, operations, runtime)
                                .executeCanonicalPrepared(context, prepared, root, Option<ApprovalDecision>.None)
                        }
                    }
            }
        } catch (_: Exception) {
            Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "task.managed_job_execution_unknown",
                "managed job execution requires reconciliation"))
        }
        let terminal = match (directToolTerminalState(job.runId, execution)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        if (terminal == RunState.Cancelled) {
            return match (runtime.cancel(1000, expectedRunId: Some(job.runId), expectedEpoch: Some(started.epoch))) {
                case Result.Ok(_) => execution; case Result.Err(error) => Result.Err(error) }
        }
        match (runtime.finish(terminal, 1000, expectedRunId: Some(job.runId), expectedEpoch: Some(started.epoch),
            reason: "managed job settled from canonical operation facts")) {
            case Result.Ok(_) => execution; case Result.Err(error) => Result.Err(error) }
    }

    // A successful parent response cannot erase a failed or unknown broker
    // child. Preserve the result payload, but settle the Run from its durable
    // operation facts; completed-Run proof remains unchanged.
    private func directToolTerminalState(runId: RunId,
        execution: Result<ToolInvocationResult>): Result<RunState> {
        canonicalTools.terminalState(runId, execution)
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
            InvocationContextProjection(),
            Option<RunId>.None,
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
            let root = productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Root)).trimAscii()
            if (!isManagedPluginSnapshot(root)) {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.root_outside_managed_store",
                    "Pi and Codex plugin snapshots must remain inside managed package storage"
                ))
            }
            if (descriptor.ecosystem == PluginEcosystem.Codex) {
                productRegistryPrepayCells83(descriptor, descriptor.hookCount * 8 + 8)
                let handlers = ArrayList<ToolHookHandlerSnapshot>()
                for (declaration in productRegistryHooks83(descriptor)) {
                    if (!codexHookGrantAllows(
                        productRegistryCopyText83(declaration.copyText(PluginHookText.Event)), productRegistryCapabilities83(descriptor)
                    )) { continue }
                    handlers.add(ToolHookHandlerSnapshot(
                        productRegistryCopyText83(declaration.copyText(PluginHookText.Event)),
                        productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)),
                        productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Version)),
                        productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest)),
                        root,
                        productRegistryCopyText83(declaration.copyText(PluginHookText.Matcher)),
                        productRegistryCopyText83(declaration.copyText(PluginHookText.Command)),
                        declaration.timeoutMillis
                    ))
                }
                match (catalog.registerHookHandlers(
                    productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)), handlers.toArray()
                )) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => ()
                }
            }
            if (productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Entrypoint)).trimAscii() == "") { return Result.Ok(()) }
            javascriptPluginLifecycleLock.lock()
            try {
                match (mountAndRegisterJavaScriptPlugin(
                    record,
                    javascriptPlugins,
                    catalog,
                    serviceRuntime: Some(ProductJavaScriptPluginServiceRuntime(catalog, pipeline, operations, askRuntime,
            canonicalDatabase173: Some(database), canonicalSummaryTimeout173: canonicalSummaryTimeout173))
                )) {
                    case Result.Ok(_) => Result.Ok(())
                    case Result.Err(error) =>
                        let _ = catalog.unregisterHookHandlers(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)))
                        return Result.Err(error)
                }
            } finally {
                javascriptPluginLifecycleLock.unlock()
            }
        }
        if (descriptor.ecosystem != PluginEcosystem.Axyndra) {
            return Result.Ok(())
        }
        activateAxyndraImportedPlugin(record)
    }

    func restoreImportedPlugin(record: ProductPluginRecord): Result<Unit> {
        // Re-activate the same immutable package through the same protocol.
        // A new process never proves recovery of plugin-local mutable state.
        activateImportedPlugin(record)
    }

    private func activateAxyndraImportedPlugin(
        record: ProductPluginRecord
    ): Result<Unit> {
        let descriptor = record.descriptor
        if (descriptor.entryKind != PluginEntryKind.NativeExecutable) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.entry_kind_migration_required",
                "legacy one-shot plugins cannot execute; migrate to native-executable and the versioned plugin protocol"
            ))
        }
        let root = productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Root)).trimAscii()
        if (!isManagedPluginSnapshot(root)) {
            return Result.Err(AgentError(
                AgentErrorKind.Configuration,
                "plugin.root_outside_managed_store",
                "executable plugin snapshots must remain inside managed package storage"
            ))
        }
        for (capability in productRegistryCapabilities83(descriptor)) {
            if (capability != "workspace.read" && capability != "workspace.write" && capability != "network.http" &&
                capability != "process.channel" && capability != "process.readview" && capability != "tool.readonly" && capability != "document.store") {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.capability_unsupported",
                    "executable plugin capability is outside the product ceiling"
                ))
            }
        }
        let manifest = SignedExtensionPackageManifest(
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Id)),
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Version)),
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.SdkRange)),
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ProtocolRange)),
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Entrypoint)),
            [],
            [],
            productRegistryCapabilities83(descriptor),
            1u32,
            "restart-does-not-replay",
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.ContentDigest)),
            productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Signature))
        )
        // Package trust is checked before initialization. Declared capabilities
        // remain requests; the isolated process receives no ambient grants.
        match (extensionSignatureVerifier) {
            case Some(verifier) => match (validateIsolatedPluginPackage(
                manifest,
                ExtensionExecutionKind.ProcessPlugin,
                1u64,
                productRegistryCapabilities83(descriptor),
                verifier,
                packageRoot: root
            )) {
                case SafeLifecycleResult.Ok(_) => ()
                case SafeLifecycleResult.Err(message) => return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.activation_rejected",
                    message
                ))
            }
            case None => if (productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Signature)) != "") {
                return Result.Err(AgentError(
                    AgentErrorKind.Configuration,
                    "plugin.signature_trust_root_missing",
                    "a signed plugin requires its configured signature trust root"
                ))
            }
        }
        javascriptPluginLifecycleLock.lock()
        try {
            mountAndRegisterJavaScriptPlugin(
                record, javascriptPlugins, catalog,
                serviceRuntime: Some(ProductJavaScriptPluginServiceRuntime(
                    catalog, pipeline, operations, askRuntime,
                    canonicalDatabase173: Some(database), canonicalSummaryTimeout173: canonicalSummaryTimeout173
                ))
            )
        } finally {
            javascriptPluginLifecycleLock.unlock()
        }
    }

    public func close(): Result<Unit> {
        match (stdioIngress.close()) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        javascriptPluginLifecycleLock.lock()
        try {
            javascriptPlugins.close()
        } finally {
            javascriptPluginLifecycleLock.unlock()
        }
    }
    public func javascriptPluginCommands(): Array<ProductJavaScriptPluginCommand> {
        // Activation publishes tools/hooks and command routes as one product
        // lifecycle boundary. Copy routes while holding the same lock, then
        // release it before executing so disable/cancellation can still run.
        javascriptPluginLifecycleLock.lock()
        try {
            javascriptPlugins.commands()
        } finally {
            javascriptPluginLifecycleLock.unlock()
        }
    }

    public func invokeJavaScriptPluginCommand(routeName: String, arguments: String, sessionId: SessionId,
        commandId: String, cancellation: CancellationToken, noticeSink: ProductJavaScriptPluginNoticeSink): Result<Unit> {
        invokePluginCommand(routeName, arguments, sessionId, commandId, cancellation, noticeSink, Option<ProductPluginCommandScope>.None)
    }
    func invokeScopedPluginCommand(routeName: String, arguments: String, scope: ProductPluginCommandScope,
        noticeSink: ProductJavaScriptPluginNoticeSink): Result<Unit> {
        invokePluginCommand(routeName, arguments, scope.sessionId, scope.commandId, scope.cancellation, noticeSink, Some(scope))
    }
    private func invokePluginCommand(
        routeName: String,
        arguments: String,
        sessionId: SessionId,
        commandId: String,
        cancellation: CancellationToken,
        noticeSink: ProductJavaScriptPluginNoticeSink,
        scope: ?ProductPluginCommandScope
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
        for (command in javascriptPluginCommands()) {
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
        match (scope) {
            case Some(owner) => match (owner.bind(javascriptPlugins, selected, arguments, sessionId, commandId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => ()
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
            catalog, pipeline, operations, askRuntime,
            canonicalDatabase173: Some(database), canonicalSummaryTimeout173: canonicalSummaryTimeout173
        ).commandObserver(sessionId, commandId, cancellation, noticeSink)
        match (javascriptPlugins.invoke(
            selected.extensionId, selected.name, argumentsJson,
            identity: identity, cancellation: cancellation, cwd: workspaceRoot,
            hasUI: askRuntime.hasInteractive(sessionId), observer: Some(observer),
            expectedInstanceGeneration: selected.instanceGeneration
        )) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(value) => try { if (value.isError) {
                let details = match (value.value.field("error")) {
                    case Some(item) => item
                    case None => return Result.Err(AgentError(
                        AgentErrorKind.InvalidInput,
                        "plugin.command_failed",
                        "plugin command reported an error"
                    ))
                }
                let code = if (details.unifiedKind == ValueKind.Text) {
                    details.text
                } else { pluginReceiptText(details, "code") }
                let message = if (details.unifiedKind == ValueKind.Text) {
                    pluginReceiptText(value.value, "message")
                } else { pluginReceiptText(details, "message") }
                Result.Err(AgentError(
                    AgentErrorKind.InvalidInput,
                    if (code == "") { "plugin.command_failed" } else { code },
                    if (message == "") { "plugin command reported an error" } else { message }
                ))
            } else {
                if (httpIntentText(value.value, "schema") == "axyndra.command-message/v1") {
                    if (!httpIntentExactFields(value.value, ["schema", "text"]) ||
                        value.value.field("text").getOrThrow().unifiedKind != ValueKind.Text ||
                        value.value.field("text").getOrThrow().text == "" || value.value.field("text").getOrThrow().text.size > 16384) {
                        return commandControlError("plugin.command_message_invalid") }
                    match (cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    match (scope) { case Some(owner) => match (owner.current()) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                        case None =>
                            let descriptor = match (javascriptPlugins.servicePackage(selected.extensionId, selected.instanceGeneration)) {
                                case Result.Err(error) => return Result.Err(error); case Result.Ok(item) => item }
                            match (ProductCommandBinding(javascriptPlugins, selected, descriptor).verify()) {
                                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () } }
                    noticeSink("info", value.value.field("text").getOrThrow().text)
                    return Result.Ok(())
                }
                if (value.value.field("schema").isSome() || value.value.field("local_tool").isSome() || value.value.field("user_control").isSome()) {
                    return match (scope) { case Some(owner) => owner.capture(value.value)
                        case None => commandControlError("plugin.command_user_scope_required") }
                }
                // A command can return noninteractive text (for example help)
                // without requesting an interactive UI service. Every frontend
                // already supplies this notice sink; the result stays bounded.
                match (value.value.field("content")) {
                    case Some(content) =>
                        if (content.unifiedKind != ValueKind.Text || content.text.size > 4096) {
                            return Result.Err(AgentError(AgentErrorKind.InvalidInput,
                                "plugin.command_output_invalid", "command content must be text of at most 4096 bytes"))
                        }
                        if (content.text != "") { noticeSink("info", content.text) }
                    case None => ()
                }
                Result.Ok(())
            } } finally { value.releasePayload() }
        }
    }

    public func deactivateImportedPlugin(record: ProductPluginRecord): Result<Unit> {
        let descriptor = record.descriptor
        if (descriptor.ecosystem == PluginEcosystem.Pi ||
            descriptor.ecosystem == PluginEcosystem.Codex ||
            descriptor.entryKind == PluginEntryKind.NativeExecutable) {
            let _ = catalog.unregisterHookHandlers(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)))
            javascriptPluginLifecycleLock.lock()
            try {
                for (namespace in javascriptPlugins.deactivationNamespaces(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)))) {
                    let _ = catalog.unregisterHookHandlers(namespace)
                    for (tool in javascriptPlugins.toolNames(namespace)) {
                        let _ = catalog.revoke("plugin." + namespace + "." + tool)
                    }
                }
                return javascriptPlugins.unmount(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)))
            } finally {
                javascriptPluginLifecycleLock.unlock()
            }
        }
        if (descriptor.ecosystem != PluginEcosystem.Axyndra) {
            return Result.Ok(())
        }
        let _ = catalog.revoke("plugin." + productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Namespace)) + ".invoke")
        match (isolatedPlugins.deactivate(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Id)))) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => isolatedPlugins.cancelAll(productRegistryCopyText83(descriptor.copyText(PluginDescriptorText.Id)))
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




// Direct synchronous roots retain one Run budget slot while a single child
// temporarily owns it. No second budget or raw-call execution lane is created.
func mountAndRegisterJavaScriptPlugin(
    record: ProductPluginRecord,
    hostManager: ProductJavaScriptPluginHost,
    catalog: ToolCatalog,
    serviceRuntime!: ?ProductJavaScriptPluginServiceRuntime = None
): Result<Unit> {
    let borrowed: ?HostJavaScriptPluginServiceRuntime = match (serviceRuntime) {
        case Some(value) => Some(value); case None => None }
    hostMountAndRegisterPluginTools(record, hostManager, catalog, serviceRuntime: borrowed)
}

func directControlModelLane(runId: RunId, capabilities: CapabilitySet, threadId!: ?ThreadId = None,
    snapshot!: ?ToolSetSnapshot = None): ModelLane {
    hostControlModelLane(runId, capabilities, threadId: threadId, snapshot: snapshot)
}
class ProductStorageServiceProvider <: ServiceProvider<String> {
    public init() {}
    public func acquire(scope: ComponentScope): Result<ServiceLease<String>> {
        Result.Ok(ServiceLease("sqlite-vnext", scope, { => () }))
    }
}
