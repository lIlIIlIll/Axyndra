package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

func liveKnownRequireHistoricalCausalPrefixOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,
    binding:AgentValue,link:ContextReadFactLink,key:String,initialFence:String,initialRevision:Int64,
    through:Int64,expected:AgentValue,pending:?OperationId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,owner:LogicalJsonOwnerReservation,extraRetained:Int64):Unit {
    if(through<0 || !httpIntentDigest(initialFence) || initialRevision<1 ||
        !pluginLivePolicyLedgerReferenceValid(expected,parent.value,through)){
        throw IllegalStateException("causal input has no exact original observation and own prefix")}
    let parentCall=httpIntentText(binding,"parent_call_id")
    match(pending){case Some(actual)=>livePolicyRequireCausalExcludedChildOwned(tx,parent,run,parentCall,binding,
        through,expected,actual,allocate,guard,owner,extraRetained);case None=>()}
    // Cursor, current/previous bounded tip and scalar digests stay paid for
    // this complete Unit scope in the existing Source/observation owner.
    let prefixRetained=journalStreamAdd(extraRetained,1048576)
    try {
        owner.ensureRetainedPeak(prefixRetained)
        let bindingDigest=modelPolicySha256Text(canonicalAgentValue(binding))
        let readDigest=modelPolicySha256Text(canonicalAgentValue(link.toValue()))
        var cursor:?Int64=None;var ordinal:Int64=0;var tip:AgentValue=nullValue()
        var fence=initialFence;var revision=initialRevision
        while(true){
            journalStreamCheck(guard)
            let ignore=match(pending){case Some(actual)=>" AND operation_id<>?";case None=>""}
            let args=ArrayList<SqlParameter>();args.add(SqlParameter.Text(parent.value))
            match(pending){case Some(actual)=>args.add(SqlParameter.Text(actual.value));case None=>()}
            let after=match(cursor){case Some(last)=>args.add(SqlParameter.Int64Value(last));" AND rowid>?";case None=>""}
            let rows=tx.query("SELECT rowid FROM derived_operation_admissions WHERE parent_operation_id=?"+
                ignore+after+" ORDER BY rowid LIMIT 1",args.toArray())
            if(rows.isEmpty()){break}
            if(ordinal>=through){throw IllegalStateException("causal input has an extra or unsettled own child")}
            let rowid=journalStreamInteger(rows[0].required(0));let next=journalStreamAdd(ordinal,1)
            // The original paid receipt reader validates the plan sequence.
            // Independently bind the actual admission's canonical sequence,
            // including unique ownership, without loading another plan DOM.
            let sequenceRows=tx.query("SELECT 1 FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                "WHERE a.rowid=? AND a.parent_operation_id=? AND o.run_id=? "+
                "AND CAST(a.call_sequence AS BLOB)=CAST(? AS BLOB) "+
                "AND (SELECT COUNT(*) FROM derived_operation_admissions n WHERE n.parent_operation_id=a.parent_operation_id "+
                "AND CAST(n.call_sequence AS BLOB)=CAST(? AS BLOB))=1",
                [SqlParameter.Int64Value(rowid),SqlParameter.Text(parent.value),SqlParameter.Text(run.value),
                    SqlParameter.Text(next.toString()),SqlParameter.Text(next.toString())])
            if(sequenceRows.size!=1){throw IllegalStateException("causal input changed its unique actual own admission sequence")}
            let previous=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(ordinal)),
                ValueField("tip",tip)])
            // This original paid reader checks every full own plan/detail/EOF,
            // exact previous prefix, reserved Receipt and no-effect witness.
            let actualTip=readPluginLivePolicyReceiptRowOwned(tx,rowid,parent,run,parentCall,binding,next,previous,allocate,guard,owner,prefixRetained)
            let operation=httpIntentText(actualTip,"operation_id")
            let childSuffix=" FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
                "WHERE a.rowid=? AND a.parent_operation_id=? AND o.run_id=? AND o.id=?"
            let childArgs=[SqlParameter.Int64Value(rowid),SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(operation)]
            let effectState=LivePolicyCausalOwnedEffectState()
            withLivePolicyStoredValueOwned(tx,"o.normalized_plan",childSuffix,childArgs,allocate,guard,owner,prefixRetained,{encoded=>
                let plan=decodeOperationPlan(encoded);let effect=plan.canonicalArguments.field("effect").getOrThrow()
                effectState.appendsJournal=httpIntentText(effect,"kind")=="row_journal.append"
                if(modelPolicySha256Text(encoded)!=httpIntentText(actualTip,"plan_sha256") ||
                    (effectState.appendsJournal && httpIntentText(effect,"key")!=key)){
                    throw IllegalStateException("causal input effect changed its paid plan or read journal key")}
            })
            let auditSuffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_journal_causal_v1'"
            let auditArgs=[SqlParameter.Text(operation),SqlParameter.Text(run.value),SqlParameter.Text(httpIntentText(binding,"thread_id"))]
            let beforeFence=fence;let beforeRevision=revision
            let receiptState=LivePolicyCausalOwnedReceiptState()
            withLivePolicyStoredValueOwned(tx,"payload",auditSuffix,auditArgs,allocate,guard,owner,prefixRetained,{encoded=>
                let value=decodeStoredValue(encoded)
                if(!httpIntentExactFields(value,["schema","parent_operation_id","run_id","thread_id","lane_id","epoch",
                    "binding_digest","read_fact_digest","sequence","operation_id","receipt_id","plan_sha256","key",
                    "before_fence","after_fence","before_revision","after_revision"]) ||
                    httpIntentText(value,"schema")!="axyndra.plugin-live-journal-causal/v1" ||
                    httpIntentText(value,"parent_operation_id")!=parent.value || httpIntentText(value,"run_id")!=run.value ||
                    httpIntentText(value,"thread_id")!=httpIntentText(binding,"thread_id") ||
                    httpIntentText(value,"lane_id")!=httpIntentText(binding,"lane_id") ||
                    value.field("epoch").getOrThrow().asNumberText()!=binding.field("epoch").getOrThrow().asNumberText() ||
                    httpIntentText(value,"binding_digest")!=bindingDigest || httpIntentText(value,"read_fact_digest")!=readDigest ||
                    value.field("sequence").getOrThrow().asNumberText()!=next.toString() ||
                    httpIntentText(value,"operation_id")!=operation ||
                    httpIntentText(value,"receipt_id")!=httpIntentText(actualTip,"receipt_id") ||
                    httpIntentText(value,"plan_sha256")!=httpIntentText(actualTip,"plan_sha256") ||
                    httpIntentText(value,"key")!=key || httpIntentText(value,"before_fence")!=beforeFence ||
                    livePolicyCausalPositiveRevision(value.field("before_revision").getOrThrow())!=beforeRevision ||
                    !httpIntentDigest(httpIntentText(value,"after_fence"))){
                    throw IllegalStateException("causal input lost its unique complete own before/after witness")}
                let proposed=livePolicyCausalPositiveRevision(value.field("after_revision").getOrThrow())
                let completed=httpIntentText(actualTip,"outcome")=="completed"
                if(completed && effectState.appendsJournal){
                    if(proposed<=beforeRevision){throw IllegalStateException("own completed append did not advance its actual journal")}
                }else if(proposed!=beforeRevision || httpIntentText(value,"after_fence")!=beforeFence){
                    throw IllegalStateException("known no-effect or filesystem child cannot advance journal history")}
                // Copy only fixed validated64 bytes while this paid phase is
                // held; no large SQL/decoded witness remains with the cursor.
                receiptState.afterFence=String.fromUtf8(httpIntentText(value,"after_fence").toArray());receiptState.afterRevision=proposed
            })
            fence=receiptState.afterFence;revision=receiptState.afterRevision;tip=actualTip;ordinal=next;cursor=Some(rowid)
        }
        let actual=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(parent.value)),ValueField("through_sequence",integerValue(ordinal)),ValueField("tip",tip)])
        if(ordinal!=through || canonicalAgentValue(actual)!=canonicalAgentValue(expected)){
            throw IllegalStateException("causal input omitted or substituted an own receipt prefix")}
        journalStreamCheck(guard)
        // Historical seven/17-field chain only. The executing/current
        // full backend fence was checked before the canonical Core writer.
        // A later lawful Parent append must not re-mint that old Source.
        // Current ContextFacts/work debt remain the caller's original check.
        journalStreamCheck(guard)
    }finally{}
}


