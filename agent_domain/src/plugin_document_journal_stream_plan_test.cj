package agent_domain

import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginDocumentJournalStreamPlanTests {
    @TestCase
    func NewReadPlansRequireTheExactNamespaceCapabilityAndRetainTheFullPlanDigest():Unit{
        for(context in [false,true]){
            let request=journalStreamDescriptorTestRequest(context)
            let namespace=httpIntentText(request.field("binding").getOrThrow(),"namespace")
            let plan=documentReadTestPlan(request,Capability(CapabilityKind.ExtensionInvoke,resource:namespace))
            @Expect(isContextReadPlan(plan),true)
            @Expect(contextReadResourceRequiresApproval(request),false)
            let digest=contextReadPlanDigest(plan)
            request.put("access_policy_digest",textValue(modelPolicySha256Text("other frozen policy")))
            @Expect(contextReadPlanDigest(documentReadTestPlan(request,Capability(CapabilityKind.ExtensionInvoke,resource:namespace)))==digest,false)
            @Expect(isContextReadPlan(documentReadTestPlan(request,Capability(CapabilityKind.WorkspaceRead))),false)
            @Expect(isContextReadPlan(documentReadTestPlan(request,Capability(CapabilityKind.ExtensionInvoke,resource:"another"))),false)
        }
    }
    @TestCase
    func MalformedDeclaredStreamDialectsNeverFallBackToGenericWorkspaceRead():Unit{
        for(context in [false,true]){
            for(field in ["sql","path","grant","window"]){
                let request=journalStreamDescriptorTestRequest(context);request.put(field,textValue("caller selected"))
                @Expect(isContextReadPlan(documentReadTestPlan(request,Capability(CapabilityKind.WorkspaceRead))),false)
                @Expect(contextReadResourceRequiresApproval(request),true)
            }
            let wrong=journalStreamDescriptorTestRequest(!context)
            wrong.put("schema",textValue(if(context){PLUGIN_DOCUMENT_CONTEXT_JOURNAL_STREAM_READ_SCHEMA}else{PLUGIN_DOCUMENT_JOURNAL_STREAM_READ_SCHEMA}))
            @Expect(isContextReadPlan(documentReadTestPlan(wrong,Capability(CapabilityKind.WorkspaceRead))),false)
        }
    }
}
