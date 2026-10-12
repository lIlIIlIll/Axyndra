package agent_core

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.sync.*
import std.collection.*
import yjson.*
import yjson_support.*

// Run-local continuation memory, not a second fact registry. The original
// source and hook input survive approval; actual read data always comes from
// the canonical Operation port and final Store admission rechecks the links.
interface CoreContextReadOwner {
    func readPreparation(): ToolPreparationRead
    func deny(code: String): Unit
    func complete(context: ToolInvocationContext, fact: ContextReadFact): Result<Unit>
}

class CorePreparationReadInput <: CoreContextReadOwner {
    let parent: CommittedToolCallRef
    private let lock = Mutex()
    private var inputJson: String
    private var rejection: ?String
    private var links: Array<ContextReadFactLink> = []
    private var sequence: ?ToolPreparationReadSequence = None
    private var firstRead: ?ToolPreparationRead = None
    private var retained: Array<ContextReadFact> = []
    private let loadFact: (OperationId,RunId)->Result<ContextReadFact>
    var read: ?ToolPreparationRead = None
    var ready = false

    init(parent: CommittedToolCallRef, input: AgentValue, loadFact:(OperationId,RunId)->Result<ContextReadFact>, rejection!: ?String = None) {
        let encoded = stringifyUnifiedJson(input)
        let _ = parseUnifiedJson(encoded, maxBytes: 8388608)
        this.parent = parent; this.inputJson = encoded; this.rejection = rejection;this.loadFact=loadFact
        this.ready = rejection.isSome()
    }
    func beginRead(value:ToolPreparationRead):Unit{
        lock.lock();try{if(firstRead.isSome()){throw IllegalStateException("initial read already selected")}
            firstRead=Some(value);sequence=value.sequence;read=Some(value)}finally{lock.unlock()}
    }
    func readOrdinal():Int64{lock.lock();try{retained.size}finally{lock.unlock()}}
    public func readPreparation(): ToolPreparationRead {
        let current=read.getOrThrow()
        if(sequence.isNone()){return current}
        ToolPreparationRead(current.ownerNamespace,current.packageDigest,current.configurationDigest,current.request(),
            {context,facts=>current.complete(context,facts)},boundary:Some({context,arguments=>
                match(verifiedFacts(context,current,None)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                current.validateBoundary(context,arguments)}))
    }
    private func verifiedFacts(context:ToolInvocationContext,current:ToolPreparationRead,next:?ContextReadFact):Result<Array<ContextReadFact>>{
        let first=firstRead.getOrThrow()
        if(context.cancellation.isCancelled() || current.ownerNamespace!=first.ownerNamespace ||
            current.packageDigest!=first.packageDigest || current.configurationDigest!=first.configurationDigest){
            return readSequenceError<Array<ContextReadFact>>("context.read_sequence_owner_changed")}
        match(current.validateBoundary(context,current.request())){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock();let old=try{retained.clone()}finally{lock.unlock()}
        let actual=ArrayList<ContextReadFact>()
        for(saved in old){let loaded=match(loadFact(saved.operationId,context.runId)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(canonicalAgentValue(loaded.link().toValue())!=canonicalAgentValue(saved.link().toValue())){
                return readSequenceError<Array<ContextReadFact>>("context.read_sequence_fact_changed")};actual.add(loaded)}
        match(next){case Some(value)=>
            for(saved in actual where saved.operationId.value==value.operationId.value){return readSequenceError<Array<ContextReadFact>>("context.read_sequence_fact_reused")}
            let loaded=match(loadFact(value.operationId,context.runId)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item}
            if(canonicalAgentValue(loaded.link().toValue())!=canonicalAgentValue(value.link().toValue())){
                return readSequenceError<Array<ContextReadFact>>("context.read_sequence_fact_changed")}
            actual.add(loaded);case None=>()}
        for(value in actual){let origin=value.origin
            if(value.runId.value!=context.runId.value || origin.parentKind!="committed" ||
                origin.parentCallItemId!=parent.canonicalItemId.value || origin.parentOperationId!="" ||
                origin.parentDecisionId!=parent.decisionId.value || origin.parentScopedCallId!=parent.scopedToolCallId.value ||
                origin.ownerNamespace!=first.ownerNamespace || origin.packageDigest!=first.packageDigest ||
                origin.configurationDigest!=first.configurationDigest || origin.projectionDigest!=contextReadProjectionDigest(context.contextProjection)){
                return readSequenceError<Array<ContextReadFact>>("context.read_sequence_fact_owner_changed")}}
        Result.Ok(actual.toArray())
    }
    func input(): AgentValue { lock.lock(); try { parseUnifiedJson(inputJson, maxBytes: 8388608) } finally { lock.unlock() } }
    func hookDecision(): CoreToolHookDecision {
        lock.lock(); try {
            match (rejection) { case Some(reason) => CoreToolHookDecision.Deny(reason)
                case None => CoreToolHookDecision.Modify(parseUnifiedJson(inputJson, maxBytes: 8388608)) }
        } finally { lock.unlock() }
    }
    func factLinks(): Array<ContextReadFactLink> { lock.lock(); try { links.clone() } finally { lock.unlock() } }
    public func deny(code: String): Unit {
        lock.lock(); try { rejection = Some("preparation read did not complete: " + code); ready = true }
        finally { lock.unlock() }
    }
    public func complete(context: ToolInvocationContext, fact: ContextReadFact): Result<Unit> {
        if(sequence.isNone()){return completeSingle(context,fact)}
        let current=read.getOrThrow()
        let facts=match(verifiedFacts(context,current,Some(fact))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let selected=sequence.getOrThrow()
        let next=match(selected.advance(context,facts)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(verifiedFacts(context,current,Some(fact))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(next){
            case ToolPreparationReadNext.Read(value)=>
                if(facts.size>=selected.maximumReads || value.ownerNamespace!=firstRead.getOrThrow().ownerNamespace ||
                    value.packageDigest!=firstRead.getOrThrow().packageDigest || value.configurationDigest!=firstRead.getOrThrow().configurationDigest ||
                    value.sequence.isSome()){return readSequenceError<Unit>("context.read_sequence_stage_limit")}
                match(value.validateBoundary(context,value.request())){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                lock.lock();try{retained=facts;links=facts.map{item=>item.link()};read=Some(value);ready=false}finally{lock.unlock()}
            case ToolPreparationReadNext.Ready(value)=>
                if(validateContextReadSequenceInputProjection(value,facts.map{item=>item.link()}).isError()){
                    return readSequenceError<Unit>("context.read_sequence_projection_invalid")}
                let raw=try{stringifyUnifiedJson(value)}catch(_:Exception){return readSequenceError<Unit>("context.read_sequence_projection_invalid")}
                try{let _=parseUnifiedJson(raw,maxBytes:8388608)}catch(_:Exception){return readSequenceError<Unit>("context.read_sequence_projection_invalid")}
                lock.lock();try{retained=facts;links=facts.map{item=>item.link()};inputJson=raw;ready=true}finally{lock.unlock()}
        }
        Result.Ok(())
    }
    private func completeSingle(context: ToolInvocationContext, fact: ContextReadFact): Result<Unit> {
        let value = match (read.getOrThrow().complete(context, [fact])) {
            case Result.Ok(item) => item; case Result.Err(error) => return Result.Err(error) }
        lock.lock(); try {
            inputJson = stringifyUnifiedJson(value); links = [fact.link()]; ready = true; Result.Ok(())
        } finally { lock.unlock() }
    }
}

func readSequenceError<T>(code:String):Result<T>{Result.Err(AgentError(AgentErrorKind.Conflict,code,
    "tool read sequence lost its exact current canonical owner"))}

class CorePendingContextRead {
    let owner: CoreContextReadOwner
    let prepared: PreparedToolInvocation
    let epoch: Int64
    private let lock = Mutex()
    private var claimed = false
    init(owner: CoreContextReadOwner, prepared: PreparedToolInvocation, epoch: Int64) {
        this.owner = owner; this.prepared = prepared; this.epoch = epoch
    }
    func claim(): Bool { lock.lock(); try { if (claimed) { false } else { claimed = true; true } } finally { lock.unlock() } }
    // Only the owner of a just-acquired claim may roll back a failed durable
    // phase transition. The pending source, slot and prepared plan remain held.
    func releaseUnstartedClaim(): Unit { lock.lock(); try { claimed = false } finally { lock.unlock() } }
}
