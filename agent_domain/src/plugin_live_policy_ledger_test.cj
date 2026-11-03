package agent_domain

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_support.*

func liveLedgerTestReference(through:Int64,parent!:String="parent-operation",outcome!:String="completed"):AgentValue{
    let tip=if(through==0){nullValue()}else{objectValue([
        ValueField("sequence",integerValue(through)),ValueField("operation_id",textValue("own-last-child")),
        ValueField("receipt_id",textValue("own-last-receipt")),ValueField("plan_sha256",textValue(modelPolicySha256Text("own exact plan"))),
        ValueField("outcome",textValue(outcome))])}
    objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
        ValueField("parent_operation_id",textValue(parent)),ValueField("through_sequence",integerValue(through)),ValueField("tip",tip)])
}
func liveLedgerTestChild(sequence:Int64):AgentValue{
    let value=livePolicyTestChild();value.put("schema",textValue(PLUGIN_LIVE_POLICY_STREAMING_CHILD_SCHEMA))
    value.put("sequence",integerValue(sequence));value.put("prior_receipts",liveLedgerTestReference(sequence-1));value
}

@Test
class PluginLivePolicyLedgerTests{
    @TestCase
    func compactReferencePreservesInt63SequenceWithoutAnInlinePrefix():Unit{
        for(sequence in [Int64(1),Int64(65537),Int64.Max]){
            let value=liveLedgerTestChild(sequence)
            @Expect(pluginLivePolicyStreamingChildValueValid(value),true)
            @Expect(stringifyUnifiedJson(value).size<16384,true)
            // Old v1 accepts only its old full inline shape, unchanged.
            @Expect(pluginLivePolicyChildValueValid(value),false)
        }
    }
    @TestCase
    func ownParentTipAndContiguousOrdinalAreOnlyDescriptors():Unit{
        @Expect(pluginLivePolicyLedgerReferenceValid(liveLedgerTestReference(2),"another-parent",2),false)
        @Expect(pluginLivePolicyLedgerReferenceValid(liveLedgerTestReference(2),"parent-operation",1),false)
        let changed=liveLedgerTestReference(2);changed.field("tip").getOrThrow().put("sequence",integerValue(1))
        @Expect(pluginLivePolicyLedgerReferenceValid(changed,"parent-operation",2),false)
        for(outcome in ["unknown","pending","failed","cancelled","timed_out"]){
            @Expect(pluginLivePolicyLedgerReferenceValid(liveLedgerTestReference(2,outcome:outcome),"parent-operation",2),false)}
        let authority=liveLedgerTestReference(2);authority.put("Source",textValue("claim"))
        @Expect(pluginLivePolicyLedgerReferenceValid(authority,"parent-operation",2),false)
        let privateFence=liveLedgerTestReference(2);privateFence.put("blind_state_sha256",textValue(modelPolicySha256Text("private")))
        @Expect(pluginLivePolicyLedgerReferenceValid(privateFence,"parent-operation",2),false)
    }
    @TestCase
    func ledgerReferenceCannotWeakenTheOriginalEffectAndFactBounds():Unit{
        let wrong=liveLedgerTestChild(2);wrong.field("effect").getOrThrow().put("sql",textValue("native SQL"))
        @Expect(pluginLivePolicyStreamingChildValueValid(wrong),false)
        let wrongRun=liveLedgerTestChild(2);wrongRun.field("binding").getOrThrow().put("run_id",textValue("other-run"))
        @Expect(pluginLivePolicyStreamingChildValueValid(wrongRun),false)
        let spelling=liveLedgerTestChild(2);spelling.put("sequence",numberValue("2.0"))
        @Expect(pluginLivePolicyStreamingChildValueValid(spelling),false)
        let empty=liveLedgerTestReference(0);empty.put("tip",liveLedgerTestReference(1).field("tip").getOrThrow())
        @Expect(pluginLivePolicyLedgerReferenceValid(empty,"parent-operation",0),false)
    }
}
