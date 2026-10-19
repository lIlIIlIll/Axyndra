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
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// The fixture proposes one call. Core/Direct and the real SQLite stores alone
// create its Source, operation, canonical ToolResult and completed Receipt.
private class CheckpointConsumerIds11318 <: IdGenerator {
    private var next: Int64 = 0
    public func nextRunId(): RunId { next++; RunId("consumer-direct-" + next.toString()) }
    public func nextSessionId(): SessionId { SessionId("consumer-thread") }
    public func nextOperationId(): OperationId { next++; OperationId("consumer-operation-" + next.toString()) }
}
private class CheckpointConsumerModel11318 <: ModelPort {
    var calls: Int64 = 0
    public func execute(request: ModelRequest, sink: ModelEventSink): Result<ModelReply> {
        calls++
        let evidence = TerminalEvidence("fixture", "message_stop", rawStopReason: "tool_use",
            messageTerminalObserved: true, streamEofObserved: true, adapterVersion: "fixture-v1")
        sink(ModelEvent.ProviderProgress(ProviderStreamEvent.MessageTerminalObserved(evidence)))
        Result.Ok(ModelReply([ModelBlock(ModelBlockKind.ToolCall, callId: "consumer-call", name: "consumer_checkpoint",
            arguments: objectValue([]))], stopReason: "tool_use", terminalEvidence: Some(evidence),
            completionDisposition: CompletionDisposition.ToolUse, decisionOutcome: DecisionOutcome.ToolCalls,
            validationVersion: 1))
    }
}

