package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.{PluginEntryKind}
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Actual installed independent Native package, original Host read-view worker,
// real SQLite/Root/Derived/Receipt and same-owner frontend ACK. Configuration
// data only selects the explicit operator recipe; it creates no Source/grant.
class NativeReadonlyShellProductFixture {
    let files=LifecycleConfigurationFixture()
    let product:ProductRuntime
    let record:ProductPluginRecord
    let database:SqliteDatabase
    init(approval!:ApprovalMode=ApprovalMode.Yolo, granted!:Bool=true, finite!:Bool=true) {
        let actualFiles=files
        let opened=lifecycleTestRequire(openProduct(config:ProductConfig(workspaceRoot:actualFiles.workspace,
            settingsRoot:actualFiles.settings,stateRoot:actualFiles.root+"/state",fixture:true,approvalMode:approval)))
        var db:?SqliteDatabase=None
        try {
            let installed=match(opened.importLocalPlugin(getVariable("AXYNDRA_SHELL_READONLY_PLUGIN_PACKAGE").getOrThrow(),PluginInstallScope.Workspace)){
                case PluginRegistryResult.Ok(value)=>value
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}
            if(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace))!="axyndra:shell-readonly" || installed.descriptor.entryKind!=PluginEntryKind.NativeExecutable){
                throw IllegalStateException("actual standalone readonly Shell package required")}
            let grant=objectValue([ValueField("kind",textValue("tool")),ValueField("name",textValue("exec")),
                ValueField("effect",textValue("read_only")),ValueField("services",listValue([textValue("process.readview")]))])
            let plugin=objectValue([ValueField("namespace",textValue(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("package_digest",textValue(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.ContentDigest)))),ValueField("configuration",objectValue([])),
                ValueField("requests",listValue([])),ValueField("credentials",listValue([])),
                ValueField("tool_read_grants",listValue(if(granted){[grant]}else{[]})),
                ValueField("read_view_parameter_references",listValue([textValue("exec")])),
                ValueField("read_view_parameter_contexts",listValue(if(granted){[textValue("exec")]}else{[]})),
                ValueField("tool_payload_limits",listValue([OrdinaryToolPayloadLimits("exec",maxInputBytes:229376,
                    maxResultBytes:1048576,maxServiceResponseBytes:262144,maxMessageBytes:1056768).value()]))])
            if(finite){plugin.put("read_view_deadlines",listValue([objectValue([
                ValueField("contribution",textValue("exec")),ValueField("maximum_ms",integerValue(600000))])]))
                plugin.put("protocol_limits",objectValue([ValueField("max_frame_bytes",integerValue(524288)),
                    ValueField("max_input_bytes",integerValue(16384)),ValueField("max_prepare_bytes",integerValue(131072)),
                    ValueField("max_result_bytes",integerValue(262144)),ValueField("max_directory_bytes",integerValue(65536)),
                    ValueField("max_tools",integerValue(64)),ValueField("call_timeout_ms",integerValue(600000))]))}
            File.writeTo(actualFiles.settings+"/plugins/services.json",stringifyUnifiedJson(objectValue([
                ValueField("version",integerValue(1)),ValueField("plugins",listValue([plugin]))])).toArray())
            File.writeTo(actualFiles.settings+"/plugins/shell-readonly-tools.json",stringifyUnifiedJson(objectValue([
                ValueField("schema",textValue("axyndra.shell-readonly-tools/v1")),ValueField("namespace",textValue(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)))),
                ValueField("package_digest",textValue(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.ContentDigest))))])).toArray())
            match(opened.setPluginEnabled(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)),true,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(_)=>()}
            if(opened.vnext.javascriptPlugins.instanceGeneration(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace)))==0u64 ||
                !opened.vnext.javascriptPlugins.toolNames(productRegistryCopyText83(installed.descriptor.copyText(PluginDescriptorText.Namespace))).contains("exec")){
                throw IllegalStateException("actual readonly Native ready publication required")}
            let actualDb=SqliteDatabase(actualFiles.root+"/state/state.db");db=Some(actualDb)
            this.product=opened;this.record=installed;this.database=actualDb
        }catch(error:Exception){
            let _=opened.close();match(db){case Some(value)=>value.close();case None=>()}
            actualFiles.close();throw error}
    }
    prop name:String {get(){"plugin."+productRegistryCopyText83(record.descriptor.copyText(PluginDescriptorText.Namespace))+".exec"}}
    func input(command:String, millis!:Int64=30000):AgentValue {objectValue([
        ValueField("command",textValue(command)),ValueField("timeout_ms",integerValue(millis))])}
    func invoke(thread:String,input:AgentValue,budget!:ExecutionBudget=ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1)):ProductNativeToolInvocation {
        lifecycleTestRequire(product.invokeShellTool(SessionId(thread),input,readOnly:true,budget:budget))}
    func count(thread:String,sql:String):Int64 {
        database.readTransaction<Int64>({transaction=>
            let rows=transaction.query(sql,[SqlParameter.Text(thread)])
            if(rows.size!=1 || rows[0].size<1){throw IllegalStateException("actual bound count returned no scalar row")}
            Int64.parse(rows[0].required(0))})
    }
    func workerHandoffs(thread:String):Int64 {count(thread,"SELECT COUNT(*) FROM audit_events a JOIN operations o ON o.id=a.operation_id "+
        "JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id=? "+
        "AND e.tool_id='host.process.readview' AND a.kind='operation_execution_handoff'")}
    func requireRootAndWorker(thread:String,receipt:String):Unit {
        let rows=database.query("SELECT o.id,o.run_id,e.tool_id,e.reserved_receipt_id,p.id,p.outcome,o.normalized_plan,e.normalized_plan,"+
            "a.parent_operation_id,a.root_operation_id,a.depth,a.child_call_id,o.tool_call_item_id,e.tool_call_item_id "+
            "FROM operations o JOIN runs r ON r.id=o.run_id JOIN operation_effect_records e ON e.operation_id=o.id "+
            "JOIN operation_receipts p ON p.operation_id=o.id LEFT JOIN derived_operation_admissions a ON a.operation_id=o.id "+
            "WHERE r.thread_id=? ORDER BY COALESCE(a.depth,0)",[SqlParameter.Text(thread)])
        if(rows.size!=2){throw IllegalStateException("two real direct Root/worker operations required")}
        let root=rows[0];let child=rows[1];let run=RunId(root.required(1));let store=DurableOperationStore(database)
        if(root.required(2)!=name || root.required(4)!=receipt || root[8].isSome() ||
            child.required(2)!=HOST_READ_VIEW_TOOL || child.required(8)!=root.required(0) ||
            child.required(9)!=root.required(0) || child.required(10)!="1"){
            throw IllegalStateException("actual Direct Root and real Derived worker provenance")}
        for(row in rows){
            if(row.required(3)!=row.required(4) || row.required(5)!="completed" || row.required(6)!=row.required(7) ||
                row.required(12)!=row.required(13)){throw IllegalStateException("actual reserved Receipt and exact canonical source")}
            let plan=store.loadPlan(OperationId(row.required(0)),run).value().getOrThrow()
            if(plan.effectClass!=OperationEffectClass.ReadOnly || !networkPolicyModeIsDenied(plan.networkPolicy.mode)){
                throw IllegalStateException("readonly/NetworkDenied is the actual admitted plan")}}
        let parent=store.loadPlan(OperationId(root.required(0)),run).value().getOrThrow()
        let leaf=store.loadPlan(OperationId(child.required(0)),run).value().getOrThrow()
        if(!isFrozenReadViewParentPlan(parent) || !readViewServiceChildAllowed(parent,leaf) ||
            store.loadCall(OperationId(child.required(0)),run).value().getOrThrow().callId!=child.required(11)){
            throw IllegalStateException("actual child call, exact ParentIntent and capability intersection")}
    }
    func close():Unit {
        let deadline=MonoTime.now()+Duration.second*10
        var acknowledged=false
        while(!acknowledged && MonoTime.now()<deadline){acknowledged=product.close().isOk()
            if(!acknowledged){sleep(Duration.millisecond*10)}}
        if(!acknowledged){throw IllegalStateException("actual readonly owner cleanup has not acknowledged")}
        database.close();files.close()
    }
}

