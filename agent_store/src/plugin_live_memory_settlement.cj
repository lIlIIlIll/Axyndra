package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

class LiveMemorySettlementTip305 {
    var value:?AgentValue=None<AgentValue>
    init(){}
}

// A distinct live-family writer. It never calls the Frozen intent settler or
// accepts a Native completion bit. Every effect, state and reserved Receipt
// belongs to the original actual Prepared invocation in this SAME transaction.
func settlePluginLivePolicyJournalChildInTransaction305(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    expected:?ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    committer:PluginDocumentPayloadCommitter,consumeTip:(AgentValue)->Unit):Unit{
    journalStreamCheck(guard)
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,expected,LivePolicyChildPhase.Executing,allocate,guard)
    requireLivePolicyChildTerminalApproval(tx,child,childPlan,expected,"completed",allocate,guard)
    requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    let effect=childPlan.canonicalArguments.field("effect").getOrThrow()
    if(httpIntentText(effect,"kind")!="row_journal.append"){
        throw IllegalStateException("actual journal entry cannot execute another effect family")}
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
        "AND kind IN ('plugin_live_no_effect_settled_v1','plugin_live_journal_causal_v1',"+
        "'operation_cancellation_settlement_only','operation_direct_preparation_rejection_only'))",
        [SqlParameter.Text(child.value)],"actual live child already has another settlement obligation")
    withLivePolicyCurrentJournalFence(tx,parentPlan,allocate,guard,{before,key,link=>
        if(httpIntentText(effect,"key")!=key || before.events<0 || !httpIntentDigest(before.digest)){
            throw IllegalStateException("actual write key differs from its original sole events-derived read")}
        let payment=ContextReadCompletedMetadataPayment(tx,link,allocate,guard)
        try{
            let read=payment.plan();let binding=childPlan.canonicalArguments.field("binding").getOrThrow()
            let selected=tx.documentStorageBackend(httpIntentText(binding,"namespace"),key)
            let backend=match(selected){case Some(value)=>match(value as SqliteOpaqueRowJournalLatestStreamBackend){
                case Some(actual)=>actual;case None=>throw IllegalStateException("actual v3 append backend changed")}
                case None=>throw IllegalStateException("actual v3 append backend is absent")}
            let configurationCurrent=backend.capture(read)
            let proof=SqlitePluginLiveRowJournalCommitProof304(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
                requestKey,callId,expected,allocate,guard,before,backend,configurationCurrent)
            let after=try{
                match(committer.commit(proof)){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}
                proof.appliedFuture()
            }finally{proof.close()}
            if(after.events<=before.events || !httpIntentDigest(after.digest) || !backend.full(tx,guard).same(after)){
                throw IllegalStateException("actual complete event group did not match its pre-write future")}
            withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
                let owner=allocate(65536)
                try{
                    var raw:Int64=65536
                    for(value in [parent.value,child.value,run.value,thread.value,key,before.digest,after.digest]){
                        raw=journalStreamAdd(raw,value.size)}
                    let bindingExtent=livePolicyStoredExtent(binding)
                    let readValue=link.toValue();let readExtent=livePolicyStoredExtent(readValue)
                    owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataRawPeak(raw),
                        journalStreamAdd(contextReadMetadataPeak(bindingExtent.bytes,bindingExtent.nodes),
                            journalStreamAdd(contextReadMetadataPeak(readExtent.bytes,readExtent.nodes),
                                liveMemoryMultiply297(journalStreamAdd(bindingExtent.bytes,readExtent.bytes),12)))))
                    let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
                    let observed=agentUtcMillis()
                    let receipt=VNextOperationReceipt("receipt-"+child.value,child,OperationOutcome.Completed,
                        objectValue([]),nullValue(),observed)
                    let causal=objectValue([ValueField("schema",textValue("axyndra.plugin-live-journal-causal/v1")),
                        ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
                        ValueField("thread_id",textValue(thread.value)),ValueField("lane_id",binding.field("lane_id").getOrThrow()),
                        ValueField("epoch",integerValue(epoch)),ValueField("binding_digest",textValue(modelPolicySha256Text(canonicalAgentValue(binding)))),
                        ValueField("read_fact_digest",textValue(modelPolicySha256Text(canonicalAgentValue(readValue)))),
                        ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue(child.value)),
                        ValueField("receipt_id",textValue(receipt.receiptId)),ValueField("plan_sha256",textValue(modelPolicySha256Text(encoded))),
                        ValueField("key",textValue(key)),ValueField("before_fence",textValue(before.digest)),ValueField("after_fence",textValue(after.digest)),
                        ValueField("before_revision",integerValue(journalStreamAdd(before.events,1))),
                        ValueField("after_revision",integerValue(journalStreamAdd(after.events,1)))])
                    let extent=livePolicyStoredExtent(causal)
                    owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataRawPeak(raw),
                        journalStreamAdd(contextReadMetadataPeak(extent.bytes,extent.nodes),liveMemoryMultiply297(extent.bytes,12))))
                    let payload=encodeStoredValue(causal)
                    if(payload.size!=extent.bytes){throw IllegalStateException("actual live causal encoding changed its paid extent")}
                    tx.execute("INSERT INTO operation_receipts(id,operation_id,outcome,detail,verification,created_at_millis) "+
                        "VALUES(?,?,'completed',?,?,?)",[SqlParameter.Text(receipt.receiptId),SqlParameter.Text(child.value),
                        SqlParameter.Text(encodeStoredValue(receipt.detail)),SqlParameter.Text(encodeStoredValue(receipt.verification)),SqlParameter.Int64Value(observed)])
                    requireStoreChanged(tx,"actual live child lost its real reserved Receipt")
                    tx.execute("UPDATE operations SET state='committed',revision=revision+1 WHERE id=? AND run_id=? AND state='executing'",
                        [SqlParameter.Text(child.value),SqlParameter.Text(run.value)])
                    requireStoreChanged(tx,"actual live child lost its original execution state");mirrorOperationState(tx,child,"committed")
                    tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                        "VALUES(?,?,?,'plugin_live_journal_causal_v1',?,?)",[SqlParameter.Text(thread.value),SqlParameter.Text(run.value),
                        SqlParameter.Text(child.value),SqlParameter.Text(payload),SqlParameter.Int64Value(observed)])
                    requireStoreChanged(tx,"actual live child lost its exact same-TX seventeen-field causal witness")
                    let rowid=livePolicyChildTerminalAdmissionRow(tx,parent,child,run,root.itemId(),sequence,requestKey,childPlan.bindingDigest,callId)
                    let tip=readPluginLivePolicyReceiptRow(tx,rowid,parent,run,root.callId(),binding,sequence,
                        childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
                    requireLivePolicyChildTerminalPrepared(tx,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,
                        expected,allocate,guard)
                    requireLivePolicyChildTerminalApproval(tx,child,childPlan,expected,"completed",allocate,guard)
                    requireLivePolicyChildNoCanonicalResult(tx,run,thread,child,callId,allocate,guard)
                    let reference=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                        ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(sequence)),ValueField("tip",tip)])
                    requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
                        progress:Some(LivePolicyReadProgress(sequence,reference,None<OperationId>)))
                    if(!backend.full(tx,guard).same(after)){throw IllegalStateException("actual Receipt changed the entire predicted post-state")}
                    journalStreamCheck(configurationCurrent);journalStreamCheck(guard)
                    // Trusted caller retains these bounded data under its own
                    // existing paid owner. Publication waits for outer TX/Source.
                    consumeTip(tip)
                }finally{owner.close()}
            })
        }finally{payment.close()}
    })
    journalStreamCheck(guard)
}
