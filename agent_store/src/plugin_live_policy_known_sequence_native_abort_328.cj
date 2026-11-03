package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// This lookup is data only. It creates no PreparedToolInvocation, Root,
// approval decision, execution grant, result lease or recovery registry.
// The actual original Parent Source and complete CURRENT own causal chain
// authorize every row before any historical identity is copied.
private func livePolicyKnownSequenceAdmissionNativeAbort328(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,sequence:Int64):Int64{
    let rows=tx.query("SELECT a.rowid FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
        "JOIN operations p ON p.id=a.parent_operation_id AND p.run_id=o.run_id AND p.tool_call_item_id=o.tool_call_item_id "+
        "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state "+
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id "+
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id "+
        "WHERE a.parent_operation_id=? AND a.root_operation_id=? AND o.run_id=? AND o.tool_call_item_id=? "+
        "AND typeof(a.call_sequence)='integer' AND a.call_sequence=? AND typeof(a.depth)='integer' AND a.depth=1 "+
        "AND ((o.state='committed' AND receipt.outcome='completed') OR (o.state='rejected' AND receipt.outcome='rejected') OR (o.state='failed' AND receipt.outcome='failed')) "+
        "AND (SELECT COUNT(*) FROM derived_operation_admissions n WHERE n.parent_operation_id=a.parent_operation_id "+
        "AND n.call_sequence=a.call_sequence)=1 AND (SELECT COUNT(*) FROM operation_receipts n WHERE n.operation_id=o.id)=1 "+
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions n WHERE n.parent_operation_id=o.id) "+
        "AND NOT EXISTS(SELECT 1 FROM items n WHERE n.id=e.reserved_result_item_id) LIMIT 2",
        [SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Text(run.value),
         SqlParameter.Text(root.itemId().value),SqlParameter.Int64Value(sequence)])
    if(rows.size!=1 || rows[0].size!=1){
        throw IllegalStateException("historical data has no sole settled actual own child at its exact sequence")}
    // The complete signed SQLite rowid domain is preserved.
    journalStreamInteger(rows[0].required(0))
}

private func livePolicyKnownSequenceApprovalNativeAbort328(value:AgentValue,child:OperationId,thread:ThreadId,
    callId:String,plan:NormalizedOperationPlan):?ApprovalRequest{
    if(value.unifiedKind==ValueKind.Null){return None<ApprovalRequest>}
    if(!httpIntentExactFields(value,["operation_id","call_id","tool_name","session_id","argument_hash","capability","resource"]) ||
        plan.requiredCapabilities.size!=1 || httpIntentText(value,"operation_id")!=child.value ||
        httpIntentText(value,"call_id")!=callId || httpIntentText(value,"tool_name")!=plan.toolName ||
        httpIntentText(value,"session_id")!=thread.value || httpIntentText(value,"argument_hash")=="" ||
        httpIntentText(value,"capability")!=storeCapabilityName(plan.requiredCapabilities[0].kind) ||
        httpIntentText(value,"resource")!=plan.requiredCapabilities[0].resource){
        throw IllegalStateException("historical data changed the complete original prepared approval identity")}
    // Reconstituted review DATA only. The original prepared evidence, actual
    // durable decision/ceiling, exact handoff or User no-effect witness are
    // independently checked by the existing full known-proposal verifier.
    Some(ApprovalRequest(child,callId,plan.toolName,plan.requiredCapabilities[0],
        preview:plan.canonicalArguments,sessionId:thread.value,argumentHash:httpIntentText(value,"argument_hash")))
}

