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
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class RetirableSubscriptionProbe113 <: OwnedAgentEventSink &
    OwnedFailureEventSink113 & OwnedFailureEventAdmission113 {
    let ordinaryCalls = AtomicInt64(0)
    let failures = AtomicInt64(0)
    let entered = AtomicBool(false)
    let returnAllowed = AtomicBool(true)
    let throwOrdinary = AtomicBool(false)
    var held: ?OwnedFailureRunPublication113 = None<OwnedFailureRunPublication113>
    func ordinary(event: AgentEvent): Unit {
        ordinaryCalls.fetchAdd(1); entered.store(true)
        let deadline = MonoTime.now() + Duration.second * 5
        while (!returnAllowed.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        if (!returnAllowed.load()) { throw IllegalStateException("subscription test callback gate timed out") }
        if (throwOrdinary.load()) { throw IllegalStateException("actual subscription callback fixture failure") }
    }
    public func emit(value: OwnedAgentEvent): Result<Unit> {
        match (value.withEvent(65536, { _ => Result<Unit>.Ok(()) })) {
            case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
        value.closeAfterEventRetirement()
    }
    public func admitOwnedFailure113(value: OwnedFailureRunPublication113): OwnedFailureEventAdmissionOutcome113 {
        @Expect(held.isNone()); failures.fetchAdd(1)
        match (value.withDiagnostic({ event, fund =>
            match (fund(65536)) { case Result.Err(error) => return Result<Unit>.Err(error); case Result.Ok(_) => () }
            match (event.payload) {
                case AgentEventPayload.Diagnostic(error) =>
                    @Expect(error.kind, AgentErrorKind.Internal)
                    @Expect(error.code, "fixture.subscription_failure雪")
                    @Expect(error.message, "actual committed observer failure\u{0}雪")
                    @Expect(error.retryable); @Expect(error.fallbackAllowed)
                    @Expect(error.fields.size, 2)
                    @Expect(error.fields[0].value, "first"); @Expect(error.fields[1].value, "second")
                    @Expect(error.attemptFailure.getOrThrow().diagnostics.toolCallsCompleted, 1)
                    @Expect(error.observation.getOrThrow().toValue().field("authorizes_effects").getOrThrow().asBool(), false)
                case _ => throw IllegalStateException("actual subscription received no complete Diagnostic") }
            @Expect(value.acknowledgeAfterConsumption().isError())
            Result<Unit>.Ok(())
        })) { case Result.Err(_) => return OwnedFailureEventAdmissionOutcome113.Held; case Result.Ok(_) => () }
        held = Some(value)
        // Registering the actual child accepts custody. Returning here does
        // not consume or acknowledge the queued error.
        OwnedFailureEventAdmissionOutcome113.Accepted
    }
    public func emitOwnedFailure113(value: OwnedFailureRunPublication113): Result<Unit> {
        throw IllegalStateException("the real App must use the typed admission port")
    }
    public func emitOwnedFailureOutcome113(value: OwnedFailureRunPublication113): OwnedFailureDataOutcome113<Unit> {
        match (admitOwnedFailure113(value)) {
            case OwnedFailureEventAdmissionOutcome113.Accepted => OwnedFailureDataOutcome113<Unit>.Value(())
            case _ => throw IllegalStateException("fixture admission did not accept its child") }
    }
    func acknowledgeHeld(): Unit {
        let actual = held.getOrThrow(); held = None<OwnedFailureRunPublication113>
        @Expect(actual.acknowledgeAfterConsumption().isOk())
    }
}

// The installed ToolPipeline and SQLite writer create the actual Source,
// canonical result and Receipt. This observer only produces a paid error
// AFTER observing the completed canonical receipt; no history is seeded.
private class RetirableCanonicalObserver113 <: ToolExecutor &
    PaidPreparedPostCanonicalToolObserver113 & PaidDirectPostCanonicalToolObserver113 {
    private let database: SqliteDatabase
    var calls: Int64 = 0
    var run: ?RunId = None<RunId>
    init(database: SqliteDatabase) { this.database = database }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        run = Some(context.runId)
        let paid = reserveNativeDocumentPayload(65536)
        Result.Ok(ToolResult(prepared.call.callId, textValue("committed-subscription-result"),
            payloadLease: Some(ToolResultPayloadLease({ => paid.close() }))))
    }
    private func observe(result: ToolResult): OwnedFailureDataOutcome113<Unit> {
        calls++
        @Expect(result.isError, false)
        let rows = database.query("SELECT outcome FROM operation_receipts WHERE id=?",
            [SqlParameter.Text(result.receiptId)])
        @Expect(rows.size, 1); @Expect(rows[0].required(0), "completed")
        let producer = reserveNativeDocumentPayload(65536)
        try {
            producer.ensureRetainedPeak(1048576)
            captureOwnedFailureData113<Unit>(AgentError(AgentErrorKind.Internal,
                "fixture.subscription_failure雪", "actual committed observer failure\u{0}雪",
                retryable: true, fallbackAllowed: true,
                fields: [ErrorField("duplicate", "first"), ErrorField("duplicate", "second")],
                attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError,
                    diagnostics: AttemptFailureDiagnostics(toolCallsStarted: 1, toolCallsCompleted: 1))),
                observation: Some(OperationObservation(stringifyUnifiedJson(objectValue([
                    ValueField("actual_receipt", textValue(result.receiptId))]))))),
                { _ => producer.deriveRetainedLease() })
        } finally { producer.close() }
    }
    public func afterPreparedResultPersistedOwned113(context: ToolInvocationContext,
        originalPlan: NormalizedOperationPlan, result: ToolResult): ?OwnedFailureDataOutcome113<Unit> {
        Some(observe(result))
    }
    public func afterDirectResultPersistedOwned113(context: ToolInvocationContext,
        prepared: PreparedToolInvocation, result: ToolResult,
        boundary: DirectPostCanonicalProjectionBoundary): ?OwnedFailureDataOutcome113<Unit> {
        @Expect(refEq(context.budget, boundary.budget)); Some(observe(result))
    }
}

