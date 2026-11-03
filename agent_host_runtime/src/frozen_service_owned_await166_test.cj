package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import std.sync.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class ActualFrozenFutureController166Tests {
    @TestCase
    func runningWorkerCannotRetirePaymentOrConsumeAndOneRealJoinAllowsExactOnce166():Unit{
        let before=nativeControlMetadataUsage113()
        actualFutureFrame166()
        let after=nativeControlMetadataUsage113()
        @Expect(after[0],before[0]);@Expect(after[1],before[1])
    }
    private func actualFutureFrame166():Unit{
        let root=reserveNativeControlMetadata(1048576)
        try{
            let phase=root.deriveRetainedLease();phase.ensureRetainedPeak(1048576)
            let entered=AtomicBool(false);let released=AtomicBool(false);let returned=AtomicBool(false)
            let current=AtomicBool(true);let calls=AtomicInt64(0)
            let controller=HostFrozenServiceAwait166(phase,"job.wait","actual-wait-intent-166",{=>
                if(current.load()){Result<Unit>.Ok(())}else{Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"test.cancelled","current frame was cancelled"))}},
                {=>calls.fetchAdd(1);entered.store(true)
                    while(!released.load()){sleep(Duration.millisecond)}
                    returned.store(true);JavaScriptHostResult<String>.Ok("{}")})
            let joined=spawn {controller.startAndJoin()}
            var observed=false
            try{
                let until=MonoTime.now()+Duration.second*5
                while(!entered.load() && MonoTime.now()<until){sleep(Duration.millisecond)}
                @Expect(entered.load());@Expect(calls.load(),1);@Expect(!returned.load())
                @Expect(controller.retireReturned().isError())
                @Expect(match(controller.consume("actual-wait-intent-166","job.wait",objectValue([
                    ValueField("intent_id",textValue("actual-wait-intent-166"))]))){case JavaScriptHostResult.Err(_)=>true;case _=>false})
                released.store(true);let result=joined.get();observed=true
                @Expect(result.isOk());@Expect(returned.load())
                @Expect(controller.startAndJoin().isError())
                @Expect(match(controller.consume("wrong-intent","job.wait",objectValue([
                    ValueField("intent_id",textValue("wrong-intent"))]))){case JavaScriptHostResult.Err(_)=>true;case _=>false})
                let consumedResult175=controller.consume("actual-wait-intent-166","job.wait",objectValue([
                    ValueField("intent_id",textValue("actual-wait-intent-166"))]))
                @Expect(match(consumedResult175){case JavaScriptHostResult.Ok(value)=>value=="{}";case _=>false})
                @Expect(controller.consumed());@Expect(calls.load(),1)
                @Expect(match(controller.consume("actual-wait-intent-166","job.wait",objectValue([
                    ValueField("intent_id",textValue("actual-wait-intent-166"))]))){case JavaScriptHostResult.Err(_)=>true;case _=>false})
                @Expect(controller.retireReturned().isOk())
            }finally{released.store(true);if(!observed){let _=joined.get()};let _=controller.retireReturned()}
        }finally{root.close()}
    }
}
