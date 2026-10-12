package agent_store

import agent_domain.*
import agent_runtime.*
import std.sync.*
import yjson.*
import yjson_support.*

// Physical allocation only. No Source/plan/Root is created or recovered.
// Default old source owns no phase here. True can share the exact actual
// caller Session reservation; the original payment includes every retained
// caller byte plus permanent full fact and active observation/scanner DOM.
class LivePolicyBaseMetadataPhase276 {
    let owner:?LogicalJsonOwnerReservation
    let extraRetained:Int64
    private let owned:Bool
    init(streamed:Bool,provided:?LogicalJsonOwnerReservation,retained:Int64,
        allocate:(Int64)->LogicalJsonOwnerReservation){
        if(retained<0 || (provided.isSome() && (!streamed || retained<1)) || retained>Int64.Max-1048576){
            throw IllegalArgumentException("real streamed caller metadata requires its complete positive retained peak")}
        if(streamed){
            let actual=match(provided){case Some(value)=>value;case None=>allocate(65536)}
            this.owner=Some(actual);this.owned=provided.isNone();this.extraRetained=retained+1048576
            try{actual.ensureRetainedPeak(this.extraRetained)}catch(error:Exception){if(this.owned){actual.close()};throw error}
        }else{this.owner=None<LogicalJsonOwnerReservation>;this.owned=false;this.extraRetained=0}
    }
    func close():Unit{if(owned){owner.getOrThrow().close()}}
}

private func livePolicyRequireBaseReplayParent(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,through:Int64,reference:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,streamedSource!:Bool=false):Unit{
    let progress=Some(LivePolicyReadProgress(through,reference,None<OperationId>))
    if(streamedSource){
        requirePluginLivePolicyParentSourceStreamed(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,progress:progress)
        requirePluginLivePolicyInputPayloadStreamed(tx,parent,run,root.itemId(),parentPlan.toolName,parentPlan.canonicalArguments,allocate,guard)
        return
    }
    requirePluginLivePolicyParentSource(tx,root,parent,run,thread,epoch,parentPlan,allocate,guard,progress:progress)
    requirePluginLivePolicyInputPayload(tx,parent,run,root.itemId(),parentPlan.toolName,parentPlan.canonicalArguments,allocate,guard)
}

