package agent_store

import agent_domain.*
import agent_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Data retention only. A step pin does not prepare/approve a child, establish
// a Root, create a Receipt or turn an unknown operation into a known result.
private func livePolicyStepDataValid(value:AgentValue,parent:OperationId,plan:NormalizedOperationPlan):Bool{
    try{
        if(!httpIntentExactFields(value,["schema","parent_operation_id","parent_binding_digest","prior_receipts","payloads"]) ||
            httpIntentText(value,"schema")!="axyndra.plugin-live-policy-step-data/v1" ||
            httpIntentText(value,"parent_operation_id")!=parent.value || httpIntentText(value,"parent_binding_digest")!=plan.bindingDigest){return false}
        let prior=value.field("prior_receipts").getOrThrow()
        let through=journalStreamInteger(prior.field("through_sequence").getOrThrow().asNumberText())
        if(!pluginLivePolicyLedgerReferenceValid(prior,parent.value,through)){return false}
        let payloads=value.field("payloads").getOrThrow();if(payloads.unifiedKind!=ValueKind.List || payloads.items.isEmpty()){return false}
        let seen=HashSet<String>()
        for(row in payloads.items){
            let payload=parsePluginDocumentPayloadReference(row).value().getOrThrow()
            if(payload.bytes<1 || !seen.add(payload.digest+":"+payload.bytes.toString())){return false}}
        true
    }catch(_:Exception){false}
}

// Every complete SQL text copy gets a fresh numeric preflight. A trusted FD
// verifier is not allowed to grow a metadata cell past its prepaid extent.
func livePolicyStepPayloadMetadata(tx:SqliteTransaction,payload:PluginDocumentPayloadReference,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):Unit{
    journalStreamCheck(guard)
    let sizes=tx.query("SELECT length(CAST(mime AS BLOB)),length(CAST(size AS BLOB)),"+
        "length(CAST(metadata AS BLOB)),length(CAST(relative_path AS BLOB)) FROM artifacts WHERE hash=?",
        [SqlParameter.Text(payload.digest)])
    if(sizes.size!=1 || sizes[0].size!=4){throw IllegalStateException("live step payload has no unique actual metadata")}
    var bytes:Int64=0
    for(index in 0..4){let count=journalStreamInteger(sizes[0].required(index));if(count<1){throw IllegalStateException("live step metadata is empty")};bytes=journalStreamAdd(bytes,count)}
    if(journalStreamInteger(sizes[0].required(2))>4096 || journalStreamInteger(sizes[0].required(0))>128 ||
        journalStreamInteger(sizes[0].required(3))>256){throw IllegalStateException("live step metadata exceeds its original fixed layout")}
    let owner=allocate(65536)
    try{owner.ensureRetainedPeak(contextReadMetadataRawPeak(bytes));requireDocumentPayloadMetadata(tx,payload);journalStreamCheck(guard)}finally{owner.close()}
}

