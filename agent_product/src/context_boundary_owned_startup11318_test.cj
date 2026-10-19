package agent_product

import agent_core.*
import agent_domain.*
import agent_extension_runtime.reserveNativeDocumentPayload
import agent_host_runtime.*
import agent_ports.*
import agent_runtime.*
import agent_store.*
import persistence_runtime.*
import tool_runtime.*
import process4cj as boundary_process
import std.collection.*
import std.env.*
import std.io.*
import std.fs.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Real installed Product assembly, real Session -> Client -> RunService ->
// Core/Pipeline/SQLite. The fixture only proposes a ToolCall and its actual
// observer owns the original native producer before full error capture.
private func boundaryConsumerError11318(kind: AgentErrorKind, result: ToolResult): AgentError {
    AgentError(kind, "fixture.checkpoint_failure雪", "actual observer failed\u{0}雪🙂",
        retryable: true, fallbackAllowed: true,
        fields: [ErrorField("same", "first"), ErrorField("same", "second\u{0}雪")],
        attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError,
            diagnostics: AttemptFailureDiagnostics(elapsedMillis: 11, softDeadlineMillis: 12,
                hardDeadlineMillis: 13, enteredCompletionGrace: true,
                lastProgressKind: AttemptProgressKind.ToolArgumentProgress, lastProgressAgeMillis: 14,
                providerTerminalObserved: true, openContentBlockCount: 15,
                toolCallsStarted: 16, toolCallsCompleted: 17))),
        observation: Some(OperationObservation(stringifyUnifiedJson(objectValue([
            ValueField("actual_receipt", textValue(result.receiptId)),
            ValueField("actual_call", textValue(result.callId))])))))
}
private func expectBoundaryConsumerError11318(error: AgentError, kind: AgentErrorKind,
    receipt: String): Unit {
    @Expect(error.kind, kind)
    @Expect(error.code, "fixture.checkpoint_failure雪")
    @Expect(error.message, "actual observer failed\u{0}雪🙂")
    @Expect(error.retryable); @Expect(error.fallbackAllowed)
    @Expect(error.fields.size, 2)
    @Expect(error.fields[0].name, "same"); @Expect(error.fields[0].value, "first")
    @Expect(error.fields[1].name, "same"); @Expect(error.fields[1].value, "second\u{0}雪")
    let attempt = error.attemptFailure.getOrThrow()
    @Expect(attempt.kind, AttemptFailureKind.ProviderProtocolError)
    let d = attempt.diagnostics
    @Expect(d.elapsedMillis, 11); @Expect(d.softDeadlineMillis, 12); @Expect(d.hardDeadlineMillis, 13)
    @Expect(d.enteredCompletionGrace); @Expect(d.lastProgressKind, AttemptProgressKind.ToolArgumentProgress)
    @Expect(d.lastProgressAgeMillis, 14); @Expect(d.providerTerminalObserved)
    @Expect(d.openContentBlockCount, 15); @Expect(d.toolCallsStarted, 16); @Expect(d.toolCallsCompleted, 17)
    let observation = error.observation.getOrThrow().toValue()
    @Expect(observation.field("authorizes_effects").getOrThrow().asBool(), false)
    @Expect(observation.field("content").getOrThrow().field("actual_receipt").getOrThrow().text, receipt)
    @Expect(observation.field("content").getOrThrow().field("actual_call").getOrThrow().text, "boundary-owned-call11318")
}
private class BoundaryConsumerObserver11318 <: ToolExecutor & PreparedPostCanonicalToolObserver &
    DirectPostCanonicalToolObserver & PaidPreparedPostCanonicalToolObserver113 & PaidDirectPostCanonicalToolObserver113 {
    private let database: SqliteDatabase
    let kind: AgentErrorKind
    var executed: Int64 = 0
    var ownedCalls: Int64 = 0
    var oldCalls: Int64 = 0
    var lastReceipt = ""
    private var executedDigest = ""
    let entered = AtomicBool(false)
    let allowReturn = AtomicBool(true)
    var actualRun: ?RunId = None<RunId>
    init(database: SqliteDatabase, kind: AgentErrorKind) { this.database = database; this.kind = kind }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        executed++
        actualRun = Some(context.runId); entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!allowReturn.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        if (!allowReturn.load()) { throw IllegalStateException("actual application fixture gate timed out") }
        executedDigest = prepared.operationPlan.bindingDigest
        let actual = reserveNativeDocumentPayload(65536)
        try {
            actual.ensureRetainedPeak(65536)
            Result.Ok(ToolResult(prepared.call.callId, textValue("canonical-success雪"),
                payloadLease: Some(ToolResultPayloadLease({ => actual.close() }))))
        } catch (failure: Exception) { actual.close(); throw failure }
    }
    private func observe(plan: NormalizedOperationPlan, result: ToolResult): OwnedFailureDataOutcome113<Unit> {
        ownedCalls++
        @Expect(plan.bindingDigest, executedDigest)
        @Expect(plan.toolName, "boundary_checkpoint11318")
        @Expect(result.isError, false); @Expect(result.payloadLease.isSome())
        let rows = database.query("SELECT o.normalized_plan,r.outcome,e.reserved_receipt_id,i.payload " +
            "FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id " +
            "JOIN operation_receipts r ON r.id=e.reserved_receipt_id AND r.operation_id=o.id " +
            "JOIN items i ON i.id=e.reserved_result_item_id WHERE r.id=?", [SqlParameter.Text(result.receiptId)])
        @Expect(rows.size, 1); @Expect(rows[0].required(1), "completed")
        @Expect(rows[0].required(2), result.receiptId)
        @Expect(decodeStoredValue(rows[0].required(0)).field("digest").getOrThrow().text, plan.bindingDigest)
        @Expect(rows[0].required(3).contains("canonical-success"))
        lastReceipt = result.receiptId
        // The original Native bank pays the actual producer before any error
        // DTO/attachment is built. Capture derives that SAME bank's child.
        let producer = reserveNativeDocumentPayload(65536)
        try {
            producer.ensureRetainedPeak(1048576)
            captureOwnedFailureData113<Unit>(boundaryConsumerError11318(kind, result),
                { _ => producer.deriveRetainedLease() })
        } finally { producer.close() }
    }
    public func afterPreparedResultPersistedOwned113(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit> {
        Some(observe(originalPlan, result))
    }
    public func afterDirectResultPersistedOwned113(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): ?OwnedFailureDataOutcome113<Unit> {
        @Expect(refEq(context.budget, boundary.budget))
        @Expect(boundary.source.runId.value, context.runId.value)
        Some(observe(prepared.operationPlan, result))
    }
    public func afterPreparedResultPersisted(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): Result<Unit> { oldCalls++; Result.Ok(()) }
    public func afterDirectResultPersisted(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        result: ToolResult, boundary: DirectPostCanonicalProjectionBoundary): Result<Unit> { oldCalls++; Result.Ok(()) }
}

