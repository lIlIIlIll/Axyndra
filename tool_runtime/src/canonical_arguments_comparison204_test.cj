package tool_runtime

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*
import yjson.*

private func canonicalComparisonProducer204(owner: ToolCanonicalArgumentsOwner204): Unit {
    owner.installProducerData204(objectValue([ValueField("value", textValue("original"))]))
}
private class UnsupportedComparisonNode204 <: JsonNode {
    public func kind(): JsonKind { JsonKind.Null }
    public func size(): Int64 { 0 }
    public func toString(): String { "null" }
    public func toPrettyString(_: String): String { "null" }
}

@Test
class CanonicalArgumentsComparison204Tests {
    @TestCase
    func equalityAndMismatchReturnOnlyTheirBooleanAndRetireTheActualCopy(): Unit {
        for (expected in ["original", "different"]) {
            let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
            let owner = ToolCanonicalArgumentsOwner204(root.deriveRetainedLease())
            canonicalComparisonProducer204(owner); owner.producerFrameReturned204(); root.close()
            let result = owner.matchesArguments204(objectValue([ValueField("value", textValue(expected))]))
            @Expect(result.isOk(), true); @Expect(result.value().getOrThrow(), expected == "original")
            @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
        }
    }
    @TestCase
    func comparisonCannotConsumeAnActiveProducer(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let owner = ToolCanonicalArgumentsOwner204(root.deriveRetainedLease())
        canonicalComparisonProducer204(owner)
        var rejected = false
        try { let _ = owner.matchesArguments204(objectValue([])) } catch (_: IllegalStateException) { rejected = true }
        @Expect(rejected, true); @Expect(bank.usage()[1] > 0, true)
        owner.producerFrameReturned204(); root.close()
        @Expect(owner.matchesArguments204(objectValue([])).value().getOrThrow(), false)
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
    @TestCase
    func unsupportedExpectedNodeKeepsTheOriginalReservationAfterException(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let owner = ToolCanonicalArgumentsOwner204(root.deriveRetainedLease())
        canonicalComparisonProducer204(owner); owner.producerFrameReturned204(); root.close()
        var rejected = false
        try { let _ = owner.matchesArguments204(UnsupportedComparisonNode204()) }
        catch (_: JsonException) { rejected = true }
        @Expect(rejected, true)
        @Expect(bank.usage()[1] > 0, true)
        var retryRejected = false
        try { let _ = owner.matchesArguments204(objectValue([])) }
        catch (_: IllegalStateException) { retryRejected = true }
        @Expect(retryRejected, true)
        @Expect(bank.usage()[1] > 0, true)
    }
    @TestCase
    func exportedProducerErrorKeepsItsOriginalDataReservation(): Unit {
        let bank = LogicalJsonOwnerBudget(); let root = bank.acquire(131072)
        let owner = ToolCanonicalArgumentsOwner204(root.deriveRetainedLease())
        owner.installProducerError204(AgentError(AgentErrorKind.Protocol, "fixture.actual_error", "producer error data"))
        owner.producerFrameReturned204(); root.close()
        let result = owner.matchesArguments204(objectValue([]))
        @Expect(result.error().getOrThrow().code, "fixture.actual_error")
        @Expect(bank.usage()[1] > 0, true)
    }
}
