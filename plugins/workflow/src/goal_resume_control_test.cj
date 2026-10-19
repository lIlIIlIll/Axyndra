package workflow_plugin

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func goalResumeControlQuery(document: AgentValue): AgentValue {
    objectValue([ValueField("schema", textValue("axyndra.workflow-policy/v1")),
        ValueField("action", textValue("goal")), ValueField("source_digest", textValue("data-only")),
        ValueField("method", textValue("tool")), ValueField("session_id", textValue("resume-policy-data")),
        ValueField("arguments", objectValue([])), ValueField("document", document),
        ValueField("facts", objectValue([ValueField("now_millis", integerValue(3000)),
            ValueField("total_tokens", integerValue(22)), ValueField("proposed_goal_id", textValue("unused-on-resume"))]))])
}

@Test
class GoalResumeControlTests {
    @TestCase
    func explicitResumeCarriesTheExactCanonicalBoundedOrUnboundedBudget(): Unit {
        for (budget in [integerValue(1000), nullValue()]) {
            let old = goalLegacyMigrationFixture(); old.put("tokenBudget", budget)
            let before = canonicalAgentValue(old)
            let result = workflowGoalSlash(goalResumeControlQuery(old), "resume")
            let control = result.field("user_control").getOrThrow()
            @Expect(httpIntentText(control, "action"), "resume_or_create")
            @Expect(httpIntentText(control, "next_prompt"), "preserve history")
            @Expect(canonicalAgentValue(control.field("token_budget").getOrThrow()), canonicalAgentValue(budget))
            @Expect(canonicalAgentValue(old), before)
            @Expect(result.field("document").getOrThrow().field("tokensUsed").getOrThrow().asNumberText(), "123")
        }
    }
    @TestCase
    func MissingOrCompletedGoalCannotReturnAnyControlDescription(): Unit {
        for (document in [nullValue(), goalLegacyMigrationFixture()]) {
            if (document.unifiedKind != ValueKind.Null) { document.put("status", textValue("complete")) }
            let result = workflowGoalSlash(goalResumeControlQuery(document), "resume")
            @Expect(result.field("is_error").getOrThrow().asBool())
            @Expect(result.field("user_control").isNone())
        }
    }
}
