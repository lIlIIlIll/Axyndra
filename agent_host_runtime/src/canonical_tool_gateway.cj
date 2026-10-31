package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_store.*
import agent_extension_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.convert.*
import std.sync.*

// Composition-owned gateway. It borrows the exact database, Runtime registry,
// catalog and pipeline already owned by the host. Context/snapshot callbacks
// are trusted composition inputs, never contribution DTOs or JSON factories.
public class HostCanonicalToolGateway <: HostServiceToolControl {
    private let database: SqliteDatabase
    private let catalog: ToolCatalog
    private let pipeline: ToolPipeline
    private let ids: IdGenerator
    private let threadRuntimes: ThreadRuntimeRegistry
    private let operations: OperationRuntimePort
    private let workspaceRoot: String
    private let contextForRoot: (String) -> ToolContextDescriptor
    private let requiresToolSnapshot: (String) -> Bool
    private let preAdmissionPolicy: (ToolCall) -> Result<Unit>
    private let ownedFailures113 = HostOwnedCheckpointFailureQueue113()
    public init(database: SqliteDatabase, catalog: ToolCatalog, pipeline: ToolPipeline,
        ids: IdGenerator, threadRuntimes: ThreadRuntimeRegistry, operations: OperationRuntimePort,
        workspaceRoot: String, contextForRoot: (String) -> ToolContextDescriptor,
        requiresToolSnapshot: (String) -> Bool, preAdmissionPolicy: (ToolCall) -> Result<Unit>) {
        this.database = database; this.catalog = catalog; this.pipeline = pipeline; this.ids = ids
        this.threadRuntimes = threadRuntimes; this.operations = operations; this.workspaceRoot = workspaceRoot
        this.contextForRoot = contextForRoot; this.requiresToolSnapshot = requiresToolSnapshot
        this.preAdmissionPolicy = preAdmissionPolicy
    }

