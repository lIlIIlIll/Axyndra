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
    var capturePaymentRequired = true
    public func headlessCapturedDataRequiresPayment():Bool { capturePaymentRequired }
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


@Test
class CapturedHeadlessFrameScopeTests {
    @TestCase
    func CapturedDataOutlivesOnlyInternalRetirementWithoutAnOutputAcknowledgment(): Unit {
        let probe = HeadlessOwnedFrameProbe()
        let scope = HeadlessCapturedFrameScope(probe)
        let result = AppTestRunner.runWithCaptureCustody(HeadlessScript().render(), { frame =>
            frame.canvas().drawText(0, 0, "雪", Style.default())
        }, { _ => UpdateResult.next() }, scope, options: HeadlessRunOptions(area: Rect(0, 0, 8, 2)))
        @Expect(result.passed()); @Expect(result.frames.size, 2); @Expect(result.snapshots.size, 2)
        @Expect(!probe.closing && !probe.asyncRetired && !probe.internalRetired)
        scope.retireInternalFrames()
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
        // The internal receipt never clears or acknowledges exported captures.
        @Expect(result.frames[0].getCell(0, 0).symbol, "雪")
        @Expect(result.snapshots[1].contains("雪"))
        scope.retireInternalFrames()
        var failure = ""
        try { let _ = AppTestRunner.runWithCaptureCustody(HeadlessScript(), { _ => () }, { _ => UpdateResult.next() }, scope) }
        catch (error: Exception) { failure = error.message }
        @Expect(failure, "display.headless_capture_scope_closed")
    }
    @TestCase
    func ActiveRenderCannotClaimInternalRetirementAndLaterFramesKeepTheirOriginalInvoice(): Unit {
        let probe = HeadlessOwnedFrameProbe(); let scope = HeadlessCapturedFrameScope(probe)
        let blocked = [0]
        let result = AppTestRunner.runWithCaptureCustody(HeadlessScript().resize(Rect(0,0,10,3)), { _ =>
            try { scope.retireInternalFrames() }
            catch (error: Exception) { if (error.message == "display.headless_capture_frame_active") { blocked[0]++ } }
        }, { _ => UpdateResult.next() }, scope, options: HeadlessRunOptions(area: Rect(0,0,8,2)))
        @Expect(blocked[0], 2); @Expect(result.frames.size, 2)
        @Expect(!probe.closing && !probe.internalRetired)
        @Expect(probe.invoices[probe.invoices.size-1] > probe.invoices[0])
        scope.retireInternalFrames()
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
    }
    @TestCase
    func RefusedCapturePaymentDoesNotExportAnotherBufferOrAcknowledgeAnyConsumer(): Unit {
        let probe = HeadlessOwnedFrameProbe(); let scope = HeadlessCapturedFrameScope(probe)
        var failure = ""
        try { let _ = AppTestRunner.runWithCaptureCustody(HeadlessScript(), { _ =>
            probe.renders++; probe.allowed = false
        }, { _ => UpdateResult.next() }, scope, options: HeadlessRunOptions(area: Rect(0,0,8,2))) }
        catch (error: Exception) { failure = error.message }
        @Expect(failure, "display.raster_payment_required"); @Expect(probe.renders, 1)
        @Expect(!probe.closing && !probe.internalRetired)
        scope.retireInternalFrames()
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
    }
    @TestCase
    func ThrowingCapturedRenderKeepsItsPrimaryFailureUntilItsRealScopeCloses(): Unit {
        let probe = HeadlessOwnedFrameProbe(); let scope = HeadlessCapturedFrameScope(probe)
        var failure = ""
        try { let _ = AppTestRunner.runWithCaptureCustody(HeadlessScript(), { _ =>
            throw Exception("original.captured_render")
        }, { _ => UpdateResult.next() }, scope) }
        catch (error: Exception) { failure = error.message }
        @Expect(failure, "original.captured_render")
        @Expect(!probe.closing && !probe.asyncRetired && !probe.internalRetired)
        scope.retireInternalFrames()
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
    }
}


