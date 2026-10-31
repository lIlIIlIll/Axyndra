package external_derived_context_contract

import agent_domain.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.env.*
import yjson.*
import yjson_support.*

func expect(value: Bool, message: String): Unit {
    if (!value) { throw IllegalStateException(message) }
}

class ExternalDerivedEstimator <: ThreadTokenEstimator {
    public func estimateSystemInstructions(_: String): Int64 { 1 }
    public func estimateToolSet(_: ToolSetSnapshot): Int64 { 1 }
    public func estimateCheckpoint(_: ContextCheckpoint): Int64 { 1 }
    public func estimateItem(_: ThreadItem): Int64 { 1 }
    public func estimateDynamicState(_: AgentValue): Int64 { 1 }
}

class ExternalDerivedIds <: IdGenerator {
    var operations: Int64 = 0
    public func nextRunId(): RunId { RunId("unused") }
    public func nextSessionId(): SessionId { SessionId("unused") }
    public func nextOperationId(): OperationId {
        operations += 1
        OperationId("external-derived-op-" + operations.toString())
    }
}

class ExternalDerivedAudit <: AuditPort {
    var calls: Int64 = 0
    public func append(_: AgentEvent): Result<Unit> { calls += 1; Result.Ok(()) }
}

// Explicit trusted test composition; this does not replace ingress authentication.
class ExternalDerivedAuthorizer <: ExternalIngressAuthorizer {
    let initial: ExternalIngressBinding
    var changed: ?ExternalIngressBinding = None
    init(initial: ExternalIngressBinding) { this.initial = initial }
    public func currentBinding(): Result<ExternalIngressBinding> {
        Result.Ok(match (changed) { case Some(value) => value; case None => initial })
    }
}

class ExternalDerivedClock { var now = agentUtcMillis() }

// Private deterministic executor observes actual canonical admission only.
// No process, filesystem mutation, transport or Host service is simulated here.
class ExternalDerivedProbe <: ToolExecutor {
    var calls: Int64 = 0
    var cancelExecuting: ?() -> Unit = None
    var evidenceContext: ?ToolInvocationContext = None
    public func executeObserved(context: ToolInvocationContext, prepared: PreparedToolInvocation): ToolExecutionOutcome {
        let result = execute(context, prepared)
        let evidence: ?ToolExecutionCancellationEvidence = match (result) {
            case Result.Err(error) => observeToolExecutionCancellation(
                match (evidenceContext) { case Some(value) => value; case None => context },
                prepared, error, context.cancellation)
            case Result.Ok(_) => None
        }
        ToolExecutionOutcome(result, cancellationEvidence: evidence)
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        expect(prepared.source.kind == PreparedInvocationSourceKind.Derived &&
            prepared.source.runId.value == context.runId.value && !context.trustedControl,
            "probe receives the actual unprivileged Derived source")
        calls += 1
        match (cancelExecuting) {
            case Some(cancel) =>
                cancel()
                match (context.cancellation.check()) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(_) => throw IllegalStateException("actual request cancellation did not reach its executor token")
                }
            case None => ()
        }
        Result.Ok(ToolResult(prepared.call.callId,
            objectValue([ValueField("sentinel", textValue("EXTERNAL_DERIVED_SCOPE"))])))
    }
    public func cancel(_: RunId): Result<Unit> { Result.Ok(()) }
}

func ready(value: Result<ToolPreparation>): PreparedToolInvocation {
    match (value) {
        case Result.Ok(ToolPreparation.Ready(prepared)) => prepared
        case Result.Err(error) => throw IllegalStateException(error.describe())
        case _ => throw IllegalStateException("contract requires actual Ready preparation")
    }
}

func errorCode(value: Result<ToolPreparation>): String {
    match (value) { case Result.Err(error) => error.code; case _ => "" }
}

