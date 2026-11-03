package agent_store

import agent_domain.*
import agent_runtime.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson_support.*

private func historyPayloadManifest(total:Int64,count:Int64,raw:String):AgentValue{
    objectValue([ValueField("schema",textValue("fixture-original-effect/v1")),ValueField("kind",textValue("effect")),
        ValueField("total_bytes",integerValue(total)),ValueField("sha256",textValue(modelPolicySha256Text(raw))),
        ValueField("payload_count",integerValue(count)),ValueField("proposal_digest",textValue(modelPolicySha256Text("original canonical proposal")))])
}
private func historyPayloadIndex(manifest:AgentValue,refs:Array<AgentValue>):AgentValue{
    objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-output-index/v1")),
        ValueField("native_manifest",manifest),ValueField("payloads",listValue(refs))])
}
private func historyPayloadReference73(raw:String):PluginDocumentPayloadReference{
    let digest=modelPolicySha256Text(raw)
    // Use the existing public descriptive parser; its constructor stays hidden.
    parsePluginDocumentPayloadReference(objectValue([
        ValueField("schema",textValue(PLUGIN_DOCUMENT_PAYLOAD_SCHEMA)),
        ValueField("artifact_ref",textValue("blob:sha256:"+digest)),
        ValueField("encoding",textValue("utf8")),
        ValueField("bytes",integerValue(raw.toArray().size)),
        ValueField("sha256",textValue(digest)),
        ValueField("content_type",textValue("text/plain; charset=utf-8"))])).value().getOrThrow()
}
private func historyPayloadThrows(consume:()->Unit):Bool{
    try{consume();false}catch(_:Exception){true}
}
private class HistoryPayloadAbsentCalls {
    var index:Int64=0
    var raw:Int64=0
    var consume:Int64=0
    init(){}
}

@Test
class LivePolicyHistoricalPayloadIntegrityTests {
    @TestCase
    func everyOriginalMemberAndFullGroupHashRetainNulUnicodeAndRepeatedReferences():Unit{
        let raw="\u{0000}原始Ω";let bytes=raw.toArray()
        let ref=historyPayloadReference73(raw)
        let manifest=historyPayloadManifest(bytes.size*2,2,raw+raw)
        let index=historyPayloadIndex(manifest,[ref.value(),ref.value()])
        let parsed=livePolicyHistoricalIndexManifest(index)
        let pass=LivePolicyHistoricalPayloadPass()
        for(_ in 0..2){
            pass.begin()
            @Expect(pass.observe(0,bytes,ref,{=>Result<Unit>.Ok(())}).isOk(),true)
            pass.end(ref,(bytes.size,ref.digest))}
        pass.finish(parsed);@Expect(pass.ordinal,2);@Expect(pass.total,bytes.size*2)
    }
    @TestCase
    func reorderedOrSwallowedRawFailureCannotBeRecoveredByAClaimedGoodEof():Unit{
        let ref=historyPayloadReference73("abc")
        let pass=LivePolicyHistoricalPayloadPass();pass.begin()
        @Expect(pass.observe(1,"abc".toArray(),ref,{=>Result<Unit>.Ok(())}).isError(),true)
        @Expect(pass.observe(0,"abc".toArray(),ref,{=>Result<Unit>.Ok(())}).isError(),true)
        @Expect(historyPayloadThrows({=>pass.end(ref,(3,ref.digest))}),true)
        @Expect(historyPayloadThrows({=>pass.begin()}),true)
    }
    @TestCase
    func matchingSlotHashesCannotSubstituteManifestTotalCountOrCompleteGroupSha():Unit{
        let ref=historyPayloadReference73("abc")
        let pass=LivePolicyHistoricalPayloadPass();pass.begin()
        @Expect(pass.observe(0,"abc".toArray(),ref,{=>Result<Unit>.Ok(())}).isOk(),true)
        pass.end(ref,(3,ref.digest))
        @Expect(historyPayloadThrows({=>pass.finish(historyPayloadManifest(3,1,"xyz"))}),true)
        @Expect(historyPayloadThrows({=>livePolicyHistoricalIndexManifest(
            historyPayloadIndex(historyPayloadManifest(4,1,"abc"),[ref.value()]))}),true)
        @Expect(historyPayloadThrows({=>livePolicyHistoricalIndexManifest(
            historyPayloadIndex(historyPayloadManifest(3,2,"abc"),[ref.value()]))}),true)
    }
    @TestCase
    func incompleteActualParentSourceCannotReadPinnedDataOrReleaseAnotherOwnersPool():Unit{
        let fixture=KnownSequenceAbsentFixture();let budget=LogicalJsonOwnerBudget();let retained=budget.acquire(1)
        let calls=HistoryPayloadAbsentCalls()
        let plan=NormalizedOperationPlan("plugin.axyndra:memory.retain",objectValue([]),[],
            OperationEffectClass.ReadOnly,OperationRetryDisposition.Never,"actual-source-required")
        // A well-shaped hostile claim cannot create the missing operation,
        // actual settled child, approval, durable receipt or production pin.
        let ledger=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(fixture.parent.value)),ValueField("through_sequence",integerValue(1)),
            ValueField("tip",objectValue([ValueField("sequence",integerValue(1)),ValueField("operation_id",textValue("claimed-child")),
                ValueField("receipt_id",textValue("claimed-receipt")),ValueField("plan_sha256",textValue(modelPolicySha256Text("claimed-plan"))),
                ValueField("outcome",textValue("completed"))]))])
        try{
            @Expect(pluginLivePolicyLedgerReferenceValid(ledger,fixture.parent.value,1),true)
            for(_ in 0..8){
                @Expect(historyPayloadThrows({=>fixture.database.readTransaction<Unit>({tx=>
                    withPluginLivePolicyKnownProposalSequencePayloads(tx,fixture.root,fixture.parent,fixture.run,
                        ThreadId("known-sequence-thread"),1,plan,1,1,ledger,{bytes=>budget.acquire(bytes)},
                        {_=>Result<Unit>.Ok(())},{=>Result<Unit>.Ok(())},
                        {_,_,_=>calls.index+=1;Result<(Int64,String)>.Ok((0,""))},
                        {_,_,_=>calls.raw+=1;Result<(Int64,String)>.Ok((0,""))},
                        {_,_,_,_,_=>calls.consume+=1},retained,16777216)
                })}),true)
                @Expect(budget.usage()[0],1);@Expect(budget.usage()[1],16777216)}
            @Expect(calls.index,0);@Expect(calls.raw,0);@Expect(calls.consume,0)
            fixture.unchanged()
        }finally{retained.close();fixture.close()}
        @Expect(budget.usage()[0],0);@Expect(budget.usage()[1],0)
    }
}
