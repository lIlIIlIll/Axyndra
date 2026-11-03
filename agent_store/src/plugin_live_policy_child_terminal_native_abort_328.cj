package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// Shape only. Neither this descriptor nor an output lease is a Source or
// evidence of settlement. Bound every scalar before invoking an encoder.
func livePolicyChildTerminalValueValidNativeAbort328(value:AgentValue,parent:OperationId,sequence:Int64):Bool{
    try{
        if(sequence<1 || value.unifiedKind!=ValueKind.Object || value.asObject().size()!=2 ||
            !httpIntentExactFields(value,["schema","receipt"]) ||
            httpIntentText(value,"schema")!="axyndra.plugin-live-effect-result/v1"){return false}
        let tip=value.field("receipt").getOrThrow()
        if(tip.unifiedKind!=ValueKind.Object || tip.asObject().size()!=5 ||
            !httpIntentExactFields(tip,["sequence","operation_id","receipt_id","plan_sha256","outcome"])){return false}
        let ordinal=tip.field("sequence").getOrThrow()
        if(ordinal.unifiedKind!=ValueKind.Number || ordinal.asNumberText().size>19 ||
            journalStreamInteger(ordinal.asNumberText())!=sequence){return false}
        // The unchanged Domain predicate checks exact five fields, bounded
        // identifiers, raw SHA256 and the two known outcomes. No arbitrary
        // result subtree is stringified to decide whether it is bounded.
        pluginLivePolicyLedgerReferenceValidNativeAbort328(objectValue([
            ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(parent.value)),
            ValueField("through_sequence",integerValue(sequence)),ValueField("tip",tip)]),parent.value,sequence)
    }catch(_:Exception){false}
}
func livePolicyChildTerminalResultValidNativeAbort328(parent:OperationId,child:OperationId,sequence:Int64,callId:String,result:ToolResult):Bool{
    if(result.callId!=callId || result.receiptId!=child.value || result.payloadLease.isNone() ||
        !livePolicyChildTerminalValueValidNativeAbort328(result.output,parent,sequence)){return false}
    let tip=result.output.field("receipt").getOrThrow()
    httpIntentText(tip,"operation_id")==child.value &&
        result.isError==(["rejected","failed"].contains(httpIntentText(tip,"outcome")))
}

// This Unit-only lifetime cannot return a raw string, DOM, prefix or snapshot.
// It never closes the caller's output lease or acknowledges physical debt.
func withLivePolicyChildTerminalPaymentNativeAbort328(allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:()->Unit):Unit{
    journalStreamCheck(guard)
    let owner=allocate(65536)
    try{
        owner.ensureRetainedPeak(1048576)
        journalStreamCheck(guard);consume();journalStreamCheck(guard)
    }finally{owner.close()}
}

// Numeric-only lookup under the caller's paid terminal phase. This relation
// is not an authorizer; the full plan, receipt, handoff and Source follow.
func livePolicyChildTerminalAdmissionRowNativeAbort328(tx:SqliteTransaction,parent:OperationId,child:OperationId,
    run:RunId,item:ItemId,sequence:Int64,requestKey:String,requestDigest:String,callId:String):Int64{
    let rows=tx.query("SELECT a.rowid FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
        "JOIN operations p ON p.id=a.parent_operation_id AND p.run_id=o.run_id AND p.tool_call_item_id=o.tool_call_item_id "+
        "JOIN operation_state_registers s ON s.operation_id=o.id AND s.state=o.state "+
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id "+
        "JOIN operation_receipts r ON r.operation_id=o.id AND r.id=e.reserved_receipt_id "+
        "WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? AND a.parent_operation_id=? AND a.root_operation_id=? "+
        "AND typeof(a.call_sequence)='integer' AND a.call_sequence=? AND typeof(a.depth)='integer' AND a.depth=1 "+
        "AND a.request_key=? AND a.request_digest=? AND a.child_call_id=? "+
        "AND ((o.state='committed' AND r.outcome='completed') OR (o.state='rejected' AND r.outcome='rejected') OR (o.state='failed' AND r.outcome='failed')) "+
        "AND (SELECT COUNT(*) FROM derived_operation_admissions n WHERE n.parent_operation_id=a.parent_operation_id "+
        "AND n.call_sequence=a.call_sequence)=1 AND (SELECT COUNT(*) FROM operation_receipts n WHERE n.operation_id=o.id)=1 "+
        "AND NOT EXISTS(SELECT 1 FROM derived_operation_admissions n WHERE n.parent_operation_id=o.id) "+
        "AND NOT EXISTS(SELECT 1 FROM items n WHERE n.id=e.reserved_result_item_id) LIMIT 2",
        [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value),
         SqlParameter.Text(parent.value),SqlParameter.Text(parent.value),SqlParameter.Int64Value(sequence),
         SqlParameter.Text(requestKey),SqlParameter.Text(requestDigest),SqlParameter.Text(callId)])
    if(rows.size!=1 || rows[0].size!=1){throw IllegalStateException("terminal child lost its sole same-TX actual admission/reserved Receipt")}
    // SQLite's full signed rowid domain is valid; no positive-only shortcut.
    journalStreamInteger(rows[0].required(0))
}