class ExternalDerivedFixture {
    let root: String
    let database: SqliteDatabase
    let store: DurableOperationStore
    let coordinator: ThreadCoordinator
    let runtime: AgentThreadRuntime
    let catalog = ToolCatalog()
    let ids = ExternalDerivedIds()
    let audit = ExternalDerivedAudit()
    let probe = ExternalDerivedProbe()
    let clock = ExternalDerivedClock()
    let foreignCancellation = CancellationSource()
    let pipeline: ToolPipeline
    let authorizer: ExternalDerivedAuthorizer
    let connection: ExternalIngressConnection
    let admission: ExternalCallAdmission
    let parentContext: ToolInvocationContext
    let parent: PreparedToolInvocation
    let source: DirectToolCallRef
    let read = Capability(CapabilityKind.WorkspaceRead)
    let invoke = Capability(CapabilityKind.ExtensionInvoke, resource: "fixture.external")
    let extra = Capability(CapabilityKind.WorkspaceWrite, resource: "/unused")
    let call = ToolCall("external-derived-root-call", "plugin.fixture.external", objectValue([]))
    let childCall = ToolCall("external-derived-child-call", "host.process.readonly", objectValue([]))
    let key = "javascript-service:external-derived-root-call:read"

    init() {
        root = Directory.createTemp(match (getVariable("TMPDIR")) { case Some(value) => value; case None => "/tmp" }).toString()
        database = SqliteDatabase(root + "/state.db")
        store = DurableOperationStore(database)
        let sink = SqliteThreadCommitSink(database)
        let thread = ThreadId("external-derived-thread")
        coordinator = ThreadCoordinator(sink.createThread(thread, "workspace"), sink)
        runtime = AgentThreadRuntime(coordinator, ContextProjector("external-derived", ExternalDerivedEstimator()),
            { => agentUtcMillis() })
        let schema = objectValue([ValueField("type", textValue("object"))])
        let descriptor = ToolDescriptor(ModelToolDefinition(call.name, "Real External scope fixture", schema), invoke,
            additionalCapabilities: [read], implementationVersion: "external-derived-v1")
        expect(catalog.register(descriptor, probe).isOk(), "register the actual ordinary root contribution")
        expect(catalog.register(ToolDescriptor(ModelToolDefinition(childCall.name, "Hidden read-only probe", schema),
            read, hostServiceOnly: true, implementationVersion: "external-derived-child-v1"), probe).isOk(),
            "register the existing fixed hidden read-only service identity")
        let caps = CapabilitySet(values: [invoke, read, extra])
        let snapshot = catalog.toolSetSnapshot("external-derived-snapshot", caps, threadId: Some(thread))
        let toolContext = ToolContextDescriptor(workspaceRoot: root, cwd: root,
            environment: ToolEnvironmentView(entries: [ToolEnvironmentEntry("FIXTURE", "frozen")]))
        let scopeContext = ToolInvocationContext(RunId("scope-only"), SessionId(thread.value), caps,
            toolContext: toolContext, toolSetSnapshot: Some(snapshot))
        let plan = normalizedToolOperationPlan(scopeContext, call, descriptor.resolved(call))
        let localClock = clock
        authorizer = ExternalDerivedAuthorizer(ExternalIngressBinding("external-derived-grant", "external-derived-connection",
            "authenticated-principal", 1, thread, externalInvocationAuthorityScope(scopeContext),
            [ExternalExportBinding(call.name, plan.implementation.toolVersion,
                plan.implementation.implementationFingerprint, plan.implementation.schemaDigest)],
            caps.values, localClock.now + 600000, []))
        connection = openExternalIngressConnection(authorizer, { => localClock.now }).value().getOrThrow()
        let lane = ModelLane(ModelLaneRole.Main, "provider", "external-fixture", "responses",
            ModelLaneCapabilitiesSnapshot(), 1000, 100, 20, "estimator", "retry", "cache", snapshot, "system")
        admission = runtime.startExternalTurn(connection, ExternalRequestId(ExternalRequestIdKind.Text, value: "request"),
            call, SemanticTurnId("external-derived-turn"), RunId("external-derived-run"), ItemId("external-derived-input"),
            lane, InvocationContextProjection()).value().getOrThrow()
        parentContext = ToolInvocationContext(admission.run.runId, SessionId(thread.value), caps,
            epoch: admission.run.epoch, cancellation: admission.cancellationToken,
            toolContext: toolContext, budget: ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1),
            toolSetSnapshot: Some(admission.run.lane.toolSet))
        pipeline = ToolPipeline(catalog, store, audit, ids)
        let unsealed = ready(pipeline.prepare(parentContext, call))
        expect(unsealed.source.operationRoot.isNone(), "a raw preparation cannot mint its own External source")
        source = runtime.commitExternalToolCall(admission, ItemId("external-derived-call"), unsealed.operationId,
            call, admission.run.runId, admission.run.epoch).value().getOrThrow()
        parent = pipeline.bindDirectRoot(parentContext, unsealed, source).value().getOrThrow()
        store.prepareDirectOperation(source, parent.operationPlan).value().getOrThrow()
        expect(source.validateLiveSource().isOk() &&
            (match (source.origin) { case DirectCallOrigin.External(_) => true; case _ => false }) &&
            database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'") == 1,
            "the real External admission alone owns the canonical Root, without fake model or User source")
    }

    func view(caps!: ?CapabilitySet = None, run!: ?RunId = None, epoch!: ?Int64 = None,
        workspace!: ?String = None, environment!: ?ToolEnvironmentView = None,
        token!: ?CancellationToken = None): ToolInvocationContext {
        ToolInvocationContext(match (run) { case Some(value) => value; case None => parentContext.runId },
            parentContext.sessionId, match (caps) { case Some(value) => value; case None => parentContext.capabilities },
            epoch: match (epoch) { case Some(value) => value; case None => parentContext.epoch },
            toolContext: ToolContextDescriptor(
                workspaceRoot: match (workspace) { case Some(value) => value; case None => parentContext.workspaceRoot },
                cwd: parentContext.cwd,
                environment: match (environment) { case Some(value) => value; case None => parentContext.environment },
                services: parentContext.services),
            cancellation: match (token) { case Some(value) => value; case None => parentContext.cancellation },
            approvalModeOverride: parentContext.approvalModeOverride, outputSink: parentContext.outputSink,
            budget: parentContext.budget, budgetModeFn: parentContext.budgetModeFn,
            contextProjection: parentContext.contextProjection, toolSetSnapshot: parentContext.toolSetSnapshot)
    }

    func assertNoChild(): Unit {
        expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM operations") == 1 &&
            database.scalarInt("SELECT COUNT(*) FROM operation_receipts") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 0 &&
            database.scalarInt("SELECT COUNT(*) FROM model_decisions") == 0 && probe.calls == 0,
            "rejected or plan-only preparation adds no child, Receipt, handoff or executor call")
    }

    func close(): Unit {
        connection.revoke(); foreignCancellation.close(); database.close(); remove(root, recursive: true)
    }
}

