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
import std.collection.*
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
private func applicationConsumerError11318(kind: AgentErrorKind, result: ToolResult): AgentError {
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
private func expectApplicationConsumerError11318(error: AgentError, kind: AgentErrorKind,
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
    @Expect(observation.field("content").getOrThrow().field("actual_call").getOrThrow().text, "application-owned-call11318")
}
private class ApplicationConsumerObserver11318 <: ToolExecutor & PreparedPostCanonicalToolObserver &
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
        @Expect(plan.toolName, "application_owned_checkpoint11318")
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
            captureOwnedFailureData113<Unit>(applicationConsumerError11318(kind, result),
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

private class ApplicationConsumerEvent11318 <: OwnedAgentEventSink & OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    private let observer: ApplicationConsumerObserver11318
    var held: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    var calls: Int64 = 0
    init(observer: ApplicationConsumerObserver11318) { this.observer = observer }
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
                    expectApplicationConsumerError11318(error, observer.kind, observer.lastReceipt)
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
private class ApplicationUnknownConsumer11318 <: OwnedAgentEventSink & OwnedFailureEventSink113 {
    var calls: Int64 = 0
    public func emit(event: OwnedAgentEvent): Result<Unit> { event.closeAfterEventRetirement() }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        calls++; Result<Unit>.Ok(())
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        calls++; OwnedFailureDataOutcome113<Unit>.Value(())
    }
}
private class ApplicationConsumerCapture11318 {
    var calls: Int64 = 0
    var value: ?OwnedAgentRunResult113 = None<OwnedAgentRunResult113>
}
private class ActualApplicationConsumerFixture11318 {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let session: ApplicationSession
    let observer: ApplicationConsumerObserver11318
    let first: ApplicationConsumerEvent11318
    let second: ApplicationConsumerEvent11318
    init(label: String, approval!: Bool = false) {
        let directory = pluginContractTemp("owned-application-consumer11318-" + label)
        let installed = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: directory,
            settingsRoot: directory + "/settings", stateRoot: directory + "/state", fixture: true,
            asyncEnabled: false, approvalMode: if (approval) { ApprovalMode.AlwaysAsk } else { ApprovalMode.Yolo })))
        let db = SqliteDatabase(directory + "/state/state.db")
        let executor = ApplicationConsumerObserver11318(db, AgentErrorKind.Internal)
        @Expect(installed.registerTool(ToolDescriptor(ModelToolDefinition("application_owned_checkpoint11318",
            "Actual paid Application failure observer", objectValue([
                ValueField("type", textValue("object")), ValueField("properties", objectValue([]))])),
            Capability(CapabilityKind.WorkspaceRead), sideEffecting: approval,
            implementationVersion: "application11318", implementationFingerprint: "application11318"), executor).isOk())
        let app = installed.applicationSession(sessionId: Some(SessionId("application-owned-thread11318")))
        let a = ApplicationConsumerEvent11318(executor); let b = ApplicationConsumerEvent11318(executor)
        app.subscribeOwned({ _ => () }, a, failures: Some(a))
        app.subscribeOwned({ _ => () }, b, failures: Some(b))
        this.root = directory; this.product = installed; this.database = db; this.session = app
        this.observer = executor; this.first = a; this.second = b
    }
    func propose(): Unit {
        product.fixtureProbe.getOrThrow().enqueueToolCallReply("application-owned-call11318",
            "application_owned_checkpoint11318", objectValue([]))
    }
    func start(): AgentError {
        propose(); session.submit("Execute the real installed checkpoint observer once.").error().getOrThrow()
    }
    func caller(marker: AgentError): OwnedFailureRunPublication113 {
        match (session.takeOwnedCheckpointFailure113(marker).getOrThrow()) {
            case OwnedAgentRunResult113.Failed(value) => value
            case _ => throw IllegalStateException("real Application did not move its paid caller") }
    }
    func expectCaller(value: OwnedFailureRunPublication113): Unit {
        @Expect(value.withError({ error, fund =>
            fund(65536).value().getOrThrow()
            expectApplicationConsumerError11318(error, observer.kind, observer.lastReceipt)
            @Expect(value.acknowledgeAfterConsumption().isError())
            Result<Unit>.Ok(())
        }).isOk())
    }
    func expectCanonical(count!: Int64 = 1): Unit {
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operations WHERE state='committed'"), count)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"), count)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_result'"), count)
        @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
        @Expect(observer.executed, count); @Expect(observer.ownedCalls, count); @Expect(observer.oldCalls, 0)
    }
    func finish(value: OwnedFailureRunPublication113): Unit {
        expectCaller(value)
        if (first.held.isSome()) { first.retire() }
        if (second.held.isSome()) { second.retire() }
        @Expect(value.acknowledgeAfterConsumption().isOk())
        session.collectOwnedCheckpointFailure113()
        let _ = session.takeOwnedCheckpointFailure113(observer.actualRun.getOrThrow())
        session.collectOwnedCheckpointFailure113()
    }
    func close(): Unit { observer.allowReturn.store(true); let _ = product.close(); database.close(); remove(root, recursive: true) }
}