private func checkpointConsumerError11318(kind: AgentErrorKind, result: ToolResult): AgentError {
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
private func expectCheckpointConsumerError11318(error: AgentError, kind: AgentErrorKind,
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
    @Expect(observation.field("content").getOrThrow().field("actual_call").getOrThrow().text, "consumer-call")
}
private class CheckpointConsumerObserver11318 <: ToolExecutor & PreparedPostCanonicalToolObserver &
    DirectPostCanonicalToolObserver & PaidPreparedPostCanonicalToolObserver113 & PaidDirectPostCanonicalToolObserver113 {
    private let database: SqliteDatabase
    let kind: AgentErrorKind
    var executed: Int64 = 0
    var ownedCalls: Int64 = 0
    var oldCalls: Int64 = 0
    var lastReceipt = ""
    private var executedDigest = ""
    init(database: SqliteDatabase, kind: AgentErrorKind) { this.database = database; this.kind = kind }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        executed++
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
        @Expect(plan.toolName, "consumer_checkpoint")
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
            captureOwnedFailureData113<Unit>(checkpointConsumerError11318(kind, result),
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

private class CheckpointConsumerEvent11318 <: OwnedAgentEventSink & OwnedFailureEventSink113 {
    private let observer: CheckpointConsumerObserver11318
    var held: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    var calls: Int64 = 0
    init(observer: CheckpointConsumerObserver11318) { this.observer = observer }
    public func emit(event: OwnedAgentEvent): Result<Unit> {
        match (event.withEvent(65536, { _ => Result<Unit>.Ok(()) })) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        event.closeAfterEventRetirement()
    }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        calls++
        @Expect(held.isNone()); held = Some(value)
        value.withDiagnostic({ event, fund =>
            fund(65536).value().getOrThrow()
            match (event.payload) { case AgentEventPayload.Diagnostic(error) =>
                expectCheckpointConsumerError11318(error, observer.kind, observer.lastReceipt)
                case _ => throw IllegalStateException("real failure publication lost its Diagnostic") }
            @Expect(value.acknowledgeAfterConsumption().isError())
            Result<Unit>.Ok(())
        })
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        match (emitOwnedFailure113(value)) { case Result.Err(error) => return value.captureFailure113<Unit>(error)
            case Result.Ok(_) => OwnedFailureDataOutcome113<Unit>.Value(()) }
        // Core must observe the unACKed real alias, despite Value. No callback
        // return may credit delivery while this actual queue still holds it.
    }
    func retire(): Unit {
        let actual = held.getOrThrow(); held = None<OwnedFailureRunPublication113>
        @Expect(actual.acknowledgeAfterConsumption().isOk())
    }
}
private class CheckpointConsumerFixture11318 {
    let root: String
    let database: SqliteDatabase
    let runs: SqliteRunRepository
    let core: AgentCore
    let gateway: HostCanonicalToolGateway
    let observer: CheckpointConsumerObserver11318
    let events: CheckpointConsumerEvent11318
    let request: AgentRunRequest
    let model: CheckpointConsumerModel11318
    init(label: String, approval!: Bool = false, kind!: AgentErrorKind = AgentErrorKind.Internal) {
        let directory = pluginContractTemp("owned-checkpoint-consumer11318-" + label)
        Directory.create(directory + "/workspace", recursive: true)
        let db = SqliteDatabase(directory + "/consumer.db")
        let ids = CheckpointConsumerIds11318(); let catalog = ToolCatalog()
        let actual = CheckpointConsumerObserver11318(db, kind)
        catalog.register(ToolDescriptor(ModelToolDefinition("consumer_checkpoint", "Actual paid failure observer",
            objectValue([ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
            Capability(CapabilityKind.WorkspaceRead), sideEffecting: approval,
            implementationVersion: "consumer11318", implementationFingerprint: "consumer11318"), actual).value().getOrThrow()
        let operations = DurableOperationStore(db)
        let pipeline = ToolPipeline(catalog, operations, SqliteAuditRepository(db), ids)
        let threads = SqliteThreadRuntimeRegistry(db,
            ContextProjector("consumer11318", ConservativeThreadTokenEstimator()), { => agentUtcMillis() })
        let repository = SqliteRunRepository(db); let proposed = CheckpointConsumerModel11318()
        let engine = AgentCore(proposed, repository, pipeline, catalog, threadRuntimes: Some(threads),
            operationRuntime: Some(operations), modelDecisionRuntime: Some(SqliteModelDecisionStore(db)),
            contextManifestRuntime: Some(ProductContextManifestRuntime(db)))
        this.root = directory; this.database = db; this.runs = repository; this.core = engine
        this.observer = actual; this.events = CheckpointConsumerEvent11318(actual); this.model = proposed
        this.request = AgentRunRequest(RunId("consumer-run"), SessionId("consumer-thread"), "fixture", "Run the real tool once",
            thinking: ThinkingLevel.Off, autoRetry: false,
            capabilities: CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]),
            approvalModeOverride: Some(if (approval) { ApprovalMode.AlwaysAsk } else { ApprovalMode.Yolo }),
            toolContext: productToolContext(directory + "/workspace"),
            budget: ResourceBudget(maxModelRequests: 1, maxToolCalls: 1, maxConcurrentTools: 1))
        this.gateway = HostCanonicalToolGateway(db, catalog, pipeline, ids, threads, operations,
            directory + "/workspace", { path => productToolContext(path) }, { _ => false }, { _ => Result<Unit>.Ok(()) })
    }
    func expectCanonical(): Unit {
        expectCanonicalReservedRootResults(database, request.sessionId.value, 1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), 1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), 1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), 1)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
        @Expect(observer.executed, 1); @Expect(observer.ownedCalls, 1); @Expect(observer.oldCalls, 0)
    }
    func close(): Unit { database.close(); remove(root, recursive: true) }
}
private func checkpointCaller11318(value: OwnedAgentRunResult113): OwnedFailureRunPublication113 {
    match (value) { case OwnedAgentRunResult113.Failed(caller) => caller
        case _ => throw IllegalStateException("actual Core failure did not transfer its paid caller") }
}
private func checkpointDirectCaller11318(value: OwnedHostDirectToolResult113): OwnedFailureDataConsumer113 {
    match (value) { case OwnedHostDirectToolResult113.Failed(caller) => caller
        case _ => throw IllegalStateException("actual Direct failure did not transfer its paid caller") }
}
private func checkpointConsumeCaller11318(f: CheckpointConsumerFixture11318,
    caller: OwnedFailureRunPublication113): Unit {
    @Expect(caller.withSnapshot({ snapshot, fund =>
        fund(65536).value().getOrThrow()
        @Expect(snapshot.status, RunState.Failed)
        expectCheckpointConsumerError11318(snapshot.error.getOrThrow(), f.observer.kind, f.observer.lastReceipt)
        @Expect(caller.acknowledgeAfterConsumption().isError())
        Result<Unit>.Ok(())
    }).isOk())
    // Default None has not credited live delivery. Install an actual typed
    // sink now; its queue retains a DIFFERENT publication until real ACK.
    @Expect(f.core.flushOwnedCheckpointFailures113(f.request.runId, events: Some(f.events)).isError())
    @Expect(f.events.calls, 1); @Expect(!refEq(f.events.held.getOrThrow(), caller))
    f.events.retire()
    @Expect(f.core.flushOwnedCheckpointFailures113(f.request.runId, events: Some(f.events)).isOk())
    @Expect(f.events.calls, 1)
    @Expect(caller.withError({ error, fund => fund(65536).value().getOrThrow()
        expectCheckpointConsumerError11318(error, f.observer.kind, f.observer.lastReceipt); Result<Unit>.Ok(()) }).isOk())
}

