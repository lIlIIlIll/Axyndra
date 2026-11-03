package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.collection.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private func rpc290Base():PluginDocumentLatestJournalStreamReference{
    let digest=modelPolicySha256Text("x")
    parsePluginDocumentLatestJournalStreamReference(objectValue([
        ValueField("schema",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_REFERENCE_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),
        ValueField("encoding",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_ENCODING)),
        ValueField("bytes",integerValue(1)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue(PLUGIN_DOCUMENT_LATEST_JOURNAL_STREAM_CONTENT_TYPE))])).value().getOrThrow()
}
private func rpc290Start(rpc:HostLivePolicyDataRPC):Unit{
    @Expect(rpc.begin("retain","original-call",7,liveRPCInput247(),nullValue(),nullValue()).isOk(),true)
    @Expect(rpc.appendParameters(0,"{}".toArray()).isOk(),true)
    @Expect(rpc.endParameters(liveRPCInput247()).isOk(),true)
    @Expect(rpc.appendBase(0,"x".toArray()).isOk(),true)
    @Expect(rpc.endBase(rpc290Base()).isOk(),true)
    @Expect(rpc.appendReceipt(0,0,"{}".toArray()).isOk(),true)
}
private func rpc290OriginalWholeJSON(value:AgentValue):(Int64,String){
    // Fixture oracle from the original full serializer; its large String
    // expires before the independently paid streaming passes are exercised.
    let original=encodeAgentValue(value);(original.size,modelPolicySha256Text(original))
}
// Real Host data codec, original loan and original allocation pool. Replies
// here are explicitly scripted transport acknowledgements, never real Store
// Source/approval/Receipt/effect claims. Actual Root integration remains open.
@Test
class HostLivePolicyFullErrorRPC290Tests {
    @TestCase
    func everyErrorOffsetAndEOFAreCheckedBeforeNativeExchange():Unit{
        let calls=AtomicInt64(0);let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=pool.acquire(1)
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1)
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("rpc290","{\"accepted\":true}"))},
            {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,64)
        let rpc=HostLivePolicyDataRPC(loan,"actual.data/v1",1,owner,1048576,{=>Result<Unit>.Ok(())})
        try{
            rpc290Start(rpc);let initial=calls.load()
            @Expect(rpc.beginReceiptError(1,4,modelPolicySha256Text("null")).isError(),true);@Expect(calls.load(),initial)
            @Expect(rpc.beginReceiptError(0,4,modelPolicySha256Text("null")).isOk(),true)
            let begun=calls.load()
            @Expect(rpc.appendReceiptError(0,1,"null".toArray()).isError(),true)
            @Expect(rpc.endReceiptError(0).isError(),true)
            @Expect(rpc.endReceipt(0,2,modelPolicySha256Text("{}"),modelPolicySha256Text("proposal"),nullValue()).isError(),true)
            @Expect(rpc.appendReceipt(0,2,"x".toArray()).isError(),true)
            @Expect(rpc.endReceiptStreamed(0,2,modelPolicySha256Text("{}"),modelPolicySha256Text("proposal"),0,"").isError(),true)
            @Expect(calls.load(),begun)
            @Expect(rpc.appendReceiptError(0,0,"null".toArray()).isOk(),true)
            @Expect(rpc.endReceiptError(0).isOk(),true)
            @Expect(rpc.endReceiptStreamed(0,2,modelPolicySha256Text("{}"),modelPolicySha256Text("proposal"),4,modelPolicySha256Text("null")).isOk(),true)
            @Expect(rpc.appendReceipt(1,0,"{}".toArray()).isOk(),true)
            @Expect(pool.usage()[0],1)
        }finally{let _=rpc.release();loan.close();owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func dataLargerThanOneFrameKeepsCompleteBytesAndSmallFinalDescriptor():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=pool.acquire(1);let actions=ArrayList<String>();let copied=ArrayList<Byte>()
        let loan=HostPluginPureDataLoan({raw,_=>
            let value=parseUnifiedJson(raw,maxBytes:196608,maxDepth:32);let action=httpIntentText(value,"action");actions.add(action)
            if(action=="append_receipt_error"){
                @Expect(hostLivePolicyRPCInteger(value,"offset"),copied.size)
                let bytes=channelServiceWriteBytes(objectValue([ValueField("id",textValue("fixture")),
                    ValueField("bytes_hex",value.field("bytes_hex").getOrThrow())]),maximumBytes:65536).value().getOrThrow()
                copied.add(all:bytes)
            }
            if(action=="end_receipt_streamed"){@Expect(raw.size<1024,true)
                let descriptor=value.field("error_payload").getOrThrow()
                @Expect(hostLivePolicyRPCInteger(descriptor,"bytes"),copied.size)
                @Expect(httpIntentText(descriptor,"sha256"),modelPolicySha256(copied.toArray()))}
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("rpc290","{\"accepted\":true}"))},
            {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,64)
        let rpc=HostLivePolicyDataRPC(loan,"actual.data/v1",1,owner,1048576,{=>Result<Unit>.Ok(())})
        try{
            rpc290Start(rpc)
            let raw=String.fromUtf8(Array<Byte>(262144,repeat:97))+"\u{0000}中文";let bytes=raw.toArray()
            @Expect(rpc.beginReceiptError(0,bytes.size,modelPolicySha256Text(raw)).isOk(),true)
            var at:Int64=0
            while(at<bytes.size){let end=min(bytes.size,at+65536);@Expect(rpc.appendReceiptError(0,at,bytes[at..end]).isOk(),true);at=end}
            @Expect(rpc.endReceiptError(0).isOk(),true)
            @Expect(rpc.endReceiptStreamed(0,2,modelPolicySha256Text("{}"),modelPolicySha256Text("proposal"),raw.size,modelPolicySha256Text(raw)).isOk(),true)
            @Expect(String.fromUtf8(copied.toArray()),raw)
            var chunks:Int64=0;for(action in actions){if(action=="append_receipt_error"){chunks+=1}};@Expect(chunks,5)
        }finally{let _=rpc.release();loan.close();owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func cancellationNeverAdvancesErrorOffsetAfterMissingActualAcknowledgement():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=pool.acquire(1);let calls=AtomicInt64(0);let cancelled=AtomicBool(false)
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1)
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("rpc290","{\"accepted\":true}"))},
            {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,64)
        let current:()->Result<Unit>={=>if(cancelled.load()){hostPluginResourceError<Unit>("fixture.cancelled","original invocation cancelled")}else{Result<Unit>.Ok(())}}
        let rpc=HostLivePolicyDataRPC(loan,"actual.data/v1",1,owner,1048576,current)
        try{
            rpc290Start(rpc);@Expect(rpc.beginReceiptError(0,4,modelPolicySha256Text("null")).isOk(),true)
            let before=calls.load();cancelled.store(true)
            @Expect(rpc.appendReceiptError(0,0,"null".toArray()).error().getOrThrow().code,"fixture.cancelled")
            @Expect(calls.load(),before);@Expect(rpc.endReceiptError(0).isError(),true)
        }finally{let _=rpc.release();loan.close();owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func originalEscapedJSONBeyondEightMiBUsesExactScalarPeakAndSharedSum():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=pool.acquire(1);owner.ensureRetainedPeak(4194304)
        var value:?AgentValue=Some(objectValue([
            ValueField("kind",textValue("conflict")),ValueField("code",textValue("fixture.original_large_error")),
            ValueField("message",textValue(String.fromUtf8(Array<Byte>(1572864,repeat:0)))),
            ValueField("retryable",boolValue(true)),ValueField("fallback_allowed",boolValue(false)),
            ValueField("fields",listValue([])),ValueField("attempt_failure",nullValue()),ValueField("observation",nullValue())]))
        try{
            let original=rpc290OriginalWholeJSON(value.getOrThrow())
            @Expect(original[0]>8388608,true)
            let payment=owner.deriveRetainedLease()
            try{
                payment.ensureRetainedPeak(1048576)
                let current:()->Result<Unit>={=>Result<Unit>.Ok(())}
                let invoice=HostLiveErrorWriterInvoice290(current);invoice.visit(value.getOrThrow())
                @Expect(invoice.peak,9437194)
                let peak=9437184+invoice.peak+invoice.nodes*512
                payment.ensureRetainedPeak(peak)
                @Expect(pool.usage()[0],1)
                @Expect(pool.usage()[1],4194304+2048+peak)
                let measured=HostLiveErrorWriter290(None<((Int64,Array<Byte>)->Result<Unit>)>,current)
                value.getOrThrow().writeJson(measured,options:JsonWriteOptions.defaults)
                let first=measured.finish();@Expect(first[0],original[0]);@Expect(first[1],original[1])
                let copied=AtomicInt64(0)
                let sent=HostLiveErrorWriter290(Some({at,raw=>
                    @Expect(at,copied.load());@Expect(raw.size<=65536,true);let _=copied.fetchAdd(raw.size);Result<Unit>.Ok(())}),current)
                value.getOrThrow().writeJson(sent,options:JsonWriteOptions.defaults)
                let second=sent.finish();@Expect(second[0],original[0]);@Expect(second[1],original[1]);@Expect(copied.load(),original[0])
            }finally{payment.close()}
        }finally{value=None<AgentValue>;owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func invoiceChecksActualCancellationDuringLargeScalarBeforeWriterAllocates():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let owner=pool.acquire(1);owner.ensureRetainedPeak(4194304)
        var value:?AgentValue=Some(textValue(String.fromUtf8(Array<Byte>(262144,repeat:0))))
        try{
            let payment=owner.deriveRetainedLease()
            try{
                payment.ensureRetainedPeak(1048576);let checks=AtomicInt64(0)
                let current:()->Result<Unit>={=>let count=checks.fetchAdd(1)+1
                    if(count>=4){hostPluginResourceError<Unit>("fixture.invoice_cancelled","original invocation cancelled during scalar scan")}
                    else{Result<Unit>.Ok(())}}
                var rejected=false
                try{HostLiveErrorWriterInvoice290(current).visit(value.getOrThrow())}
                catch(error:HostArtifactOperationFailure){rejected=error.failure.code=="fixture.invoice_cancelled"}
                @Expect(rejected,true);@Expect(checks.load(),4)
            }finally{payment.close()}
            @Expect(pool.usage()[0],1)
        }finally{value=None<AgentValue>;owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
