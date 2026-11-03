package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class LiveInputOwnedFlag{var value=false}
class LiveInputOwnedCounter{var value:Int64=0}

// Real same-pool ownership and ORIGINAL codec oracles only. These controls
// do not manufacture a Root, completed read, Receipt or successful pin.
@Test
class PluginLivePolicyInputStreamedOwnerTests{
    @TestCase
    func OnePinPhaseWithSmallInputKeepsRealNearEightMiBOutputLease():Unit{
        let pool=LogicalJsonOwnerBudget();let output=pool.acquire(8388608)
        let session=pool.acquire(65536);let registry=pool.acquire(65536);let pin=pool.acquire(65536)
        try{
            let value=objectValue([ValueField("unicode",textValue("中文😀\u{0000}\"\\")),
                ValueField("number",JsonNode.number("1e0"))])
            let expected=encodeAgentValue(contextReadBusinessInput(value));let consumed=LiveInputOwnedFlag()
            @Expect(pool.usage()[1],117440512)
            livePolicyInputPayloadIdentityOwned(value,pin,{=>Result<Unit>.Ok(())},{bytes,digest=>
                @Expect(bytes,expected.size);@Expect(digest,modelPolicySha256Text(expected))
                @Expect(pool.usage()[0],4);@Expect(pool.usage()[1],117440512);consumed.value=true},extraRetained:1048576)
            @Expect(consumed.value,true);@Expect(pool.usage()[0],4)
        }finally{pin.close();registry.close();session.close();output.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func SameOwnerStoredAndJsonIdentityKeepOriginalByteGrammar():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        try{
            for(value in [nullValue(),boolValue(false),JsonNode.number("-0.0"),
                textValue("中文😀\u{0000}\b\t\n\r\"\\<&'="),
                objectValue([ValueField("z",integerValue(7)),ValueField("a",listValue([JsonNode.number("1e0"),boolValue(true)]))])]){
                @Expect(livePolicyInputStoredDigestStreamedOwned(value,owner,{=>Result<Unit>.Ok(())},extraRetained:1048576),
                    modelPolicySha256Text(encodeStoredValue(value)))
                let expected=encodeAgentValue(contextReadBusinessInput(value));let consumed=LiveInputOwnedFlag()
                livePolicyInputPayloadIdentityOwned(value,owner,{=>Result<Unit>.Ok(())},{bytes,digest=>
                    @Expect(bytes,expected.size);@Expect(digest,modelPolicySha256Text(expected));consumed.value=true},extraRetained:1048576)
                @Expect(consumed.value,true);@Expect(pool.usage()[0],1)
            }
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func FullMechanicalEqualityMatchesOriginalCanonicalValueIncludingNumberSpelling():Unit{
        let a=objectValue([ValueField("z",JsonNode.number("1e0")),ValueField("a",listValue([textValue("中文\u{0000}"),boolValue(true)]))])
        let reordered=objectValue([ValueField("a",listValue([textValue("中文\u{0000}"),boolValue(true)])),ValueField("z",JsonNode.number("1e0"))])
        let respelled=objectValue([ValueField("z",JsonNode.number("1.0")),ValueField("a",listValue([textValue("中文\u{0000}"),boolValue(true)]))])
        let changed=objectValue([ValueField("z",JsonNode.number("1e0")),ValueField("a",listValue([textValue("中文\u{0001}"),boolValue(true)]))])
        for(value in [a,reordered,respelled,changed]){
            @Expect(livePolicyInputSameValue(a,value,0),canonicalAgentValue(a)==canonicalAgentValue(value))}
        @Expect(livePolicyInputSameValue(a,reordered,0),true)
        @Expect(livePolicyInputSameValue(a,respelled,0),false)
        @Expect(livePolicyInputSameValue(a,changed,0),false)
    }
    @TestCase
    func FailedStreamDoesNotCloseBorrowedPinOrPhysicalCleanupDebt():Unit{
        let pool=LogicalJsonOwnerBudget(maximumCharged: LOGICAL_JSON_SATURATION_CAPACITY);let output=pool.acquire(8388608)
        let session=pool.acquire(65536);let cleanupDebt=pool.acquire(4194304);let pin=pool.acquire(65536)
        try{
            @Expect(pool.usage()[1],134217728)
            let value=textValue(String.fromUtf8(Array<Byte>(8388606,repeat:65)))
            let consumed=LiveInputOwnedFlag();var rejected=false
            try{livePolicyInputPayloadIdentityOwned(value,pin,{=>Result<Unit>.Ok(())},{_,_=>consumed.value=true},extraRetained:1048576)}
            catch(_:LogicalJsonPayloadError){rejected=true}
            @Expect(rejected,true);@Expect(consumed.value,false)
            @Expect(pool.usage()[0],4);@Expect(pool.usage()[1],134217728)
        }finally{pin.close();cleanupDebt.close();session.close();output.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
    @TestCase
    func CancellationCannotPublishPartialIdentityOrRefundCallerOwner():Unit{
        let pool=LogicalJsonOwnerBudget();let owner=pool.acquire(65536)
        let probes=LiveInputOwnedCounter();let consumed=LiveInputOwnedFlag();var cancelled=false
        try{
            try{livePolicyInputPayloadIdentityOwned(textValue(String.fromUtf8(Array<Byte>(262144,repeat:65))),owner,
                {=>probes.value++;if(probes.value>=8){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"input.cancelled","actual cancellation"))}
                    else{Result<Unit>.Ok(())}},{_,_=>consumed.value=true},extraRetained:1048576)}catch(_:Exception){cancelled=true}
            @Expect(cancelled,true);@Expect(consumed.value,false);@Expect(pool.usage()[0],1)
        }finally{owner.close()}
        @Expect(pool.usage()[0],0);@Expect(pool.usage()[1],0)
    }
}
