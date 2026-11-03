package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// The original generic Derived settlement has already proved its exact
// canonical parent, actual admitted child, reserved unique Receipt, execution
// handoff and current Host guard. This fixed primitive uses that same TX.
func settlePluginRowJournalInTransaction(tx:SqliteTransaction,run:RunId,parent:OperationId,receipt:VNextOperationReceipt,
    plan:NormalizedOperationPlan,allocate:?(Int64)->LogicalJsonOwnerReservation,committer:?PluginDocumentPayloadCommitter,
    guard:()->Result<Unit>):Unit{
    if(!isPluginDocumentRowJournalChildPlan(plan)){throw IllegalStateException("invalid strict row journal settlement plan")}
    if(receipt.outcome!=OperationOutcome.Completed){return}
    let intent=parsePluginDocumentRowJournalIntent(plan.canonicalArguments).value().getOrThrow()
    if(canonicalAgentValue(receipt.detail)!=canonicalAgentValue(intent.result()) || allocate.isNone()){
        throw IllegalStateException("row journal Receipt differs from its exact frozen child result")}
    if(encodeStoredValue(receipt.detail).size>8388608 || encodeStoredValue(receipt.verification).size>8388608){
        throw IllegalStateException("row journal Receipt exceeds its original durable codec")}
    let handoff=tx.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? AND thread_id=? AND kind='operation_execution_handoff' LIMIT 2",
        [SqlParameter.Text(receipt.operationId.value),SqlParameter.Text(run.value),SqlParameter.Text(httpIntentText(intent.binding(),"thread_id"))])
    if(handoff.size!=1){throw IllegalStateException("row journal has no actual unique child handoff")}
    let parents=tx.query("SELECT normalized_plan,tool_call_item_id FROM operations WHERE id=? AND run_id=?",
        [SqlParameter.Text(parent.value),SqlParameter.Text(run.value)])
    if(parents.size!=1){throw IllegalStateException("row journal actual parent absent")}
    let actual=decodeOperationPlan(parents[0].required(0))
    requireDocumentWindowPayloadPlan(tx,run,ItemId(parents[0].required(1)),actual,allocate,true)
    journalStreamCheck(guard)
    if(intent.append){
        if(committer.isNone()){throw IllegalStateException("row journal append requires its actual locked content owner")}
        let proof=SqlitePluginRowJournalCommitProof(tx,run,parent,receipt.operationId,plan,intent,actual.contextReadFacts,allocate.getOrThrow(),guard)
        try{
            match(committer.getOrThrow().commit(proof)){case Result.Err(error)=>throw PluginDocumentGuardFailure(error);case Result.Ok(_)=>()}
            if(!proof.didApply()){throw IllegalStateException("row journal committer did not consume its actual finite proof")}
        }finally{proof.close()}
    }else if(committer.isSome()){throw IllegalStateException("row journal read cannot accept a mutation committer")}
    journalStreamCheck(guard)
    // The caller now inserts the one already reserved canonical Receipt.
    // Receipt, row/events and logical revision roll back together on failure.
}

