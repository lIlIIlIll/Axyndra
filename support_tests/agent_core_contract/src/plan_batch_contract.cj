package agent_core_contract

import agent_core.*
import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import std.collection.*
import std.fs.*
import tool_runtime.*
import yjson.*
import yjson_support.*

class PlanBatchReadExecutor <: ToolExecutor {
    var executions: Int64 = 0

    public func execute(_: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        executions += 1
        Result.Ok(ToolResult(prepared.call.callId, textValue("must not execute")))
    }
}

class PlanBatchAdmissionModel <: ModelPort & ReturningModelInputPort159 & ReturningModelTranscriptPort159 {
    private let arguments: AgentValue
    private let approvalArguments: ?AgentValue
    var calls: Int64 = 0

    init(arguments: AgentValue, approvalArguments!: ?AgentValue = None) {
        this.arguments = arguments
        this.approvalArguments = approvalArguments
    }

    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        executeFrame204(request, events)
    }
    public func executeReturningInput159(request: ModelRequest, events: ModelEventSink,
        _: ModelInputDataBudget159): ModelInputReturn159 {
        let result = executeFrame204(request, events)
        // No request/input alias is stored. Only this complete finite helper
        // returning normally can supply the typed synchronous return.
        ModelInputReturn159.Returned(result)
    }
    public func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        let result = planBatchNoTranscriptFrame204(request)
        loan.returnModelToolsFrame159()
        result
    }
    private func executeFrame204(_: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        events(ModelEvent.Completed)
        let blocks = ArrayList<ModelBlock>()
        blocks.add(ModelBlock(ModelBlockKind.ToolCall, callId: "plan-batch-first", name: "read", arguments: arguments))
        blocks.add(ModelBlock(ModelBlockKind.ToolCall, callId: "plan-batch-second", name: "read", arguments: arguments))
        match (approvalArguments) {
            case Some(value) =>
                blocks.add(ModelBlock(ModelBlockKind.ToolCall, callId: "plan-batch-approval", name: "write", arguments: value))
                blocks.add(ModelBlock(ModelBlockKind.ToolCall, callId: "plan-batch-deferred", name: "read", arguments: arguments))
            case None => ()
        }
        Result.Ok(contractModelReply(blocks.toArray()))
    }
}

// A concrete finite terminal provider for this managed-lifetime fixture. No
// request, system, tools, transcript or event callback is cached or exported.
class PlanBatchTerminalModel204 <: ModelPort & ReturningModelInputPort159 & ReturningModelTranscriptPort159 {
    var calls: Int64 = 0
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        executeFrame204(request, events)
    }
    public func executeReturningInput159(request: ModelRequest, events: ModelEventSink,
        _: ModelInputDataBudget159): ModelInputReturn159 {
        let result = executeFrame204(request, events)
        ModelInputReturn159.Returned(result)
    }
    public func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        let result = planBatchNoTranscriptFrame204(request)
        loan.returnModelToolsFrame159()
        result
    }
    private func executeFrame204(_: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1
        events(ModelEvent.Completed)
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "done")], stopReason: "end_turn"))
    }
}

private func planBatchNoTranscriptFrame204(_: ModelRequest): ?String { None }

class PlanBatchAudit <: AuditPort {
    var approvalRequested = false
    var deferredPrepared = false

    public func append(event: AgentEvent): Result<Unit> {
        let call = event.detail.field("call_id").getOrThrow().text
        if (call == "plan-batch-approval" &&
            event.detail.field("action").getOrThrow().text == "tool.approval_requested") { approvalRequested = true }
        if (call == "plan-batch-deferred") { deferredPrepared = true }
        Result.Ok(())
    }
}

// Both calls prepare successfully. The first consumes the single action
// reservation, so admission of the second fails before either executor starts.
func planBatchAdmissionFailureContract(): Unit {
    planBatchAdmissionFailureCase(false)
    planBatchAdmissionFailureCase(true)
    planExecutionBoundaryCase204(false)
    planExecutionBoundaryCase204(true)
    planExecutionBoundaryCase204(false, commitAmbiguous: true)
    planRequestDataRefusalCase204()
}

