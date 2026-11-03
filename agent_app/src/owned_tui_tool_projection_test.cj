package agent_app

import agent_domain.*
import agent_runtime.*
import agent_tui.*
import yjson.*
import yjson_support.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func ownedTuiProjectionFixture(pool: LogicalJsonOwnerBudget, bytes: Int64, started: Bool,
    numeric!: Bool = false): OwnedAgentEvent {
    let row = pool.acquire(bytes); row.ensureRetainedPeak(bytes * 8 + 1048576)
    let text = String.fromUtf8(Array<Byte>(bytes, repeat: if (numeric) { b'1' } else { 0u8 }))
    let root = OwnedCanonicalThreadItemCustody(ThreadItem(ItemId("tui-owned-item"), ThreadId("tui-owned-thread"),
        SemanticTurnId("tui-owned-turn"), 1, ThreadItemContent.SystemNote(text), ItemProvenance("system")), row)
    let alias = root.retainAliasCustody().value().getOrThrow()
    let event = OwnedAgentEvent(EventMeta(1, TraceId("tui-owned-trace"), RunId("tui-owned-run")),
        {item => match (item.content) {
            case ThreadItemContent.SystemNote(value) => AgentEventPayload.Extension(AgentEventKind.Tool, objectValue([
                ValueField("code", textValue(if (started) { "tool.execution_started" } else { "tool.execution_completed" })),
                ValueField("name", textValue("generic")), ValueField("call_id", textValue("tui-call")),
                ValueField(if (started) { "arguments" } else { "output" }, if (numeric) { numberValue(value) } else { textValue(value) })
            ]))
            case _ => throw IllegalStateException("actual original row required") } }, alias)
    @Expect(root.closeAfterConsumption().isOk(), true)
    event
}

private class OwnedTuiTestRegistration { var count: Int64 = 0 }

@Test
class OwnedTuiProjectionTests {
    @TestCase
    func CompleteOriginalEightMiBResultCanRetireWhileItsRealCopiedDisplayRemainsPaid(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = ownedTuiProjectionFixture(pool, 8388608, false)
        let adopted = ArrayList<OwnedTuiToolDisplay>()
        let copy = copyOwnedTuiToolEvent(source, {value => adopted.add(value)}).value().getOrThrow()
        @Expect(adopted.size, 1); @Expect(source.isAcknowledged(), false)
        @Expect(source.closeAfterEventRetirement().isOk(), true)
        @Expect(pool.usage()[1] > 0 && pool.usage()[1] < 8388608, true)
        @Expect(copy.withCopiedEvent({event =>
            @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), false)
            match (event) {
                case TuiAgentEvent.ToolCompletedWithId(name, id, failed, completion) =>
                    @Expect(name, "generic"); @Expect(id, "tui-call"); @Expect(failed, false)
                    @Expect(completion.detailPreview.size < 6600, true)
                    @Expect(completion.detailPreview.contains("8387584 bytes omitted"), true)
                    @Expect(completion.previewTruncated, true)
                case _ => @Fail("actual copied completion required") }
            Result.Ok(()) }).isOk(), true)
        @Expect(copy.isAcknowledged(), false)
        adopted.clear(); @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), true)
        @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func RealToolStartedUsesSamePaidOriginalArgumentLoanAndBoundedActualCopy(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = ownedTuiProjectionFixture(pool, 3145728, true)
        let copy = copyOwnedTuiToolEvent(source, {_ => ()}).value().getOrThrow()
        @Expect(source.closeAfterEventRetirement().isOk(), true)
        @Expect(copy.withCopiedEvent({event =>
            match (event) {
                case TuiAgentEvent.ToolStartedWithId(_, _, arguments) =>
                    @Expect(arguments.size < 6600, true)
                    @Expect(arguments.contains("3144704 bytes omitted"), true)
                case _ => @Fail("actual copied start required") }
            Result.Ok(()) }).isOk(), true)
        @Expect(pool.usage()[1] > 0, true)
        @Expect(copy.closeAfterCopiedDisplayRetirement().isOk(), true); @Expect(pool.usage()[1], 0)
    }
    @TestCase
    func CompleteNumberInvoiceRejectsOriginalBankPressureBeforeRegisterOrScalarCopy(): Unit {
        let pool = LogicalJsonOwnerBudget(); let source = ownedTuiProjectionFixture(pool, 1048576, false, numeric: true)
        let pressure = ArrayList<LogicalJsonOwnerReservation>()
        for (_ in 0..6) { pressure.add(pool.acquire(1)) }
        let registration = OwnedTuiTestRegistration()
        @Expect(copyOwnedTuiToolEvent(source, {_ => registration.count++}).isOk(), false)
        @Expect(registration.count, 0); @Expect(source.isAcknowledged(), false)
        @Expect(source.closeAfterEventRetirement().isOk(), true)
        for (value in pressure) { value.close() }; pressure.clear(); @Expect(pool.usage()[1], 0)
    }
}
