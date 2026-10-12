package agent_extension_runtime

import agent_domain.*
import agent_sdk.*
import std.env.*
import std.fs.*
import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*
import yjson.JsonNode

class RequestPayloadObserver <: JavaScriptHostObserver {
    let calls=AtomicInt64(0)
    let peakOwners=AtomicInt64(0)
    public func onProgress(invocation:String,value:String):JavaScriptHostResult<Unit>{JavaScriptHostResult.Ok(())}
    public func onServiceRequest(invocation:String,request:String,service:String,arguments:String):JavaScriptHostResult<String>{
        let n=calls.fetchAdd(1)
        if(n==0){peakOwners.store(nativePayloadOwnerBudget.usage()[0])}
        else{@Expect(nativePayloadOwnerBudget.usage()[0],peakOwners.load())}
        @Expect(service,"fixture.echo");@Expect(parseUnifiedJson(arguments,maxBytes:1048576).field("text").isSome())
        JavaScriptHostResult.Ok("{}")
    }
}
func requestPayloadFixtureRoot():String{
    let root=Directory.createTemp("/tmp").toString()
    let source=getVariable("AXYNDRA_REPO_ROOT").getOrThrow()+"/support_tests/ordinary_request_payload_host_fixture/peer.py"
    File.writeTo(root+"/worker",File.readFrom(source));let _=FileInfo(root+"/worker").setExecutable(true);root
}
@Test
class OrdinaryServiceRequestPayloadTests {
    @TestCase
    func sameTwoSlotsAcceptMixedRawAndLogicalRequestsThenReleaseOnlyAtResultConsumer():Unit{
        for(mode in ["mixed","many"]){
            let before=nativePayloadOwnerBudget.usage();let root=requestPayloadFixtureRoot();let host=ordinaryPayloadHost(root)
            let baseline=nativePayloadOwnerBudget.usage();let observer=RequestPayloadObserver()
            try{
                let output=match(host.invoke("run",stringifyUnifiedJson(objectValue([ValueField("mode",textValue(mode))])),
                    identity:quotaIdentity("tool"),timeoutMillis:10000,toolPayloadLimits:Some(OrdinaryToolPayloadLimits("run")),observer:Some(observer))){
                    case JavaScriptHostResult.Ok(value)=>value;case JavaScriptHostResult.Err(error)=>throw IllegalStateException(error.code)}
                try{
                    let expected=if(mode=="many"){32}else{2}
                    @Expect(observer.calls.load(),expected);@Expect(nativePayloadOwnerBudget.usage()[0],baseline[0]+2)
                    @Expect(parseUnifiedJson(output.resultJson).field("calls").getOrThrow().asNumberText(),expected.toString())
                }finally{output.releasePayload()}
                @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),baseline))
            }finally{@Expect(host.awaitCleanup(timeoutMillis:2000).isOk());remove(root,recursive:true)}
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before))
        }
    }
    @TestCase
    func wrongWindowSequenceHashOverlapAndIncompleteRequestNeverDispatchObserver():Unit{
        for(mode in ["window","sequence","hash","overlap","incomplete","bad_eof","bad_utf8","identity"]){
            let before=nativePayloadOwnerBudget.usage();let root=requestPayloadFixtureRoot();let host=ordinaryPayloadHost(root);let observer=RequestPayloadObserver()
            try{
                let output=host.invoke("run",stringifyUnifiedJson(objectValue([ValueField("mode",textValue(mode))])),
                    identity:quotaIdentity("tool"),timeoutMillis:1000,toolPayloadLimits:Some(OrdinaryToolPayloadLimits("run")),observer:Some(observer))
                @Expect(!output.isOk());@Expect(observer.calls.load(),0)
            }finally{@Expect(host.awaitCleanup(timeoutMillis:2000).isOk());remove(root,recursive:true)}
            @Expect(nativePayloadUsageEqual(nativePayloadOwnerBudget.usage(),before))
        }
    }
    @TestCase
    func defaultTerminalOnlyReceiverCannotAcceptLogicalServiceRequest():Unit{
        let root=requestPayloadFixtureRoot();let host=ordinaryPayloadHost(root);let observer=RequestPayloadObserver()
        try{
            let output=host.invoke("run","{\"mode\":\"many\"}",identity:quotaIdentity("tool"),timeoutMillis:1000,observer:Some(observer))
            @Expect(!output.isOk());@Expect(observer.calls.load(),0)
        }finally{@Expect(host.awaitCleanup(timeoutMillis:2000).isOk());remove(root,recursive:true)}
    }
}