private class RetirableApplicationFixture113 {
    let directory: String
    let product: ProductRuntime
    let session: ApplicationSession
    let paid: LogicalJsonOwnerReservation
    init(label: String, paid: LogicalJsonOwnerReservation) {
        let root = pluginContractTemp("retirable-subscription113-" + label)
        let product = lifecycleTestRequire(openProduct(config: ProductConfig(workspaceRoot: root,
            settingsRoot: root + "/settings", stateRoot: root + "/state", fixture: true,
            asyncEnabled: false, approvalMode: ApprovalMode.Yolo)))
        this.paid = paid; this.directory = root; this.product = product
        this.session = product.applicationSession(sessionId: Some(SessionId("retirable-thread113")))
    }
    func subscribe(probe: RetirableSubscriptionProbe113): ApplicationOwnedSubscription113 {
        let child = paid.deriveRetainedLease(); child.ensureRetainedPeak(65536)
        session.subscribeRetirableOwned113(child, { event => probe.ordinary(event) }, probe, failures: Some(probe))
    }
    func unsubscribe(token: ApplicationOwnedSubscription113): Unit {
        @Expect(!token.isRetired113()); @Expect(session.unsubscribeRetirableOwned113(token))
        // Application's complete removal helper has returned before closing
        // the retained metadata payment; unsubscribe itself was not an ACK.
        @Expect(!token.isRetired113()); @Expect(token.retireAfterUnsubscribe113())
        @Expect(token.isRetired113())
    }
    func close(): Unit { let _ = product.close(); paid.close(); remove(directory, recursive: true) }
}
private func actualRetirableFixture113(label: String): RetirableApplicationFixture113 {
    // Fund before the fixture/controller, probes, callbacks and Future
    // holders exist. Every token below is a distinct derived child.
    let paid = reserveProductControlMetadata113(1048576)
    RetirableApplicationFixture113(label, paid)
}

