package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Only the real DB assembly can bind the one-shot native-abort witness.
// This function re-authorizes the ORIGINAL executing child and full Source
// in the NEW actual write transaction, before consuming that resource proof.
func settlePluginLivePolicyNativeAbortFailedChild328(tx:SqliteTransaction,witness:SqliteLiveMemoryNativeAbortWitness324,
    loan:LogicalJsonOwnerReservation,loanPeak:Int64,captured:LiveMemoryNativeAbortBefore328,
    root:OperationRootSource,parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    expected:?ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consumeTip:(AgentValue)->Unit):Unit{
    journalStreamCheck(guard)
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,LivePolicyChildPhase.Executing,allocate,guard)
    requireLivePolicyChildTerminalApproval(tx,child,childPlan,expected,"completed",allocate,guard)
    requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    let effect=childPlan.canonicalArguments.field("effect").getOrThrow()
    if(httpIntentText(effect,"kind")!="row_journal.append"){
        throw IllegalStateException("native-abort failed settlement cannot adopt another effect family")}
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
        "AND kind IN ('plugin_live_no_effect_settled_v1','plugin_live_write_rollback_settled_v1','plugin_live_journal_causal_v1',"+
        "'operation_cancellation_settlement_only','operation_direct_preparation_rejection_only'))",
        [SqlParameter.Text(child.value)],"native-abort child already has another settlement obligation")
    withLivePolicyCurrentJournalFence(tx,parentPlan,allocate,guard,{actual,key,link=>
        let before=captured.before()
        if(!actual.same(before) || httpIntentText(effect,"key")!=key){
            throw IllegalStateException("native autoabort did not restore the complete original five-cell journal fence")}
        // Resource proof is consumed only after original Prepared, handoff,
        // normal approved/Ready, complete read/Source and whole fence checks.
        witness.consume324(tx,loan,{original=>
            withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
                loan.ensureRetainedPeak(journalStreamAdd(loanPeak,journalStreamAdd(1048576,
                    contextReadMetadataRawPeak(original.message.size))))
                let error=match(operationStoreError<Unit>("plugin.live_parent_transaction_unverified",parent,original)){
                    case Result.Err(value)=>value;case Result.Ok(_)=>throw IllegalStateException("original Store error mapping must remain an error")}
                let detail=livePolicyRejectedErrorDetailOwned(error,loan,journalStreamAdd(loanPeak,1048576),guard)
                let detailExtent=livePolicyStoredExtent(detail)
                let binding=childPlan.canonicalArguments.field("binding").getOrThrow()
                let read=link.toValue();let bindingExtent=livePolicyStoredExtent(binding);let readExtent=livePolicyStoredExtent(read)
                let retained=journalStreamAdd(loanPeak,journalStreamAdd(1048576,journalStreamAdd(
                    contextReadMetadataPeak(detailExtent.bytes,detailExtent.nodes),journalStreamAdd(
                    contextReadMetadataPeak(bindingExtent.bytes,bindingExtent.nodes),contextReadMetadataPeak(readExtent.bytes,readExtent.nodes)))))
                loan.ensureRetainedPeak(journalStreamAdd(retained,liveMemoryMultiply297(journalStreamAdd(detailExtent.bytes,
                    journalStreamAdd(bindingExtent.bytes,readExtent.bytes)),12)))
                let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
                let revision=journalStreamAdd(before.events,1);let observed=agentUtcMillis()
                let receipt=VNextOperationReceipt("receipt-"+child.value,child,OperationOutcome.Failed,detail,nullValue(),observed)
                let detailEncoded=encodeStoredValue(detail);let planDigest=modelPolicySha256Text(encoded)
                if(detailEncoded.size!=detailExtent.bytes){throw IllegalStateException("actual original error encoding changed its paid extent")}
                let rollback=livePolicyNativeAbortWitnessValue328(parent,child,run,sequence,receipt.receiptId,planDigest,
                    modelPolicySha256Text(detailEncoded))
                let causal=objectValue([ValueField("schema",textValue("axyndra.plugin-live-journal-causal/v1")),
                    ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
                    ValueField("thread_id",textValue(thread.value)),ValueField("lane_id",binding.field("lane_id").getOrThrow()),
                    ValueField("epoch",integerValue(epoch)),ValueField("binding_digest",textValue(modelPolicySha256Text(canonicalAgentValue(binding)))),
                    ValueField("read_fact_digest",textValue(modelPolicySha256Text(canonicalAgentValue(read)))),
                    ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue(child.value)),
                    ValueField("receipt_id",textValue(receipt.receiptId)),ValueField("plan_sha256",textValue(planDigest)),
                    ValueField("key",textValue(key)),ValueField("before_fence",textValue(before.digest)),ValueField("after_fence",textValue(before.digest)),
                    ValueField("before_revision",integerValue(revision)),ValueField("after_revision",integerValue(revision))])
                let rollbackExtent=livePolicyStoredExtent(rollback);let causalExtent=livePolicyStoredExtent(causal)
                let addedBytes=journalStreamAdd(rollbackExtent.bytes,causalExtent.bytes)
                loan.ensureRetainedPeak(journalStreamAdd(retained,journalStreamAdd(
                    contextReadMetadataPeak(addedBytes,journalStreamAdd(rollbackExtent.nodes,causalExtent.nodes)),
                    liveMemoryMultiply297(journalStreamAdd(addedBytes,journalStreamAdd(detailExtent.bytes,journalStreamAdd(bindingExtent.bytes,readExtent.bytes))),12))))
                let rollbackEncoded=encodeStoredValue(rollback);let causalEncoded=encodeStoredValue(causal)
                if(rollbackEncoded.size!=rollbackExtent.bytes || causalEncoded.size!=causalExtent.bytes){
                    throw IllegalStateException("native-abort settlement changed its complete paid witness encodings")}
                journalStreamCheck(guard)
                tx.execute("INSERT INTO operation_receipts(id,operation_id,outcome,detail,verification,created_at_millis) "+
                    "VALUES(?,?,'failed',?,?,?)",[SqlParameter.Text(receipt.receiptId),SqlParameter.Text(child.value),
                    SqlParameter.Text(detailEncoded),SqlParameter.Text(encodeStoredValue(receipt.verification)),SqlParameter.Int64Value(observed)])
                requireStoreChanged(tx,"native-abort child lost its real reserved Failed Receipt")
                tx.execute("UPDATE operations SET state='failed',revision=revision+1 WHERE id=? AND run_id=? AND state='executing'",
                    [SqlParameter.Text(child.value),SqlParameter.Text(run.value)])
                requireStoreChanged(tx,"native-abort child lost its original executing state");mirrorOperationState(tx,child,"failed")
                for(pair in [("plugin_live_write_rollback_settled_v1",rollbackEncoded),("plugin_live_journal_causal_v1",causalEncoded)]){
                    tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) VALUES(?,?,?,?,?,?)",
                        [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
                            SqlParameter.Text(pair[0]),SqlParameter.Text(pair[1]),SqlParameter.Int64Value(observed)])
                    requireStoreChanged(tx,"native-abort child lost its atomic causal/rollback witness")}
                let rowid=livePolicyChildTerminalAdmissionRowNativeAbort328(tx,parent,child,run,root.itemId(),sequence,requestKey,childPlan.bindingDigest,callId)
                let tip=readPluginLivePolicyReceiptRowNativeAbort328(tx,rowid,parent,run,root.callId(),binding,sequence,
                    childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
                let reference=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                    ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(sequence)),ValueField("tip",tip)])
                requirePluginLivePolicyKnownProposalChildNativeAbort328(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                    requestKey,callId,expected,sequence,reference,allocate,guard)
                // New Source reader consumes every actual own Receipt/error,
                // every original17-field chain and current full5-cell EOF.
                requirePluginLivePolicyParentSourceStreamedNativeAbort328(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
                    progress:Some(LivePolicyReadProgress(sequence,reference,None<OperationId>)))
                withLivePolicyCurrentJournalFence(tx,parentPlan,allocate,guard,{after,_,_=>
                    if(!after.same(before)){throw IllegalStateException("actual Failed bookkeeping changed the complete original journal")}})
                journalStreamCheck(guard);consumeTip(tip);journalStreamCheck(guard)
            })
        })
    })
    journalStreamCheck(guard)
}
