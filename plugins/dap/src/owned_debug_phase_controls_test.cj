package dap_plugin

import process4cj.*
import std.collection.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Native finite-state controls only. These deliberately manufacture no
// Prepared, Host Source, Store Known receipt, process, grant or physical ACK.
// Actual Hosted Store/Registry/lease acceptance remains a separate gate.
func dapOwnedControlConfiguration():JsonNode{
    parseUnifiedJson("{\"adapter\":\"fixture\",\"executable\":\"/usr/bin/python3\",\"args\":[],\"environment\":{},\"workspace_mode\":\"workspace_readonly\",\"network\":{\"mode\":\"deny\"},\"launch\":{},\"attach\":{},\"workspace_root\":\"/workspace\",\"context_cwd\":\"/workspace\"}")
}
class DapOwnedControlFixture{
    let session:DapOwnedDebugSession
    let workflow:DapOwnedDebugWorkflow
    init(action:String){
        let actual=DapOwnedDebugSession("fixture",dapOwnedControlConfiguration(),DapDebugLocations("/workspace",program:"/workspace/target"),1048576)
        actual.leaseId="actual-unit-lease";actual.initialized=true
        actual.policy.configureDebug(debugTestCapabilities());actual.policy.event("stopped",parseUnifiedJson("{\"threadId\":7}"))
        session=actual
        workflow=try{DapOwnedDebugWorkflow(actual,parseUnifiedJson(action),MonoTime.now()+Duration.second*30,131072)}
            catch(error:Exception){actual.close();throw error}
    }
    func acknowledge(effect:JsonNode):Unit{
        let operation=field(effect,"operation")
        workflow.acknowledge(number(effect,"sequence"),jsonObject([
            JsonObjectEntry("schema",jsonString("axyndra.managed-channel-write-result/v1")),
            JsonObjectEntry("lease_id",jsonString(session.leaseId)),JsonObjectEntry("intent_id",field(operation,"id")),
            JsonObjectEntry("written_bytes",jsonNumber((text(operation,"bytes_hex").size/2).toString()))]))
    }
    func response(command:String,body:JsonNode,success!:Bool=true,message!:String=""):JsonNode{
        let value=jsonObject([JsonObjectEntry("seq",jsonNumber("42")),JsonObjectEntry("type",jsonString("response")),
            JsonObjectEntry("request_seq",jsonNumber("1")),JsonObjectEntry("command",jsonString(command)),
            JsonObjectEntry("success",jsonBool(success)),JsonObjectEntry("message",jsonString(message)),JsonObjectEntry("body",body)])
        let raw=encodeContentLengthFrame(stringifyUnifiedJson(value));var offset:Int64=0
        while(offset<raw.size){let next=min(raw.size,offset+16384);workflow.receive(raw[offset..next].clone(),false);offset=next}
        value
    }
    func close():Unit{workflow.close();session.close()}
}

