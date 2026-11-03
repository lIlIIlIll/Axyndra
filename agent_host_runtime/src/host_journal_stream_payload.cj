package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_store.*
import agent_extension_runtime.*
import std.sync.*

// An inert owner for one real executing ContextRead. No constructor opens a
// file, reserves a transfer, grants access, or creates a Source. The executor
// retains this owner before read(), and retains failed cleanup for retry.
public class HostJournalStreamPayloadReader <: PluginDocumentPayloadMaterializer {
    private let lock=Mutex()
    private let invoke:(PluginDocumentPayloadMaterializer)->Result<AgentValue>
    private let createWriter:()->Result<HostServiceArtifactWriter>
    private let publish:(SqliteTransaction,HostServiceArtifactWriter)->Result<AgentValue>
    private let guard:()->Result<Unit>
    private var active:?HostServiceArtifactWriter=None
    private var buffer:?LogicalJsonFixedBufferReservation=None
    private var started=false
    private var inRead=false
    private var closed=false
    public init(invoke:(PluginDocumentPayloadMaterializer)->Result<AgentValue>,
        createWriter:()->Result<HostServiceArtifactWriter>,
        publish:(SqliteTransaction,HostServiceArtifactWriter)->Result<AgentValue>,guard:()->Result<Unit>){
        this.invoke=invoke;this.createWriter=createWriter;this.publish=publish;this.guard=guard}
    private func cleanup():Result<Unit>{
        match(active){case Some(value)=>match(value.close()){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>active=None};case None=>()}
        // A writer/verifier/native close failure keeps both reservations with
        // this same owner. ACK precedes release; no replacement handle exists.
        match(buffer){case Some(value)=>value.close();buffer=None;case None=>()}
        Result<Unit>.Ok(())}
    public func close():Result<Unit>{lock.lock();try{closed=true;cleanup()}finally{lock.unlock()}}
    public func read():Result<AgentValue>{
        lock.lock()
        try{
            if(closed || started){return hostPluginResourceError<AgentValue>(
                "plugin.journal_stream_reader_closed","journal stream reader is one-shot")}
            started=true;inRead=true
            let result=try{invoke(this)}catch(_:Exception){hostPluginResourceError<AgentValue>(
                "plugin.journal_stream_materialize_failed","canonical stream materialization failed")}
                finally{inRead=false}
            match(cleanup()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            result
        }finally{lock.unlock()}}
    public func materialize(value:PluginDocumentPayloadReadProof):Result<AgentValue>{
        if(!inRead || closed || active.isSome() || buffer.isSome()){
            return hostPluginResourceError<AgentValue>("plugin.journal_stream_window_closed","stream materialization window is closed")}
        // This class has a package-private Store constructor and verifies the
        // actual Source, handoff, current mapping and whole fence in its TX.
        let proof=match(value as SqlitePluginDocumentJournalStreamReadProof){case Some(actual)=>actual
            case None=>return hostPluginResourceError<AgentValue>("plugin.journal_stream_proof_invalid","actual Store stream proof required")}
        match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        if(proof.bytes<1){return hostPluginResourceError<AgentValue>("plugin.journal_stream_extent_invalid","complete stream extent is invalid")}
        // Two independent fixed reservations: this transport overlap and the
        // existing writer's prefix/hash/verification workspace. Aggregate file
        // bytes are not a DOM allocation or a worker-selected message bound.
        let charge=try{reserveNativeObservationBuffer()}catch(_:Exception){
            return hostPluginResourceError<AgentValue>("plugin.journal_stream_capacity","shared stream buffer capacity exhausted")}
        buffer=Some(charge)
        let writer=match(createWriter()){case Result.Ok(created)=>created;case Result.Err(error)=>return Result<AgentValue>.Err(error)}
        active=Some(writer)
        match(writer.open()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
        proof.materialize({offset,bytes=>
            match(guard()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            match(writer.appendJournalStreamBytes(offset,bytes,proof.bytes)){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
            guard()
        },{transaction,digest,bytes=>
            match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            if(bytes!=proof.bytes){return hostPluginResourceError<AgentValue>("plugin.journal_stream_extent_changed","actual stream extent changed")}
            match(writer.finish(bytes,digest)){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            let result=publish(transaction,writer)
            match(guard()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            // Release happens after materialize returns, so the actual Store
            // can check registered metadata/full fence and persist observation.
            result
        })
    }
}
