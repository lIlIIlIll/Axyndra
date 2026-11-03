package core

import std.unittest.*
import std.unittest.testmacro.*

class ActualAsyncReferenceProbe {
    var cell: ?AsyncTaskReferenceCell = None
    var called: Int64 = 0
    var retirementWhileBorrowed = true
}
@Test
class AsyncTaskReferenceCellTests {
    @TestCase
    func ActualBorrowedCallableCannotRetireUntilItsRealHelperFrameEnds(): Unit {
        let probe = ActualAsyncReferenceProbe()
        let cell = AsyncTaskReferenceCell({=>
            probe.called++
            probe.cell.getOrThrow().beginClosing()
            probe.retirementWhileBorrowed = probe.cell.getOrThrow().referencesRetired()
            Event.Message("result still live") })
        probe.cell = Some(cell)
        let result = cell.run()
        @Expect(probe.called, 1); @Expect(probe.retirementWhileBorrowed, false)
        @Expect(cell.referencesRetired(), true)
        // Callable retirement is deliberately not an arbitrary returned
        // Event/String lifetime ACK. The actual result remains usable here.
        match (result) { case Event.Message(text) => @Expect(text, "result still live"); case _ => @Fail("actual returned result") }
    }
    @TestCase
    func PendingCancelledCallableReallyClearsBeforeAnyLaterWorkerEntry(): Unit {
        let probe = ActualAsyncReferenceProbe()
        let cell = AsyncTaskReferenceCell({=> probe.called++; Event.Message("captured") })
        cell.beginClosing(); @Expect(cell.referencesRetired(), true)
        let _ = cell.run(); @Expect(probe.called, 0)
    }
    @TestCase
    func ConcreteDirectStdOutNeedsPhysicalFlushAndClosesActualWriteAdmission(): Unit {
        let output = DirectStdOutDisplayOutput.open()
        let receipt = RetiredDirectStdOutDisplayReferences.retire(output).getOrThrow()
        @Expect(receipt.physicallyFlushed(), true); @Expect(receipt.acknowledges(output), true)
        @Expect(receipt.acknowledges(DirectStdOutDisplayOutput.open()), false)
        var failed = false
        try { output.write([]) } catch (_: Exception) { failed = true }
        @Expect(failed, true)
    }
}
