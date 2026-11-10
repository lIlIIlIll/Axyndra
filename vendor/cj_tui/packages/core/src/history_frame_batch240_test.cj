package core

import std.unittest.*
import std.unittest.testmacro.*

private func expectedHistoryFrame240(backend: Backend, area: Rect): Unit {
    let buffer = Buffer(area)
    let frame = Frame(area, buffer)
    frame.canvas().drawText(0, 0, "viewport", Style.default())
    backend.moveTo(area.x, area.y + max(0, area.height - 1))
    backend.write("\u{1B}[2K")
    backend.drawFrame("history界\r\n", buffer, Some(Position(2, 1)), false)
}

@Test
class HistoryFrameBatch240Tests {
    @TestCase
    func ansiHistoryAndCursorPreserveBytesInOneActualOutputWrite(): Unit {
        let area = Rect(0, 0, 8, 2)
        let expected = TestOutput()
        expectedHistoryFrame240(AnsiBackend(output: expected,
            driver: FallbackTerminalDriver(area: area)), area)
        for (presented in [false, true]) {
            let output = TestOutput()
            let ansi = AnsiBackend(output: output, driver: FallbackTerminalDriver(area: area))
            let backend: Backend = if (presented) { PresentationBackend(ansi) } else { ansi }
            let terminal = Terminal(backend)
            let _ = terminal.draw({ frame =>
                frame.writeRaw("history界\r\n")
                frame.canvas().drawText(0, 0, "viewport", Style.default())
                frame.setCursor(Position(2, 1))
            })
            @Expect(output.text(), expected.text())
            @Expect(output.writeCalls, 1)
            @Expect(output.flushCalls, 1)
        }
    }
    @TestCase
    func genericBackendKeepsItsOriginalPositionPrefixAndCursorBehavior(): Unit {
        let area = Rect(0, 0, 8, 2)
        let expected = TestBackend(area: area)
        expectedHistoryFrame240(expected, area)
        let actual = TestBackend(area: area)
        let terminal = Terminal(actual)
        let _ = terminal.draw({ frame =>
            frame.writeRaw("history界\r\n")
            frame.canvas().drawText(0, 0, "viewport", Style.default())
            frame.setCursor(Position(2, 1))
        })
        @Expect(actual.output(), expected.output())
        @Expect(actual.snapshot(), expected.snapshot())
    }
}
