package agent_product

import agent_plugin_registry

import agent_core.*
import agent_domain.*
import agent_store.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func readonlyQNameRejected(value: Result<ToolInvocationResult>): Bool {
    match(value){
        case Result.Err(_)=>true
        case Result.Ok(ToolInvocationResult.Completed(result))=>try{result.isError}finally{result.releasePayload()}
        case Result.Ok(ToolInvocationResult.Denied(_))=>true
        case _=>false}
}

// Used only by narrowing-predicate negative tests. Never admitted, written to
// SQL, executed, or used as a Source/approval/Receipt.
func readonlyQNamePlanWithCapabilities(plan:NormalizedOperationPlan,caps:Array<Capability>):NormalizedOperationPlan{
    NormalizedOperationPlan(plan.toolName,plan.canonicalArguments,caps,plan.effectClass,plan.retryDisposition,plan.bindingDigest,
        resolvedPaths:plan.resolvedPaths,resolvedHosts:plan.resolvedHosts,networkPolicy:Some(plan.networkPolicy),cwd:plan.cwd,
        relevantEnvironment:plan.relevantEnvironment,approvalMetadata:Some(plan.approvalMetadata),idempotencyKey:plan.idempotencyKey,
        replayDisposition:Some(plan.replayDisposition),toolVersion:plan.implementation.toolVersion,
        implementationFingerprint:plan.implementation.implementationFingerprint,schemaDigest:plan.implementation.schemaDigest,
        effectiveArgumentsDigest:plan.implementation.effectiveArgumentsDigest,replayContractVersion:plan.implementation.replayContractVersion,
        contextReadFacts:plan.contextReadFacts)
}

