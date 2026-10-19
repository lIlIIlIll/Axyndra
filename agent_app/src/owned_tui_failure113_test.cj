package agent_app

import agent_core.OwnedAgentRunResult113
import agent_domain.*
import agent_runtime.*
import agent_tui.*
import std.collection.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private func tuiFullErrorFixture113(secondary!: Bool = false): AgentError {
    AgentError(if (secondary) { AgentErrorKind.Transport } else { AgentErrorKind.Internal },
        if (secondary) { "secondary雪\u{0}" } else { "checkpoint雪\u{0}" },
        "complete message🙂\u{0}\n", retryable: true, fallbackAllowed: true,
        fields: [ErrorField("duplicate", "first"), ErrorField("duplicate", "second雪\u{0}")],
        attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderProtocolError,
            diagnostics: AttemptFailureDiagnostics(elapsedMillis: 1, softDeadlineMillis: 2,
                hardDeadlineMillis: 3, enteredCompletionGrace: true,
                lastProgressKind: AttemptProgressKind.ToolArgumentProgress, lastProgressAgeMillis: 4,
                providerTerminalObserved: true, openContentBlockCount: 5,
                toolCallsStarted: 6, toolCallsCompleted: 7))),
        observation: Some(OperationObservation("{\"original\":\"雪\\u0000🙂\"}")))
}
private func tuiFailureConsumerFrame113(pool: LogicalJsonOwnerBudget,
    producer: LogicalJsonOwnerReservation): OwnedFailureDataConsumer113 {
    producer.ensureRetainedPeak(1048576)
    match (captureOwnedFailureData113<Unit>(tuiFullErrorFixture113(), { _ => producer.deriveRetainedLease() })) {
        case OwnedFailureDataOutcome113.Failure(actual) => actual
        case _ => throw IllegalStateException("actual error did not acquire its consumer") }
}
private func tuiFailureConsumer113(pool: LogicalJsonOwnerBudget): OwnedFailureDataConsumer113 {
    let producer = pool.acquire(1)
    try { tuiFailureConsumerFrame113(pool, producer) } finally { producer.close() }
}
// Independent original DOM codec oracle. It is built only after the actual
// copied owner pays its whole original data/DOM/encoding cost in this loan.
private func tuiOriginalErrorDom113(secondary: Bool): AgentValue {
    let error = tuiFullErrorFixture113(secondary: secondary)
    objectValue([
        ValueField("kind", textValue(if (secondary) { "transport" } else { "internal" })),
        ValueField("code", textValue(error.code)), ValueField("message", textValue(error.message)),
        ValueField("retryable", boolValue(true)), ValueField("fallback_allowed", boolValue(true)),
        ValueField("fields", listValue([
            objectValue([ValueField("name", textValue("duplicate")), ValueField("value", textValue("first"))]),
            objectValue([ValueField("name", textValue("duplicate")), ValueField("value", textValue("second雪\u{0}"))])])),
        ValueField("attempt_failure", objectValue([ValueField("kind", textValue("provider_protocol_error")),
            ValueField("diagnostics", objectValue([
                ValueField("elapsed_millis", integerValue(1)), ValueField("soft_deadline_millis", integerValue(2)),
                ValueField("hard_deadline_millis", integerValue(3)), ValueField("entered_completion_grace", boolValue(true)),
                ValueField("last_progress_kind", textValue("tool_argument_progress")), ValueField("last_progress_age_millis", integerValue(4)),
                ValueField("provider_terminal_observed", boolValue(true)), ValueField("open_content_block_count", integerValue(5)),
                ValueField("tool_calls_started", integerValue(6)), ValueField("tool_calls_completed", integerValue(7))]))])),
        ValueField("observation", error.observation.getOrThrow().toValue())])
}
private class TuiFailureOutputFixture113 <: OwnedTuiFailureDisplayOutput113 {
    var calls: Int64 = 0
    var waiting = false
    var throwOnce = false
    var secondaryOnce = false
    var last: ?OwnedTuiFailureDisplay113 = None<OwnedTuiFailureDisplay113>
    public func acceptFailureDisplay113(display: OwnedTuiFailureDisplay113): Result<Unit> {
        calls++
        if (waiting) { return Result<Unit>.Err(TUI_FAILURE_MAILBOX_PENDING113) }
        if (throwOnce) { throwOnce = false; throw IllegalStateException("actual fixture callback still owns its frame") }
        display.ensureCopiedDisplayRetainedPeak(display.projectionInvoice + 1048576).value().getOrThrow()
        if (secondaryOnce) {
            secondaryOnce = false
            // This real copied owner remains held by the exact original node
            // while the queue captures the complete secondary from this frame.
            return Result<Unit>.Err(tuiFullErrorFixture113(secondary: true))
        }
        display.withCopiedFailure113({ code, message, complete =>
            let secondary = code == "secondary雪\u{0}"
            @Expect(code, if (secondary) { "secondary雪\u{0}" } else { "checkpoint雪\u{0}" })
            @Expect(message, "complete message🙂\u{0}\n")
            @Expect(complete, encodeAgentValue(tuiOriginalErrorDom113(secondary)))
            @Expect(display.closeUnpublishedCopiedFailure113().isError(), true)
            Result<Unit>.Ok(())
        }).value().getOrThrow()
        last = Some(display)
        Result<Unit>.Ok(())
    }
}

