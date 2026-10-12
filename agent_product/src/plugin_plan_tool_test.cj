package agent_product

import agent_plugin_registry

import agent_core.*
import agent_domain.*
import agent_sdk.*
import agent_store.*
import tool_runtime.*
import process4cj as plan_fixture_process
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func workflowPlanTestSelect(f: WorkflowRolesFixture): String {
    let name="plugin."+productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace))+".plan_write"
    File.writeTo(f.root+"/settings/plugins/policies.json",stringifyUnifiedJson(objectValue([
        ValueField("version",integerValue(1)),ValueField("bindings",objectValue([
            ValueField("workflow",objectValue([ValueField("namespace",textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("provider",textValue("propose")),ValueField("package_digest",textValue(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.ContentDigest)))),
                ValueField("plan_tool",textValue("plan_write"))]))]))])).toArray())
    name
}

func planDataOnlyFixtureSource(root: String, manifestProfile!: String = "data_only", readyProfile!: String = "data_only"): String {
    let source=root+"/data-only-plugin";Directory.create(source)
    let script=String.fromUtf8(File.readFrom(getVariable("AXYNDRA_DATA_ONLY_PLUGIN_FIXTURE").getOrThrow()))
    File.writeTo(source+"/main.py",script.replace("execution_profile='data_only'","execution_profile='"+readyProfile+"'").toArray())
    let mode=plan_fixture_process.runProcess(plan_fixture_process.ProcessCommand("/usr/bin/chmod",
        arguments:["700",source+"/main.py"],maxOutputBytes:4096))
    if(mode.status.code!=0){throw IllegalStateException("cannot set data-only fixture executable mode")}
    File.writeTo(source+"/axyndra.plugin.json",stringifyUnifiedJson(objectValue([
        ValueField("id",textValue("data-only-fixture")),ValueField("version",textValue("1.0.0")),
        ValueField("entry_kind",textValue("native-executable")),ValueField("entrypoint",textValue("main.py")),
        ValueField("sdk_range",textValue("[2.1.0,3.0.0)")),ValueField("protocol_range",textValue("axyndra-js-host-v2")),
        ValueField("capabilities",listValue([textValue("document.store")])),ValueField("contributions",listValue([
            objectValue([ValueField("kind",textValue("tool")),ValueField("name",textValue("probe")),
                ValueField("execution_profile",textValue(manifestProfile))])]))])).toArray())
    source
}

func planDataOnlyFixtureInstall(product: ProductRuntime, root: String): ProductPluginRecord {
    let source=planDataOnlyFixtureSource(root)
    let record=match(product.importLocalPlugin(source,PluginInstallScope.Workspace)){
        case PluginRegistryResult.Ok(value)=>value;case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
    match(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)),true,PluginInstallScope.Workspace)){
        case PluginRegistryResult.Ok(_)=>();case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
    record
}

