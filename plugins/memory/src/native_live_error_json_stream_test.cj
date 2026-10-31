package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

private class Error321HashSink <: OutputStream {
    private let hash=SHA256()
    var bytes:Int64=0
    public func write(value:Array<Byte>):Unit{hash.write(value);bytes=memoryLiveAdd(bytes,value.size)}
    public func flush():Unit{}
    func finish():(Int64,String){(bytes,logicalJsonEncodeHex(hash.finish()))}
}
private class Error321UploadSink <: OutputStream {
    private let data:NativeMemoryLiveToolData
    private let hash=SHA256()
    private let buffer=Array<Byte>(65536,repeat:0)
    private var used:Int64=0
    private var offset:Int64=0
    init(data:NativeMemoryLiveToolData){this.data=data}
    public func write(value:Array<Byte>):Unit{
        var at:Int64=0
        while(at<value.size){let size=min(buffer.size-used,value.size-at)
            for(index in 0..size){buffer[used+index]=value[at+index]};used+=size;at+=size
            if(used==buffer.size){flush()}}
    }
    public func flush():Unit{
        if(used==0){return}
        let raw=buffer[..used];hash.write(raw)
        let _=data.handle(liveDataTestRequest("append_receipt_error",extra:[ValueField("ordinal",integerValue(0)),
            ValueField("offset",integerValue(offset)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw)))]))
        offset+=used;used=0
    }
    func finish():(Int64,String){flush();(offset,logicalJsonEncodeHex(hash.finish()))}
}
private class Error321FixtureCell {var value:?AgentError=None}
private class Error321WireCell {var value:?String=None}
private func error321Original():AgentError{
    AgentError(AgentErrorKind.Conflict,"fixture.full_error","NUL\u{0000}汉字😀\\\"",retryable:true,fallbackAllowed:true,
        fields:[ErrorField("first","value\u{0000}"),ErrorField("same","a"),ErrorField("same","b")],
        attemptFailure:Some(AttemptFailure(AttemptFailureKind.ProtocolIncomplete,diagnostics:AttemptFailureDiagnostics(
            elapsedMillis:17,softDeadlineMillis:19,hardDeadlineMillis:23,enteredCompletionGrace:true,
            lastProgressKind:AttemptProgressKind.ToolArgumentProgress,lastProgressAgeMillis:29,providerTerminalObserved:true,
            openContentBlockCount:31,toolCallsStarted:37,toolCallsCompleted:41))),
        observation:Some(OperationObservation("{\"original\":[null,true,false,-0.125,\"\\u0000\\ud83d\\ude00\"]}")))
}
private func error321Visit(raw:String,width:Int64,consume:(AgentError)->Unit):Unit{
    let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728);let owner=pool.acquire(1);let temporary=owner.deriveRetainedLease()
    let decoder=MemoryLiveErrorStream321(raw.size,modelPolicySha256Text(raw),temporary,{bytes=>owner.ensureRetainedPeak(bytes)})
    try{
        // Convert the COMPLETE valid String once, then split actual Bytes.
        // String slicing would validate each fragment and reject split UTF8
        // before the real incremental decoder ever sees its byte boundary.
        let bytes=raw.toArray();var offset:Int64=0
        while(offset<bytes.size){let end=min(bytes.size,offset+width);decoder.append(offset,bytes[offset..end]);offset=end}
        consume(decoder.finish())
        @Expect(pool.usage()[0],1);@Expect(pool.usage()[1]<=134217728,true)
    }finally{decoder.close();owner.close()}
    @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
}
private func error321Reject(raw:String,width!:Int64=1):Bool{
    var rejected=false
    try{error321Visit(raw,width,{_=>()})}catch(_:Exception){rejected=true};rejected
}
private func error321OriginalReject(raw:String):Bool{
    try{
        let value=parseUnifiedJson(raw,maxBytes:raw.size,maxDepth:256)
        memoryLiveErrorFrom(value).isNone()
    }catch(_:Exception){true}
}
private func error321WriteHash(value:AgentValue,writer:LogicalJsonOwnerReservation):(Int64,String){
    let payment=MemoryLiveWriterPayment();payment.visit(value)
    writer.ensureRetainedPeak(memoryLiveAdd(payment.peak,memoryLiveAdd(2097152,memoryLiveMul(payment.nodes,512))))
    let sink=Error321HashSink();value.writeJson(sink,options:JsonWriteOptions.defaults);sink.finish()
}
private func error321LargeValue():AgentError{
    AgentError(AgentErrorKind.Conflict,"fixture.near_original_8m_nul",
        "original NUL "+String.fromUtf8(Array<Byte>(8380416,repeat:0)),retryable:true,fallbackAllowed:true,
        fields:[ErrorField("complete","preserved")],
        attemptFailure:Some(AttemptFailure(AttemptFailureKind.ProtocolIncomplete,diagnostics:AttemptFailureDiagnostics(
            elapsedMillis:17,lastProgressKind:AttemptProgressKind.TextProgress,toolCallsStarted:2))),
        observation:Some(OperationObservation("{\"observed\":true}")))
}
private func error321PressureWire():String{
    stringifyUnifiedJson(memoryLiveErrorValue(AgentError(AgentErrorKind.Conflict,"fixture.pressure",
        "original NUL "+String.fromUtf8(Array<Byte>(4194304,repeat:0)))))
}
private func error321PressureAppend(decoder:MemoryLiveErrorStream321,raw:String):Unit{
    var offset:Int64=0
    while(offset<raw.size){let end=min(raw.size,offset+65536);decoder.append(offset,raw[offset..end].toArray());offset=end}
    let _=decoder.finish()
}
// Test fixture, ORIGINAL oracle, actual Native and writer all compete in the
// SAME128MiB bank. The escaped48MiB wire/output never accumulates in the test.
// Fixture aliases clear before its owner retires and before Native computes.
private func error321UploadLarge(data:NativeMemoryLiveToolData,pool:LogicalJsonOwnerBudget,
    proposal:LiveDataTestOutput):(Int64,String){
    let owner=pool.acquire(1);let construction=owner.deriveRetainedLease();let fixture=Error321FixtureCell()
    var writer:?LogicalJsonOwnerReservation=None
    try{
        owner.ensureRetainedPeak(8380416+1048576+65536)
        construction.ensureRetainedPeak(8380416*4+1048576)
        fixture.value=Some(error321LargeValue());construction.close()
        writer=Some(owner.deriveRetainedLease())
        let wire=error321WriteHash(memoryLiveErrorValue(fixture.value.getOrThrow()),writer.getOrThrow())
        let expected=error321WriteHash(memoryLiveRecoverableOutput(fixture.value.getOrThrow()),writer.getOrThrow())
        @Expect(wire[0]>8*8388608/2,true);@Expect(expected[0]>8388608,true)
        let _=data.handle(liveDataTestRequest("begin_receipt_error",extra:[ValueField("ordinal",integerValue(0)),
            ValueField("bytes",integerValue(wire[0])),ValueField("sha256",textValue(wire[1]))]))
        let upload=Error321UploadSink(data)
        memoryLiveErrorValue(fixture.value.getOrThrow()).writeJson(upload,options:JsonWriteOptions.defaults)
        let actual=upload.finish();@Expect(actual[0],wire[0]);@Expect(actual[1],wire[1])
        let _=data.handle(liveDataTestRequest("end_receipt_error",extra:[ValueField("ordinal",integerValue(0))]))
        let _=data.handle(liveDataTestRequest("end_receipt_streamed",extra:[ValueField("ordinal",integerValue(0)),
            ValueField("bytes",integerValue(proposal.body.size)),ValueField("sha256",textValue(modelPolicySha256Text(proposal.body))),
            ValueField("proposal_digest",proposal.manifest.field("proposal_digest").getOrThrow()),
            ValueField("error_payload",objectValue([ValueField("bytes",integerValue(wire[0])),ValueField("sha256",textValue(wire[1]))]))]))
        @Expect(pool.usage()[1]<=134217728,true);expected
    }finally{
        fixture.value=None;construction.close()
        match(writer){case Some(value)=>value.close();case None=>()};writer=None;owner.close()
    }
}
private func error321DrainHash(data:NativeMemoryLiveToolData,metadata:AgentValue):(Int64,String){
    let manifest=parseUnifiedJson(liveDataTestDownload(data,metadata.field("manifest").getOrThrow()))
    let hash=SHA256();var count:Int64=0;var pageOffset:Int64=0
    while(pageOffset<documentDataInteger(metadata,"payload_count")){
        let page=data.handle(liveDataTestRequest("describe",extra:[ValueField("offset",integerValue(pageOffset)),ValueField("count",integerValue(32))]))
        for(descriptor in page.field("payloads").getOrThrow().items){
            let slot=memoryDocumentText(descriptor,"slot");let size=documentDataInteger(descriptor,"bytes")
            @Expect(size<=8388608,true);let partHash=SHA256();var at:Int64=0
            while(at<size){
                let part=data.handle(liveDataTestRequest("download",extra:[ValueField("slot",textValue(slot)),ValueField("offset",integerValue(at)),ValueField("max_bytes",integerValue(65536))]))
                let raw=memoryLiveHex(memoryDocumentText(part,"bytes_hex"));hash.write(raw);partHash.write(raw)
                @Expect(documentDataInteger(part,"offset"),at);at+=raw.size;count+=raw.size;@Expect(memoryLiveBool(part,"last"),at==size)
            };@Expect(logicalJsonEncodeHex(partHash.finish()),memoryDocumentText(descriptor,"sha256"))
        };pageOffset=documentDataInteger(page,"next_offset")
    }
    let digest=logicalJsonEncodeHex(hash.finish());@Expect(count,documentDataInteger(manifest,"total_bytes"));@Expect(digest,memoryDocumentText(manifest,"sha256"))
    (count,digest)
}