// New-family base replay only. The original completed ReadFact and its entire
// observed payload stay immutable; its old private fence is related to NOW by
// the complete own known17-field causal chain, never by a Native assertion.
// Construction is private to this Store assembly and returns no raw private
// fence, SQL, file path, Source factory or permission.
public class SqlitePluginLivePolicyBaseJournalInputProof{
    private let tx:SqliteTransaction
    private let root:OperationRootSource
    private let parent:OperationId
    private let run:RunId
    private let thread:ThreadId
    private let epoch:Int64
    private let parentPlan:NormalizedOperationPlan
    private let through:Int64
    private let reference:AgentValue
    private let binding:AgentValue
    private let link:ContextReadFactLink
    private let backend:SqliteOpaqueRowJournalLatestStreamBackend
    private let charge:ContextReadCompletedMetadataPayment
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let guard:()->Result<Unit>
    private let streamedSource:Bool
    private let metadataPhase:LivePolicyBaseMetadataPhase276
    private let configurationCurrent:()->Result<Unit>
    private let lock=Mutex()
    private let inMaterialize=AtomicBool(false)
    private var active=true
    private var verified=false
    init(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,run:RunId,thread:ThreadId,epoch:Int64,
        parentPlan:NormalizedOperationPlan,through:Int64,reference:AgentValue,
        allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,streamedSource!:Bool=false,
        retainedMetadataOwner!:?LogicalJsonOwnerReservation=None,retainedMetadataPeak!:Int64=0){
        this.tx=tx;this.root=root;this.parent=parent;this.run=run;this.thread=thread;this.epoch=epoch
        this.parentPlan=parentPlan;this.through=through;this.reference=reference;this.allocate=allocate;this.guard=guard
        this.streamedSource=streamedSource
        journalStreamCheck(guard)
        if(!isPluginLivePolicyParentPlan(parentPlan) || through<0 ||
            !pluginLivePolicyLedgerReferenceValid(reference,parent.value,through)){
            throw IllegalStateException("strict actual base replay parent and known prefix required")}
        let host=parentPlan.canonicalArguments.field("host_plan").getOrThrow()
        binding=host.field("binding").getOrThrow()
        let links=contextReadFactLinksFromValue(host.field("initial_read_facts").getOrThrow())
        if(links.size!=1){throw IllegalStateException("base replay requires its sole original actual Tool12 read")}
        link=links[0]
        livePolicyRequireBaseReplayParent(tx,root,parent,run,thread,epoch,parentPlan,through,reference,allocate,guard,streamedSource:streamedSource)
        let phase=LivePolicyBaseMetadataPhase276(streamedSource,retainedMetadataOwner,retainedMetadataPeak,allocate)
        metadataPhase=phase
        let payment=try{ContextReadCompletedMetadataPayment(tx,link,allocate,guard,
            phaseOwner:phase.owner,extraRetained:phase.extraRetained)}catch(error:Exception){phase.close();throw error}
        charge=payment
        try{
            let fact=payment.fact();let read=latestJournalInputRequireFact(tx,link,binding,fact.output(),payment)
            if(!pluginDocumentLatestJournalStreamReadAuthority(read) || pluginDocumentContextLatestJournalStreamReadAuthority(read)){
                throw IllegalStateException("base replay cannot use a parentless or old read dialect")}
            let key=httpIntentText(read.canonicalArguments,"key")
            backend=match(tx.documentStorageBackend(httpIntentText(binding,"namespace"),key)){
                case Some(value)=>match(value as SqliteOpaqueRowJournalLatestStreamBackend){case Some(actual)=>actual
                    case None=>throw IllegalStateException("base replay lost its actual latest stream backend")}
                case None=>throw IllegalStateException("base replay has no actual frozen backend")}
            configurationCurrent=backend.capture(read)
            journalStreamCheck(configurationCurrent)
            let _=if(streamedSource){payment.withBorrowedObservation({actualOwner,retained=>
                livePolicyRequireCausalObservationOwned(tx,parent,run,link,read,fact.output(),backend,
                    through,reference,None<OperationId>,allocate,guard,actualOwner,retained)})}else{
                payment.withObservation({=>livePolicyRequireCausalObservation(tx,parent,run,link,read,fact.output(),backend,
                through,reference,None<OperationId>,allocate,guard)})}
        }catch(error:Exception){payment.close();phase.close();throw error}
    }
    private func requireParent():Unit{
        livePolicyRequireBaseReplayParent(tx,root,parent,run,thread,epoch,parentPlan,through,reference,allocate,guard,streamedSource:streamedSource)
    }
    private func current():Result<Unit>{
        if(!inMaterialize.load()){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,
            "plugin.live_base_input_closed","actual causal base cursor left its same materialization scope"))}
        journalStreamCheck(guard);journalStreamCheck(configurationCurrent);charge.current(binding)
    }
    public func materialize(consume:(PluginDocumentLatestJournalStreamReference,()->Result<Unit>)->Result<(Int64,String)>):Result<Unit>{
        lock.lock()
        try{
            if(!active){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,
                "plugin.live_base_input_closed","actual causal base input is one-shot"))}
            active=false;inMaterialize.store(true)
            requireParent();journalStreamCheck({=>current()})
            let fact=charge.fact();let read=latestJournalInputRequireFact(tx,link,binding,fact.output(),charge)
            let stream=if(streamedSource){charge.withBorrowedObservation({actualOwner,retained=>
                livePolicyRequireCausalObservationOwned(tx,parent,run,link,read,fact.output(),backend,
                    through,reference,None<OperationId>,allocate,{=>current()},actualOwner,retained)})}else{
                charge.withObservation({=>livePolicyRequireCausalObservation(tx,parent,run,link,read,fact.output(),backend,
                through,reference,None<OperationId>,allocate,{=>current()})})}
            let copied=match(consume(stream,{=>current()})){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
            // Host returns only after independently counting every fixed-FD
            // byte/hash, actual native EOF ACK AND physical FD close ACK.
            if(copied[0]!=stream.bytes || copied[1]!=stream.digest){
                return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_base_input_content_changed",
                    "actual complete base bytes/hash differ from the original paid read artifact"))}
            journalStreamCheck({=>current()});requireParent()
            let afterFact=charge.fact();let afterRead=latestJournalInputRequireFact(tx,link,binding,afterFact.output(),charge)
            let after=if(streamedSource){charge.withBorrowedObservation({actualOwner,retained=>
                livePolicyRequireCausalObservationOwned(tx,parent,run,link,afterRead,afterFact.output(),backend,
                    through,reference,None<OperationId>,allocate,{=>current()},actualOwner,retained)})}else{
                charge.withObservation({=>livePolicyRequireCausalObservation(tx,parent,run,link,afterRead,afterFact.output(),backend,
                through,reference,None<OperationId>,allocate,{=>current()})})}
            if(after.bytes!=stream.bytes || after.digest!=stream.digest){throw IllegalStateException("causal base artifact changed at complete EOF")}
            journalStreamCheck({=>current()});verified=true;Result<Unit>.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_base_input_stale",
            "actual current Source, base ReadFact or complete own causal chain changed"))}
        finally{inMaterialize.store(false);lock.unlock()}
    }
    // Powerless metadata preflight for Native begin, before input/base FDs.
    // It does not set verifiedResult(), create a Root, or acknowledge a file.
    // The actual one-shot base materialization still requires all full EOF
    // predicates. The trusted Host copies only the original <=16KiB request
    // and public reference into its already paid Session metadata owner.
    public func describe(consume:(AgentValue,PluginDocumentLatestJournalStreamReference)->Unit):Result<Unit>{
        lock.lock();try{
            if(!active){return Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_base_input_closed","actual descriptor scope is one-shot"))}
            active=false;inMaterialize.store(true)
            requireParent();journalStreamCheck({=>current()})
            let fact=charge.fact();let read=latestJournalInputRequireFact(tx,link,binding,fact.output(),charge)
            let stream=if(streamedSource){charge.withBorrowedObservation({actualOwner,retained=>
                livePolicyRequireCausalObservationOwned(tx,parent,run,link,read,fact.output(),backend,
                    through,reference,None<OperationId>,allocate,{=>current()},actualOwner,retained)})}else{
                charge.withObservation({=>livePolicyRequireCausalObservation(tx,parent,run,link,read,fact.output(),backend,
                through,reference,None<OperationId>,allocate,{=>current()})})}
            if(!pluginDocumentLatestJournalStreamReadRequestValid(read.canonicalArguments)){
                throw IllegalStateException("actual descriptor lost its original bounded Tool12 request")}
            consume(read.canonicalArguments,stream)
            journalStreamCheck({=>current()});requireParent()
            let afterFact=charge.fact();let afterRead=latestJournalInputRequireFact(tx,link,binding,afterFact.output(),charge)
            let after=if(streamedSource){charge.withBorrowedObservation({actualOwner,retained=>
                livePolicyRequireCausalObservationOwned(tx,parent,run,link,afterRead,afterFact.output(),backend,
                    through,reference,None<OperationId>,allocate,{=>current()},actualOwner,retained)})}else{
                charge.withObservation({=>livePolicyRequireCausalObservation(tx,parent,run,link,afterRead,afterFact.output(),backend,
                through,reference,None<OperationId>,allocate,{=>current()})})}
            if(after.bytes!=stream.bytes || after.digest!=stream.digest ||
                canonicalAgentValue(afterRead.canonicalArguments)!=canonicalAgentValue(read.canonicalArguments)){
                throw IllegalStateException("actual base descriptor changed during its paid Unit scope")}
            journalStreamCheck({=>current()});Result<Unit>.Ok(())
        }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
        catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_base_descriptor_stale",
            "actual descriptor, full current Source, input pin or own complete known prefix changed"))}
        finally{inMaterialize.store(false);lock.unlock()}
    }

    func verifiedResult():Bool{lock.lock();try{verified}finally{lock.unlock()}}
    func close():Unit{inMaterialize.store(false);lock.lock();try{active=false;charge.close();metadataPhase.close()}finally{lock.unlock()}}
}


