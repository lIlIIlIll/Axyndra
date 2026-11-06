package core

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

class HeadlessOwnedFrameProbe <: TerminalFrameProvider {
    let invoices = ArrayList<Int64>()
    var allowed = true
    var closing = false
    var asyncRetired = false
    var internalRetired = false
    var renders: Int64 = 0
    var rendering = false
    var failCleanup = false
    public func prepareRetainedFrameCopies(size: Rect, previous: Int64): Bool {
        let _ = size; invoices.add(previous); allowed
    }
    public func wantsRetainedDisplayProducerRetirement(): Bool { true }
    public func beginRetainedDisplayProducerClosing(): Unit { closing = true }
    public func noteAsyncTaskReferencesRetired(actual: RetiredAsyncTaskReferences): Unit {
        asyncRetired = actual.callableReferencesRetired() && actual.notifierAndRuntimeResultReferencesRetired()
    }
    public func noteInternalDisplayFrameReferencesRetired(actual: RetiredInternalDisplayFrameReferences): Unit {
        @Expect(!rendering)
        internalRetired = actual.internalReferencesRetired() && !actual.transportPhysicallyAcknowledged()
        if (failCleanup) { throw Exception("secondary.headless_cleanup") }
    }
    public func prepareFrame(size: Rect): PresentationFrame { PresentationFrame(PresentationMode.Fullscreen, size, viewport: size) }
    public func renderViewport(frame: Frame): Unit { let _ = frame }
    public func renderHistory(id: Int64, start: Int64, frame: Frame): Unit { let _ = id; let _ = start; let _ = frame }
    public func acknowledgeHistory(id: Int64): Unit { let _ = id }
    public func requestReplay(): Unit {}
}

@Test
class OwnedHeadlessFrameTests {
    @TestCase
    func ActualBuffersAreReservedAndWholeHelpersRetireWithoutTransportAck(): Unit {
        let probe = HeadlessOwnedFrameProbe()
        let result = AppTestRunner.runOwned(HeadlessScript().render(), { frame =>
            probe.rendering = true
            try { frame.canvas().drawText(0, 0, "actual", Style.default()) }
            finally { probe.rendering = false }
        }, { _ => UpdateResult.next() }, probe,
            options: HeadlessRunOptions(area: Rect(0, 0, 8, 2), captureBuffers: false, captureSnapshots: false))
        @Expect(result.passed()); @Expect(result.frames.size, 0); @Expect(result.snapshots.size, 0)
        @Expect(probe.invoices.size, 2); @Expect(probe.invoices[0], 0); @Expect(probe.invoices[1] > 0)
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
    }
    @TestCase
    func RefusedOriginalPaymentPreventsTheFirstDraw(): Unit {
        let probe = HeadlessOwnedFrameProbe(); probe.allowed = false
        var failure = ""
        try { let _ = AppTestRunner.runOwned(HeadlessScript(), { _ => probe.renders++ }, { _ => UpdateResult.next() }, probe) }
        catch (error: Exception) { failure = error.message }
        @Expect(failure, "display.raster_payment_required"); @Expect(probe.renders, 0)
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
    }
    @TestCase
    func ThrowingDrawReturnsBeforeActualRetirementAndKeepsThePrimaryFailure(): Unit {
        let probe = HeadlessOwnedFrameProbe(); probe.failCleanup = true
        var failure = ""
        try { let _ = AppTestRunner.runOwned(HeadlessScript(), { _ =>
            probe.rendering = true
            try { throw Exception("original.headless_render") }
            finally { probe.rendering = false }
        }, { _ => UpdateResult.next() }, probe) }
        catch (error: Exception) { failure = error.message }
        @Expect(failure, "original.headless_render")
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
    }
    @TestCase
    func RetainedSnapshotsCannotBeAcknowledgedByTheNoncapturingRunner(): Unit {
        let probe = HeadlessOwnedFrameProbe(); var failure = ""
        try { let _ = AppTestRunner.runOwned(HeadlessScript(), { _ => probe.renders++ }, { _ => UpdateResult.next() }, probe,
            options: HeadlessRunOptions(captureBuffers: true, captureSnapshots: false)) }
        catch (error: Exception) { failure = error.message }
        @Expect(failure, "display.headless_capture_custody_required")
        @Expect(probe.renders, 0); @Expect(probe.invoices.size, 0)
        @Expect(!probe.closing && !probe.asyncRetired && !probe.internalRetired)
    }
}