@Test
class NativeMemoryIncrementalErrorCustodyTests321 {
    @TestCase
    func allEightTypedFieldsAndSplitEveryEscapeMatchOriginalDecoder():Unit{
        let original=error321Original();let raw=stringifyUnifiedJson(memoryLiveErrorValue(original))
        error321Visit(raw,1,{decoded=>
            @Expect(canonicalAgentValue(memoryLiveErrorValue(decoded)),canonicalAgentValue(memoryLiveErrorValue(original)))
            @Expect(decoded.fields.size,3);@Expect(decoded.fallbackAllowed,true)
            @Expect(decoded.attemptFailure.getOrThrow().diagnostics.toolCallsCompleted,41)})
    }
    @TestCase
    func nearOriginalEightMiBNulReplaysAndStreamsCompleteOutputInActual128MiBBank():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728);let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},sharedCustody:true)
        try{
            liveDataTestStart(data,"{\"items\":[{\"content\":\"first\"}]}")
            let proposal=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")))
            liveDataTestRequireProposal(proposal)
            liveDataTestUpload(data,"append_receipt",proposal.body,ordinal:0)
            let expected=error321UploadLarge(data,pool,proposal)
            let complete=data.handle(liveDataTestRequest("compute"));@Expect(memoryLiveBool(complete,"is_error"),true)
            let actual=error321DrainHash(data,complete);@Expect(actual[0],expected[0]);@Expect(actual[1],expected[1])
            @Expect(pool.usage()[0],1);@Expect(pool.usage()[1]<=134217728,true)
        }finally{data.close()};@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func duplicateKeysNumbersSurrogatesControlsAndTrailingGrammarMatchOriginalRejection():Unit{
        let raw=stringifyUnifiedJson(memoryLiveErrorValue(error321Original()))
        for(changed in [raw+"true",raw[..raw.size-1]+",}",raw.replace("\"kind\":", "\"kind\":\"conflict\",\"kind\":"),
            raw.replace("\"retryable\":true", "\"retryable\":01"),raw.replace("\"retryable\":true", "\"retryable\":tru"),
            raw.replace("NUL\\u0000", "NUL\\ud800"),raw.replace("NUL\\u0000", "NUL\\udc00"),
            raw.replace("NUL\\u0000", "NUL\u{0000}")]){
            @Expect(error321OriginalReject(changed),true);@Expect(error321Reject(changed),true)
        }
    }
    @TestCase
    func wholeHashMissingEofAndGapNeverProduceTypedError():Unit{
        let raw=stringifyUnifiedJson(memoryLiveErrorValue(error321Original()))
        for(mode in ["hash","eof","gap"]){
            let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728);let owner=pool.acquire(1);let child=owner.deriveRetainedLease()
            let decoder=MemoryLiveErrorStream321(raw.size,modelPolicySha256Text(if(mode=="hash"){raw+"x"}else{raw}),child,{bytes=>owner.ensureRetainedPeak(bytes)})
            var rejected=false
            try{decoder.append(if(mode=="gap"){1}else{0},raw[..if(mode=="eof"){raw.size-1}else{raw.size}].toArray());let _=decoder.finish()}
            catch(_:Exception){rejected=true}finally{decoder.close();owner.close()}
            @Expect(rejected,true);@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }
    }
    @TestCase
    func errorShapeAndUntrustedObservationRemainOriginalTypedChecks():Unit{
        let raw=stringifyUnifiedJson(memoryLiveErrorValue(error321Original()))
        for(changed in [raw.replace("\"retryable\":true", "\"retryable\":1"),
            raw.replace("\"fallback_allowed\":true", "\"fallback_allowed\":\"true\""),
            raw.replace("\"kind\":\"conflict\"", "\"kind\":\"future-kind\""),
            raw.replace("\"authorizes_effects\":false", "\"authorizes_effects\":true"),
            raw.replace("\"name\":\"first\"", "\"wrong\":\"first\"")]){
            @Expect(error321OriginalReject(changed),true);@Expect(error321Reject(changed,width:7),true)
        }
    }
    @TestCase
    func depthAndRawUtf8RemainFullyValidatedWithoutEscapedWireStorage():Unit{
        let raw=stringifyUnifiedJson(memoryLiveErrorValue(error321Original()))
        let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728);let owner=pool.acquire(1);let child=owner.deriveRetainedLease()
        let bytes=raw.toArray();for(index in 0..bytes.size where bytes[index]>=0x80){bytes[index]=0xFF;break}
        let decoder=MemoryLiveErrorStream321(bytes.size,modelPolicySha256(bytes),child,{size=>owner.ensureRetainedPeak(size)})
        var rejected=false
        try{decoder.append(0,bytes);let _=decoder.finish()}catch(_:Exception){rejected=true}finally{decoder.close();owner.close()}
        @Expect(rejected,true);@Expect(pool.usage()[0],0)
        var nested="null";for(_ in 0..257){nested="["+nested+"]"}
        let deep="{\"kind\":\"conflict\",\"code\":\"fixture.depth\",\"message\":\"complete\",\"retryable\":false,"+
            "\"fallback_allowed\":false,\"fields\":[],\"attempt_failure\":null,\"observation\":{"+
            "\"schema\":\"axyndra.operation-observation/v1\",\"trust\":\"untrusted_data\",\"authorizes_effects\":false,\"content\":"+nested+"}}"
        @Expect(error321OriginalReject(deep),true);@Expect(error321Reject(deep,width:11),true)
    }
    @TestCase
    func realCompetingReservationRefusesUnpaidScalarAndRetainsItsOwnOwner():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728);let competing=pool.acquire(1);competing.ensureRetainedPeak(112*1048576)
        // The same competing reservation also prepays every fixture raw,
        // escaped and conversion backing; it is not an unbilled large input.
        let fixture=Error321WireCell();fixture.value=Some(error321PressureWire())
        let owner=pool.acquire(1);let child=owner.deriveRetainedLease()
        let decoder=MemoryLiveErrorStream321(fixture.value.getOrThrow().size,
            modelPolicySha256Text(fixture.value.getOrThrow()),child,{bytes=>owner.ensureRetainedPeak(bytes)})
        var rejected=false
        try{error321PressureAppend(decoder,fixture.value.getOrThrow())}catch(_:Exception){rejected=true}
        finally{decoder.close();owner.close()}
        @Expect(rejected,true);@Expect(pool.usage()[0],1);@Expect(pool.usage()[1],112*1048576)
        fixture.value=None;competing.close();@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func closingUnfinishedDecoderDoesNotRefundItsLiveOriginalAncestor():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: 134217728);let owner=pool.acquire(1);let child=owner.deriveRetainedLease()
        let raw=stringifyUnifiedJson(memoryLiveErrorValue(error321Original()))
        let decoder=MemoryLiveErrorStream321(raw.size,modelPolicySha256Text(raw),child,{bytes=>owner.ensureRetainedPeak(bytes)})
        decoder.append(0,raw[..19].toArray());let before=pool.usage()[1]
        decoder.close();@Expect(pool.usage()[0],1);@Expect(pool.usage()[1],before)
        owner.close();@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