func livePolicyChildTerminalUnsettledHeaderNativeAbort328(content:ThreadItemContent,child:OperationId,callId:String):Unit{
    match(content){case ThreadItemContent.ToolResult(id,operation,_,_,_)=>
        if(id.value==callId || operation.value==child.value){
            throw IllegalStateException("terminal child already has a canonical ToolResult")}
        case _=>throw IllegalStateException("actual tool-result row lost its original required header")}
}
func requireLivePolicyChildNoCanonicalResultNativeAbort328(tx:SqliteTransaction,run:RunId,thread:ThreadId,child:OperationId,callId:String,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    var after:?Int64=None
    while(true){
        journalStreamCheck(guard)
        let base=" FROM items i JOIN runs r ON r.thread_id=i.thread_id AND r.turn_id=i.turn_id "+
            "WHERE r.id=? AND r.thread_id=? AND i.kind='tool_result'"
        let rows=match(after){
            case None=>tx.query("SELECT i.rowid"+base+" ORDER BY i.rowid LIMIT 1",
                [SqlParameter.Text(run.value),SqlParameter.Text(thread.value)])
            case Some(last)=>tx.query("SELECT i.rowid"+base+" AND i.rowid>? ORDER BY i.rowid LIMIT 1",
                [SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Int64Value(last)])}
        if(rows.isEmpty()){break}
        let rowid=journalStreamInteger(rows[0].required(0))
        let suffix=base+" AND i.rowid=?"
        withContextReadMetadataCell(tx,"SELECT length(CAST(i.payload AS BLOB))"+suffix,"SELECT i.payload"+suffix,
            [SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Int64Value(rowid)],allocate,guard,{_,meter=>
                // Every body is scanned through original grammar/UTF8/EOF;
                // only the original required header is decoded for equality.
                livePolicyChildTerminalUnsettledHeaderNativeAbort328(decodeStoredThreadContent(encodeStoredValue(meter.consumptionHeader())),child,callId)})
        after=Some(rowid)
    }
    journalStreamCheck(guard)
}

func requireLivePolicyChildTerminalPreparedNativeAbort328(tx:SqliteTransaction,parent:OperationId,child:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,allocate:(Int64)->LogicalJsonOwnerReservation,
    guard:()->Result<Unit>):Unit{
    let owner=allocate(65536)
    try{
        owner.ensureRetainedPeak(contextReadMetadataRawPeak(livePolicyPreparedTupleBytes(parent,child,run,thread,
            parentPlan,childPlan,requestKey,callId,expected)))
        journalStreamCheck(guard)
        match(expected){case Some(value)=>
            // The original full preview equality allocates two canonical
            // encodings. Measure BOTH actual current values and pay their
            // combined raw/node peak before invoking that unchanged check.
            let preview=livePolicyStoredExtent(value.preview)
            let arguments=livePolicyStoredExtent(childPlan.canonicalArguments)
            owner.ensureRetainedPeak(journalStreamAdd(contextReadMetadataRawPeak(livePolicyPreparedTupleBytes(parent,child,run,thread,
                parentPlan,childPlan,requestKey,callId,expected)),
                contextReadMetadataPeak(journalStreamAdd(preview.bytes,arguments.bytes),journalStreamAdd(preview.nodes,arguments.nodes))))
            if(!livePolicyApprovalMatches(value,child,thread,callId,childPlan)){
                throw IllegalStateException("terminal child changed its retained original review")}
            case None=>()}
        livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT COUNT(*) FROM audit_events WHERE operation_id=? "+
            "AND kind='plugin_live_child_prepared_v1')=1",[SqlParameter.Text(child.value)],
            "terminal child has no sole original prepared audit")
        let evidence=livePolicyPreparedEvidence(parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,expected)
        withLivePolicyStoredValue(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
            "AND kind='plugin_live_child_prepared_v1'",
            [SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,{actual=>
                if(canonicalAgentValue(decodeStoredValue(actual))!=canonicalAgentValue(evidence)){
                    throw IllegalStateException("terminal child changed its full original prepared Source/approval")}})
        journalStreamCheck(guard)
    }finally{owner.close()}
}

