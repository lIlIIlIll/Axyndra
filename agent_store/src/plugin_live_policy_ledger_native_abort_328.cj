package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Same-TX receipt relationship only. This helper is deliberately package-
// internal and grants no Source, child admission, effect, retry or settlement.
// A future actual live-parent verifier must independently retain its complete
// paid canonical Source/current scope; an arbitrary guard cannot replace it.
class SqliteLivePolicyReceiptPrefixNativeAbort328 {
    private var value:?AgentValue
    private let charge:LogicalJsonOwnerReservation
    private let lock=Mutex()
    private var closed=false
    init(value:AgentValue,charge:LogicalJsonOwnerReservation){this.value=Some(value);this.charge=charge}
    func reference():AgentValue{
        lock.lock();try{if(closed){throw IllegalStateException("live prefix owner is closed")};value.getOrThrow()}finally{lock.unlock()}}
    func close():Unit{
        lock.lock();try{if(!closed){closed=true;value=None;charge.close()}}finally{lock.unlock()}}
}

// Every previous OWN child is inspected. No inline receipt array, history
// count cap, Native scalar invoice, private corpus hash or private ID lookup.
// The actual rowid cursor starts without a lower bound and covers Int64.
func readPluginLivePolicyReceiptPrefixNativeAbort328(tx:SqliteTransaction,parentOperation:OperationId,run:RunId,
    parentCallId:String,binding:AgentValue,throughSequence:Int64,expectedReference:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):SqliteLivePolicyReceiptPrefixNativeAbort328{
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
            tip=readPluginLivePolicyReceiptRowNativeAbort328(tx,rowid,parentOperation,run,parentCallId,binding,next,previous,allocate,guard)
            ordinal=next;cursor=Some(rowid)
        }
        if(ordinal!=throughSequence){throw IllegalStateException("live prefix is incomplete")}
        let actual=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
            ValueField("parent_operation_id",textValue(parentOperation.value)),ValueField("through_sequence",integerValue(ordinal)),
            ValueField("tip",tip)])
        if(canonicalAgentValue(actual)!=canonicalAgentValue(expectedReference)){
            throw IllegalStateException("live prefix substituted an own receipt tip")}
        journalStreamCheck(guard);SqliteLivePolicyReceiptPrefixNativeAbort328(actual,referenceCharge)
    }catch(error:Exception){referenceCharge.close();throw error}
}

// Exact nine-column numeric extent only. No raw identity/state/value is
// loaded until their complete simultaneous String extent has been paid.
func livePolicyLedgerCopiedHeaderBytesNativeAbort328(lengths:SqliteRow):Int64{
    if(lengths.size!=9){throw IllegalStateException("live prefix metadata column count changed")}
    var total:Int64=0
    for(index in 0..9){let bytes=journalStreamInteger(lengths.required(index))
        if(bytes<1){throw IllegalStateException("live prefix copied header cell is empty")}
        total=journalStreamAdd(total,bytes)}
    total
}

