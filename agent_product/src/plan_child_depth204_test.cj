package agent_product

import agent_core.*
import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Normal runtime budget boundaries, using the exact production guard. No IPC
// worker, alternate pool, fabricated source or completion witness is created.
@Test
class PlanChildDepth204Tests {
    @TestCase
    func defaultRuntimeDepthAcceptsFourAndRejectsFive(): Unit {
        let resource = ResourceBudget()
        let canonical = executionBudgetFrom(resource)
        @Expect(canonical.maxDepth, 4)
        @Expect(requirePluginChildDepth204(4, resource).isOk())
        match (requirePluginChildDepth204(5, resource)) {
            case Result.Err(error) =>
                @Expect(error.code, "subagent.budget_exceeded")
                @Expect(error.kind, AgentErrorKind.InvalidInput)
                @Expect(error.fields.isEmpty())
            case Result.Ok(_) => @Expect(false)
        }
    }

    @TestCase
    func actualChildRequestNeverWidensRoleBaseOrParentDepth(): Unit {
        for ((roleDepth, baseDepth, parentDepth, expected) in [
            (4, 4, 4, 4), (4, 4, 1, 1), (4, 2, 4, 2), (2, 4, 4, 2), (8, 8, 4, 4)]) {
            let limits = objectValue([
                ValueField("max_output_tokens", integerValue(8000)), ValueField("max_model_requests", integerValue(12)),
                ValueField("max_turns", integerValue(12)), ValueField("max_tool_calls", integerValue(24)),
                ValueField("max_wall_millis", integerValue(300000)), ValueField("max_idle_millis", integerValue(90000)),
                ValueField("max_children", integerValue(8)), ValueField("max_depth", integerValue(roleDepth)),
                ValueField("max_concurrent_children", integerValue(4))])
            let description = ProductPluginChildRequest111(objectValue([
                ValueField("prompt", textValue("observe the inherited depth ceiling")),
                ValueField("system_prompt", textValue("bounded role")), ValueField("cache_key", textValue("")),
                ValueField("capability_ceiling", listValue([])), ValueField("requested_limits", limits)]), ThinkingLevel.Medium)
            let base = AgentRunRequest(RunId("depth-budget-run"), SessionId("depth-budget-session"), "fixture", "bounded depth",
                budget: ResourceBudget(maxDepth: baseDepth))
            let child = productPluginChildRequest111(base, description, base.capabilities, ExecutionBudget(maxDepth: parentDepth))
            @Expect(child.budget.maxDepth, expected)
            @Expect(requirePluginChildDepth204(expected, child.budget).isOk())
            @Expect(requirePluginChildDepth204(expected + 1, child.budget).isError())
        }
    }
}