class HeadlessAwaitState227 {
    var complete = false
    var keys: Int64 = 0
}
@Test
class HeadlessAwait227Tests {
    @TestCase
    func AwaitPumpsActualAsyncCompletionWithoutRetiringItsCapturedConsumer(): Unit {
        let state = HeadlessAwaitState227(); let probe = HeadlessOwnedFrameProbe()
        let scope = HeadlessCapturedFrameScope(probe)
        let result = AppTestRunner.runWithCaptureCustody(
            HeadlessScript().key(KeyEvent(KeyCode.Enter)).waitUntil({ => state.complete }, timeoutMillis:1000),
            { frame => frame.canvas().drawText(0,0,if(state.complete){"done"}else{"waiting"},Style.default()) },
            { event => match(event) {
                case Event.KeyDown(_) => UpdateResult.withCommand(Command.AsyncTask("await227",{ => Event.Message("done") }))
                case Event.AsyncCompleted("await227",Event.Message("done")) => state.complete=true;UpdateResult.next()
                case _ => UpdateResult.next()
            } },scope,options:HeadlessRunOptions(area:Rect(0,0,8,2)))
        @Expect(state.complete); @Expect(result.passed())
        @Expect(result.frames.size,3); @Expect(result.snapshots[2].contains("done"))
        @Expect(!probe.closing && !probe.asyncRetired && !probe.internalRetired)
        scope.retireInternalFrames()
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
    }
    @TestCase
    func AwaitTimeoutCannotDeliverLaterScriptedInputOrClaimRetirement(): Unit {
        let state = HeadlessAwaitState227(); let probe = HeadlessOwnedFrameProbe()
        let scope = HeadlessCapturedFrameScope(probe);var failure=""
        try { let _ = AppTestRunner.runWithCaptureCustody(
            HeadlessScript().waitUntil({ => false },timeoutMillis:1,label:"never").key(KeyEvent(KeyCode.Enter)),
            { _ => () },{ event => match(event){case Event.KeyDown(_)=>state.keys++;case _=>()};UpdateResult.next() },scope,
            options:HeadlessRunOptions(area:Rect(0,0,8,2))) }
        catch(error:Exception){failure=error.message}
        @Expect(failure,"headless.await_timeout: never");@Expect(state.keys,0)
        @Expect(!probe.closing && !probe.asyncRetired && !probe.internalRetired)
        scope.retireInternalFrames()
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired)
    }
    @TestCase
    func AwaitInputTravelsThroughTheOrdinaryUpdateAndCommandLoop(): Unit {
        let state=HeadlessAwaitState227();let probe=HeadlessOwnedFrameProbe();let scope=HeadlessCapturedFrameScope(probe)
        let result=AppTestRunner.runWithCaptureCustody(
            HeadlessScript().waitUntil({=>state.complete},input:{=>Some(Event.KeyDown(KeyEvent(KeyCode.Enter)))},timeoutMillis:1000),
            {_=>()}, {event=>match(event){case Event.KeyDown(_)=>state.keys++;state.complete=true;case _=>()};UpdateResult.next()},scope,
            options:HeadlessRunOptions(area:Rect(0,0,8,2)))
        @Expect(result.passed());@Expect(state.keys,1);@Expect(result.frames.size,2)
        scope.retireInternalFrames()
    }
}


@Test
class HeadlessCapturePayer227Tests {
    @TestCase
    func PriorUnownedFixtureFramesCannotBecomeALaterCopiedDisplayInvoice():Unit {
        let probe=HeadlessOwnedFrameProbe();probe.capturePaymentRequired=false
        let scope=HeadlessCapturedFrameScope(probe)
        let unowned=AppTestRunner.runWithCaptureCustody(HeadlessScript().tick(count:20),{_=>()},
            {_=>UpdateResult.next()},scope,options:HeadlessRunOptions(area:Rect(0,0,20,8)))
        probe.capturePaymentRequired=true
        let firstPaid=probe.invoices.size
        let paid=AppTestRunner.runWithCaptureCustody(HeadlessScript(),{_=>()},
            {_=>UpdateResult.next()},scope,options:HeadlessRunOptions(area:Rect(0,0,8,2)))
        let fresh=HeadlessOwnedFrameProbe();let freshScope=HeadlessCapturedFrameScope(fresh)
        let control=AppTestRunner.runWithCaptureCustody(HeadlessScript(),{_=>()},
            {_=>UpdateResult.next()},freshScope,options:HeadlessRunOptions(area:Rect(0,0,8,2)))
        @Expect(probe.invoices.size-firstPaid,fresh.invoices.size)
        for(index in 0..fresh.invoices.size){@Expect(probe.invoices[firstPaid+index],fresh.invoices[index])}
        @Expect(unowned.frames.size,21);@Expect(paid.frames.size,1);@Expect(control.frames.size,1)
        scope.retireInternalFrames();freshScope.retireInternalFrames()
    }
    @TestCase
    func ATemporaryUnownedPhaseNeverDropsEarlierCopiedDisplayPayments():Unit {
        let probe=HeadlessOwnedFrameProbe();let scope=HeadlessCapturedFrameScope(probe)
        let first=AppTestRunner.runWithCaptureCustody(HeadlessScript(),{_=>()},
            {_=>UpdateResult.next()},scope,options:HeadlessRunOptions(area:Rect(0,0,8,2)))
        let earlier=probe.invoices[probe.invoices.size-1]
        probe.capturePaymentRequired=false
        let unowned=AppTestRunner.runWithCaptureCustody(HeadlessScript(),{_=>()},
            {_=>UpdateResult.next()},scope,options:HeadlessRunOptions(area:Rect(0,0,8,2)))
        probe.capturePaymentRequired=true
        let later=AppTestRunner.runWithCaptureCustody(HeadlessScript(),{_=>()},
            {_=>UpdateResult.next()},scope,options:HeadlessRunOptions(area:Rect(0,0,8,2)))
        @Expect(probe.invoices[probe.invoices.size-1]>earlier)
        @Expect(first.frames.size,1);@Expect(unowned.frames.size,1);@Expect(later.frames.size,1)
        scope.retireInternalFrames()
    }
}
