package agent_product

import agent_core.OwnedAgentRunResult113
import agent_domain
import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class MaintenanceCallerCapture173c {
    var consumer: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
    var calls: Int64 = 0
    func offer(value: OwnedAgentRunResult113): OwnedFailureDataConsumer113 {
        calls++
        let actual = match (value) {
            case OwnedAgentRunResult113.Pending(consumer) => consumer
            case _ => throw IllegalStateException("maintenance cannot fabricate a Core Run") }
        match (consumer) { case Some(old) => @Expect(refEq(old, actual)); case None => consumer = Some(actual) }
        actual
    }
}
private func originalMaintenanceEightField173c(): AgentError {
    AgentError(AgentErrorKind.Cancelled, "maintenance.original.complete173c", "original雪🙂\u{0}",
        retryable: true, fallbackAllowed: true, fields: [ErrorField("field雪", "value🙂\u{0}")],
        attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderTransportError,
            diagnostics: AttemptFailureDiagnostics(elapsedMillis: 7, softDeadlineMillis: 11,
                hardDeadlineMillis: 13, enteredCompletionGrace: true, lastProgressAgeMillis: 17,
                providerTerminalObserved: true, openContentBlockCount: 2, toolCallsStarted: 3, toolCallsCompleted: 1))),
        observation: Some(OperationObservation("{\"value\":\"雪🙂\\u0000\"}")))
}
// The pool's own fixed aggregate, so the pressure assertions track the
// configured capacity instead of duplicating one literal number.
private func nativeControlMetadataCapacity173c(): Int64 { nativeControlMetadataCapacityReader173c() }

