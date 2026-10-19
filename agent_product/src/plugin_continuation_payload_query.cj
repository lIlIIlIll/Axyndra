package agent_product

import yjson.*
import yjson_support.*

import agent_domain.*
import agent_store.*
import std.collection.*
import std.convert.*

// Transport adapter only. The installed pure provider alone evaluates the
// existing predicate; this Host never interprets Goal fields or accepts new
// control/prompt/budget values. The shared data scope owns the actual worker.
class ProductContinuationPayloadQuery {
    private let data: ProductFixedProviderDataScope
    private let reader: ProductContinuationPayloadReader
    private let sequence: Int64
    private let digest: String
    let query: AgentValue
    init(data:ProductFixedProviderDataScope,reader:ProductContinuationPayloadReader,sequence:Int64,
        query:AgentValue,observed:CompletedPluginDocumentObservation) {
        this.data=data;this.reader=reader;this.sequence=sequence;this.query=query
        digest=modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("reader_source",textValue(reader.sourceDigest)),ValueField("mutation",observed.descriptor()),
            ValueField("sequence",integerValue(sequence)),ValueField("query",query)])))
    }
    private func phase(action:String,fields!: Array<ValueField> = []):AgentValue {
        let values=ArrayList<ValueField>([ValueField("schema",textValue("axyndra.document-data-query/v1")),
            ValueField("action",textValue(action)),ValueField("sequence",integerValue(sequence)),ValueField("source_digest",textValue(digest))])
        values.add(all:fields);objectValue(values.toArray())
    }
    // These outer guards run outside the captured Host worker/generation
    // mutex. Each transfer rechecks the actual Application owner and complete
    // configuration bytes; semantic checkpoints additionally rehash package.
    private func exchange(value:AgentValue,checkpoint!:Bool=false):Result<AgentValue> {
        match(reader.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let result=match(data.exchange(value,checkpoint:checkpoint)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(item)=>item }
        match(reader.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        Result.Ok(result)
    }
    private func acknowledged(value:AgentValue,field:String):Result<Unit> {
        if(!httpIntentExactFields(value,[field]) || value.field(field).getOrThrow().unifiedKind!=ValueKind.Boolean ||
            !value.field(field).getOrThrow().asBool()){return commandControlError("continuation.payload_transfer_rejected")}
        Result.Ok(())
    }
    private func append(id:String,offset:Int64,bytes:Array<Byte>):Result<Unit> {
        let value=match(exchange(phase("append",fields:[ValueField("id",textValue(id)),ValueField("offset",integerValue(offset)),
            ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes)))]))) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        acknowledged(value,"accepted")
    }
    func execute(session:ProductDocumentDataSession,index:Int64):Result<AgentValue> {
        let started=match(exchange(phase("begin",fields:[ValueField("tool",textValue("goal_continuation")),ValueField("input",query),
            ValueField("documents",listValue([query.field("approved_document").getOrThrow(),query.field("current_document").getOrThrow()]))]),checkpoint:true)) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
        match(acknowledged(started,"accepted")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        var released=false
        try {
            match(reader.uploadApproved(session,{offset,bytes=>append("approved",offset,bytes)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(reader.uploadCurrent(session,index,{offset,bytes=>append("current",offset,bytes)})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let answer=match(exchange(phase("compute"),checkpoint:true)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            if(!httpIntentExactFields(answer,["continue"]) || answer.field("continue").getOrThrow().unifiedKind!=ValueKind.Boolean){
                return commandControlError("continuation.payload_predicate_invalid")}
            let closed=match(exchange(phase("release"),checkpoint:true)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            match(acknowledged(closed,"released")){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            released=true
            match(reader.validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            Result.Ok(answer)
        }finally{
            // An expired/revoked release cannot create a fresh deadline. The
            // session then keeps the captured physical worker cleanup until
            // its real close ACK; no computed answer escapes this failure.
            if(!released){let _=exchange(phase("release"),checkpoint:true)}
        }
    }
}

func continuationPayloadSlot(id:String,reference:PluginDocumentPayloadReference):AgentValue {
    objectValue([ValueField("id",textValue(id)),ValueField("bytes",integerValue(reference.bytes)),ValueField("sha256",textValue(reference.digest))])
}

func restrictProductContinuationPayload(restriction:ProductContinuationRestriction,ownerDigest:String,
    original:CompletedPluginDocumentObservation,chain:Array<CompletedPluginDocumentObservation>,thread:ThreadId,key:String,
    totalTokens:Int64,cancellation:CancellationToken,requestId:String,anchorRun:String,anchorClaim:String,
    allocation:ContinuationDocumentReadScope,window:ProductContinuationPreparationDeadline,reader:ProductContinuationPayloadReader,
    limits:ExecutionResourceLimits):Result<ProductContinuationDocumentSelection> {
    window.check()
    match(reader.validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    if(chain.isEmpty() || chain.size>256 || original.payload.isNone()) {return commandControlError("continuation.document_chain_invalid")}
    let observedAt=nowMillis();let queries=ArrayList<AgentValue>()
    let session=match(restriction.command.host.documentDataSession()){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    // The Host factory retains this same session before any file/worker can
    // exist. run() fails closed when cleanup lacks its actual ACK.
    let result=session.run({owned=>
        for(index in 0..chain.size) {
            window.check();let observed=chain[index]
            if(observed.payload.isNone()){return commandControlError("continuation.document_chain_invalid")}
            let query=objectValue([ValueField("schema",textValue("axyndra.continuation-restriction/v1")),ValueField("selector",restriction.selector()),
                ValueField("approved_document",continuationPayloadSlot("approved",original.payload.getOrThrow())),
                ValueField("current_document",continuationPayloadSlot("current",observed.payload.getOrThrow())),
                ValueField("facts",objectValue([ValueField("now_millis",integerValue(observedAt)),ValueField("total_tokens",integerValue(totalTokens))]))])
            let sequence=match(restriction.command.host.allocateDocumentDataSequence()){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            let data=ProductFixedProviderDataScope(restriction.command.host,restriction.configuration,restriction.provider,
                restriction.command.generation,thread,cancellation,limits,requestId+"-"+observed.revision.toString(),window.deadline,
                {=>reader.local()},{=>reader.validate()})
            let transfer=ProductContinuationPayloadQuery(data,reader,sequence,query,observed)
            let answer=match(data.run(owned,{_=>transfer.execute(owned,index)})) {
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
            if(!answer.field("continue").getOrThrow().asBool()){return commandControlError("continuation.restriction_stopped")}
            match(reader.validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            queries.add(objectValue([ValueField("mutation",observed.descriptor()),
                ValueField("query_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(query)))),
                ValueField("reply_sha256",textValue(modelPolicySha256Text(canonicalAgentValue(answer))))]))
        }
        Result.Ok(nullValue())
    })
    match(result){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(reader.validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    window.check()
    productContinuationDocumentSelection(restriction,ownerDigest,original,chain,observedAt,totalTokens,queries.toArray(),
        anchorRun,anchorClaim,allocation,window)
}
