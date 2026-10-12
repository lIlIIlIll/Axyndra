package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

private class InputIdentityStreamFlag{var value:Bool=false}
private class InputIdentityStreamCounter{var value:Int64=0}

@Test
class PluginLivePolicyInputIdentityStreamTests{
    @TestCase
    func OriginalStoredFramingAndStreamHashAgreeOnEveryKindAndInsertionOrder():Unit{
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        try{
            for(value in [nullValue(),boolValue(true),boolValue(false),JsonNode.number("1e0"),
                textValue("中文😀\u{0000}\n\"\\"),listValue([integerValue(17),textValue("all bytes")]),
                objectValue([ValueField("z",textValue("first")),ValueField("a",JsonNode.number("1.0"))])]){
                let expected=encodeStoredValue(value)
                @Expect(livePolicyInputStoredDigestStreamed(value,{bytes=>budget.acquire(bytes)},
                    {=>Result<Unit>.Ok(())}),modelPolicySha256Text(expected))
                @Expect(budget.usage()[0],1)
            }
            let first=objectValue([ValueField("a",integerValue(1)),ValueField("b",integerValue(2))])
            let second=objectValue([ValueField("b",integerValue(2)),ValueField("a",integerValue(1))])
            let a=livePolicyInputStoredDigestStreamed(first,{bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())})
            let b=livePolicyInputStoredDigestStreamed(second,{bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())})
            @Expect(a!=b,true)
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func ExactEightMiBStoredScalarFitsWithOriginalRetainedChargesAndNoWholeCopy():Unit{
        let budget=LogicalJsonOwnerBudget()
        let actualValue=budget.acquire(8388608);let session=budget.acquire(65536)
        let descriptor=budget.acquire(65536);let pin=budget.acquire(65536)
        try{
            let value=textValue(String.fromUtf8(Array<Byte>(8388599,repeat:b'x')))
            @Expect(budget.usage()[1],117440512)
            // Independent SHA256 of s8388599: followed by all8388599 x bytes.
            @Expect(livePolicyInputStoredDigestStreamed(value,{bytes=>budget.acquire(bytes)},
                {=>Result<Unit>.Ok(())}),"eaae1758f57520e09265511f489c6b30139d30b78b3b7fe6acfaa371c5e96084")
            @Expect(budget.usage()[0],4);@Expect(budget.usage()[1],117440512)
        }finally{pin.close();descriptor.close();session.close();actualValue.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func BusinessProjectionUsesCompleteOriginalJsonWriterAndOneActualOwner():Unit{
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        try{
            let input=objectValue([ValueField("query",textValue("中文😀\u{0000}\n")),
                ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("data",textValue("only reserved metadata"))])),
                ValueField("number",JsonNode.number("1e0")),ValueField("nested",listValue([boolValue(false),textValue("keep")]))])
            let expected=encodeAgentValue(contextReadBusinessInput(input));let consumed=InputIdentityStreamFlag()
            withPluginLivePolicyInputPayloadIdentity(input,{bytes=>budget.acquire(bytes)},
                {=>Result<Unit>.Ok(())},{bytes,digest=>
                    @Expect(bytes,expected.size);@Expect(digest,modelPolicySha256Text(expected))
                    @Expect(budget.usage()[0],2);consumed.value=true})
            @Expect(consumed.value,true);@Expect(budget.usage()[0],1)
            let phase=budget.acquire(65536)
            try{
                livePolicyInputPayloadIdentityOwned(input,phase,{=>Result<Unit>.Ok(())},{bytes,digest=>
                    @Expect(bytes,expected.size);@Expect(digest,modelPolicySha256Text(expected))
                    @Expect(budget.usage()[0],2)},extraRetained:65536)
            }finally{phase.close()}
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func CancellationDepthAndAggregateRefusalReleaseOnlyTemporaryOwners():Unit{
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1);let counter=InputIdentityStreamCounter()
        try{
            let value=textValue(String.fromUtf8(Array<Byte>(262144,repeat:b'x')));var cancelled=false
            try{let _=livePolicyInputStoredDigestStreamed(value,{bytes=>budget.acquire(bytes)},{=>
                counter.value++;if(counter.value>=8){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,
                    "input.identity.cancelled","actual hash cancelled"))}else{Result<Unit>.Ok(())}})}
            catch(_:Exception){cancelled=true}
            @Expect(cancelled,true);@Expect(budget.usage()[0],1)
            var deep:AgentValue=nullValue()
            for(_ in 0..66){deep=listValue([deep])}
            var rejected=false
            try{let _=livePolicyInputStoredDigestStreamed(deep,{bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())})}
            catch(_:Exception){rejected=true}
            @Expect(rejected,true);@Expect(budget.usage()[0],1)
        }finally{held.close()}
        let valueOwner=budget.acquire(8388608);let session=budget.acquire(65536)
        let descriptor=budget.acquire(65536);let pin=budget.acquire(65536)
        try{
            let value=textValue(String.fromUtf8(Array<Byte>(8388599,repeat:b'x')))
            let consumed=InputIdentityStreamFlag();var refused=false
            // All original charges remain live. The original native JSON
            // writer's real scalar overlap exceeds the remaining capacity.
            try{withPluginLivePolicyInputPayloadIdentity(value,{bytes=>budget.acquire(bytes)},
                {=>Result<Unit>.Ok(())},{_,_=>consumed.value=true})}
            catch(_:LogicalJsonPayloadError){refused=true}
            @Expect(refused,true);@Expect(consumed.value,false)
            @Expect(budget.usage()[0],4);@Expect(budget.usage()[1],117440512)
        }finally{pin.close();descriptor.close();session.close();valueOwner.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
