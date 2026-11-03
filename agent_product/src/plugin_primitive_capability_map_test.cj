package agent_product

import agent_domain.*
import agent_plugin_registry
import agent_store.*
import tool_runtime.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func primitiveMapValue111(catalog:String,list:String,receive:String):AgentValue {
    objectValue([ValueField("catalog",textValue(catalog)),ValueField("services",objectValue([
        ValueField("peer.list",textValue(list)),ValueField("peer.receive",textValue(receive))]))])
}
private func primitiveMapSelection111(f:WorkflowChildFixture111,value:AgentValue):AgentValue {
    objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
        ValueField("namespace",textValue(f.namespace)),ValueField("package_digest",textValue(f.digest)),
        ValueField("tools",listValue([objectValue([ValueField("name",textValue("hub")),ValueField("profile",textValue("frozen-primitives-v1")),
            ValueField("services",listValue([textValue("peer.list"),textValue("peer.receive")])),
            ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",value)])]))])]))])
}
private func primitiveMapInstall111(f:WorkflowChildFixture111,value:AgentValue):Unit {
    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
    File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(primitiveMapSelection111(f,value)).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace,true).isOk())
}
private func primitiveMapCall111(f:WorkflowChildFixture111,id:String,op:String):ToolCall {
    ToolCall(id,"plugin."+f.namespace+".hub",objectValue([ValueField("op",textValue(op))]))
}
private func primitiveMapRefused111(value:Result<ToolInvocationResult>):Unit {
    match(value){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
        case Result.Ok(ToolInvocationResult.Completed(result))=>try{@Expect(result.isError)}finally{result.releasePayload()}
        case _=>@Expect(false)}
}

@Test
class InstalledPrimitiveInvocationMapTests111 {
    @TestCase
    func catalogVisibilityAndActualCallsRetainAllSixOriginalRoleCapabilities():Unit {
        let f=WorkflowChildFixture111(mode:ApprovalMode.Write);let token=CancellationSource()
        try {
            primitiveMapInstall111(f,primitiveMapValue111("workspace.read","workspace.read","workspace.read"))
            for(name in ["task","scout","designer","reviewer","librarian","sonic"]){
                let role=lifecycleTestRequire(queryProductWorkflowRole(f.product,name,SessionId("map-role-"+name),token.token,"map-role-"+name))
                @Expect(role.pin.validateCurrent().isOk())
                let defs=f.product.toolsFor(role.ceiling)
                var visible=false
                for(def in defs where def.name=="plugin."+f.namespace+".hub"){visible=true}
                @Expect(visible)
                let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("map-role-"+name),role.ceiling,
                    primitiveMapCall111(f,"map-role-"+name,"list"),budget:f.budget()))
                try{@Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)}finally{result.releasePayload()}
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approvals"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),12)
            f.database.transaction{tx:SqliteTransaction=>for(row in tx.query("SELECT normalized_plan FROM operations")){
                let plan=decodeOperationPlan(row.required(0))
                @Expect(plan.requiredCapabilities.size,1);@Expect(plan.requiredCapabilities[0].kind,CapabilityKind.WorkspaceRead)
                @Expect(pluginPrimitiveInvocationName111(plan.canonicalArguments),"workspace.read")
            }}
        }finally{token.close();f.close()}
    }
    @TestCase
    func onlyTheFrozenServiceSelectsItsCapabilityAndPendingMapDriftCannotExecute():Unit {
        let f=WorkflowChildFixture111(mode:ApprovalMode.Write)
        let token=CancellationSource();let owner=ProductDirectPreparationOwner({=>token.token.check()})
        try {
            primitiveMapInstall111(f,primitiveMapValue111("workspace.read","workspace.read","extension.invoke"))
            let readonly=CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)])
            let listed=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("map-list"),readonly,
                primitiveMapCall111(f,"map-list","list"),budget:f.budget()))
            try{@Expect(!listed.isError)}finally{listed.releasePayload()}
            primitiveMapRefused111(f.product.vnext.executeCanonicalTool(SessionId("map-receive-denied"),readonly,
                primitiveMapCall111(f,"map-receive-denied","inbox"),budget:f.budget()))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
            let started=f.product.vnext.executeDeferredCanonicalTool(SessionId("map-receive-approval"),f.capabilities(delegate:false),
                primitiveMapCall111(f,"map-receive-approval","inbox"),owner,token.token,budget:f.budget())
            @Expect(match(started){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
            let pending=owner.approval().getOrThrow()
            File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(primitiveMapSelection111(f,
                primitiveMapValue111("workspace.read","workspace.read","workspace.read"))).toArray())
            primitiveMapRefused111(owner.decide(pending.operationId.value,ApprovalDecision.Approve))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),2)
        }finally{let _=token.cancel();let _=owner.cancel();token.close();f.close()}
    }
    @TestCase
    func incompleteExtraCrossServiceAndUnselectedCatalogMappingsCannotMount():Unit {
        for(mode in ["missing","extra","wrong","catalog","type"]){
            let f=WorkflowChildFixture111()
            try {
                @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
                let selection=if(mode=="missing"){objectValue([ValueField("catalog",textValue("workspace.read")),
                    ValueField("services",objectValue([ValueField("peer.list",textValue("workspace.read"))]))])}
                    else{primitiveMapValue111("workspace.read","workspace.read","workspace.read")}
                if(mode=="extra"){selection.field("services").getOrThrow().put("child.start",textValue("delegate"))}
                if(mode=="wrong"){selection.field("services").getOrThrow().put("peer.receive",textValue("delegate"))}
                if(mode=="catalog"){selection.put("catalog",textValue("peer.message"))}
                if(mode=="type"){selection.field("services").getOrThrow().put("peer.receive",integerValue(1))}
                File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(primitiveMapSelection111(f,selection)).toArray())
                @Expect(!f.product.setPluginEnabled(f.namespace,true).isOk())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
            }finally{f.close()}
        }
    }
}
