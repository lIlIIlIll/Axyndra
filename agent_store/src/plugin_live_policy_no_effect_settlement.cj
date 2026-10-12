package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Only an actual User decision for this untouched waiting child reaches this
// writer. Cancellation, an executor error and a worker rollback are separate
// obligations: none can enter this path or manufacture a known no-effect tip.
// The caller owns the same transaction and its actual logical allocation pool.
func settlePluginLivePolicyUserRejectedChildInTransaction(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,child:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
    parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,requestKey:String,callId:String,
    expected:ApprovalRequest,approvalId:String,ceiling:CapabilitySet,source:String,expires:?Int64,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,rejectionError!:?AgentError=None):Unit{
    journalStreamCheck(guard)
    if(source!=approvalDecisionSourceName(ApprovalDecisionSource.User)){
        throw IllegalStateException("known unexecuted rejection requires the actual User decision source")}
    // First prove the entire actual child tuple and original reviewed approval.
    // Only then may the parent read verifier exclude this unique pending child.
    requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
        requestKey,callId,Some(expected),LivePolicyChildPhase.WaitingApproval,allocate,guard)
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
        progress:Some(livePolicyReadProgressForChild(childPlan,Some(child))))
    livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
        "AND kind IN ('plugin_live_no_effect_settled_v1','plugin_live_journal_causal_v1',"+
        "'operation_cancellation_settlement_only','operation_direct_preparation_rejection_only'))",
        [SqlParameter.Text(child.value)],"live child already has a different settlement obligation or witness")
    withLivePolicyCurrentJournalFence(tx,parentPlan,allocate,guard,{before,key,link=>
        if(!httpIntentDigest(before.digest) || before.events<0){
            throw IllegalStateException("no-effect settlement has no actual complete private journal fence")}
        let revision=journalStreamAdd(before.events,1)
        // Same-TX canonical decision, state mirror and exact reviewed ceiling.
        // This bookkeeping performs no handoff and has not yet written a Receipt.
        recordLivePolicyApprovalInTransaction(tx,child,run,childPlan,approvalId,ceiling,false,
            source,expires,allocate,guard)
        requireLivePolicyChildPreparedTuple(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,
            requestKey,callId,Some(expected),LivePolicyChildPhase.RejectedWithoutHandoff,allocate,guard)
        withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
            let owner=allocate(65536)
            try{
                // Pay complete actual scalar copies before allocating the new
                // bounded metadata nodes, hashes, encodings and SQL parameters.
                var bytes:Int64=65536
                for(value in [parent.value,child.value,run.value,thread.value,key,before.digest]){
                    bytes=journalStreamAdd(bytes,value.size)}
                let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
                bytes=journalStreamAdd(bytes,httpIntentText(binding,"lane_id").size)
                owner.ensureRetainedPeak(contextReadMetadataRawPeak(bytes))
                let bindingExtent=livePolicyStoredExtent(binding)
                owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(bindingExtent.bytes,bindingExtent.nodes),
                    journalStreamAdd(bytes,bindingExtent.bytes*12)))
                let planDigest=modelPolicySha256Text(encoded)
                let bindingDigest=modelPolicySha256Text(canonicalAgentValue(binding))
                let readValue=link.toValue();let readExtent=livePolicyStoredExtent(readValue)
                owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(readExtent.bytes,readExtent.nodes),
                    journalStreamAdd(bytes,readExtent.bytes*12)))
                let readDigest=modelPolicySha256Text(canonicalAgentValue(readValue))
                let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
                // The opt-in error is the actual trusted caller's typed data.
                // The original User/Waiting/full Source/7+17 proof above remains
                // the only settlement authority. Missing historical fields are
                // never reconstructed from an error code or a Native isError.
                let rejectionDetail=match(rejectionError){
                    case None=>objectValue([ValueField("code",textValue("plugin.live_child_user_rejected")),
                        ValueField("message",textValue("the user rejected this reviewed child before execution"))])
                    case Some(error)=>
                        let retained=journalStreamAdd(bytes,journalStreamAdd(
                            contextReadMetadataPeak(bindingExtent.bytes,bindingExtent.nodes),
                            journalStreamAdd(contextReadMetadataPeak(readExtent.bytes,readExtent.nodes),
                                journalStreamAdd(bindingExtent.bytes*12,readExtent.bytes*12))))
                        livePolicyRejectedErrorDetailOwned(error,owner,retained,guard)
                }
                let receipt=VNextOperationReceipt("receipt-"+child.value,child,OperationOutcome.Rejected,
                    rejectionDetail,nullValue(),agentUtcMillis())
                let noEffect=objectValue([ValueField("schema",textValue("axyndra.plugin-live-no-effect/v1")),
                    ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
                    ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue(child.value)),
                    ValueField("receipt_id",textValue(receipt.receiptId)),ValueField("plan_sha256",textValue(planDigest))])
                let causal=objectValue([ValueField("schema",textValue("axyndra.plugin-live-journal-causal/v1")),
                    ValueField("parent_operation_id",textValue(parent.value)),ValueField("run_id",textValue(run.value)),
                    ValueField("thread_id",textValue(thread.value)),ValueField("lane_id",binding.field("lane_id").getOrThrow()),
                    ValueField("epoch",integerValue(epoch)),ValueField("binding_digest",textValue(bindingDigest)),
                    ValueField("read_fact_digest",textValue(readDigest)),ValueField("sequence",integerValue(sequence)),
                    ValueField("operation_id",textValue(child.value)),ValueField("receipt_id",textValue(receipt.receiptId)),
                    ValueField("plan_sha256",textValue(planDigest)),ValueField("key",textValue(key)),
                    ValueField("before_fence",textValue(before.digest)),ValueField("after_fence",textValue(before.digest)),
                    ValueField("before_revision",integerValue(revision)),ValueField("after_revision",integerValue(revision))])
                let noEffectExtent=livePolicyStoredExtent(noEffect);let causalExtent=livePolicyStoredExtent(causal)
                let detailExtent=livePolicyStoredExtent(receipt.detail);let verificationExtent=livePolicyStoredExtent(receipt.verification)
                let encodedBytes=journalStreamAdd(journalStreamAdd(noEffectExtent.bytes,causalExtent.bytes),
                    journalStreamAdd(detailExtent.bytes,verificationExtent.bytes))
                let nodes=journalStreamAdd(journalStreamAdd(noEffectExtent.nodes,causalExtent.nodes),
                    journalStreamAdd(detailExtent.nodes,verificationExtent.nodes))
                owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataPeak(encodedBytes,nodes),
                    journalStreamAdd(bytes,encodedBytes*12)))
                let detail=encodeStoredValue(receipt.detail);let verification=encodeStoredValue(receipt.verification)
                let noEffectEncoded=encodeStoredValue(noEffect);let causalEncoded=encodeStoredValue(causal)
                if(detail.size!=detailExtent.bytes || verification.size!=verificationExtent.bytes ||
                    noEffectEncoded.size!=noEffectExtent.bytes || causalEncoded.size!=causalExtent.bytes){
                    throw IllegalStateException("no-effect settlement changed its complete paid encodings")}
                journalStreamCheck(guard)
                // Immutable child proof above binds this real reserved slot.
                // Generic six-column Receipt shape, dedicated live-family proof;
                // no entry into the old derived/frozen ParentIntent settler.
                tx.execute("INSERT INTO operation_receipts(id,operation_id,outcome,detail,verification,created_at_millis) "+
                    "VALUES (?,?,?,?,?,?)",[SqlParameter.Text(receipt.receiptId),SqlParameter.Text(child.value),
                    SqlParameter.Text(operationOutcomeName(receipt.outcome)),SqlParameter.Text(detail),
                    SqlParameter.Text(verification),SqlParameter.Int64Value(receipt.observedAtMillis)])
                requireStoreChanged(tx,"no-effect settlement lost its actual reserved Receipt")
                tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                    "VALUES (?,?,?,'plugin_live_no_effect_settled_v1',?,?)",
                    [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
                        SqlParameter.Text(noEffectEncoded),SqlParameter.Int64Value(receipt.observedAtMillis)])
                requireStoreChanged(tx,"no-effect settlement lost its exact seven-field witness")
                tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                    "VALUES (?,?,?,'plugin_live_journal_causal_v1',?,?)",
                    [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(child.value),
                        SqlParameter.Text(causalEncoded),SqlParameter.Int64Value(receipt.observedAtMillis)])
                requireStoreChanged(tx,"no-effect settlement lost its exact same-fence causal witness")
                // Re-read the genuine reserved Receipt with the original complete
                // paid plan/detail/verification/EOF reader before using its tip.
                let admissions=tx.query("SELECT rowid FROM derived_operation_admissions WHERE operation_id=? "+
                    "AND parent_operation_id=? AND call_sequence=?",
                    [SqlParameter.Text(child.value),SqlParameter.Text(parent.value),SqlParameter.Int64Value(sequence)])
                if(admissions.size!=1){throw IllegalStateException("no-effect settlement lost its unique actual child")}
                let tip=readPluginLivePolicyReceiptRow(tx,journalStreamInteger(admissions[0].required(0)),parent,run,
                    root.callId(),binding,sequence,childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
                let reference=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                    ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(sequence)),
                    ValueField("tip",tip)])
                // No pending exclusion remains: full Source/current/actual read
                // and every known own child now bind this exact final prefix.
                requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
                    progress:Some(LivePolicyReadProgress(sequence,reference,None)))
                journalStreamCheck(guard)
            }finally{owner.close()}
        })
    })
    journalStreamCheck(guard)
}