func planBatchAdmissionFailureCase(withDeferred: Bool): Unit {
    let temporary = Directory.createTemp("target").toString()
    let root = canonicalize(Path(temporary)).toString()
    let database = SqliteDatabase(root + "/plan-batch.db")
    try {
        let runs = SqliteRunRepository(database)
        let registry = SqliteThreadRuntimeRegistry(database,
            ContextProjector("plan-batch", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
        let operations = DurableOperationStore(database)
        let catalog = planBatchReadCatalog204()
        let plans = DurablePlanExecutionStore(database, knownParentAllocation: Some({ bytes =>
            catalog.reserveRegistryData180(bytes).getOrThrow()
        }))
        let executor = PlanBatchReadExecutor()
        let descriptor = ToolDescriptor(ModelToolDefinition("read", "batch admission regression", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), supervisedExecutionSafe: true)
        expect(catalog.register(descriptor, executor).isOk(), "supervised batch read registers")
        let pathArguments = objectValue([ValueField("path", textValue(root + "/source.txt"))])
        let action = PlanAction("read-once", ["read"], ["denied"], OperationEffectClass.ReadOnly,
            pathArguments, 1, exactArguments: true, toolIdentities: objectValue([
                ValueField("read", objectValue([
                    ValueField("version", textValue(descriptor.implementationVersion)),
                    ValueField("fingerprint", textValue(descriptor.implementationFingerprint)),
                    ValueField("schema_digest", textValue(descriptor.schemaDigest))
                ]))
            ]))
        let session = SessionId("plan-batch-session")
        let steps = ArrayList<PlanExecutionStep>()
        steps.add(PlanExecutionStep(PlanStepId("inspect"), [], true, [action]))
        var approvalArguments: ?AgentValue = None
        if (withDeferred) {
            let writeDescriptor = ToolDescriptor(ModelToolDefinition("write", "approval barrier regression", objectValue([])),
                Capability(CapabilityKind.WorkspaceWrite), sideEffecting: true, supervisedExecutionSafe: true)
            expect(catalog.register(writeDescriptor, executor).isOk(), "batch write uses the real approval policy")
            let writeArguments = objectValue([ValueField("path", textValue(root + "/output.txt")),
                ValueField("content", textValue("must not write"))])
            let writeAction = PlanAction("write-once", ["write"], ["denied"], OperationEffectClass.WorkspaceMutation,
                writeArguments, 1, exactArguments: true, toolIdentities: objectValue([
                    ValueField("write", objectValue([
                        ValueField("version", textValue(writeDescriptor.implementationVersion)),
                        ValueField("fingerprint", textValue(writeDescriptor.implementationFingerprint)),
                        ValueField("schema_digest", textValue(writeDescriptor.schemaDigest))
                    ]))
                ]))
            steps.add(PlanExecutionStep(PlanStepId("write"), [], false, [writeAction]))
            approvalArguments = Some(objectValue([
                ValueField("path", textValue(root + "/output.txt")), ValueField("content", textValue("must not write")),
                ValueField("_plan", objectValue([
                    ValueField("step_id", textValue("write")), ValueField("action_id", textValue("write-once"))
                ]))
            ]))
        }
        let contract = PlanContract([root], steps.toArray())
        expect(plans.activate("plan-batch-execution", session.value, contract).isOk(),
            "batch fixture activates the immutable single-attempt contract")
        let arguments = objectValue([
            ValueField("path", textValue(root + "/source.txt")),
            ValueField("_plan", objectValue([
                ValueField("step_id", textValue("inspect")), ValueField("action_id", textValue("read-once"))
            ]))
        ])
        let model = PlanBatchAdmissionModel(arguments, approvalArguments: approvalArguments)
        let audit = PlanBatchAudit()
        let pipeline = ToolPipeline(catalog, operations, audit, FixtureIds(), plans: Some(plans))
        let core = AgentCore(model, runs, pipeline, catalog, threadRuntimes: Some(registry),
            operationRuntime: Some(operations), modelDecisionRuntime: Some(SqliteModelDecisionStore(database)))
        let runId = RunId("plan-batch-run")
        let requestCustody = PlanRequestCustody204(catalog.reserveRegistryData180(131072).getOrThrow())
        let result = planBatchOwnedStartFrame204(core, runId, session, root,
            "read the approved source once", CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead),
                Capability(CapabilityKind.WorkspaceWrite)]), true, requestCustody)
        requestCustody.returnApplicationFrame204()
        expect(match (core.takeOwnedCheckpointFailure113(runId)) {
            case OwnedAgentRunResult113.Existing(_) => true; case _ => false
        } && requestCustody.isDataReturned204(),
            "actual no-head collector returns custody after the complete managed Core and application frames")

        expect(result.isError() && result.error().getOrThrow().code == "plan.admission_denied" &&
            model.calls == 1 && executor.executions == 0,
            "second admission rejects the whole batch before any executor starts")
        let receipts = database.query("SELECT r.outcome,r.detail FROM operations o JOIN operation_receipts r ON r.operation_id=o.id WHERE o.run_id=?",
            [SqlParameter.Text(runId.value)])
        let expectedCalls = if (withDeferred) { 4 } else { 2 }
        expect(receipts.size == expectedCalls, "every committed call retains its own canonical receipt")
        for (row in receipts) {
            expect(row.required(0) == "rejected" && planBatchExplicitlyNotStarted(decodeStoredValue(row.required(1))),
                "each canonical rejection explicitly records that its target never started")
        }
        expect(database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions a LEFT JOIN operation_receipts r ON r.operation_id=a.operation_id WHERE r.id IS NULL") == 0,
            "aborted batch has no executor handoff or unresolved admitted Operation")
        let runtime = registry.acquire(ThreadId(session.value), root).value().getOrThrow()
        var paired: Int64 = 0
        for (item in runtime.threadSnapshot().items) {
            match (item.content) {
                case ThreadItemContent.ToolResult(_, _, _, _, isError) =>
                    paired += 1
                    expect(isError, "unexecuted batch calls never commit fabricated success")
                case _ => ()
            }
        }
        expect(paired == expectedCalls && runtime.activeRun().isNone(),
            "all canonical calls are paired before the failed Run releases its owner")
        if (withDeferred) {
            expect(audit.approvalRequested && !audit.deferredPrepared &&
                database.scalarInt("SELECT COUNT(*) FROM approvals") == 0 && !exists(Path(root + "/output.txt")),
                "real approval preparation defers the fourth call; batch rejection settles both without approval or effects")
        }
        let readPayer = catalog.reserveRegistryData180(4096).getOrThrow()
        let projectionOwner = plans.openInspection204(runId, readPayer).value().getOrThrow()
        readPayer.close()
        let projectionConsumer = projectionOwner.beginConsumer204()
        let settled = planBatchSettledProjection204(projectionConsumer)
        projectionConsumer.returnConsumerFrame204(); projectionOwner.closeAfterCaller204()
        expect(settled && database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions") == 1,
            "known batch rejection settles pending state without replenishing the approved attempt")

        if (!withDeferred) {
            let nextModel = PlanBatchTerminalModel204()
            let nextCore = AgentCore(nextModel, runs, pipeline, catalog, threadRuntimes: Some(registry),
                operationRuntime: Some(operations), modelDecisionRuntime: Some(SqliteModelDecisionStore(database)))
            let nextCustody = PlanRequestCustody204(catalog.reserveRegistryData180(131072).getOrThrow())
            let next = planBatchOwnedStartFrame204(nextCore, RunId("plan-batch-next-run"), session, root,
                "report the remaining plan evidence", CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
                false, nextCustody)
            nextCustody.returnApplicationFrame204()
            expect(match (nextCore.takeOwnedCheckpointFailure113(RunId("plan-batch-next-run"))) {
                case OwnedAgentRunResult113.Existing(_) => true; case _ => false
            } && nextCustody.isDataReturned204(),
                "subsequent managed Run returns its independently paid request custody through the actual collector")

            expect(next.isError() && next.error().getOrThrow().code == "plan.evidence_incomplete" && nextModel.calls == 1 &&
                runtime.activeRun().isNone() && executor.executions == 0,
                "a new Run reaches normal plan validation instead of an orphaned tool recovery barrier")
            expect(database.scalarInt("SELECT COUNT(*) FROM plan_action_admissions") == 1,
                "subsequent Run does not erase or restore the spent action reservation")
        }
    } finally {
        database.close()
        let _ = removeIfExists(temporary, recursive: true)
    }
}

