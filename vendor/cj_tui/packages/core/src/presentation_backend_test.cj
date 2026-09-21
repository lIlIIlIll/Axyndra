package core

import std.unittest.*
import std.unittest.testmacro.*

func countPresentationToken(value: String, token: String): Int64 {
    if (token == "") {
        return 0
    }
    var count: Int64 = 0
    var offset: Int64 = 0
    while (offset <= value.size - token.size) {
        let remaining = value[offset..]
        if (remaining.startsWith(token)) {
            count++
            offset += token.size
        } else {
            offset++
        }
    }
    count
}

@Test
class PresentationBackendContractTest {
    @TestCase
    func historyBatchCopiesInputAndClampsAccess(): Unit {
        let lines = ["first", "second"]
        let batch = HistoryBatch(
            -4,
            HistoryBatchKind.Append,
            lines,
            startRow: -2
        )
        lines[0] = "changed"

        @Expect(batch.id, 0)
        @Expect(batch.startRow, 0)
        @Expect(batch.lineCount(), 2)
        @Expect(batch.line(0), "first")
        @Expect(batch.line(-1), "")
        @Expect(batch.line(9), "")
        @Expect(batch.lines()[1], "second")
    }

    @TestCase
    func terminalFrameWritesHistoryThroughOneTransport(): Unit {
        let output = TestOutput()
        let backend = AnsiBackend(
            output: output,
            fallbackArea: Rect(0, 0, 12, 2)
        )
        let terminal = Terminal(backend)
        let batch = HistoryBatch(
            7,
            HistoryBatchKind.Replay,
            ["old one", "old two"]
        )

        terminal.draw { frame =>
            renderHistoryBatch(batch, 0, frame)
            frame.canvas().drawText(
                0,
                0,
                "live",
                Style.default()
            )
        }

        let text = output.text()
        @Expect(text.contains("old one\r\nold two\r\n"), true)
        @Expect(text.contains("live"), true)
        @Expect(output.flushCalls, 1)
    }

    @TestCase
    func historyStartsAtBottomBeforeViewportRepaint(): Unit {
        let output = TestOutput()
        let backend = AnsiBackend(
            output: output,
            fallbackArea: Rect(0, 0, 12, 2)
        )
        let terminal = Terminal(backend)
        let batch = HistoryBatch(
            8,
            HistoryBatchKind.Append,
            ["old one", "old two"]
        )

        terminal.draw { frame =>
            renderHistoryBatch(batch, 0, frame)
            frame.canvas().drawText(0, 0, "live", Style.default())
        }

        @Expect(output.text().contains("\u{1B}[2;1Hold one\r\nold two\r\n"), true)
    }

    @TestCase
    func invalidationPreservesCursorVisibilityForNextHide(): Unit {
        let output = TestOutput()
        let backend = AnsiBackend(
            output: output,
            fallbackArea: Rect(0, 0, 12, 2)
        )
        let terminal = Terminal(backend)

        terminal.draw { frame =>
            frame.setCursor(Position(1, 0))
        }
        terminal.invalidate()
        terminal.draw { _ => () }

        @Expect(countPresentationToken(output.text(), "\u{1B}[?25l"), 1)
    }

    @TestCase
    func fullscreenModeTransitionsAreIdempotentAndRestored(): Unit {
        let output = TestOutput()
        let backend = AnsiBackend(
            output: output,
            fallbackArea: Rect(0, 0, 12, 2)
        )
        let presenter = PresentationBackend(backend)
        let session = TerminalSession(
            backend,
            rawMode: false,
            alternateScreen: false,
            mouse: false,
            bracketedPaste: false,
            hideCursor: false
        )
        presenter.bind(session)

        session.run {
            @Expect(presenter.sync(PresentationMode.Primary), false)
            @Expect(presenter.sync(PresentationMode.Fullscreen), true)
            @Expect(session.fullscreenActive, true)
            @Expect(session.alternateScreenActive, true)
            @Expect(session.mouseEnabled, true)
            @Expect(presenter.sync(PresentationMode.Fullscreen), false)
            @Expect(presenter.sync(PresentationMode.Primary), true)
            @Expect(session.fullscreenActive, false)
            @Expect(session.alternateScreenActive, false)
            @Expect(session.mouseEnabled, false)
        }

        let text = output.text()
        @Expect(countPresentationToken(text, "\u{1B}[?1049h"), 1)
        @Expect(countPresentationToken(text, "\u{1B}[?1049l"), 1)
        @Expect(countPresentationToken(text, "\u{1B}[?1000h"), 1)
        @Expect(countPresentationToken(text, "\u{1B}[?1000l"), 1)
    }
}