@Test
class SelectedNativeReadonlyShellTests {
    @TestCase
    func actualReadonlyRootConsumesExactTwoCallsAndRetainsOutputUntilAck():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{File.writeTo(f.files.workspace+"/input.txt","readonly-sentinel".toArray())
            let budget=ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1)
            let actual=f.invoke("readonly-direct",f.input("cat input.txt"),budget:budget)
            try{let output=lifecycleTestRequire(actual.output());@Expect(output.field("stdout").getOrThrow().text,"readonly-sentinel")
                @Expect(output.field("exit_code").getOrThrow().asNumberText(),"0")
                @Expect(!output.field("timed_out").getOrThrow().asBool());@Expect(!output.field("truncated").getOrThrow().asBool())
                @Expect(actual.receiptId()!="");f.requireRootAndWorker("readonly-direct",actual.receiptId())
                @Expect(budget.snapshot().toolCalls,2);@Expect(budget.snapshot().activeTools,0)
                @Expect(f.workerHandoffs("readonly-direct"),1)
                @Expect(String.fromUtf8(File.readFrom(f.files.workspace+"/input.txt")),"readonly-sentinel")
            }finally{lifecycleTestRequire(actual.close())}
            @Expect(actual.output().isError())
        }finally{f.close()}
    }
    @TestCase
    func actualRootKeepsOriginal131072CaptureAndExplicitTruncation():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let actual=f.invoke("readonly-capture",f.input("printf '%0140000d' 0"))
            try{let output=lifecycleTestRequire(actual.output())
                @Expect(output.field("stdout").getOrThrow().text.size,131072)
                @Expect(output.field("stderr").getOrThrow().text,"")
                @Expect(output.field("truncated").getOrThrow().asBool());f.requireRootAndWorker("readonly-capture",actual.receiptId())
            }finally{lifecycleTestRequire(actual.close())}
        }finally{f.close()}
    }
    @TestCase
    func relativeCwdAndExplicitEnvironmentUseOnlyActualWorkspaceView():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{Directory.create(f.files.workspace+"/sub");File.writeTo(f.files.workspace+"/sub/input.txt","cwd-data".toArray())
            let input=f.input("printf '%s:' \"$SAMPLE\"; cat input.txt")
            input.put("cwd",textValue("sub"));input.put("env",objectValue([ValueField("SAMPLE",textValue("bound"))]))
            let actual=f.invoke("readonly-cwd",input)
            try{@Expect(lifecycleTestRequire(actual.output()).field("stdout").getOrThrow().text,"bound:cwd-data")
                f.requireRootAndWorker("readonly-cwd",actual.receiptId())
            }finally{lifecycleTestRequire(actual.close())}
        }finally{f.close()}
    }
    @TestCase
    func actualTimeout124PreservesPartialOutputAndFailedRootUntilSameOwnerAck():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let actual=f.invoke("readonly-timeout",f.input("printf partial; sleep 5",millis:100))
            try{@Expect(actual.output().isError())
                let observed=lifecycleTestRequire(actual.observedOutput())
                @Expect(observed.field("exit_code").getOrThrow().asNumberText(),"124")
                @Expect(observed.field("stdout").getOrThrow().text,"partial")
                @Expect(observed.field("timed_out").getOrThrow().asBool())
                @Expect(f.count("readonly-timeout","SELECT COUNT(*) FROM runs WHERE thread_id=? AND state='completed'"),0)
                @Expect(f.workerHandoffs("readonly-timeout"),1)
            }finally{lifecycleTestRequire(actual.close())}
            @Expect(actual.observedOutput().isError())
        }finally{f.close()}
    }
    @TestCase
    func explicitRootReviewAndWrongDecisionCannotBorrowStartupApproval():Unit {
        let f=NativeReadonlyShellProductFixture(approval:ApprovalMode.AlwaysAsk)
        try{let actual=f.invoke("readonly-review",f.input("printf reviewed"))
            try{let review=actual.approval().getOrThrow()
                @Expect(f.workerHandoffs("readonly-review"),0);@Expect(actual.decide("different-operation",ApprovalDecision.Approve).isError())
                @Expect(actual.approval().getOrThrow().operationId.value,review.operationId.value)
                lifecycleTestRequire(actual.decide(review.operationId.value,ApprovalDecision.Approve))
                @Expect(lifecycleTestRequire(actual.output()).field("stdout").getOrThrow().text,"reviewed")
                f.requireRootAndWorker("readonly-review",actual.receiptId())
            }finally{lifecycleTestRequire(actual.close())}
        }finally{f.close()}
    }
    @TestCase
    func currentConfigAndGenerationDriftRefuseExactAcquiredOwnerBeforeRoot():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let configOwner=lifecycleTestRequire(f.product.acquireShellToolInvocation(SessionId("readonly-config"),readOnly:true))
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations")
            let path=f.files.settings+"/plugins/services.json";let original=String.fromUtf8(File.readFrom(path))
            File.writeTo(path,(original+"\n").toArray())
            try{let failed=configOwner.start(f.input("printf forbidden"),ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1))
                @Expect(failed.isError());configOwner.recordFailure(failed.error().getOrThrow())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            }finally{lifecycleTestRequire(configOwner.close());File.writeTo(path,original.toArray())}
            let generationOwner=lifecycleTestRequire(f.product.acquireShellToolInvocation(SessionId("readonly-generation"),readOnly:true))
            try{match(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),false,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(_)=>()}
                let failed=generationOwner.start(f.input("printf forbidden"),ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1))
                @Expect(failed.isError());generationOwner.recordFailure(failed.error().getOrThrow())
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
            }finally{lifecycleTestRequire(generationOwner.close())}
        }finally{f.close()}
    }
    @TestCase
    func missingReadGrantAndDefaultSixtySecondProfileCannotAuthorizeWorker():Unit {
        let missing=NativeReadonlyShellProductFixture(granted:false)
        try{let before=missing.database.scalarInt("SELECT COUNT(*) FROM operations")
            @Expect(missing.product.invokeShellTool(SessionId("readonly-ungranted"),missing.input("printf forbidden"),readOnly:true).isError())
            @Expect(missing.database.scalarInt("SELECT COUNT(*) FROM operations"),before)
        }finally{missing.close()}
        let ordinary=NativeReadonlyShellProductFixture(finite:false)
        try{let actual=ordinary.invoke("readonly-default-profile",ordinary.input("printf forbidden",millis:600000))
            try{@Expect(actual.output().isError());@Expect(ordinary.workerHandoffs("readonly-default-profile"),0)}
            finally{lifecycleTestRequire(actual.close())}
        }finally{ordinary.close()}
    }
    @TestCase
    func malformedOversizedAndWritePolicyInputsNeverHandOffBusinessWorker():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let oversized=String.fromUtf8(Array<Byte>(131073,repeat:97u8))
            let inputs=[f.input(oversized),f.input("printf \u{0000}"),f.input("touch forbidden.txt"),f.input("printf forbidden > forbidden.txt"),
                f.input("printf forbidden",millis:600001)]
            for(index in 0..inputs.size){let thread="readonly-bad-"+index.toString();let actual=f.invoke(thread,inputs[index])
                try{@Expect(actual.output().isError());@Expect(f.workerHandoffs(thread),0)}finally{lifecycleTestRequire(actual.close())}}
            @Expect(!exists(Path(f.files.workspace+"/forbidden.txt")))
        }finally{f.close()}
    }
    @TestCase
    func workspaceSymlinkAndOutsideCwdCannotReadExternalData():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{File.writeTo(f.files.external+"/secret.txt","external-secret".toArray())
            SymbolicLink.create(f.files.workspace+"/escape",to:f.files.external)
            let input=f.input("cat secret.txt");input.put("cwd",textValue("escape"))
            let actual=f.invoke("readonly-symlink",input)
            try{@Expect(actual.output().isError());@Expect(f.workerHandoffs("readonly-symlink"),0)}finally{lifecycleTestRequire(actual.close())}
            remove(f.files.workspace+"/escape")
            let outside=f.input("cat secret.txt");outside.put("cwd",textValue("../external"))
            let refused=f.invoke("readonly-outside",outside)
            try{@Expect(refused.output().isError());@Expect(f.workerHandoffs("readonly-outside"),0)}finally{lifecycleTestRequire(refused.close())}
        }finally{f.close()}
    }
    @TestCase
    func cancellationBeforeStartDoesNotMintRootOrConsumeToolBudget():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let actual=lifecycleTestRequire(f.product.acquireShellToolInvocation(SessionId("readonly-pre-cancel"),readOnly:true))
            let before=f.database.scalarInt("SELECT COUNT(*) FROM operations");let budget=ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1)
            try{lifecycleTestRequire(actual.cancel());let failed=actual.start(f.input("printf forbidden"),budget)
                @Expect(failed.isError());actual.recordFailure(failed.error().getOrThrow())
                @Expect(actual.failure().getOrThrow().kind,AgentErrorKind.Cancelled)
                @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),before);@Expect(budget.snapshot().toolCalls,0)
            }finally{lifecycleTestRequire(actual.close())}
        }finally{f.close()}
    }
    @TestCase
    func planModeInspectionUsesSameActualThreadReadonlyQNamesAsModelRequest():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let thread=SessionId("readonly-plan-inspection")
            let application=f.product.applicationSession(sessionId:Some(thread))
            lifecycleTestRequire(application.handle("/plan"))
            let request=f.product.request("Read this workspace.",sessionId:Some(thread),readOnly:true)
            @Expect(request.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:f.name))
            @Expect(!request.capabilities.allows(CapabilityKind.ExtensionInvoke))
            @Expect(application.activeTools().any({tool=>tool.name==f.name}))
            @Expect(lifecycleTestRequire(application.handle("/tools")).text.contains(f.name))
            @Expect(!application.activeTools().any({tool=>["bash","bash_readonly","run_program"].contains(tool.name)}))
            match(f.product.setPluginEnabled(productRegistryCopyText83(f.record.descriptor.copyText(PluginDescriptorText.Namespace)),false,PluginInstallScope.Workspace)){
                case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code);case PluginRegistryResult.Ok(_)=>()}
            @Expect(!application.activeTools().any({tool=>tool.name==f.name}))
            @Expect(!f.product.request("Read only.",sessionId:Some(thread),readOnly:true).capabilities
                .allows(CapabilityKind.ExtensionInvoke,resource:f.name))
            @Expect(f.database.scalarInt("SELECT COUNT(*) FROM operations"),0)
        }finally{f.close()}
    }
    @TestCase
    func explicitSixHundredSecondProfileExecutesFastCommandWithoutSilentClamp():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let actual=f.invoke("readonly-finite-maximum",f.input("printf finite-maximum",millis:600000))
            try{@Expect(lifecycleTestRequire(actual.output()).field("stdout").getOrThrow().text,"finite-maximum")
                f.requireRootAndWorker("readonly-finite-maximum",actual.receiptId())
                let row=f.database.query("SELECT o.id,o.run_id FROM operations o JOIN runs r ON r.id=o.run_id "+
                    "JOIN operation_effect_records e ON e.operation_id=o.id WHERE r.thread_id=? AND e.tool_id=?",
                    [SqlParameter.Text("readonly-finite-maximum"),SqlParameter.Text(f.name)])
                @Expect(row.size,1)
                let plan=DurableOperationStore(f.database).loadPlan(OperationId(row[0].required(0)),RunId(row[0].required(1))).value().getOrThrow()
                @Expect(plan.canonicalArguments.field("host_plan").getOrThrow()
                    .field("intents").getOrThrow().items[0].field("request").getOrThrow().field("timeout_ms").getOrThrow().asNumberText(),"600000")
            }finally{lifecycleTestRequire(actual.close())}
        }finally{f.close()}
    }
    @TestCase
    func earlierActualCallerDeadlineCannotBeExtendedByFiniteOperatorProfile():Unit {
        let f=NativeReadonlyShellProductFixture()
        let cancellation=CancellationSource(deadlineMillis:agentUtcMillis()+3000)
        let owner=ProductDirectPreparationOwner({=>cancellation.token.check()})
        try{let thread=SessionId("readonly-earlier-deadline")
            let capabilities=f.product.request("Read only.",sessionId:Some(thread),readOnly:true).capabilities
            let budget=ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1)
            let started=MonoTime.now()
            let result=f.product.vnext.executeDeferredCanonicalTool(thread,capabilities,
                ToolCall("earlier-deadline",f.name,f.input("printf begun; sleep 30",millis:600000)),owner,cancellation.token,budget:budget)
            let rejected=match(result){
                case Result.Err(_)=>true
                case Result.Ok(ToolInvocationResult.Completed(value))=>try{value.isError}finally{value.releasePayload()}
                case Result.Ok(ToolInvocationResult.Denied(_))=>true
                case _=>false}
            @Expect(rejected);@Expect(MonoTime.now()-started<Duration.second*7)
            @Expect(f.count(thread.value,"SELECT COUNT(*) FROM runs WHERE thread_id=? AND state='completed'"),0)
            @Expect(budget.snapshot().toolCalls<=2);@Expect(budget.snapshot().activeTools,0)
            lifecycleTestRequire(owner.closeAcknowledgement())
        }finally{cancellation.close();f.close()}
    }
    @TestCase
    func actualParentCancellationStopsLongWorkerWithoutCompletingRunOrLeakingOwner():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let actual=lifecycleTestRequire(f.product.acquireShellToolInvocation(SessionId("readonly-live-cancel"),readOnly:true))
            let budget=ExecutionBudget(maxToolCalls:2,maxConcurrentTools:1)
            let pending=spawn{actual.start(f.input("printf begun; sleep 30",millis:600000),budget)}
            try{let deadline=MonoTime.now()+Duration.second*5
                while(f.workerHandoffs("readonly-live-cancel")==0 && MonoTime.now()<deadline){sleep(Duration.millisecond*5)}
                @Expect(f.workerHandoffs("readonly-live-cancel"),1)
                lifecycleTestRequire(actual.cancel());let _=pending.get()
                @Expect(actual.output().isError())
                @Expect(f.count("readonly-live-cancel","SELECT COUNT(*) FROM runs WHERE thread_id=? AND state='completed'"),0)
                @Expect(budget.snapshot().toolCalls,2);@Expect(budget.snapshot().activeTools,0)
            }finally{let _=actual.cancel();let _=pending.get();lifecycleTestRequire(actual.close())}
        }finally{f.close()}
    }

    @TestCase
    func actualRootPreservesFullControlCaptureThroughPaidNeutralPayloadAndSameOwnerAck():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let actual=f.invoke("readonly-control-output",f.input("for ((i=0;i<131077;i++));do printf '\\001';done"))
            try{let output=lifecycleTestRequire(actual.output())
                @Expect(output.field("stdout").getOrThrow().text.toArray(),Array<Byte>(131072,repeat:1u8))
                @Expect(output.field("stderr").getOrThrow().text,"")
                @Expect(output.field("truncated").getOrThrow().asBool());@Expect(output.fields.size,5)
                f.requireRootAndWorker("readonly-control-output",actual.receiptId())
            }finally{lifecycleTestRequire(actual.close())}
            @Expect(actual.observedOutput().isError())
        }finally{f.close()}
    }
    @TestCase
    func actualRootKeepsOriginalInvalidUtf8ReplacementInsteadOfTruncatingItsExpandedText():Unit {
        let f=NativeReadonlyShellProductFixture()
        try{let actual=f.invoke("readonly-invalid-utf8-output",f.input("for ((i=0;i<131072;i++));do printf '\\377';done"))
            try{let output=lifecycleTestRequire(actual.output())
                let expected=Array<Byte>(393216,{index=>[239u8,191u8,189u8][index%3]})
                @Expect(output.field("stdout").getOrThrow().text.toArray(),expected)
                @Expect(output.field("stderr").getOrThrow().text,"")
                @Expect(!output.field("truncated").getOrThrow().asBool());@Expect(output.fields.size,5)
                f.requireRootAndWorker("readonly-invalid-utf8-output",actual.receiptId())
            }finally{lifecycleTestRequire(actual.close())}
        }finally{f.close()}
    }
}
