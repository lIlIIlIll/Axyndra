package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class ScalarEstimateExecutor204 <: ToolExecutor {
    public func execute(_: ToolInvocationContext, _: PreparedToolInvocation): Result<ToolResult> {
        Result.Err(AgentError(AgentErrorKind.Protocol, "test.scalar_only", "scalar estimation cannot execute tools"))
    }
}
private class ScalarUnsupportedNumber204 <: JsonNode {
    public func kind(): JsonKind { JsonKind.Number }
    public func size(): Int64 { 0 }
    public func toString(): String { "unsupported" }
    public func toPrettyString(_: String): String { "unsupported" }
}
private class ScalarEarlyReturnNode204 <: JsonNode {
    private let scratch: ToolTokenScratch204
    var rejected = false
    init(scratch: ToolTokenScratch204) { this.scratch = scratch }
    public func kind(): JsonKind {
        try { scratch.returnWholeEstimate204() } catch (_: IllegalStateException) { rejected = true }
        JsonKind.Null
    }
    public func size(): Int64 { 0 }
    public func toString(): String { "null" }
    public func toPrettyString(_: String): String { "null" }
}
private func scalarEstimateSchema204(): AgentValue {
    objectValue([ValueField("q\"", listValue([textValue("雪\n"), boolValue(true), nullValue(),
        parseUnifiedJson("12.5"), objectValue([ValueField("é", textValue("a\\b"))])]))])
}
private func scalarScratchFrame204(scratch: ToolTokenScratch204, value: AgentValue): Int64 {
    estimateAgentValueTokensData204(value, scratch: Some(scratch))
}

@Test
class ToolTokenEstimate204Tests {
    @TestCase
    func escapedUnicodeNestedSchemaHasIndependentHandCount(): Unit {
        let schema = scalarEstimateSchema204()
        // q\" key:1; nested list:25; outer object:2+3+1+25=31.
        // read_a name:3; A \"é\" newline description:3; tool:18+3+3+31=55.
        @Expect(estimateAgentValueTokensData204(schema), 31)
        @Expect(estimateToolTokensData204("read_a", "A \"é\"\n", schema), 55)
        let definition = ModelToolDefinition("read_a", "A \"é\"\n", schema)
        @Expect(estimateContextTokens([], tools: [definition]), 63)
        let messages = [ModelMessage(ModelRole.User, [ModelBlock(ModelBlockKind.Text, text: "hi")])]
        // User message:8 + text block:6 + ceil(2/4)=1 =>15.
        @Expect(estimateContextTokens(messages, tools: [definition]), 78)
        @Expect(estimateContextTokensWithToolTokens204(messages, 55), 78)
        @Expect(stringifyUnifiedJson(schema).contains("\\n"), true)
        @Expect(stringifyUnifiedJson(schema).contains("\\\""), true)
    }
    @TestCase
    func closedCatalogScalarPreservesExactCapabilityAndVisibilitySelection(): Unit {
        let catalog = ToolCatalog(); let executor = ScalarEstimateExecutor204()
        @Expect(catalog.register(ToolDescriptor(ModelToolDefinition("read_a", "A \"é\"\n", scalarEstimateSchema204()),
            Capability(CapabilityKind.WorkspaceRead)), executor).isOk(), true)
        @Expect(catalog.register(ToolDescriptor(ModelToolDefinition("excluded_write", "", objectValue([])),
            Capability(CapabilityKind.WorkspaceWrite)), executor).isOk(), true)
        @Expect(catalog.register(ToolDescriptor(ModelToolDefinition("hidden_read", "", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), hostServiceOnly: true), executor).isOk(), true)
        @Expect(catalog.register(ToolDescriptor(ModelToolDefinition("control_read", "", objectValue([])),
            Capability(CapabilityKind.WorkspaceRead), controlOnly: true), executor).isOk(), true)
        @Expect(catalog.estimateDefinitionsTokens204(CapabilitySet(values: [Capability(CapabilityKind.WorkspaceRead)]), None), 55)
        @Expect(catalog.estimateDefinitionsTokens204(CapabilitySet(), None), 0)
        @Expect(catalog.actualTransientConsumersReturned204(), true)
    }
    @TestCase
    func unknownPublicScalarCannotBeAcknowledgedAsReturned(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let scratch = ToolTokenScratch204(bank.acquire(131072))
        var rejected = false
        try { let _ = scalarScratchFrame204(scratch, ScalarUnsupportedNumber204()) }
        catch (_: JsonException) { rejected = true }
        @Expect(rejected, true)
        var falseAck = false
        try { scratch.returnWholeEstimate204() } catch (_: IllegalStateException) { falseAck = true }
        @Expect(falseAck, true)
        @Expect(bank.usage()[1] > 0, true)
    }
    @TestCase
    func paidScratchTracksLiveDepthRatherThanCumulativeNodeCount(): Unit {
        let bank = LogicalJsonOwnerBudget(maximumCharged: 16777216)
        let payment = bank.acquire(131072); let scratch = ToolTokenScratch204(payment)
        @Expect(scalarScratchFrame204(scratch, listValue([boolValue(true)])), 4)
        let firstPeak = bank.usage()[1]
        let wide = listValue(Array<AgentValue>(4096, repeat: boolValue(true)))
        @Expect(scalarScratchFrame204(scratch, wide), 8194)
        @Expect(bank.usage()[1], firstPeak)
        // Arbitrarily long parsed numeric literals are borrowed by the pinned
        // JsonNode accessor; their token count must not be truncated to 512.
        let literal = String.fromUtf8(Array<Byte>(4096, repeat: b'1'))
        @Expect(scalarScratchFrame204(scratch, JsonNode.number(literal)), 1366)
        @Expect(bank.usage()[1], firstPeak)
        let early = ScalarEarlyReturnNode204(scratch)
        @Expect(scalarScratchFrame204(scratch, early), 1)
        @Expect(early.rejected, true)
        @Expect(bank.usage()[1], firstPeak)
        // The complete private scalar calls have returned before this ACK.
        scratch.returnWholeEstimate204()
        @Expect(bank.usage()[0], 0); @Expect(bank.usage()[1], 0)
    }
}
