package agent_domain

import yjson.*
import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class PluginDocumentLatestJournalStreamPlanTests {
    @TestCase
    func NewReadPlansRequireTheExactNamespaceCapabilityAndRetainTheFullPlanDigest():Unit{
        for(context in [false,true]){
            let request=latestViewDescriptorTestRequest(context)
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
            for(field in ["sql","path","grant","window","private_fence","group_key_path"]){
                let request=latestViewDescriptorTestRequest(context);request.put(field,textValue("caller selected"))
                @Expect(isContextReadPlan(documentReadTestPlan(request,Capability(CapabilityKind.WorkspaceRead))),false)
                @Expect(contextReadResourceRequiresApproval(request),true)
            }
            let wrong=latestViewDescriptorTestRequest(!context)
            wrong.put("schema",textValue(if(context){PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA}else{PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_READ_SCHEMA}))
            @Expect(isContextReadPlan(documentReadTestPlan(wrong,Capability(CapabilityKind.WorkspaceRead))),false)
        }
    }
}
