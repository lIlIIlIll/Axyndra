package agent_tui

import std.unittest.*
import std.unittest.testmacro.*

@Test
class ToolOutputPreviewTests {
    @TestCase
    func shortTextIsPreserved(): Unit {
        let preview = boundedTerminalPreview("one\ntwo")

        @Expect(preview.text, "one\ntwo")
        @Expect(preview.sourceBytes, 7)
        @Expect(preview.omittedBytes, 0)
        @Expect(!preview.truncated)
    }

    @TestCase
    func hugeSingleLineHasAByteBoundedUtf8SafePrefix(): Unit {
        let huge = largeAsciiFixture(603445)
        let preview = boundedTerminalPreview(huge)

        @Expect(preview.truncated)
        @Expect(preview.sourceBytes, 603445)
        @Expect(preview.omittedBytes, 603445 - 1024)
        @Expect(preview.text.size < 1100)
        @Expect(preview.text.contains("602421 bytes omitted"))
    }

    @TestCase
    func truncationNeverSplitsUtf8(): Unit {
        let preview = boundedTerminalPreview("中文🙂tail", maximumBytes: 7, maximumLineBytes: 7)

        @Expect(preview.truncated)
        @Expect(preview.text.startsWith("中文"))
        @Expect(preview.text.contains("bytes omitted"))
    }

    @TestCase
    func reducerStopsRetainingStreamAfterThePreviewIsFull(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(snapshot, UiEvent.UpsertCard(
            "large-shell", UiCardKind.Tool, "Run fixture", "running", "running", false, ""
        ))
        UiReducer.reduce(snapshot, UiEvent.SetToolMetadata(
            "large-shell", "bash", "{\"command\":\"head fixture\"}", "call-large", ""
        ))
        UiReducer.reduce(snapshot, UiEvent.AppendToolOutput("large-shell", largeAsciiFixture(603445)))
        let retained = snapshot.cards[0].toolOutput
        UiReducer.reduce(snapshot, UiEvent.AppendToolOutput("large-shell", "later output"))

        @Expect(snapshot.cards[0].toolOutputTruncated)
        @Expect(retained.size < 1100)
        @Expect(snapshot.cards[0].toolOutput, retained)
        @Expect(!snapshot.cards[0].body.contains("later output"))
    }
}

private func largeAsciiFixture(size: Int64): String {
    var value = "x"
    while (value.size < size) {
        value += value
    }
    value[..size]
}
