package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*


// No authority is returned. All historical Parent contracts in the same Run
// are inspected, including ones whose next legal Parent already appended.
func liveKnownRequireParentHistoryOwned(tx:SqliteTransaction,parent:OperationId,run:RunId,thread:ThreadId,
    owner:LogicalJsonOwnerReservation,retained:Int64,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    livePolicyRequireOne(tx,"SELECT count(*) FROM audit_events WHERE operation_id=? AND kind=? HAVING count(*)=1",
        [SqlParameter.Text(parent.value),SqlParameter.Text(LIVE_KNOWN_PARENT_AUDIT)],
        "known Parent has more than one or a foreign-enclosure private witness")
    let args=[SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Text(LIVE_KNOWN_PARENT_AUDIT)]
    let suffix=" FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind=?"
    let cell=contextReadMetadataMeasureOwned(tx,"payload",suffix,args,owner,retained,guard)
    withLivePolicyStoredValueOwned(tx,"payload",suffix,args,allocate,guard,owner,retained,{encoded=>
        let value=decodeStoredValue(encoded);let witnessPeak=journalStreamAdd(retained,contextReadMetadataPeak(cell.bytes,cell.nodes))
        if(!httpIntentExactFields(value,["schema","parent_operation_id","run_id","thread_id","epoch","root_item_id","root_call_id",
            "parent_binding_digest","canonical_item_id","canonical_item_ordinal","canonical_receipt_id","post_thread_revision",
            "snapshot_head","prior_receipts","terminal_audit_id","immutable_history_sha256","canonical_sha256"]) ||
            httpIntentText(value,"schema")!=LIVE_KNOWN_PARENT_SCHEMA || httpIntentText(value,"parent_operation_id")!=parent.value ||
            httpIntentText(value,"run_id")!=run.value || httpIntentText(value,"thread_id")!=thread.value ||
            !httpIntentDigest(httpIntentText(value,"immutable_history_sha256")) || !httpIntentDigest(httpIntentText(value,"canonical_sha256"))){
            throw IllegalStateException("known Parent has no exact private canonical history contract")}
        let epoch=journalStreamInteger(value.field("epoch").getOrThrow().asNumberText())
        let revision=journalStreamInteger(value.field("post_thread_revision").getOrThrow().asNumberText())
        let ordinal=journalStreamInteger(value.field("canonical_item_ordinal").getOrThrow().asNumberText())
        let snapshot=journalStreamInteger(value.field("snapshot_head").getOrThrow().asNumberText())
        let terminalId=journalStreamInteger(value.field("terminal_audit_id").getOrThrow().asNumberText())
        if(epoch<0 || revision<1 || ordinal<1 || snapshot<0 || terminalId<1){throw IllegalStateException("known Parent historical counter is invalid")}
        let item=ItemId(httpIntentText(value,"root_item_id"));let prefix=value.field("prior_receipts").getOrThrow()
        let through=journalStreamInteger(prefix.field("through_sequence").getOrThrow().asNumberText())
        if(!pluginLivePolicyLedgerReferenceValid(prefix,parent.value,through)){
            throw IllegalStateException("known Parent omitted its full own bounded prefix")}
        livePolicyRequireOne(tx,"SELECT 1 FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id "+
            "JOIN operation_state_registers s ON s.operation_id=o.id JOIN operation_receipts r ON r.operation_id=o.id "+
            "JOIN items i ON i.id=e.reserved_result_item_id JOIN threads t ON t.id=i.thread_id JOIN runs run ON run.id=o.run_id "+
            "WHERE o.id=? AND o.run_id=? AND o.tool_call_item_id=? AND o.state='committed' AND s.state='committed' "+
            "AND r.id=e.reserved_receipt_id AND r.id=? AND r.outcome IN ('completed','failed') AND i.id=? AND i.ordinal=? "+
            "AND i.thread_id=? AND i.turn_id=run.turn_id AND i.kind='tool_result' AND t.revision>=? AND run.epoch=?",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value),
             SqlParameter.Text(httpIntentText(value,"canonical_receipt_id")),SqlParameter.Text(httpIntentText(value,"canonical_item_id")),
             SqlParameter.Int64Value(ordinal),SqlParameter.Text(thread.value),SqlParameter.Int64Value(revision),SqlParameter.Int64Value(epoch)],
            "known historical Parent lost its reserved canonical Receipt/result/provenance enclosure")
        if(liveKnownCanonicalDigest(tx,parent,run,thread,owner,witnessPeak,guard)!=httpIntentText(value,"canonical_sha256")){
            throw IllegalStateException("known canonical Receipt/output/item/provenance changed after commit")}
        let planSuffix=" FROM operations WHERE id=? AND run_id=? AND tool_call_item_id=?"
        let planArgs=[SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(item.value)]
        let planCell=contextReadMetadataMeasureOwned(tx,"normalized_plan",planSuffix,planArgs,owner,witnessPeak,guard)
        withLivePolicyStoredValueOwned(tx,"normalized_plan",planSuffix,planArgs,allocate,guard,owner,witnessPeak,{raw=>
            let plan=decodeOperationPlan(raw);let planPeak=journalStreamAdd(witnessPeak,contextReadMetadataPeak(planCell.bytes,planCell.nodes))
            if(!isPluginLivePolicyParentPlan(plan) || plan.bindingDigest!=httpIntentText(value,"parent_binding_digest") || plan.contextReadFacts.size!=1){
                throw IllegalStateException("known historical Parent changed its complete original plan")}
            if(liveKnownHistoryDigest(tx,liveKnownImmutableQueries(parent,run,item,plan.contextReadFacts[0]),owner,planPeak,guard)!=
                httpIntentText(value,"immutable_history_sha256")){
                throw IllegalStateException("known Parent Source/read/input/prepared/child history is no longer the originally validated whole")}
            withLivePolicyStoredValueOwned(tx,"payload"," FROM audit_events WHERE id=? AND operation_id=? AND run_id=? AND thread_id=? "+
                "AND kind='plugin_live_policy_parent_terminal_v1'",
                [SqlParameter.Int64Value(terminalId),SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
                allocate,guard,owner,planPeak,{terminalRaw=>
                let descriptor=decodeStoredValue(terminalRaw)
                if(!pluginLivePolicyTerminalDataValid(descriptor,parent.value,plan.bindingDigest) ||
                    canonicalAgentValue(descriptor.field("prior_receipts").getOrThrow())!=canonicalAgentValue(prefix)){
                    throw IllegalStateException("known terminal audit changed its exact originally FD-verified descriptor")}
                let descriptorPeak=journalStreamAdd(planPeak,contextReadMetadataPeak(terminalRaw.size,livePolicyStoredExtent(descriptor).nodes))
                let reference=parsePluginDocumentPayloadReference(descriptor.field("result_payload").getOrThrow()).value().getOrThrow()
                liveKnownRequireTerminalBlobMetadataOwned(tx,reference,owner,descriptorPeak,guard)
                withLivePolicyStoredValueOwned(tx,"payload"," FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? "+
                    "AND kind='plugin_live_parent_prepared_v1'",
                    [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],allocate,guard,owner,descriptorPeak,{markerRaw=>
                    let marker=decodeStoredValue(markerRaw)
                    if(!httpIntentExactFields(marker,["schema","parent_operation_id","run_id","thread_id","epoch","lane_id","projection_digest",
                        "root_item_id","root_call_id","parent_plan_sha256","parent_binding_digest","source"]) ||
                        httpIntentText(marker,"schema")!="axyndra.plugin-live-policy-parent-prepared/v1" ||
                        httpIntentText(marker,"parent_operation_id")!=parent.value || httpIntentText(marker,"run_id")!=run.value ||
                        httpIntentText(marker,"thread_id")!=thread.value || marker.field("epoch").getOrThrow().asNumberText()!=epoch.toString() ||
                        httpIntentText(marker,"root_item_id")!=item.value || httpIntentText(marker,"root_call_id")!=httpIntentText(value,"root_call_id") ||
                        httpIntentText(marker,"parent_plan_sha256")!=modelPolicySha256Text(raw) ||
                        httpIntentText(marker,"parent_binding_digest")!=plan.bindingDigest ||
                        httpIntentText(marker,"projection_digest")!=plan.contextReadFacts[0].origin.projectionDigest){
                        throw IllegalStateException("historical prepared Parent does not describe its original canonical Root tuple")}
                    let markerPeak=journalStreamAdd(descriptorPeak,contextReadMetadataPeak(markerRaw.size,livePolicyStoredExtent(marker).nodes))
                    liveKnownRequireHistoricalReadAndPrefix(tx,parent,run,thread,epoch,plan,prefix,marker,allocate,owner,markerPeak,guard)
                })
            })
        })
    })
    journalStreamCheck(guard)
}

