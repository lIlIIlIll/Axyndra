package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func goalContextTestQuery(document:AgentValue,total!:Int64=100,now!:Int64=2000):AgentValue{
    let raw=stringifyUnifiedJson(document)
    objectValue([ValueField("schema",textValue("axyndra.goal-context-query/v1")),
        ValueField("_axyndra_context_provider",objectValue([ValueField("namespace",textValue("axyndra:workflow")),
            ValueField("package_digest",textValue("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
            ValueField("generation",textValue("1")),ValueField("provider",textValue("goal_context"))])),
        ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",textValue("axyndra.context-read-input/v1")),
            ValueField("facts",listValue([])),ValueField("data",objectValue([
                ValueField("schema",textValue("axyndra.plugin-document-read-result/v1")),
                ValueField("request_digest",textValue("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")),
                ValueField("documents",listValue([objectValue([ValueField("key",textValue("goal")),
                    ValueField("revision",integerValue(1)),ValueField("json",textValue(raw)),ValueField("sha256",textValue(modelPolicySha256Text(raw)))])])),
                ValueField("observation",objectValue([ValueField("schema",textValue("axyndra.document-observation/v1")),
                    ValueField("thread_id",textValue("actual-thread")),ValueField("run_id",textValue("actual-run")),
                    ValueField("observed_at_millis",integerValue(now)),ValueField("input_tokens",integerValue(total)),
                    ValueField("output_tokens",integerValue(0))]))]))]))])
}
func goalContextTestDocument(enabled!:Bool=true,budget!:Int64=50):AgentValue{
    encodeGoalState(WorkflowGoalState("goal-id","finish verified work","active",Some(budget),5,1,1000,1000,enabled,100,1000))
}
@Test
class NativeGoalContextTests{
    @TestCase
    func currentObservedUsageIsPureContentWithActualPublishedNameAndNoProposal(){
        let document=goalContextTestDocument();let original=canonicalAgentValue(document)
        let result=workflowGoalContext(goalContextTestQuery(document,total:110))
        @Expect(httpIntentExactFields(result,["schema","contributions"]))
        let row=result.field("contributions").getOrThrow().items[0]
        @Expect(httpIntentExactFields(row,["id","content","references"]))
        @Expect(workflowText(row,"content").contains("Tokens used: 15"))
        @Expect(workflowText(row,"content").contains("Call plugin.axyndra:workflow.goal with op=complete"))
        @Expect(canonicalAgentValue(document),original)
    }
    @TestCase
    func absenceAndDisabledDisplayCannotEmitAutonomousContent(){
        for(document in [nullValue(),goalContextTestDocument(enabled:false)]){
            @Expect(workflowGoalContext(goalContextTestQuery(document)).field("contributions").getOrThrow().items.size,0)}
    }
    @TestCase
    func observedBudgetExhaustionRefusesContentWithoutWritingTheOriginalDocument(){
        let document=goalContextTestDocument();let original=canonicalAgentValue(document)
        @Expect(workflowGoalContext(goalContextTestQuery(document,total:145)).field("contributions").getOrThrow().items.size,0)
        @Expect(canonicalAgentValue(document),original)
    }
    @TestCase
    func malformedHistoryAndChangedRawDigestCannotBecomeContent(){
        let query=goalContextTestQuery(goalContextTestDocument())
        query.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow().field("documents").getOrThrow().items[0].put("json",textValue("null"))
        var rejected=false
        try{let _=workflowGoalContext(query)}catch(_:Exception){rejected=true};@Expect(rejected)
        let malformed=goalContextTestDocument();malformed.put("tokensUsed",textValue("5"));rejected=false
        try{let _=workflowGoalContext(goalContextTestQuery(malformed))}catch(_:Exception){rejected=true};@Expect(rejected)
    }
    @TestCase
    func overflowUsageAndCallerControlFieldsRemainClosed(){
        let query=goalContextTestQuery(goalContextTestDocument(),total:9223372036854775807)
        query.field(CONTEXT_READ_INPUT_FIELD).getOrThrow().field("data").getOrThrow().field("observation").getOrThrow().put("output_tokens",integerValue(1))
        var rejected=false;try{let _=workflowGoalContext(query)}catch(_:Exception){rejected=true};@Expect(rejected)
        let control=goalContextTestQuery(goalContextTestDocument());control.put("user_control",objectValue([]));rejected=false
        try{let _=workflowGoalContext(control)}catch(_:Exception){rejected=true};@Expect(rejected)
    }
}
