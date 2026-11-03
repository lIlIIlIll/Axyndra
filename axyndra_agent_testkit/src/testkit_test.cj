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
        let harness = NativePluginContractHarness(FixtureNativePlugin())
        @Expect(harness.contributionNames().size, 1)
        let prepared = requireSdkOk(harness.prepare("fixture",
            jsonObject([JsonObjectEntry("value", jsonString("done"))]), callId: "fixture-call"))
        assertCapabilityNotRequested(prepared.definition, "workspace.read")
        let output = requireSdkOk(harness.invoke(prepared))
        @Expect(output.field("value").getOrThrow().text, "done")
    }
}

class FixtureNativePlugin <: NativePluginHandler {
    public func definition(): NativePluginDefinition {
        NativePluginDefinition("fixture.testkit", "1.0.0",
            [PluginContributionDefinition("fixture", PluginContributionKind.Provider)])
    }
    public func validate(_kind: PluginContributionKind, _name: String, input: JsonNode): SdkResult<JsonNode> { SdkResult.Ok(input) }
    public func invoke(invocation: NativePluginInvocation): SdkResult<JsonNode> { SdkResult.Ok(invocation.input) }
}