@Test
class ActualApplicationOwnedConsumer11318Tests {
    @TestCase
    func actualSessionClientCoreCanonicalCallerAndTwoDelayedSubscribersRetireIndependently(): Unit {
        let f = ActualApplicationConsumerFixture11318("asynchronous")
        try {
            let marker = f.start(); @Expect(marker.kind, AgentErrorKind.Internal)
            @Expect(f.session.hasOwnedCheckpointFailure113(marker))
            let caller = f.caller(marker); f.expectCaller(caller); f.expectCanonical()
            @Expect(f.first.calls, 1); @Expect(f.second.calls, 1)
            @Expect(!refEq(f.first.held.getOrThrow(), f.second.held.getOrThrow()))
            @Expect(!refEq(f.first.held.getOrThrow(), caller))
            @Expect(!f.session.hasOwnedCheckpointFailure113(marker))
            f.first.retire(); f.session.collectOwnedCheckpointFailure113()
            @Expect(!caller.isAcknowledged()); @Expect(!f.second.held.getOrThrow().isAcknowledged())
            @Expect(match (f.session.takeOwnedCheckpointFailure113(f.observer.actualRun.getOrThrow())) {
                case OwnedAgentRunResult113.Held => true; case _ => false })
            f.finish(caller)
            @Expect(f.first.calls, 1); @Expect(f.second.calls, 1); f.expectCanonical()
            @Expect(f.session.takeOwnedCheckpointFailure113(marker).isNone())
        } finally { f.close() }
    }
    @TestCase
    func exactMarkerTransactionalRejectAndThrowPreservePaidSlotUntilActualAdmission(): Unit {
        let f = ActualApplicationConsumerFixture11318("transactional")
        try {
            let marker = f.start(); let offered = ApplicationConsumerCapture11318()
            let other = f.product.applicationSession(sessionId: Some(SessionId("other-application11318")))
            @Expect(!other.hasOwnedCheckpointFailure113(marker))
            @Expect(other.takeOwnedCheckpointFailure113(marker).isNone())
            @Expect(!f.session.admitOwnedCheckpointFailure113(marker, { value =>
                offered.calls++
                match (value) { case OwnedAgentRunResult113.Failed(actual) => f.expectCaller(actual)
                    case _ => throw IllegalStateException("actual transactional offer lost its caller") }
                @Expect(f.session.hasOwnedCheckpointFailure113(marker))
                @Expect(f.session.takeOwnedCheckpointFailure113(marker).isNone())
                false }))
            @Expect(f.session.hasOwnedCheckpointFailure113(marker)); @Expect(offered.calls, 1)
            var threw = false
            try { let _ = f.session.admitOwnedCheckpointFailure113(marker,
                { _ => throw IllegalStateException("unaccepted fixed fixture metadata") }) }
            catch (_: IllegalStateException) { threw = true }
            @Expect(threw); @Expect(f.session.hasOwnedCheckpointFailure113(marker))
            @Expect(f.session.admitOwnedCheckpointFailure113(marker, { value => offered.value = Some(value); true }))
            @Expect(!f.session.admitOwnedCheckpointFailure113(marker, { _ => offered.calls++; true }))
            @Expect(offered.calls, 1)
            let caller = match (offered.value.getOrThrow()) {
                case OwnedAgentRunResult113.Failed(actual) => actual
                case _ => throw IllegalStateException("registered caller was not the real publication") }
            offered.value = None<OwnedAgentRunResult113>; f.finish(caller); f.expectCanonical()
        } finally { f.close() }
    }
    @TestCase
    func originalNativeCapacityPressureCallsNoClientAndStaticMarkerCannotTakeLaterGeneration(): Unit {
        let f = ActualApplicationConsumerFixture11318("pressure")
        let paid = ArrayList<LogicalJsonOwnerReservation>()
        try {
            try { while (true) { paid.add(reserveNativeDocumentPayload(65536)) } }
            catch (_: LogicalJsonPayloadError) { () }
            let before = f.product.fixtureProbe.getOrThrow().observedCallCount11318()
            let rejected = f.start()
            @Expect(f.product.fixtureProbe.getOrThrow().observedCallCount11318(), before)
            @Expect(f.observer.executed, 0)
            @Expect(!f.session.hasOwnedCheckpointFailure113(rejected))
            @Expect(f.session.takeOwnedCheckpointFailure113(rejected).isNone())
            for (owner in paid) { owner.close() }; paid.clear()
            // The earlier proposed model reply has not run. The real client
            // now consumes that same queued reply once, with a new paid key.
            let actual = f.session.submit("Consume the actual queued call after capacity returns.").error().getOrThrow()
            @Expect(!refEq(rejected, actual)); @Expect(actual.kind, AgentErrorKind.Internal)
            @Expect(f.session.takeOwnedCheckpointFailure113(rejected).isNone())
            @Expect(f.product.fixtureProbe.getOrThrow().observedCallCount11318(), before + 1)
            f.finish(f.caller(actual)); f.expectCanonical()
        } finally { for (owner in paid) { owner.close() }; f.close() }
    }
    @TestCase
    func nonAdmissionSubscriberIsHeldWithoutCallingOrAcknowledgingItsResultCallback(): Unit {
        let f = ActualApplicationConsumerFixture11318("unknown")
        try {
            let caller = f.caller(f.start())
            let unknown = ApplicationUnknownConsumer11318()
            let other = f.product.applicationSession(sessionId: Some(SessionId("unknown-admission11318")))
            other.subscribeOwned({ _ => () }, unknown, failures: Some(unknown))
            let actual = caller.retainConsumer().value().getOrThrow()
            let input = (other.ownedEventSink() as OwnedFailureEventAdmission113).getOrThrow()
            @Expect(match (input.admitOwnedFailure113(actual)) {
                case OwnedFailureEventAdmissionOutcome113.Held => true; case _ => false })
            @Expect(unknown.calls, 0); @Expect(!actual.isAcknowledged())
            // Held retained no observer alias: the caller still owns this
            // actual derived share and consumes it after the returned frame.
            f.expectCaller(actual); @Expect(actual.acknowledgeAfterConsumption().isOk())
            @Expect(!caller.isAcknowledged()); f.finish(caller); f.expectCanonical()
        } finally { f.close() }
    }
    @TestCase
    func actualSessionApprovalThenDecidePreservesOriginalCanonicalReceiptAndPaidFailure(): Unit {
        let f = ActualApplicationConsumerFixture11318("decide", approval: true)
        try {
            f.propose(); let waiting = f.session.submit("Ask before the real installed effect.").value().getOrThrow()
            let approval = waiting.approval.getOrThrow()
            @Expect(f.observer.executed, 0); @Expect(f.observer.ownedCalls, 0)
            let marker = f.session.decide(approval.operationId.value, ApprovalDecision.Approve).error().getOrThrow()
            @Expect(marker.kind, AgentErrorKind.Internal)
            @Expect(f.session.hasOwnedCheckpointFailure113(marker))
            f.finish(f.caller(marker)); f.expectCanonical()
            @Expect(f.product.fixtureProbe.getOrThrow().observedCallCount11318(), 1)
        } finally { f.close() }
    }
    @TestCase
    func simultaneousActualSessionCallCannotOverwriteTheInFlightPaidGeneration(): Unit {
        let f = ActualApplicationConsumerFixture11318("concurrent")
        f.propose(); f.observer.allowReturn.store(false)
        let pending = spawn { f.session.submit("Enter the actual client and wait in the real tool.") }
        try {
            let deadline = MonoTime.now() + Duration.second * 5
            while (!f.observer.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(f.observer.entered.load())
            let other = f.session.submit("Overlap this invocation without a second real client entry.").error().getOrThrow()
            @Expect(!f.session.hasOwnedCheckpointFailure113(other))
            @Expect(f.session.takeOwnedCheckpointFailure113(other).isNone())
            @Expect(f.product.fixtureProbe.getOrThrow().observedCallCount11318(), 1)
            f.observer.allowReturn.store(true)
            let actual = pending.get().error().getOrThrow()
            @Expect(!refEq(actual, other)); @Expect(actual.kind, AgentErrorKind.Internal)
            @Expect(f.session.takeOwnedCheckpointFailure113(other).isNone())
            f.finish(f.caller(actual)); f.expectCanonical()
        } finally { f.observer.allowReturn.store(true); let _ = pending.get(); f.close() }
    }
}


// The poll entry only offers the already installed actual caller. These
// controls use the existing real Session/Client/Core/SQLite fixture above;
// they never install a synthetic Held slot or fabricate an execution result.
@Test
class ActualApplicationTuiFailurePoll113Tests {
    @TestCase
    func pollRejectThrowAndAcceptKeepExactOriginalCallerAndCanonicalExecutionOnce113(): Unit {
        let f = ActualApplicationConsumerFixture11318("tui-poll-admission")
        try {
            let marker = f.start()
            let capture = ApplicationConsumerCapture11318()
            @Expect(!f.session.pollAndAdmitOwnedCheckpointFailure113(marker, { actual =>
                capture.calls++
                match (actual) {
                    case OwnedAgentRunResult113.Failed(publication) => f.expectCaller(publication)
                    case _ => throw IllegalStateException("poll lost the actual original caller") }
                false }))
            @Expect(capture.calls, 1)
            @Expect(f.session.hasOwnedCheckpointFailure113(marker))
            @Expect(f.first.calls, 1); @Expect(f.second.calls, 1); f.expectCanonical()
            var threw = false
            try { let _ = f.session.pollAndAdmitOwnedCheckpointFailure113(marker,
                { _ => throw IllegalStateException("actual TUI registration has not accepted its caller") }) }
            catch (_: IllegalStateException) { threw = true }
            @Expect(threw); @Expect(f.session.hasOwnedCheckpointFailure113(marker)); f.expectCanonical()
            @Expect(f.session.pollAndAdmitOwnedCheckpointFailure113(marker, { actual =>
                capture.calls++; capture.value = Some(actual); true }))
            @Expect(capture.calls, 2)
            @Expect(!f.session.hasOwnedCheckpointFailure113(marker))
            @Expect(!f.session.pollAndAdmitOwnedCheckpointFailure113(marker, { _ => capture.calls++; true }))
            @Expect(capture.calls, 2); f.expectCanonical()
            let caller = match (capture.value.getOrThrow()) {
                case OwnedAgentRunResult113.Failed(actual) => actual
                case _ => throw IllegalStateException("TUI registration did not receive the original publication") }
            capture.value = None<OwnedAgentRunResult113>
            @Expect(!caller.isAcknowledged()); f.finish(caller); f.expectCanonical()
        } finally { f.close() }
    }
    @TestCase
    func pollCannotTakeInFlightOrForeignMarkerAndNeverStartsAnotherActualClient113(): Unit {
        let f = ActualApplicationConsumerFixture11318("tui-poll-inflight")
        f.propose(); f.observer.allowReturn.store(false)
        let pending = spawn { f.session.submit("Wait in the real Tool before the paid caller exists.") }
        try {
            let deadline = MonoTime.now() + Duration.second * 5
            while (!f.observer.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(f.observer.entered.load())
            let overlap = f.session.submit("A simultaneous original invocation is still reserved.").error().getOrThrow()
            let capture = ApplicationConsumerCapture11318()
            @Expect(!f.session.pollAndAdmitOwnedCheckpointFailure113(overlap, { _ => capture.calls++; true }))
            @Expect(capture.calls, 0); @Expect(f.observer.executed, 1); @Expect(f.observer.ownedCalls, 0)
            @Expect(f.product.fixtureProbe.getOrThrow().observedCallCount11318(), 1)
            f.observer.allowReturn.store(true)
            let marker = pending.get().error().getOrThrow()
            @Expect(!refEq(marker, overlap)); f.expectCanonical()
            @Expect(!f.session.pollAndAdmitOwnedCheckpointFailure113(overlap, { _ => capture.calls++; true }))
            let foreignSession = f.product.applicationSession(sessionId: Some(SessionId("foreign-tui-poll113")))
            @Expect(!foreignSession.pollAndAdmitOwnedCheckpointFailure113(marker, { _ => capture.calls++; true }))
            @Expect(capture.calls, 0)
            @Expect(f.session.hasOwnedCheckpointFailure113(marker))
            f.finish(f.caller(marker)); f.expectCanonical()
        } finally { f.observer.allowReturn.store(true); let _ = pending.get(); f.close() }
    }
}
