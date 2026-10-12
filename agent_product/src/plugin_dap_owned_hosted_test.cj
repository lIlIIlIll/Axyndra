package agent_product

import agent_plugin_registry

import agent_domain.*
import agent_extension_runtime.*
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

// Compose the original real package/Product fixture. No Prepared, Root,
// ModelDecision, installed worker, channel, permission or Receipt is forged.
// The independent owned wire peer leaves all original fixture bytes intact.
class OwnedDapProductFixture {
    let actual:DapProductFixture
    init(approval!:ApprovalMode=ApprovalMode.Yolo,multiple!:Bool=false,payload!:Bool=false,mode!:String="normal",selectedMaximum!:Int64=0){
        let opened=DapProductFixture(approval:approval,payload:payload)
        try{
            let peer=Path(getVariable("AXYNDRA_DAP_TEST_SERVER").getOrThrow()).parent.join("dap_owned_peer.py").toString()
            File.writeTo(opened.files.external+"/dap-peer.py",File.readFrom(peer))
            let configuration=parseUnifiedJson(String.fromUtf8(File.readFrom(opened.files.settings+"/plugins/lifecycle.json")),maxBytes:131072)
            let plugin=configuration.field("plugins").getOrThrow().items[0]
            let service=plugin.field("services").getOrThrow().items[0]
            service.put("arguments",listValue([textValue("-u"),textValue(opened.files.external+"/dap-peer.py"),textValue(opened.transcript),textValue("primary"),textValue(mode)]))
            service.put("environment",objectValue([ValueField("DAP_SELECTED_ADAPTER",textValue("primary"))]))
            let business=objectValue([ValueField("transport",textValue("managed_channel_owned")),
                ValueField("adapter",textValue("fixture")),ValueField("launch",objectValue([])),ValueField("attach",objectValue([]))])
            if(multiple){
                let secondary=parseUnifiedJson(stringifyUnifiedJson(service))
                secondary.put("id",textValue("secondary"))
                secondary.put("arguments",listValue([textValue("-u"),textValue(opened.files.external+"/dap-peer.py"),textValue(opened.transcript),textValue("secondary"),textValue(mode)]))
                secondary.put("environment",objectValue([ValueField("DAP_SELECTED_ADAPTER",textValue("secondary"))]))
                if(selectedMaximum>0){secondary.put("max_instances",integerValue(selectedMaximum))}
                plugin.put("services",listValue([service,secondary]))
                business.put("managed_process_services",listValue([textValue("stdio"),textValue("secondary")]))
                business.put("adapters",objectValue([
                    ValueField("primary",objectValue([ValueField("service_id",textValue("stdio")),
                        ValueField("fileTypes",listValue([textValue(".txt")])),ValueField("launchDefaults",objectValue([])),ValueField("attachDefaults",objectValue([]))])),
                    ValueField("secondary",objectValue([ValueField("service_id",textValue("secondary")),
                        ValueField("fileTypes",listValue([textValue(".py")])),ValueField("launchDefaults",objectValue([])),ValueField("attachDefaults",objectValue([]))]))]))
            }
            plugin.put("configuration",business);opened.files.write(configuration)
            actual=opened
        }catch(error:Exception){opened.close();throw error}
    }
    func name():String{actual.name("debug")}
    func start(thread:String):ToolResult{managedCompleted(actual.start(thread))}
    func input(action:String,fields!:Array<ValueField>=[]):AgentValue{
        let values=ArrayList<ValueField>([ValueField("action",textValue(action))]);values.add(all:fields);objectValue(values.toArray())
    }
    func call(thread:String,id:String,input:AgentValue):ToolResult{managedCompleted(actual.call(thread,id,"debug",input,maxCalls:32))}
    func launch(thread:String,id:String,adapter!:String=""):ToolResult{
        let fields=ArrayList<ValueField>([ValueField("program",textValue(actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))])
        if(adapter!=""){fields.add(ValueField("adapter",textValue(adapter)))}
        call(thread,id,input("launch",fields:fields.toArray()))
    }
    func receipts(tool:String,outcome!:String="completed"):Int64{
        let rows=actual.database.query("SELECT COUNT(*) FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id=? AND r.outcome=?",
            [SqlParameter.Text(tool),SqlParameter.Text(outcome)])
        Int64.parse(rows[0].required(0))
    }
    func childPlans(id:String):Array<AgentValue>{
        let result=ArrayList<AgentValue>()
        for(row in actual.database.query("SELECT normalized_plan FROM operation_effect_records WHERE tool_id IN ('host.process.channel.owned.write','host.process.channel.owned.spawn','host.process.channel.owned.close')")){
            let plan=decodeStoredValue(row.required(0));let arguments=plan.field("arguments").getOrThrow()
            if(lifecycleText(arguments,"request_key").startsWith("managed-channel:"+id+":")){result.add(plan)}}
        result.toArray()
    }
    func canonical(thread:String,id:String,error:Bool):AgentValue{
        for(item in SqliteThreadCommitSink(actual.database).loadThread(ThreadId(thread)).items){
            match(item.content){case ThreadItemContent.ToolResult(call,_,_,output,isError)=>
                if(call.value==id){if(isError!=error){throw IllegalStateException("owned DAP canonical error changed")};return output}
                case _=>()}}
        throw IllegalStateException("owned DAP canonical output missing")
    }
    func visible(thread:String):Bool{
        for(definition in actual.product.tools(threadId:Some(ThreadId(thread))) where definition.name==name()){return true};false
    }
    func parsedPeerResponse(command:String):AgentValue{
        var result:?AgentValue=None<AgentValue>
        let deadline=MonoTime.now()+Duration.second*5
        while(result.isNone() && MonoTime.now()<deadline){
            for(item in actual.observed() where lifecycleText(item,"type")=="fixture_response"){
                let response=item.field("response").getOrThrow()
                if(lifecycleText(response,"command")==command){
                    if(result.isSome()){throw IllegalStateException("unique whole adapter response required")};result=Some(response)}}
            if(result.isNone()){sleep(Duration.millisecond*5)}}
        result.getOrThrow()
    }
    func released():Bool{
        for(status in actual.product.pluginServiceStatuses() where !status.field("cleanup_acknowledged").getOrThrow().asBool()){return false};true
    }
    func stop(thread:String):Unit{
        lifecycleTestRequire(actual.product.stopPluginService(SessionId(thread),productRegistryCopyText83(actual.record.descriptor.copyText(PluginDescriptorText.Namespace)),"stdio"))
        let deadline=MonoTime.now()+Duration.second*10
        while(!released() && MonoTime.now()<deadline){sleep(Duration.millisecond*10)}
        if(!released()){throw IllegalStateException("actual owned service physical cleanup ACK missing")}
        @Expect(!visible(thread))
    }
    func close():Unit{actual.close()}
    func approvedCommand(plan:AgentValue):String{
        let operation=plan.field("arguments").getOrThrow().field("operation").getOrThrow()
        if(lifecycleText(operation,"kind")!="write"){return lifecycleText(operation,"kind")}
        let encoded=lifecycleText(operation,"bytes_hex")
        for(command in ["initialize","launch","configurationDone","stackTrace"]){
            if(encoded.contains(serviceObservationHex(("\"command\":\""+command+"\"").toArray()))){return command}}
        throw IllegalStateException("an actual approved launch phase was not identified")
    }
}

