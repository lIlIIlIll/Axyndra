package agent_store

import agent_domain.*
import yjson.*
import yjson_support.*

// Full actual own prefix remains a relationship, never Source/permission.
// Only Unit escapes. The checked small tip/reference stays under this actual
// owner through consume; Blob metadata must borrow this owner and add the
// supplied live-retained invoice. Closing a borrower is forbidden.
func withPluginLivePolicyReceiptPrefixOwnedNativeAbort328(tx:SqliteTransaction,parentOperation:OperationId,run:RunId,
    parentCallId:String,binding:AgentValue,throughSequence:Int64,expectedReference:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(LogicalJsonOwnerReservation,Int64)->Unit):Unit{
    if(validatePluginDocumentBinding(binding).isError() || httpIntentText(binding,"run_id")!=run.value ||
        !pluginLivePolicyLedgerReferenceValidNativeAbort328(expectedReference,parentOperation.value,throughSequence)){
        throw IllegalStateException("live prefix reference has no exact own parent/count/tip")}
    let referenceCharge=allocate(65536)
    try{
        // This small owner remains held through the caller's freezing/output
        // consumption. It never retains any plan/detail/history DOM.
        referenceCharge.ensureRetainedPeak(1048576)
        var cursor:?Int64=None;var ordinal:Int64=0;var tip:AgentValue=nullValue()
        while(true){
            journalStreamCheck(guard)
            let cursorRows=match(cursor){
                case None=>tx.query("SELECT rowid FROM derived_operation_admissions WHERE parent_operation_id=? ORDER BY rowid LIMIT 1",
                    [SqlParameter.Text(parentOperation.value)])
                case Some(last)=>tx.query("SELECT rowid FROM derived_operation_admissions WHERE parent_operation_id=? AND rowid>? ORDER BY rowid LIMIT 1",
                    [SqlParameter.Text(parentOperation.value),SqlParameter.Int64Value(last)])}
            if(cursorRows.isEmpty()){break}
            if(ordinal>=throughSequence){throw IllegalStateException("live prefix has an extra or still pending child")}
            let rowid=journalStreamInteger(cursorRows[0].required(0));let next=ordinal+1
            let previous=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parentOperation.value)),ValueField("through_sequence",integerValue(ordinal)),ValueField("tip",tip)])
            tip=readPluginLivePolicyReceiptRowOwnedNativeAbort328(tx,rowid,parentOperation,run,parentCallId,binding,next,previous,allocate,guard,referenceCharge,1048576)
            ordinal=next;cursor=Some(rowid)
        }
        if(ordinal!=throughSequence){throw IllegalStateException("live prefix is incomplete")}
        let actual=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(parentOperation.value)),ValueField("through_sequence",integerValue(ordinal)),
            ValueField("tip",tip)])
        if(canonicalAgentValue(actual)!=canonicalAgentValue(expectedReference)){
            throw IllegalStateException("live prefix substituted an own receipt tip")}
        journalStreamCheck(guard);consume(referenceCharge,1048576);journalStreamCheck(guard)
    }finally{referenceCharge.close()}
}