// Additional immutable terminal relations are checked for EVERY child, not
// just the bounded final tip. This does not construct an Approval or Source.
func liveKnownRequireChildHistoricalTuple(tx:SqliteTransaction,parent:OperationId,run:RunId,thread:ThreadId,
    epoch:Int64,parentPlan:NormalizedOperationPlan,parentMarker:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>):Unit{
    var cursor:?Int64=None
    while(true){
        let args=ArrayList<SqlParameter>([SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
        let after=match(cursor){case None=>"";case Some(last)=>args.add(SqlParameter.Int64Value(last));" AND a.rowid>?"}
        let found=tx.query("SELECT a.rowid FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "WHERE a.parent_operation_id=? AND o.run_id=?"+after+" ORDER BY a.rowid LIMIT 1",args.toArray())
        if(found.isEmpty()){break};let rowid=journalStreamInteger(found[0].required(0))
        let params=[SqlParameter.Int64Value(rowid),SqlParameter.Text(parent.value),SqlParameter.Text(run.value)]
        let suffix=" FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
            "JOIN operation_effect_records e ON e.operation_id=o.id WHERE a.rowid=? AND a.parent_operation_id=? AND o.run_id=?"
        let lengths=tx.query("SELECT length(CAST(o.id AS BLOB)),length(CAST(a.child_call_id AS BLOB)),"+
            "length(CAST(a.request_key AS BLOB)),length(CAST(o.state AS BLOB)),length(CAST(e.reserved_result_item_id AS BLOB))"+suffix,params)
        if(lengths.size!=1){throw IllegalStateException("historical child has no original reserved identity")}
        var bytes:Int64=0;for(index in 0..5){let size=journalStreamInteger(lengths[0].required(index))
            if(size<1){throw IllegalStateException("historical child identity is empty")};bytes=journalStreamAdd(bytes,size)}
        let headerPeak=journalStreamAdd(retained,contextReadMetadataRawPeak(bytes));owner.ensureRetainedPeak(headerPeak)
        let headers=tx.query("SELECT o.id,a.child_call_id,a.request_key,o.state,e.reserved_result_item_id"+suffix,params)
        if(headers.size!=1){throw IllegalStateException("historical child identity changed")}
        for(index in 0..5){if(headers[0].required(index).size!=journalStreamInteger(lengths[0].required(index))){
            throw IllegalStateException("historical child identity extent drift")}}
        let child=OperationId(headers[0].required(0));let call=headers[0].required(1);let key=headers[0].required(2)
        let rejected=headers[0].required(3)=="rejected"
        if(!rejected && headers[0].required(3)!="committed"){throw IllegalStateException("historical child is not Known terminal")}
        if(!tx.query("SELECT 1 FROM items WHERE id=?",[SqlParameter.Text(headers[0].required(4))]).isEmpty()){
            throw IllegalStateException("historical derived child cannot acquire an independent canonical ToolResult")}
        let childCell=contextReadMetadataMeasureOwned(tx,"o.normalized_plan",suffix,params,owner,headerPeak,guard)
        withLivePolicyStoredValueOwned(tx,"o.normalized_plan",suffix,params,allocate,guard,owner,headerPeak,{encoded=>
            let plan=decodeOperationPlan(encoded)
            let planPeak=journalStreamAdd(headerPeak,contextReadMetadataPeak(childCell.bytes,childCell.nodes))
            if(!isPluginLivePolicyStreamingChildPlan(plan) || !pluginLivePolicyStreamingChildWithinCeiling(parentPlan,plan)){
                throw IllegalStateException("historical child changed its exact strict-v2 immutable ceiling")}
            let auditArgs=[SqlParameter.Text(child.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)]
            let auditSuffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='plugin_live_child_prepared_v1'"
            let auditCell=contextReadMetadataMeasureOwned(tx,"payload",auditSuffix,auditArgs,owner,planPeak,guard)
            withLivePolicyStoredValueOwned(tx,"payload",auditSuffix,auditArgs,allocate,guard,owner,planPeak,{raw=>
                let auditPeak=journalStreamAdd(planPeak,contextReadMetadataPeak(auditCell.bytes,auditCell.nodes))
                let value=decodeStoredValue(raw)
                if(!httpIntentExactFields(value,["schema","parent_operation_id","operation_id","run_id","thread_id","epoch",
                    "parent_binding_digest","child_binding_digest","request_key","call_id","approval"]) ||
                    httpIntentText(value,"schema")!="axyndra.plugin-live-policy-prepared/v1" ||
                    httpIntentText(value,"parent_operation_id")!=parent.value || httpIntentText(value,"operation_id")!=child.value ||
                    httpIntentText(value,"run_id")!=run.value || httpIntentText(value,"thread_id")!=thread.value ||
                    value.field("epoch").getOrThrow().asNumberText()!=epoch.toString() ||
                    httpIntentText(value,"parent_binding_digest")!=parentPlan.bindingDigest ||
                    httpIntentText(value,"child_binding_digest")!=plan.bindingDigest || httpIntentText(value,"request_key")!=key ||
                    httpIntentText(value,"call_id")!=call){throw IllegalStateException("historical child lost its entire original prepared audit")}
                let approval=value.field("approval").getOrThrow()
                if(approval.unifiedKind==ValueKind.Null){
                    if(rejected || !tx.query("SELECT 1 FROM approvals WHERE operation_id=?",[SqlParameter.Text(child.value)]).isEmpty()){
                        throw IllegalStateException("historical child cannot downgrade a reviewed User rejection to Ready")}
                }else{
                    if(!httpIntentExactFields(approval,["operation_id","call_id","tool_name","session_id","argument_hash","capability","resource"]) ||
                        httpIntentText(approval,"operation_id")!=child.value || httpIntentText(approval,"call_id")!=call ||
                        httpIntentText(approval,"tool_name")!=plan.toolName || httpIntentText(approval,"session_id")!=thread.value ||
                        httpIntentText(approval,"argument_hash")=="" || plan.requiredCapabilities.size!=1 ||
                        httpIntentText(approval,"capability")!=storeCapabilityName(plan.requiredCapabilities[0].kind) ||
                        httpIntentText(approval,"resource")!=plan.requiredCapabilities[0].resource){
                        throw IllegalStateException("historical child approval changed its exact original reviewed tuple")}
                    // No terminal-clock expiry test: the actual handoff/User
                    // rejection checked its durable decision at execution.
                    let decision=if(rejected){"rejected"}else{"approved"}
                    // Both the child plan and complete prepared audit remain
                    // live here. Pay the original capability wrapper before
                    // constructing it, then its entire encoding/SQL copies.
                    let wrappers=journalStreamAdd(128,plan.requiredCapabilities.size*4)
                    if(wrappers>(Int64.Max-1048576)/2048){throw IllegalStateException("known capability wrapper overflow")}
                    let wrapperPeak=journalStreamAdd(auditPeak,1048576+wrappers*2048)
                    owner.ensureRetainedPeak(wrapperPeak)
                    let capabilities=capabilityValues(plan.requiredCapabilities)
                    let ceilingExtent=livePolicyStoredExtent(capabilities)
                    if(ceilingExtent.bytes>(Int64.Max-wrapperPeak)/12){throw IllegalStateException("known capability encoding payment overflow")}
                    owner.ensureRetainedPeak(journalStreamAdd(wrapperPeak,ceilingExtent.bytes*12))
                    let ceiling=encodeCapabilities(plan.requiredCapabilities)
                    if(ceiling.size!=ceilingExtent.bytes){throw IllegalStateException("known capability original codec extent changed")}
                    livePolicyRequireOne(tx,"SELECT 1 FROM approvals WHERE operation_id=? AND operation_digest=? AND decision=? "+
                        "AND CAST(capability_ceiling AS BLOB)=CAST(? AS BLOB) AND (?=0 OR source='user') "+
                        "AND (expires_at_millis IS NULL OR (typeof(expires_at_millis)='integer' AND expires_at_millis>=0))",
                        [SqlParameter.Text(child.value),SqlParameter.Text(plan.bindingDigest),SqlParameter.Text(decision),SqlParameter.Text(ceiling),
                         SqlParameter.Int64Value(if(rejected){1}else{0})],"historical child has no unique actual durable decision/exact ceiling")
                }
            })
            if(rejected){
                livePolicyRequireOne(tx,"SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM audit_events WHERE operation_id=? AND kind='operation_execution_handoff')",
                    [SqlParameter.Text(child.value)],"genuine rejected child acquired an execution handoff")
                withLivePolicyStoredValueOwned(tx,"detail"," FROM operation_receipts WHERE operation_id=? AND outcome='rejected'",
                    [SqlParameter.Text(child.value)],allocate,guard,owner,planPeak,{raw=>
                    let detail=decodeStoredValue(raw)
                    if(!httpIntentExactFields(detail,["code","message"]) || httpIntentText(detail,"code")!="plugin.live_child_user_rejected" ||
                        httpIntentText(detail,"message")!="the user rejected this reviewed child before execution"){
                        throw IllegalStateException("historical rejected child is not the actual known User-no-effect outcome")}})
                livePolicyRequireOne(tx,"SELECT 1 FROM operation_receipts WHERE operation_id=? AND outcome='rejected' AND CAST(verification AS BLOB)=CAST('n' AS BLOB)",
                    [SqlParameter.Text(child.value)],"historical rejected child changed its original null verification")
            }else{
                withLivePolicyStoredValueOwned(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='operation_execution_handoff'",
                    auditArgs,allocate,guard,owner,planPeak,{raw=>
                    let handoff=decodeStoredValue(raw);let binding=parentPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
                    if(!httpIntentExactFields(handoff,["schema","parent_operation_id","operation_id","run_id","thread_id","epoch","lane_id",
                        "projection_digest","root_item_id","root_call_id","child_call_id","request_key","sequence","parent_plan_sha256",
                        "child_plan_sha256","parent_binding_digest","child_binding_digest","source"]) ||
                        httpIntentText(handoff,"schema")!="axyndra.plugin-live-policy-child-handoff/v1" ||
                        httpIntentText(handoff,"parent_operation_id")!=parent.value || httpIntentText(handoff,"operation_id")!=child.value ||
                        httpIntentText(handoff,"run_id")!=run.value || httpIntentText(handoff,"thread_id")!=thread.value ||
                        handoff.field("epoch").getOrThrow().asNumberText()!=epoch.toString() ||
                        httpIntentText(handoff,"lane_id")!=httpIntentText(binding,"lane_id") ||
                        httpIntentText(handoff,"projection_digest")!=parentPlan.contextReadFacts[0].origin.projectionDigest ||
                        httpIntentText(handoff,"root_item_id")!=httpIntentText(parentMarker,"root_item_id") ||
                        httpIntentText(handoff,"root_call_id")!=httpIntentText(parentMarker,"root_call_id") ||
                        httpIntentText(handoff,"child_call_id")!=call || httpIntentText(handoff,"request_key")!=key ||
                        handoff.field("sequence").getOrThrow().asNumberText()!=plan.canonicalArguments.field("sequence").getOrThrow().asNumberText() ||
                        httpIntentText(handoff,"parent_plan_sha256")!=httpIntentText(parentMarker,"parent_plan_sha256") ||
                        httpIntentText(handoff,"child_plan_sha256")!=modelPolicySha256Text(encoded) ||
                        httpIntentText(handoff,"parent_binding_digest")!=parentPlan.bindingDigest ||
                        httpIntentText(handoff,"child_binding_digest")!=plan.bindingDigest ||
                        canonicalAgentValue(handoff.field("source").getOrThrow())!=canonicalAgentValue(parentMarker.field("source").getOrThrow())){
                        throw IllegalStateException("historical completed child lost its full original handoff/actual source class")}})
            }
        })
        cursor=Some(rowid);journalStreamCheck(guard)
    }
}

// Full historical data-only revalidation. It never calls the running-only
// consumption helper or turns an old fact/marker into a new execution Source.
func liveKnownRequireHistoricalReadAndPrefix(tx:SqliteTransaction,parent:OperationId,run:RunId,thread:ThreadId,
    epoch:Int64,plan:NormalizedOperationPlan,prefix:AgentValue,parentMarker:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,owner:LogicalJsonOwnerReservation,retained:Int64,guard:()->Result<Unit>):Unit{
    if(plan.contextReadFacts.size!=1 || !isPluginLivePolicyParentPlan(plan)){
        throw IllegalStateException("historical Parent has no original sole complete read contract")}
    let link=plan.contextReadFacts[0]
    let payment=ContextReadCompletedMetadataPayment(tx,link,allocate,guard,phaseOwner:Some(owner),extraRetained:retained)
    try{
        let read=payment.plan();let fact=payment.fact()
        if(!pluginDocumentLatestJournalStreamReadAuthority(read) || pluginDocumentContextLatestJournalStreamReadAuthority(read) ||
            link.runId.value!=run.value || fact.runId.value!=run.value ||
            canonicalAgentValue(fact.reference())!=canonicalAgentValue(link.toValue()) ||
            fact.origin.parentCallItemId!=httpIntentText(parentMarker,"root_item_id") ||
            documentPayloadParentOperation(fact).value!=parent.value ||
            fact.origin.projectionDigest!=plan.contextReadFacts[0].origin.projectionDigest){
            throw IllegalStateException("historical read changed its full original completed Tool12 fact")}
        let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let request=read.canonicalArguments;let readBinding=request.field("binding").getOrThrow()
        if(canonicalAgentValue(binding)!=canonicalAgentValue(readBinding) || httpIntentText(binding,"thread_id")!=thread.value ||
            httpIntentText(binding,"run_id")!=run.value || binding.field("epoch").getOrThrow().asNumberText()!=epoch.toString()){
            throw IllegalStateException("historical Parent/read binding changed")}
        let data=fact.output();let document=data.field("documents").getOrThrow().items[0]
        let through=journalStreamInteger(prefix.field("through_sequence").getOrThrow().asNumberText())
        let _=payment.withBorrowedObservation({phaseOwner,peak=>
            withLivePolicyStoredValueOwned(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
                "AND kind='plugin_document_latest_journal_observed'",
                [SqlParameter.Text(link.operationId.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,phaseOwner,peak,{raw=>
                let observed=decodeStoredValue(raw)
                if(!httpIntentExactFields(observed,["schema","thread_id","lane_id","run_id","read_operation_id","read_item_id","plan_sha256",
                    "binding","projection_digest","access_policy_digest","view_policy_digest","key","revision","epoch","private_event_fence","stream"]) ||
                    httpIntentText(observed,"schema")!="axyndra.journal-stream-observation/v3" || httpIntentText(observed,"thread_id")!=thread.value ||
                    httpIntentText(observed,"lane_id")!=httpIntentText(binding,"lane_id") || httpIntentText(observed,"run_id")!=run.value ||
                    httpIntentText(observed,"read_operation_id")!=link.operationId.value || httpIntentText(observed,"read_item_id")!=link.sourceItemId.value ||
                    httpIntentText(observed,"plan_sha256")!=modelPolicySha256Text(encodeOperationPlan(read)) ||
                    canonicalAgentValue(observed.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
                    httpIntentText(observed,"projection_digest")!=httpIntentText(request,"projection_digest") ||
                    httpIntentText(observed,"access_policy_digest")!=httpIntentText(request,"access_policy_digest") ||
                    httpIntentText(observed,"view_policy_digest")!=httpIntentText(request,"view_policy_digest") ||
                    httpIntentText(observed,"key")!=httpIntentText(request,"key") ||
                    observed.field("epoch").getOrThrow().asNumberText()!=binding.field("epoch").getOrThrow().asNumberText() ||
                    observed.field("revision").getOrThrow().asNumberText()!=document.field("revision").getOrThrow().asNumberText() ||
                    canonicalAgentValue(observed.field("stream").getOrThrow())!=canonicalAgentValue(document.field("stream").getOrThrow())){
                    throw IllegalStateException("historical observation changed its whole original private contract")}
                let observationExtent=livePolicyStoredExtent(observed)
                let retainedObservation=journalStreamAdd(peak,contextReadMetadataPeak(raw.size,observationExtent.nodes))
                liveKnownRequireHistoricalCausalPrefixOwned(tx,parent,run,binding,link,httpIntentText(request,"key"),
                    httpIntentText(observed,"private_event_fence"),livePolicyCausalPositiveRevision(document.field("revision").getOrThrow()),
                    through,prefix,None<OperationId>,allocate,guard,phaseOwner,retainedObservation)
            })
        })
        let _=payment.withBorrowedObservation({phaseOwner,peak=>
            liveKnownRequireChildHistoricalTuple(tx,parent,run,thread,epoch,plan,parentMarker,allocate,phaseOwner,peak,guard)})
    }finally{payment.close()}
}
