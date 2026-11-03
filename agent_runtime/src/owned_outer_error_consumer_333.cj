package agent_runtime

import agent_domain.*
import std.sync.*
import std.collection.*

// An opt-in data borrower, never Source, Receipt or retry authority. Each
// invocation obtains a NEW actual child invoice from the original Session
// bank. ensureAdditional is a sum for that invocation, not a new pool or a
// permission to forget copies retained by earlier invocations.
public interface PluginLivePolicyPaidOuterErrorSource333 <: PluginLivePolicyOuterErrorDataOwner331 {
    func withPaidError333(consume:(AgentError,(Int64)->Result<Unit>)->Result<Unit>):Result<Unit>
}

// These interfaces deliberately do not adapt a naked callback by treating
// its return as retirement. A repository/observer must pay BEFORE encoding,
// forwarding, queueing or copying, using the loan on each actual borrow.
public interface OwnedOuterErrorRunRepository333 {
    func saveOwnedOuterError333(value:OwnedOuterErrorFailure333):Result<Unit>
    func appendOwnedOuterError333(value:OwnedOuterErrorFailure333):Result<Unit>
}
public interface OwnedOuterErrorEventSink333 {
    func emitOwnedOuterError333(value:OwnedOuterErrorFailure333):Result<Unit>
}

// Pending exposes no legacy raw-error getter or payment closer. A missing
// paid subtype stays closed; its physical/data owner is still retained.
public class OwnedOuterErrorPending333 {
    private let source:PluginLivePolicyOuterErrorDataOwner331
    public init(source:PluginLivePolicyOuterErrorDataOwner331){
        // A returned Pending wrapper is itself an independent caller alias.
        // Pay before retaining it; no missing subtype or exhausted pool can
        // silently publish another uncharged reference to the original owner.
        let actual=match(source as PluginLivePolicyPaidOuterErrorSource333){
            case Some(value)=>value
            case None=>throw IllegalStateException("pending outer error needs same-bank funding")}
        match(actual.withPaidError333({_,fund=>fund(4096)})){
            case Result.Err(_)=>throw IllegalStateException("pending outer error alias invoice unavailable")
            case Result.Ok(_)=>()}
        this.source=source
    }
    public func withPaidError(consume:(AgentError,(Int64)->Result<Unit>)->Result<Unit>):Result<Unit>{
        match(source as PluginLivePolicyPaidOuterErrorSource333){
            case Some(actual)=>actual.withPaidError333(consume)
            case None=>ownedOuterErrorConsumerError333("run.owned_outer_error_paid_consumer_required")}
    }
    public func closeAfterConsumerRetirement():Result<Unit>{
        ownedOuterErrorConsumerError333("run.owned_outer_error_aliases_pending")}
    public func isConsumerRetired():Bool{false}
}

