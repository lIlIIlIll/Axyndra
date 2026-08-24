package agent_tui

import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class StreamingTranscriptTests {
    @TestCase
    func appendTextKeepsRewriteEpochUntilBodyReplacement(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(
            snapshot,
            UiEvent.AppendText("assistant-stream", UiCardKind.Assistant, "Assistant", "first")
        )
        @Assert(snapshot.cards.size, 1)
        let card = snapshot.cards[0]
        let initialEpoch = card.bodyRewriteEpoch
        let initialRevision = card.contentRevision

        UiReducer.reduce(
            snapshot,
            UiEvent.AppendText("assistant-stream", UiCardKind.Assistant, "Assistant", " second")
        )
        @Expect(card.body, "first second")
        @Expect(card.bodyRewriteEpoch, initialEpoch)
        @Expect(card.contentRevision, initialRevision + 1)

        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard(
                "assistant-stream",
                UiCardKind.Assistant,
                "Assistant",
                "replacement",
                "streaming",
                false,
                ""
            )
        )
        @Expect(card.body, "replacement")
        @Expect(card.bodyRewriteEpoch, initialEpoch + 1)
    }

    @TestCase
    func transcriptSourceGenerationChangesForSnapshotAndThemeInvalidation(): Unit {
        let source = AgentTranscriptSource(UiSnapshot(), { _, _, _ => Document([]) })
        @Expect(source.generation(), 0)

        source.setSnapshot(UiSnapshot())
        @Expect(source.generation(), 1)

        source.invalidateGeneration()
        @Expect(source.generation(), 2)
    }

    @TestCase
    func transcriptSourceOffersFastTextOnlyForVisibleStreamingCards(): Unit {
        let snapshot = UiSnapshot()
        UiReducer.reduce(
            snapshot,
            UiEvent.AppendText("fast-assistant", UiCardKind.Assistant, "Assistant", "plain **stream**")
        )
        let source = AgentTranscriptSource(snapshot, { _, _, _ => Document([]) })

        match (source.itemAppendOnlyText(0, 12, "omp")) {
            case Some(value) =>
                @Expect(value.text, "plain **stream**")
                @Expect(value.wrapWidth, 10)
                @Expect(value.appendEpoch, snapshot.cards[0].bodyRewriteEpoch)
            case None => @Fail("visible assistant stream must use append-only text layout")
        }

        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard(
                "fast-assistant",
                UiCardKind.Assistant,
                "Assistant",
                "plain **stream**",
                "completed",
                false,
                ""
            )
        )
        @Expect(source.itemAppendOnlyText(0, 12, "omp").isNone())

        UiReducer.reduce(
            snapshot,
            UiEvent.UpsertCard(
                "hidden-reasoning",
                UiCardKind.Reasoning,
                "Thinking",
                "hidden",
                "streaming",
                true,
                ""
            )
        )
        @Expect(source.itemAppendOnlyText(1, 12, "omp").isNone())
    }
}
