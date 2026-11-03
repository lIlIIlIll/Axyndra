package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

// Descriptive-only shape tests; no Source, actual Root, Receipt or artifact
// is constructed or claimed by these values.
private func liveTerminalData():AgentValue{liveTerminalData(0,"completed")}
private func liveTerminalData(through:Int64):AgentValue{liveTerminalData(through,"completed")}
private func liveTerminalData(through:Int64,outcome:String):AgentValue{
    let digest=modelPolicySha256Text("terminal-data-shape")
    let tip=if(through==0){nullValue()}else{objectValue([ValueField("sequence",integerValue(through)),
        ValueField("operation_id",textValue("child")),ValueField("receipt_id",textValue("receipt")),
        ValueField("plan_sha256",textValue(digest)),ValueField("outcome",textValue(outcome))])}
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_TERMINAL_DATA_SCHEMA)),
        ValueField("parent_operation_id",textValue("parent")),ValueField("parent_binding_digest",textValue(digest)),
        ValueField("prior_receipts",objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue("parent")),ValueField("through_sequence",integerValue(through)),ValueField("tip",tip)])),
        ValueField("result_payload",objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
            ValueField("artifact_ref",textValue("blob:sha256:"+digest)),ValueField("encoding",textValue("utf8")),
            ValueField("bytes",integerValue(4)),ValueField("sha256",textValue(digest)),ValueField("content_type",textValue("text/plain; charset=utf-8"))])),
        ValueField("is_error",boolValue(false))])
}
private func liveTerminalInvalidNumberConstructorRejected(number:String):Bool{
    try{let _=JsonNode.number(number);false}catch(_:IllegalArgumentException){true}
}
private func liveTerminalInvalidNumberEnvelopeRejected(number:String):Bool{
    let source=liveTerminalData().stringify()
    let marker="\"through_sequence\":0"
    if(!source.contains(marker)){throw IllegalStateException("terminal sequence fixture marker missing")}
    let malformed=source.replace(marker,"\"through_sequence\":"+number)
    try{
        let digest=modelPolicySha256Text("terminal-data-shape")
        let _=pluginLivePolicyTerminalDataValid(parseUnifiedJson(malformed),"parent",digest)
        false
    }catch(_:JsonException){true}
}
@Test
class PluginLivePolicyTerminalDataTests {
    @TestCase
    func EmptyAndKnownOwnPrefixesAreDescriptiveDataOnly():Unit{
        let digest=modelPolicySha256Text("terminal-data-shape")
        @Expect(pluginLivePolicyTerminalDataValid(liveTerminalData(),"parent",digest),true)
        @Expect(pluginLivePolicyTerminalDataValid(liveTerminalData(1,"completed"),"parent",digest),true)
        @Expect(pluginLivePolicyTerminalDataValid(liveTerminalData(1,"rejected"),"parent",digest),true)
        @Expect(pluginLivePolicyTerminalDataValid(liveTerminalData(1,"unknown"),"parent",digest),false)
    }
    @TestCase
    func ExactParentBindingAndNoAdditionalAuthorityFields():Unit{
        let digest=modelPolicySha256Text("terminal-data-shape")
        @Expect(pluginLivePolicyTerminalDataValid(liveTerminalData(),"other",digest),false)
        @Expect(pluginLivePolicyTerminalDataValid(liveTerminalData(),"parent",modelPolicySha256Text("other")),false)
        for(field in ["source","approval","handoff","receipt","owner","path","sql"]){
            let value=liveTerminalData();value.put(field,textValue("claim"))
            @Expect(pluginLivePolicyTerminalDataValid(value,"parent",digest),false)}
    }
    @TestCase
    func NoNewSequenceCountCeilingAndStrictCanonicalIntegers():Unit{
        let digest=modelPolicySha256Text("terminal-data-shape")
        @Expect(pluginLivePolicyTerminalDataValid(liveTerminalData(Int64.Max),"parent",digest),true)
        for(number in ["-1","00","1.0","1e0","9223372036854775808"]){
            // A0-03: 00 is invalid JSON and cannot reach the typed validator.
            // Keep the original literal at both real fail-closed boundaries.
            if(number=="00"){
                @Expect(liveTerminalInvalidNumberConstructorRejected(number),true)
                @Expect(liveTerminalInvalidNumberEnvelopeRejected(number),true)
                continue
            }
            let value=liveTerminalData();value.field("prior_receipts").getOrThrow().put("through_sequence",JsonNode.number(number))
            @Expect(pluginLivePolicyTerminalDataValid(value,"parent",digest),false)}
    }
    @TestCase
    func OriginalPayloadReferenceBoundAndRealBooleanRemainUnchanged():Unit{
        let digest=modelPolicySha256Text("terminal-data-shape")
        let value=liveTerminalData();let payload=value.field("result_payload").getOrThrow()
        payload.put("bytes",integerValue(8388608))
        @Expect(pluginLivePolicyTerminalDataValid(value,"parent",digest),true)
        payload.put("bytes",integerValue(8388609))
        @Expect(pluginLivePolicyTerminalDataValid(value,"parent",digest),false)
        payload.put("bytes",integerValue(4));value.put("is_error",textValue("false"))
        @Expect(pluginLivePolicyTerminalDataValid(value,"parent",digest),false)
        payload.put("path",textValue("untrusted"));value.put("is_error",boolValue(false))
        @Expect(pluginLivePolicyTerminalDataValid(value,"parent",digest),false)
    }
}
