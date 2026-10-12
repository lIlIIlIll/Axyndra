package agent_runtime

import agent_domain.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

func ownedFailureSeed113(pool: LogicalJsonOwnerBudget): OwnedFailureData113 {
    let source = pool.acquire(1)
    try { source.ensureRetainedPeak(4194304); ownedFailureSeedFrame113(pool) }
    finally { source.close() }
}
func ownedFailureSeedFrame113(pool: LogicalJsonOwnerBudget): OwnedFailureData113 {
    let message = String.fromUtf8(Array<Byte>(300000, repeat: b'e')) + "\u{0}雪🙂"
    let error = AgentError(AgentErrorKind.Provider, "original.dynamic.code", message,
        retryable: true, fallbackAllowed: true, fields: [ErrorField("original", "\u{0}雪🙂")],
        attemptFailure: Some(AttemptFailure(AttemptFailureKind.ProviderTransportError,
            diagnostics: AttemptFailureDiagnostics(elapsedMillis: 7, softDeadlineMillis: 11,
                hardDeadlineMillis: 13, enteredCompletionGrace: true, lastProgressAgeMillis: 17,
                providerTerminalObserved: true, openContentBlockCount: 2, toolCallsStarted: 3, toolCallsCompleted: 1))),
        observation: Some(OperationObservation("{\"original\":\"雪🙂\"}")))
    OwnedFailureData113(error, { bytes => pool.acquire(bytes) })
}

@Test
class OwnedFailureData113Tests {
    @TestCase
    func fullOriginalEightFieldsOutliveProducerUntilActualConsumerAcknowledges113(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let data = ownedFailureSeed113(pool)
        let consumer = data.retainConsumer().value().getOrThrow()
        @Expect(data.closeAfterProducerRetirement().isOk(), true)
        @Expect(data.isRetired(), false); @Expect(pool.usage()[0], 1)
        @Expect(consumer.withError({ error, pay =>
            @Expect(error.kind, AgentErrorKind.Provider)
            @Expect(error.code, "original.dynamic.code")
            @Expect(error.message.size > 300000, true); @Expect(error.message.endsWith("\u{0}雪🙂"), true)
            @Expect(error.retryable, true); @Expect(error.fallbackAllowed, true)
            @Expect(error.fields.size, 1); @Expect(error.fields[0].value, "\u{0}雪🙂")
            let d = error.attemptFailure.getOrThrow().diagnostics
            @Expect(d.elapsedMillis, 7); @Expect(d.softDeadlineMillis, 11); @Expect(d.hardDeadlineMillis, 13)
            @Expect(d.enteredCompletionGrace, true); @Expect(d.lastProgressAgeMillis, 17)
            @Expect(d.providerTerminalObserved, true); @Expect(d.openContentBlockCount, 2)
            @Expect(d.toolCallsStarted, 3); @Expect(d.toolCallsCompleted, 1)
            @Expect(error.observation.isSome(), true)
            @Expect(pay(1048576).isOk(), true)
            @Expect(consumer.acknowledgeAfterConsumption().isError(), true)
        }).isOk(), true)
        @Expect(pool.usage()[0], 1); @Expect(data.isRetired(), false)
        @Expect(consumer.acknowledgeAfterConsumption().isOk(), true)
        @Expect(consumer.isAcknowledged(), true); @Expect(data.isRetired(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func genuinelyHeldConsumerCallbackPreventsEarlyAcknowledgementAndRefund113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let data = ownedFailureSeed113(pool)
        let consumer = data.retainConsumer().value().getOrThrow()
        let entered = AtomicBool(false); let release = AtomicBool(false)
        let worker: Future<Unit> = spawn {
            @Expect(consumer.withError({ error, pay =>
                @Expect(error.message.size > 300000, true)
                @Expect(pay(1048576).isOk(), true)
                entered.store(true)
                while (!release.load()) { sleep(Duration.millisecond) }
                @Expect(error.fields[0].value, "\u{0}雪🙂")
            }).isOk(), true)
        }
        try {
            let deadline = MonoTime.now() + Duration.second * 2
            while (!entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond) }
            @Expect(entered.load(), true)
            @Expect(data.closeAfterProducerRetirement().isOk(), true)
            @Expect(consumer.acknowledgeAfterConsumption().isError(), true)
            @Expect(data.isRetired(), false); @Expect(pool.usage()[0], 1)
        } finally { release.store(true); worker.get() }
        @Expect(consumer.acknowledgeAfterConsumption().isOk(), true)
        @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func consumerExceptionLeavesDataPaidAndEachSimultaneousInvoiceIsAdded113(): Unit {
        let pool = LogicalJsonOwnerBudget(); let data = ownedFailureSeed113(pool)
        let first = data.retainConsumer().value().getOrThrow()
        let second = first.retainConsumer().value().getOrThrow()
        @Expect(data.closeAfterProducerRetirement().isOk(), true)
        var threw = false
        try { let _ = first.withError({ _, pay =>
            @Expect(pay(16777216).isOk(), true); @Expect(pay(16777216).isOk(), true)
            throw IllegalStateException("actual consumer throws") }) }
        catch (_: Exception) { threw = true }
        @Expect(threw, true); @Expect(pool.usage()[1] > 33554432, true)
        @Expect(first.acknowledgeAfterConsumption().isOk(), true)
        @Expect(data.isRetired(), false); @Expect(pool.usage()[0], 1)
        @Expect(second.withError({ error, _ => @Expect(error.code, "original.dynamic.code") }).isOk(), true)
        @Expect(second.acknowledgeAfterConsumption().isOk(), true)
        @Expect(data.isRetired(), true); @Expect(pool.usage()[0], 0); @Expect(pool.usage()[1], 0)
    }
}