public class OwnedOuterErrorFailure333 {
    private let source:PluginLivePolicyPaidOuterErrorSource333
    private let snapshot:RunSnapshot
    private let event:EventMeta
    private let metadataPeak:Int64
    private let lock=Mutex()
    private let supplementalErrors=ArrayList<AgentError>()
    // Constructor is data-only. Core provides its actual counters/identity;
    // no canonical Run may be created from this object by a consumer.
    public init(source:PluginLivePolicyPaidOuterErrorSource333,snapshot:RunSnapshot,event:EventMeta){
        if(snapshot.error.isSome() || snapshot.summary!="" || snapshot.structuredOutput.isSome() ||
            snapshot.status!=RunState.RecoveryRequired || snapshot.runId.value!=event.runId.value){
            throw IllegalArgumentException("owned failure requires actual empty metadata and the same Run")}
        let peak=ownedOuterErrorMetadataPeak333(snapshot,event)
        // Payment precedes this object's retention of the metadata. An
        // unpublished constructor failure cannot release earlier consumers.
        match(source.withPaidError333({_,fund=>fund(peak)})){
            case Result.Err(_)=>throw IllegalStateException("owned outer error metadata payment unavailable")
            case Result.Ok(_)=>()}
        this.source=source;this.snapshot=snapshot;this.event=event;metadataPeak=peak
    }
    public func matchesRun(run:RunId):Bool{snapshot.runId.value==run.value}
    public func retainCallerAlias333():Result<Unit>{
        // A repeated typed return may outlive the original caller, so it has
        // its own permanent invoice rather than borrowing the first one.
        source.withPaidError333({_,fund=>fund(4096)})
    }
    public func withError(consume:(AgentError,(Int64)->Result<Unit>)->Result<Unit>):Result<Unit>{
        source.withPaidError333({error,fund=>
            match(fund(metadataPeak)){case Result.Err(value)=>Result.Err(value);case Result.Ok(_)=>consume(error,{extra=>
                fund(ownedOuterErrorAdd333(metadataPeak,extra))})}})
    }
    public func withSnapshot(consume:(RunSnapshot,(Int64)->Result<Unit>)->Result<Unit>):Result<Unit>{
        withError({error,fund=>
            let actual=RunSnapshot(snapshot.runId,snapshot.sessionId,snapshot.status,
                sequence:snapshot.sequence,summary:error.message,error:Some(error),
                modelRequests:snapshot.modelRequests,usage:snapshot.usage,
                lastInputTokens:snapshot.lastInputTokens,lastOutputTokens:snapshot.lastOutputTokens,
                lastRequestDurationMillis:snapshot.lastRequestDurationMillis,
                toolCalls:snapshot.toolCalls,turns:snapshot.turns,kind:snapshot.kind)
            consume(actual,fund)})
    }
    public func withDiagnostic(consume:(AgentEvent,(Int64)->Result<Unit>)->Result<Unit>):Result<Unit>{
        withError({error,fund=>
            // AgentEvent constructs the old full Diagnostic detail DOM.
            // Its arrays/nodes are paid before construction, including every
            // ErrorField occurrence. The complete AgentError is not replaced.
            match(fund(ownedOuterErrorAdd333(32768,ownedOuterErrorMultiply333(error.fields.size,4096)))){
                case Result.Err(value)=>Result.Err(value)
                case Result.Ok(_)=>consume(AgentEvent(event,AgentEventPayload.Diagnostic(error)),{extra=>
                    fund(ownedOuterErrorAdd333(ownedOuterErrorAdd333(32768,
                        ownedOuterErrorMultiply333(error.fields.size,4096)),extra))})}})
    }
    public func withDescription(consume:(String)->Result<Unit>):Result<Unit>{
        withError({error,fund=>
            var bytes=ownedOuterErrorAdd333(error.message.size,ownedOuterErrorAdd333(error.code.size,3))
            for(field in error.fields){bytes=ownedOuterErrorAdd333(bytes,
                ownedOuterErrorAdd333(3,ownedOuterErrorAdd333(field.name.size,field.value.size)))}
            // Covers every growing concatenation and its final escaping
            // String. Each call has an independent, permanently retained loan.
            match(fund(ownedOuterErrorAdd333(32768,ownedOuterErrorMultiply333(bytes,4)))){
                case Result.Err(value)=>Result.Err(value);case Result.Ok(_)=>consume(error.describe())}})
    }
    public func retainSupplement(error:AgentError):Result<Unit>{
        // Preserve an independent scheduler/storage/cleanup error in full;
        // do not concatenate describe() into an unaccounted merged String.
        source.withPaidError333({_,fund=>
            match(fund(ownedOuterErrorRetainedPeak333(error))){
                case Result.Err(value)=>Result.Err(value)
                case Result.Ok(_)=>lock.lock();try{supplementalErrors.add(ownedOuterErrorCopy333(error));Result.Ok(())}
                    finally{lock.unlock()}}})
    }
    public func withSupplement(index:Int64,consume:(AgentError,(Int64)->Result<Unit>)->Result<Unit>):Result<Unit>{
        lock.lock()
        let selected:AgentError=try{
            if(index<0 || index>=supplementalErrors.size){
                return ownedOuterErrorConsumerError333("run.owned_outer_error_supplement_missing")}
            supplementalErrors[index]
        }finally{lock.unlock()}
        source.withPaidError333({_,fund=>
            let base=ownedOuterErrorRetainedPeak333(selected)
            match(fund(base)){case Result.Err(value)=>Result.Err(value)
                case Result.Ok(_)=>consume(ownedOuterErrorCopy333(selected),{extra=>fund(ownedOuterErrorAdd333(base,extra))})}})
    }
    public func closeAfterConsumerRetirement():Result<Unit>{
        // RunRepository.find/events, public String/error fields and arbitrary
        // callers have no true alias-retirement contract yet. No fake ACK.
        ownedOuterErrorConsumerError333("run.owned_outer_error_aliases_pending")
    }
    public func isConsumerRetired():Bool{false}
}