func requireLivePolicyChildTerminalApprovalNativeAbort328(tx:SqliteTransaction,child:OperationId,childPlan:NormalizedOperationPlan,
    expected:?ApprovalRequest,outcome:String,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    match(expected){
        case None=>
            if(outcome!="completed"){throw IllegalStateException("known user rejection has no original retained review")}
            livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM approvals WHERE operation_id=?)",
                [SqlParameter.Text(child.value)],"original Ready terminal child adopted another durable approval")
        case Some(_)=>withLivePolicyPlanEncoding(childPlan,allocate,guard,{_=>
            // Execution admission/handoff already checked expiry against the
            // actual clock. A later terminal check cannot turn known work
            // into unknown merely because that approved interval has ended.
            let decision=if(outcome=="completed"){"approved"}else{"rejected"}
            livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND operation_digest=? "+
                "AND decision=? AND CAST(capability_ceiling AS BLOB)=CAST(? AS BLOB) "+
                "AND ((?='completed' AND length(CAST(source AS BLOB))>0) OR (?='rejected' AND source='user')) "+
                "AND (expires_at_millis IS NULL OR (typeof(expires_at_millis)='integer' AND expires_at_millis>=0)) "+
                "AND (SELECT COUNT(*) FROM approvals other WHERE other.operation_id=approvals.operation_id)=1",
                [SqlParameter.Text(child.value),SqlParameter.Text(childPlan.bindingDigest),SqlParameter.Text(decision),
                 SqlParameter.Text(encodeCapabilities(childPlan.requiredCapabilities)),SqlParameter.Text(outcome),SqlParameter.Text(outcome)],
                "terminal child lost its exact durable decision/plan/capability evidence")
            journalStreamCheck(guard)
        })
    }
    journalStreamCheck(guard)
}

// Verify only, with the actual Prepared invocation's retained approval.
// No mutation, new Source, admission, Root, result Item, output release or
// cleanup ACK occurs here. Tools must still own the actual output lease and
// Host collector and perform their original physical settlement ordering.
func requirePluginLivePolicyChildTerminalNativeAbort328(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,child:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,childPlan:NormalizedOperationPlan,
    requestKey:String,callId:String,expected:?ApprovalRequest,result:ToolResult,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,streamedSource!:Bool=false):Unit{
    withLivePolicyChildTerminalPaymentNativeAbort328(allocate,guard,{=>
        if(child.value==parent.value || !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,childPlan) ||
            requestKey!=pluginLivePolicyStreamingRequestKey(root.callId(),childPlan)){
            throw IllegalStateException("terminal child substituted its independently normalized parent/plan/request")}
        let sequence=journalStreamInteger(childPlan.canonicalArguments.field("sequence").getOrThrow().asNumberText())
        if(sequence<1 || callId!=root.callId()+":live:"+sequence.toString() ||
            !livePolicyChildTerminalResultValidNativeAbort328(parent,child,sequence,callId,result)){
            throw IllegalStateException("terminal result has no exact bounded known child/call/leased output")}
        let rowid=livePolicyChildTerminalAdmissionRowNativeAbort328(tx,parent,child,run,root.itemId(),sequence,requestKey,childPlan.bindingDigest,callId)
        journalStreamCheck(guard)
        withLivePolicyPlanEncoding(childPlan,allocate,guard,{encoded=>
            requireLivePolicyImmutableEffect(tx,child,run,root.itemId(),childPlan,encoded)})
        requireLivePolicyChildTerminalPreparedNativeAbort328(tx,parent,child,run,thread,epoch,parentPlan,childPlan,requestKey,callId,
            expected,allocate,guard)
        let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let tip=readPluginLivePolicyReceiptRowNativeAbort328(tx,rowid,parent,run,root.callId(),binding,sequence,
            childPlan.canonicalArguments.field("prior_receipts").getOrThrow(),allocate,guard)
        // tip lives in the enclosing 1 MiB owner after the ledger reader's
        // own full raw/plan payments close, through every remaining check.
        if(httpIntentText(tip,"operation_id")!=child.value ||
            canonicalAgentValue(tip)!=canonicalAgentValue(result.output.field("receipt").getOrThrow())){
            throw IllegalStateException("terminal output differs from its actual reserved Receipt and full plan")}
        let outcome=httpIntentText(tip,"outcome")
        requireLivePolicyChildTerminalApproval(tx,child,childPlan,expected,if(outcome=="failed"){"completed"}else{outcome},allocate,guard)
        livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? "+
            "AND kind IN ('operation_cancellation_settlement_only','operation_direct_preparation_rejection_only')) "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='plugin_live_no_effect_settled_v1')=? "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')=? "+
            "AND (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND kind='plugin_live_journal_causal_v1')=1",
            [SqlParameter.Text(child.value),SqlParameter.Text(child.value),SqlParameter.Int64Value(if(outcome=="rejected"){1}else{0}),
                SqlParameter.Text(child.value),SqlParameter.Int64Value(if(outcome!="rejected"){1}else{0}),SqlParameter.Text(child.value)],
            "known terminal child has conflicting or duplicated handoff/no-effect settlement evidence")
        if(outcome!="rejected"){
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
        let actualPrefix=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(sequence)),ValueField("tip",tip)])
        // Include the already terminal child. None excludes no own child;
        // the full Parent Source replays actual receipts and every 17-field
        // causal witness and current full fence, never the caller's DTO tip.
        if(streamedSource){
            requirePluginLivePolicyParentSourceStreamedNativeAbort328(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
                phase:LivePolicyParentPhase.Executing,progress:Some(LivePolicyReadProgress(sequence,actualPrefix,None)))
        }else{
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
            phase:LivePolicyParentPhase.Executing,progress:Some(LivePolicyReadProgress(sequence,actualPrefix,None)))
        }
        requireLivePolicyChildNoCanonicalResultNativeAbort328(tx,run,thread,child,callId,allocate,guard)
        journalStreamCheck(guard)
    })
}
