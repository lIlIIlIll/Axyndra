package core

import std.unittest.*
import std.unittest.testmacro.*

private class ManualFrameObservation240 {
    var saved: ?HeadlessManualFrame240 = None
    var messages: Int64 = 0
    var actionRefused = false
}

@Test
class ManualHeadlessFrame240Tests {
    @TestCase
    func realCommandsAndDirtyDrawRetireOnlyAfterTheirActualHelperReturns(): Unit {
        let probe = HeadlessOwnedFrameProbe()
        let scope = HeadlessCapturedFrameScope(probe)
        let state = ManualFrameObservation240()
        let answer = scope.withManualFrame240<Int64>({ event =>
            match (event) {
                case Event.KeyDown(_) => UpdateResult.withCommand(Command.Emit(Event.Message("manual")))
                case Event.Message(text) => if (text == "manual") { state.messages++ }; UpdateResult.next()
                case _ => UpdateResult.next()
            }
        }, { manual =>
            state.saved = Some(manual)
            let _ = manual.update(Event.KeyDown(KeyEvent(KeyCode.Char(r'x'))))
            let _ = manual.draw({ frame => frame.canvas().drawText(0, 0, "actual", Style.default()) })
            @Expect(probe.asyncRetired || probe.internalRetired, false)
            state.messages
        }, area: Rect(0, 0, 8, 2))
        @Expect(answer, 1)
        var rejected = false
        try { let _ = state.saved.getOrThrow().draw({ _ => () }) }
        catch (error: Exception) { rejected = error.message == "display.manual_frame_unavailable" }
        @Expect(rejected, true)
        scope.retireInternalFrames()
        @Expect(probe.closing && probe.asyncRetired && probe.internalRetired, true)
    }
    @TestCase
    func originalPaymentRefusalPreventsManualRendering(): Unit {
        let probe = HeadlessOwnedFrameProbe(); probe.capturePaymentRequired = false; probe.allowed = false
        let scope = HeadlessCapturedFrameScope(probe)
        var errorCode = ""
        try { let _ = scope.withManualFrame240<Int64>({ _ => UpdateResult.next() }, { manual =>
            let _ = manual.draw({ _ => probe.renders++ }); 0
        }) } catch (error: Exception) { errorCode = error.message }
        @Expect(errorCode, "display.raster_payment_required")
        @Expect(probe.renders, 0)
        scope.retireInternalFrames()
        @Expect(probe.asyncRetired && probe.internalRetired, true)
    }
    @TestCase
    func throwingRenderPreservesPrimaryFailureAndRevokesItsFacade(): Unit {
        let probe = HeadlessOwnedFrameProbe(); let scope = HeadlessCapturedFrameScope(probe)
        let state = ManualFrameObservation240()
        var errorCode = ""
        try { let _ = scope.withManualFrame240<Int64>({ _ => UpdateResult.next() }, { manual =>
            state.saved = Some(manual)
            let _ = manual.draw({ _ => throw Exception("original.manual_render") }); 0
        }) } catch (error: Exception) { errorCode = error.message }
        @Expect(errorCode, "original.manual_render")
        var rejected = false
        try { let _ = state.saved.getOrThrow().update(Event.Message("late")) }
        catch (_: Exception) { rejected = true }
        @Expect(rejected, true)
        scope.retireInternalFrames()
        @Expect(probe.asyncRetired && probe.internalRetired, true)
    }
    @TestCase
    func activeBodyCannotAcknowledgeItsScopeOrReenterTheActualDraw(): Unit {
        let probe = HeadlessOwnedFrameProbe(); let scope = HeadlessCapturedFrameScope(probe)
        let answer = scope.withManualFrame240<Int64>({ _ => UpdateResult.next() }, { manual =>
            var scopeRefused = false
            try { scope.retireInternalFrames() } catch (_: Exception) { scopeRefused = true }
            @Expect(scopeRefused, true)
            let state = ManualFrameObservation240()
            let _ = manual.draw({ _ =>
                try { let _ = manual.update(Event.Message("reentrant")) }
                catch (_: Exception) { state.actionRefused = true }
            })
            @Expect(state.actionRefused, true)
            1
        })
        @Expect(answer, 1)
        scope.retireInternalFrames()
        @Expect(probe.asyncRetired && probe.internalRetired, true)
    }
}