func planBatchExplicitlyNotStarted(error: AgentValue): Bool {
    match (error.field("fields")) {
        case Some(fields) => for (field in fields.items) {
            if (field.field("name").getOrThrow().text == "started" &&
                field.field("value").getOrThrow().text == "false") { return true }
        }
        case None => ()
    }
    false
}

// Return only a scalar after the complete paid projection consumer frame.
func planBatchSettledProjection204(consumer: PlanExecutionReadConsumer204): Bool {
    let projection = consumer.value204()
    let action = projection.field("steps").getOrThrow().items[0].field("actions").getOrThrow().items[0]
    action.field("state").getOrThrow().text == "blocked" &&
        action.field("attempts").getOrThrow().asNumberText() == "1" &&
        action.field("remaining_attempts").getOrThrow().asNumberText() == "0"
}

// This is the real owned Core entry, not a fabricated return witness. The
// caller may acknowledge application DATA only after this whole helper ends.
func planBatchOwnedStartFrame204(core: AgentCore, run: RunId, session: SessionId, workspace: String,
    prompt: String, capabilities: CapabilitySet, parallel: Bool,
    custody: PlanRequestCustody204, events!: AgentEventSink = {_ => ()}): Result<AgentRunOutcome> {
    let request = AgentRunRequest(run, session, "fixture", prompt,
        capabilities: capabilities, parallelToolCalls: parallel,
        toolContext: ToolContextDescriptor(workspaceRoot: workspace, cwd: workspace),
        planRequestCustody204: Some(custody))
    match (core.startOwnedCheckpointFailure113(request, events)) {
        case OwnedAgentRunResult113.Existing(result) => result
        // Unknown/owned observer outcomes cannot be flattened or fake-ACKed
        // just to satisfy the legacy result assertion in this batch fixture.
        case _ => throw IllegalStateException("batch fixture received an unexpected owned failure or pending consumer")
    }
}


