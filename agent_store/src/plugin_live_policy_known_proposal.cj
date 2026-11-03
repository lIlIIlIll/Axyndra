package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Data only. Every historical proposal still belongs to an actual settled
// child in the complete CURRENT parent chain. Its earlier production pin
// is immutable identity, never an earlier fence or a new execution grant.
func livePolicyKnownProposalErrorDataValid(value:AgentValue):Bool{
    try{
        if(value.unifiedKind==ValueKind.Null){return true}
        if(!httpIntentExactFields(value,["kind","code","message","retryable","fallback_allowed","fields","attempt_failure","observation"]) ||
            value.field("retryable").getOrThrow().unifiedKind!=ValueKind.Boolean ||
            value.field("fallback_allowed").getOrThrow().unifiedKind!=ValueKind.Boolean){return false}
        for(name in ["kind","code","message"]){if(value.field(name).getOrThrow().unifiedKind!=ValueKind.Text){return false}}
        let fields=value.field("fields").getOrThrow();if(fields.unifiedKind!=ValueKind.List){return false}
        for(field in fields.items){if(!httpIntentExactFields(field,["name","value"]) ||
            field.field("name").getOrThrow().unifiedKind!=ValueKind.Text || field.field("value").getOrThrow().unifiedKind!=ValueKind.Text){return false}}
        for(name in ["attempt_failure","observation"]){let item=value.field(name).getOrThrow()
            if(item.unifiedKind!=ValueKind.Null && item.unifiedKind!=ValueKind.Object){return false}}
        // The full original typed Native codec validates all diagnostic and
        // observation data. These fields are not used as Source or authority.
        true
    }catch(_:Exception){false}
}

private func withLivePolicyHistoricalProposalPin(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    currentThrough:Int64,currentLedger:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,
    verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,guard:()->Result<Unit>,consume:()->Unit):Unit{
    let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
    let produced=childPlan.canonicalArguments.field("prior_receipts").getOrThrow()
    if(sequence<1 || sequence>currentThrough ||
        !pluginLivePolicyLedgerReferenceValid(produced,parent.value,sequence-1) ||
        !pluginLivePolicyLedgerReferenceValid(currentLedger,parent.value,currentThrough)){
        throw IllegalStateException("historical proposal lost its exact production prefix and complete current parent chain")}
    let payload=parsePluginDocumentPayloadReference(childPlan.canonicalArguments.field("proposal_payload").getOrThrow()).value().getOrThrow()
    let owner=allocate(65536)
    try{
        // The old single-payload step pin is exact. The current full Source
        // and all actual receipt rows above independently prove that its
        // production prefix is an original prefix of this same parent.
        let descriptor=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-step-data/v1")),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("parent_binding_digest",textValue(parentPlan.bindingDigest)),
            ValueField("prior_receipts",produced),ValueField("payloads",listValue([payload.value()]))])
        let extent=livePolicyStoredExtent(descriptor)
        owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
        let encoded=encodeStoredValue(descriptor)
        if(encoded.size!=extent.bytes){throw IllegalStateException("historical proposal changed its fully paid original pin encoding")}
        let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let current:()->Unit={=>
            requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
                phase:LivePolicyParentPhase.Executing,progress:Some(LivePolicyReadProgress(currentThrough,currentLedger,None)))
            requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),parentPlan.toolName,parentPlan.canonicalArguments,allocate,guard)
            livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND run_id=? "+
                "AND thread_id=? AND kind='plugin_live_policy_step_data_v1' AND payload=?)=1",
                [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Text(encoded)],
                "historical proposal lost its sole original same-parent production data pin")
            withPluginLivePolicyReceiptPrefixOwned(tx,parent,run,root.callId(),binding,currentThrough,currentLedger,allocate,guard,{actualOwner,retained=>
                requireLivePolicyParentTerminalBlobOwned(tx,payload,actualOwner,retained,{=>verifyContent(payload)},guard)})}
        current();journalStreamCheck(guard);consume();journalStreamCheck(guard);current()
    }finally{owner.close()}
}