// Iterate one exact sequence at a time. There is no receipt-array/count cap;
// every actual plan, original approval identity, complete raw receipt error,
// proposal pin and CURRENT full Source/fence remains paid through Unit use.
public func withPluginLivePolicyKnownProposalSequenceNativeAbort328(tx:SqliteTransaction,root:OperationRootSource,
    parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,
    sequence:Int64,currentThrough:Int64,currentLedger:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,
    guard:()->Result<Unit>,consume:(AgentValue,PluginDocumentPayloadReference,AgentValue)->Unit):Unit{
    journalStreamCheck(guard)
    if(sequence<1 || sequence>currentThrough ||
        !pluginLivePolicyLedgerReferenceValidNativeAbort328(currentLedger,parent.value,currentThrough)){
        throw IllegalStateException("historical data requires an existing exact sequence in the complete own known prefix")}
    let source:()->Unit={=>
        requirePluginLivePolicyParentSourceStreamedNativeAbort328(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
            phase:LivePolicyParentPhase.Executing,progress:Some(LivePolicyReadProgress(currentThrough,currentLedger,None)))
        requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),parentPlan.toolName,
            parentPlan.canonicalArguments,allocate,guard)}
    source()
    let rowid=livePolicyKnownSequenceAdmissionNativeAbort328(tx,root,parent,run,sequence)
    let retained=allocate(65536)
    try{
        // This real enclosing phase retains only original bounded receipt
        // identity while the reader's larger plan/string phases close.
        retained.ensureRetainedPeak(1048576)
        let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let previous=if(sequence==1){
            objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(0)),
                ValueField("tip",nullValue())])
        }else{
            let priorRow=livePolicyKnownSequenceAdmissionNativeAbort328(tx,root,parent,run,sequence-1)
            // The current full Source already checked every complete prefix.
            // To read the previous tip, obtain its own frozen preceding
            // reference from the original paid plan rather than inventing it.
            livePolicyKnownPreviousReferenceNativeAbort328(tx,priorRow,parent,run,root.callId(),binding,sequence-1,allocate,guard)}
        let tip=readPluginLivePolicyReceiptRowNativeAbort328(tx,rowid,parent,run,root.callId(),binding,sequence,previous,allocate,guard)
        let child=OperationId(httpIntentText(tip,"operation_id"))
        let callId=root.callId()+":live:"+sequence.toString()
        let requestKey="live-policy:"+root.callId()+":"+sequence.toString()
        withLivePolicyStoredValue(tx,"e.normalized_plan",
            " FROM operation_effect_records e JOIN operations o ON o.id=e.operation_id AND o.run_id=e.run_id "+
            "AND o.tool_call_item_id=e.tool_call_item_id WHERE e.operation_id=? AND e.run_id=? AND e.tool_call_item_id=?",
            [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(root.itemId().value)],allocate,guard,{encoded=>
                let plan=decodeOperationPlan(encoded)
                if(modelPolicySha256Text(encoded)!=httpIntentText(tip,"plan_sha256") ||
                    !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,plan) ||
                    requestKey!=pluginLivePolicyStreamingRequestKey(root.callId(),plan)){
                    throw IllegalStateException("historical data substituted the immutable actually normalized child plan")}
                withLivePolicyStoredValue(tx,"payload",
                    " FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_child_prepared_v1'",
                    [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{raw=>
                        let evidence=decodeStoredValue(raw)
                        let expected=livePolicyKnownSequenceApprovalNativeAbort328(evidence.field("approval").getOrThrow(),child,thread,callId,plan)
                        withPluginLivePolicyKnownProposalInputsNativeAbort328(tx,root,parent,child,run,thread,epoch,parentPlan,plan,
                            requestKey,callId,expected,currentThrough,currentLedger,allocate,verifyContent,guard,consume)
                    })
            })
        if(livePolicyKnownSequenceAdmissionNativeAbort328(tx,root,parent,run,sequence)!=rowid){
            throw IllegalStateException("historical data admission changed before its actual complete consumption ACK")}
    }finally{retained.close()}
    source();journalStreamCheck(guard)
}

// Read a previous receipt's actual frozen preceding prefix from its paid
// original plan. Complete Source replay already proved that every such
// prefix is part of this parent; the original row reader proves it again.
private func livePolicyKnownPreviousReferenceNativeAbort328(tx:SqliteTransaction,rowid:Int64,parent:OperationId,run:RunId,
    callId:String,binding:AgentValue,sequence:Int64,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):AgentValue{
    let result=LivePolicyKnownSequenceReferenceNativeAbort328()
    let suffix=" FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id WHERE a.rowid=? "+
        "AND a.parent_operation_id=? AND o.run_id=?"
    withLivePolicyStoredValue(tx,"o.normalized_plan",suffix,
        [SqlParameter.Int64Value(rowid),SqlParameter.Text(parent.value),SqlParameter.Text(run.value)],allocate,guard,{encoded=>
            let plan=decodeOperationPlan(encoded)
            if(!isPluginLivePolicyStreamingChildPlan(plan) ||
                journalStreamInteger(plan.canonicalArguments.field("sequence").getOrThrow().asNumberText())!=sequence){
                throw IllegalStateException("historical previous tip changed its actual immutable child sequence")}
            let tip=readPluginLivePolicyReceiptRowNativeAbort328(tx,rowid,parent,run,callId,binding,sequence,
                plan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
            // The caller's enclosing actual 1MiB reservation retains this
            // strictly bounded five-field Node after the raw plan closes.
            result.value=Some(objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(sequence)),
                ValueField("tip",tip)]))
        })
    result.value.getOrThrow()
}
private class LivePolicyKnownSequenceReferenceNativeAbort328 {
    var value:?AgentValue=None<AgentValue>
    init(){}
}
