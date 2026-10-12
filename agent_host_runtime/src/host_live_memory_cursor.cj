package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import stdx.crypto.digest.SHA256

// Trusted actual Artifact/Session assembly only. Exactly one fixed member FD
// remains on the SAME Session, adopted before open. Every full member reaches
// EOF/hash and checked close before another is opened. A failed close stays
// on both actual owners and retains its payment; it cannot authorize compute.
class HostLivePolicyProposalCursor306 <: PluginLivePolicyProposalCursor {
    private var members:?Array<PluginDocumentPayloadReference>
    private var open:? (PluginDocumentPayloadReference)->Result<HostVerifiedArtifactInput>
    private var acknowledge:? (HostVerifiedArtifactInput)->Result<Unit>
    private var current:? ()->Result<Unit>
    private let owner:LogicalJsonOwnerReservation
    private var reader:?HostVerifiedArtifactInput=None<HostVerifiedArtifactInput>
    private var ordinal:Int64=0
    private var offset:Int64=0
    private var hash=SHA256()
    private var done=false
    private var closed=false
    init(members:Array<PluginDocumentPayloadReference>,open:(PluginDocumentPayloadReference)->Result<HostVerifiedArtifactInput>,
        acknowledge:(HostVerifiedArtifactInput)->Result<Unit>,current:()->Result<Unit>,owner:LogicalJsonOwnerReservation){
        if(members.isEmpty() || members.size>Int64.Max/256){throw IllegalArgumentException("actual proposal cursor metadata accounting overflow")}
        this.owner=owner;owner.ensureRetainedPeak(2097152+members.size*256)
        this.members=Some(members);this.open=Some(open);this.acknowledge=Some(acknowledge);this.current=Some(current)
    }
    public func next():Result<Array<Byte>>{
        try{
            if(closed){return hostPluginResourceError("plugin.live_proposal_cursor_closed","actual proposal cursor is closed")}
            if(done){return Result.Ok([])}
            while(ordinal<members.getOrThrow().size){
                let expected=members.getOrThrow()[ordinal]
                match(current.getOrThrow()()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                if(reader.isNone()){
                    reader=Some(match(open.getOrThrow()(expected)){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value})
                    offset=0;hash=SHA256()
                }
                let buffer=Array<Byte>(65536,repeat:0)
                let count=match(reader.getOrThrow().read(buffer)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                if(count>expected.bytes-offset){return hostPluginResourceError("plugin.live_proposal_member_changed","actual member exceeded its complete extent")}
                if(count>0){
                    let raw=buffer[..count];hash.write(raw);offset+=count
                    match(current.getOrThrow()()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    return Result.Ok(raw)
                }
                if(offset!=expected.bytes || hostArtifactHex(hash.finish())!=expected.digest){
                    return hostPluginResourceError("plugin.live_proposal_member_changed","actual member did not finish its complete EOF/hash")}
                // Close is a checked physical acknowledgement on this exact
                // Session FD. It occurs before any next member can be opened.
                match(acknowledge.getOrThrow()(reader.getOrThrow())){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>reader=None<HostVerifiedArtifactInput>}
                ordinal++
            }
            done=true;Result.Ok([])
        }catch(error:HostArtifactOperationFailure){Result.Err(error.failure)}
        catch(_:Exception){hostPluginResourceError("plugin.live_proposal_member_changed","actual proposal fixed cursor could not finish")}
    }
    public func finish():Result<Unit>{
        if(closed || !done || reader.isSome() || ordinal!=members.getOrThrow().size){
            return hostPluginResourceError("plugin.live_proposal_cursor_incomplete","all actual member EOF/hash/close acknowledgements are required")}
        current.getOrThrow()()
    }
    public func close():Result<Unit>{
        if(closed){return Result.Ok(())}
        match(reader){case Some(file)=>match(acknowledge.getOrThrow()(file)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>reader=None<HostVerifiedArtifactInput>};case None=>()}
        members=None<Array<PluginDocumentPayloadReference>>;open=None<(PluginDocumentPayloadReference)->Result<HostVerifiedArtifactInput>>
        acknowledge=None<(HostVerifiedArtifactInput)->Result<Unit>>;current=None<()->Result<Unit>>
        closed=true;owner.close();Result.Ok(())
    }
    func isClosed306():Bool{closed}
    // Called ONLY by the original same Session collector after its actual
    // input FD and writers have physically ACKed. Cancellation is cleanup;
    // this function grants neither full EOF nor a known effect settlement.
    func retireAfterSessionPhysicalCleanup306():Unit{
        reader=None<HostVerifiedArtifactInput>;members=None<Array<PluginDocumentPayloadReference>>
        open=None<(PluginDocumentPayloadReference)->Result<HostVerifiedArtifactInput>>
        acknowledge=None<(HostVerifiedArtifactInput)->Result<Unit>>;current=None<()->Result<Unit>>
        if(!closed){closed=true;owner.close()}
    }
}

class HostLivePolicyJournalCommitter306 <: PluginDocumentPayloadCommitter {
    private let actual:HostDocumentDataSession
    private let open:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<HostVerifiedArtifactInput>
    init(actual:HostDocumentDataSession,open:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<HostVerifiedArtifactInput>){
        this.actual=actual;this.open=open}
    public func commit(proof:PluginDocumentPayloadCommitProof):Result<Unit>{
        match(proof as SqlitePluginLiveRowJournalCommitProof304){
            case None=>hostPluginResourceError("plugin.live_journal_commit_proof_required","the actual Store private live proof is required")
            case Some(value)=>actual.commitLivePolicyJournal306(value,open)
        }
    }
}

// Explicit native-abort committer. Only the actual Store private proof is
// accepted; original committer/factory selection above remain unchanged.
class HostLivePolicyNativeAbortJournalCommitter325 <: PluginDocumentPayloadCommitter {
    private let actual:HostDocumentDataSession
    private let open:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<HostVerifiedArtifactInput>
    init(actual:HostDocumentDataSession,open:(PluginDocumentPayloadReference,()->Result<Unit>)->Result<HostVerifiedArtifactInput>){
        this.actual=actual;this.open=open}
    public func commit(proof:PluginDocumentPayloadCommitProof):Result<Unit>{
        match(proof as SqlitePluginLiveRowJournalCommitProof304){
            case None=>hostPluginResourceError("plugin.live_journal_commit_proof_required","the actual Store private live proof is required")
            case Some(value)=>actual.commitLivePolicyJournalNativeAbort325(value,open)
        }
    }
}