    public func takeOwnedCheckpointFailure113(run: RunId): OwnedHostDirectToolResult113 {
        ownedFailures113.take(run, Result<ToolInvocationResult>.Err(hostOwnedCheckpointFailurePending113()))
    }
    public func executeOwnedCheckpointFailure113(sessionId: SessionId, capabilities: CapabilitySet,
        call: ToolCall, contextSnapshot: InvocationContextProjection, runId: ?RunId,
        approvalDecision: ?ApprovalDecision, executionRoot!: String = "", trustedControl!: Bool = false,
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1),
        hostServiceOrigin!: ?HostServiceOrigin = None, hostCallerCancellation!: ?CancellationToken = None,
        externalConnection!: ?ExternalIngressConnection = None, externalRequest!: ?ExternalRequestId = None,
        externalFrame!: ?ExternalReceivedFrame = None, directPreparationOwner!: ?HostDirectPreparationOwner = None,
        commandParticipant!: ?PluginDocumentCommitParticipant = None,
        commandAdmission!: ?(ActiveRunSnapshot) -> Result<Unit> = None,
        commandControlAdmission159e!: ?(RunId, Int64) -> Result<Unit> = None,
        executionSettings180!: AgentValue = nullValue(), approvalModeOverride180!: ?ApprovalMode = None<ApprovalMode>,
        modelFaultCounters180!: ?ModelStreamFaultCounters180 = None<ModelStreamFaultCounters180>,
        frontendCancellation180!: ?CancellationToken = None<CancellationToken>): OwnedHostDirectToolResult113 {
        let actual = match (runId) { case Some(value) => value; case None => ids.nextRunId() }
        let result = execute(sessionId, capabilities, call, contextSnapshot, Some(actual), approvalDecision,
            executionRoot: executionRoot, trustedControl: trustedControl, budget: budget,
            hostServiceOrigin: hostServiceOrigin, hostCallerCancellation: hostCallerCancellation,
            externalConnection: externalConnection, externalRequest: externalRequest, externalFrame: externalFrame,
            directPreparationOwner: directPreparationOwner, commandParticipant: commandParticipant,
            commandAdmission: commandAdmission, commandControlAdmission159e: commandControlAdmission159e,
            executionSettings180: executionSettings180, modelFaultCounters180: modelFaultCounters180, approvalModeOverride180: approvalModeOverride180, frontendCancellation180: frontendCancellation180)
        ownedFailures113.take(actual, result)
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
        execute(sessionId, capabilities, call, InvocationContextProjection(), None<RunId>, approvalDecision,
            trustedControl: true, budget: budget, hostServiceOrigin: Some(origin),
            hostCallerCancellation: callerCancellation)
    }

    // Trusted ingress composition uses the same canonical External gateway.
    // The received frame and connection retain their original sealed authority.
    public func executeExternalTool(connection: ExternalIngressConnection, request: ExternalRequestId,
        call: ToolCall, approvalDecision!: ?ApprovalDecision = None,
        budget!: ExecutionBudget = ExecutionBudget(maxConcurrentTools: 1),
        receivedFrame!: ?ExternalReceivedFrame = None, dataReturn180!: ?HostCanonicalInputReturn180 = None<HostCanonicalInputReturn180>): Result<ToolInvocationResult> {
        match (connection.validateCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let binding = connection.binding
        let probe = ToolInvocationContext(RunId("external-scope-probe"), SessionId(binding.threadId.value),
            binding.ceiling, toolContext: contextForRoot(workspaceRoot), trustedControl: false)
        if (externalInvocationAuthorityScope(probe) != binding.permissionDomain) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "external.context_changed",
                "ingress grant belongs to a different workspace, environment or capability domain"))
        }
        execute(SessionId(binding.threadId.value), binding.ceiling, call,
            InvocationContextProjection(), None<RunId>, approvalDecision, budget: budget,
            externalConnection: Some(connection), externalRequest: Some(request), externalFrame: receivedFrame, dataReturn180: dataReturn180)
    }

    private func contextForRequest180(root: String, settings: AgentValue, counters: ?ModelStreamFaultCounters180): ToolContextDescriptor {
        let base = contextForRoot(root)
        if (settings.unifiedKind == ValueKind.Null) { base } else { ToolContextDescriptor(base, settings, modelFaultCounters180: counters) }
    }
    public func execute(
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
        directPreparationOwner!: ?HostDirectPreparationOwner = None,
        commandParticipant!: ?PluginDocumentCommitParticipant = None,
        commandAdmission!: ?(ActiveRunSnapshot) -> Result<Unit> = None,
        commandControlAdmission159e!: ?(RunId, Int64) -> Result<Unit> = None,
        executionSettings180!: AgentValue = nullValue(),
        modelFaultCounters180!: ?ModelStreamFaultCounters180 = None<ModelStreamFaultCounters180>,
        approvalModeOverride180!: ?ApprovalMode = None<ApprovalMode>,
        frontendCancellation180!: ?CancellationToken = None<CancellationToken>,
        dataReturn180!: ?HostCanonicalInputReturn180 = None<HostCanonicalInputReturn180>
    ): Result<ToolInvocationResult> {
        if ((commandAdmission.isSome() && commandControlAdmission159e.isSome()) ||
            commandParticipant.isSome() != (commandAdmission.isSome() || commandControlAdmission159e.isSome()) ||
            (commandParticipant.isSome() && directPreparationOwner.isNone())) {
            return directPreparationError("command.participant_owner_missing") }
        if (directPreparationOwner.isSome() && (trustedControl || hostServiceOrigin.isSome() ||
            externalConnection.isSome() || approvalDecision.isSome())) {
            return directPreparationError("command.direct_origin_mixed") }
        if (externalConnection.isSome() != externalRequest.isSome() ||
            (externalConnection.isSome() && (trustedControl || hostServiceOrigin.isSome() || hostCallerCancellation.isSome() ||
                frontendCancellation180.isSome() || modelFaultCounters180.isSome() || executionSettings180.unifiedKind != ValueKind.Null || approvalModeOverride180.isSome()))) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied, "external.origin_mixed", "external calls cannot claim trusted host control"))
        }
        match (hostCallerCancellation) {
            case Some(value) => match (value.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            case None => ()
        }
        match (frontendCancellation180) { case Some(token) => match (token.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }; case None => () }
        if (approvalDecision.isSome() && pipeline.requiresSeparatePreparationDecision(ToolInvocationContext(
            RunId("direct-approval-preflight"), sessionId, capabilities,
            toolContext: contextForRequest180(workspaceRoot, executionSettings180, modelFaultCounters180), approvalModeOverride: approvalModeOverride180), call)) {
            return Result.Err(AgentError(AgentErrorKind.PermissionDenied,
                "context.read_separate_approval_required", "read-backed tools require separate frozen read and mutation reviews through Application command approval")) }
        match (preAdmissionPolicy(call)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let contextProjection = try {
            validatedContextSnapshot(contextSnapshot)
        } catch (error: Exception) {
            return Result.Err(AgentError(
                AgentErrorKind.InvalidInput,
                "context.snapshot_invalid",
                error.message
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
        let runBudget = objectValue([
            ValueField("run_kind", textValue(if (externalConnection.isSome()) { "external" } else if (hostServiceOrigin.isSome()) { "host_service" } else { "direct_tool" })),
            ValueField("read_only", boolValue(false)),
            ValueField("max_tool_calls", integerValue(budget.maxToolCalls)),
            ValueField("max_concurrent_tools", integerValue(budget.maxConcurrentTools)),
            ValueField("deadline_millis", integerValue(budget.deadlineMillis))
        ])
        // The compatibility predicate is retained in the constructor, but ordinary
        // roots are classified by the actual published descriptor. Hidden fixed
        // services and control roots keep their original non-catalog lane semantics.
        // Unknown tools still reach canonical rejection and settlement below.
        let ordinary159e = catalog.isPublishedOrdinaryTool159e(call.name, threadId: Some(ThreadId(sessionId.value)))
        let lane159e = hostGatewayModelLane159e(catalog, effectiveRunId, capabilities, ordinary159e, ThreadId(sessionId.value))
        let frame159e = hostCreateDirectGatewayFrame159e(lane159e)
        match (dataReturn180) { case Some(receiver) => receiver.bindGatewayFrame180(frame159e); case None => () }
        let result159e = executeGatewayConsumerFrame159e(runtime, lane159e, frame159e, ordinary159e,
            sessionId, capabilities, call, approvalDecision, executionRoot, trustedControl, budget,
            hostCallerCancellation, directPreparationOwner, commandParticipant, commandAdmission, commandControlAdmission159e,
            contextProjection, effectiveRunId, runBudget, externalConnection, externalRequest, externalFrame, hostServiceOrigin,
            executionSettings180, modelFaultCounters180, approvalModeOverride180, frontendCancellation180, dataReturn180)
        match (frame159e) { case Some(frame) => frame.observeCatalogResult204(result159e); case None => () }
        // All concrete start, admission, Context and executor helpers returned.
        // Runtime and deferred consumers each hold independent paid views.
        lane159e.returnOwnedLaneFrame159()
        match (frame159e) { case Some(frame) => frame.gatewayReturned159e(); case None => () }
        result159e
    }
    private func executeGatewayConsumerFrame159e(runtime: AgentThreadRuntime, lane159e: ModelLane,
        frame159e: ?HostDirectGatewayFrame159e, ordinary159e: Bool,
        sessionId: SessionId, capabilities: CapabilitySet, call: ToolCall, approvalDecision: ?ApprovalDecision,
        executionRoot: String, trustedControl: Bool, budget: ExecutionBudget,
        hostCallerCancellation: ?CancellationToken, directPreparationOwner: ?HostDirectPreparationOwner,
        commandParticipant: ?PluginDocumentCommitParticipant, commandAdmission: ?(ActiveRunSnapshot) -> Result<Unit>,
        commandControlAdmission159e: ?(RunId, Int64) -> Result<Unit>, contextProjection: InvocationContextProjection,
        effectiveRunId: RunId, runBudget: AgentValue, externalConnection: ?ExternalIngressConnection,
        externalRequest: ?ExternalRequestId, externalFrame: ?ExternalReceivedFrame, hostServiceOrigin: ?HostServiceOrigin,
        executionSettings180: AgentValue, modelFaultCounters180: ?ModelStreamFaultCounters180, approvalModeOverride180: ?ApprovalMode, frontendCancellation180: ?CancellationToken,
        dataReturn180: ?HostCanonicalInputReturn180
    ): Result<ToolInvocationResult> {
        match (dataReturn180) { case Some(receiver) => receiver.enterOriginalStartHelper180(); case None => () }
        let admitted159e = startGatewayRunFrame159e(runtime, lane159e, effectiveRunId, sessionId, call,
            contextProjection, runBudget, budget, externalConnection, externalRequest, externalFrame, hostServiceOrigin)
        let (started, serviceAdmission, externalAdmission) = match (admitted159e) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (frame159e) { case Some(frame) => frame.bindStarted159e(started); case None => () }
        executeAdmittedGatewayFrame159e(runtime, started, serviceAdmission, externalAdmission,
            frame159e, ordinary159e, sessionId, capabilities, call, approvalDecision, executionRoot, trustedControl, budget,
            hostCallerCancellation, directPreparationOwner, commandParticipant, commandAdmission, commandControlAdmission159e,
            contextProjection, effectiveRunId, executionSettings180, modelFaultCounters180, approvalModeOverride180, frontendCancellation180, dataReturn180)
    }
    private func startGatewayRunFrame159e(runtime: AgentThreadRuntime, lane159e: ModelLane,
        effectiveRunId: RunId, sessionId: SessionId, call: ToolCall,
        contextProjection: InvocationContextProjection, runBudget: AgentValue, budget: ExecutionBudget,
        externalConnection: ?ExternalIngressConnection, externalRequest: ?ExternalRequestId,
        externalFrame: ?ExternalReceivedFrame, hostServiceOrigin: ?HostServiceOrigin
    ): Result<(ActiveRunSnapshot, ?HostServiceRunAdmission, ?ExternalCallAdmission)> {
        var externalAdmission: ?ExternalCallAdmission = None
        let (started, serviceAdmission): (ActiveRunSnapshot, ?HostServiceRunAdmission) = if (externalConnection.isSome()) {
            let admitted = match (runtime.startExternalTurn(externalConnection.getOrThrow(), externalRequest.getOrThrow(), call,
                SemanticTurnId("external-turn-" + effectiveRunId.value), effectiveRunId,
                ItemId("external-input-" + effectiveRunId.value),
                lane159e, contextProjection,
                createdAtMillis: agentUtcMillis(), deadlineMillis: budget.deadlineMillis, runBudgetSnapshot: runBudget, receivedFrame: externalFrame)) {
                case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error)
            }
            externalAdmission = Some(admitted)
            (admitted.run, None)
        } else { match (hostServiceOrigin) {
            case Some(origin) =>
                let admitted = match (runtime.startHostServiceTurn(
                    SemanticTurnId("direct-tool-turn-" + effectiveRunId.value), effectiveRunId,
                    ItemId("host-service-input-" + effectiveRunId.value), origin,
                    lane159e, contextProjection,
                    createdAtMillis: agentUtcMillis(), deadlineMillis: budget.deadlineMillis,
                    runBudgetSnapshot: runBudget
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                (admitted.run, Some(admitted))
            case None =>
                let admitted = match (runtime.startTurn(
                    SemanticTurnId("direct-tool-turn-" + effectiveRunId.value), effectiveRunId,
                    ItemId("direct-tool-input-" + effectiveRunId.value),
                    ThreadItemContent.UserMessage([ThreadMessagePart.Text("direct tool: " + call.name)]),
                    lane159e, contextProjection,
                    createdAtMillis: agentUtcMillis(), deadlineMillis: budget.deadlineMillis,
                    runBudgetSnapshot: runBudget
                )) {
                    case Result.Ok(value) => value
                    case Result.Err(error) => return Result.Err(error)
                }
                (admitted, None)
        } }
        Result.Ok((started, serviceAdmission, externalAdmission))
    }
    private func executeAdmittedGatewayFrame159e(runtime: AgentThreadRuntime, started: ActiveRunSnapshot,
        serviceAdmission: ?HostServiceRunAdmission, externalAdmission: ?ExternalCallAdmission,
        frame159e: ?HostDirectGatewayFrame159e, ordinary159e: Bool, sessionId: SessionId, capabilities: CapabilitySet, call: ToolCall,
        approvalDecision: ?ApprovalDecision, executionRoot: String, trustedControl: Bool, budget: ExecutionBudget,
        hostCallerCancellation: ?CancellationToken, directPreparationOwner: ?HostDirectPreparationOwner,
        commandParticipant: ?PluginDocumentCommitParticipant,
        commandAdmission: ?(ActiveRunSnapshot) -> Result<Unit>, commandControlAdmission159e: ?(RunId, Int64) -> Result<Unit>,
        contextProjection: InvocationContextProjection, effectiveRunId: RunId,
        executionSettings180: AgentValue, modelFaultCounters180: ?ModelStreamFaultCounters180, approvalModeOverride180: ?ApprovalMode, frontendCancellation180: ?CancellationToken,
        dataReturn180: ?HostCanonicalInputReturn180): Result<ToolInvocationResult> {
        let cancellation = if (externalAdmission.isSome()) { externalAdmission.getOrThrow().cancellationToken } else { match (runtime.childCancellationToken(
            expectedRunId: Some(started.runId),
            expectedEpoch: Some(started.epoch)
        )) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        } }
        match (commandAdmission) {
            case Some(bindActualRun) => match (bindActualRun(started.forkIndependentView159())) {
                case Result.Err(error) => return finishDirectExecution(runtime, started, Result.Err(error), dataReturn180: dataReturn180); case Result.Ok(_) => () }
            case None => ()
        }
        match (commandControlAdmission159e) {
            case Some(bindActualRun) => match (bindActualRun(started.runId, started.epoch)) {
                case Result.Err(error) => return finishDirectExecution(runtime, started, Result.Err(error), dataReturn180: dataReturn180); case Result.Ok(_) => () }
            case None => ()
        }
        let startupCancellation = HostCallerCancellation(cancellation, hostCallerCancellation, frontendCancellation180: frontendCancellation180)
        let invocationRoot = if (executionRoot.trimAscii() == "") { workspaceRoot } else { executionRoot }
        // Borrow the immutable snapshot owned and persisted by this actual Run;
        // a publication change cannot substitute a newly resolved catalog here.
        let contextData180 = match (dataReturn180) { case Some(receiver) => Some(receiver.reserveContextBeforeConstruction180()); case None => None<LogicalJsonOwnerReservation> }
        let invocationContext = ToolInvocationContext(effectiveRunId, sessionId, capabilities, epoch: started.epoch,
            cancellation: startupCancellation.token, toolContext: contextForRequest180(invocationRoot, executionSettings180, modelFaultCounters180),
            approvalModeOverride: approvalModeOverride180,
            contextProjection: contextProjection, budget: budget, toolSetSnapshot: if (ordinary159e) { started.lane.legacyToolSetSnapshot159() } else { None<ToolSetSnapshot> },
            ownedToolSetSnapshot159: if (ordinary159e) { started.lane.forkOwnedToolSetSnapshot159() } else { None<SharedToolSetSnapshot159> }, trustedControl: trustedControl,
            hostDocumentCommitParticipant: commandParticipant,
            ownedInvocationData180: contextData180)
        match (dataReturn180) { case Some(receiver) => receiver.bindActualContext180(invocationContext); case None => () }
        invocationContext.bindPaidExecutionFailureSink173(ownedFailures113)
        match (frame159e) { case Some(frame) => frame.bindContext159e(invocationContext); case None => () }
        match (frame159e) { case Some(frame) => frame.bindCatalogConsumer204(pipeline.beginHostCatalogConsumer204(invocationContext)); case None => () }
        let actualOwner: ?HostDirectPreparationOwner = if (directPreparationOwner.isSome()) { directPreparationOwner }
            else if (!trustedControl && serviceAdmission.isNone() && externalAdmission.isNone() &&
                pipeline.hasPreparationRead(invocationContext, call)) {
                Some(HostDirectPreparationOwner({ => invocationContext.cancellation.check() }, allowDeferred: false))
            } else { None }
        match (actualOwner) {
            case Some(owner) =>
                match (frame159e) { case Some(frame) => frame.expectOwnerReturn159e(); case None => () }
                owner.bind({ result => finishDirectExecution(runtime, started, result, dataReturn180: dataReturn180) },
                { => startupCancellation.close() },
                { => acknowledgeDirectCleanup(runtime, started, call.callId, call.name, budget) },
                ownedFailures113: Some(ownedFailures113), ownedRun113: Some(started.runId), gatewayFrame159e: frame159e)
            case None => ()
        }
        try {
        let execution = HostTrustedControlToolExecutor(pipeline, operations, runtime,
            hostServiceAdmission: serviceAdmission, externalAdmission: externalAdmission,
            directPreparationOwner: actualOwner, ownedFailures113: ownedFailures113,
            ownedRuntimeRegistry204: threadRuntimes as SqliteThreadRuntimeRegistry).invoke(
            invocationContext,
            call,
            approvalDecision: approvalDecision
        )
        let result = match (actualOwner) {
            case Some(owner) => owner.complete(execution)
            case None => finishDirectExecution(runtime, started, execution, dataReturn180: dataReturn180)
        }
        // The internally-created nondeferred owner has no caller which could
        // later retire it. Its original real SQL/physical proof remains required.
        if (frame159e.isSome() && directPreparationOwner.isNone()) {
            match (actualOwner) { case Some(owner) => let _ = owner.closeAcknowledgement(); case None => () }
        }
        result
        } catch (error: OwnedCanonicalDataFailure113) {
            match (dataReturn180) { case Some(receiver) => receiver.retainOriginalException180(error); case None => () }
            let failed = Result<ToolInvocationResult>.Err(error.error)
            match (actualOwner) { case Some(owner) => owner.complete(failed); case None => failed }
        } catch (error: Exception) {
            match (dataReturn180) { case Some(receiver) => receiver.retainOriginalException180(error); case None => () }
            let failed = Result<ToolInvocationResult>.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "command.direct_execution_failed", error.message))
            match (actualOwner) { case Some(owner) => owner.complete(failed); case None => failed }
        } finally { if (actualOwner.isNone()) { startupCancellation.close() } }
    }

    // Only physical reclamation facts from this already acquired actual Run.
    // All variable SQLite strings and subsequent codec DOMs share the original
    // Native pool; COUNT/UTF8 metadata is checked before transferring each row.
    // No permission, new Source, execution, recovery write or Port callback is
    // obtained from these facts. Unknown obligations preserve the saved error.
    private func acknowledgeDirectCleanup(runtime: AgentThreadRuntime, started: ActiveRunSnapshot,
        originalCallId: String, originalToolName: String, budget: ExecutionBudget): Result<Unit> {
        if (runtime.threadSnapshot().thread.id.value != started.threadId.value ||
            budget.snapshot().activeTools != 0) { return hostDirectCleanupError() }
        match (runtime.activeRunControl159()) {
            case Some(active) => if (active[2].value == started.runId.value) { return hostDirectCleanupError() }
            case None => ()
        }
        try {
            let scope = ContinuationDocumentReadScope({ bytes => reserveNativeDocumentPayload(bytes) })
            try {
                let proof: Result<Unit> = database.readTransaction { transaction: SqliteTransaction =>
                    let identity = [SqlParameter.Text(started.runId.value)]
                    let total = scope.query(transaction, "SELECT COUNT(*) FROM operations WHERE run_id=?", identity, 1)
                    if (total.size != 1 || Int64.parse(total[0].required(0)) < 1 ||
                        Int64.parse(total[0].required(0)) > 255) { return hostDirectCleanupError() }
                    let runs = scope.query(transaction,
                        "SELECT r.thread_id,r.turn_id,r.epoch,r.state,r.finished_at_millis," +
                            "t.thread_id,t.state,t.active_run_id,h.active_turn_id FROM runs r " +
                            "JOIN turns t ON t.id=r.turn_id JOIN threads h ON h.id=r.thread_id WHERE r.id=?", identity, 9)
                    if (runs.size != 1 || runs[0].required(0) != started.threadId.value ||
                        runs[0].required(1) != started.turnId.value || runs[0].required(2) != started.epoch.toString() ||
                        !["completed", "failed", "cancelled"].contains(runs[0].required(3)) || runs[0][4].isNone() ||
                        runs[0].required(5) != started.threadId.value ||
                        !["completed", "failed", "cancelled"].contains(runs[0].required(6)) || runs[0][7].isSome() ||
                        runs[0][8] == Some(started.turnId.value)) { return hostDirectCleanupError() }
                    let effects = scope.query(transaction,
                        "SELECT o.id,o.state,o.tool_call_item_id,o.normalized_plan,e.run_id,e.tool_call_item_id," +
                            "e.normalized_plan,e.reserved_receipt_id,e.reserved_result_item_id,r.id,r.outcome," +
                            "a.parent_operation_id,p.run_id,r.detail,r.verification,e.tool_id,p.tool_call_item_id " +
                            "FROM operations o LEFT JOIN operation_effect_records e ON e.operation_id=o.id " +
                            "LEFT JOIN operation_receipts r ON r.operation_id=o.id " +
                            "LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id " +
                            "LEFT JOIN operations p ON p.id=a.parent_operation_id WHERE o.run_id=?", identity, 17)
                    if (effects.size.toString() != total[0].required(0)) { return hostDirectCleanupError() }
                    var originalRoots: Int64 = 0
                    for (row in effects) {
                        if (row[4] != Some(started.runId.value) || row[5] != row[2] || row[6] != row[3] ||
                            row[7].isNone() || row[8].isNone() || row[9] != row[7] || row[10].isNone() ||
                            !["completed", "rejected", "cancelled", "timed_out", "failed"].contains(row.required(10))) {
                            return hostDirectCleanupError()
                        }
                        // Original bounded length-frame/node preflight happens
                        // before decode constructs any full plan/value DOM.
                        for (index in [3, 6, 13, 14]) { scope.preflightStored(row.required(index)) }
                        let plan = decodeOperationPlan(row.required(3))
                        if (row[15] != Some(plan.toolName)) { return hostDirectCleanupError() }
                        if (row[11].isSome()) {
                            // Real Derived children settle only their reserved
                            // Receipt; their reserved Thread result must be absent.
                            let expectedState = if (row.required(10) == "completed") { "committed" } else { row.required(10) }
                            if (row.required(1) != expectedState || row[12] != Some(started.runId.value) ||
                                row[16] != row[2] || !scope.query(transaction, "SELECT id FROM items WHERE id=?",
                                    [SqlParameter.Text(row.required(8))], 1).isEmpty()) { return hostDirectCleanupError() }
                            let _ = decodeStoredValue(row.required(13))
                            let _ = decodeStoredValue(row.required(14))
                        } else {
                            if (row.required(1) != "committed") { return hostDirectCleanupError() }
                            let slots = scope.query(transaction,
                                "SELECT c.thread_id,c.turn_id,c.kind,c.payload,i.thread_id,i.turn_id,i.kind,i.payload " +
                                    "FROM items c JOIN items i ON i.id=? WHERE c.id=?",
                                [SqlParameter.Text(row.required(8)), SqlParameter.Text(row.required(2))], 8)
                            if (slots.size != 1 || slots[0].required(0) != started.threadId.value ||
                                slots[0].required(1) != started.turnId.value || slots[0].required(2) != "tool_call" ||
                                slots[0].required(4) != started.threadId.value || slots[0].required(5) != started.turnId.value ||
                                slots[0].required(6) != "tool_result") { return hostDirectCleanupError() }
                            scope.preflightStored(slots[0].required(3)); scope.preflightStored(slots[0].required(7))
                            let callId = match (decodeStoredThreadContent(slots[0].required(3))) {
                                case ThreadItemContent.ToolCall(id, name, _) =>
                                    if (name != plan.toolName) { return hostDirectCleanupError() }
                                    if (id.value == originalCallId && name == originalToolName) { originalRoots += 1 }
                                    id.value
                                case _ => return hostDirectCleanupError()
                            }
                            match (decodeStoredThreadContent(slots[0].required(7))) {
                                case ThreadItemContent.ToolResult(id, op, receipt, _, _) =>
                                    if (id.value != callId || op.value != row.required(0) ||
                                        receipt != row.required(7)) { return hostDirectCleanupError() }
                                case _ => return hostDirectCleanupError()
                            }
                        }
                    }
                    if (originalRoots != 1 || budget.snapshot().activeTools != 0) { return hostDirectCleanupError() }
                    Result.Ok(())
                }
                proof
            } finally { scope.close() }
        } catch (_: Exception) { hostDirectCleanupError() }
    }
    private func finishDirectExecution(runtime: AgentThreadRuntime, started: ActiveRunSnapshot,
        execution: Result<ToolInvocationResult>, dataReturn180!: ?HostCanonicalInputReturn180 = None<HostCanonicalInputReturn180>): Result<ToolInvocationResult> {
        var resultTransferred = false
        try {
        let terminal = match (terminalState(started.runId, execution)) {
            case Result.Ok(value) => value
            case Result.Err(error) => return Result.Err(error)
        }
        if (terminal == RunState.Cancelled) {
            let consumed204 = consumeDirectCancellationFrame204(runtime, started)
            match (dataReturn180) { case Some(receiver) => receiver.bindOriginalScope180(consumed204[2]); case None => () }
            // The complete settlement consumer has returned. This independent
            // returned Run view is distinct from started and the Runtime root.
            match (consumed204[1]) { case Some(view) => view.returnOwnedLaneView159(); case None => () }
            return match (consumed204[0]) {
                case Result.Ok(_) => resultTransferred = true; execution
                case Result.Err(error) => Result.Err(error)
            }
        }
        let consumed204 = consumeDirectFinishFrame204(runtime, started, terminal)
        match (dataReturn180) { case Some(receiver) => receiver.bindOriginalScope180(consumed204[2]); case None => () }
        match (consumed204[1]) { case Some(view) => view.returnOwnedLaneView159(); case None => () }
        match (consumed204[0]) {
            case Result.Ok(_) => resultTransferred = true; execution
            case Result.Err(error) => Result.Err(error)
        }
        } finally { if (!resultTransferred) { releaseToolInvocationPayload(execution) } }
    }

    // These concrete consumers retain the original complete settlement until
    // their whole frames return. They export only its original error or the
    // independent prepaid Run view which the outer caller then actually returns.
    private func consumeDirectCancellationFrame204(runtime: AgentThreadRuntime,
        started: ActiveRunSnapshot): (Result<Unit>, ?ActiveRunSnapshot, ?OwnedTaskReturnWitness113) {
        match (runtime.cancel(1000,
            expectedRunId: Some(started.runId), expectedEpoch: Some(started.epoch))) {
            case Result.Ok(value) => (Result<Unit>.Ok(()), Some(value.run), value.ownedTaskReturnWitness113())
            case Result.Err(error) => (Result<Unit>.Err(error), None<ActiveRunSnapshot>, None<OwnedTaskReturnWitness113>)
        }
    }
    private func consumeDirectFinishFrame204(runtime: AgentThreadRuntime,
        started: ActiveRunSnapshot, terminal: RunState): (Result<Unit>, ?ActiveRunSnapshot, ?OwnedTaskReturnWitness113) {
        match (runtime.finish(
            terminal, 1000,
            expectedRunId: Some(started.runId),
            expectedEpoch: Some(started.epoch),
            reason: if (terminal == RunState.Completed) {
                "direct tool completed"
            } else {
                "direct tool did not complete"
            }
        )) {
            case Result.Ok(value) => (Result<Unit>.Ok(()), Some(value.run), value.ownedTaskReturnWitness113())
            case Result.Err(error) => (Result<Unit>.Err(error), None<ActiveRunSnapshot>, None<OwnedTaskReturnWitness113>)
        }
    }

    public func terminalState(
        runId: RunId,
        execution: Result<ToolInvocationResult>
    ): Result<RunState> {
        var terminal = match (execution) {
            case Result.Ok(ToolInvocationResult.Completed(value)) =>
                if (value.isError) { RunState.Failed } else { RunState.Completed }
            case Result.Err(error) =>
                if (error.kind == AgentErrorKind.Cancelled) { return Result.Ok(RunState.Cancelled) }
                if (error.kind == AgentErrorKind.RecoveryRequired) { RunState.RecoveryRequired }
                else { RunState.Failed }
            case _ => RunState.Failed
        }
        try {
            let rows = database.query(
                "SELECT o.state,COALESCE(r.outcome,'') FROM operations o " +
                    "LEFT JOIN operation_receipts r ON r.operation_id=o.id WHERE o.run_id=?",
                [SqlParameter.Text(runId.value)]
            )
            for (row in rows) {
                let state = row.required(0)
                let outcome = row.required(1)
                if (outcome == "" || outcome == "unknown" || state == "recovery_required" ||
                    state == "unknown" || state == "prepared" || state == "waiting_approval" ||
                    state == "executing") {
                    return Result.Ok(RunState.RecoveryRequired)
                }
                if (state != "committed" || outcome != "completed") {
                    if (terminal == RunState.Completed) { terminal = RunState.Failed }
                }
            }
            Result.Ok(terminal)
        } catch (error: Exception) {
            Result.Err(AgentError(AgentErrorKind.RecoveryRequired,
                "operation.direct_terminal_unavailable", error.message))
        }
    }

}

public func hostControlModelLane(runId: RunId, capabilities: CapabilitySet, threadId!: ?ThreadId = None, snapshot!: ?ToolSetSnapshot = None): ModelLane {
    let entries = ArrayList<ToolSnapshotEntry>()
    let _ = capabilities
    ModelLane(
        ModelLaneRole.Main,
        "direct-control",
        "none",
        "direct-control-v1",
        ModelLaneCapabilitiesSnapshot(
            streaming: false,
            tools: snapshot.isSome(),
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
        match (snapshot) { case Some(value) => value; case None => ToolSetSnapshot("direct-control-catalog-" + runId.value, entries.toArray(), threadId: threadId) },
        "direct-control-v1"
    )
}

func hostDirectCleanupError(): Result<Unit> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "command.cleanup_not_acknowledged",
        "the original actual Direct Run still requires its canonical terminal acknowledgement"))
}
