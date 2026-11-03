package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func liveDataTestRequest(action:String,extra!:Array<ValueField>=[],sequence!:Int64=1):AgentValue{
    let fields=ArrayList<ValueField>([ValueField("schema",textValue(MEMORY_LIVE_TOOL_DATA_SCHEMA)),ValueField("action",textValue(action)),ValueField("sequence",integerValue(sequence))])
    fields.add(all:extra);objectValue(fields.toArray())
}
func liveDataTestEmpty():String{
    MEMORY_LATEST_JOURNAL_FRAME_MAGIC+latestJournalFrameTestStart(0,0)+latestJournalFrameTestEnd(0,0,0,0)
}
func liveDataTestLedger(through:Int64):AgentValue{
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),ValueField("parent_operation_id",textValue("parent")),
        ValueField("through_sequence",integerValue(through)),ValueField("tip",if(through==0){nullValue()}else{objectValue([
            ValueField("sequence",integerValue(through)),ValueField("operation_id",textValue("child")),ValueField("receipt_id",textValue("receipt")),
            ValueField("plan_sha256",textValue(modelPolicySha256Text("actual-test-data"))),ValueField("outcome",textValue("completed"))])})])
}
func liveDataTestBegin(raw:String,input:String,through!:Int64=0,sequence!:Int64=1,tool!:String="retain"):AgentValue{
    liveDataTestRequest("begin",sequence:sequence,extra:[ValueField("tool",textValue(tool)),ValueField("call_id",textValue("actual-call")),
        ValueField("now_millis",integerValue(1000)),ValueField("prior_receipts",liveDataTestLedger(through)),
        ValueField("input_payload",objectValue([ValueField("bytes",integerValue(input.size)),ValueField("sha256",textValue(modelPolicySha256Text(input)))])),
        ValueField("stream",objectValue([ValueField("reference",latestJournalFrameTestReference(raw.size,modelPolicySha256Text(raw)).toValue()),
            ValueField("request_digest",textValue(modelPolicySha256Text("actual request"))),ValueField("access_policy_digest",textValue(modelPolicySha256Text("actual frozen policy"))),
            ValueField("view_policy_digest",textValue(modelPolicySha256Text("actual frozen latest view")))]))])
}
func liveDataTestUpload(data:NativeMemoryLiveToolData,action:String,text:String,ordinal!:Int64= -1,sequence!:Int64=1,width!:Int64=65536):Unit{
    let raw=text.toArray();var at:Int64=0
    while(at<raw.size){let end=min(raw.size,at+width);let fields=ArrayList<ValueField>([
        ValueField("offset",integerValue(at)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw[at..end])))])
        if(ordinal>=0){fields.add(ValueField("ordinal",integerValue(ordinal)))}
        let _=data.handle(liveDataTestRequest(action,extra:fields.toArray(),sequence:sequence));at=end}
}
func liveDataTestStart(data:NativeMemoryLiveToolData,input:String,raw!:String=liveDataTestEmpty(),through!:Int64=0,sequence!:Int64=1,tool!:String="retain"):Unit{
    let _=data.handle(liveDataTestBegin(raw,input,through:through,sequence:sequence,tool:tool))
    liveDataTestUpload(data,"append_parameters",input,sequence:sequence,width:7)
    let _=data.handle(liveDataTestRequest("end_parameters",sequence:sequence))
    liveDataTestUpload(data,"append_base",raw,sequence:sequence,width:7)
    let _=data.handle(liveDataTestRequest("end_base",sequence:sequence))
}
func liveDataTestDownload(data:NativeMemoryLiveToolData,descriptor:AgentValue,sequence!:Int64=1):String{
    let slot=memoryDocumentText(descriptor,"slot");let size=documentDataInteger(descriptor,"bytes")
    let bytes=ArrayList<Byte>();var at:Int64=0
    while(at<size){let part=data.handle(liveDataTestRequest("download",sequence:sequence,extra:[ValueField("slot",textValue(slot)),
        ValueField("offset",integerValue(at)),ValueField("max_bytes",integerValue(65536))]))
        let raw=memoryLiveHex(memoryDocumentText(part,"bytes_hex"));@Expect(documentDataInteger(part,"offset"),at)
        bytes.add(all:raw);at+=raw.size;@Expect(memoryLiveBool(part,"last"),at==size)}
    let raw=bytes.toArray();@Expect(modelPolicySha256(raw),memoryDocumentText(descriptor,"sha256"));String.fromUtf8(raw)
}
class LiveDataTestOutput {
    let body:String
    let manifest:AgentValue
    init(body:String,manifest:AgentValue){this.body=body;this.manifest=manifest}
}
func liveDataTestDrain(data:NativeMemoryLiveToolData,metadata:AgentValue,sequence!:Int64=1):LiveDataTestOutput{
    let manifest=parseUnifiedJson(liveDataTestDownload(data,metadata.field("manifest").getOrThrow(),sequence:sequence))
    let parts=StringBuilder();var offset:Int64=0;let total=documentDataInteger(metadata,"payload_count")
    while(offset<total){let page=data.handle(liveDataTestRequest("describe",sequence:sequence,extra:[ValueField("offset",integerValue(offset)),ValueField("count",integerValue(32))]))
        @Expect(documentDataInteger(page,"total"),total)
        for(descriptor in page.field("payloads").getOrThrow().items){@Expect(documentDataInteger(descriptor,"bytes")<=8388608,true)
            parts.append(liveDataTestDownload(data,descriptor,sequence:sequence))}
        offset=documentDataInteger(page,"next_offset")}
    let raw=parts.toString();@Expect(raw.size,documentDataInteger(manifest,"total_bytes"));@Expect(modelPolicySha256Text(raw),memoryDocumentText(manifest,"sha256"))
    LiveDataTestOutput(raw,manifest)
}
// Check the actual original Native result before calling it a proposal.
// A correct invalid-input Completed must never make a negative Receipt test
// pass early. Data tests assert no real Host Source/SQLite/Receipt authority.
func liveDataTestRequireProposal(output:LiveDataTestOutput):Unit{
    @Expect(memoryDocumentText(output.manifest,"kind"),"effect")
    @Expect(output.manifest.field("proposal_digest").isSome(),true)
    @Expect(httpIntentDigest(memoryDocumentText(output.manifest,"proposal_digest")),true)
}
func liveDataTestSettle(data:NativeMemoryLiveToolData,output:LiveDataTestOutput,ordinal:Int64,error!:?AgentError=None,sequence!:Int64=1):Unit{
    liveDataTestRequireProposal(output)
    liveDataTestUpload(data,"append_receipt",output.body,ordinal:ordinal,sequence:sequence)
    let _=data.handle(liveDataTestRequest("end_receipt",sequence:sequence,extra:[ValueField("ordinal",integerValue(ordinal)),
        ValueField("bytes",integerValue(output.body.size)),ValueField("sha256",textValue(modelPolicySha256Text(output.body))),
        ValueField("proposal_digest",output.manifest.field("proposal_digest").getOrThrow()),
        ValueField("error",match(error){case Some(value)=>memoryLiveErrorValue(value);case None=>nullValue()})]))
}
class LiveDataTestGuard {var cancelled=false;func check():Unit{if(cancelled){throw PureProviderError("fixture.cancelled","actual test consumer revoked")}}}

