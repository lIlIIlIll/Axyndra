package agent_tui

import core.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class TuiMailboxTests {
    @TestCase
    func adjacentStreamingEventsAreCoalesced(): Unit {
        let mailbox = TuiMailbox(capacity: 8)
        mailbox.push(TuiAgentEvent.TextDelta("one"))
        mailbox.push(TuiAgentEvent.TextDelta("two"))
        mailbox.push(TuiAgentEvent.ToolOutput("call", "a", false))
        mailbox.push(TuiAgentEvent.ToolOutput("call", "b", false))
        mailbox.push(TuiAgentEvent.Usage(1, 2))
        mailbox.push(TuiAgentEvent.Usage(3, 4))

        let events = mailbox.drain()
        @Expect(events.size, 3)
        match (events[0]) {
            case TuiAgentEvent.TextDelta(value) => @Expect(value, "onetwo")
            case _ => @Fail("expected coalesced text")
        }
        match (events[1]) {
            case TuiAgentEvent.ToolOutput(callId, value, stderr) =>
                @Expect(callId == "call" && value == "ab" && !stderr)
            case _ => @Fail("expected coalesced tool output")
        }
        match (events[2]) {
            case TuiAgentEvent.Usage(input, output) =>
                @Expect(input == 3 && output == 4)
            case _ => @Fail("expected latest usage")
        }
    }

    @TestCase
    func barriersPreserveStreamingOrder(): Unit {
        let mailbox = TuiMailbox(capacity: 8)
        mailbox.push(TuiAgentEvent.TextDelta("before"))
        mailbox.push(TuiAgentEvent.Warning("warning", "barrier"))
        mailbox.push(TuiAgentEvent.TextDelta("after"))

        let events = mailbox.drain()
        @Expect(events.size, 3)
        match (events[0]) {
            case TuiAgentEvent.TextDelta(value) => @Expect(value, "before")
            case _ => @Fail("expected leading text")
        }
        match (events[2]) {
            case TuiAgentEvent.TextDelta(value) => @Expect(value, "after")
            case _ => @Fail("expected trailing text")
        }
    }

    @TestCase
    func readyMarkerIsSingleFlightForProducerBurst(): Unit {
        let port = ExternalPort<Event>(capacity: 1)
        let mailbox = TuiMailbox(capacity: 8, ready: {=>
            _ = port.tryEnqueue(Event.Message("agent-external-ready"))
        })
        mailbox.push(TuiAgentEvent.TextDelta("one"))
        mailbox.push(TuiAgentEvent.TextDelta("two"))

        @Expect(mailbox.size(), 1)
        @Expect(port.size(), 1)
        @Expect(port.acceptedCount(), 1)
        @Expect(port.fullCount(), 0)
        @Expect(mailbox.drain().size, 1)
        port.close()
    }
}

@Test
class TuiTranscriptPagingTests {
    @TestCase
    func olderPagesPrependWithoutDuplicatingCommittedCards(): Unit {
        let current = UiSnapshot()
        UiReducer.reduce(current, UiEvent.UpsertCard(
            "item-3", UiCardKind.Assistant, "Assistant", "three", "completed", false, ""
        ))
        UiReducer.reduce(current, UiEvent.UpsertCard(
            "item-4", UiCardKind.Assistant, "Assistant", "four", "completed", false, ""
        ))
        current.inputTokens = 12

        let merged = prependTranscriptPage(
            current,
            TuiTranscriptPage(
                [
                    TuiTranscriptItem("item-1", UiCardKind.User, "You", "one"),
                    TuiTranscriptItem("item-3", UiCardKind.Assistant, "Assistant", "duplicate")
                ],
                1,
                false
            )
        )

        @Expect(merged.cards.size, 3)
        @Expect(merged.cards[0].id, "item-1")
        @Expect(merged.cards[1].id, "item-3")
        @Expect(merged.cards[2].id, "item-4")
        @Expect(merged.cards[1].body, "duplicate")
        @Expect(merged.inputTokens, 12)
    }
}
