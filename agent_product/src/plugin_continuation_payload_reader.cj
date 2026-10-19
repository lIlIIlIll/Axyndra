package agent_product

import agent_domain.*
import agent_extension_runtime.reserveNativeDocumentPayload
import agent_store.*
import persistence_runtime.*
import std.convert.*
import std.sync.*

// A restrictive facts check, not a read/admission capability. Production
// reaches it only after the actual live owner checked preparing/source/token.
func continuationPayloadFactsCurrent(transaction:SqliteTransaction,facts:ContinuationAllowanceRepository,
    address:ContinuationAllowanceAddress,eventId:Int64,generation:Int64,sourceDigest:String):Result<Unit> {
    let actual=match(facts.readFacts(transaction,address)){
        case Result.Ok(Some(value))=>value;case Result.Err(error)=>return Result.Err(error)
        case Result.Ok(None)=>return commandControlError("continuation.control_missing")}
    if(!actual.hasRemainingTokens() || actual.eventId!=eventId || actual.generation!=generation || actual.controlSourceDigest!=sourceDigest){
        return commandControlError("continuation.control_changed_or_exhausted")}
    Result.Ok(())
}

// Host-private, non-serializable read scope. An actual retained user owner
// constructs it only after the complete historical chain was verified. The
// public Store metadata DTO and an artifact reference cannot construct that
// owner. This adapter owns no file: the existing data session owns its input,
// fixed buffer and failed-close cleanup until the real consumer acknowledges.
class ProductContinuationPayloadReader {
    private let owner: ProductContinuationOwner
    private let database: SqliteDatabase
    private let address: ContinuationAllowanceAddress
    private let restriction: ProductContinuationRestriction
    private let original: CompletedPluginDocumentObservation
    private let chain: Array<CompletedPluginDocumentObservation>
    private let cancellation: CancellationToken
    private let window: ProductContinuationPreparationDeadline
    private let closed = AtomicBool(false)
    private let ownerDigest: String
    let sourceDigest: String
    init(owner: ProductContinuationOwner, database: SqliteDatabase, address: ContinuationAllowanceAddress,
        restriction: ProductContinuationRestriction, original: CompletedPluginDocumentObservation,
        chain: Array<CompletedPluginDocumentObservation>, ownerDigest: String,
        cancellation: CancellationToken, window: ProductContinuationPreparationDeadline) {
        if (original.payload.isNone() || chain.isEmpty() || chain.size > 256) {
            throw IllegalArgumentException("completed document payload scope required") }
        for (value in chain) {
            if (value.payload.isNone()) { throw IllegalArgumentException("inline and referenced history cannot be mixed") }
        }
        this.owner=owner;this.database=database;this.address=address;this.restriction=restriction
        this.original=original;this.chain=chain.clone();this.ownerDigest=ownerDigest
        this.cancellation=cancellation;this.window=window
        sourceDigest=modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("kind",textValue("host_user_continuation_document_history/v1")),
            ValueField("owner_digest",textValue(ownerDigest)),ValueField("thread_id",textValue(address.threadId.value)),
            ValueField("lane_id",textValue(address.laneId.value)),ValueField("namespace",textValue(address.namespace)),
            ValueField("key",textValue(address.documentKey)),ValueField("original",original.descriptor()),
            ValueField("chain",listValue(Array<AgentValue>(chain.size,{index=>chain[index].descriptor()})))])))
    }
    func close(): Unit { closed.store(true) }
    // Safe inside a supplied Store transaction: no Host/package/Runtime lock
    // is acquired here, and this check never renews the original MonoTime.
    private func currentData(): Unit {
        window.check()
        if (closed.load() || cancellation.isCancelled()) {
            throw IllegalStateException("completed document read scope has closed") }
    }
    func local(): Result<Unit> {
        try {currentData();Result.Ok(())} catch(_:Exception){commandControlError("continuation.payload_read_closed")}
    }
    func current(): Result<Unit> {
        try { currentData() } catch (_: Exception) { return commandControlError("continuation.payload_read_closed") }
        match(owner.validatePayloadReadSource(ownerDigest,original.operationId,original.receiptId)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
        // Operator file bytes are still compared in full on each transfer
        // check. Only the immutable package rehash is deferred to the actual
        // pure compute/consumption boundary; a stat witness is insufficient.
        match(restriction.configuration.validateTransferWitness()) { case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
        // Other actual control scopes can change the canonical allowance
        // without invoking this Application owner's volatile revoke(). Check
        // its bounded latest fact and current Run statistics before forwarding
        // each chunk, outside every Host/Store callback and owner mutex.
        let facts=try {database.readTransaction<Result<Unit>>({tx=>owner.validatePayloadReadFacts(tx,ownerDigest)})}
            catch(_:Exception){return commandControlError("continuation.payload_control_unavailable")}
        match(facts){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        try { currentData();Result.Ok(()) } catch (_: Exception) { commandControlError("continuation.payload_read_closed") }
    }
    func validate(): Result<Unit> {
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(owner.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(restriction.current(address.documentKey)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        current()
    }
    private func authorize(observed: CompletedPluginDocumentObservation): Result<Unit> {
        match(validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let reading=try { ContinuationDocumentReadScope({bytes=>reserveNativeDocumentPayload(bytes)},current:{=>currentData()}) }
            catch(_:Exception){return commandControlError("continuation.observation_capacity")}
        try {
            let result=database.readTransaction<Result<Unit>>({tx=>
                match(owner.validatePayloadReadFacts(tx,ownerDigest)) {case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let expected=ContinuationDocumentVersion(address.threadId,address.laneId,address.namespace,
                    address.documentKey,observed.revision,observed.payload.getOrThrow())
                let actual=match(observeCompletedPluginDocumentPayload(tx,expected,restriction.parentTool,
                    restriction.command.digest,restriction.command.generation.toString(),restriction.configuration.digest,
                    reading,operationId:Some(observed.operationId))) {
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
                if(canonicalAgentValue(actual.descriptor())!=canonicalAgentValue(observed.descriptor()) ||
                    canonicalAgentValue(actual.payload.getOrThrow().value())!=canonicalAgentValue(observed.payload.getOrThrow().value())) {
                    return commandControlError("continuation.payload_history_changed") }
                currentData();owner.validatePayloadReadFacts(tx,ownerDigest)
            })
            match(result){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            validate()
        } catch(_:Exception) {commandControlError("continuation.payload_history_changed")}
        finally {reading.close()}
    }
    // The caller selects a frozen position, never an arbitrary artifact/path.
    // The session calls authorize before retaining this exact ref and owns all
    // physical input cleanup; every chunk still passes current().
    func uploadApproved(session: ProductDocumentDataSession,
        consume: (Int64,Array<Byte>)->Result<Unit>): Result<Unit> {
        upload(session,original,consume)
    }
    func uploadCurrent(session: ProductDocumentDataSession,index:Int64,
        consume: (Int64,Array<Byte>)->Result<Unit>): Result<Unit> {
        if(index<0 || index>=chain.size){return commandControlError("continuation.payload_history_index")}
        upload(session,chain[index],consume)
    }
    private func upload(session:ProductDocumentDataSession,observed:CompletedPluginDocumentObservation,
        consume:(Int64,Array<Byte>)->Result<Unit>):Result<Unit> {
        session.uploadPrepared(observed.payload.getOrThrow(),{=>authorize(observed)},{=>current()},consume)
    }
}
