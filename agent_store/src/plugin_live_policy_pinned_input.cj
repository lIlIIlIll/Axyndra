package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// A new-family data callback ONLY. All Source/current/prefix checks are
// performed inside this actual same read transaction before and after the
// fixed file reaches full EOF/hash/FD ACK. No initial private fence is reused
// after this parent's own append, and no public Source or path is returned.
public func consumePluginLivePolicyPinnedInput(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,through:Int64,ledger:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<(Int64,String)>):Result<Unit>{
    try{
        if(!isPluginLivePolicyParentPlan(parentPlan) || through<0 ||
            !pluginLivePolicyLedgerReferenceValid(ledger,parent.value,through)){
            throw IllegalStateException("pinned input requires its actual strict parent and complete known prefix")}
        let requireFull:()->Unit={=>
            requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,
                progress:Some(LivePolicyReadProgress(through,ledger,None<OperationId>)))
            requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),parentPlan.toolName,
                parentPlan.canonicalArguments,allocate,guard)}
        journalStreamCheck(guard);requireFull()
        let host=parentPlan.canonicalArguments.field("host_plan").getOrThrow()
        let binding=host.field("binding").getOrThrow()
        let links=contextReadFactLinksFromValue(host.field("initial_read_facts").getOrThrow())
        if(links.size!=1){throw IllegalStateException("pinned input has no sole original actual Tool12 fact")}
        let payload=parsePluginDocumentPayloadReference(host.field("input_payload").getOrThrow()).value().getOrThrow()
        let payment=ContextReadCompletedMetadataPayment(tx,links[0],allocate,guard)
        try{
            let active=AtomicBool(true)
            let current:()->Result<Unit>={=>
                if(!active.load()){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,
                    "plugin.live_input_cursor_closed","same actual pinned input cursor is no longer live"))}
                journalStreamCheck(guard);payment.current(binding)}
            let copied=try{match(consume(payload,current)){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}}
                finally{active.store(false)}
            if(copied[0]!=payload.bytes || copied[1]!=payload.digest){
                throw IllegalStateException("actual original pinned input changed at complete file EOF")}
            journalStreamCheck(guard)
        }finally{payment.close()}
        // No full metadata/DOM owner survives into this final Source phase.
        requireFull();journalStreamCheck(guard);Result<Unit>.Ok(())
    }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
    catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_input_stale",
        "actual input pin, original caller, complete known prefix or current scope changed"))}
}
