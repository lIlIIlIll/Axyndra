package agent_store

import agent_domain.*
import agent_runtime.*
import yjson.*
import yjson_support.*

// One complete data-only Blob from the actual CURRENT step. This is not a
// history grant, earlier fence, Root, preparation, approval or completion.
// The fixed-file consumer is trusted assembly, not a Native callback.
public func consumePluginLivePolicyCurrentStepPayload(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,plan:NormalizedOperationPlan,currentLedger:AgentValue,
    payload:PluginDocumentPayloadReference,allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<(Int64,String)>):Result<Unit>{
    try{
        journalStreamCheck(guard)
        let through=journalStreamInteger(currentLedger.field("through_sequence").getOrThrow().asNumberText())
        if(!isPluginLivePolicyParentPlan(plan) || payload.bytes<1 ||
            !pluginLivePolicyLedgerReferenceValid(currentLedger,parent.value,through)){
            throw IllegalStateException("current live step requires its complete actual parent and ledger")}
        let owner=allocate(65536)
        try{
            let descriptor=objectValue([ValueField("schema",textValue("axyndra.plugin-live-policy-step-data/v1")),
                ValueField("parent_operation_id",textValue(parent.value)),ValueField("parent_binding_digest",textValue(plan.bindingDigest)),
                ValueField("prior_receipts",currentLedger),ValueField("payloads",listValue([payload.value()]))])
            let extent=livePolicyStoredExtent(descriptor);owner.ensureRetainedPeak(contextReadMetadataPeak(extent.bytes,extent.nodes))
            let encoded=encodeStoredValue(descriptor)
            if(encoded.size!=extent.bytes){throw IllegalStateException("current live step changed its paid pin encoding")}
            let requireCurrent:()->Unit={=>
                requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,plan,allocate,guard,
                    progress:Some(LivePolicyReadProgress(through,currentLedger,None<OperationId>)))
                requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),plan.toolName,plan.canonicalArguments,allocate,guard)
                // Exact actual data pin is proved BEFORE opening or reading
                // any Blob. Its public reference itself authorizes nothing.
                livePolicyRequireOne(tx,"SELECT 1 WHERE (SELECT COUNT(*) FROM audit_events WHERE operation_id=? AND run_id=? "+
                    "AND thread_id=? AND kind='plugin_live_policy_step_data_v1' AND payload=?)=1",
                    [SqlParameter.Text(parent.value),SqlParameter.Text(run.value),SqlParameter.Text(thread.value),SqlParameter.Text(encoded)],
                    "current live step has no sole actual same-parent GC data pin")
                livePolicyStepPayloadMetadata(tx,payload,allocate,guard)}
            requireCurrent();journalStreamCheck(guard)
            let copied=match(consume(payload,guard)){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
            if(copied[0]!=payload.bytes || copied[1]!=payload.digest){throw IllegalStateException("current step failed full fixed-FD EOF/hash/ACK")}
            // The consumer physically closed its real FD before this second
            // complete same-TX Source/current/prefix/pin and metadata check.
            requireCurrent();journalStreamCheck(guard);Result<Unit>.Ok(())
        }finally{owner.close()}
    }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
    catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_step_input_stale",
        "current actual step, caller, GC pin or full fixed-file bytes changed"))}
}
