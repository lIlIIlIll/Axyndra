package agent_store

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

class LiveParentTerminalStreamFlag{var value:Bool=false}

@Test
class PluginLivePolicyParentTerminalStreamTests{
    @TestCase
    func OriginalWholeWriterAndStreamingIdentityAgreeOnAllJsonBytes():Unit{
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1)
        try{
            for(value in [nullValue(),boolValue(true),JsonNode.number("1e0"),
                textValue("中文😀\u{0000}\b\t\n\r\"\\<&'="),
                objectValue([ValueField("_axyndra_context",textValue("keep")),ValueField("z",listValue([integerValue(7),boolValue(false)])),
                    ValueField("a",textValue("original order"))])]){
                let expected=encodeAgentValue(value);let consumed=LiveParentTerminalStreamFlag()
                withPluginLivePolicyTerminalOutputIdentity(value,{bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},{bytes,digest=>
                    @Expect(bytes,expected.size);@Expect(digest,modelPolicySha256Text(expected));consumed.value=true})
                @Expect(consumed.value,true);@Expect(budget.usage()[0],1)
            }
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func NearEightMiBOutputFitsWithRealOutputAndMetadataAndDescriptorCharges():Unit{
        let budget=LogicalJsonOwnerBudget()
        let actualOutput=budget.acquire(8388608)
        let metadata=budget.acquire(65536);let descriptor=budget.acquire(65536)
        try{
            let value=textValue(String.fromUtf8(Array<Byte>(8388606,repeat:65)))
            let expected=encodeAgentValue(value);let digest=modelPolicySha256Text(expected)
            let consumed=LiveParentTerminalStreamFlag()
            @Expect(budget.usage()[1],100663296)
            withPluginLivePolicyTerminalOutputIdentity(value,{bytes=>budget.acquire(bytes)},{=>Result<Unit>.Ok(())},{bytes,actual=>
                @Expect(bytes,8388608);@Expect(actual,digest);@Expect(budget.usage()[0],4)
                @Expect(budget.usage()[1]<=134217728,true);consumed.value=true})
            @Expect(consumed.value,true);@Expect(budget.usage()[0],3);@Expect(budget.usage()[1],100663296)
        }finally{descriptor.close();metadata.close();actualOutput.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
    @TestCase
    func CancellationAndOriginalNumericErrorsCannotReturnPartialIdentity():Unit{
        let budget=LogicalJsonOwnerBudget();let held=budget.acquire(1);let probes=LiveParentTerminalCounter()
        try{
            let value=textValue(String.fromUtf8(Array<Byte>(262144,repeat:65)));let consumed=LiveParentTerminalStreamFlag()
            var cancelled=false
            try{withPluginLivePolicyTerminalOutputIdentity(value,{bytes=>budget.acquire(bytes)},
                {=>probes.value++;if(probes.value>=8){Result<Unit>.Err(AgentError(AgentErrorKind.Cancelled,"terminal.cancelled","actual stream cancelled"))}
                    else{Result<Unit>.Ok(())}}, {_,_=>consumed.value=true})}catch(_:Exception){cancelled=true}
            @Expect(cancelled,true);@Expect(consumed.value,false);@Expect(budget.usage()[0],1)
            for(literal in ["00","1e"]){
                let partial=LiveParentTerminalStreamFlag();var rejected=false
                try{withPluginLivePolicyTerminalOutputIdentity(JsonNode.number(literal),{bytes=>budget.acquire(bytes)},
                    {=>Result<Unit>.Ok(())},{_,_=>partial.value=true})}catch(_:IllegalArgumentException){rejected=true}
                @Expect(rejected,true);@Expect(partial.value,false);@Expect(budget.usage()[0],1)
            }
        }finally{held.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
