package agent_product

import agent_plugin_registry
import agent_domain.*
import agent_store.*
import tool_runtime.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class WorkflowChildFixture111 {
    let root: String
    let product: ProductRuntime
    let database: SqliteDatabase
    let namespace: String
    let digest: String
    init(selected!: Bool = true, mode!: ApprovalMode = ApprovalMode.Yolo, asynchronous!: Bool = false, waitService!: Bool = false) {
        let root=pluginContractTemp("workflow-actual-child-111")
        if(!exists(Path(root))){Directory.create(root,recursive:true)}
        let product=lifecycleTestRequire(openProduct(config:ProductConfig(workspaceRoot:root,
            settingsRoot:root+"/settings",stateRoot:root+"/state",fixture:true,approvalMode:mode,asyncEnabled:asynchronous)))
        let record=match(product.importLocalPlugin(getVariable("AXYNDRA_WORKFLOW_PLUGIN_PACKAGE").getOrThrow())){
            case PluginRegistryResult.Ok(value)=>value;case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
        namespace=productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))
        digest=productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.ContentDigest))
        if(!exists(Path(root+"/settings/plugins"))){Directory.create(root+"/settings/plugins",recursive:true)}
        if(selected){File.writeTo(root+"/settings/plugins/primitives.json",stringifyUnifiedJson(objectValue([
            ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
                ValueField("namespace",textValue(namespace)),ValueField("package_digest",textValue(digest)),
                ValueField("tools",listValue([objectValue([ValueField("name",textValue("task")),
                    ValueField("profile",textValue("frozen-primitives-v1")),ValueField("services",listValue(if(waitService){[textValue("child.start"),textValue("child.wait")]}else{[textValue("child.start")]})),
                    ValueField("preparation_provider",textValue("prepare_child"))])]))])]))])).toArray())}
        File.writeTo(root+"/settings/plugins/policies.json",stringifyUnifiedJson(objectValue([
            ValueField("version",integerValue(1)),ValueField("bindings",objectValue([ValueField("workflow",objectValue([
                ValueField("namespace",textValue(namespace)),ValueField("provider",textValue("propose")),
                ValueField("package_digest",textValue(digest))]))]))])).toArray())
        match(product.setPluginEnabled(namespace,true)){
            case PluginRegistryResult.Ok(_)=>();case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
        this.root=root;this.product=product;database=SqliteDatabase(root+"/state/state.db")
    }
    func capabilities(delegate!: Bool=true):CapabilitySet{
        if(!delegate){return CapabilitySet(values:[Capability(CapabilityKind.ExtensionInvoke,resource:namespace),Capability(CapabilityKind.WorkspaceRead)])}
        CapabilitySet(values:[Capability(CapabilityKind.ExtensionInvoke,resource:namespace),Capability(CapabilityKind.Delegate),
            Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.PeerMessage)])
    }
    func call(thread:String, localTool!:String="task"):ToolCall{
        ToolCall(thread+"-call","plugin."+namespace+"."+localTool,objectValue([
            ValueField("agent",textValue("scout")),ValueField("task",textValue("Summarize this bounded child observation."))]))
    }
    func budget():ExecutionBudget{ExecutionBudget(maxToolCalls:12,maxConcurrentTools:1,maxChildren:1,maxConcurrentChildren:1,maxDepth:4)}
    func close():Unit{let _=product.close();database.close();remove(root,recursive:true)}
}

