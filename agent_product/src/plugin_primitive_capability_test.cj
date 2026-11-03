package agent_product

import agent_domain.*
import agent_plugin_registry
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func primitiveCapabilitySelection111(f:WorkflowChildFixture111,hub:AgentValue,
    task!:String="extension.invoke",digest!:String=""):AgentValue {
    let taskEntry=objectValue([ValueField("name",textValue("task")),ValueField("profile",textValue("frozen-primitives-v1")),
        ValueField("services",listValue([textValue("child.start")])),ValueField("preparation_provider",textValue("prepare_child"))])
    if(task!="extension.invoke"){taskEntry.put("invocation_capability",textValue(task))}
    let hubEntry=objectValue([ValueField("name",textValue("hub")),ValueField("profile",textValue("frozen-primitives-v1")),
        ValueField("services",listValue([textValue("peer.list"),textValue("peer.receive")])),
        ValueField("preparation_provider",textValue("prepare_child")),ValueField("invocation_capability",hub)])
    objectValue([ValueField("version",integerValue(1)),ValueField("plugins",listValue([objectValue([
        ValueField("namespace",textValue(f.namespace)),ValueField("package_digest",textValue(if(digest==""){f.digest}else{digest})),
        ValueField("tools",listValue([taskEntry,hubEntry]))])]))])
}
private func primitiveCapabilityMount111(f:WorkflowChildFixture111,value:AgentValue):Unit {
    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
    File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(value).toArray())
    @Expect(f.product.setPluginEnabled(f.namespace,true).isOk())
}
private func primitiveCapabilityList111(f:WorkflowChildFixture111,id:String):ToolCall {
    ToolCall(id,"plugin."+f.namespace+".hub",objectValue([ValueField("op",textValue("list"))]))
}
private func primitiveCapabilityRefused111(value:Result<ToolInvocationResult>):Unit {
    match(value){case Result.Err(_)=>();case Result.Ok(ToolInvocationResult.Denied(_))=>()
        case Result.Ok(ToolInvocationResult.Completed(result))=>try{@Expect(result.isError)}finally{result.releasePayload()}
        case _=>@Expect(false)}
}
private func primitiveCapabilityPlan111(database:SqliteDatabase,tool:String,expected:String):Unit {
    database.transaction{tx:SqliteTransaction=>
        let rows=tx.query("SELECT o.normalized_plan FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id WHERE e.tool_id=?",[SqlParameter.Text(tool)])
        @Expect(rows.size>0)
        for(row in rows){let plan=decodeOperationPlan(row.required(0))
            @Expect(plan.requiredCapabilities.size,1)
            @Expect(pluginPrimitiveInvocationName111(plan.canonicalArguments),expected)
            @Expect(plan.requiredCapabilities[0].resource,"")
            @Expect(plan.requiredCapabilities[0].kind,if(expected=="workspace.read"){CapabilityKind.WorkspaceRead}else{CapabilityKind.Delegate})
        }
    }
}