@Test
class ReadonlyQNameAuthorityTests {
    @TestCase
    func actualReadonlyCommittedProgramHasIndependentRootAndChildQNames():Unit{
        let f=ProgramDelegationFixture()
        try{
            let thread=SessionId("readonly-qname-committed")
            let request=f.product.request("Use the actual installed readonly Program.",sessionId:Some(thread),readOnly:true)
            let target="plugin."+productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace))+".read"
            @Expect(request.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:f.name))
            @Expect(request.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:target))
            @Expect(!request.capabilities.allows(CapabilityKind.ExtensionInvoke))
            for(cap in request.capabilities.values){@Expect(cap.kind==CapabilityKind.WorkspaceRead ||
                (cap.kind==CapabilityKind.ExtensionInvoke && cap.resource!=""))}
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("readonly-qname-call",f.name,f.input())
            let snapshot=match(f.product.client.start(request,{_=>()})){
                case Result.Ok(AgentRunOutcome.Completed(value))=>value
                case _=>throw IllegalStateException("actual readonly Program did not complete")}
            @Expect(snapshot.status,RunState.Completed);@Expect(f.children(thread.value),2)
            let rows=f.database.query("SELECT o.id,a.depth,e.tool_id,e.reserved_receipt_id,p.id,p.outcome,e.normalized_plan,o.normalized_plan "+
                "FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id "+
                "JOIN operation_receipts p ON p.operation_id=o.id LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id "+
                "WHERE r.thread_id=? ORDER BY COALESCE(a.depth,0)",[SqlParameter.Text(thread.value)])
            @Expect(rows.size,3)
            let store=DurableOperationStore(f.database)
            for(row in rows){@Expect(row.required(3),row.required(4));@Expect(row.required(5),"completed")
                @Expect(row.required(6),row.required(7))
                let plan=store.loadPlan(OperationId(row.required(0)),snapshot.runId).value().getOrThrow()
                for(cap in plan.requiredCapabilities){@Expect(request.capabilities.allows(cap.kind,resource:cap.resource))}}
            let root=store.loadPlan(OperationId(rows[0].required(0)),snapshot.runId).value().getOrThrow()
            let child=store.loadPlan(OperationId(rows[1].required(0)),snapshot.runId).value().getOrThrow()
            let leaf=store.loadPlan(OperationId(rows[2].required(0)),snapshot.runId).value().getOrThrow()
            @Expect(CapabilitySet(values:root.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke,resource:f.name))
            @Expect(CapabilitySet(values:root.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke,resource:target))
            @Expect(!CapabilitySet(values:root.requiredCapabilities).allows(CapabilityKind.ExtensionInvoke))
            @Expect(readonlyDelegationChildAllowed(root,child));@Expect(readViewServiceChildAllowed(child,leaf))
            @Expect(f.count(thread.value,"SELECT COUNT(*) FROM items WHERE thread_id=? AND kind='tool_call'"),1)
            @Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
        }finally{f.close()}
    }

    @TestCase
    func ownProgramQNameCannotGrantMissingOrForeignTargetQName():Unit{
        let f=ProgramDelegationFixture()
        try{
            let choices=[CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.ExtensionInvoke,resource:f.name)]),
                CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.ExtensionInvoke,resource:f.name),
                    Capability(CapabilityKind.ExtensionInvoke,resource:"plugin.axyndra:other.read")])]
            for(index in 0..choices.size){
                let thread="readonly-qname-missing-"+index.toString()
                @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId(thread),choices[index],
                    ToolCall(thread,f.name,f.input()),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))))
                @Expect(f.children(thread),0)
                @Expect(f.count(thread,"SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND p.outcome='completed'"),0)
            }
            @Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
        }finally{f.close()}
    }

    @TestCase
    func actualFrozenParentAndChildEachRequireTheirOwnExactResource():Unit{
        let f=ProgramDelegationFixture()
        try{
            let thread="readonly-qname-parent-intersection"
            let caps=f.product.request("Read only.",sessionId:Some(SessionId(thread)),readOnly:true).capabilities
            @Expect(!readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId(thread),caps,
                ToolCall(thread,f.name,f.input()),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))))
            let rows=f.database.query("SELECT o.id,o.run_id,a.depth FROM operations o JOIN runs r ON r.id=o.run_id "+
                "LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id WHERE r.thread_id=? ORDER BY COALESCE(a.depth,0)",
                [SqlParameter.Text(thread)])
            @Expect(rows.size,3);let store=DurableOperationStore(f.database);let run=RunId(rows[0].required(1))
            let parent=store.loadPlan(OperationId(rows[0].required(0)),run).value().getOrThrow()
            let child=store.loadPlan(OperationId(rows[1].required(0)),run).value().getOrThrow()
            let leaf=store.loadPlan(OperationId(rows[2].required(0)),run).value().getOrThrow()
            let ownOnly=readonlyQNamePlanWithCapabilities(parent,[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.ExtensionInvoke,resource:parent.toolName)])
            @Expect(!isFrozenReadonlyDelegationParentPlan(ownOnly));@Expect(!readonlyDelegationChildAllowed(ownOnly,child))
            for(resource in [parent.toolName,"plugin.axyndra:other.read"]){
                let wrongChild=readonlyQNamePlanWithCapabilities(child,[Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.ExtensionInvoke,resource:resource)])
                @Expect(!isFrozenReadViewParentPlan(wrongChild));@Expect(!readonlyDelegationChildAllowed(parent,wrongChild))
                @Expect(!readViewServiceChildAllowed(wrongChild,leaf))}
            let missing=readonlyQNamePlanWithCapabilities(child,[Capability(CapabilityKind.WorkspaceRead)])
            @Expect(!isFrozenReadViewParentPlan(missing));@Expect(!readonlyDelegationChildAllowed(parent,missing))
            @Expect(f.children(thread),2)
        }finally{f.close()}
    }

    @TestCase
    func actualWorkspaceWriteEditAndIndependentResourceWriteRemainDenied():Unit{
        let f=ProgramDelegationFixture()
        try{
            let thread="readonly-qname-effects"
            let caps=f.product.request("Read only.",sessionId:Some(SessionId(thread)),readOnly:true).capabilities
            let write="plugin."+productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace))+".write";let edit="plugin."+productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace))+".edit"
            for(name in [write,edit]){@Expect(!caps.allows(CapabilityKind.ExtensionInvoke,resource:name))}
            @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId(thread+"-write"),caps,ToolCall("write",write,
                objectValue([ValueField("path",textValue("new.txt")),ValueField("content",textValue("forbidden"))])),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))))
            @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId(thread+"-edit"),caps,ToolCall("edit",edit,
                objectValue([ValueField("input",textValue("[first.txt#F27C]\nSWAP 1:\n+forbidden"))])),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))))
            @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId(thread+"-resource"),caps,ToolCall("resource","write_resource",
                objectValue([ValueField("reference",textValue("file:"+f.root+"/workspace/first.txt")),ValueField("content",textValue("forbidden"))])),budget:ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1))))
            @Expect(!exists(Path(f.root+"/workspace/new.txt")));@Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
        }finally{f.close()}
    }

    @TestCase
    func actualConfigRevocationAndDisabledGenerationDoNotRestoreProjection():Unit{
        let f=ProgramDelegationFixture()
        try{
            let path=f.root+"/settings/plugins/services.json";let original=String.fromUtf8(File.readFrom(path))
            let caps=f.product.request("Read only.",sessionId:Some(SessionId("readonly-qname-before")),readOnly:true).capabilities
            let changed=parseUnifiedJson(original);changed.field("plugins").getOrThrow().items[0].put("tool_read_grants",listValue([]))
            File.writeTo(path,stringifyUnifiedJson(changed).toArray())
            let denied=f.product.request("Read only.",sessionId:Some(SessionId("readonly-qname-after")),readOnly:true).capabilities
            @Expect(!denied.allows(CapabilityKind.ExtensionInvoke,resource:f.name))
            let full=f.product.request("Full compatibility.",readOnly:false).capabilities
            @Expect(full.allows(CapabilityKind.ExtensionInvoke));@Expect(full.allows(CapabilityKind.WorkspaceWrite))
            @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId("readonly-qname-revoked"),caps,
                ToolCall("revoked",f.name,f.input()),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))))
            @Expect(f.children("readonly-qname-revoked"),0)
            File.writeTo(path,original.toArray())
            match(f.product.setPluginEnabled(productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace)),false,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(_)=>()}
            let inactive=f.product.request("Read only.",sessionId:Some(SessionId("readonly-qname-inactive")),readOnly:true).capabilities
            @Expect(!inactive.allows(CapabilityKind.ExtensionInvoke,resource:f.name))
            @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId("readonly-qname-disabled"),caps,
                ToolCall("disabled",f.name,f.input()),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))))
            @Expect(f.children("readonly-qname-disabled"),0)
        }finally{f.close()}
    }

    @TestCase
    func configuredWriteAndEditQNamesStillCannotPublishAFilePlan():Unit{
        for(target in ["write","edit"]){
            let f=ProgramDelegationFixture(target:target)
            try{
                let path=f.root+"/settings/plugins/services.json"
                let changed=parseUnifiedJson(String.fromUtf8(File.readFrom(path)))
                changed.field("plugins").getOrThrow().items[0].put("tool_read_grants",
                    listValue([textValue("read"),textValue("grep"),textValue("glob"),textValue(target)]))
                File.writeTo(path,stringifyUnifiedJson(changed).toArray())
                let thread="readonly-qname-misconfigured-"+target
                let caps=f.product.request("Read only.",sessionId:Some(SessionId(thread)),readOnly:true).capabilities
                let name="plugin."+productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace))+"."+target
                @Expect(caps.allows(CapabilityKind.ExtensionInvoke,resource:name))
                @Expect(caps.allows(CapabilityKind.ExtensionInvoke,resource:f.name))
                @Expect(!caps.allows(CapabilityKind.WorkspaceWrite));@Expect(!caps.allows(CapabilityKind.ExtensionInvoke))
                let input=if(target=="write"){
                    objectValue([ValueField("path",textValue("unapplied.txt")),ValueField("content",textValue("forbidden"))])
                }else{objectValue([ValueField("input",textValue("[first.txt#F27C]\nSWAP 1:\n+forbidden"))])}
                let result=f.completed(f.product.vnext.executeCanonicalTool(SessionId(thread),caps,
                    ToolCall(thread,name,input),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1)))
                try{
                    @Expect(result.isError);@Expect(result.output.field("application_plan").isNone())
                    @Expect(httpIntentText(result.output,"error"),"read_view.service_denied")
                }finally{result.releasePayload()}
                @Expect(f.count(thread,"SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND p.outcome='failed' AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)"),1)
                @Expect(f.count(thread,"SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id=? AND p.outcome='completed' AND e.tool_id='host.process.readview'"),1)
                @Expect(f.count(thread,"SELECT COUNT(*) FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND e.tool_id='host.file.plan.propose'"),0)
                // The independent delegated target must still be validated as a
                // readonly child, not inherit the Program's own QName authority.
                let delegated=thread+"-delegated"
                let code=if(target=="write"){ "return await tools.read({\"path\":\"unapplied.txt\",\"content\":\"forbidden\"});" }
                    else{ "return await tools.read({\"input\":\"[first.txt#F27C]\\nSWAP 1:\\n+forbidden\"});" }
                @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId(delegated),caps,
                    ToolCall(delegated,f.name,f.input(code:code)),budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))))
                @Expect(f.count(delegated,"SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND p.outcome='completed' AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions a WHERE a.operation_id=o.id)"),0)
                @Expect(f.count(delegated,"SELECT COUNT(*) FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND e.tool_id='host.file.plan.propose'"),0)
                @Expect(!exists(Path(f.root+"/workspace/unapplied.txt")));@Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
            }finally{f.close()}
        }
    }

    @TestCase
    func actualReadyGenerationDriftRefusesTheExistingReadonlyApproval():Unit{
        let f=ProgramDelegationFixture(mode:ApprovalMode.Write)
        let thread=SessionId("readonly-qname-ready-drift")
        let request=f.product.request("Read only through the actual Program.",sessionId:Some(thread),readOnly:true)
        try{
            f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("readonly-qname-ready-call",f.name,f.input())
            let approval=match(f.product.client.start(request,{_=>()})){
                case Result.Ok(AgentRunOutcome.AwaitingApproval(_,value))=>value
                case _=>throw IllegalStateException("actual readonly approval was not retained")}
            @Expect(approval.toolName,f.name);@Expect(f.children(thread.value),0)
            let plan=DurableOperationStore(f.database).loadPlan(approval.operationId,request.runId).value().getOrThrow()
            let frozen=plan.canonicalArguments.field("host_plan").getOrThrow().field("tools").getOrThrow().items[0]
            let generation=f.product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace)))
            @Expect(httpIntentText(frozen,"generation"),generation.toString())
            for(enabled in [false,true]){
                match(f.product.setPluginEnabled(productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace)),enabled,PluginInstallScope.Workspace)){
                    case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(_)=>()}}
            let current=f.product.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(f.workspace.descriptor.copyText(PluginDescriptorText.Namespace)))
            @Expect(current!=0u64 && current!=generation)
            let now=f.product.request("Read only after genuine re-enable.",sessionId:Some(SessionId(thread.value+"-new")),readOnly:true)
            @Expect(now.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:f.name))
            let _=f.product.client.decide(request,approval,ApprovalDecision.Approve,{_=>()})
            @Expect(f.children(thread.value),0)
            @Expect(f.count(thread.value,"SELECT COUNT(*) FROM operation_receipts p JOIN operations o ON o.id=p.operation_id JOIN runs r ON r.id=o.run_id WHERE r.thread_id=? AND p.outcome='completed'"),0)
            @Expect(String.fromUtf8(File.readFrom(f.root+"/workspace/first.txt")),"before\n")
        }finally{let _=f.product.client.cancel(request.runId);f.close()}
    }

    @TestCase
    func actualPrivateDocumentNamespaceWriteIsNotAReadonlyQNameGrant():Unit{
        let f=WorkflowDocumentFixture(provider:"prepare_document",payload:true)
        try{
            let thread="readonly-qname-private-document"
            let caps=f.product.request("Read only.",sessionId:Some(SessionId(thread)),readOnly:true).capabilities
            @Expect(!caps.allows(CapabilityKind.ExtensionInvoke,resource:productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))))
            @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId(thread),caps,ToolCall("document",f.tool,
                objectValue([ValueField("op",textValue("init")),ValueField("items",listValue([textValue("must not persist")]))])),
                budget:ExecutionBudget(maxToolCalls:3,maxConcurrentTools:1))))
            @Expect(f.snapshot(thread).encoded,"null")
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plugin_documents"),0)
        }finally{f.close()}
    }

    @TestCase
    func actualChannelHttpAndForeignThreadEndpointsDoNotEnterReadonlyProjection():Unit{
        let channel=McpProductFixture()
        try{
            let thread="readonly-qname-channel";@Expect(!readonlyQNameRejected(channel.start(thread)))
            let caps=channel.product.request("Read only.",sessionId:Some(SessionId(thread)),readOnly:true).capabilities
            @Expect(!caps.allows(CapabilityKind.ExtensionInvoke,resource:channel.name));let before=channel.calls()
            @Expect(readonlyQNameRejected(channel.call(thread,"readonly-channel-call",capabilities:caps)))
            @Expect(channel.calls(),before)
            var foreignVisible=false
            for(tool in channel.product.toolsFor(productCapabilities(),threadId:Some(ThreadId(thread+"-foreign"))) where tool.name==channel.name){foreignVisible=true}
            @Expect(!foreignVisible)
            @Expect(readonlyQNameRejected(channel.call(thread+"-foreign","readonly-foreign-call",capabilities:productCapabilities())))
            @Expect(channel.calls(),before)
        }finally{channel.close()}
        let http=McpHttpProductFixture()
        try{
            let thread="readonly-qname-http";@Expect(!readonlyQNameRejected(http.start(thread)))
            let caps=http.product.request("Read only.",sessionId:Some(SessionId(thread)),readOnly:true).capabilities
            @Expect(!caps.allows(CapabilityKind.ExtensionInvoke,resource:http.name));@Expect(!caps.allows(CapabilityKind.NetworkAccess))
            let before=http.calls()
            @Expect(readonlyQNameRejected(http.product.vnext.executeCanonicalTool(SessionId(thread),caps,
                ToolCall("readonly-http-call",http.name,objectValue([])),budget:ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1))))
            @Expect(http.calls(),before)
        }finally{http.close()}
    }

    @TestCase
    func actualReadyJavaScriptToolKeepsFullCompatibilityButReadonlyCannotInvokeIt():Unit{
        let f=ProgramDelegationFixture()
        try{
            let source=f.root+"/readonly-js";Directory.create(source,recursive:true)
            File.writeTo(source+"/package.json","{\"name\":\"readonly-qname-js\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[\"probe.js\"]}}".toArray())
            File.writeTo(source+"/probe.js",("import { Type } from 'typebox';\n"+
                "export default function(pi){pi.registerTool({name:'probe',label:'Probe',description:'Actual readonly projection negative',parameters:Type.Object({}),execute:async()=>({content:[{type:'text',text:'ready'}],details:{}})});}\n").toArray())
            let record=match(f.product.importLocalPlugin(source,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(value)=>value}
            match(f.product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)),true,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(_)=>()}
            @Expect(record.descriptor.entryKind,PluginEntryKind.JavaScript)
            let name="plugin."+productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))+".probe"
            @Expect(f.product.vnext.javascriptPlugins.toolNames(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))).contains("probe"))
            @Expect(!readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId("readonly-qname-js-full"),
                f.product.request("Full compatibility.",readOnly:false).capabilities,ToolCall("js-full",name,objectValue([])),
                budget:ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1))))
            let caps=f.product.request("Read only.",sessionId:Some(SessionId("readonly-qname-js-denied")),readOnly:true).capabilities
            @Expect(!caps.allows(CapabilityKind.ExtensionInvoke,resource:name))
            @Expect(readonlyQNameRejected(f.product.vnext.executeCanonicalTool(SessionId("readonly-qname-js-denied"),caps,
                ToolCall("js-denied",name,objectValue([])),budget:ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1))))
            @Expect(f.count("readonly-qname-js-denied","SELECT COUNT(*) FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_receipts p ON p.operation_id=o.id WHERE r.thread_id=? AND p.outcome='completed'"),0)
        }finally{f.close()}
    }
}
