package core

import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

class ActualNotifierDelayGate {
    private let lock = Mutex()
    private var entered = false
    private var released = false
    func delayActualNotifier(): Unit {
        lock.lock(); try { entered = true } finally { lock.unlock() }
        while (!isReleased()) { sleep(Duration.millisecond) }
    }
    func isEntered(): Bool { lock.lock(); try { entered } finally { lock.unlock() } }
    private func isReleased(): Bool { lock.lock(); try { released } finally { lock.unlock() } }
    func release(): Unit { lock.lock(); try { released = true } finally { lock.unlock() } }
}

@Test
class AsyncDrainedNotifierCustodyTests {
    @TestCase
    func ActualDrainKeepsCompletedResultCustodyWhileRealNotifierIsDelayed(): Unit {
        let gate = ActualNotifierDelayGate()
        let runtime = AsyncRuntime({=> gate.delayActualNotifier() })
        try {
            _ = runtime.start("delayed", {=> Event.Message("\u{0000}完整 result") })
            while (!gate.isEntered()) { sleep(Duration.millisecond) }
            var delivered: ?Event = None
            while (delivered.isNone()) {
                let actual = runtime.drain()
                if (actual.size > 0) { delivered = Some(actual[0]) }
                else { sleep(Duration.millisecond) }
            }
            @Expect(runtime.pendingCount(), 0)
            @Expect(runtime.retainedReferenceTaskCount(), 1)
            @Expect(runtime.allActualNotifierFramesEnded(), false)
            @Expect(runtime.drain().size, 0)
            @Expect(runtime.cancel("delayed"), false)
            // Release the REAL spawned notifier. Retirement must wait for its
            // actual borrowing helper, not result availability/cancel/GC.
            let actualRetirement = spawn { RetiredAsyncTaskReferences.retire(runtime) }
            while (!runtime.retirementWaitingOnActualNotifier()) { sleep(Duration.millisecond) }
            @Expect(runtime.retainedReferenceTaskCount(), 1)
            @Expect(runtime.allActualNotifierFramesEnded(), false)
            @Expect(actualRetirement.tryGet().isNone(), true)
            gate.release()
            let retired = actualRetirement.get()
            @Expect(retired.notifierAndRuntimeResultReferencesRetired(), true)
            @Expect(runtime.retainedReferenceTaskCount(), 0)
            match (delivered.getOrThrow()) {
                case Event.AsyncCompleted(id, Event.Message(text)) =>
                    @Expect(id, "delayed"); @Expect(text, "\u{0000}完整 result")
                case _ => @Fail("actual drained result remains exact")
            }
            // The caller still owns this exact Event. No returned-data,
            // metadata payment, capacity, transport or bank-zero ACK claim.
        } finally { gate.release() }
    }

    @TestCase
    func DeliveredNotifierCustodyDoesNotChangePendingOrReusedIDCancellation(): Unit {
        let gate = ActualNotifierDelayGate()
        let runtime = AsyncRuntime({=> gate.delayActualNotifier() })
        try {
            _ = runtime.start("same", {=> Event.Message("first") })
            while (!gate.isEntered()) { sleep(Duration.millisecond) }
            var delivered = false
            while (!delivered) {
                for (actual in runtime.drain()) {
                    match (actual) {
                        case Event.AsyncCompleted(_, Event.Message(text)) => @Expect(text, "first"); delivered = true
                        case _ => @Fail("original first result")
                    }
                }
                if (!delivered) { sleep(Duration.millisecond) }
            }
            @Expect(runtime.pendingCount(), 0)
            _ = runtime.start("same", {=> Event.Message("second") })
            @Expect(runtime.pendingCount(), 1)
            @Expect(runtime.cancel("same"), true)
            var cancelled = false
            while (!cancelled) {
                for (actual in runtime.drain()) {
                    match (actual) {
                        case Event.AsyncCancelled(id) => @Expect(id, "same"); cancelled = true
                        case _ => @Fail("original second cancellation")
                    }
                }
                if (!cancelled) { sleep(Duration.millisecond) }
            }
            @Expect(runtime.pendingCount(), 0)
            @Expect(runtime.retainedReferenceTaskCount(), 2)
            @Expect(runtime.drain().size, 0)
            gate.release()
            let _ = RetiredAsyncTaskReferences.retire(runtime)
            @Expect(runtime.retainedReferenceTaskCount(), 0)
        } finally { gate.release() }
    }
}