// Real Native data objects, original v3 decoder, original business methods and
// actual shared allocation pool. These are NOT Host Source/SQLite/Receipt tests.
@Test
class NativeMemoryLiveToolDataTests {
    @TestCase
    func completeTwoDraftWirePreservesOriginalOutputAndReleaseOwner():Unit{
        let pool=LogicalJsonOwnerBudget();let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)})
        let input="{\"items\":[{\"content\":\"first\"},{\"content\":\"second\"}]}"
        try{
            liveDataTestStart(data,input)
            let first=data.handle(liveDataTestRequest("compute"));@Expect(memoryDocumentText(first,"kind"),"effect")
            @Expect(memoryDocumentText(first.field("effect").getOrThrow(),"kind"),"row_journal.append")
            let firstData=liveDataTestDrain(data,first);liveDataTestSettle(data,firstData,0)
            let second=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")))
            @Expect(documentDataInteger(parseUnifiedJson(second.body),"ordinal"),1);liveDataTestSettle(data,second,1)
            let complete=data.handle(liveDataTestRequest("compute"));@Expect(memoryDocumentText(complete,"kind"),"completed");@Expect(memoryLiveBool(complete,"is_error"),false)
            let actual=liveDataTestDrain(data,complete)
            let oracle=nativeMemoryTestRequire(memoryReplayOriginalRetain(NativeMemoryJournal([],1000)))
            @Expect(actual.body,stringifyUnifiedJson(oracle.output));@Expect(pool.usage()[0]>0,true)
            let _=data.handle(liveDataTestRequest("release"));@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }finally{data.close()}
    }
    @TestCase
    func newWorkerReplaysFullOriginalOwnPrefixAtSameFrozenClock():Unit{
        let input="{\"items\":[{\"content\":\"first\"},{\"content\":\"second\"}]}"
        let first=NativeMemoryLiveToolData();let next=NativeMemoryLiveToolData()
        try{
            liveDataTestStart(first,input);let known=liveDataTestDrain(first,first.handle(liveDataTestRequest("compute")));first.close()
            liveDataTestStart(next,input,through:1)
            liveDataTestSettle(next,known,0)
            let response=liveDataTestDrain(next,next.handle(liveDataTestRequest("compute")))
            let proposal=parseUnifiedJson(response.body)
            @Expect(documentDataInteger(proposal,"ordinal"),1)
            @Expect(memoryDocumentText(proposal.field("events").getOrThrow().items[0].field("record").getOrThrow(),"id"),"memv3-1000-2")
        }finally{first.close();next.close()}
    }
    @TestCase
    func knownRejectedAppendRetainsFullErrorAndOriginalModelFacingOutput():Unit{
        let pool=LogicalJsonOwnerBudget();let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)})
        let failure=AgentError(AgentErrorKind.Conflict,"fixture.cas","actual known rejection",retryable:true,fallbackAllowed:true,
            fields:[ErrorField("expected","old"),ErrorField("actual","new")],
            attemptFailure:Some(AttemptFailure(AttemptFailureKind.ProtocolIncomplete,diagnostics:AttemptFailureDiagnostics(elapsedMillis:17,lastProgressKind:AttemptProgressKind.TextProgress,toolCallsStarted:2))),
            observation:Some(OperationObservation("{\"observed\":true}")))
        let roundtrip=memoryLiveErrorFrom(memoryLiveErrorValue(failure)).getOrThrow()
        @Expect(canonicalAgentValue(memoryLiveErrorValue(roundtrip)),canonicalAgentValue(memoryLiveErrorValue(failure)))
        try{
            liveDataTestStart(data,"{\"items\":[{\"content\":\"first\"}]}")
            let pending=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")))
            liveDataTestSettle(data,pending,0,error:Some(failure))
            let complete=data.handle(liveDataTestRequest("compute"));@Expect(memoryLiveBool(complete,"is_error"),true)
            let result=liveDataTestDrain(data,complete)
            @Expect(result.body,stringifyUnifiedJson(memoryLiveRecoverableOutput(failure)))
            @Expect(memoryDocumentText(parseUnifiedJson(result.body),"error"),failure.code)
        }finally{data.close()};@Expect(pool.usage()[0],0)
    }
    @TestCase
    func independentCurrentNeverReconstructedFromReadableOldHistory():Unit{
        let body=streamEventTestRaw("\"older readable history\"")
        let raw=MEMORY_LATEST_JOURNAL_FRAME_MAGIC+latestJournalFrameTestStart(1,0)+
            latestJournalFrameTestBodyHeader("event",0,body.size,modelPolicySha256Text(body),false)+body+latestJournalFrameTestEnd(1,0,1,0)
        let data=NativeMemoryLiveToolData()
        try{liveDataTestStart(data,"{\"query\":\"readable\"}",raw:raw,tool:"reflect")
            let result=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")))
            @Expect(documentDataInteger(parseUnifiedJson(result.body),"count"),0)
        }finally{data.close()}
    }
    @TestCase
    func invalidOldBodyAndIncompleteBaseCannotReachBusinessComputation():Unit{
        let valid=streamEventTestRaw("\"body\"");let bad=valid.replace("\"version\":3","\"version\":2")
        let raw=MEMORY_LATEST_JOURNAL_FRAME_MAGIC+latestJournalFrameTestStart(1,0)+
            latestJournalFrameTestBodyHeader("event",0,bad.size,modelPolicySha256Text(bad),false)+bad+latestJournalFrameTestEnd(1,0,1,0)
        let pool=LogicalJsonOwnerBudget();let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)})
        var rejected=false
        try{liveDataTestStart(data,"{\"query\":\"x\"}",raw:raw,tool:"reflect")}
        catch(_:Exception){rejected=true}finally{data.close()};@Expect(rejected,true);@Expect(pool.usage()[0],0)
        let other=NativeMemoryLiveToolData();var incomplete=false
        try{let _=other.handle(liveDataTestBegin(liveDataTestEmpty(),"{}"));let _=other.handle(liveDataTestRequest("compute"))}
        catch(_:Exception){incomplete=true}finally{other.close()};@Expect(incomplete,true)
    }
    @TestCase
    func sequenceOffsetSchemaAndOriginalFullHashFailuresReleaseWithoutReplay():Unit{
        for(mode in ["offset","hash","extra","sequence"]){
            let pool=LogicalJsonOwnerBudget();let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)});var rejected=false
            try{
                let begin=liveDataTestBegin(liveDataTestEmpty(),"{}")
                if(mode=="sequence"){begin.put("sequence",integerValue(Int64.Max))}
                if(mode=="hash"){begin.field("input_payload").getOrThrow().put("sha256",textValue(modelPolicySha256Text("another")))}
                if(mode=="extra"){begin.put("authority",boolValue(true))}
                let _=data.handle(begin)
                let _=data.handle(liveDataTestRequest("append_parameters",extra:[ValueField("offset",integerValue(if(mode=="offset"){1}else{0})),ValueField("bytes_hex",textValue("7b7d"))]))
                let _=data.handle(liveDataTestRequest("end_parameters"))
            }catch(_:Exception){rejected=true}finally{data.close()};@Expect(rejected,true);@Expect(pool.usage()[0],0)
        }
    }
    @TestCase
    func changedFullKnownProposalNeverBecomesFinalSuccess():Unit{
        let input="{\"items\":[{\"content\":\"first\"}]}";let first=NativeMemoryLiveToolData();let next=NativeMemoryLiveToolData()
        try{
            liveDataTestStart(first,input);let previous=liveDataTestDrain(first,first.handle(liveDataTestRequest("compute")));first.close()
            liveDataTestStart(next,"{\"items\":[{\"content\":\"changed\"}]}",through:1)
            liveDataTestSettle(next,previous,0);var rejected=false
            try{let _=next.handle(liveDataTestRequest("compute"))}catch(error:PureProviderError){rejected=error.code=="memory.live_proposal_changed"}
            @Expect(rejected,true)
        }finally{first.close();next.close()}
    }
    @TestCase
    func actualConsumerCancellationBeforeDownloadClosesAllPrivateOwners():Unit{
        let pool=LogicalJsonOwnerBudget();let guard=LiveDataTestGuard()
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},current:{=>guard.check()})
        try{
            liveDataTestStart(data,"{\"items\":[{\"content\":\"first\"}]}");let metadata=data.handle(liveDataTestRequest("compute"))
            @Expect(pool.usage()[0]>0,true);guard.cancelled=true;var rejected=false
            try{let _=data.handle(liveDataTestRequest("download",extra:[ValueField("slot",textValue("manifest")),ValueField("offset",integerValue(0)),ValueField("max_bytes",integerValue(65536))]))}
            catch(error:PureProviderError){rejected=error.code=="fixture.cancelled"}
            @Expect(rejected,true);@Expect(pool.usage()[0],0)
        }finally{data.close()}
    }
    @TestCase
    func originalJsonWriterCrossesEightMiBReferenceWithoutAggregateLimit():Unit{
        let text=String.fromUtf8(Array<Byte>(1400000,repeat:0));let node=textValue(text)
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        try{
            let payment=MemoryLiveWriterPayment();payment.visit(node);owner.ensureRetainedPeak(payment.peak+1048576)
            let sink=MemoryLiveJsonStream({=>()},{bytes=>owner.ensureRetainedPeak(payment.peak+1048576+bytes)})
            node.writeJson(sink,options:JsonWriteOptions.defaults);let actual=sink.finish()
            let original=stringifyUnifiedJson(node)
            @Expect(actual[0],original.size);@Expect(actual[0]>8388608,true);@Expect(actual[1],modelPolicySha256Text(original))
            @Expect(actual[2].size,2);@Expect(actual[2][0].bytes,8388608)
            @Expect(actual[2][0].digest,modelPolicySha256Text(original[..8388608]));@Expect(actual[2][1].digest,modelPolicySha256Text(original[8388608..]))
        }finally{owner.close()};@Expect(pool.usage()[0],0)
    }
    @TestCase
    func outputMustBeDescribedAndFullyConsumedBeforeKnownSettlement():Unit{
        let pool=LogicalJsonOwnerBudget();let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)})
        try{
            liveDataTestStart(data,"{\"items\":[{\"content\":\"first\"}]}");let _=data.handle(liveDataTestRequest("compute"));var rejected=false
            try{let _=data.handle(liveDataTestRequest("download",extra:[ValueField("slot",textValue("payload-0")),ValueField("offset",integerValue(0)),ValueField("max_bytes",integerValue(65536))]))}
            catch(_:Exception){rejected=true};@Expect(rejected,true);@Expect(pool.usage()[0],0)
            // Released computation IDs cannot be recycled by the same worker.
            var stale=false
            try{let _=data.handle(liveDataTestBegin(liveDataTestEmpty(),"{}"))}catch(_:Exception){stale=true};@Expect(stale,true)
        }finally{data.close()}
    }
}