class PlanBoundaryModel204 <: ModelPort & ReturningModelInputPort159 & ReturningModelTranscriptPort159 {
    private let arguments: AgentValue
    var calls: Int64 = 0
    init(arguments: AgentValue) { this.arguments = arguments }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> { executeFrame204(request, events) }
    public func executeReturningInput159(request: ModelRequest, events: ModelEventSink,
        _: ModelInputDataBudget159): ModelInputReturn159 {
        let result = executeFrame204(request, events)
        ModelInputReturn159.Returned(result)
    }
    public func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        let result = planBatchNoTranscriptFrame204(request)
        loan.returnModelToolsFrame159(); result
    }
    private func executeFrame204(_: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        calls += 1; events(ModelEvent.Completed)
        if (calls == 1) {
            return Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.ToolCall,
                callId: "boundary-call", name: "read", arguments: arguments)])) }
        Result.Ok(contractModelReply([ModelBlock(ModelBlockKind.Text, text: "done")], stopReason: "end_turn"))
    }
}
class PlanBoundaryExecutor204 <: ToolExecutor {
    private let database: SqliteDatabase
    private let registry: SqliteThreadRuntimeRegistry
    private let workspace: String
    var calls: Int64 = 0
    var observedExecuting = false
    var executingCandidateRefused = false
    init(database: SqliteDatabase, registry: SqliteThreadRuntimeRegistry, workspace: String) {
        this.database = database; this.registry = registry; this.workspace = workspace
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let rows = database.query("SELECT state FROM operations WHERE id=?", [SqlParameter.Text(prepared.operationId.value)])
        let handoffs = database.query("SELECT id FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff'",
            [SqlParameter.Text(prepared.operationId.value)])
        observedExecuting = rows.size == 1 && rows[0].required(0) == "executing" && handoffs.size == 1
        if (!observedExecuting) { return planExecutionError("fixture.execution_without_admission",
            "executor requires the real durable Executing state and canonical handoff") }
        // Simulate the admission caller losing its return after SQLite has
        // really committed Executing. All source, call, plan and epoch facts
        // are genuine; only its proposed not-started stage is false.
        let runtime = registry.acquire(ThreadId(context.sessionId.value), workspace).value().getOrThrow()
        let reason = AgentError(AgentErrorKind.Conflict, "tool.execution_not_admitted",
            "execution admission did not return successfully", fields: [
                ErrorField("cause", "operation.execution_prepare_failed"), ErrorField("started", "false"),
                ErrorField("plan_digest", prepared.operationPlan.bindingDigest)])
        let forged = runtime.resolveOperation(ItemId("boundary-unstarted-candidate"), prepared.operationId,
            CanonicalToolCallId(prepared.call.callId), prepared.operationPlan, OperationAttemptStage.Prepared,
            Result.Ok(ToolInvocationResult.Denied(ToolDenial(prepared.call.callId, prepared.call.name, reason))),
            "receipt-" + prepared.operationId.value, agentUtcMillis())
        let refused = match (forged) {
            case Result.Ok(value) => match (value.semanticCommit) {
                case Some(SemanticCommitDecision.Rejected(_)) => true; case _ => false }
            case _ => false }
        let remaining = database.query("SELECT state FROM operations WHERE id=?", [SqlParameter.Text(prepared.operationId.value)])
        executingCandidateRefused = refused && remaining.size == 1 && remaining[0].required(0) == "executing" &&
            database.query("SELECT id FROM operation_receipts WHERE operation_id=?", [SqlParameter.Text(prepared.operationId.value)]).isEmpty() &&
            database.query("SELECT id FROM items WHERE id='boundary-unstarted-candidate'").isEmpty()
        if (!executingCandidateRefused) { return planExecutionError("fixture.executing_reinterpreted",
            "a genuine Executing operation must refuse a not-started candidate without changing its receipt or state") }
        calls += 1
        Result.Ok(ToolResult(prepared.call.callId, textValue("inspected")))
    }
}
class PlanBoundaryRevocation204 {
    private let database: SqliteDatabase
    private let run: RunId
    private let session: SessionId
    private let enabled: Bool
    private let commitAmbiguous: Bool
    var revoked = false
    var committedAmbiguous = false
    init(database: SqliteDatabase, run: RunId, session: SessionId, enabled: Bool, commitAmbiguous: Bool) {
        this.database = database; this.run = run; this.session = session; this.enabled = enabled
        this.commitAmbiguous = commitAmbiguous
    }
    func event(_: AgentEvent): Unit {
        if ((!enabled && !commitAmbiguous) || revoked || committedAmbiguous) { return }
        // The first Core event after canonical preparation precedes the tool
        // wave. Revoke the active approval using real SQLite state, while the
        // exact admitted Operation is still Prepared; no executor is mocked.
        if (database.query("SELECT o.id FROM operations o JOIN plan_action_admissions a ON a.operation_id=o.id WHERE o.run_id=? AND o.state='prepared'",
            [SqlParameter.Text(run.value)]).size == 1) {
            if (commitAmbiguous) {
                // Fault injection at the real admitted canonical boundary:
                // persist precisely Executing+its mirror, but lose the caller
                // return before the generic admission callback or handoff.
                // The canonical call, plan, Decision and approval are intact.
                database.transaction { tx =>
                    tx.execute("UPDATE operations SET state='executing',revision=revision+1 WHERE run_id=? AND state='prepared'",
                        [SqlParameter.Text(run.value)])
                    tx.execute("UPDATE operation_state_registers SET state='executing',revision=revision+1 WHERE operation_id IN (SELECT id FROM operations WHERE run_id=?)",
                        [SqlParameter.Text(run.value)])
                }
                committedAmbiguous = true
            } else {
                database.execute("DELETE FROM plan_execution_sessions WHERE session_id=?", [SqlParameter.Text(session.value)])
                revoked = true
            }
        }
    }
}