func externalDerivedCase(mode: String): Unit {
    let fixture = ExternalDerivedFixture()
    try {
        let narrow = CapabilitySet(values: [fixture.read])
        var parentContext = fixture.parentContext
        var childContext = fixture.view(caps: Some(narrow))
        if (mode == "same-context") {
            let old = ready(fixture.pipeline.prepareDerived(parentContext, fixture.childCall, fixture.parent, fixture.key))
            let current = ready(fixture.pipeline.prepareDerived(parentContext, parentContext,
                fixture.childCall, fixture.parent, fixture.key))
            expect(old.source.kind == current.source.kind && old.authorization == current.authorization &&
                sameNormalizedOperationPlan(old.operationPlan, current.operationPlan) &&
                old.source.parentOperationId.getOrThrow().value == current.source.parentOperationId.getOrThrow().value,
                "the old same-context entry retains its source, plan and authorization semantics")
            fixture.assertNoChild()
            return
        }
        if (mode == "narrowed") {
            expect(errorCode(fixture.pipeline.prepareDerived(childContext, fixture.childCall, fixture.parent, fixture.key)) ==
                "external.context_changed", "the unchanged legacy entry still demands the Direct parent's full scope")
            let child = ready(fixture.pipeline.prepareDerived(parentContext, childContext,
                fixture.childCall, fixture.parent, fixture.key))
            expect(child.source.kind == PreparedInvocationSourceKind.Derived &&
                child.source.parentOperationId.getOrThrow().value == fixture.parent.operationId.value &&
                child.source.requestKey == fixture.key && child.source.operationRoot.getOrThrow().itemId().value ==
                    fixture.source.canonicalItemId.value && !childContext.capabilities.allows(fixture.extra.kind, resource: fixture.extra.resource),
                "the real Direct root remains sealed while the child retains its strict capability subset")
            fixture.assertNoChild()
            expect(fixture.pipeline.admitDerived(childContext, child).isError(),
                "a valid child plan still cannot precede the original Root's durable handoff")
            fixture.store.markExecutingWithSource(Some(OperationRootSource.Direct(fixture.source)), fixture.parent.operationId,
                parentContext.runId, fixture.parent.operationPlan, agentUtcMillis(), false).value().getOrThrow()
            fixture.store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(fixture.source)), fixture.parent.operationId,
                parentContext.runId, fixture.source.threadId, agentUtcMillis()).value().getOrThrow()
            expect(fixture.pipeline.admitDerived(childContext, child).value().getOrThrow().value == child.operationId.value &&
                fixture.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 1,
                "the existing Store alone admits exactly one child from the actual executing Root")
            let output = match (fixture.pipeline.executePrepared(childContext, child)) {
                case Result.Ok(ToolInvocationResult.Completed(value)) => value
                case Result.Err(error) => throw IllegalStateException(error.describe())
                case _ => throw IllegalStateException("actual admitted child did not execute")
            }
            try {
                expect(!output.isError && output.output.field("sentinel").getOrThrow().text == "EXTERNAL_DERIVED_SCOPE" &&
                    fixture.probe.calls == 1, "the admitted child executes its exact original pipeline once")
                fixture.store.settleDerivedOperation(parentContext.runId, fixture.parent.operationId,
                    VNextOperationReceipt("receipt-" + child.operationId.value, child.operationId, OperationOutcome.Completed,
                        output.output, objectValue([]), agentUtcMillis())).value().getOrThrow()
                expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'") == 1 &&
                    fixture.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'") == 2 &&
                    fixture.database.query("PRAGMA foreign_key_check").isEmpty(),
                    "actual child settlement retains its single Receipt and both original handoffs")
                let replay = ready(fixture.pipeline.prepareDerived(parentContext, childContext,
                    fixture.childCall, fixture.parent, fixture.key))
                expect(fixture.pipeline.admitDerived(childContext, replay).value().getOrThrow().value == child.operationId.value &&
                    fixture.probe.calls == 1 && fixture.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions") == 1,
                    "the exact retained request cannot mint or execute a second child")
            } finally { output.releasePayload() }
            return
        }
        if (mode == "parent-cap") { parentContext = fixture.view(caps: Some(narrow)) }
        else if (mode == "parent-run") { parentContext = fixture.view(run: Some(RunId("foreign-run"))) }
        else if (mode == "parent-epoch") { parentContext = fixture.view(epoch: Some(parentContext.epoch + 1)) }
        else if (mode == "parent-token") { parentContext = fixture.view(token: Some(fixture.foreignCancellation.token)) }
        else if (mode == "child-widen") { childContext = fixture.view(caps: Some(CapabilitySet(values: [fixture.read,
            Capability(CapabilityKind.ProcessSpawn)]))) }
        else if (mode == "child-run") { childContext = fixture.view(caps: Some(narrow), run: Some(RunId("foreign-child"))) }
        else if (mode == "child-epoch") { childContext = fixture.view(caps: Some(narrow), epoch: Some(parentContext.epoch + 1)) }
        else if (mode == "child-path") { childContext = fixture.view(caps: Some(narrow), workspace: Some(fixture.root + "/other")) }
        else if (mode == "child-env") { childContext = fixture.view(caps: Some(narrow),
            environment: Some(ToolEnvironmentView(entries: [ToolEnvironmentEntry("FIXTURE", "changed")]))) }
        else if (mode == "child-token") { childContext = fixture.view(caps: Some(narrow), token: Some(fixture.foreignCancellation.token)) }
        else if (mode == "expired") { fixture.clock.now = fixture.connection.binding.expiresAtMillis }
        else if (mode == "revoked") { fixture.connection.revoke() }
        else if (mode == "changed-binding") {
            let binding = fixture.authorizer.initial
            fixture.authorizer.changed = Some(ExternalIngressBinding(binding.grantId, binding.connectionId,
                "different-principal", binding.generation, binding.threadId, binding.permissionDomain,
                [binding.exported(fixture.call.name).getOrThrow()], binding.ceiling.values, binding.expiresAtMillis, []))
        }
        else if (mode == "executing-cancel" || mode == "foreign-observation" || mode == "observation-failure") {
            let child = ready(fixture.pipeline.prepareDerived(parentContext, childContext,
                fixture.childCall, fixture.parent, fixture.key))
            fixture.store.markExecutingWithSource(Some(OperationRootSource.Direct(fixture.source)), fixture.parent.operationId,
                parentContext.runId, fixture.parent.operationPlan, agentUtcMillis(), false).value().getOrThrow()
            fixture.store.markExecutionHandoffWithSource(Some(OperationRootSource.Direct(fixture.source)), fixture.parent.operationId,
                parentContext.runId, fixture.source.threadId, agentUtcMillis()).value().getOrThrow()
            fixture.pipeline.admitDerived(childContext, child).value().getOrThrow()
            fixture.probe.cancelExecuting = Some({ =>
                fixture.connection.cancelRequest(ExternalRequestId(ExternalRequestIdKind.Text, value: "request")).value().getOrThrow()
            })
            if (mode == "foreign-observation") { fixture.probe.evidenceContext = Some(fixture.view(caps: Some(narrow))) }
            let returnedExecution: Array<?ReturnedToolExecutionObservation> = [None]
            let failure = fixture.pipeline.executePrepared(childContext, child, {_ => Result.Ok(())},
                executionObservation: Some({ actual =>
                    returnedExecution[0] = Some(actual)
                    if (mode == "observation-failure") { throw IllegalStateException("actual terminal consumer failed") }
                })).error().getOrThrow()
            if (mode == "foreign-observation" || mode == "observation-failure") {
                expect(fixture.probe.calls == 1 &&
                    !returnedExecution[0].getOrThrow().provesReturnedCancellation(child, failure) &&
                    fixture.store.loadDerivedOperationState(child.operationId, parentContext.runId).value().getOrThrow() == "executing" &&
                    fixture.store.loadDerivedOperationReceipt(child.operationId, parentContext.runId).value().getOrThrow().isNone(),
                    "foreign-context evidence or failed callback cannot settle or falsely acknowledge executing debt")
                if (mode == "observation-failure") { expect(failure.kind == AgentErrorKind.RecoveryRequired &&
                    failure.code == "tool.execution_observation_failed", "callback failure remains Unknown instead of relabelling original cancellation") }
                return
            }
            let cause = fixture.admission.cancellationToken.check().error().getOrThrow()
            expect(fixture.probe.calls == 1 && failure.kind == AgentErrorKind.Cancelled &&
                failure.code == cause.code && failure.message == cause.message &&
                fixture.connection.validateCurrent().isOk(),
                "the actual executing child returns its acknowledged cancellation without replacing it with ownership loss")
            let actual = returnedExecution[0].getOrThrow()
            expect(actual.provesReturnedCancellation(child, failure) &&
                !actual.provesReturnedCancellation(fixture.parent, failure) &&
                !actual.provesReturnedCancellation(child, AgentError(failure.kind, failure.code, failure.message)),
                "only the original returned executor observation proves its exact Prepared cancellation; copied errors and naked tokens do not")
            fixture.store.settleDerivedOperation(parentContext.runId, fixture.parent.operationId,
                VNextOperationReceipt("receipt-" + child.operationId.value, child.operationId, OperationOutcome.Cancelled,
                    objectValue([ValueField("error_code", textValue(failure.code))]), objectValue([]), agentUtcMillis())).value().getOrThrow()
            expect(fixture.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='cancelled'") == 1 &&
                fixture.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='recovery_required'") == 0 &&
                sameNormalizedOperationPlan(fixture.store.loadPlan(child.operationId, parentContext.runId).value().getOrThrow(), child.operationPlan) &&
                fixture.database.query("PRAGMA foreign_key_check").isEmpty(),
                "the actual acknowledged child cancellation retains its sole canonical Receipt and unchanged normalized plan without recovery debt")
            expect(fixture.pipeline.prepareDerived(parentContext, childContext,
                fixture.childCall, fixture.parent, fixture.key).isError() && fixture.probe.calls == 1,
                "retaining original cancellation evidence cannot authorize another child or effect")
            return
        }
        else if (mode == "late-cancel") {
            let child = ready(fixture.pipeline.prepareDerived(parentContext, childContext,
                fixture.childCall, fixture.parent, fixture.key))
            fixture.connection.cancelRequest(ExternalRequestId(ExternalRequestIdKind.Text, value: "request")).value().getOrThrow()
            let cause = fixture.admission.cancellationToken.check().error().getOrThrow()
            let sourceFailure = fixture.source.validateLiveSource().error().getOrThrow()
            expect(sourceFailure.kind == AgentErrorKind.Cancelled && sourceFailure.code == cause.code &&
                sourceFailure.message == cause.message && fixture.connection.validateCurrent().isOk(),
                "cancelled prepared request retains its exact live connection and original cancellation cause, not lost ownership; source=" +
                    sourceFailure.code + ": " + sourceFailure.message + "; cause=" + cause.code + ": " + cause.message)
            expect(fixture.admission.cancellationToken.isCancelled() &&
                fixture.pipeline.admitDerived(childContext, child).isError() &&
                fixture.pipeline.executePrepared(childContext, child).isError(),
                "real request cancellation after preparation blocks admission and execution before IO")
            fixture.assertNoChild()
            return
        }
        else { throw IllegalStateException("unknown external-derived contract mode") }
        let beforeIds = fixture.ids.operations
        let beforeAudit = fixture.audit.calls
        let refused = fixture.pipeline.prepareDerived(parentContext, childContext,
            fixture.childCall, fixture.parent, fixture.key)
        let code = errorCode(refused)
        expect(code != "" && fixture.ids.operations == beforeIds && fixture.audit.calls == beforeAudit,
            mode + " fails actual source validation before child operation allocation or policy audit")
        if (mode == "parent-run" || mode == "parent-epoch" || mode == "child-run" || mode == "child-epoch") {
            expect(code == "tool.prepared_source_context_changed", mode + " keeps exact Run/session/epoch fencing")
        } else if (mode == "parent-cap" || mode == "parent-token" || mode == "child-path" || mode == "child-env" || mode == "child-token") {
            expect(code == "external.context_changed", mode + " retains the original frozen permission domain and token validator")
        } else if (mode == "child-widen") {
            expect(code == "external.capability_ceiling", "the genuine Derived validator still rejects a capability outside the sealed ceiling")
        }
        fixture.assertNoChild()
    } finally { fixture.close() }
}

main(): Int64 {
    var completed: Int64 = 0
    for (mode in ["narrowed", "same-context", "parent-cap", "parent-run", "parent-epoch", "parent-token",
        "child-widen", "child-run", "child-epoch", "child-path", "child-env", "child-token",
        "expired", "revoked", "changed-binding", "late-cancel", "executing-cancel", "foreign-observation", "observation-failure"]) {
        externalDerivedCase(mode)
        completed += 1
    }
    expect(completed == 19, "all positive and source-rejection scenarios completed")
    println("External derived context contract passed: 19 scenarios")
    0
}
