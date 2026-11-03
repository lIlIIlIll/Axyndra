package memory_plugin

import agent_domain.*
import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func error289Upload(data:NativeMemoryLiveToolData,error:AgentError):AgentValue{
    let raw=stringifyUnifiedJson(memoryLiveErrorValue(error))
    let descriptor=objectValue([ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(modelPolicySha256Text(raw)))])
    let _=data.handle(liveDataTestRequest("begin_receipt_error",extra:[ValueField("ordinal",integerValue(0)),
        ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(modelPolicySha256Text(raw)))]))
    liveDataTestUpload(data,"append_receipt_error",raw,ordinal:0,width:65536)
    let _=data.handle(liveDataTestRequest("end_receipt_error",extra:[ValueField("ordinal",integerValue(0))]))
    descriptor
}
private func error289End(data:NativeMemoryLiveToolData,proposal:LiveDataTestOutput,descriptor:AgentValue):Unit{
    liveDataTestRequireProposal(proposal)
    let _=data.handle(liveDataTestRequest("end_receipt_streamed",extra:[ValueField("ordinal",integerValue(0)),
        ValueField("bytes",integerValue(proposal.body.size)),ValueField("sha256",textValue(modelPolicySha256Text(proposal.body))),
        ValueField("proposal_digest",proposal.manifest.field("proposal_digest").getOrThrow()),ValueField("error_payload",descriptor)]))
}

// Actual Native objects, original replay/business decoder and real pool.
// These controls exercise data transport; no Host Source or Receipt claim.
@Test
class NativeMemoryFullReceiptErrorTransportTests289{
    @TestCase
    func errorBeyondOneFrameRetainsOriginalTypedAndModelOutput():Unit{
        let pool=LogicalJsonOwnerBudget();let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)})
        let error=AgentError(AgentErrorKind.Conflict,"fixture.large_known_error",
            String.fromUtf8(Array<Byte>(262144,repeat:97))+"\u{0000}汉字\\\"",retryable:true,
            fields:[ErrorField("original","preserved")],observation:Some(OperationObservation("{\"observed\":true}")))
        try{
            liveDataTestStart(data,"{\"items\":[{\"content\":\"first\"}]}")
            let proposal=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")))
            liveDataTestRequireProposal(proposal)
            liveDataTestUpload(data,"append_receipt",proposal.body,ordinal:0)
            let descriptor=error289Upload(data,error)
            @Expect(documentDataInteger(descriptor,"bytes")>196608,true)
            error289End(data,proposal,descriptor)
            let completed=data.handle(liveDataTestRequest("compute"))
            @Expect(memoryLiveBool(completed,"is_error"),true)
            let result=liveDataTestDrain(data,completed)
            @Expect(result.body,stringifyUnifiedJson(memoryLiveRecoverableOutput(error)))
        }finally{data.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func streamedNullSuccessMatchesOriginalInlineReceiptOutput():Unit{
        let first=NativeMemoryLiveToolData();let second=NativeMemoryLiveToolData()
        try{
            liveDataTestStart(first,"{\"items\":[{\"content\":\"first\"}]}");liveDataTestStart(second,"{\"items\":[{\"content\":\"first\"}]}")
            let one=liveDataTestDrain(first,first.handle(liveDataTestRequest("compute")))
            let two=liveDataTestDrain(second,second.handle(liveDataTestRequest("compute")))
            @Expect(one.body,two.body);liveDataTestSettle(first,one,0)
            liveDataTestUpload(second,"append_receipt",two.body,ordinal:0);error289End(second,two,nullValue())
            @Expect(liveDataTestDrain(first,first.handle(liveDataTestRequest("compute"))).body,
                liveDataTestDrain(second,second.handle(liveDataTestRequest("compute"))).body)
        }finally{first.close();second.close()}
    }
    @TestCase
    func changedErrorHashOffsetAndNullSubstitutionReleaseWithoutReplay():Unit{
        for(mode in ["hash","offset","null"]){
            let pool=LogicalJsonOwnerBudget();let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)});var rejected=false
            try{
                liveDataTestStart(data,"{\"items\":[{\"content\":\"first\"}]}")
                let proposal=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")))
            liveDataTestRequireProposal(proposal)
                liveDataTestUpload(data,"append_receipt",proposal.body,ordinal:0)
                let raw=stringifyUnifiedJson(memoryLiveErrorValue(AgentError(AgentErrorKind.Conflict,"fixture.error","complete original error")))
                let _=data.handle(liveDataTestRequest("begin_receipt_error",extra:[ValueField("ordinal",integerValue(0)),
                    ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(modelPolicySha256Text(if(mode=="hash"){raw+"x"}else{raw})))]))
                if(mode=="null"){error289End(data,proposal,nullValue())}
                else{
                    let _=data.handle(liveDataTestRequest("append_receipt_error",extra:[ValueField("ordinal",integerValue(0)),
                        ValueField("offset",integerValue(if(mode=="offset"){1}else{0})),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw.toArray())))]))
                    let _=data.handle(liveDataTestRequest("end_receipt_error",extra:[ValueField("ordinal",integerValue(0))]))}
            }catch(_:Exception){rejected=true}finally{data.close()}
            @Expect(rejected,true);@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }
    }
    @TestCase
    func actualCancellationDuringErrorUploadDropsTheSamePrivateOwners():Unit{
        let pool=LogicalJsonOwnerBudget();let guard=LiveDataTestGuard()
        let data=NativeMemoryLiveToolData(allocate:{bytes=>pool.acquire(bytes)},current:{=>guard.check()})
        try{
            liveDataTestStart(data,"{\"items\":[{\"content\":\"first\"}]}")
            let proposal=liveDataTestDrain(data,data.handle(liveDataTestRequest("compute")))
            liveDataTestRequireProposal(proposal)
            liveDataTestUpload(data,"append_receipt",proposal.body,ordinal:0)
            let _=data.handle(liveDataTestRequest("begin_receipt_error",extra:[ValueField("ordinal",integerValue(0)),
                ValueField("bytes",integerValue(4)),ValueField("sha256",textValue(modelPolicySha256Text("null")))]))
            guard.cancelled=true;var rejected=false
            try{let _=data.handle(liveDataTestRequest("append_receipt_error",extra:[ValueField("ordinal",integerValue(0)),
                ValueField("offset",integerValue(0)),ValueField("bytes_hex",textValue("6e756c6c"))]))}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
        }finally{data.close()}
    }
}
