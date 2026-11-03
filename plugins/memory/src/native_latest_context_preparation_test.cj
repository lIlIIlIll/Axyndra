package memory_plugin

import agent_domain.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

@Test
class NativeLatestContextPreparationDescriptorTests {
    @TestCase
    func originalWholeQueryAndDescriptorHaveSamePowerlessLogicalSelector():Unit{
        let parameters=objectValue([ValueField("schema",textValue("axyndra.memory-context-query/v1")),
            ValueField("query",textValue("needle")),ValueField("max_bytes",integerValue(4096))])
        let whole=objectValue([ValueField("schema",textValue(MEMORY_LATEST_CONTEXT_PREPARATION)),
            ValueField("provider",textValue("memory_context")),ValueField("input",parameters)])
        let raw=stringifyUnifiedJson(parameters)
        let descriptor=objectValue([ValueField("schema",textValue(MEMORY_LATEST_CONTEXT_PREPARATION)),
            ValueField("provider",textValue("memory_context")),ValueField("input_payload",objectValue([
                ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(modelPolicySha256Text(raw)))]))])
        @Expect(canonicalAgentValue(memoryLatestContextPrepare(whole)),canonicalAgentValue(memoryLatestContextPrepare(descriptor)))
        @Expect(memoryLatestContextPrepare(descriptor).field("source").isNone())
        @Expect(memoryLatestContextPrepare(descriptor).field("capabilities").isNone())
    }
    @TestCase
    func descriptorCannotMixFullInputOrSupplyGrantAndKeepsOriginalMessageBound():Unit{
        for(extra in ["input","source","approval","binding","maximum_reads"]){
            let value=objectValue([ValueField("schema",textValue(MEMORY_LATEST_CONTEXT_PREPARATION)),
                ValueField("provider",textValue("memory_context")),ValueField("input_payload",objectValue([
                    ValueField("bytes",integerValue(2)),ValueField("sha256",textValue(modelPolicySha256Text("{}")))]))])
            value.put(extra,nullValue());var rejected=false
            try{let _=memoryLatestContextPrepare(value)}catch(_:Exception){rejected=true};@Expect(rejected)}
        for(size in [1,CONTENT_PAYLOAD_MESSAGE_BYTES+1]){
            let value=objectValue([ValueField("schema",textValue(MEMORY_LATEST_CONTEXT_PREPARATION)),
                ValueField("provider",textValue("memory_context")),ValueField("input_payload",objectValue([
                    ValueField("bytes",integerValue(size)),ValueField("sha256",textValue(modelPolicySha256Text("{}")))]))])
            var rejected=false;try{let _=memoryLatestContextPrepare(value)}catch(_:Exception){rejected=true};@Expect(rejected)}
    }
}
