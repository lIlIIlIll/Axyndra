package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Pure transport/real reservation tests only. The scripted pure reply is not
// a Store fact, Runtime Source, Receipt, approval or successful Memory effect.
func liveRPCInput247():PluginDocumentPayloadReference{
    let digest=modelPolicySha256Text("{}")
    parsePluginDocumentPayloadReference(objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue("utf8")),
        ValueField("bytes",integerValue(2)),ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue("text/plain; charset=utf-8"))])).value().getOrThrow()
}

@Test
class LivePolicyDataRPCOwner247Tests {
    @TestCase
    func originalInputOffsetAndEOFAreCheckedBeforeAnotherNativeDispatch():Unit{
        let calls=AtomicInt64(0);let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1)
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("rpc247","{\"accepted\":true}"))},
            {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,16)
        let rpc=HostLivePolicyDataRPC(loan,"test.actual-frozen/v1",1,owner,1048576,{=>Result<Unit>.Ok(())})
        try{
            @Expect(rpc.begin("retain","actual-call",7,liveRPCInput247(),nullValue(),nullValue()).isOk(),true)
            @Expect(calls.load(),1)
            @Expect(rpc.appendParameters(1,"{}".toArray()).error().getOrThrow().code,"plugin.live_rpc_offset")
            @Expect(rpc.endParameters(liveRPCInput247()).error().getOrThrow().code,"plugin.live_rpc_eof")
            @Expect(calls.load(),1)
            @Expect(rpc.appendParameters(0,"{}".toArray()).isOk(),true)
            @Expect(rpc.endParameters(liveRPCInput247()).isOk(),true)
            @Expect(calls.load(),3)
            @Expect(rpc.appendParameters(2,"a".toArray()).isError(),true)
            @Expect(calls.load(),3)
            @Expect(pool.usage()[0],1)
        }finally{let _=rpc.release();loan.close();owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func malformedAcknowledgementClosesActualReplyAndDoesNotAdvanceInputState():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1);let calls=AtomicInt64(0)
        let loan=HostPluginPureDataLoan({_,_=>let ordinal=calls.fetchAdd(1)
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("rpc247",
                if(ordinal==0){"{\"accepted\":true,\"extra\":null}"}else{"{\"accepted\":true}"}))},
            {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,16)
        let rpc=HostLivePolicyDataRPC(loan,"test.actual-frozen/v1",1,owner,1048576,{=>Result<Unit>.Ok(())})
        try{
            @Expect(rpc.begin("retain","actual-call",7,liveRPCInput247(),nullValue(),nullValue()).error().getOrThrow().code,"plugin.live_rpc_reply")
            @Expect(pool.usage()[0],1)
            @Expect(rpc.appendParameters(0,"{}".toArray()).error().getOrThrow().code,"plugin.live_rpc_chunk")
            @Expect(calls.load(),1)
            @Expect(rpc.begin("retain","actual-call",7,liveRPCInput247(),nullValue(),nullValue()).isOk(),true)
            @Expect(calls.load(),2)
        }finally{let _=rpc.release();loan.close();owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func cancellationBeforeExchangeDoesNotMintOrSpendAnUploadAcknowledgement():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1);let calls=AtomicInt64(0)
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1)
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("rpc247","{\"accepted\":true}"))},
            {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,16)
        let rpc=HostLivePolicyDataRPC(loan,"test.actual-frozen/v1",1,owner,1048576,{=>hostPluginResourceError<Unit>("test.cancelled","actual caller cancelled")})
        try{
            @Expect(rpc.begin("retain","actual-call",7,liveRPCInput247(),nullValue(),nullValue()).error().getOrThrow().code,"test.cancelled")
            @Expect(calls.load(),0);@Expect(pool.usage()[0],1)
        }finally{let _=rpc.release();loan.close();owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func measuredMetadataBorrowUsesTheSamePhysicalSessionOwnerAndDoesNotCloseIt():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-live-borrow247"))
        let physical=session.retainExecutionCustody().value().getOrThrow();let visits=AtomicInt64(0)
        try{
            let result=session.run({actual=>
                let metadata=objectValue([ValueField("sequence",integerValue(1)),ValueField("binding",textValue("actual-host-metadata"))])
                let measured=1048576+logicalJsonWriteReservationBytes(metadata,65536)*8+logicalJsonValueNodeCount(metadata)*512
                actual.withLivePolicyRunningMetadata(metadata,{owner,peak=>
                    @Expect(peak,measured);owner.ensureRetainedPeak(peak+65536);let _=visits.fetchAdd(1)})
                // Borrow completion did not release the unique reservation.
                actual.withLivePolicyRunningMetadata(metadata,{owner,peak=>owner.ensureRetainedPeak(peak);let _=visits.fetchAdd(1)})
                Result<AgentValue>.Ok(nullValue())})
            @Expect(result.isOk(),true);@Expect(visits.load(),2)
            @Expect(physical.releaseTransient().isOk(),true)
            @Expect(physical.close().isOk(),true)
        }finally{let _=physical.close();let _=session.close()}
    }
    @TestCase
    func anInertOrFinishedSessionCannotOfferTheRunningMetadataOwner():Unit{
        let session=HostDocumentDataSession(HostArtifactStore("/never-opened-live-borrow-closed247"));let visits=AtomicInt64(0)
        try{
            var rejected=false
            try{session.withLivePolicyRunningMetadata(nullValue(),{_,_=>let _=visits.fetchAdd(1)})}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(visits.load(),0)
            @Expect(session.run({_=>Result<AgentValue>.Ok(nullValue())}).isOk(),true)
            rejected=false
            try{session.withLivePolicyRunningMetadata(nullValue(),{_,_=>let _=visits.fetchAdd(1)})}catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(visits.load(),0)
        }finally{let _=session.close()}
    }
}