// Before publishing internal content-addressed bytes, the caller checks the
// actual executing Parent and its complete current causal chain. Publishing
// is still only data; retention repeats these predicates in its same TX.
public func verifyPluginLivePolicyStepDataParent(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,streamedSource!:Bool=false):Unit{
    journalStreamCheck(guard)
    if(streamedSource){
        let paid=allocate(65536)
        try{
            let extent=livePolicyStoredExtent(descriptor);paid.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
            if(!livePolicyStepDataValid(descriptor,parent,plan)){throw IllegalStateException("strict actual live step data descriptor required")}
            let ledger=descriptor.field("prior_receipts").getOrThrow()
            let through=journalStreamInteger(ledger.field("through_sequence").getOrThrow().asNumberText())
            let progress=Some(LivePolicyReadProgress(through,ledger,None<OperationId>))
            requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
            requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
            let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
            withPluginLivePolicyReceiptPrefixOwned(tx,parent,run,root.callId(),binding,through,ledger,allocate,guard,{_,_=>()})
            journalStreamCheck(guard)
        }finally{paid.close()}
        return
    }
    let owner=allocate(65536)
    try{
        let extent=livePolicyStoredExtent(descriptor)
        owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
        if(!livePolicyStepDataValid(descriptor,parent,plan)){throw IllegalStateException("strict actual live step data descriptor required")}
        let ledger=descriptor.field("prior_receipts").getOrThrow()
        let through=journalStreamInteger(ledger.field("through_sequence").getOrThrow().asNumberText())
        let progress=Some(LivePolicyReadProgress(through,ledger,None<OperationId>))
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
        requirePluginLivePolicyInputPayload(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
        let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let prefix=readPluginLivePolicyReceiptPrefix(tx,parent,run,root.callId(),binding,through,ledger,allocate,guard)
        prefix.close();journalStreamCheck(guard)
    }finally{owner.close()}
}


// Explicit new-family path. Every old descriptor, caller, input-pin, own
// Receipt prefix, Blob and complete fixed-FD predicate is still required.
// Borrowing the real prefix reservation pays its metadata; it grants no
// Source and cannot close another owner's retained resources.
private func withLivePolicyStepEvidenceStreamed(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,
    guard:()->Result<Unit>,consume:(String)->Unit):Unit{
    journalStreamCheck(guard)
    let owner=allocate(65536)
    try{
        let extent=livePolicyStoredExtent(descriptor)
        owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
        if(!livePolicyStepDataValid(descriptor,parent,plan)){throw IllegalStateException("strict actual live step data descriptor required")}
        let encoded=encodeStoredValue(descriptor)
        if(encoded.size!=extent.bytes){throw IllegalStateException("live step descriptor changed during paid encoding")}
        let ledger=descriptor.field("prior_receipts").getOrThrow()
        let through=journalStreamInteger(ledger.field("through_sequence").getOrThrow().asNumberText())
        let progress=Some(LivePolicyReadProgress(through,ledger,None<OperationId>))
        let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let requireCurrent:()->Unit={=>
            requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
            requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
            withPluginLivePolicyReceiptPrefixOwned(tx,parent,run,root.callId(),binding,through,ledger,allocate,guard,{actualOwner,retained=>
                for(row in descriptor.field("payloads").getOrThrow().items){
                    let payload=parsePluginDocumentPayloadReference(row).value().getOrThrow()
                    // The exact Root9 metadata preflight is repeated before
                    // each complete SQL copy and on both sides of full EOF.
                    requireLivePolicyParentTerminalBlobOwned(tx,payload,actualOwner,retained,{=>verifyContent(payload)},guard)}})}
        requireCurrent();journalStreamCheck(guard);consume(encoded);journalStreamCheck(guard)
        requireCurrent();journalStreamCheck(guard)
    }finally{owner.close()}
}

private func withLivePolicyStepEvidence(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,
    guard:()->Result<Unit>,consume:(String)->Unit,streamedSource!:Bool=false):Unit{
    if(streamedSource){withLivePolicyStepEvidenceStreamed(tx,root,parent,run,thread,epoch,plan,descriptor,allocate,verifyContent,guard,consume);return}
    journalStreamCheck(guard)
    let owner=allocate(65536)
    try{
        let extent=livePolicyStoredExtent(descriptor)
        owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
        if(!livePolicyStepDataValid(descriptor,parent,plan)){throw IllegalStateException("strict actual live step data descriptor required")}
        let encoded=encodeStoredValue(descriptor)
        if(encoded.size!=extent.bytes){throw IllegalStateException("live step descriptor changed during paid encoding")}
        let ledger=descriptor.field("prior_receipts").getOrThrow()
        let through=journalStreamInteger(ledger.field("through_sequence").getOrThrow().asNumberText())
        let progress=Some(LivePolicyReadProgress(through,ledger,None<OperationId>))
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
        requirePluginLivePolicyInputPayload(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
        let binding=plan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        let prefix=readPluginLivePolicyReceiptPrefix(tx,parent,run,root.callId(),binding,through,ledger,allocate,guard)
        prefix.close()
        for(row in descriptor.field("payloads").getOrThrow().items){
            let payload=parsePluginDocumentPayloadReference(row).value().getOrThrow()
            livePolicyStepPayloadMetadata(tx,payload,allocate,guard)
            journalStreamCheck({=>verifyContent(payload)});journalStreamCheck(guard)
            livePolicyStepPayloadMetadata(tx,payload,allocate,guard)}
        consume(encoded)
        journalStreamCheck(guard)
        requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,plan,allocate,guard,progress:progress)
        requirePluginLivePolicyInputPayload(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
        let after=readPluginLivePolicyReceiptPrefix(tx,parent,run,root.callId(),binding,through,ledger,allocate,guard)
        after.close()
        for(row in descriptor.field("payloads").getOrThrow().items){
            let payload=parsePluginDocumentPayloadReference(row).value().getOrThrow()
            livePolicyStepPayloadMetadata(tx,payload,allocate,guard)
            journalStreamCheck({=>verifyContent(payload)});journalStreamCheck(guard)
            livePolicyStepPayloadMetadata(tx,payload,allocate,guard)}
    }finally{owner.close()}
}

// Caller owns the original Artifact lock -> SQL transaction and throws on
// failure. Result.Err is never mistaken for SQLite rollback. Repeated exact
// retention is idempotent data reuse after the full current Source recheck.
public func retainPluginLivePolicyStepData(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,guard:()->Result<Unit>,streamedSource!:Bool=false):Unit{
    withLivePolicyStepEvidence(tx,root,parent,run,thread,epoch,plan,descriptor,allocate,verifyContent,guard,{encoded=>
        let rows=tx.query("SELECT 1 FROM audit_events WHERE operation_id=? AND run_id=? "+
            "AND kind='plugin_live_policy_step_data_v1' AND payload=? LIMIT 2",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(encoded)])
        if(rows.size>1){throw IllegalStateException("live step exact pin is repeated")}
        if(rows.isEmpty()){
            tx.execute("INSERT INTO audit_events(thread_id,run_id,operation_id,kind,payload,created_at_millis) "+
                "VALUES (?,?,?,'plugin_live_policy_step_data_v1',?,?)",
                [SqlParameter.Text(thread.value),SqlParameter.Text(run.value),SqlParameter.Text(parent.value),
                 SqlParameter.Text(encoded),SqlParameter.Int64Value(agentUtcMillis())])}
        livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT count(*) FROM audit_events WHERE operation_id=? AND run_id=? "+
            "AND thread_id=? AND kind='plugin_live_policy_step_data_v1' AND payload=?)=1",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Text(encoded)],
            "live step pin changed its actual parent/run/thread/data")
    },streamedSource:streamedSource)
}

// Reuse repeats the exact same current Source/causal checks and both complete
// fixed-FD verifications. Finding a GC pin alone grants no readable data.
public func requirePluginLivePolicyStepData(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,descriptor:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,verifyContent:(PluginDocumentPayloadReference)->Result<Unit>,guard:()->Result<Unit>,streamedSource!:Bool=false):Unit{
    withLivePolicyStepEvidence(tx,root,parent,run,thread,epoch,plan,descriptor,allocate,verifyContent,guard,{encoded=>
        livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT count(*) FROM audit_events WHERE operation_id=? AND run_id=? "+
            "AND thread_id=? AND kind='plugin_live_policy_step_data_v1' AND payload=?)=1",
            [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Text(encoded)],
            "live step reuse lost its exact actual parent/run/thread/data pin")
    },streamedSource:streamedSource)
}