@Test
class ActualRetirableApplicationSubscription113Tests {
    @TestCase
    func twoRetirableTokensInterleavedWithOriginalObserversKeepExactIndices(): Unit {
        let fixture = actualRetirableFixture113("indices")
        let first = RetirableSubscriptionProbe113(); let second = RetirableSubscriptionProbe113()
        let oldOrdinary = AtomicInt64(0); let oldOwned = RetirableSubscriptionProbe113()
        let a = fixture.subscribe(first)
        fixture.session.subscribe({ _ => oldOrdinary.fetchAdd(1); () })
        fixture.session.subscribeOwned({ event => oldOwned.ordinary(event) }, oldOwned)
        let b = fixture.subscribe(second)
        try {
            @Expect(fixture.session.submit("A real fixture model turn.").isOk())
            @Expect(first.ordinaryCalls.load() > 0); @Expect(second.ordinaryCalls.load() > 0)
            let beforeFirst = first.ordinaryCalls.load(); let beforeSecond = second.ordinaryCalls.load()
            let beforeOld = oldOrdinary.load(); let beforeOwned = oldOwned.ordinaryCalls.load()
            fixture.unsubscribe(a)
            @Expect(fixture.session.submit("A second real fixture model turn.").isOk())
            @Expect(first.ordinaryCalls.load(), beforeFirst)
            @Expect(second.ordinaryCalls.load() > beforeSecond)
            @Expect(oldOrdinary.load() > beforeOld); @Expect(oldOwned.ordinaryCalls.load() > beforeOwned)
            fixture.unsubscribe(b)
            @Expect(fixture.session.unsubscribeRetirableOwned113(a)); @Expect(a.retireAfterUnsubscribe113())
        } finally { fixture.close() }
    }

    @TestCase
    func realCanonicalFailureChildBlocksUnsubscribeUntilItsActualAcknowledgement(): Unit {
        let fixture = actualRetirableFixture113("actual-failure")
        let database = SqliteDatabase(fixture.directory + "/state/state.db")
        let observer = RetirableCanonicalObserver113(database)
        let probe = RetirableSubscriptionProbe113(); let token = fixture.subscribe(probe)
        try {
            @Expect(fixture.product.registerTool(ToolDescriptor(ModelToolDefinition("retirable_checkpoint113",
                "Actual completed observer", objectValue([ValueField("type", textValue("object")),
                ValueField("properties", objectValue([]))])), Capability(CapabilityKind.WorkspaceRead),
                implementationVersion: "retirable113", implementationFingerprint: "retirable113"), observer).isOk())
            fixture.product.fixtureProbe.getOrThrow().enqueueToolCallReply("retirable-call113",
                "retirable_checkpoint113", objectValue([]))
            let marker = fixture.session.submit("Run the actual registered observer once.").error().getOrThrow()
            @Expect(fixture.session.hasOwnedCheckpointFailure113(marker))
            @Expect(observer.calls, 1); @Expect(probe.failures.load(), 1)
            @Expect(!probe.held.getOrThrow().isAcknowledged())
            @Expect(!fixture.session.unsubscribeRetirableOwned113(token)); @Expect(!token.isRetired113())
            @Expect(!token.retireAfterUnsubscribe113())
            let caller = match (fixture.session.takeOwnedCheckpointFailure113(marker).getOrThrow()) {
                case OwnedAgentRunResult113.Failed(value) => value
                case _ => throw IllegalStateException("actual App did not transfer its caller publication") }
            @Expect(!refEq(caller, probe.held.getOrThrow()))
            probe.acknowledgeHeld(); fixture.session.collectOwnedCheckpointFailure113()
            fixture.unsubscribe(token)
            @Expect(!caller.isAcknowledged()); @Expect(caller.acknowledgeAfterConsumption().isOk())
            fixture.session.collectOwnedCheckpointFailure113()
            let _ = fixture.session.takeOwnedCheckpointFailure113(observer.run.getOrThrow())
            fixture.session.collectOwnedCheckpointFailure113()
            @Expect(observer.calls, 1)
        } finally { database.close(); fixture.close() }
    }