private class BoundaryConsumerEvent11318 <: OwnedAgentEventSink & OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let observer: BoundaryConsumerObserver11318
    var held: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    var calls: Int64 = 0
    init(observer: BoundaryConsumerObserver11318) { this.observer = observer }
    public func emit(event: OwnedAgentEvent): Result<Unit> {
        match (event.withEvent(65536, { _ => Result<Unit>.Ok(()) })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        event.closeAfterEventRetirement()
    }
    public func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 {
        calls++; @Expect(held.isNone()); held = Some(value)
        @Expect(value.withDiagnostic({ event, fund =>
            fund(65536).value().getOrThrow()
            match (event.payload) {
                case AgentEventPayload.Diagnostic(error) =>
                    expectBoundaryConsumerError11318(error, observer.kind, observer.lastReceipt)
                case _ => throw IllegalStateException("actual Application Diagnostic lost its full error") }
            @Expect(value.acknowledgeAfterConsumption().isError())
            Result<Unit>.Ok(())
        }).isOk())
        OwnedFailureEventAdmissionOutcome113.Accepted
    }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        throw IllegalStateException("actual Application must use explicit admission, not Result inference")
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        match (admitOwnedFailure113(value)) {
            case OwnedFailureEventAdmissionOutcome113.Accepted => OwnedFailureDataOutcome113<Unit>.Value(())
            case _ => throw IllegalStateException("fixture admission did not accept its actual share") }
    }
    func retire(): Unit {
        let value = held.getOrThrow(); held = None<OwnedFailureRunPublication113>
        @Expect(value.acknowledgeAfterConsumption().isOk())
    }
}