@Test
class InstalledPlanToolTests {
    @TestCase
    func missingOptionalPackageKeepsActualUnknownRootAndNoStaticPlanTool(): Unit {
        let root=pluginContractTemp("plan-tool-missing");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        try {
            for(tool in product.tools()){@Expect(tool.name!="plan_write")}
            let session=product.applicationSession(sessionId:Some(SessionId("plan-missing")))
            @Expect(session.handle("/plan").isError());@Expect(session.workMode(),"none")
            let result=hostServiceEntryCompleted(product.vnext.executeCanonicalTool(SessionId("plan-unknown"),
                CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("unknown-plan","plan_write",objectValue([ValueField("content",textValue("cannot execute"))]))))
            try {@Expect(result.isError);@Expect(result.output.field("error").getOrThrow().text,"tool.not_found")}
            finally {result.releasePayload()}
            @Expect(database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='plan-unknown' AND state='failed'"),1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='user_message'"),1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM items WHERE kind='tool_call'"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_decisions"),0)
        } finally {database.close();product.close();remove(root,recursive:true)}
    }

    @TestCase
    func actualInstalledDataToolUsesOneReservedCanonicalRootAndNoDocumentAuthority(): Unit {
        let f=WorkflowRolesFixture();let name=workflowPlanTestSelect(f)
        let budget=ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1)
        try {
            var published=false
            for(tool in f.product.tools() where tool.name==name){
                published=true;@Expect(tool.inputSchema.field("properties").getOrThrow().field("content").getOrThrow().field("type").getOrThrow().text,"string")
                @Expect(tool.inputSchema.field("required").getOrThrow().items.size,1)
                @Expect(!tool.inputSchema.field("additionalProperties").getOrThrow().asBool())
            }
            @Expect(published)
            let result=hostServiceEntryCompleted(f.product.vnext.executeCanonicalTool(SessionId("plan-direct"),
                CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),
                ToolCall("actual-plan",name,objectValue([ValueField("content",textValue("  Goal: native plan 雪\nAcceptance: exact receipt  "))])),budget:budget))
            try {
                @Expect(!result.isError)
                @Expect(result.output.text,"Plan recorded for review. The user reviews it via /plan-review before execution.")
                expectCanonicalReturnedReceipt(f.database,result)
                expectCanonicalReservedRootResults(f.database,"plan-direct",1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='completed'"),1)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plugin_documents"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM model_decisions"),0)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.context.read'"),0)
                let args=lifecycleTestRequire(f.product.vnext.completedDataToolHistoryArguments(ThreadId("plan-direct"),result.receiptId,"actual-plan",name))
                @Expect(httpIntentText(args,"content"),"  Goal: native plan 雪\nAcceptance: exact receipt  ")
                @Expect(f.product.vnext.completedDataToolHistoryArguments(ThreadId("different-plan-thread"),
                    result.receiptId,"actual-plan",name).isError())
                @Expect(f.product.vnext.completedDataToolHistoryArguments(ThreadId("plan-direct"),
                    "invented-plan-receipt","actual-plan",name).isError())
                @Expect(f.product.vnext.completedDataToolHistoryArguments(ThreadId("plan-direct"),
                    result.receiptId,"different-actual-call",name).isError())
                @Expect(f.product.vnext.completedDataToolHistoryArguments(ThreadId("plan-direct"),
                    result.receiptId,"actual-plan",name,version:"wrong-instance",fingerprint:"wrong-package").isError())
            } finally {result.releasePayload()}
            @Expect(budget.snapshot().toolCalls,1);@Expect(budget.snapshot().activeTools,0)
        } finally {f.close()}
    }

    @TestCase
    func applicationUsesSelectedNativeContributionAndReceiptBoundCanonicalReview(): Unit {
        let f=WorkflowRolesFixture();let name=workflowPlanTestSelect(f)
        let events=ArrayList<AgentEvent>();let session=f.product.applicationSession(sessionId:Some(SessionId("plan-ui")))
        session.subscribe({event=>events.add(event)})
        try {
            let result=lifecycleTestRequire(session.handle("/plan fixture plan write"))
            @Expect(result.planReview.isSome());@Expect(result.planReview.getOrThrow().contains("Goal: ship a plan"))
            @Expect(session.workMode(),"plan");@Expect(session.allSubagents().isEmpty());@Expect(session.approval().isNone())
            var actualPlanUpdate=false
            for(event in events where httpIntentText(event.detail,"code")=="plan.updated"){
                actualPlanUpdate=true;@Expect(httpIntentText(event.detail,"body").contains("Acceptance: contract passes"))}
            @Expect(actualPlanUpdate)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id="+sqliteText(name)),1)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM plugin_documents"),0)
            let review=lifecycleTestRequire(session.handle("/plan-review"))
            @Expect(review.text,result.planReview.getOrThrow())
            let edited=lifecycleTestRequire(session.updateLatestPlan("","# Goal\n\nActual human edited plan"))
            @Expect(lifecycleTestRequire(session.handle("/plan-review")).text,edited)
            @Expect(session.updateLatestPlan("wrong-stale-hash","must fail").isError())
            let reopened=f.product.applicationSession(sessionId:Some(session.id()))
            @Expect(lifecycleTestRequire(reopened.handle("/plan-review")).text,edited)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM approvals"),0)
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            match(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),false,f.record.scope)){
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(_)=>()}
            @Expect(session.approveLatestPlan().isError());@Expect(session.workMode(),"plan")
            @Expect(lifecycleTestRequire(session.handle("/plan-review")).text,edited)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','waiting_approval','executing')"),0)
        } finally {session.cancel();f.close()}
    }

    @TestCase
    func dataOnlyActualProcessCannotUsePackageDocumentCapabilityOrRawServiceFallback(): Unit {
        let root=pluginContractTemp("data-only-service-denied");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        let budget=ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1)
        try {
            let record=planDataOnlyFixtureInstall(product,root)
            let name="plugin."+productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))+".probe"
            let result=hostServiceEntryCompleted(product.vnext.executeCanonicalTool(SessionId("data-only-service"),
                CapabilitySet(values:[Capability(CapabilityKind.WorkspaceRead)]),ToolCall("pure-probe",name,objectValue([])),budget:budget))
            try {
                @Expect(result.isError)
                @Expect(result.output.field("error").getOrThrow().text,"extension.service_unsupported")
                expectCanonicalReturnedReceipt(database,result)
            } finally {result.releasePayload()}
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"),1)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM derived_operation_admissions"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM plugin_documents"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_effect_records WHERE tool_id='host.context.read'"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
            @Expect(budget.snapshot().toolCalls,1);@Expect(budget.snapshot().activeTools,0)
        } finally {database.close();product.close();remove(root,recursive:true)}
    }

    @TestCase
    func unknownExecutionProfileNeverImportsOrPublishesAnyTool(): Unit {
        let root=pluginContractTemp("data-only-unknown-profile");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        try{
            let source=planDataOnlyFixtureSource(root,manifestProfile:"unknown-executor")
            match(product.importLocalPlugin(source,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Ok(_)=>throw IllegalStateException("unknown execution profile imported")
                case PluginRegistryResult.Err(_)=>()}
            @Expect(productRegistryRecords83(product.pluginSnapshots()).isEmpty())
            @Expect(product.vnext.publishedToolIdentity("plugin.axyndra:data-only-fixture.probe").isNone())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
        }finally{database.close();product.close();remove(root,recursive:true)}
    }

    @TestCase
    func actualReadyProfileCannotChangeTheInspectedManifestRestriction(): Unit {
        let root=pluginContractTemp("data-only-ready-mismatch");Directory.create(root+"/workspace",recursive:true)
        let product=workspacePluginOpen(root,ApprovalMode.Yolo);let database=SqliteDatabase(root+"/state/state.db")
        try{
            let source=planDataOnlyFixtureSource(root,readyProfile:"unknown-ready-profile")
            let record=match(product.importLocalPlugin(source,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(value)=>value}
            match(product.setPluginEnabled(productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace)),true,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Ok(_)=>throw IllegalStateException("ready profile mismatch published")
                case PluginRegistryResult.Err(_)=>()}
            @Expect(product.vnext.publishedToolIdentity("plugin."+productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))+".probe").isNone())
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operations"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM operation_receipts"),0)
            @Expect(database.scalarInt("SELECT COUNT(*) FROM model_attempts"),0)
        }finally{database.close();product.close();remove(root,recursive:true)}
    }
}
