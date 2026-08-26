package axyndra_agent_testkit

import agent_sdk.*
import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PublicAgentTestkitTests {
    @TestCase
    func controlsTimeIdsCancellationAndDeadlineWithoutWallClock() {
        let clock = ManualClock(initialMillis: 10)
        let deadline = clock.deadlineAfter(5)
        @Expect(deadline.exceeded(clock.nowMillis()), false)
        @Expect(clock.advance(5), 15)
        @Expect(deadline.exceeded(clock.nowMillis()), true)
        @Expect(clock.setMillis(20), 20)

        let ids = SequenceIds(prefix: "fixture")
        @Expect(ids.next(scope: "call"), "fixture-call-1")
        @Expect(ids.next(scope: "operation"), "fixture-operation-2")

        let cancellation = ManualCancellation()
        @Expect(cancellation.cancel(reason: "stop"), true)
        @Expect(cancellation.cancel(reason: "again"), false)
        @Expect(cancellation.isCancelled(), true)
        @Expect(cancellation.reason(), "stop")
    }

    @TestCase
    func schedulesNamedFaultsDeterministically() {
        let plan = FaultPlan(rules: [
            FaultRule("before.persist", occurrence: 2),
            FaultRule("after.receipt", repeat: true)
        ])
        @Expect(plan.shouldFail("before.persist"), false)
        @Expect(plan.shouldFail("before.persist"), true)
        @Expect(plan.shouldFail("before.persist"), false)
        @Expect(plan.shouldFail("after.receipt"), true)
        @Expect(plan.shouldFail("after.receipt"), true)
        @Expect(plan.calls("before.persist"), 3)
    }

    @TestCase
    func exercisesExtensionContractWithoutExecutionAuthority() {
        let harness = ExtensionContractHarness(FixtureExtension())
        @Expect(harness.toolNames().size, 1)
        let prepared = requireSdkOk(harness.prepare(
            "fixture",
            jsonObject([JsonObjectEntry("value", jsonString("ok"))]),
            callId: "fixture-call"
        ))
        assertCapabilityRequested(prepared.definition, "workspace.read")
        let output = requireSdkOk(harness.decode(
            prepared,
            ExecutionResult(jsonObject([
                JsonObjectEntry("value", jsonString("done"))
            ]))
        ))
        @Expect(output.structured.field("value").getOrThrow().text, "done")
    }
}

class FixtureExtension <: Extension {
    public func metadata(): ExtensionMetadata {
        ExtensionMetadata("fixture.testkit", "Fixture", "1.0.0", "testkit fixture")
    }
    public func tools(): Array<ExtensionTool> { [FixtureTool()] }
}

class FixtureTool <: ExtensionTool {
    public func definition(): ExtensionToolDefinition {
        ExtensionToolDefinition(
            "fixture",
            "fixture tool",
            jsonObject([JsonObjectEntry("type", jsonString("object"))]),
            [workspaceRead()]
        )
    }
    public func validate(input: JsonNode): SdkResult<JsonNode> { SdkResult.Ok(input) }
    public func prepare(invocation: ToolInvocation): SdkResult<OperationIntent> {
        SdkResult.Ok(OperationIntent.HostOperation(HostOperationIntent("fixture", invocation.input)))
    }
    public func decode(
        _invocation: ToolInvocation,
        result: ExecutionResult
    ): SdkResult<ToolOutput> {
        let _ = _invocation
        SdkResult.Ok(ToolOutput(structured: result.value))
    }
}