// A real settled first ToolResult changes the installed catalogue. Core's
// ORIGINAL safe-cut writer commits the resulting boundary; no successful
// boundary, Run, Source, plan, Receipt, or canonical history is seeded by SQL.
private class BoundaryPrepareTool11318 <: ToolExecutor {
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        let owner = reserveNativeDocumentPayload(65536)
        try {
            owner.ensureRetainedPeak(65536)
            Result.Ok(ToolResult(prepared.call.callId, textValue("actual pre-cut success"),
                payloadLease: Some(ToolResultPayloadLease({ => owner.close() }))))
        } catch (error: Exception) { owner.close(); throw error }
    }
}
private func boundaryDescriptor11318(name: String): ToolDescriptor {
    ToolDescriptor(ModelToolDefinition(name, "Actual crash-and-reopen boundary fixture",
        objectValue([ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
        Capability(CapabilityKind.WorkspaceRead), sideEffecting: false,
        implementationVersion: "boundary11318", implementationFingerprint: "boundary11318")
}
private func boundaryOpenProduct11318(root: String): ProductRuntime {
    lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root,
        settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
        asyncEnabled: false, approvalMode: ApprovalMode.Yolo)))
}
private class BoundaryActualCut11318 {
    let product: ProductRuntime
    let database: SqliteDatabase
    let observer: BoundaryConsumerObserver11318
    let run: RunId
    let root: String
    var installed = false
    init(product: ProductRuntime, database: SqliteDatabase, observer: BoundaryConsumerObserver11318,
        run: RunId, root: String) {
        this.product = product; this.database = database; this.observer = observer
        this.run = run; this.root = root
    }
    func event(value: AgentEvent): Unit {
        if (value.runId.value != run.value) { return }
        match (value.payload) {
            case AgentEventPayload.Extension(_, detail) =>
                if (!installed && detail.field("code").isSome() &&
                    detail.field("code").getOrThrow().text == "tool.execution_completed" &&
                    detail.field("name").getOrThrow().text == "boundary_prepare11318") {
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
                    @Expect(product.registerTool(boundaryDescriptor11318("boundary_checkpoint11318"), observer).isOk())
                    installed = true
                }
            case AgentEventPayload.BudgetUpdated(_) => if (installed) {
                let actual = lifecycleTestRequire(product.pendingContextBoundary(SessionId("boundary-thread11318")))
                if (actual.isSome()) {
                    @Expect(actual.getOrThrow().continuation.runId.value, run.value)
                    @Expect(contextBoundaryText(actual.getOrThrow().data(), "point"), "turn_reserved")
                    @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 1)
                    @Expect(observer.executed, 0); @Expect(observer.ownedCalls, 0)
                    @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
                    // This file is only a committed-cut observation. The parent
                    // must kill AND reap this real child before recovery starts.
                    File.writeTo(root + "/boundary-ready11318", run.value.toArray())
                    while (true) { sleep(Duration.millisecond * 10) }
                }
            }
            case _ => ()
        }
    }
}
private func boundaryRunActualChild11318(root: String): Unit {
    let product = boundaryOpenProduct11318(root)
    let database = SqliteDatabase(root + "/state/state.db")
    let observer = BoundaryConsumerObserver11318(database, AgentErrorKind.Internal)
    try {
        @Expect(product.registerTool(boundaryDescriptor11318("boundary_prepare11318"), BoundaryPrepareTool11318()).isOk())
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("boundary-prepare-call11318", "boundary_prepare11318", objectValue([]))
        let request = product.request("Commit the actual first tool, then freeze at the real safe cut.",
            sessionId: Some(SessionId("boundary-thread11318")))
        let cut = BoundaryActualCut11318(product, database, observer, request.runId, root)
        let _ = product.client.start(request, { value => cut.event(value) })
        throw IllegalStateException("the real committed context boundary was never observed")
    } finally { let _ = product.close(); database.close() }
}
private class BoundaryChildOutput11318 {
    var bytes: Int64 = 0
    func drain(input: InputStream): Unit {
        let buffer = Array<Byte>(8192, repeat: 0u8)
        while (true) {
            let size = input.read(buffer); if (size == 0) { return }
            bytes += size
            if (bytes > 1048576) { throw IllegalStateException("owned boundary child output exceeded its original one-MiB limit") }
        }
    }
}
@Test
class ActualBoundaryOwnedStartup11318Tests {
    @TestCase
    func actualCommittedBoundaryAfterPhysicalChildExitResumesStartupWithPaidFailureAndRealSubscribers(): Unit {
        match (getVariable("AXYNDRA_BOUNDARY_CHILD_ROOT11318")) {
            case Some(childRoot) => boundaryRunActualChild11318(childRoot); return
            case None => ()
        }
        let root = pluginContractTemp("actual-boundary-startup11318")
        let repo = getVariable("AXYNDRA_REPO_ROOT").getOrThrow()
        let environment = HashMap<String, String>()
        // A nonempty native ProcessCommand environment replaces environ.
        // Preserve every actual parent variable, including SDK/cache and
        // network policy; add only this private child fixture selector.
        for ((name, value) in getVariables()) { environment[name] = value }
        environment["AXYNDRA_BOUNDARY_CHILD_ROOT11318"] = root
        let child = boundary_process.startProcess(boundary_process.ProcessCommand(repo + "/scripts/pinned_cangjie",
            arguments: ["cjpm", "test", "-m", "agent_product", "--skip-build", "--filter",
                "ActualBoundaryOwnedStartup11318Tests.actualCommittedBoundaryAfterPhysicalChildExitResumesStartupWithPaidFailureAndRealSubscribers",
                "--parallel", "1", "--timeout-each=60s", "--no-color", "--no-progress"],
            workingDirectory: repo, environment: environment, maxOutputBytes: 1048576, terminateProcessTree: true))
        let stdout = BoundaryChildOutput11318(); let stderr = BoundaryChildOutput11318()
        let outputTask = spawn { stdout.drain(child.stdout) }
        let errorTask = spawn { stderr.drain(child.stderr) }
        try {
            let deadline = MonoTime.now() + Duration.second * 20
            while (!exists(Path(root + "/boundary-ready11318")) && child.isAlive() && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 10)
            }
            @Expect(exists(Path(root + "/boundary-ready11318")))
            @Expect(child.isAlive())
            @Expect(child.terminate(force: true))
            let status = child.wait(); @Expect(!status.succeeded); @Expect(!child.isAlive())
            outputTask.get(); errorTask.get(); @Expect(child.close())
            // The OS process (and every original child Source/physical owner)
            // is now gone. Recovery uses its actual database, never a cloned or
            // manually repaired successful history and never a second live Run.
            let product = boundaryOpenProduct11318(root)
            let database = SqliteDatabase(root + "/state/state.db")
            let observer = BoundaryConsumerObserver11318(database, AgentErrorKind.Internal)
            try {
                @Expect(product.registerTool(boundaryDescriptor11318("boundary_prepare11318"), BoundaryPrepareTool11318()).isOk())
                @Expect(product.registerTool(boundaryDescriptor11318("boundary_checkpoint11318"), observer).isOk())
                let actual = lifecycleTestRequire(product.pendingContextBoundary(SessionId("boundary-thread11318"))).getOrThrow()
                @Expect(contextBoundaryText(actual.data(), "point"), "turn_reserved")
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
                let oldReceipt = database.query("SELECT r.id,r.detail,i.payload FROM operation_receipts r " +
                    "JOIN operation_effect_records e ON e.reserved_receipt_id=r.id " +
                    "JOIN items i ON i.id=e.reserved_result_item_id WHERE r.outcome='completed'")
                @Expect(oldReceipt.size, 1)
                let session = product.applicationSession(sessionId: Some(SessionId("boundary-thread11318")))
                let first = BoundaryConsumerEvent11318(observer); let second = BoundaryConsumerEvent11318(observer)
                session.subscribeOwned({ _ => () }, first, failures: Some(first))
                session.subscribeOwned({ _ => () }, second, failures: Some(second))
                product.fixtureProbe.getOrThrow().enqueueToolCallReply("boundary-owned-call11318", "boundary_checkpoint11318", objectValue([]))
                let marker = session.resumeStartup().error().getOrThrow()
                @Expect(marker.kind, AgentErrorKind.Internal)
                @Expect(session.hasOwnedCheckpointFailure113(marker))
                @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 1)
                @Expect(observer.executed, 1); @Expect(observer.ownedCalls, 1); @Expect(observer.oldCalls, 0)
                @Expect(first.calls, 1); @Expect(second.calls, 1)
                let caller = match (session.takeOwnedCheckpointFailure113(marker).getOrThrow()) {
                    case OwnedAgentRunResult113.Failed(value) => value
                    case _ => throw IllegalStateException("real boundary startup did not transfer its paid caller") }
                @Expect(caller.withError({ error, fund =>
                    fund(65536).value().getOrThrow()
                    expectBoundaryConsumerError11318(error, observer.kind, observer.lastReceipt)
                    @Expect(caller.acknowledgeAfterConsumption().isError()); Result<Unit>.Ok(()) }).isOk())
                @Expect(!refEq(first.held.getOrThrow(), second.held.getOrThrow()))
                @Expect(!refEq(first.held.getOrThrow(), caller))
                @Expect(session.resumeStartup().isError())
                @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 1)
                first.retire(); session.collectOwnedCheckpointFailure113()
                @Expect(!second.held.getOrThrow().isAcknowledged()); @Expect(!caller.isAcknowledged())
                second.retire(); @Expect(caller.acknowledgeAfterConsumption().isOk())
                session.collectOwnedCheckpointFailure113()
                let _ = session.takeOwnedCheckpointFailure113(actual.continuation.runId)
                session.collectOwnedCheckpointFailure113()
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 2)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 2)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 2)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 2)
                let unchanged = database.query("SELECT r.id,r.detail,i.payload FROM operation_receipts r " +
                    "JOIN operation_effect_records e ON e.reserved_receipt_id=r.id " +
                    "JOIN items i ON i.id=e.reserved_result_item_id WHERE r.id=?", [SqlParameter.Text(oldReceipt[0].required(0))])
                @Expect(unchanged.size, 1)
                for (index in 0..3) { @Expect(unchanged[0].required(index), oldReceipt[0].required(index)) }
                @Expect(product.pendingContextBoundary(SessionId("boundary-thread11318")).value().getOrThrow().isNone())
                @Expect(database.query("PRAGMA foreign_key_check").isEmpty())
                @Expect(session.takeOwnedCheckpointFailure113(marker).isNone())
            } finally { let _ = product.close(); database.close() }
        } finally {
            let _ = child.terminate(force: true); let _ = child.wait()
            try { outputTask.get() } finally { try { errorTask.get() } finally { let _ = child.close(); remove(root, recursive: true) } }
        }
    }
}