@Test
class InstalledWorkflowChildPilotTests111 {
    @TestCase
    func actualMixedPackageStartsOneCanonicalChildAndCompletesItsReservedReceipt():Unit{
        let f=WorkflowChildFixture111()
        try{
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("child-pilot"),
                f.capabilities(),f.call("child-pilot"),budget:f.budget()))
            try{
                @Expect(!result.isError)
                let rows=result.output.field("results").getOrThrow().items
                @Expect(rows.size,1);@Expect(httpIntentText(rows[0],"status"),"completed")
                @Expect(httpIntentText(rows[0],"runId")!="");@Expect(httpIntentText(rows[0],"sessionRef")!="child-pilot")
                @Expect(rows[0].field("exitCode").getOrThrow().asNumberText(),"0")
                expectCanonicalReturnedReceipt(f.database,result)
            }finally{result.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),2)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
            let restored=ProductTaskPersistence(f.database).loadAll()
            @Expect(restored.size,1);@Expect(restored[0].subagents.size,1)
            @Expect(restored[0].subagents[0].agentSource.startsWith("plugin:"+f.namespace+":"+f.digest+":"))
            @Expect(restored[0].subagents[0].pluginAdmission111.isNone())
        }finally{f.close()}
    }
    @TestCase
    func actualOperatorSelectionDoesNotGrantAnotherContributionOrMissingDelegate():Unit{
        for(mode in ["no-selection","no-delegate","other-tool"]){
            let f=WorkflowChildFixture111(selected:mode!="no-selection")
            try{
                let result=f.product.vnext.executeCanonicalTool(SessionId("child-refuse"),
                    f.capabilities(delegate:mode!="no-delegate"),f.call("child-refuse",localTool:if(mode=="other-tool"){"todo"}else{"task"}),budget:f.budget())
                match(result){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
                    case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                    case _=>@Expect(false)}
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            }finally{f.close()}
        }
    }
    @TestCase
    func actualFrozenApprovalCannotLaunchAfterPackageDisableOrSelectionRewrite():Unit{
        for(mode in ["disable","selection"]){
            let f=WorkflowChildFixture111(mode:ApprovalMode.AlwaysAsk)
            let cancellation=CancellationSource()
            let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
            try{
                let started=f.product.vnext.executeDeferredCanonicalTool(SessionId("child-wait"),f.capabilities(),
                    f.call("child-wait"),owner,cancellation.token,budget:f.budget())
                @Expect(match(started){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
                let pending=owner.approval().getOrThrow()
                if(mode=="disable"){@Expect(f.product.setPluginEnabled(f.namespace,false).isOk())}
                else{File.writeTo(f.root+"/settings/plugins/primitives.json","{\"version\":1,\"plugins\":[]}".toArray())}
                let resumed=owner.decide(pending.operationId.value,ApprovalDecision.Approve)
                match(resumed){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
                    case Result.Ok(ToolInvocationResult.Completed(value))=>try{@Expect(value.isError)}finally{value.releasePayload()}
                    case _=>@Expect(false)}
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
            }finally{let _=cancellation.cancel();let _=owner.cancel();cancellation.close();f.close()}
        }
    }
}

@Test
class InstalledWorkflowTaskParameterCompletion152Tests {
    @TestCase
    func fullOriginalParameterErrorsCommitOneCanonicalParentWithoutChildOrReplay152(): Unit {
        let f = WorkflowChildFixture111(waitService: true)
        let arguments = [objectValue([]), objectValue([ValueField("agent", textValue("missing")), ValueField("task", textValue(""))]),
            objectValue([ValueField("task", textValue("work")), ValueField("effort", textValue("bad"))]),
            objectValue([ValueField("context", textValue("parent")), ValueField("tasks", listValue([]))])]
        let messages = ["task is required", "unknown bundled agent: missing", "effort must be lo, med, or hi", "tasks must contain between 1 and 8 task items"]
        try {
            for (index in 0..arguments.size) {
                let thread = "task-parameter-canonical-" + index.toString()
                let beforeRuns = f.database.scalarInt("SELECT COUNT(*) FROM runs")
                let beforeOperations = f.database.scalarInt("SELECT COUNT(*) FROM operations")
                let beforeReceipts = f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts")
                let value = hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId(thread), f.capabilities(),
                    ToolCall(thread + "-call", "plugin." + f.namespace + ".task", arguments[index]), budget: f.budget()))
                try {
                    @Expect(value.isError)
                    @Expect(httpIntentExactFields(value.output, ["results", "error"]))
                    @Expect(value.output.field("results").getOrThrow().items.size, 0)
                    @Expect(httpIntentText(value.output, "error"), messages[index])
                    @Expect(value.payloadLease.isSome())
                    expectCanonicalReturnedReceipt(f.database, value)
                } finally { value.releasePayload() }
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"), beforeRuns + 1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"), beforeOperations + 1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"), beforeReceipts + 1)
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"), 0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"), 0)
            @Expect(ProductTaskPersistence(f.database).loadAll().size, 0)
        } finally { f.close() }
    }

    @TestCase
    func missingSelectionAndDisabledPackageNeverFallBackToBareTask152(): Unit {
        for (mode in ["missing", "disabled"]) {
            let f = WorkflowChildFixture111(selected: mode != "missing")
            try {
                if (mode == "disabled") { @Expect(f.product.setPluginEnabled(f.namespace, false).isOk()) }
                for (name in ["task", "plugin." + f.namespace + ".task"]) {
                    let attempted = f.product.vnext.executeCanonicalTool(SessionId("task-unavailable-" + mode), f.capabilities(),
                        ToolCall("task-unavailable-" + mode + "-" + name, name, objectValue([])), budget: f.budget())
                    match (attempted) {
                        case Result.Err(_) => ()
                        case Result.Ok(ToolInvocationResult.Denied(_)) => ()
                        case Result.Ok(ToolInvocationResult.Completed(value)) =>
                            try { @Expect(false) } finally { value.releasePayload() }
                        case _ => @Expect(false)
                    }
                }
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.child.start'"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"), 0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_attempts"), 0)
            } finally { f.close() }
        }
    }
}