public func ownedOuterErrorAdd333(left:Int64,right:Int64):Int64{
    if(left<0 || right<0 || right>Int64.Max-left){throw IllegalStateException("outer error invoice overflow")}
    left+right
}
public func ownedOuterErrorMultiply333(bytes:Int64,count:Int64):Int64{
    if(bytes<0 || count<0 || (count>0 && bytes>Int64.Max/count)){
        throw IllegalStateException("outer error invoice overflow")};bytes*count
}
// Pure copy only. Its caller must already hold a same-bank occurrence invoice.
// Immutable scalar strings/typed attachments remain fully represented; each
// mutable fields array is independent from every retained/borrowed view.
public func ownedOuterErrorCopy333(error:AgentError):AgentError{
    AgentError(error.kind,error.code,error.message,retryable:error.retryable,
        fallbackAllowed:error.fallbackAllowed,
        fields:Array<ErrorField>(error.fields.size,{i=>ErrorField(error.fields[i].name,error.fields[i].value)}),
        attemptFailure:error.attemptFailure,observation:error.observation)
}
public func ownedOuterErrorScalarBytes333(error:AgentError):Int64{
    var bytes=ownedOuterErrorAdd333(error.code.size,error.message.size)
    for(field in error.fields){bytes=ownedOuterErrorAdd333(bytes,
        ownedOuterErrorAdd333(field.name.size,field.value.size))};bytes
}
public func ownedOuterErrorRetainedPeak333(error:AgentError):Int64{
    // AttemptFailure contains only typed scalar diagnostics. Observation
    // owns at most its original 64KiB frozen encoding; do not materialize it.
    ownedOuterErrorAdd333(16384,ownedOuterErrorAdd333(
        ownedOuterErrorMultiply333(ownedOuterErrorScalarBytes333(error),4),
        ownedOuterErrorAdd333(ownedOuterErrorMultiply333(error.fields.size,4096),
            if(error.observation.isSome()){131072}else{0})))
}
func ownedOuterErrorMetadataPeak333(snapshot:RunSnapshot,event:EventMeta):Int64{
    let bytes=ownedOuterErrorAdd333(ownedOuterErrorAdd333(snapshot.runId.value.size,snapshot.sessionId.value.size),
        ownedOuterErrorEventMetadataBytes333(event))
    ownedOuterErrorAdd333(32768,ownedOuterErrorMultiply333(bytes,4))
}
public func ownedOuterErrorEventMetadataBytes333(event:EventMeta):Int64{
    var bytes=ownedOuterErrorAdd333(event.runId.value.size,event.traceId.value.size)
    match(event.turnId){case Some(value)=>bytes=ownedOuterErrorAdd333(bytes,value.value.size);case None=>()}
    match(event.requestId){case Some(value)=>bytes=ownedOuterErrorAdd333(bytes,value.value.size);case None=>()}
    match(event.semanticRequestId){case Some(value)=>bytes=ownedOuterErrorAdd333(bytes,value.value.size);case None=>()}
    match(event.attemptId){case Some(value)=>bytes=ownedOuterErrorAdd333(bytes,value.value.size);case None=>()}
    match(event.toolBatchId){case Some(value)=>bytes=ownedOuterErrorAdd333(bytes,value.value.size);case None=>()}
    match(event.toolCallId){case Some(value)=>bytes=ownedOuterErrorAdd333(bytes,value.value.size);case None=>()}
    match(event.operationId){case Some(value)=>bytes=ownedOuterErrorAdd333(bytes,value.value.size);case None=>()}
    bytes
}
public func ownedOuterErrorConsumerError333<T>(code:String):Result<T>{Result.Err(AgentError(
    AgentErrorKind.RecoveryRequired,code,"complete outer error remains in its paid typed owner; actual cleanup is not acknowledged"))}