func requireCompletedRowJournalPayload(tx:SqliteTransaction,plan:NormalizedOperationPlan,
    allocate:?(Int64)->LogicalJsonOwnerReservation):Unit{
    if(allocate.isNone() || !isPluginDocumentRowJournalChildPlan(plan)){throw IllegalStateException("row journal completion has no original paid owner")}
    let intent=parsePluginDocumentRowJournalIntent(plan.canonicalArguments).value().getOrThrow();let run=RunId(httpIntentText(intent.binding(),"run_id"))
    let child=tx.query("SELECT o.id,a.parent_operation_id,r.id FROM operations o JOIN operation_effect_records e ON e.operation_id=o.id AND e.normalized_plan=o.normalized_plan AND e.run_id=o.run_id JOIN derived_operation_admissions a ON a.operation_id=o.id JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state JOIN operation_receipts r ON r.operation_id=o.id AND r.id=e.reserved_receipt_id WHERE o.run_id=? AND o.normalized_plan=? AND o.state='committed' AND r.outcome='completed' AND r.detail=? LIMIT 2",
        [SqlParameter.Text(run.value),SqlParameter.Text(encodeOperationPlan(plan)),SqlParameter.Text(encodeStoredValue(intent.result()))])
    if(child.size!=1){throw IllegalStateException("row journal completion has no exact actual committed child Receipt")}
    let parents=tx.query("SELECT normalized_plan FROM operations WHERE id=? AND run_id=?",[SqlParameter.Text(child[0].required(1)),SqlParameter.Text(run.value)])
    if(parents.size!=1){throw IllegalStateException("row journal completion lost its actual full parent")}
    let parent=decodeOperationPlan(parents[0].required(0));let links=parent.contextReadFacts
    requireDocumentWindowPayloadPlan(tx,run,ItemId(requireContextReadFact(tx,links[0].operationId,run).origin.parentCallItemId),parent,allocate,false)
    if(!intent.append){let observed=requireToolWindowInput(tx,links,intent.binding(),windowFactDataList(tx,links));observed.close();return}
    // The durable audit codec is byte-length-framed, not JSON. Capture only
    // indexed metadata first, then pay the same bounded worst-case node extent
    // as the original document pins before loading or decoding the raw value.
    let metadata=tx.query("SELECT id,length(CAST(payload AS BLOB)) FROM audit_events WHERE operation_id=? AND run_id=? AND kind='row_journal_commit_observed' LIMIT 2",
        [SqlParameter.Text(child[0].required(0)),SqlParameter.Text(run.value)])
    if(metadata.size!=1){throw IllegalStateException("row journal has no unique actual commit state witness")}
    let bytes=journalStreamInteger(metadata[0].required(1))
    if(bytes<1 || bytes>65536){throw IllegalStateException("row journal commit state witness exceeds its fixed durable codec bound")}
    let owner=allocate.getOrThrow()(bytes)
    try{
        owner.ensureDecoded(bytes,bytes)
        let observed=tx.query("SELECT payload FROM audit_events WHERE id=? AND operation_id=? AND run_id=? AND kind='row_journal_commit_observed' AND length(CAST(payload AS BLOB))=?",
            [SqlParameter.Text(metadata[0].required(0)),SqlParameter.Text(child[0].required(0)),SqlParameter.Text(run.value),SqlParameter.Int64Value(bytes)])
        if(observed.size!=1){throw IllegalStateException("row journal actual commit state witness changed during capture")}
        let witness=decodeStoredValue(observed[0].required(0))
        if(!httpIntentExactFields(witness,["schema","plan_sha256","binding","manifest_payload","before_state","after_state","revision"]) ||
            httpIntentText(witness,"schema")!="axyndra.row-journal-commit-observation/v1" ||
            httpIntentText(witness,"plan_sha256")!=modelPolicySha256Text(encodeOperationPlan(plan)) ||
            canonicalAgentValue(witness.field("binding").getOrThrow())!=canonicalAgentValue(intent.binding()) ||
            canonicalAgentValue(witness.field("manifest_payload").getOrThrow())!=canonicalAgentValue(intent.manifestPayload.value()) ||
            journalWindowInteger(witness.field("revision").getOrThrow())!=intent.expectedRevision+1){
            throw IllegalStateException("row journal state witness differs from its actual completed Root")}
        let first=requireWindowObservation(tx,links[0],journalWindowFactPlan(tx,links[0]))
        try{
        if(canonicalAgentValue(first.value.field("state").getOrThrow())!=canonicalAgentValue(witness.field("before_state").getOrThrow())){
            throw IllegalStateException("row journal before fence differs from its actual manifest")}
        let selected=tx.documentStorageBackend(httpIntentText(intent.binding(),"namespace"),intent.key)
        let backend=match(selected){case Some(value)=>match(latestJournalOriginalWindowBackend(value)){case Some(value)=>value;
            case None=>throw IllegalStateException("actual completed backend changed")};case None=>throw IllegalStateException("actual completed backend missing")}
        let actual=backend.full(tx,journalWindowFactPlan(tx,links[0]),{=>Result<Unit>.Ok(())});let state=witness.field("after_state").getOrThrow()
        if(actual.digest!=httpIntentText(state,"sha256") || actual.chain!=httpIntentText(state,"chain_sha256") ||
            actual.nextEvent!=journalWindowInteger(state.field("next_event_id").getOrThrow()) ||
            actual.rows!=journalWindowInteger(state.field("rows").getOrThrow()) || actual.events!=journalWindowInteger(state.field("events").getOrThrow()) ||
            backend.revision(tx)!=intent.expectedRevision+1){throw IllegalStateException("completed row journal state differs from its original predicted future fence")}
        }finally{first.close()}
    }finally{owner.close()}
}

func currentFrozenDocumentResult(host:AgentValue,now:Int64):Result<Unit>{
    if(httpIntentText(host,"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){return pluginDocumentRowJournalFrozenResultCurrent(host,now)}
    pluginDocumentFrozenResultCurrent(host,now)
}
