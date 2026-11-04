package agent_host_runtime

import agent_domain.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func taskWaitOutputCopyFrame204(source: HostPaidValueProjection151, target: HostPaidValueProjection151,
    entered: AtomicBool, release: AtomicBool): Unit {
    let borrowed = [None<AgentValue>]
    // Match the actual backend envelope: its projection getter has returned,
    // but this complete private outer helper still holds that source alias.
    // The projection's own callback counter is now zero; only the real outer
    // DATA reader can keep Task.close from retiring this backing too early.
    source.withValue151({ value => borrowed[0] = Some(value) })
    entered.store(true)
    let deadline = MonoTime.now() + Duration.second * 5
    while (!release.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
    if (!release.load()) { throw IllegalStateException("output-copy barrier was not released") }
    target.retainValue151(1, borrowed[0].getOrThrow())
    target.projectValue151(1)
    borrowed[0] = None<AgentValue>
}

@Test
class TaskExecutorData204Tests {
    @TestCase
    func distinctWaitReaderKeepsOriginalProjectionPaidUntilWholeOutputCopyReturns(): Unit {
        let bank = LogicalJsonOwnerBudget()
        let source = HostPaidValueProjection151(bank.acquire(1048576))
        let copied = HostPaidValueProjection151(bank.acquire(1048576))
        source.retainValue151(1, textValue("the complete original Task projection"))
        source.projectValue151(1)
        let original = HostTaskExecutorDataReaders204()
        original.beginFrame204(); original.returnCompleteFrame204()
        let waiting = HostTaskExecutorDataReaders204()
        waiting.beginFrame204()
        // Production child.wait installs this exact source only after actual
        // Source/receipt/closing checks on its state, before borrowing output.
        waiting.borrowSourceFrame204(original)
        let entered = AtomicBool(false)
        let release = AtomicBool(false)
        let worker = spawn {
            taskWaitOutputCopyFrame204(source, copied, entered, release)
            waiting.returnCompleteFrame204()
        }
        try {
            let deadline = MonoTime.now() + Duration.second * 5
            while (!entered.load() && MonoTime.now() < deadline) { sleep(Duration.millisecond * 2) }
            @Expect(entered.load(), true)
            // This is the same guard used by real Task.close. A child Future
            // may already be joined; the distinct outer reader still blocks.
            @Expect(original.readersReturned204(), false)
            @Expect(waiting.readersReturned204(), false)
            @Expect(bank.usage()[0], 2)
            if (original.readersReturned204()) { source.closeUnpublished151() }
            @Expect(bank.usage()[0], 2)
        } finally { release.store(true); worker.get() }
        @Expect(original.readersReturned204(), true)
        @Expect(waiting.readersReturned204(), true)
        source.closeUnpublished151()
        copied.withValue151({ value => @Expect(value.text, "the complete original Task projection") })
        copied.closeUnpublished151()
        @Expect(bank.usage()[0], 0)
        @Expect(bank.usage()[1], 0)
    }
}