// Stream all Run operations. Every noncommitted row must be the unique actual
// rejected child of a fully verified canonical Parent; a generic rejected
// state, absent receipt, pending/Unknown or physical debt never qualifies.
public func requirePluginLiveKnownRunOperationDebt(tx:SqliteTransaction,thread:ThreadId,run:RunId,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    let owner=allocate(65536)
    try{
        journalStreamCheck(guard)
        var cursor:?Int64=None
        while(true){
            let args=ArrayList<SqlParameter>([SqlParameter.Text(run.value)])
            let after=match(cursor){case None=>"";case Some(last)=>args.add(SqlParameter.Int64Value(last));" AND a.id>?"}
            let rows=tx.query("SELECT a.id FROM audit_events a WHERE a.run_id=? AND a.kind='plugin_live_known_parent_canonical_v1'"+
                after+" ORDER BY a.id LIMIT 1",args.toArray())
            if(rows.isEmpty()){break};let id=journalStreamInteger(rows[0].required(0))
            let sizes=tx.query("SELECT length(CAST(operation_id AS BLOB)),length(CAST(thread_id AS BLOB)) FROM audit_events WHERE id=?",
                [SqlParameter.Int64Value(id)])
            if(sizes.size!=1){throw IllegalStateException("known Parent audit disappeared")}
            var bytes:Int64=0;for(index in 0..2){let size=journalStreamInteger(sizes[0].required(index))
                if(size<1){throw IllegalStateException("known Parent audit owner is empty")};bytes=journalStreamAdd(bytes,size)}
            let retained=contextReadMetadataRawPeak(bytes);owner.ensureRetainedPeak(retained)
            let raw=tx.query("SELECT operation_id,thread_id FROM audit_events WHERE id=?",[SqlParameter.Int64Value(id)])
            if(raw.size!=1 || raw[0].required(0).size!=journalStreamInteger(sizes[0].required(0)) ||
                raw[0].required(1).size!=journalStreamInteger(sizes[0].required(1)) || raw[0].required(1)!=thread.value){
                throw IllegalStateException("known historical Parent audit changed its actual Thread")}
            liveKnownRequireParentHistoryOwned(tx,OperationId(raw[0].required(0)),run,thread,owner,retained,allocate,guard)
            cursor=Some(id)
        }
        // All actual operations are covered, including rejected rows that
        // are not named by the continuation's current in-memory debt list.
        cursor=None
        while(true){
            let args=ArrayList<SqlParameter>([SqlParameter.Text(run.value)])
            let after=match(cursor){case None=>"";case Some(last)=>args.add(SqlParameter.Int64Value(last));" AND o.rowid>?"}
            let rows=tx.query("SELECT o.rowid FROM operations o WHERE o.run_id=?"+after+" ORDER BY o.rowid LIMIT 1",args.toArray())
            if(rows.isEmpty()){break};let id=journalStreamInteger(rows[0].required(0))
            if(tx.query("SELECT 1 FROM operations o JOIN operation_receipts r ON r.operation_id=o.id "+
                "WHERE o.rowid=? AND o.run_id=? AND o.state='committed'",[SqlParameter.Int64Value(id),SqlParameter.Text(run.value)]).size!=1){
                livePolicyRequireOne(tx,"SELECT 1 FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id AND s.state='rejected' "+
                    "JOIN operation_effect_records e ON e.operation_id=o.id JOIN operation_receipts r ON r.operation_id=o.id AND r.id=e.reserved_receipt_id "+
                    "JOIN derived_operation_admissions d ON d.operation_id=o.id JOIN operations p ON p.id=d.parent_operation_id AND p.run_id=o.run_id "+
                    "WHERE o.rowid=? AND o.run_id=? AND o.state='rejected' AND r.outcome='rejected' AND d.root_operation_id=p.id AND d.depth=1 "+
                    "AND p.state='committed' AND (SELECT count(*) FROM audit_events a WHERE a.operation_id=p.id AND a.run_id=o.run_id "+
                    "AND a.thread_id=? AND a.kind='plugin_live_known_parent_canonical_v1')=1",
                    [SqlParameter.Int64Value(id),SqlParameter.Text(run.value),SqlParameter.Text(thread.value)],
                    "Run still has unknown, missing-Receipt or unproven noncommitted operation debt")
            }
            cursor=Some(id);journalStreamCheck(guard)
        }
    }finally{owner.close()}
}

