package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func boundaryBudgetEventRejected(detail: AgentValue): Bool {
    try { let _ = contextBoundaryBudgetEventUsage(detail); false } catch (_: Exception) { true }
}

@Test
class ContextBoundaryBudgetEventTests {
    @TestCase
    func typedAndPublicEventDetailsPreserveEveryOriginalAccountingDimension(): Unit {
        let expected = ExecutionUsage(turns: 3, modelRequests: 4, drainModelRequests: 1,
            toolCalls: 9, activeTools: 0, inputTokens: 31, outputTokens: 17, costMicros: 11)
        let typed = eventDetail(AgentEventPayload.BudgetUpdated(expected))
        let event = AgentEvent(EventMeta(1, TraceId("budget-regression"), RunId("budget-regression-run"),
            occurredAtMillis: 1), AgentEventPayload.BudgetUpdated(expected))
        let protocol = eventProtocolDetail(event)
        @Expect(protocol.field("code").getOrThrow().text, "budget.updated")
        @Expect(canonicalAgentValue(contextBoundaryUsageValue(contextBoundaryBudgetEventUsage(typed))),
            canonicalAgentValue(contextBoundaryUsageValue(expected)))
        @Expect(canonicalAgentValue(contextBoundaryUsageValue(contextBoundaryBudgetEventUsage(protocol))),
            canonicalAgentValue(contextBoundaryUsageValue(expected)))
    }

    @TestCase
    func wrongDiscriminatorAndExtraFieldsNeverBecomeBudgetFacts(): Unit {
        let expected = contextBoundaryUsageValue(ExecutionUsage(toolCalls: 2))
        for (code in ["budget", "budget.signal", "", "budget.updated.extra"]) {
            let wrong = parseUnifiedJson(stringifyUnifiedJson(expected))
            wrong.put("code", textValue(code))
            @Expect(boundaryBudgetEventRejected(wrong))
        }
        let extra = parseUnifiedJson(stringifyUnifiedJson(expected))
        extra.put("code", textValue("budget.updated"))
        extra.put("permission", boolValue(true))
        @Expect(boundaryBudgetEventRejected(extra))
    }

    @TestCase
    func missingAndNoncanonicalAccountingDimensionsRemainRejected(): Unit {
        let missing = objectValue([ValueField("code", textValue("budget.updated"))])
        @Expect(boundaryBudgetEventRejected(missing))
        let wrong = contextBoundaryUsageValue(ExecutionUsage(toolCalls: 2))
        wrong.put("code", textValue("budget.updated"))
        wrong.put("tool_calls", textValue("2"))
        @Expect(boundaryBudgetEventRejected(wrong))
        let negative = contextBoundaryUsageValue(ExecutionUsage(toolCalls: 2))
        negative.put("code", textValue("budget.updated"))
        negative.put("tool_calls", integerValue(-1))
        @Expect(boundaryBudgetEventRejected(negative))
    }
}