@Test
class InstalledPrimitiveInvocationCapabilityTests111 {
    @TestCase
    func sixActualRolesUseInstalledReadonlyPeerToolWithoutAcquiringExtensionOrDelegate():Unit {
        for(name in ["task","scout","designer","reviewer","librarian","sonic"]){
            let f=WorkflowChildFixture111();let token=CancellationSource()
            try {
                primitiveCapabilityMount111(f,primitiveCapabilitySelection111(f,textValue("workspace.read")))
                let role=lifecycleTestRequire(queryProductWorkflowRole(f.product,name,SessionId("role-"+name),token.token,"actual-role-"+name))
                @Expect(role.ceiling.allows(CapabilityKind.WorkspaceRead))
                @Expect(role.ceiling.allows(CapabilityKind.ExtensionInvoke),name=="task")
                @Expect(role.ceiling.allows(CapabilityKind.Delegate),name=="task")
                @Expect(role.pin.validateCurrent().isOk())
                f.product.fixtureProbe.getOrThrow().enqueueToolCallReply("role-peer-call","plugin."+f.namespace+".hub",
                    objectValue([ValueField("op",textValue("list"))]))
                let call=ToolCall("role-parent","plugin."+f.namespace+".task",objectValue([
                    ValueField("agent",textValue(name)),ValueField("task",textValue("List the current peers, then finish."))]))
                let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("role-"+name),f.capabilities(),call,budget:f.budget()))
                try{@Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)}finally{result.releasePayload()}
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),2)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),2)
                primitiveCapabilityPlan111(f.database,"plugin."+f.namespace+".hub","workspace.read")
                let reduced=ArrayList<Capability>()
                for(cap in role.ceiling.values where cap.kind!=CapabilityKind.WorkspaceRead){reduced.add(cap)}
                let before=f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions")
                primitiveCapabilityRefused111(f.product.vnext.executeCanonicalTool(SessionId("role-denied-"+name),
                    CapabilitySet(values:reduced.toArray()),primitiveCapabilityList111(f,"role-denied"),budget:f.budget()))
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),before)
            }finally{token.close();f.close()}
        }
    }
    @TestCase
    func readonlyWriteAndAlwaysAskKeepOriginalNoPromptAndOneCapabilityInBothPlans():Unit {
        for(mode in [ApprovalMode.Write,ApprovalMode.AlwaysAsk]){
            let f=WorkflowChildFixture111(mode:mode)
            try {
                primitiveCapabilityMount111(f,primitiveCapabilitySelection111(f,textValue("workspace.read")))
                let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("readonly-mapped"),
                    CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),primitiveCapabilityList111(f,"mapped-list"),budget:f.budget()))
                try{@Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)}finally{result.releasePayload()}
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approvals"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),2)
                primitiveCapabilityPlan111(f.database,"plugin."+f.namespace+".hub","workspace.read")
                primitiveCapabilityPlan111(f.database,HOST_PLUGIN_CHILD_TOOL111,"workspace.read")
            }finally{f.close()}
        }
    }
    @TestCase
    func mappedDelegateStillNeedsRealAlwaysAskApprovalAndCannotGrantMissingDelegate():Unit {
        let f=WorkflowChildFixture111(mode:ApprovalMode.AlwaysAsk)
        let cancellation=CancellationSource();let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
        let caps=CapabilitySet(values:[Capability(CapabilityKind.Delegate),Capability(CapabilityKind.WorkspaceRead),Capability(CapabilityKind.PeerMessage)])
        try {
            primitiveCapabilityMount111(f,primitiveCapabilitySelection111(f,textValue("workspace.read"),task:"delegate"))
            primitiveCapabilityRefused111(f.product.vnext.executeCanonicalTool(SessionId("no-mapped-delegate"),
                CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),f.call("no-mapped-delegate"),budget:f.budget()))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            let started=f.product.vnext.executeDeferredCanonicalTool(SessionId("ask-mapped-delegate"),caps,
                f.call("ask-mapped-delegate"),owner,cancellation.token,budget:f.budget())
            @Expect(match(started){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            let pending=owner.approval().getOrThrow()
            let result=hostServiceEntryCompleted(owner.decide(pending.operationId.value,ApprovalDecision.Approve))
            try{@Expect(!result.isError);expectCanonicalReturnedReceipt(f.database,result)}finally{result.releasePayload()}
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),1)
            primitiveCapabilityPlan111(f.database,HOST_PLUGIN_CHILD_TOOL111,"delegate")
        }finally{let _=cancellation.cancel();let _=owner.cancel();cancellation.close();f.close()}
    }
    @TestCase
    func pendingMappedPlanRejectsProfileHashGenerationAndContributionChangesBeforeHandoff():Unit {
        for(mode in ["profile","hash","generation","contribution","disable"]){
            let f=WorkflowChildFixture111(mode:ApprovalMode.AlwaysAsk)
            let cancellation=CancellationSource();let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
            try {
                primitiveCapabilityMount111(f,primitiveCapabilitySelection111(f,textValue("workspace.read"),task:"delegate"))
                let started=f.product.vnext.executeDeferredCanonicalTool(SessionId("mapped-stale"),f.capabilities(),
                    f.call("mapped-stale"),owner,cancellation.token,budget:f.budget())
                @Expect(match(started){case Result.Ok(ToolInvocationResult.NeedsApproval(_))=>true;case _=>false})
                let pending=owner.approval().getOrThrow()
                if(mode=="generation" || mode=="disable"){
                    @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
                    if(mode=="generation"){@Expect(f.product.setPluginEnabled(f.namespace,true).isOk())}
                }else{
                    let next=primitiveCapabilitySelection111(f,textValue("workspace.read"),task:if(mode=="profile"){"extension.invoke"}else{"delegate"},
                        digest:if(mode=="hash"){"sha256:"+modelPolicySha256Text("another installed package")}else{""})
                    if(mode=="contribution"){next.field("plugins").getOrThrow().items[0].field("tools").getOrThrow().items[0].put("name",textValue("todo"))}
                    File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(next).toArray())
                }
                primitiveCapabilityRefused111(owner.decide(pending.operationId.value,ApprovalDecision.Approve))
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM runs"),1)
            }finally{let _=cancellation.cancel();let _=owner.cancel();cancellation.close();f.close()}
        }
    }
    @TestCase
    func unknownWrongKindAndNonTextOperatorCapabilitiesCannotMount():Unit {
        for(value in [textValue("unknown.permission"),textValue("delegate"),textValue("peer.message"),textValue("process.spawn"),nullValue(),boolValue(true)]){
            let f=WorkflowChildFixture111()
            try {
                @Expect(f.product.setPluginEnabled(f.namespace,false).isOk())
                File.writeTo(f.root+"/settings/plugins/primitives.json",encodeAgentValue(primitiveCapabilitySelection111(f,value)).toArray())
                @Expect(!f.product.setPluginEnabled(f.namespace,true).isOk())
                primitiveCapabilityRefused111(f.product.vnext.executeCanonicalTool(SessionId("invalid-operator"),
                    f.capabilities(),primitiveCapabilityList111(f,"invalid-operator"),budget:f.budget()))
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
            }finally{f.close()}
        }
    }
    @TestCase
    func ExactOperatorMappingDoesNotApplyToOtherContributionOrUnselectedPackage():Unit {
        let f=WorkflowChildFixture111()
        try {
            primitiveCapabilityMount111(f,primitiveCapabilitySelection111(f,textValue("workspace.read")))
            primitiveCapabilityRefused111(f.product.vnext.executeCanonicalTool(SessionId("not-selected-contribution"),
                CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("not-selected","plugin."+f.namespace+".todo",objectValue([ValueField("op",textValue("view"))])),budget:f.budget()))
            let source=nativePluginTestSource(f.root,command:"echo",tool:true)
            let record=match(f.product.importLocalPlugin(source)){case PluginRegistryResult.Ok(value)=>value
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
            let namespace=productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))
            @Expect(namespace!=f.namespace);@Expect(f.product.setPluginEnabled(namespace,true).isOk())
            primitiveCapabilityRefused111(f.product.vnext.executeCanonicalTool(SessionId("not-selected-package"),
                CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),ToolCall("not-selected-package","plugin."+namespace+".echo",objectValue([])),budget:f.budget()))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
        }finally{f.close()}
    }
    @TestCase
    func defaultSelectionStillRequiresExtensionAndRawInputCannotChooseInvocationCapability():Unit {
        let f=WorkflowChildFixture111()
        try {
            primitiveCapabilityMount111(f,primitiveCapabilitySelection111(f,textValue("extension.invoke")))
            for(injected in [false,true]){
                let input=objectValue([ValueField("op",textValue("list"))])
                if(injected){input.put("invocation_capability",textValue("workspace.read"))}
                primitiveCapabilityRefused111(f.product.vnext.executeCanonicalTool(SessionId("default-invoke"),
                    CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),ToolCall("default-call","plugin."+f.namespace+".hub",input),budget:f.budget()))
            }
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM audit_events WHERE kind='operation_execution_handoff'"),0)
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("default-allowed"),
                f.capabilities(delegate:false),primitiveCapabilityList111(f,"default-allowed"),budget:f.budget()))
            try{@Expect(!result.isError)}finally{result.releasePayload()}
            f.database.transaction{tx:SqliteTransaction=>
                for(row in tx.query("SELECT normalized_plan FROM operations WHERE state='committed'")){
                    let plan=decodeOperationPlan(row.required(0))
                    @Expect(plan.requiredCapabilities.size,2)
                    @Expect(pluginPrimitiveInvocationName111(plan.canonicalArguments),"extension.invoke")
                    @Expect((plan.canonicalArguments.field("host_plan") ?? plan.canonicalArguments).field("invocation_capability").isNone())
                }
            }
        }finally{f.close()}
    }
}
