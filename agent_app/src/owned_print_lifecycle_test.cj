package agent_app

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

private func ownedPrintLifecycleFixture(pool: LogicalJsonOwnerBudget, kind: AgentEventKind,
    code: String): OwnedAgentEvent {
    let payment = pool.acquire(1); payment.ensureRetainedPeak(16777216)
    let root = OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("print-owned-item"), ThreadId("print-owned-thread"),
        SemanticTurnId("print-owned-turn"), 1,
        ThreadItemContent.SystemNote(String.fromUtf8(Array<Byte>(1048576, repeat: b'x'))), ItemProvenance("system")), payment)
    let alias = root.retainAliasCustody().value().getOrThrow()
    let event = OwnedAgentEvent(EventMeta(1, TraceId("print-owned-trace"), RunId("print-owned-run")),
        { item => match (item.content) {
            case ThreadItemContent.SystemNote(value) => AgentEventPayload.Extension(kind,
                objectValue([ValueField("code", textValue(code)), ValueField("output", textValue(value))]))
            case _ => throw IllegalStateException("full print control item missing") } }, alias)
    root.closeAfterConsumption().value().getOrThrow(); event
}

@Test
class OwnedPrintLifecycleTests {
    @TestCase
    func FullIgnoredToolPayloadAcknowledgesOnlyThisConcreteObserverAfterBorrowEnds(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let event = ownedPrintLifecycleFixture(pool, AgentEventKind.Tool, "tool.execution_completed")
        let other = event.fanout().value().getOrThrow()
        try {
            @Expect(ignoreOwnedPrintToolLifecycle(event).isOk(), true)
            @Expect(event.isAcknowledged(), true); @Expect(other.isAcknowledged(), false)
            @Expect(pool.usage()[1] >= 16777216, true)
            @Expect(other.withEvent(65536, { actual =>
                @Expect(actual.detail.field("output").getOrThrow().text.size, 1048576)
                Result<Unit>.Ok(()) }).isOk(), true)
        } finally { let _ = event.closeAfterEventRetirement(); let _ = other.closeAfterEventRetirement() }
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func ModelTextCodeCannotBeSilentlyConsumedByToolLifecycleNoop(): Unit {
        let pool = LogicalJsonOwnerBudget()
        let event = ownedPrintLifecycleFixture(pool, AgentEventKind.Tool, "model.text_delta")
        try {
            @Expect(ignoreOwnedPrintToolLifecycle(event).isOk(), false)
            @Expect(event.isAcknowledged(), false); @Expect(pool.usage()[1] >= 16777216, true)
        } finally { let _ = event.closeAfterEventRetirement() }
        @Expect(pool.usage()[1], 0)
    }
}
