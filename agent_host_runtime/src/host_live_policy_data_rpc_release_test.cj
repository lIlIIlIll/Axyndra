package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// Actual captured-loan/reservation controls; neither reply authorizes a Source.
@Test
class LivePolicyRPCNativeRelease251Tests {
    @TestCase
    func exactNativeReleaseReplyDropsTheActualReplyOwnerOnce():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1);let calls=AtomicInt64(0)
        let loan=HostPluginPureDataLoan({_,_=>let _=calls.fetchAdd(1)
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("release251","{\"released\":true}"))},
            {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,16)
        let rpc=HostLivePolicyDataRPC(loan,"actual.frozen/v1",1,owner,1048576,{=>Result<Unit>.Ok(())})
        try{
            @Expect(rpc.release().isOk(),true);@Expect(calls.load(),1)
            @Expect(pool.usage()[0],1)
            @Expect(rpc.release().isOk(),true);@Expect(calls.load(),1)
        }finally{loan.close();owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func uploadAcknowledgementCannotSubstituteForPhysicalProducerRelease():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(1)
        let loan=HostPluginPureDataLoan({_,_=>
            JavaScriptHostResult<JavaScriptHostInvocationResult>.Ok(JavaScriptHostInvocationResult("release251","{\"accepted\":true}"))},
            {bytes=>pool.acquire(bytes)},{=>Result<Unit>.Ok(())},MonoTime.now()+Duration.second*5,16)
        let rpc=HostLivePolicyDataRPC(loan,"actual.frozen/v1",1,owner,1048576,{=>Result<Unit>.Ok(())})
        try{
            @Expect(rpc.release().error().getOrThrow().code,"plugin.live_rpc_reply")
            @Expect(pool.usage()[0],1)
        }finally{loan.close();owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