func readPluginLivePolicyReceiptRowNativeAbort328(tx:SqliteTransaction,rowid:Int64,parentOperation:OperationId,run:RunId,
    parentCallId:String,binding:AgentValue,sequence:Int64,previous:AgentValue,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):AgentValue{
    let parameters=[SqlParameter.Int64Value(rowid),SqlParameter.Text(parentOperation.value),SqlParameter.Text(run.value)]
    let suffix=" FROM derived_operation_admissions a JOIN operations o ON o.id=a.operation_id "+
        "JOIN operations parent ON parent.id=a.parent_operation_id AND parent.run_id=o.run_id AND parent.tool_call_item_id=o.tool_call_item_id "+
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id "+
        "AND CAST(e.normalized_plan AS BLOB)=CAST(o.normalized_plan AS BLOB) "+
        "JOIN operation_state_registers state ON state.operation_id=o.id AND state.state=o.state "+
        "JOIN operation_receipts receipt ON receipt.operation_id=o.id AND receipt.id=e.reserved_receipt_id "+
        "WHERE a.rowid=? AND a.parent_operation_id=? AND o.run_id=?"
    journalStreamCheck(guard)
    // Only numeric extents materialize before the raw owner. IDs/request keys
    // are measured too, including state/outcome/depth. SQLite is not assumed
    // to contain short legal TEXT or a legal depth scalar before validation.
    let lengths=tx.query("SELECT length(CAST(o.id AS BLOB)),length(CAST(a.request_key AS BLOB)),"+
        "length(CAST(a.request_digest AS BLOB)),length(CAST(a.child_call_id AS BLOB)),"+
        "length(CAST(a.root_operation_id AS BLOB)),length(CAST(receipt.id AS BLOB)),"+
        "length(CAST(o.state AS BLOB)),length(CAST(receipt.outcome AS BLOB)),length(CAST(a.depth AS BLOB))"+suffix,parameters)
    if(lengths.size!=1){throw IllegalStateException("live prefix has no unique reserved receipt/effect/state")}
    let smallBytes=livePolicyLedgerCopiedHeaderBytesNativeAbort328(lengths[0])
    let small=allocate(65536)
    try{
        small.ensureRetainedPeak(contextReadMetadataRawPeak(smallBytes))
        let headers=tx.query("SELECT o.id,a.request_key,a.request_digest,a.child_call_id,a.root_operation_id,"+
            "receipt.id,o.state,receipt.outcome,a.depth"+suffix,parameters)
        if(headers.size!=1){throw IllegalStateException("live prefix metadata changed")}
        let header=headers[0]
        for(index in 0..9){if(header.required(index).size!=journalStreamInteger(lengths[0].required(index))){
            throw IllegalStateException("live prefix identity extent changed")}}
        if(header.required(1)!="live-policy:"+parentCallId+":"+sequence.toString() ||
            header.required(3)!=parentCallId+":live:"+sequence.toString() ||
            header.required(4)!=parentOperation.value || header.required(8)!="1" ||
            !((header.required(6)=="committed" && header.required(7)=="completed") ||
                (header.required(6)=="rejected" && header.required(7)=="rejected") ||
                (header.required(6)=="failed" && header.required(7)=="failed"))){
            throw IllegalStateException("live prefix is not a contiguous completed/known-no-effect own child")}
        // Ignored user-facing result/detail bodies still receive the original
        // complete StoredValue grammar/UTF8/node/EOF scan and exact payment.
        // Each temporary raw value is released before the next phase.
        let _=contextReadMetadataMeasure(tx,"receipt.detail",suffix,parameters,allocate,guard)
        let _=contextReadMetadataMeasure(tx,"receipt.verification",suffix,parameters,allocate,guard)
        let planCell=contextReadMetadataMeasure(tx,"o.normalized_plan",suffix,parameters,allocate,guard)
        let planPhase=allocate(65536)
        try{
            planPhase.ensureRetainedPeak(contextReadMetadataPeak(planCell.bytes,planCell.nodes))
            let rows=tx.query("SELECT o.normalized_plan"+suffix,parameters)
            if(rows.size!=1 || rows[0].required(0).size!=planCell.bytes){throw IllegalStateException("live prefix plan extent changed")}
            let encoded=rows[0].required(0);let plan=decodeOperationPlan(encoded)
            if(!pluginLivePolicyStreamingChildValueValidNativeAbort328(plan.canonicalArguments) ||
                !livePolicyLedgerPlanEnvelopeValidNativeAbort328(plan) || plan.bindingDigest!=header.required(2) ||
                canonicalAgentValue(plan.canonicalArguments.field("prior_receipts").getOrThrow())!=canonicalAgentValue(previous) ||
                canonicalAgentValue(plan.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
                journalStreamInteger(plan.canonicalArguments.field("sequence").getOrThrow().asNumberText())!=sequence ||
                httpIntentText(plan.canonicalArguments.field("prior_receipts").getOrThrow(),"parent_operation_id")!=parentOperation.value){
                throw IllegalStateException("live prefix plan does not bind its actual sequence/parent/effect")}
            let digest=modelPolicySha256Text(encoded)
            // Rejected is sufficient ONLY when the actual Store's future
            // zero-effect/rollback-ACK settlement wrote this exact witness in
            // the same transaction. Arbitrary Err/rejected text is insufficient.
            if(header.required(7)=="rejected"){
                let witness=objectValue([ValueField("schema",textValue("axyndra.plugin-live-no-effect/v1")),
                    ValueField("parent_operation_id",textValue(parentOperation.value)),ValueField("run_id",textValue(run.value)),
                    ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue(header.required(0))),
                    ValueField("receipt_id",textValue(header.required(5))),ValueField("plan_sha256",textValue(digest))])
                let audits=tx.query("SELECT id FROM audit_events WHERE operation_id=? AND run_id=? "+
                    "AND kind='plugin_live_no_effect_settled_v1' AND CAST(payload AS BLOB)=CAST(? AS BLOB) LIMIT 2",
                    [SqlParameter.Text(header.required(0)),SqlParameter.Text(run.value),SqlParameter.Text(encodeStoredValue(witness))])
                if(audits.size!=1){throw IllegalStateException("live rejected child lacks its exclusive actual no-effect settlement witness")}}
            if(header.required(7)=="failed"){
                requireLivePolicyNativeAbortStoredWitness328(tx,parentOperation,OperationId(header.required(0)),run,
                    sequence,header.required(5),digest,allocate,guard,planPhase,journalStreamAdd(contextReadMetadataRawPeak(smallBytes),contextReadMetadataPeak(planCell.bytes,planCell.nodes)))
            }
            livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT COUNT(*) FROM audit_events WHERE operation_id=? "+
                "AND kind='plugin_live_write_rollback_settled_v1')=?",
                [SqlParameter.Text(header.required(0)),SqlParameter.Int64Value(if(header.required(7)=="failed"){1}else{0})],
                "actual terminal prefix has conflicting native-abort settlement evidence")
            journalStreamCheck(guard)
            let tip=objectValue([ValueField("sequence",integerValue(sequence)),ValueField("operation_id",textValue(header.required(0))),
                ValueField("receipt_id",textValue(header.required(5))),ValueField("plan_sha256",textValue(digest)),
                ValueField("outcome",textValue(header.required(7)))])
            let reference=objectValue([ValueField("schema",textValue(PLUGIN_LIVE_POLICY_LEDGER_REFERENCE_SCHEMA)),
                ValueField("parent_operation_id",textValue(parentOperation.value)),ValueField("through_sequence",integerValue(sequence)),ValueField("tip",tip)])
            if(!pluginLivePolicyLedgerReferenceValidNativeAbort328(reference,parentOperation.value,sequence)){
                throw IllegalStateException("live receipt cannot fit its original bounded identity descriptor")}
            // The checked identifier/digest/field bounds guarantee this small
            // descriptor fits the already retained referenceCharge. Full SQL
            // strings and decoded plan remain confined to the phases above.
            tip
        }finally{planPhase.close()}
    }finally{small.close()}
}

