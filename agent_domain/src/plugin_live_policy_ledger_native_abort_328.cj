package agent_domain

import yjson.*
import yjson_support.*


// A compact reference to this parent's OWN public receipts. This is neither a
// private corpus fingerprint nor a proof, Source, approval or retry grant.
// Store must inspect the complete same-TX prefix, not trust the tip/count.
public func pluginLivePolicyLedgerReferenceValidNativeAbort328(value:AgentValue,parentOperationId:String,throughSequence:Int64):Bool{
    try{
        if(throughSequence<0 || !documentContractIdentifier(parentOperationId) ||
            !httpIntentExactFields(value,["schema","parent_operation_id","through_sequence","tip"]) ||
            httpIntentText(value,"schema")!=PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA ||
            httpIntentText(value,"parent_operation_id")!=parentOperationId ||
            documentContractInteger(value.field("through_sequence").getOrThrow())!=throughSequence){return false}
        let tip=value.field("tip").getOrThrow()
        if(throughSequence==0){return tip.unifiedKind==ValueKind.Null}
        httpIntentExactFields(tip,["sequence","operation_id","receipt_id","plan_sha256","outcome"]) &&
            documentContractInteger(tip.field("sequence").getOrThrow())==throughSequence &&
            documentContractIdentifier(httpIntentText(tip,"operation_id")) &&
            documentContractIdentifier(httpIntentText(tip,"receipt_id")) &&
            httpIntentDigest(httpIntentText(tip,"plan_sha256")) &&
            ["completed","rejected","failed"].contains(httpIntentText(tip,"outcome"))
    }catch(_:Exception){false}
}

public func pluginLivePolicyStreamingChildValueValidNativeAbort328(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["schema","binding","sequence","effect","proposal_payload","read_facts","prior_receipts"]) ||
            httpIntentText(value,"schema")!=PLUGIN_LIVE_POLICY_STREAMING_CHILD_SCHEMA){return false}
        let sequence=documentContractInteger(value.field("sequence").getOrThrow())
        let ledger=value.field("prior_receipts").getOrThrow()
        if(sequence<1 || !pluginLivePolicyLedgerReferenceValidNativeAbort328(ledger,httpIntentText(ledger,"parent_operation_id"),sequence-1)){return false}
        // Reuse the entire existing non-ledger shape predicate without making
        // an inline array proportional to sequence. Only this shallow seven-
        // field view is allocated; nested objects are never mutated here.
        pluginLivePolicyChildValueValid(objectValue([
            ValueField("schema",textValue(PLUGIN_LIVE_POLICY_CHILD_SCHEMA)),
            ValueField("binding",value.field("binding").getOrThrow()),ValueField("sequence",integerValue(1)),
            ValueField("effect",value.field("effect").getOrThrow()),
            ValueField("proposal_payload",value.field("proposal_payload").getOrThrow()),
            ValueField("read_facts",value.field("read_facts").getOrThrow()),ValueField("prior_receipts",listValue([]))]))
    }catch(_:Exception){false}
}