// A genuine other callback stack keeps this exact original consumer loan
// alive after output registration. Only actual Future completion retires it.
private class TuiFailureLoanOutput113 <: OwnedTuiFailureDisplayOutput113 {
    private let source: OwnedFailureDataConsumer113
    private let entered = AtomicBool(false)
    private let returnLoan = AtomicBool(false)
    private var worker: ?Future<Unit> = Option<Future<Unit>>.None
    var calls: Int64 = 0
    init(source: OwnedFailureDataConsumer113) { this.source = source }
    public func acceptFailureDisplay113(display: OwnedTuiFailureDisplay113): Result<Unit> {
        calls++
        if (worker.isSome()) { throw IllegalStateException("the same copied display was registered twice") }
        @Expect(display.withCopiedFailure113({ _, _, complete =>
            @Expect(complete.contains("attempt_failure")); Result<Unit>.Ok(()) }).isOk())
        worker = Some(spawn {
            source.withError({ _, fund =>
                fund(4096).value().getOrThrow(); entered.store(true)
                let deadline = MonoTime.now() + Duration.second * 5
                while (!returnLoan.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                if (!returnLoan.load()) { throw IllegalStateException("real original loan did not return") }
            }).value().getOrThrow()
        })
        let deadline = MonoTime.now() + Duration.second * 5
        while (!entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
        @Expect(entered.load()); Result<Unit>.Ok(())
    }
    func retireActualLoan(): Unit {
        returnLoan.store(true)
        match (worker) { case Some(actual) => actual.get(); case None => () }
        worker = Option<Future<Unit>>.None
    }
}

@Test
class ActualOwnedTuiFailureQueue113Tests {
    @TestCase
    func pressuredClosingDiscardWaitsForActualLoanAndNeverClaimsDisplayedOrRegistryRetired113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = tuiFailureConsumer113(pool)
        let queue = OwnedTuiFailureQueue113(); let output = TuiFailureOutputFixture113()
        @Expect(queue.admit(OwnedAgentRunResult113.Pending(source)))
        let entered = AtomicBool(false); let returnLoan = AtomicBool(false)
        let active = spawn {
            source.withError({ _, _ =>
                entered.store(true)
                let deadline = MonoTime.now() + Duration.second * 5
                while (!returnLoan.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
                if (!returnLoan.load()) { throw IllegalStateException("actual close loan did not return") }
            }).value().getOrThrow()
        }
        let pressure = ArrayList<LogicalJsonOwnerReservation>()
        try {
            let deadline = MonoTime.now() + Duration.second * 5
            while (!entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 5) }
            @Expect(entered.load())
            try { while (true) { pressure.add(pool.acquire(1)) } } catch (_: LogicalJsonPayloadError) { () }
            queue.beginClosing()
            @Expect(queue.discardRegisteredOriginalsAfterActualFrames113().isError())
            @Expect(!source.isAcknowledged()); @Expect(queue.hasOriginalDebt())
            @Expect(queue.discardedOnCloseCount113(), 0); @Expect(output.calls, 0)
            returnLoan.store(true); active.get()
            @Expect(queue.discardRegisteredOriginalsAfterActualFrames113().isOk())
            @Expect(source.isAcknowledged()); @Expect(!queue.hasOriginalDebt())
            @Expect(queue.discardedOnCloseCount113(), 1); @Expect(output.calls, 0)
            @Expect(pool.usage()[1] > 0)
            for (paid in pressure) { paid.close() }; pressure.clear()
            // Cancellation consumed the real eight-field source, not a
            // Screen/stdout/renderer. Independent registry metadata is still
            // live, so bank zero awaits real whole-Screen retirement.
            @Expect(pool.usage()[1] > 0)
        } finally { returnLoan.store(true); active.get(); for (paid in pressure) { paid.close() } }
    }
    @TestCase
    func realConcurrentLoanBlocksAckWithoutRepublishingTheAlreadyAdmittedDisplay113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = tuiFailureConsumer113(pool)
        @Expect(source.withError({ _, fund => fund(8192).value().getOrThrow() }).isOk())
        let queue = OwnedTuiFailureQueue113(); let output = TuiFailureLoanOutput113(source)
        try {
            @Expect(queue.admit(OwnedAgentRunResult113.Pending(source)))
            queue.drain(output)
            @Expect(output.calls, 1); @Expect(!source.isAcknowledged()); @Expect(queue.hasOriginalDebt())
            @Expect(pool.usage()[1] > 0)
            output.retireActualLoan()
            queue.drain(output)
            @Expect(output.calls, 1); @Expect(source.isAcknowledged()); @Expect(!queue.hasOriginalDebt())
            // The independently copied display/registration remain paid;
            // neither a finished producer Future nor ACK refunds that data.
            @Expect(pool.usage()[1] > 0)
        } finally { output.retireActualLoan() }
    }
    @TestCase
    func actualEightFieldsAreCopiedBeforeSourceAckAndRemainPaidAfterOutputReturns113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = tuiFailureConsumer113(pool)
        let queue = OwnedTuiFailureQueue113(); let output = TuiFailureOutputFixture113()
        @Expect(queue.admit(OwnedAgentRunResult113.Pending(source)), true)
        @Expect(source.isAcknowledged(), false); @Expect(queue.hasOriginalDebt(), true)
        queue.drain(output)
        @Expect(output.calls, 1); @Expect(source.isAcknowledged(), true)
        @Expect(queue.hasOriginalDebt(), false); @Expect(pool.usage()[1] > 0, true)
        @Expect(output.last.getOrThrow().isAcknowledged(), false)
        // This actual copied registry/callback still owns its data. This is
        // deliberately no fake Screen/native stdout retirement positive.
    }
    @TestCase
    func actualMailboxBackpressureHoldsTheOriginalAndRetryAcknowledgesOnlyAfterAdmission113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = tuiFailureConsumer113(pool)
        let queue = OwnedTuiFailureQueue113(); let output = TuiFailureOutputFixture113()
        output.waiting = true
        @Expect(queue.admit(OwnedAgentRunResult113.Pending(source)), true)
        queue.drain(output)
        @Expect(source.isAcknowledged(), false); @Expect(queue.hasOriginalDebt(), true)
        output.waiting = false; queue.drain(output)
        @Expect(output.calls, 2); @Expect(source.isAcknowledged(), true)
        @Expect(pool.usage()[1] > 0, true)
    }
    @TestCase
    func actualOriginalPoolPressureAndClosingCannotAdmitOrAcknowledgeAnotherConsumer113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = tuiFailureConsumer113(pool)
        let pressure = ArrayList<LogicalJsonOwnerReservation>()
        let queue = OwnedTuiFailureQueue113(); let output = TuiFailureOutputFixture113()
        try {
            while (true) { pressure.add(pool.acquire(1)) }
        } catch (_: LogicalJsonPayloadError) { () }
        @Expect(queue.admit(OwnedAgentRunResult113.Pending(source)), false)
        @Expect(source.isAcknowledged(), false); @Expect(output.calls, 0)
        for (paid in pressure) { paid.close() }; pressure.clear()
        @Expect(queue.admit(OwnedAgentRunResult113.Pending(source)), true)
        queue.drain(output); @Expect(source.isAcknowledged(), true)
        let next = tuiFailureConsumer113(pool)
        queue.beginClosing()
        @Expect(queue.admit(OwnedAgentRunResult113.Pending(next)), false)
        @Expect(next.isAcknowledged(), false)
        next.acknowledgeAfterConsumption().value().getOrThrow()
        @Expect(pool.usage()[1] > 0, true) // real earlier copied/registry debt
    }
    @TestCase
    func realSecondaryOutputErrorKeepsEightFieldsAndWaitsForItsOwnConsumer113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = tuiFailureConsumer113(pool)
        let queue = OwnedTuiFailureQueue113(); let output = TuiFailureOutputFixture113()
        output.secondaryOnce = true
        @Expect(queue.admit(OwnedAgentRunResult113.Pending(source)), true)
        queue.drain(output)
        @Expect(source.isAcknowledged(), false); @Expect(queue.hasOriginalDebt(), true)
        queue.drain(output)
        @Expect(source.isAcknowledged(), true); @Expect(queue.hasOriginalDebt(), true)
        queue.drain(output)
        @Expect(output.calls, 3); @Expect(queue.hasOriginalDebt(), false)
        @Expect(output.last.getOrThrow().withCopiedFailure113({ code, _, _ =>
            @Expect(code, "secondary雪\u{0}"); Result<Unit>.Ok(()) }).isOk(), true)
        @Expect(pool.usage()[1] > 0, true)
    }
    @TestCase
    func callbackThrowLeavesTheExactSourceDebtAndLaterSuccessfulCopyDoesNotReplayExecution113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = tuiFailureConsumer113(pool)
        let queue = OwnedTuiFailureQueue113(); let output = TuiFailureOutputFixture113()
        output.throwOnce = true
        @Expect(queue.admit(OwnedAgentRunResult113.Pending(source)), true)
        var threw = false
        try { queue.drain(output) } catch (_: IllegalStateException) { threw = true }
        @Expect(threw, true); @Expect(source.isAcknowledged(), false); @Expect(queue.hasOriginalDebt(), true)
        queue.drain(output)
        @Expect(output.calls, 2); @Expect(source.isAcknowledged(), true)
        @Expect(queue.hasOriginalDebt(), false); @Expect(pool.usage()[1] > 0, true)
    }
}
