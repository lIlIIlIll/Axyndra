package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_extension_runtime.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// DATA-custody controls use the ORIGINAL process bank. There is no fabricated
// prepared invocation, canonical Source, Item, Receipt or database seed here.
class ThrowingExecutionConsumer173a <: PaidExecutionFailureSink173 {
    var calls: Int64 = 0
    public func captureExecutionFailure173(context: ToolInvocationContext, callId: String,
        consumer: OwnedFailureDataConsumer113, dataOnly: Bool): Result<AgentError> {
        calls++
        throw IllegalStateException("actual synchronous failure consumer throws")
    }
}

private func originalEightFieldError173a(): AgentError {
    AgentError(AgentErrorKind.Cancelled, "original.complete.cancelled173a", "cancelled雪🙂\u{0}",
        retryable: true, fallbackAllowed: true, fields: [ErrorField("field雪", "value🙂\u{0}")],
        attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderTransportError,
            diagnostics: AttemptFailureDiagnostics(elapsedMillis: 7, softDeadlineMillis: 11,
                hardDeadlineMillis: 13, enteredCompletionGrace: true, lastProgressAgeMillis: 17,
                providerTerminalObserved: true, openContentBlockCount: 2, toolCallsStarted: 3, toolCallsCompleted: 1))),
        observation: Some(OperationObservation("{\"value\":\"雪🙂\\u0000\"}")))
}
private func expectOriginalEightFieldLoan173a(held: HostCanonicalExecutionFailure173): Unit {
    @Expect(held.withError173({ error, fund =>
        @Expect(error.kind, AgentErrorKind.Cancelled)
        @Expect(error.code, "original.complete.cancelled173a")
        @Expect(error.message, "cancelled雪🙂\u{0}")
        @Expect(error.retryable); @Expect(error.fallbackAllowed)
        @Expect(error.fields.size, 1); @Expect(error.fields[0].name, "field雪")
        @Expect(error.fields[0].value, "value🙂\u{0}")
        let d = error.attemptFailure.getOrThrow().diagnostics
        @Expect(d.elapsedMillis, 7); @Expect(d.softDeadlineMillis, 11); @Expect(d.hardDeadlineMillis, 13)
        @Expect(d.enteredCompletionGrace); @Expect(d.lastProgressAgeMillis, 17)
        @Expect(d.providerTerminalObserved); @Expect(d.openContentBlockCount, 2)
        @Expect(d.toolCallsStarted, 3); @Expect(d.toolCallsCompleted, 1)
        error.observation.getOrThrow().withFrozenEncodedData113({ encoded =>
            @Expect(encoded, "{\"value\":\"雪🙂\\u0000\"}") })
        @Expect(fund(4096).isError())
        @Expect(held.consumer.getOrThrow().acknowledgeAfterConsumption().isError())
    }).isOk())
    @Expect(!held.consumer.getOrThrow().isAcknowledged())
}

private func actualGlobalPressureFrame173a(selected: HostCanonicalProjectionSelection173, throwSink: Bool): Unit {
    // Holder registration is first. All identity/error construction below is
    // paid by the original source owner, not a second pool or test floor.
    let held = selected.reserveExecutionFailure173()
    let context = ToolInvocationContext(RunId("data-only-run173a"), SessionId("data-only-session173a"), CapabilitySet())
    let throwing = ThrowingExecutionConsumer173a()
    if (throwSink) { context.bindPaidExecutionFailureSink173(throwing) }
    let failure = OwnedCanonicalPaidFailure113(originalEightFieldError173a(),
        { bytes => selected.deriveDataPayment173(bytes) })
    let pressure = reserveNativeControlMetadata(4096)
    try {
        let usage = nativeControlMetadataUsage113()
        pressure.ensureRetainedPeak(nativeControlMetadataCapacity113() - usage[1] + 16777216)
        @Expect(nativeControlMetadataUsage113()[1], nativeControlMetadataCapacity113())
        var refused = false
        try { let impossible = selected.reserveExecutionFailure173() }
        catch (_: LogicalJsonPayloadError) { refused = true }
        @Expect(refused)
        // The original old code would refuse its holder reserve NOW, after
        // takeConsumer. The actual new adoption needs no further allocation.
        held.adoptPaidFailure173(failure)
        @Expect(selected.classifyExecutionFailure173(held).isOk())
        @Expect(!held.recoverable)
        let marker = selected.dispatchExecutionFailure173(context, "data-only-call173a", held, false)
        @Expect(marker.kind, AgentErrorKind.Cancelled)
        @Expect(marker.code, "tool.owned_execution_failure_pending")
        @Expect(throwing.calls, if (throwSink) { 1 } else { 0 })
        @Expect(held.hasConsumer173())
        expectOriginalEightFieldLoan173a(held)
        @Expect(nativeControlMetadataUsage113()[1], nativeControlMetadataCapacity113())
        @Expect(held.consumer.getOrThrow().acknowledgeAfterConsumption().isOk())
        @Expect(held.consumer.getOrThrow().isAcknowledged())
    } finally {
        pressure.close()
        // A failed assertion does not leave a test fixture's original DATA
        // consumer unretired after its actual synchronous loan returns.
        if (held.hasConsumer173()) { let _ = held.consumer.getOrThrow().acknowledgeAfterConsumption() }
    }
}

private func originalBankPressureControl173a(throwSink: Bool): Unit {
    let before = nativeControlMetadataUsage113()
    let source = reserveNativeControlMetadata(4096)
    source.ensureRetainedPeak(16777216)
    try {
        let selected = HostCanonicalProjectionSelection173("", "", "", "axyndra:compaction", "actual-data-descriptor",
            1, objectValue([ValueField("name", textValue("checkpoint")), ValueField("provider", textValue("summarize")),
                ValueField("action", textValue("canonical.context.project")), ValueField("capability", textValue("workspace.read")),
                ValueField("effect", textValue("read_only"))]), source)
        try { actualGlobalPressureFrame173a(selected, throwSink) }
        finally { selected.retireAcknowledgedExecutionFailures173() }
        // No holder/borrow/producer helper alias escapes the real inner frame.
    } finally { source.close() }
    @Expect(nativeControlMetadataUsage113()[0], before[0])
    @Expect(nativeControlMetadataUsage113()[1], before[1])
}

@Test
class CanonicalProjectionFailureTransfer173aTests {
    @TestCase
    func fullOriginalBankPressureAndNoSinkRetainOriginalEightFieldConsumer173a(): Unit {
        originalBankPressureControl173a(false)
    }
    @TestCase
    func actualThrowingSinkCannotDropOrAcknowledgePaidErrorUnderPressure173a(): Unit {
        originalBankPressureControl173a(true)
    }
}