// Explicit opt-in, no default old source/fence body is weakened.
public func describePluginLivePolicyBaseJournalInput(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,through:Int64,reference:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    consume:(AgentValue,PluginDocumentLatestJournalStreamReference)->Unit,
    retainedMetadataOwner!:?LogicalJsonOwnerReservation=None,retainedMetadataPeak!:Int64=0):Result<Unit>{
    try{
        let proof=SqlitePluginLivePolicyBaseJournalInputProof(tx,root,parent,run,thread,epoch,parentPlan,through,reference,
            allocate,guard,streamedSource:true,retainedMetadataOwner:retainedMetadataOwner,retainedMetadataPeak:retainedMetadataPeak)
        try{proof.describe(consume)}finally{proof.close()}
    }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
    catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_base_descriptor_stale","actual base descriptor cannot be retained"))}
}
public func consumePluginLivePolicyBaseJournalInputStreamed(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,through:Int64,reference:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    materialize:(SqlitePluginLivePolicyBaseJournalInputProof)->Result<Unit>,
    retainedMetadataOwner!:?LogicalJsonOwnerReservation=None,retainedMetadataPeak!:Int64=0):Result<Unit>{
    try{
        let proof=SqlitePluginLivePolicyBaseJournalInputProof(tx,root,parent,run,thread,epoch,parentPlan,through,reference,
            allocate,guard,streamedSource:true,retainedMetadataOwner:retainedMetadataOwner,retainedMetadataPeak:retainedMetadataPeak)
        try{
            let result=materialize(proof)
            if(result.isOk() && !proof.verifiedResult()){throw IllegalStateException("actual streamed base did not reach full EOF and ACK")}
            result
        }finally{proof.close()}
    }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
    catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_base_input_stale","actual streamed base cannot be consumed"))}
}

// The trusted callback is confined to this actual TX/proof. Returning Unit
// without materializing the original full frame/EOF cannot authorize data.
public func consumePluginLivePolicyBaseJournalInput(tx:SqliteTransaction,root:OperationRootSource,parent:OperationId,
    run:RunId,thread:ThreadId,epoch:Int64,parentPlan:NormalizedOperationPlan,through:Int64,reference:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,
    materialize:(SqlitePluginLivePolicyBaseJournalInputProof)->Result<Unit>):Result<Unit>{
    try{
        let proof=SqlitePluginLivePolicyBaseJournalInputProof(tx,root,parent,run,thread,epoch,parentPlan,through,reference,allocate,guard)
        try{
            let result=materialize(proof)
            if(result.isOk() && !proof.verifiedResult()){throw IllegalStateException("actual causal base proof did not reach complete EOF and ACK")}
            result
        }finally{proof.close()}
    }catch(error:PluginDocumentGuardFailure){Result<Unit>.Err(error.failure)}
    catch(_:Exception){Result<Unit>.Err(AgentError(AgentErrorKind.Conflict,"plugin.live_base_input_stale",
        "base data cannot consume another actual Parent, ReadFact, current scope or own receipt chain"))}
}