// Same existing exact effect/capability envelope; new v2 shape is validated
// above. This pure relationship cannot admit the new family in old Store.
func livePolicyLedgerPlanEnvelopeValidNativeAbort328(plan:NormalizedOperationPlan):Bool{
    // Only the new strict streaming dialect uses the actual normalizer's
    // WorkspaceMutation filesystem class. All v1 predicates below remain
    // exact, and this relationship cannot admit or approve any effect.
    if(pluginLivePolicyStreamingChildValueValidNativeAbort328(plan.canonicalArguments)){
        return isPluginLivePolicyStreamingChildPlan(plan)}
    if(plan.toolName!=HOST_PLUGIN_LIVE_EFFECT_TOOL || plan.implementation.toolVersion!=HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT ||
        plan.implementation.implementationFingerprint!=HOST_PLUGIN_LIVE_EFFECT_FINGERPRINT ||
        plan.effectClass!=OperationEffectClass.ExternalMutation || plan.retryDisposition!=OperationRetryDisposition.Never ||
        plan.idempotencyKey!="" || !plan.resolvedHosts.isEmpty() || !plan.relevantEnvironment.isEmpty() ||
        !plan.contextReadFacts.isEmpty() || plan.requiredCapabilities.size!=1 ||
        !networkPolicyModeIsDenied(plan.networkPolicy.mode) || !plan.networkPolicy.egress.isEmpty() || !plan.networkPolicy.publish.isEmpty()){
        return false}
    let effect=plan.canonicalArguments.field("effect").getOrThrow();let cap=plan.requiredCapabilities[0]
    let scope=if(httpIntentText(effect,"kind")=="row_journal.append"){
        cap.kind==CapabilityKind.ExtensionInvoke && cap.resource==httpIntentText(plan.canonicalArguments.field("binding").getOrThrow(),"namespace") && plan.resolvedPaths.isEmpty()
    }else{let path=httpIntentText(effect,"canonical_path");cap.kind==CapabilityKind.WorkspaceWrite && cap.resource==path && plan.resolvedPaths.size==1 && plan.resolvedPaths[0]==path}
    scope && match(plan.replayDisposition){case ReplayDisposition.NeverReplay=>true;case _=>false}
}