@Test
class OwnedCheckpointConsumer11318Tests {
    @TestCase
    func actualCoreStartSqlStorageEventAndCallerRetireIndependently(): Unit {
        let f = CheckpointConsumerFixture11318("core-start")
        try {
            let runner: AgentRunner = f.core
            let caller = checkpointCaller11318(runner.startOwnedCheckpointFailure113(f.request, { _ => () }))
            try {
                f.expectCanonical(); checkpointConsumeCaller11318(f, caller)
                let storage = caller.retainConsumer().value().getOrThrow()
                @Expect(!refEq(storage, caller))
                match (f.runs.saveOwnedFailureOutcome113(storage)) {
                    case OwnedFailureDataOutcome113.Value(_) => @Expect(storage.isAcknowledged())
                    case _ => throw IllegalStateException("real SQLite independent consumer did not store") }
                @Expect(!caller.isAcknowledged())
                // Original 128 MiB pool: 64+32+32 fits only AFTER the paid
                // failure's last consumer retires. No new bank or raised cap.
                let first = reserveNativeDocumentPayload(8388608)
                try {
                    let second = reserveNativeDocumentPayload(4194304)
                    try {
                        var rejected = false
                        try { let unexpected = reserveNativeDocumentPayload(4194304); unexpected.close() }
                        catch (_: LogicalJsonPayloadError) { rejected = true }
                        @Expect(rejected)
                        @Expect(caller.acknowledgeAfterConsumption().isOk())
                        let restored = reserveNativeDocumentPayload(4194304); restored.close()
                    } finally { second.close() }
                } finally { first.close() }
                f.expectCanonical()
            } finally { let _ = caller.acknowledgeAfterConsumption() }
        } finally { f.close() }
    }
    @TestCase
    func actualResumeGatewayPreservesExistingCanonicalFailureAndFullCaller(): Unit {
        let f = CheckpointConsumerFixture11318("core-resume")
        try {
            @Expect(f.core.start(f.request, { _ => () }).isError())
            f.expectCanonical()
            // Resume enters the real repository continuation check; its
            // non-running-model error cannot replace the existing paid error.
            let runner: AgentRunner = f.core
            let caller = checkpointCaller11318(runner.resumeOwnedCheckpointFailure113(f.request, { _ => () }))
            try { checkpointConsumeCaller11318(f, caller); f.expectCanonical(); @Expect(f.model.calls, 1) }
            finally { @Expect(caller.acknowledgeAfterConsumption().isOk()) }
        } finally { f.close() }
    }
    @TestCase
    func actualDecideExecutesTheOriginalApprovalOnceThenTransfersFullFailure(): Unit {
        let f = CheckpointConsumerFixture11318("core-decide", approval: true)
        try {
            let runner: AgentRunner = f.core
            let approval = match (runner.startOwnedCheckpointFailure113(f.request, { _ => () })) {
                case OwnedAgentRunResult113.Existing(Result.Ok(AgentRunOutcome.AwaitingApproval(_, value))) => value
                case _ => throw IllegalStateException("real Core did not create its pending approval") }
            @Expect(f.observer.executed, 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), 0)
            let caller = checkpointCaller11318(runner.decideOwnedCheckpointFailure113(
                f.request, approval, ApprovalDecision.Approve, { _ => () }))
            try { f.expectCanonical(); checkpointConsumeCaller11318(f, caller); @Expect(f.model.calls, 1) }
            finally { @Expect(caller.acknowledgeAfterConsumption().isOk()) }
        } finally { f.close() }
    }
    @TestCase
    func actualDirectGatewayTransfersTheFailedObserverAfterKnownCompletion(): Unit {
        let f = CheckpointConsumerFixture11318("direct")
        try {
            let caller = checkpointDirectCaller11318(f.gateway.executeOwnedCheckpointFailure113(
                f.request.sessionId, f.request.capabilities, ToolCall("consumer-call", "consumer_checkpoint", objectValue([])),
                InvocationContextProjection(), Some(f.request.runId), None<ApprovalDecision>))
            try {
                f.expectCanonical(); @Expect(f.model.calls, 0)
                @Expect(caller.withError({ error, fund => fund(65536).value().getOrThrow()
                    expectCheckpointConsumerError11318(error, f.observer.kind, f.observer.lastReceipt)
                    @Expect(caller.acknowledgeAfterConsumption().isError()) }).isOk())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), 0)
            } finally { @Expect(caller.acknowledgeAfterConsumption().isOk()) }
        } finally { f.close() }
    }
    @TestCase
    func actualDeferredDirectOwnerUsesTheSameGatewayQueueAndRealApproval(): Unit {
        let f = CheckpointConsumerFixture11318("direct-deferred", approval: true)
        let owner = HostDirectPreparationOwner({ => Result<Unit>.Ok(()) })
        try {
            let approval = match (f.gateway.executeOwnedCheckpointFailure113(f.request.sessionId, f.request.capabilities,
                ToolCall("consumer-call", "consumer_checkpoint", objectValue([])), InvocationContextProjection(),
                Some(f.request.runId), None<ApprovalDecision>, directPreparationOwner: Some(owner))) {
                case OwnedHostDirectToolResult113.Existing(Result.Ok(ToolInvocationResult.NeedsApproval(value))) => value
                case _ => throw IllegalStateException("actual deferred Direct operation did not wait for approval") }
            @Expect(owner.approval().getOrThrow().operationId.value, approval.operationId.value)
            @Expect(f.observer.executed, 0); @Expect(owner.closeAcknowledgement().isError())
            let caller = checkpointDirectCaller11318(owner.decideOwnedCheckpointFailure113(
                approval.operationId.value, ApprovalDecision.Approve))
            try {
                f.expectCanonical(); @Expect(f.model.calls, 0)
                @Expect(caller.withError({ error, fund => fund(65536).value().getOrThrow()
                    expectCheckpointConsumerError11318(error, f.observer.kind, f.observer.lastReceipt) }).isOk())
                @Expect(owner.closeAcknowledgement().isOk())
                @Expect(!caller.isAcknowledged()) // Physical cleanup is not DATA caller ACK.
            } finally { @Expect(caller.acknowledgeAfterConsumption().isOk()) }
        } finally { f.close() }
    }
    @TestCase
    func actualSqlFailureCapturesIndependentSecondaryWithoutRetryOrCanonicalRewrite(): Unit {
        let f = CheckpointConsumerFixture11318("secondary-sql")
        try {
            let caller = checkpointCaller11318(f.core.startOwnedCheckpointFailure113(f.request, { _ => () }))
            try {
                checkpointConsumeCaller11318(f, caller); f.expectCanonical()
                let before = f.database.query("SELECT app_snapshot FROM runs WHERE id=?", [SqlParameter.Text(f.request.runId.value)])[0].required(0)
                let events = f.database.scalarInt("SELECT COUNT(*) FROM app_run_events")
                f.database.execute("CREATE TRIGGER consumer_save_abort11318 BEFORE UPDATE OF app_snapshot ON runs " +
                    "BEGIN SELECT RAISE(ABORT,'real consumer SQL failure雪'); END")
                let storage = caller.retainConsumer().value().getOrThrow()
                let secondary = match (f.runs.saveOwnedFailureOutcome113(storage)) {
                    case OwnedFailureDataOutcome113.Failure(value) => value
                    case _ => throw IllegalStateException("actual SQLite trigger did not produce its paid secondary") }
                try {
                    @Expect(storage.isAcknowledged()); @Expect(!caller.isAcknowledged())
                    @Expect(secondary.withError({ error, _ =>
                        @Expect(error.kind, AgentErrorKind.RecoveryRequired)
                        @Expect(error.code, "persistence.sqlite_run_save")
                        @Expect(error.message.contains("real consumer SQL failure雪"))
                        @Expect(secondary.acknowledgeAfterConsumption().isError()) }).isOk())
                    @Expect(f.database.query("SELECT app_snapshot FROM runs WHERE id=?", [SqlParameter.Text(f.request.runId.value)])[0].required(0), before)
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), events)
                    @Expect(f.core.flushOwnedCheckpointFailures113(f.request.runId, events: Some(f.events)).isOk())
                    @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), events)
                    f.expectCanonical()
                    @Expect(caller.acknowledgeAfterConsumption().isOk())
                    @Expect(secondary.withError({ error, _ => @Expect(error.message.contains("real consumer SQL failure雪")) }).isOk())
                } finally { @Expect(secondary.acknowledgeAfterConsumption().isOk()) }
                f.database.execute("DROP TRIGGER consumer_save_abort11318")
            } finally { let _ = caller.acknowledgeAfterConsumption() }
        } finally { f.close() }
    }
    @TestCase
    func actualDelayedEventAckThenRunnerTakeRetiresCoreWithoutResendingPorts(): Unit {
        let f = CheckpointConsumerFixture11318("delayed-event-take")
        try {
            let runner: AgentRunner = f.core
            let caller = checkpointCaller11318(runner.startOwnedCheckpointFailure113(f.request, { _ => () }))
            try {
                f.expectCanonical()
                @Expect(f.core.flushOwnedCheckpointFailures113(f.request.runId, events: Some(f.events)).isError())
                @Expect(f.events.calls, 1)
                @Expect(!refEq(f.events.held.getOrThrow(), caller))
                let count = f.database.scalarInt("SELECT COUNT(*) FROM app_run_events")
                let saved = f.database.query("SELECT app_snapshot FROM runs WHERE id=?",
                    [SqlParameter.Text(f.request.runId.value)])[0].required(0)
                f.events.retire()
                // This is the public runner poll used by the real caller
                // chain. No explicit flush after the asynchronous ACK.
                match (runner.takeOwnedCheckpointFailure113(f.request.runId)) {
                    case OwnedAgentRunResult113.Existing(_) => ()
                    case _ => throw IllegalStateException("actual ACKed event still left Core's failure debt held") }
                @Expect(f.events.calls, 1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM app_run_events"), count)
                @Expect(f.database.query("SELECT app_snapshot FROM runs WHERE id=?",
                    [SqlParameter.Text(f.request.runId.value)])[0].required(0), saved)
                @Expect(caller.withError({ error, fund => fund(65536).value().getOrThrow()
                    expectCheckpointConsumerError11318(error, f.observer.kind, f.observer.lastReceipt)
                    Result<Unit>.Ok(()) }).isOk())
                let first = reserveNativeDocumentPayload(8388608)
                try {
                    let second = reserveNativeDocumentPayload(4194304)
                    try {
                        var rejected = false
                        try { let unexpected = reserveNativeDocumentPayload(4194304); unexpected.close() }
                        catch (_: LogicalJsonPayloadError) { rejected = true }
                        @Expect(rejected)
                        @Expect(caller.acknowledgeAfterConsumption().isOk())
                        let restored = reserveNativeDocumentPayload(4194304); restored.close()
                    } finally { second.close() }
                } finally { first.close() }
                f.expectCanonical()
            } finally { let _ = caller.acknowledgeAfterConsumption() }
        } finally { f.close() }
    }
    @TestCase
    func actualDirectConsumerPreservesEveryOriginalErrorKindAndCompletedReceipt(): Unit {
        let kinds = [AgentErrorKind.Configuration, AgentErrorKind.Authentication, AgentErrorKind.PermissionDenied,
            AgentErrorKind.InvalidInput, AgentErrorKind.RateLimited, AgentErrorKind.Timeout, AgentErrorKind.Transport,
            AgentErrorKind.Provider, AgentErrorKind.Protocol, AgentErrorKind.Cancelled, AgentErrorKind.BudgetExceeded,
            AgentErrorKind.Conflict, AgentErrorKind.RecoveryRequired, AgentErrorKind.Internal]
        var ordinal: Int64 = 0
        for (kind in kinds) {
            ordinal++
            let f = CheckpointConsumerFixture11318("direct-kind-" + ordinal.toString(), kind: kind)
            try {
                // The original API has a fixed metadata marker of the SAME
                // kind. The actual gateway retains the complete paid error.
                let original = f.gateway.execute(f.request.sessionId, f.request.capabilities,
                    ToolCall("consumer-call", "consumer_checkpoint", objectValue([])), InvocationContextProjection(),
                    Some(f.request.runId), None<ApprovalDecision>)
                @Expect(original.isError()); @Expect(original.error().getOrThrow().kind, kind)
                let caller = checkpointDirectCaller11318(f.gateway.takeOwnedCheckpointFailure113(f.request.runId))
                try {
                    f.expectCanonical()
                    @Expect(caller.withError({ error, fund => fund(65536).value().getOrThrow()
                        expectCheckpointConsumerError11318(error, kind, f.observer.lastReceipt) }).isOk())
                } finally { @Expect(caller.acknowledgeAfterConsumption().isOk()) }
            } finally { f.close() }
        }
    }
}