    @TestCase
    func activeOriginalDispatchCannotRetirePaidTokenBeforeFutureActuallyReturns(): Unit {
        let fixture = actualRetirableFixture113("active-dispatch")
        let probe = RetirableSubscriptionProbe113(); probe.returnAllowed.store(false)
        let token = fixture.subscribe(probe)
        let future = spawn { fixture.session.submit("Block inside the actual original App dispatch.") }
        try {
            let deadline = MonoTime.now() + Duration.second * 5
            while (!probe.entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(probe.entered.load()); @Expect(future.tryGet().isNone())
            @Expect(!fixture.session.unsubscribeRetirableOwned113(token))
            @Expect(!token.retireAfterUnsubscribe113()); @Expect(!token.isRetired113())
            probe.returnAllowed.store(true)
            @Expect(future.get().isOk())
            fixture.unsubscribe(token)
        } finally { probe.returnAllowed.store(true); let _ = future.get(); fixture.close() }
    }

    @TestCase
    func throwingActualCallbackKeepsReachablePaymentUntilWholeHelperReturnAndRemoval(): Unit {
        let fixture = actualRetirableFixture113("throwing-callback")
        let probe = RetirableSubscriptionProbe113(); probe.throwOrdinary.store(true)
        let token = fixture.subscribe(probe)
        try {
            try { let _ = fixture.session.submit("Reach the real callback which throws.") }
            catch (_: Exception) { () }
            @Expect(probe.entered.load()); @Expect(!token.isRetired113())
            @Expect(!token.retireAfterUnsubscribe113())
            fixture.unsubscribe(token)
        } finally { fixture.close() }
    }

    @TestCase
    func metadataSharesUseOriginalSumAndRetireOnlyAfterBothTokensRemove(): Unit {
        let baseline = productControlMetadataUsage113()
        let fixture = actualRetirableFixture113("same-bank")
        let first = RetirableSubscriptionProbe113(); let second = RetirableSubscriptionProbe113()
        let a = fixture.subscribe(first); let b = fixture.subscribe(second)
        try {
            let original = fixture.paid.retainedCustodyUsage113()
            let physical = productControlMetadataUsage113()
            @Expect(original[0], 8 * 1048576 + 1024 + 2 * (65536 + 1024))
            @Expect(original[2], 3)
            @Expect(!a.retireAfterUnsubscribe113()); @Expect(!b.retireAfterUnsubscribe113())
            expectActualUsageFields163_3(fixture.paid.retainedCustodyUsage113(), original)
            fixture.unsubscribe(a)
            let one = fixture.paid.retainedCustodyUsage113()
            @Expect(one[0], original[0] - 65536 - 1024); @Expect(one[2], 2)
            @Expect(!b.isRetired113())
            fixture.unsubscribe(b)
            @Expect(fixture.paid.retainedCustodyUsage113()[0], one[0] - 65536 - 1024)
            @Expect(fixture.paid.retainedCustodyUsage113()[2], 1)
            // Actual lease SUM drops. The original physical floor/high-water
            // remains until the last real parent retires; no floor is cut.
            expectActualUsageFields163_2(productControlMetadataUsage113(), physical)
        } finally { fixture.close() }
        expectActualUsageFields163_2(productControlMetadataUsage113(), baseline)
    }
}

private func expectActualUsageFields163_2(actual: (Int64, Int64), expected: (Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
}

private func expectActualUsageFields163_3(actual: (Int64, Int64, Int64), expected: (Int64, Int64, Int64)): Unit {
    @Expect(actual[0], expected[0])
    @Expect(actual[1], expected[1])
    @Expect(actual[2], expected[2])
}