func planExecutionBoundaryCase204(revoke: Bool, commitAmbiguous!: Bool = false): Unit {
    let temporary = Directory.createTemp("target").toString()
    let workspace = canonicalize(Path(temporary)).toString()
    let database = SqliteDatabase(workspace + "/execution-boundary.db")
    try {
        let catalog = planBatchReadCatalog204()
        let allocate: (Int64) -> LogicalJsonOwnerReservation = { bytes => catalog.reserveRegistryData180(bytes).getOrThrow() }
        let operations = DurableOperationStore(database, documentPayloadAllocation: Some(allocate))
        let plans = DurablePlanExecutionStore(database, knownParentAllocation: Some(allocate))
        let registry = SqliteThreadRuntimeRegistry(database,
            ContextProjector("boundary", ConservativeThreadTokenEstimator()), { => agentUtcMillis() },
            knownParentAllocation: Some(allocate))
        let executor = PlanBoundaryExecutor204(database, registry, workspace)
        let descriptor = ToolDescriptor(ModelToolDefinition("read", "canonical execution boundary", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), supervisedExecutionSafe: true)
        catalog.register(descriptor, executor).value().getOrThrow()
        let business = objectValue([ValueField("path", textValue(workspace + "/source.txt"))])
        let action = PlanAction("read-once", ["read"], ["denied"], OperationEffectClass.ReadOnly,
            business, 1, exactArguments: true, toolIdentities: objectValue([ValueField("read", objectValue([
                ValueField("version", textValue(descriptor.implementationVersion)),
                ValueField("fingerprint", textValue(descriptor.implementationFingerprint)),
                ValueField("schema_digest", textValue(descriptor.schemaDigest))]))]))
        let session = SessionId("boundary-session")
        let run = RunId("boundary-run")
        plans.activate("boundary-execution", session.value,
            PlanContract([workspace], [PlanExecutionStep(PlanStepId("inspect"), [], true, [action])])).value().getOrThrow()
        let arguments = objectValue([ValueField("path", textValue(workspace + "/source.txt")), ValueField("_plan", objectValue([
            ValueField("step_id", textValue("inspect")), ValueField("action_id", textValue("read-once"))]))])
        let model = PlanBoundaryModel204(arguments)
        let pipeline = ToolPipeline(catalog, operations, PlanBatchAudit(), FixtureIds(), plans: Some(plans))
        let core = AgentCore(model, SqliteRunRepository(database), pipeline, catalog,
            threadRuntimes: Some(registry), operationRuntime: Some(operations),
            modelDecisionRuntime: Some(SqliteModelDecisionStore(database)))
        let custody = PlanRequestCustody204(catalog.reserveRegistryData180(131072).getOrThrow())
        let revocation = PlanBoundaryRevocation204(database, run, session, revoke, commitAmbiguous)
        let result = planBatchOwnedStartFrame204(core, run, session, workspace, "inspect the approved source",
            CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]), false, custody,
            events: { event => revocation.event(event) })
        custody.returnApplicationFrame204()
        let receipts = database.query("SELECT r.outcome,r.detail FROM operations o JOIN operation_receipts r ON r.operation_id=o.id WHERE o.run_id=?",
            [SqlParameter.Text(run.value)])
        if (commitAmbiguous) {
            expect(revocation.committedAmbiguous && result.isError() && executor.calls == 0 && receipts.isEmpty() &&
                database.query("SELECT o.id FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id " +
                    "WHERE o.run_id=? AND o.state='executing' AND s.state='executing'", [SqlParameter.Text(run.value)]).size == 1 &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
                database.query("SELECT execution_id FROM plan_execution_sessions WHERE session_id=?", [SqlParameter.Text(session.value)]).size == 1,
                "a lost admission return with real durable Executing and zero handoff refuses the not-started candidate without any detached receipt or state reinterpretation")
            return
        }
        expect(receipts.size == 1, "each real boundary outcome has exactly one canonical SQLite receipt")
        if (revoke) {
            expect(revocation.revoked && result.isError() && result.error().getOrThrow().code != "operation.receipt_commit_failed" &&
                result.error().getOrThrow().kind == AgentErrorKind.Conflict &&
                result.error().getOrThrow().code == "plan.admission_denied" &&
                executor.calls == 0 && receipts[0].required(0) == "rejected" &&
                planBatchExplicitlyNotStarted(decodeStoredValue(receipts[0].required(1))) &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0,
                "approval revocation before Executing rejects canonically as not started without an executor or fabricated executing receipt; result=" +
                    match (result) { case Result.Err(error) => error.code; case Result.Ok(_) => "ok" } +
                    " revoked=" + revocation.revoked.toString() + " calls=" + executor.calls.toString() +
                    " receipt=" + receipts[0].required(0) + " notstarted=" +
                    planBatchExplicitlyNotStarted(decodeStoredValue(receipts[0].required(1))).toString())
        } else {
            expect(result.isOk() && executor.calls == 1 && executor.observedExecuting && executor.executingCandidateRefused &&
                receipts[0].required(0) == "completed" &&
                database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 1,
                "actual durable Executing and canonical handoff precede the executor and its completed SQLite receipt; result=" +
                    match (result) { case Result.Err(error) => error.code; case Result.Ok(_) => "ok" } +
                    " calls=" + executor.calls.toString() + " executing=" + executor.observedExecuting.toString() +
                    " receipt=" + receipts[0].required(0))
        }
    } finally {
        database.close(); let _ = removeIfExists(temporary, recursive: true)
    }
}