// All other debt components keep the exact old requirement. This opt-in
// data predicate never releases physical owners or fabricates their ACK.
public func requirePluginLiveKnownContinuationDebt(tx:SqliteTransaction,thread:ThreadId,value:DurableRunContinuationV1,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,allowUnclaimedInputs!:Bool=false):Unit{
    let debt=value.workDebt
    if((!allowUnclaimedInputs && !debt.unclaimedInputs.isEmpty()) || !debt.activeAttempts.isEmpty() || !debt.uncommittedDecisions.isEmpty() || !debt.pendingApprovals.isEmpty() ||
        !debt.waitingExternal.isEmpty() || !debt.activeChildRuns.isEmpty() || !debt.ownedTasks.isEmpty() ||
        !debt.deferredContexts.isEmpty() || value.pendingOperationId.isSome() || value.pendingApprovalId.isSome() ||
        value.waitingExternal.isSome() || value.attemptId.isSome()){
        throw IllegalStateException("context.boundary_durable_resource_owner_unavailable")}
    requirePluginLiveKnownRunOperationDebt(tx,thread,value.runId,allocate,guard)
    for(operation in debt.unsettledOperations){
        livePolicyRequireOne(tx,"SELECT 1 FROM operations o JOIN derived_operation_admissions a ON a.operation_id=o.id "+
            "JOIN operation_receipts r ON r.operation_id=o.id JOIN operation_effect_records e ON e.operation_id=o.id AND e.reserved_receipt_id=r.id "+
            "WHERE o.id=? AND o.run_id=? AND o.state='rejected' AND r.outcome='rejected' "+
            "AND (SELECT count(*) FROM audit_events w WHERE w.operation_id=a.parent_operation_id AND w.run_id=o.run_id "+
            "AND w.thread_id=? AND w.kind='plugin_live_known_parent_canonical_v1')=1",
            [SqlParameter.Text(operation.value),SqlParameter.Text(value.runId.value),SqlParameter.Text(thread.value)],
            "durable unsettled operation is not the exact proven Known rejected child")
    }
}