@Test
class PluginDapOwnedHostedTests {
    @TestCase
    func installedOwnedPathExecutesAllTwentyEightActionsAndExactCurrentFrames():Unit{
        let f=OwnedDapProductFixture(multiple:true);let thread="dap-owned-28"
        try{
            @Expect(!f.start(thread).isError);@Expect(f.actual.commandCount("initialize"),0)
            let launched=f.launch(thread,"owned-launch")
            @Expect(!launched.isError);@Expect(lifecycleText(launched.output,"action"),"launch")
            @Expect(lifecycleText(launched.output.field("snapshot").getOrThrow(),"adapter"),"secondary")
            var actualSelection:Int64=0
            for(item in f.actual.observed() where lifecycleText(item,"command")=="adapter-start"){
                @Expect(lifecycleText(item,"adapter_label"),"secondary")
                @Expect(lifecycleText(item,"environment"),"secondary");actualSelection+=1}
            @Expect(actualSelection,1)
            @Expect(f.actual.commandCount("initialize"),1);@Expect(f.actual.commandCount("launch"),1)
            @Expect(f.actual.commandCount("configurationDone"),1);@Expect(f.actual.commandCount("stackTrace"),1)
            var previousFrame=Int64.parse(launched.output.field("snapshot").getOrThrow().field("frameId").getOrThrow().asNumberText())
            let source=f.actual.files.workspace+"/main.py"
            let actions=[("set_breakpoint","setBreakpoints"),("remove_breakpoint","setBreakpoints"),
                ("set_instruction_breakpoint","setInstructionBreakpoints"),("remove_instruction_breakpoint","setInstructionBreakpoints"),
                ("data_breakpoint_info","dataBreakpointInfo"),("set_data_breakpoint","setDataBreakpoints"),("remove_data_breakpoint","setDataBreakpoints"),
                ("continue","continue"),("step_over","next"),("step_in","stepIn"),("step_out","stepOut"),("pause","pause"),
                ("evaluate","evaluate"),("stack_trace","stackTrace"),("threads","threads"),("scopes","scopes"),("variables","variables"),
                ("disassemble","disassemble"),("read_memory","readMemory"),("write_memory","writeMemory"),("modules","modules"),
                ("loaded_sources","loadedSources"),("custom_request","fixture/observedStop"),("output",""),("sessions","")]
            var count:Int64=1
            for((action,command) in actions){
                let before=if(command==""){0}else{f.actual.commandCount(command)}
                let input=parseUnifiedJson("{\"file\":\"\",\"line\":2,\"instruction_reference\":\"0x40\",\"name\":\"value\",\"data_id\":\"actual-data-id\",\"expression\":\"完整求值\\u0000雪🙂\",\"variable_ref\":3,\"instruction_count\":1,\"memory_reference\":\"0x40\",\"count\":1,\"data\":\"eA==\",\"command\":\"fixture/observedStop\",\"arguments\":{\"output\":\"完整输出 雪🙂\"},\"timeout\":5}")
                input.put("file",textValue(source));input.put("action",textValue(action))
                let id="owned-"+action;let result=f.call(thread,id,input)
                @Expect(!result.isError);@Expect(lifecycleText(result.output,"action"),action)
                @Expect(result.output.field("success").getOrThrow().asBool(),true)
                @Expect(canonicalAgentValue(f.canonical(thread,id,false)),canonicalAgentValue(result.output))
                if(command!=""){@Expect(f.actual.commandCount(command),before+1)}
                if(action=="evaluate"){@Expect(lifecycleText(result.output.field("response").getOrThrow(),"result"),"完整求值\u{0}雪🙂")}
                if(action=="output"){@Expect(lifecycleText(result.output,"content").contains("完整输出 雪🙂"))}
                if(["continue","step_over","step_in","step_out","pause"].contains(action)){
                    @Expect(lifecycleText(result.output.field("snapshot").getOrThrow(),"status"),"stopped")
                    let currentFrame=Int64.parse(result.output.field("snapshot").getOrThrow().field("frameId").getOrThrow().asNumberText())
                    @Expect(currentFrame>previousFrame);previousFrame=currentFrame
                    @Expect(f.childPlans(id).size,2)}
                count+=1
            }
            @Expect(!f.call(thread,"owned-terminate",f.input("terminate")).isError);count+=1
            let attached=f.call(thread,"owned-attach",f.input("attach",fields:[ValueField("pid",integerValue(0)),ValueField("adapter",textValue("primary")),ValueField("timeout",integerValue(5))]))
            @Expect(!attached.isError);@Expect(lifecycleText(attached.output.field("snapshot").getOrThrow(),"adapter"),"primary");count+=1
            @Expect(f.actual.commandCount("attach"),1);@Expect(f.actual.commandCount("initialize"),2)
            @Expect(f.actual.commandCount("configurationDone"),2)
            @Expect(count,28)
            @Expect(!f.call(thread,"owned-final-terminate",f.input("terminate")).isError)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM model_decisions"),0)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records e JOIN derived_operation_admissions a ON a.operation_id=e.operation_id WHERE e.tool_id IN ('host.process.channel.owned.write','host.process.channel.owned.spawn','host.process.channel.owned.close') AND (a.depth<>1 OR a.root_operation_id<>a.parent_operation_id)"),0)
            // Every exact approved write is compared with the real adapter's
            // observed physical wire bytes, not just command names.
            let frames=String.fromUtf8(File.readFrom(f.actual.transcript+".frames")).split("\n")
            var matched:Int64=0
            for(row in f.actual.database.query("SELECT normalized_plan FROM operation_effect_records WHERE tool_id='host.process.channel.owned.write'")){
                let operation=decodeStoredValue(row.required(0)).field("arguments").getOrThrow().field("operation").getOrThrow()
                let bytes=lifecycleText(operation,"bytes_hex");var seen:Int64=0
                for(frame in frames where frame==bytes){seen+=1}
                @Expect(seen,1);matched+=1}
            @Expect(matched,f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL));f.stop(thread)
        }finally{f.close()}
    }

    @TestCase
    func actualParentRejectionAndEachFrozenChildApprovalCannotBorrowOtherWrites():Unit{
        let f=OwnedDapProductFixture(approval:ApprovalMode.AlwaysAsk);let thread="dap-owned-approval"
        try{
            @Expect(!f.start(thread).isError)
            let session=f.actual.product.applicationSession(sessionId:Some(SessionId(thread)))
            session.setThinking(ThinkingLevel.Off)
            let input=f.input("launch",fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))])
            f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("deny-parent",f.name(),input)
            lifecycleTestRequire(session.submit("Review the exact owned debugger launch."))
            let parent=session.approval().getOrThrow()
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),0);@Expect(f.actual.observed().size,0)
            lifecycleTestRequire(session.decide(parent.operationId.value,ApprovalDecision.Reject))
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),0);@Expect(f.actual.observed().size,0)
            f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("approve-parent-deny-child",f.name(),input)
            lifecycleTestRequire(session.submit("Review the parent, then its separately proposed adapter spawn."))
            lifecycleTestRequire(session.decide(session.approval().getOrThrow().operationId.value,ApprovalDecision.Approve))
            let child=session.approval().getOrThrow()
            let frozen=f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(child.operationId.value)])[0].required(0)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),0);@Expect(f.actual.observed().size,0)
            lifecycleTestRequire(session.decide(child.operationId.value,ApprovalDecision.Reject))
            @Expect(f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(child.operationId.value)])[0].required(0),frozen)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),0);@Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),0)
            f.stop(thread)
        }finally{f.close()}
    }

    @TestCase
    func initializeLaunchConfigurationAndRefreshEachWaitForTheirOwnFrozenApproval():Unit{
        // Five rejection branches and one complete approval branch enter the
        // installed Product, real committed Root, Store and physical adapter.
        // Reading a saved plan here only observes the exact requested effect.
        for(target in ["spawn","initialize","launch","configurationDone","stackTrace","approve-all"]){
            let f=OwnedDapProductFixture(approval:ApprovalMode.AlwaysAsk)
            let thread="dap-owned-phase-approval-"+target
            try{
                @Expect(!f.start(thread).isError)
                let session=f.actual.product.applicationSession(sessionId:Some(SessionId(thread)))
                session.setThinking(ThinkingLevel.Off)
                f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("exact-phase",f.name(),
                    f.input("launch",fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))]))
                lifecycleTestRequire(session.submit("Review every actual adapter phase separately."))
                lifecycleTestRequire(session.decide(session.approval().getOrThrow().operationId.value,ApprovalDecision.Approve))
                let seen=ArrayList<String>();var rejected=false
                while(session.approval().isSome() && !rejected){
                    let approval=session.approval().getOrThrow()
                    let rows=f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(approval.operationId.value)])
                    @Expect(rows.size,1);let frozen=rows[0].required(0)
                    let command=f.approvedCommand(decodeStoredValue(frozen))
                    if(command!="spawn"){@Expect(f.actual.commandCount(command),0)}
                    else{@Expect(f.actual.commandCount("adapter-start"),0)}
                    seen.add(command);if(seen.size>5){throw IllegalStateException("launch proposed an unexpected extra effect")}
                    if(command==target){
                        lifecycleTestRequire(session.decide(approval.operationId.value,ApprovalDecision.Reject));rejected=true
                        @Expect(f.actual.database.query("SELECT normalized_plan FROM operations WHERE id=?",[SqlParameter.Text(approval.operationId.value)])[0].required(0),frozen)
                        if(command!="spawn"){@Expect(f.actual.commandCount(command),0)}
                        else{@Expect(f.actual.commandCount("adapter-start"),0)}
                    }else{lifecycleTestRequire(session.decide(approval.operationId.value,ApprovalDecision.Approve))}
                }
                @Expect(rejected,target!="approve-all")
                let expected=["spawn","initialize","launch","configurationDone","stackTrace"]
                for(index in 0..seen.size){@Expect(seen[index],expected[index])}
                if(target=="approve-all"){
                    @Expect(seen.size,5);@Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),1)
                    @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),4)
                    @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
                }
                @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operation_effect_records e JOIN derived_operation_admissions a ON a.operation_id=e.operation_id WHERE e.tool_id IN ('host.process.channel.owned.spawn','host.process.channel.owned.write') AND (a.depth<>1 OR a.root_operation_id<>a.parent_operation_id)"),0)
                @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
                f.stop(thread)
            }finally{f.close()}
        }
    }

    @TestCase
    func completeAdapterFailureIsKnownAndKeepsParsedResponseDistinctFromWriteAck():Unit{
        let f=OwnedDapProductFixture();let thread="dap-owned-error"
        try{
            @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"launch-error").isError)
            let before=f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)
            let failed=f.call(thread,"actual-error",f.input("custom_request",fields:[ValueField("command",textValue("fixture/error")),ValueField("arguments",objectValue([]))]))
            @Expect(failed.isError);@Expect(failed.output.field("success").getOrThrow().asBool(),false)
            @Expect(lifecycleText(failed.output,"content"),"known adapter failure 雪🙂")
            @Expect(canonicalAgentValue(f.canonical(thread,"actual-error",true)),canonicalAgentValue(failed.output))
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),before+1)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),0)
            let rows=f.actual.database.query("SELECT r.detail FROM operation_receipts r JOIN operation_effect_records e ON e.operation_id=r.operation_id WHERE e.tool_id=? AND e.normalized_plan LIKE ?",
                [SqlParameter.Text(f.name()),SqlParameter.Text("%fixture/error%")])
            @Expect(rows.size,1)
            // Parent canonical output is complete. The independently sealed
            // terminal evidence also contains the whole parsed envelope;
            // the write child's receipt contains only its physical write ACK.
            @Expect(lifecycleText(decodeStoredValue(rows[0].required(0)).field("output").getOrThrow(),"content"),"known adapter failure 雪🙂")
            let response=f.parsedPeerResponse("fixture/error")
            @Expect(response.field("success").getOrThrow().asBool(),false)
            @Expect(lifecycleText(response.field("body").getOrThrow(),"original"),"完整错误\u{0}雪🙂")
            let encoded=encodeStoredValue(response);var matched:Int64=0
            for(row in f.actual.database.query("SELECT payload FROM audit_events WHERE kind='managed_channel_actual_terminal_v1'")){
                let witness=decodeStoredValue(row.required(0))
                if(lifecycleText(witness,"root_call_id")=="actual-error"){
                    @Expect(lifecycleText(witness,"terminal_kind"),"protocol")
                    let record=witness.field("protocol_record").getOrThrow()
                    let identity=record.field("response_identity").getOrThrow()
                    @Expect(Int64.parse(identity.field("bytes").getOrThrow().asNumberText()),encoded.size)
                    @Expect(lifecycleText(identity,"sha256"),modelPolicySha256Text(encoded))
                    let child=f.actual.database.query("SELECT detail FROM operation_receipts WHERE operation_id=?",[SqlParameter.Text(lifecycleText(record,"operation_id"))])
                    @Expect(child.size,1)
                    let ack=decodeStoredValue(child[0].required(0)).field("output").getOrThrow()
                    @Expect(lifecycleText(ack,"schema"),"axyndra.managed-channel-write-result/v1")
                    @Expect(ack.field("response").isNone());matched+=1}}
            @Expect(matched,1)
            @Expect(!f.call(thread,"error-remains-usable",f.input("threads")).isError)
            @Expect(!f.call(thread,"error-close",f.input("terminate")).isError);f.stop(thread)
        }finally{f.close()}
    }

    @TestCase
    func otherActualThreadCannotUseTheInstalledAdapterOrMintItsNextEffect():Unit{
        let f=OwnedDapProductFixture();let original="dap-owned-thread-original"
        try{
            @Expect(!f.start(original).isError);@Expect(!f.launch(original,"original-launch").isError)
            let spawns=f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL)
            let writes=f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)
            @Expect(!f.visible("dap-owned-other-thread"))
            @Expect(managedRejected(f.actual.call("dap-owned-other-thread","foreign-read","debug",f.input("threads"),maxCalls:32)))
            @Expect(managedRejected(f.actual.call("dap-owned-other-thread","foreign-spawn","debug",f.input("launch",
                fields:[ValueField("program",textValue(f.actual.files.workspace+"/main.py")),ValueField("timeout",integerValue(5))]),maxCalls:32)))
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),spawns)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),writes)
            @Expect(f.actual.commandCount("threads"),0);@Expect(f.actual.commandCount("adapter-start"),1)
            @Expect(!f.call(original,"same-thread-remains-current",f.input("threads")).isError)
            @Expect(f.actual.commandCount("threads"),1);f.stop(original)
        }finally{f.close()}
    }

    @TestCase
    func lateResponseAfterWrittenCancellationCannotCommitKnownOrReviveOldEndpoint():Unit{
        let f=OwnedDapProductFixture();let thread="dap-owned-late"
        try{
            @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"launch-late").isError)
            let before=f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)
            let session=f.actual.product.applicationSession(sessionId:Some(SessionId(thread)))
            f.actual.product.fixtureProbe.getOrThrow().enqueueToolCallReply("late-response",f.name(),
                f.input("custom_request",fields:[ValueField("command",textValue("fixture/late")),ValueField("arguments",objectValue([])),ValueField("timeout",integerValue(10))]))
            let running=spawn{session.submit("Wait for the real adapter response.")}
            try{
                f.actual.awaitCommand("fixture/late",1)
                let deadline=MonoTime.now()+Duration.second*5
                while(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)<before+1 && MonoTime.now()<deadline){sleep(Duration.millisecond*5)}
                @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),before+1)
                lifecycleTestRequire(session.cancel());let _=running.get()
                File.writeTo(f.actual.files.workspace+"/release-late-response","release".toArray())
                f.actual.awaitCommand("late-response-attempt",1)
                @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),1)
                @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM runs WHERE thread_id='dap-owned-late' AND state='cancelled'"),1)
                @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
                @Expect(managedRejected(f.actual.call(thread,"never-replay","debug",f.input("threads"),maxCalls:32)))
                @Expect(f.actual.commandCount("threads"),0);f.stop(thread)
            }finally{let _=session.cancel();let _=running.get()}
        }finally{f.close()}
    }

    @TestCase
    func reverseSpawnUsesSameActualNamespaceAndBothIndependentKnownChildOperations():Unit{
        let f=OwnedDapProductFixture();let thread="dap-owned-reverse"
        try{
            @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"launch-reverse").isError)
            let spawns=f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL);let writes=f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)
            let result=f.call(thread,"reverse",f.input("custom_request",fields:[ValueField("command",textValue("fixture/runInTerminal")),ValueField("arguments",objectValue([]))]))
            @Expect(!result.isError);@Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),spawns+1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),writes+2)
            let response=result.output.field("response").getOrThrow()
            @Expect(Int64.parse(response.field("confirmedProcessId").getOrThrow().asNumberText())>2)
            @Expect(lifecycleText(response,"command").endsWith("/sleep"));@Expect(lifecycleText(response,"argument"),"30")
            let plans=f.childPlans("reverse");@Expect(plans.size,3)
            var auxiliary:Int64=0;var replies:Int64=0
            for(plan in plans){let operation=plan.field("arguments").getOrThrow().field("operation").getOrThrow()
                if(lifecycleText(operation,"role")=="auxiliary"){@Expect(operation.field("configured_process").isNone());auxiliary+=1}
                if(lifecycleText(operation,"id").startsWith("dap-reverse-")){replies+=1}}
            @Expect(auxiliary,1);@Expect(replies,1)
            @Expect(!f.call(thread,"reverse-terminate",f.input("terminate")).isError)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_CLOSE_TOOL),1);f.stop(thread)
        }finally{f.close()}
    }

    @TestCase
    func selectedOperatorsSmallerQuotaRejectsAuxiliaryWithoutBorrowingBaseQuota():Unit{
        let f=OwnedDapProductFixture(multiple:true,selectedMaximum:1);let thread="dap-owned-selected-quota"
        try{
            @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"selected-quota-launch").isError)
            @Expect(f.actual.commandCount("adapter-start"),1)
            let spawns=f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL)
            @Expect(managedRejected(f.actual.call(thread,"selected-quota-reverse","debug",f.input("custom_request",
                fields:[ValueField("command",textValue("fixture/runInTerminal")),ValueField("arguments",objectValue([]))]),maxCalls:32)))
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_SPAWN_TOOL),spawns)
            @Expect(f.actual.commandCount("runInTerminal"),0)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),1)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
            f.stop(thread)
        }finally{f.close()}
    }

    @TestCase
    func explicitAdapterChoiceChangedConfigurationAndDisableCannotRetargetOldResource():Unit{
        for(mode in ["configuration","disable"]){
            let f=OwnedDapProductFixture(multiple:true);let thread="dap-owned-revoke-"+mode
            try{
                @Expect(!f.start(thread).isError);let launched=f.launch(thread,"explicit-primary",adapter:"primary")
                @Expect(!launched.isError);@Expect(lifecycleText(launched.output.field("snapshot").getOrThrow(),"adapter"),"primary")
                let plans=f.childPlans("explicit-primary");var selected:Int64=0
                for(plan in plans){let operation=plan.field("arguments").getOrThrow().field("operation").getOrThrow()
                    if(lifecycleText(operation,"kind")=="spawn"){@Expect(lifecycleText(operation,"configured_process"),"stdio");selected+=1}}
                @Expect(selected,1)
                var actualSelection:Int64=0
                for(item in f.actual.observed() where lifecycleText(item,"command")=="adapter-start"){
                    @Expect(lifecycleText(item,"adapter_label"),"primary")
                    @Expect(lifecycleText(item,"environment"),"primary");actualSelection+=1}
                @Expect(actualSelection,1)
                let before=f.actual.commandCount("adapter-start")
                if(mode=="configuration"){
                    let path=f.actual.files.settings+"/plugins/lifecycle.json"
                    File.writeTo(path,(String.fromUtf8(File.readFrom(path))+"\n").toArray())
                }else{
                    match(f.actual.product.setPluginEnabled(productRegistryCopyText83(f.actual.record.descriptor.copyText(PluginDescriptorText.Namespace)),false)){
                        case PluginRegistryResult.Ok(_)=>();case PluginRegistryResult.Err(error)=>throw IllegalStateException(error.code)}}
                @Expect(managedRejected(f.actual.call(thread,"stale-never-retarget","debug",f.input("threads"),maxCalls:32)))
                @Expect(f.actual.commandCount("threads"),0);@Expect(f.actual.commandCount("adapter-start"),before)
                f.stop(thread)
            }finally{f.close()}
        }
    }

    @TestCase
    func wrongCorrelationDuplicateAndTruncatedActualFramesCannotPublishKnown():Unit{
        for(mode in ["wrong-sequence","wrong-command","duplicate","truncated"]){
            let f=OwnedDapProductFixture();let thread="dap-owned-corrupt-"+mode
            try{
                @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"launch-corrupt").isError)
                let writes=f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)
                let command="fixture/"+mode
                @Expect(managedRejected(f.actual.call(thread,"corrupt-frame","debug",f.input("custom_request",
                    fields:[ValueField("command",textValue(command)),ValueField("arguments",objectValue([])),ValueField("timeout",integerValue(5))]),maxCalls:32)))
                @Expect(f.actual.commandCount(command),1);@Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),writes+1)
                @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operation_receipts WHERE outcome='unknown'"),1)
                var proof:Int64=0
                for(row in f.actual.database.query("SELECT payload FROM audit_events WHERE kind='managed_channel_actual_terminal_v1'")){
                    if(lifecycleText(decodeStoredValue(row.required(0)),"root_call_id")=="corrupt-frame"){proof+=1}}
                @Expect(proof,0)
                @Expect(managedRejected(f.actual.call(thread,"corrupt-no-replay","debug",f.input("threads"),maxCalls:32)))
                @Expect(f.actual.commandCount("threads"),0);f.stop(thread)
            }finally{f.close()}
        }
    }

    @TestCase
    func realPartialPipeWriteCannotTurnAnUnacknowledgedResponseIntoKnown():Unit{
        let f=OwnedDapProductFixture(payload:true,mode:"partial_write");let thread="dap-owned-partial-write"
        try{
            @Expect(!f.start(thread).isError);@Expect(!f.launch(thread,"launch-partial").isError)
            let completed=f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL)
            let expression=String.fromUtf8(Array<Byte>(262144,repeat:b'x'))
            @Expect(managedRejected(f.actual.call(thread,"partial-no-ack","debug",f.input("evaluate",
                fields:[ValueField("expression",textValue(expression)),ValueField("timeout",integerValue(5))]),maxCalls:32)))
            f.actual.awaitCommand("partial-write-prefix",1)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL),completed)
            @Expect(f.receipts(HOST_MANAGED_CHANNEL_WRITE_TOOL,outcome:"unknown"),1)
            var known:Int64=0
            for(row in f.actual.database.query("SELECT payload FROM audit_events WHERE kind='managed_channel_actual_terminal_v1'")){
                if(lifecycleText(decodeStoredValue(row.required(0)),"root_call_id")=="partial-no-ack"){known+=1}}
            @Expect(known,0)
            @Expect(f.actual.database.scalarInt("SELECT COUNT(*) FROM operations WHERE state IN ('prepared','executing','waiting_approval')"),0)
            f.stop(thread)
        }finally{f.close()}
    }
}