private func expectMaintenanceEightLoan173c(actual: OwnedFailureDataConsumer113, pressure: Bool): Unit {
    @Expect(actual.withError({ error, fund =>
        @Expect(error.kind, AgentErrorKind.Cancelled); @Expect(error.code, "maintenance.original.complete173c")
        @Expect(error.message, "original雪🙂\u{0}"); @Expect(error.retryable); @Expect(error.fallbackAllowed)
        @Expect(error.fields.size, 1); @Expect(error.fields[0].name, "field雪"); @Expect(error.fields[0].value, "value🙂\u{0}")
        @Expect(error.attemptFailure.getOrThrow().kind, AttemptFailureKind.ProviderTransportError)
        let d = error.attemptFailure.getOrThrow().diagnostics
        @Expect(d.elapsedMillis, 7); @Expect(d.softDeadlineMillis, 11); @Expect(d.hardDeadlineMillis, 13)
        @Expect(d.enteredCompletionGrace); @Expect(d.lastProgressAgeMillis, 17); @Expect(d.providerTerminalObserved)
        @Expect(d.openContentBlockCount, 2); @Expect(d.toolCallsStarted, 3); @Expect(d.toolCallsCompleted, 1)
        error.observation.getOrThrow().withFrozenEncodedData113({ bytes =>
            @Expect(bytes, "{\"value\":\"雪🙂\\u0000\"}") })
        if (pressure) { @Expect(fund(nativeControlMetadataCapacity173c()).isError()) }
        @Expect(actual.acknowledgeAfterConsumption().isError())
    }).isOk())
    @Expect(!actual.isAcknowledged())
}
// Actual installed Native query first; only the following complete paid
// exception is a deliberate DATA custody fault injection. It is not a fake
// Native operation failure, canonical Receipt, SQL row or Run completion.
private func actualNativeMaintenanceFailure173c(f: CompactionPolicyFixture,
    pressure!: ?LogicalJsonOwnerReservation = None<LogicalJsonOwnerReservation>): AgentError {
    let source = agent_domain.CancellationSource()
    try {
        let result = withNativeCheckpointRetention173<Unit>(f.product.vnext.javascriptPlugins,
            f.root + "/settings", f.session, source.token,
            { value => f.product.retainOwnedMaintenanceProducer173(value) },
            { => f.product.collectOwnedMaintenanceFailures173() }, { query, owner =>
                let proposal = query.query("checkpoint_retention_error173", [])
                try { @Expect(httpIntentText(proposal.field("error").getOrThrow(), "code"),
                    "session.compaction_checkpoint_active"); query.check() }
                finally { query.release(proposal) }
                // The original bank pays this source error BEFORE construction.
                owner.ensureRetainedPeak(2097152)
                let failure = OwnedCanonicalPaidFailure113(originalMaintenanceEightField173c(), { bytes =>
                    let child = owner.deriveRetainedLease()
                    try { child.ensureRetainedPeak(bytes); child }
                    catch (failure: Exception) { child.close(); throw failure } })
                match (pressure) {
                    case Some(actual) =>
                        let current = nativeControlMetadataUsage113()
                        actual.ensureRetainedPeak(nativeControlMetadataCapacity173c() - current[1] + 16777216)
                        @Expect(nativeControlMetadataUsage113()[1], nativeControlMetadataCapacity173c())
                    case None => () }
                // No holder allocation/payment is permitted after this move.
                throw failure
            })
        @Expect(result.isError()); result.error().getOrThrow()
    } finally { source.close() }
}
private func settleMaintenanceCaller173c(session: ApplicationSession, marker: AgentError,
    capture: MaintenanceCallerCapture173c): Unit {
    if (session.hasOwnedCheckpointFailure113(marker)) {
        let _ = session.admitOwnedCheckpointFailure113(marker, { value => let _ = capture.offer(value); true }) }
    match (capture.consumer) { case Some(actual) => let _ = actual.acknowledgeAfterConsumption(); case None => () }
    capture.consumer = None<OwnedFailureDataConsumer113>
    session.collectOwnedCheckpointFailure113()
}
@Test
class InstalledMaintenanceFailureConsumer173cTests {
    @TestCase
    func actualAppRejectThrowAndPressurePreserveOneCompleteConsumerWithoutProducerReplay173c(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        let session = f.product.applicationSession(sessionId: Some(f.session))
        let capture = MaintenanceCallerCapture173c()
        let pressure = reserveNativeControlMetadata(4096)
        let marker = actualNativeMaintenanceFailure173c(f, pressure: Some(pressure))
        try {
            @Expect(marker.kind, AgentErrorKind.Cancelled); @Expect(session.hasOwnedCheckpointFailure113(marker))
            let foreignSession = f.product.applicationSession(sessionId: Some(SessionId("other-maintenance173c")))
            @Expect(!foreignSession.hasOwnedCheckpointFailure113(marker))
            @Expect(!session.hasOwnedCheckpointFailure113(AgentError(marker.kind, marker.code, marker.message)))
            @Expect(nativeControlMetadataUsage113()[1], nativeControlMetadataCapacity173c())
            @Expect(!session.pollAndAdmitOwnedCheckpointFailure113(marker, { value =>
                expectMaintenanceEightLoan173c(capture.offer(value), true); false }))
            // A share may fit the already-paid root's original high-water;
            // otherwise it remains pending. Neither branch gets a new bank.
            let pressureOffers = capture.calls
            @Expect(pressureOffers <= 1); @Expect(session.hasOwnedCheckpointFailure113(marker))
            pressure.close()
            @Expect(!session.admitOwnedCheckpointFailure113(marker, { value =>
                expectMaintenanceEightLoan173c(capture.offer(value), false); false }))
            var thrown = false
            try { let _ = session.admitOwnedCheckpointFailure113(marker, { value =>
                expectMaintenanceEightLoan173c(capture.offer(value), false)
                throw IllegalStateException("real caller refuses") }) }
            catch (_: IllegalStateException) { thrown = true }
            @Expect(thrown); @Expect(capture.calls, pressureOffers + 2)
            @Expect(session.pollAndAdmitOwnedCheckpointFailure113(marker, { value =>
                expectMaintenanceEightLoan173c(capture.offer(value), false); true }))
            @Expect(capture.calls, pressureOffers + 3); @Expect(!capture.consumer.getOrThrow().isAcknowledged())
            let beforeAck = nativeControlMetadataUsage113()[1]
            session.collectOwnedCheckpointFailure113()
            @Expect(nativeControlMetadataUsage113()[1], beforeAck)
            @Expect(capture.consumer.getOrThrow().acknowledgeAfterConsumption().isOk())
            capture.consumer = None<OwnedFailureDataConsumer113>
            session.collectOwnedCheckpointFailure113()
            @Expect(nativeControlMetadataUsage113()[1] < beforeAck)
            let settled = nativeControlMetadataUsage113()[1]
            session.collectOwnedCheckpointFailure113(); @Expect(nativeControlMetadataUsage113()[1], settled)
            @Expect(!session.hasOwnedCheckpointFailure113(marker))
            f.noExecutionOrCheckpoint()
        } finally { pressure.close(); settleMaintenanceCaller173c(session, marker, capture); f.close() }
    }
    @TestCase
    func actualCallerBorrowAndIndependentOldSiblingPreventFullDataRefund173c(): Unit {
        let f = CompactionPolicyFixture(hybrid: false, seedDefaultHistory: false)
        let session = f.product.applicationSession(sessionId: Some(f.session))
        let capture = MaintenanceCallerCapture173c()
        let marker = actualNativeMaintenanceFailure173c(f)
        var sibling: ?OwnedFailureDataConsumer113 = None<OwnedFailureDataConsumer113>
        try {
            @Expect(session.admitOwnedCheckpointFailure113(marker, { value => let _ = capture.offer(value); true }))
            let caller = capture.consumer.getOrThrow()
            sibling = Some(lifecycleTestRequire(caller.retainConsumer()))
            @Expect(caller.withError({ error, _ =>
                @Expect(error.code, "maintenance.original.complete173c")
                @Expect(caller.acknowledgeAfterConsumption().isError())
                session.collectOwnedCheckpointFailure113()
            }).isOk())
            @Expect(!caller.isAcknowledged())
            @Expect(caller.acknowledgeAfterConsumption().isOk())
            capture.consumer = None<OwnedFailureDataConsumer113>
            session.collectOwnedCheckpointFailure113()
            let stillPaid = nativeControlMetadataUsage113()[1]
            expectMaintenanceEightLoan173c(sibling.getOrThrow(), false)
            @Expect(sibling.getOrThrow().acknowledgeAfterConsumption().isOk())
            sibling = None<OwnedFailureDataConsumer113>
            @Expect(nativeControlMetadataUsage113()[1] < stillPaid)
            f.noExecutionOrCheckpoint()
        } finally {
            match (sibling) { case Some(actual) => let _ = actual.acknowledgeAfterConsumption(); case None => () }
            sibling = None<OwnedFailureDataConsumer113>
            settleMaintenanceCaller173c(session, marker, capture); f.close()
        }
    }
}