@Test
class DapOwnedNativePhaseControls{
    @TestCase
    func snapshotReadsDrainBothCurrentStreamsAndRetainCompleteOutputEvents():Unit{
        let f=DapOwnedControlFixture("{\"action\":\"output\"}")
        try{
            let read=f.workflow.next();@Expect(text(read,"status"),"read");@Expect(number(read,"wait_ms"),0)
            let event=parseUnifiedJson("{\"seq\":8,\"type\":\"event\",\"event\":\"output\",\"body\":{\"output\":\"fresh stdout\"}}")
            f.workflow.receiveStream("stdout",encodeContentLengthFrame(stringifyUnifiedJson(event)),false)
            f.workflow.receiveStream("stderr"," + fresh stderr".toArray(),false)
            @Expect(text(f.workflow.next(),"status"),"read")
            f.workflow.receiveStream("stdout",[],false)
            @Expect(text(f.workflow.next(),"status"),"read")
            f.workflow.receiveStream("stderr",[],false)
            let result=f.workflow.next();@Expect(text(result,"status"),"complete")
            @Expect(text(field(field(result,"result"),"response"),"output"),"fresh stdout + fresh stderr")
            @Expect(result.field("protocol_record").isNone(),true)
        }finally{f.close()}
    }
    @TestCase
    func currentSessionsSnapshotConsumesEventsBeforeItCompletes():Unit{
        let f=DapOwnedControlFixture("{\"action\":\"sessions\"}")
        try{
            @Expect(text(f.workflow.next(),"status"),"read")
            let event=parseUnifiedJson("{\"seq\":9,\"type\":\"event\",\"event\":\"continued\",\"body\":{\"threadId\":7,\"allThreadsContinued\":true}}")
            f.workflow.receiveStream("stdout",encodeContentLengthFrame(stringifyUnifiedJson(event)),false)
            f.workflow.receiveStream("stderr",[],false)
            @Expect(text(f.workflow.next(),"status"),"read")
            f.workflow.receiveStream("stdout",[],false);f.workflow.receiveStream("stderr",[],false)
            let result=f.workflow.next();@Expect(text(result,"status"),"complete")
            @Expect(text(field(field(result,"result"),"snapshot"),"status"),"running")
            @Expect(result.field("protocol_record").isNone(),true)
        }finally{f.close()}
    }
    @TestCase
    func allTwentyEightLegacyActionsRetainTheirIndependentCommandAndSchemaContract():Unit{
        let legacy=[("launch","launch"),("attach","attach"),("set_breakpoint","setBreakpoints"),("remove_breakpoint","setBreakpoints"),
            ("set_instruction_breakpoint","setInstructionBreakpoints"),("remove_instruction_breakpoint","setInstructionBreakpoints"),
            ("data_breakpoint_info","dataBreakpointInfo"),("set_data_breakpoint","setDataBreakpoints"),("remove_data_breakpoint","setDataBreakpoints"),
            ("continue","continue"),("step_over","next"),("step_in","stepIn"),("step_out","stepOut"),("pause","pause"),
            ("evaluate","evaluate"),("stack_trace","stackTrace"),("threads","threads"),("scopes","scopes"),("variables","variables"),
            ("disassemble","disassemble"),("read_memory","readMemory"),("write_memory","writeMemory"),("modules","modules"),
            ("loaded_sources","loadedSources"),("custom_request","unitCustom"),("output",""),("terminate","terminate"),("sessions","")]
        let schema=debugInputSchema();let names=field(field(schema,"properties"),"action").field("enum").getOrThrow().items
        @Expect(names.size,legacy.size)
        for(index in 0..legacy.size){
            let (action,command)=legacy[index];@Expect(names[index].text,action)
            let input=parseUnifiedJson("{\"program\":\"target\",\"pid\":0,\"file\":\"note.txt\",\"line\":2,\"instruction_reference\":\"0x1\",\"name\":\"v\",\"data_id\":\"id\",\"expression\":\"x\",\"variable_ref\":0,\"instruction_count\":1,\"memory_reference\":\"0x1\",\"count\":1,\"data\":\"eA==\",\"command\":\"unitCustom\",\"arguments\":{}}")
            input.put("action",jsonString(action))
            let call=prepareDebugCall(input,debugTestSnapshot(),debugTestCapabilities(),
                DapDebugLocations("/workspace",program:"/workspace/target",source:"/workspace/note.txt"),jsonObject([]),jsonObject([]))
            if(command==""){@Expect(call.request.isNone(),true)}else{@Expect(text(call.request.getOrThrow(),"command"),command)}
        }
        let options=["program","args","adapter","cwd","file","line","function","name","condition","hit_condition","expression","context",
            "frame_id","scope_id","variable_ref","pid","port","host","levels","memory_reference","instruction_reference","instruction_count",
            "instruction_offset","count","data","data_id","access_type","command","arguments","offset","resolve_symbols","allow_partial",
            "start_module","module_count","timeout"]
        for(option in options){@Expect(field(schema,"properties").field(option).isSome(),true)}
        @Expect(field(schema,"required").items.size,1);@Expect(field(schema,"required").items[0].text,"action")
    }
    @TestCase
    func concreteWriteProposalStaysFrozenAndUnsentResponseCannotBeAccepted():Unit{
        let fixture=DapOwnedControlFixture("{\"action\":\"threads\"}")
        try{
            let first=fixture.workflow.next();let resumed=fixture.workflow.next()
            @Expect(stringifyUnifiedJson(first),stringifyUnifiedJson(resumed));@Expect(number(first,"sequence"),1)
            var refused=false
            try{let _=fixture.response("threads",jsonObject([]))}catch(_:Exception){refused=true}
            @Expect(refused,true)
        }finally{fixture.close()}
    }
    @TestCase
    func partialAckCannotAdvanceAndFullResponseIsDistinctFromTheWriteAck():Unit{
        let fixture=DapOwnedControlFixture("{\"action\":\"threads\"}")
        try{
            let first=fixture.workflow.next();let operation=field(first,"operation");var refused=false
            try{fixture.workflow.acknowledge(1,jsonObject([JsonObjectEntry("schema",jsonString("axyndra.managed-channel-write-result/v1")),
                JsonObjectEntry("lease_id",jsonString(fixture.session.leaseId)),JsonObjectEntry("intent_id",field(operation,"id")),
                JsonObjectEntry("written_bytes",jsonNumber("0"))]))}catch(_:Exception){refused=true}
            @Expect(refused,true);@Expect(stringifyUnifiedJson(fixture.workflow.next()),stringifyUnifiedJson(first))
            fixture.acknowledge(first);@Expect(text(fixture.workflow.next(),"status"),"read")
            let complete=fixture.response("threads",jsonObject([JsonObjectEntry("threads",jsonArray([])),
                JsonObjectEntry("full",jsonString(String.fromUtf8(Array<Byte>(70000,repeat:b'x'))))]))
            let result=fixture.workflow.next();@Expect(text(result,"status"),"complete")
            @Expect(number(field(result,"protocol_record"),"child_sequence"),1)
            @Expect(stringifyUnifiedJson(field(field(result,"protocol_record"),"response")),stringifyUnifiedJson(complete))
        }finally{fixture.close()}
    }
    @TestCase
    func actualAdapterErrorKeepsItsCompleteParsedResponseAndDoesNotBecomeAnAck():Unit{
        let fixture=DapOwnedControlFixture("{\"action\":\"threads\"}")
        try{
            fixture.acknowledge(fixture.workflow.next())
            let response=fixture.response("threads",jsonObject([JsonObjectEntry("detail",jsonString("original"))]),success:false,message:"adapter refused")
            let result=fixture.workflow.next();@Expect(boolean(result,"is_error"),true)
            @Expect(text(field(result,"result"),"content"),"adapter refused")
            @Expect(stringifyUnifiedJson(field(field(result,"protocol_record"),"response")),stringifyUnifiedJson(response))
        }finally{fixture.close()}
    }
    @TestCase
    func policyStopRetiresItsProposalWithoutWritingOrProducingProtocolProof():Unit{
        let fixture=DapOwnedControlFixture("{\"action\":\"threads\"}")
        try{
            let first=fixture.workflow.next();fixture.workflow.abortProposal("policy_stop")
            let stopped=fixture.workflow.next();@Expect(text(stopped,"status"),"complete")
            @Expect(boolean(stopped,"is_error"),true);@Expect(stopped.field("protocol_record").isNone(),true)
            @Expect(text(field(stopped,"result"),"content"),"Debug operation was denied by policy.")
            var refused=false;try{fixture.acknowledge(first)}catch(_:Exception){refused=true};@Expect(refused,true)
        }finally{fixture.close()}
    }
    @TestCase
    func closeRequiresActualReleaseAckAndLateAckCannotRestartAClosedWorkflow():Unit{
        let fixture=DapOwnedControlFixture("{\"action\":\"terminate\"}")
        try{
            fixture.acknowledge(fixture.workflow.next());let _=fixture.response("terminate",jsonObject([]))
            let closing=fixture.workflow.next();@Expect(text(field(closing,"operation"),"kind"),"close")
            let sequence=number(closing,"sequence");var refused=false
            try{fixture.workflow.acknowledge(sequence,jsonObject([JsonObjectEntry("schema",jsonString("axyndra.managed-channel-close-result/v1")),
                JsonObjectEntry("lease_id",jsonString(fixture.session.leaseId)),JsonObjectEntry("resources_released",jsonBool(false))]))}
                catch(_:Exception){refused=true}
            @Expect(refused,true);@Expect(text(fixture.session.policy.snapshot(),"status")!="terminated",true)
            fixture.workflow.acknowledge(sequence,jsonObject([JsonObjectEntry("schema",jsonString("axyndra.managed-channel-close-result/v1")),
                JsonObjectEntry("lease_id",jsonString(fixture.session.leaseId)),JsonObjectEntry("resources_released",jsonBool(true))]))
            @Expect(text(fixture.workflow.next(),"status"),"complete")
            fixture.workflow.close();refused=false
            try{fixture.workflow.acknowledge(sequence,jsonObject([]))}catch(_:Exception){refused=true};@Expect(refused,true)
        }finally{fixture.close()}
    }
    @TestCase
    func functionBreakpointRequiresNoFileObservationAndInvalidArgumentsStopInPurePrepare():Unit{
        let fixture=DapOwnedControlFixture("{\"action\":\"threads\"}")
        try{
            let request=parseUnifiedJson("{\"action\":\"remove_breakpoint\",\"function\":\"main\"}")
            @Expect(dapOwnedDebugPathRequests(request,dapOwnedControlConfiguration(),Some(fixture.session)).items.size,0)
            let args=jsonObject([JsonObjectEntry("action",jsonString("channel_prepare")),JsonObjectEntry("tool",jsonString("debug")),
                JsonObjectEntry("input",parseUnifiedJson("{\"action\":\"read_memory\",\"count\":-1}")),
                JsonObjectEntry("configuration",dapOwnedControlConfiguration())])
            var refused=false;try{let _=dapOwnedDebugPrepare(args,Some(fixture.session))}catch(_:Exception){refused=true}
            @Expect(refused,true)
        }finally{fixture.close()}
    }
}