class PlanRequestDataPressure204 {
    private let database: SqliteDatabase
    private let catalog: ToolCatalog
    private let run: RunId
    private var payment: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>
    var applied = false
    var policyCalls: Int64 = 0
    init(database: SqliteDatabase, catalog: ToolCatalog, run: RunId) {
        this.database = database; this.catalog = catalog; this.run = run
    }
    func afterSafeCutPolicy204(): Unit {
        policyCalls += 1
        if (applied || database.query("SELECT id FROM runs WHERE id=? AND state='running'",
            [SqlParameter.Text(run.value)]).size != 1) { return }
        // The real first validatePolicySnapshot call is in bounded request
        // construction, AFTER continueRun's refreshToolSetAtSafeCut returns.
        // Observe its existing canonical Run and no attempted provider call;
        // this fixture-only pressure does not alter any production boundary.
        expect(database.query("SELECT id FROM model_attempts WHERE run_id=?", [SqlParameter.Text(run.value)]).isEmpty(),
            "controlled copy pressure precedes the actual model attempt")
        // Controlled pressure on the SAME original 64-MiB fixture bank,
        // after identity comparison. The remaining 4-MiB test window targets
        // the selected-schema prepayment after the paid request view opens.
        let actual = catalog.reserveRegistryData180(4096).getOrThrow()
        let used = actual.retainedCustodyUsage113()[0]
        expect(used < 67108864 - 4194304, "fixture source leaves the declared pressure window")
        actual.ensureRetainedPeak(67108864 - used - 4194304 + 4096)
        payment = Some(actual); applied = true
    }
    func returnPressureFrame204(): Unit {
        let actual = payment; payment = None<LogicalJsonOwnerReservation>
        match (actual) { case Some(value) => value.close(); case None => () }
    }
}
class PlanRequestDataPressureModel204 <: ModelPort & ReturningModelInputPort159 & ReturningModelTranscriptPort159 {
    private let pressure: PlanRequestDataPressure204
    private let actual = PlanBatchTerminalModel204()
    prop calls: Int64 { get() { actual.calls } }
    init(pressure: PlanRequestDataPressure204) { this.pressure = pressure }
    public func validatePolicySnapshot(_: String, _: ?ModelExecutionCapabilitiesSnapshot): Result<Unit> {
        pressure.afterSafeCutPolicy204(); Result.Ok(())
    }
    public func execute(request: ModelRequest, events: ModelEventSink): Result<ModelReply> {
        actual.execute(request, events)
    }
    public func executeReturningInput159(request: ModelRequest, events: ModelEventSink,
        payment: ModelInputDataBudget159): ModelInputReturn159 {
        actual.executeReturningInput159(request, events, payment)
    }
    public func transcriptSnapshotReturning159(request: ModelRequest, loan: ModelInputToolsBorrow159): ?String {
        actual.transcriptSnapshotReturning159(request, loan)
    }
}
func planRequestDataRefusalCase204(): Unit {
    let temporary = Directory.createTemp("target").toString()
    let workspace = canonicalize(Path(temporary)).toString()
    let database = SqliteDatabase(workspace + "/request-copy-refusal.db")
    try {
        let catalog = planBatchReadCatalog204()
        let allocate: (Int64)->LogicalJsonOwnerReservation = { bytes => catalog.reserveRegistryData180(bytes).getOrThrow() }
        let schema = objectValue([ValueField("type", textValue("object")),
            ValueField("description", textValue(String.fromUtf8(Array<Byte>(65536, repeat: b'x'))))])
        let descriptor = ToolDescriptor(ModelToolDefinition("read", "selected schema pressure fixture", schema),
            Capability(CapabilityKind.WorkspaceRead), supervisedExecutionSafe: true)
        let executor = PlanBatchReadExecutor()
        catalog.register(descriptor, executor).value().getOrThrow()
        let action = PlanAction("read-once", ["read"], ["denied"], OperationEffectClass.ReadOnly,
            objectValue([ValueField("path", textValue(workspace + "/source.txt"))]), 1,
            toolIdentities: objectValue([ValueField("read", objectValue([
                ValueField("version", textValue(descriptor.implementationVersion)),
                ValueField("fingerprint", textValue(descriptor.implementationFingerprint)),
                ValueField("schema_digest", textValue(descriptor.schemaDigest))]))]))
        let session = SessionId("copy-refusal-session"); let run = RunId("copy-refusal-run")
        let plans = DurablePlanExecutionStore(database, knownParentAllocation: Some(allocate))
        plans.activate("copy-refusal-execution", session.value,
            PlanContract([workspace], [PlanExecutionStep(PlanStepId("inspect"), [], true, [action])])).value().getOrThrow()
        let registry = SqliteThreadRuntimeRegistry(database,
            ContextProjector("copy-refusal", ConservativeThreadTokenEstimator()), { => agentUtcMillis() },
            knownParentAllocation: Some(allocate))
        let operations = DurableOperationStore(database, documentPayloadAllocation: Some(allocate))
        let pressure = PlanRequestDataPressure204(database, catalog, run)
        let model = PlanRequestDataPressureModel204(pressure)
        let pipeline = ToolPipeline(catalog, operations, PlanBatchAudit(), FixtureIds(), plans: Some(plans))
        let core = AgentCore(model, SqliteRunRepository(database), pipeline, catalog,
            threadRuntimes: Some(registry), operationRuntime: Some(operations),
            modelDecisionRuntime: Some(SqliteModelDecisionStore(database)))
        let custody = PlanRequestCustody204(catalog.reserveRegistryData180(131072).getOrThrow())
        let result = planBatchOwnedStartFrame204(core, run, session, workspace,
            "read after original-bank request data admission", CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
            false, custody)
        // The complete managed invocation returned before either real caller
        // acknowledges its own DATA. No provider or task witness is invented.
        custody.returnApplicationFrame204(); pressure.returnPressureFrame204()
        let rows = database.query("SELECT state FROM runs WHERE id=?", [SqlParameter.Text(run.value)])
        expect(pressure.applied && pressure.policyCalls == 1 && result.isError() && result.error().getOrThrow().kind == AgentErrorKind.BudgetExceeded &&
            result.error().getOrThrow().code == "model.request_data_failed" && model.calls == 0 && executor.executions == 0 &&
            rows.size == 1 && rows[0].required(0) == "failed" &&
            database.query("SELECT id FROM model_attempts WHERE run_id=?", [SqlParameter.Text(run.value)]).isEmpty() &&
            registry.acquire(ThreadId(session.value), workspace).value().getOrThrow().activeRun().isNone(),
            "exact original-bank pre-copy refusal returns its real fixed failure, canonically fails the actual Run, and starts neither model nor executor")
        expect(match (core.takeOwnedCheckpointFailure113(run)) {
            case OwnedAgentRunResult113.Existing(_) => true; case _ => false
        }, "a consumed fixed pre-copy failure leaves no synthetic owned failure head or running orphan")
    } finally { database.close(); let _ = removeIfExists(temporary, recursive: true) }
}
