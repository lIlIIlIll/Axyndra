package core

import std.unittest.*
import std.unittest.testmacro.*

@Test
class RetiredInternalDisplayFrameTests {
    @TestCase
    func ActualDrawBorrowBlocksInternalRetirementAndRetainedBackendSnapshotIsNeverTransportAcknowledged(): Unit {
        let backend = TestBackend(area: Rect(0, 0, 8, 2)); let terminal = Terminal(backend)
        let _ = terminal.draw({frame =>
            frame.canvas().drawText(0, 0, "kept", Style.default())
            @Expect(RetiredInternalDisplayFrameReferences.retire(terminal).isNone(), true) })
        let witness = RetiredInternalDisplayFrameReferences.retire(terminal).getOrThrow()
        @Expect(witness.internalReferencesRetired(), true)
        @Expect(witness.transportPhysicallyAcknowledged(), false)
        @Expect(backend.lastBuffer().getOrThrow().getCell(0, 0).symbol, "k")
        var failed = false
        try { let _ = terminal.draw({_ =>}) } catch (_: Exception) { failed = true }
        @Expect(failed, true)
    }
    @TestCase
    func ActualFailedDrawEndsItsHelperBeforeAnInternalWitnessCanClearTerminalFields(): Unit {
        let terminal = Terminal(TestBackend(area: Rect(0, 0, 8, 2)))
        var failed = false
        try { let _ = terminal.draw({_ => throw Exception("original.render_failure")}) }
        catch (_: Exception) { failed = true }
        @Expect(failed, true)
        @Expect(RetiredInternalDisplayFrameReferences.retire(terminal).getOrThrow().transportPhysicallyAcknowledged(), false)
    }
}