// No Root/Receipt/approval is made here. The immutable actual child,
// reserved Receipt, reviewed approval, handoff or User no-effect witness,
// complete source and all current 17-field causal links are mandatory.
// None of result.output/is_error/Native metadata determines this tuple.
public func withPluginLivePolicyKnownProposalInputs(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,child:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,currentThrough:Int64,currentLedger:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,
    guard:()->Result<Unit>,consume:(AgentValue,PluginDocumentPayloadReference,AgentValue)->Unit):Unit{
    journalStreamCheck(guard)
    requirePluginLivePolicyKnownProposalChild(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,
        expected,currentThrough,currentLedger,allocate,guard)
    withLivePolicyHistoricalProposalPin(tx,root,parent,run,thread,epoch,parentPlan,childPlan,currentThrough,currentLedger,
        allocate,verifyContent,guard,{=>
            let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
            let paid=allocate(65536)
            try{
                paid.ensureRetainedPeak(1048576)
                let rowid=livePolicyChildTerminalAdmissionRow(tx,parent,child,run,root.itemId(),sequence,requestKey,childPlan.bindingDigest,callId)
                let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
                let tip=readPluginLivePolicyReceiptRow(tx,rowid,parent,run,root.callId(),binding,sequence,
                    childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
                // Preserve actual durable error data, including null. Old
                // two-field rejection details are diagnosed, never upgraded
                // into a guessed eight-field error or synthetic success.
                withLivePolicyStoredValue(tx,"detail"," FROM operation_receipts WHERE operation_id=? AND id=?",
                    [SqlParameter.Text(child.value),SqlParameter.Text(httpIntentText(tip,"receipt_id"))],allocate,guard,{raw=>
                        let detail=decodeStoredValue(raw)
                        if(!livePolicyKnownProposalErrorDataValid(detail) ||
                            (httpIntentText(tip,"outcome")=="rejected" && detail.unifiedKind==ValueKind.Null)){
                            throw IllegalStateException("historical receipt does not retain the complete original typed error data")}
                        let payload=parsePluginDocumentPayloadReference(childPlan.canonicalArguments.field("proposal_payload").getOrThrow()).value().getOrThrow()
                        journalStreamCheck(guard);consume(tip,payload,detail);journalStreamCheck(guard)})
                if(rowid!=livePolicyChildTerminalAdmissionRow(tx,parent,child,run,root.itemId(),sequence,requestKey,childPlan.bindingDigest,callId)){
                    throw IllegalStateException("historical actual child admission changed during complete data consumption")}
            }finally{paid.close()}
        })
    requirePluginLivePolicyKnownProposalChild(tx,root,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,
        expected,currentThrough,currentLedger,allocate,guard)
    journalStreamCheck(guard)
}

private func requirePluginLivePolicyKnownProposalChild(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,child:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,currentThrough:Int64,currentLedger:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    withLivePolicyChildTerminalPayment(allocate,guard,{=>
        if(child.value==parent.value || !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,childPlan) ||
            requestKey!=pluginLivePolicyStreamingRequestKey(root.callId(),childPlan)){
            throw IllegalStateException("terminal child substituted its independently normalized parent/plan/request")}
        let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
        if(sequence<1 || sequence>currentThrough || callId!=root.callId()+":live:"+sequence.toString() ||
            !pluginLivePolicyLedgerReferenceValid(currentLedger,parent.value,currentThrough)){
            throw IllegalStateException("known proposal requires its actual child and complete current parent ledger")}
        let rowid=livePolicyChildTerminalAdmissionRow(tx,parent,child,run,root.itemId(),sequence,requestKey,childPlan.bindingDigest,callId)
        journalStreamCheck(guard)
        withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
            requireLivePolicyImmutableEffect(tx,child,run,root.itemId(),childPlan,encoded)})
        requireLivePolicyChildTerminalPrepared(tx,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,
            expected,allocate,guard)
        let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let tip=readPluginLivePolicyReceiptRow(tx,rowid,parent,run,root.callId(),binding,sequence,
            childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
        // tip lives in the enclosing 1 MiB owner after the ledger reader's
        // own full raw/plan payments close, through every remaining check.
        if(httpIntentText(tip,"operation_id")!=child.value){
            throw IllegalStateException("known proposal differs from its actual reserved Receipt and full plan")}
        let outcome=httpIntentText(tip,"outcome")
        requireLivePolicyChildTerminalApproval(tx,child,childPlan,expected,outcome,allocate,guard)
        livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
            "AND kind IN ('operation_cancellation_settlement_only','operation_direct_preparation_rejection_only')) "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='plugin_live_no_effect_settled_v1')=? "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')=? "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='plugin_live_journal_causal_v1')=1",
            [SqlParameter.Text(child.value),SqlParameter.Text(child.value),SqlParameter.Int64Value(if(outcome=="rejected"){1}else{0}),
                SqlParameter.Text(child.value),SqlParameter.Int64Value(if(outcome=="completed"){1}else{0}),SqlParameter.Text(child.value)],
            "known terminal child has conflicting or duplicated handoff/no-effect settlement evidence")
        if(outcome=="completed"){
            withLivePolicyChildHandoff(parent,child,root,run,thread,epoch,parentPlan,childPlan,requestKey,callId,allocate,guard,{expectedHandoff=>
                withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
                    "AND kind='operation_execution_handoff'",
                    [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                        if(actual!=expectedHandoff){throw IllegalStateException("terminal child changed its full original handoff Source/plan")}})})
        }else{
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
                "AND kind='operation_execution_handoff')",[SqlParameter.Text(child.value)],
                "known no-effect rejection cannot contain an execution handoff")
        }
        let actualPrefix=currentLedger
        // Include the already terminal child. None excludes no own child;
        // the full Parent Source replays actual receipts and every 17-field
        // causal witness and current full fence, never the caller's DTO tip.
        requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
            phase:LivePolicyParentPhase.Executing,progress:Some(LivePolicyReadProgress(currentThrough,actualPrefix,None)))
        requireLivePolicyChildNoCanonicalResult(tx,run,thread,child,callId,allocate,guard)
        journalStreamCheck(guard)
    })
}
