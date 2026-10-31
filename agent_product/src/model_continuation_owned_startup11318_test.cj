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
private func modelStartupConsumerError11318(kind: AgentErrorKind, result: ToolResult): AgentError {
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
private func expectModelStartupConsumerError11318(error: AgentError, kind: AgentErrorKind,
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
    @Expect(observation.field("content").getOrThrow().field("actual_call").getOrThrow().text, "model-startup-owned-call11318")
}
private class ModelStartupConsumerObserver11318 <: ToolExecutor & PreparedPostCanonicalToolObserver &
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
        @Expect(plan.toolName, "model_startup_checkpoint11318")
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
            captureOwnedFailureData113<Unit>(modelStartupConsumerError11318(kind, result),
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

private class ModelStartupConsumerEvent11318 <: OwnedAgentEventSink & OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let observer: ModelStartupConsumerObserver11318
    var held: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    var calls: Int64 = 0
    init(observer: ModelStartupConsumerObserver11318) { this.observer = observer }
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
                    expectModelStartupConsumerError11318(error, observer.kind, observer.lastReceipt)
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

private class ModelStartupChildOutput11318 {
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

private func modelStartupOpenProduct11318(root: String): ProductRuntime {
    lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root,
        settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
        asyncEnabled: false, approvalMode: ApprovalMode.Yolo)))
}
private func modelStartupInstallObserver11318(product: ProductRuntime, observer: ModelStartupConsumerObserver11318): Unit {
    @Expect(product.registerTool(ToolDescriptor(ModelToolDefinition("model_startup_checkpoint11318",
        "Actual frozen model continuation followed by a paid checkpoint observer", objectValue([
            ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
        Capability(CapabilityKind.WorkspaceRead), sideEffecting: false,
        implementationVersion: "model-startup11318", implementationFingerprint: "model-startup11318"), observer).isOk())
}
private class ModelStartupActualCheckpoint11318 {
    private let product: ProductRuntime
    private let database: SqliteDatabase
    private let observer: ModelStartupConsumerObserver11318
    private let root: String
    private let session: SessionId
    init(product: ProductRuntime, database: SqliteDatabase, observer: ModelStartupConsumerObserver11318,
        root: String, session: SessionId) {
        this.product = product; this.database = database; this.observer = observer
        this.root = root; this.session = session
    }
    func observe(event: AgentEvent): Unit {
        match (event.payload) {
            case AgentEventPayload.Extension(_, detail) =>
                if (detail.field("code").isNone() ||
                    detail.field("code").getOrThrow().text != "model.attempt_policy_applied") { return }
                let continuation = product.pendingRecoveryContinuation(session).value().getOrThrow().getOrThrow()
                @Expect(continuation.kind, RunContinuationKind.RunningModel)
                @Expect(continuation.runId.value, event.runId.value)
                let checkpoint = continuation.runningModel.getOrThrow()
                let rows = database.query("SELECT id,dispatch_state,attempt_no,transcript_snapshot FROM model_attempts WHERE id=?",
                    [SqlParameter.Text(checkpoint.activeAttemptId.value)])
                @Expect(rows.size, 1); @Expect(rows[0].required(1), "prepared"); @Expect(rows[0].required(2), "1")
                @Expect(rows[0].required(3) != "")
                @Expect(product.fixtureProbe.getOrThrow().validateTranscriptSnapshot(rows[0].required(3)))
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
                @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 0)
                @Expect(observer.executed, 0); @Expect(observer.ownedCalls, 0)
                // The ORIGINAL writer committed this complete checkpoint in
                // prepareModelAttempt before this event and before dispatch.
                // This file observes its identity; it constructs no history.
                File.writeTo(root + "/model-ready11318", checkpoint.activeAttemptId.value.toArray())
                while (true) { sleep(Duration.millisecond * 10) }
            case _ => ()
        }
    }
}
private func modelStartupRunActualChild11318(root: String): Unit {
    let product = modelStartupOpenProduct11318(root)
    let database = SqliteDatabase(root + "/state/state.db")
    let observer = ModelStartupConsumerObserver11318(database, AgentErrorKind.Internal)
    try {
        modelStartupInstallObserver11318(product, observer)
        let session = product.applicationSession(sessionId: Some(SessionId("model-startup-thread11318")))
        let cut = ModelStartupActualCheckpoint11318(product, database, observer, root, session.id())
        session.subscribe({ event => cut.observe(event) })
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("model-startup-owned-call11318", "model_startup_checkpoint11318", objectValue([]))
        let _ = session.submit("Dispatch this exact frozen request only after real process recovery.")
        throw IllegalStateException("the original committed model checkpoint was not observed")
    } finally { let _ = product.close(); database.close() }
}
@Test
class ActualModelContinuationOwnedStartup11318Tests {
    @TestCase
    func actualPreparedModelAfterPhysicalChildExitResumesStartupAndKeepsOriginalAttemptWithPaidFailureShares(): Unit {
        match (getVariable("AXYNDRA_MODEL_CHILD_ROOT11318")) {
            case Some(childRoot) => modelStartupRunActualChild11318(childRoot); return
            case None => ()
        }
        let root = pluginContractTemp("actual-model-startup11318")
        let repo = getVariable("AXYNDRA_REPO_ROOT").getOrThrow()
        let environment = HashMap<String, String>()
        for ((name, value) in getVariables()) { environment[name] = value }
        environment["AXYNDRA_MODEL_CHILD_ROOT11318"] = root
        let child = boundary_process.startProcess(boundary_process.ProcessCommand(repo + "/scripts/pinned_cangjie",
            arguments: ["cjpm", "test", "-m", "agent_product", "--skip-build", "--filter",
                "ActualModelContinuationOwnedStartup11318Tests.actualPreparedModelAfterPhysicalChildExitResumesStartupAndKeepsOriginalAttemptWithPaidFailureShares",
                "--parallel", "1", "--timeout-each=60s", "--no-color", "--no-progress"],
            workingDirectory: repo, environment: environment, maxOutputBytes: 1048576, terminateProcessTree: true))
        let stdout = ModelStartupChildOutput11318(); let stderr = ModelStartupChildOutput11318()
        let outputTask = spawn { stdout.drain(child.stdout) }; let errorTask = spawn { stderr.drain(child.stderr) }
        try {
            let deadline = MonoTime.now() + Duration.second * 20
            while (!exists(Path(root + "/model-ready11318")) && child.isAlive() && MonoTime.now() < deadline) {
                sleep(Duration.millisecond * 10)
            }
            @Expect(exists(Path(root + "/model-ready11318"))); @Expect(child.isAlive())
            @Expect(child.terminate(force: true))
            let status = child.wait(); @Expect(!status.succeeded); @Expect(!child.isAlive())
            outputTask.get(); errorTask.get(); @Expect(child.close())
            let product = modelStartupOpenProduct11318(root)
            let database = SqliteDatabase(root + "/state/state.db")
            let observer = ModelStartupConsumerObserver11318(database, AgentErrorKind.Internal)
            try {
                modelStartupInstallObserver11318(product, observer)
                let session = product.applicationSession(sessionId: Some(SessionId("model-startup-thread11318")))
                let continuation = product.pendingRecoveryContinuation(session.id()).value().getOrThrow().getOrThrow()
                @Expect(continuation.kind, RunContinuationKind.RunningModel)
                let checkpoint = continuation.runningModel.getOrThrow()
                @Expect(checkpoint.activeAttemptId.value, String.fromUtf8(File.readFrom(root + "/model-ready11318")))
                let original = database.query("SELECT id,semantic_request_id,semantic_request_digest,wire_policy_digest," +
                    "attempt_no,COALESCE(parent_attempt_id,''),provider_request_id,transcript_snapshot FROM model_attempts WHERE id=?",
                    [SqlParameter.Text(checkpoint.activeAttemptId.value)])
                @Expect(original.size, 1); @Expect(original[0].required(4), "1"); @Expect(original[0].required(5), "")
                @Expect(original[0].required(7) != "")
                @Expect(original[0].required(1), checkpoint.semanticRequestId.value)
                @Expect(original[0].required(2), checkpoint.semanticRequestDigest)
                @Expect(original[0].required(3), checkpoint.wirePolicyDigest)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
                @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 0)
                let first = ModelStartupConsumerEvent11318(observer); let second = ModelStartupConsumerEvent11318(observer)
                session.subscribeOwned({ _ => () }, first, failures: Some(first))
                session.subscribeOwned({ _ => () }, second, failures: Some(second))
                product.fixtureProbe.getOrThrow().enqueueToolCallReply("model-startup-owned-call11318", "model_startup_checkpoint11318", objectValue([]))
                // Same real queued script and original canonical request reproduce
                // the committed provider transcript before any model executes.
                let frozenRequest = modelRequestFromSnapshotValue(checkpoint.canonicalRequest,
                    checkpoint.stableRequestId).value().getOrThrow()
                @Expect(product.fixtureProbe.getOrThrow().validateTranscriptSnapshot(original[0].required(7)))
                @Expect(product.fixtureProbe.getOrThrow().transcriptSnapshot(frozenRequest).getOrThrow(), original[0].required(7))
                let marker = session.resumeStartup().error().getOrThrow()
                @Expect(marker.kind, AgentErrorKind.Internal); @Expect(session.hasOwnedCheckpointFailure113(marker))
                @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 1)
                @Expect(observer.executed, 1); @Expect(observer.ownedCalls, 1); @Expect(observer.oldCalls, 0)
                @Expect(first.calls, 1); @Expect(second.calls, 1)
                let caller = match (session.takeOwnedCheckpointFailure113(marker).getOrThrow()) {
                    case OwnedAgentRunResult113.Failed(value) => value
                    case _ => throw IllegalStateException("restored model did not hand off its actual paid caller") }
                @Expect(caller.withError({ error, fund =>
                    fund(65536).value().getOrThrow()
                    expectModelStartupConsumerError11318(error, observer.kind, observer.lastReceipt)
                    @Expect(caller.acknowledgeAfterConsumption().isError()); Result<Unit>.Ok(()) }).isOk())
                @Expect(!refEq(first.held.getOrThrow(), second.held.getOrThrow()))
                @Expect(!refEq(first.held.getOrThrow(), caller))
                @Expect(session.resumeStartup().isError())
                @Expect(observer.executed, 1); @Expect(product.fixtureProbe.getOrThrow().observedCallCount11318(), 1)
                first.retire(); session.collectOwnedCheckpointFailure113()
                @Expect(!caller.isAcknowledged()); @Expect(!second.held.getOrThrow().isAcknowledged())
                second.retire(); @Expect(caller.acknowledgeAfterConsumption().isOk())
                session.collectOwnedCheckpointFailure113()
                let _ = session.takeOwnedCheckpointFailure113(continuation.runId)
                session.collectOwnedCheckpointFailure113()
                let unchanged = database.query("SELECT id,semantic_request_id,semantic_request_digest,wire_policy_digest," +
                    "attempt_no,COALESCE(parent_attempt_id,''),provider_request_id,transcript_snapshot FROM model_attempts WHERE id=?",
                    [SqlParameter.Text(checkpoint.activeAttemptId.value)])
                @Expect(unchanged.size, 1)
                for (index in 0..8) { @Expect(unchanged[0].required(index), original[0].required(index)) }
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts WHERE parent_attempt_id IS NOT NULL"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
                @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 1)
                @Expect(database.query("PRAGMA foreign_key_check").isEmpty())
                @Expect(session.takeOwnedCheckpointFailure113(marker).isNone())
            } finally { let _ = product.close(); database.close() }
        } finally {
            let _ = child.terminate(force: true); let _ = child.wait()
            try { outputTask.get() } finally { try { errorTask.get() } finally { let _ = child.close(); remove(root, recursive: true) } }
        }
    }
}
