package agent_host_runtime

import agent_domain.*
import tool_runtime.*
import std.collection.*
import std.io.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

private class HostLiveKnownTransfer290 {
    var consumed=false
    var bytes:Int64=0
    var digest=""
    var proposalDigest=""
    var errorBytes:Int64=0
    var errorDigest=""
    var offset:Int64=0
}

// Only called inside the actual running Session's metadata/FD custody.
// Every historical child has its own independently settled Root receipt.
// The Store performs complete group preflight, full ordered second pass and
// its Source/ledger after-checks before this function emits endReceiptStreamed.
// No historical Node or read callback escapes the actual Store Unit lifetime.
func hostUploadLivePolicyKnownSequence290(actual:HostDocumentDataSession,rpc:HostLivePolicyDataRPC,
    context:ToolInvocationContext,parent:PreparedToolInvocation,sequence:Int64,through:Int64,ledger:AgentValue,
    owner:LogicalJsonOwnerReservation,retainedPeak:Int64,current:()->Result<Unit>):Result<Unit>{
    if(sequence<1 || sequence>through){return hostPluginResourceError("plugin.live_history_sequence","one actual known child ordinal required")}
    let state=HostLiveKnownTransfer290()
    let copied=actual.consumeLivePolicyKnownProposalPayloads(context,parent,sequence,through,ledger,owner,retainedPeak,current,
        {_,_,error,index,send=>
            if(state.consumed){throw IllegalStateException("actual historical proposal callback replayed")}
            state.consumed=true
            let manifest=index.field("native_manifest").getOrThrow()
            state.bytes=hostLivePolicyRPCInteger(manifest,"total_bytes")
            state.digest=httpIntentText(manifest,"sha256");state.proposalDigest=httpIntentText(manifest,"proposal_digest")
            for(row in index.field("payloads").getOrThrow().items){
                let reference=parsePluginDocumentPayloadReference(row).value().getOrThrow()
                match(send(reference,{_,raw=>
                    let sent=rpc.appendReceipt(sequence-1,state.offset,raw)
                    if(sent.isOk()){state.offset=hostLiveStepAdd248(state.offset,raw.size)};sent})){
                    case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            }
            if(state.offset!=state.bytes){throw IllegalStateException("historical original whole-group EOF changed")}
            if(error.unifiedKind!=ValueKind.Null){
                if(!httpIntentExactFields(error,["kind","code","message","retryable","fallback_allowed","fields","attempt_failure","observation"])){
                    throw IllegalStateException("actual original complete eight-field error required")}
                // The original StoredValue Receipt bound is independent of
                // its escaped JSON extent. The original writer streams both
                // passes without a new aggregate bound or full JSON String.
                // A child of this original shared reservation adds its real
                // SUM to the live index/prior prefix invoice; merely growing
                // the parent to max(error,index) would underpay their overlap.
                // The shared child has the original 1024-byte bookkeeping,
                // with no second message floor or replacement pool.
                let payment=owner.deriveRetainedLease()
                let sent=try{hostEmitLivePolicyKnownError290(rpc,sequence-1,error,payment,current)}finally{payment.close()}
                match(sent){case Result.Err(error)=>throw HostArtifactOperationFailure(error)
                    case Result.Ok(value)=>state.errorBytes=value[0];state.errorDigest=value[1]}
            }
        })
    match(copied){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
    if(!state.consumed || state.offset!=state.bytes){return hostPluginResourceError("plugin.live_history_incomplete","complete actual historical Unit proof was not consumed")}
    match(current()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
    rpc.endReceiptStreamed(sequence-1,state.bytes,state.digest,state.proposalDigest,state.errorBytes,state.errorDigest)
}

// The original writer's one escaped scalar Array and bounded sink chunks
// expire before the outer callback closes their exact shared child payment.
private func hostEmitLivePolicyKnownError290(rpc:HostLivePolicyDataRPC,ordinal:Int64,error:AgentValue,
    payment:LogicalJsonOwnerReservation,current:()->Result<Unit>):Result<(Int64,String)>{
    match(current()){case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
    payment.ensureRetainedPeak(1048576)
    let invoice=HostLiveErrorWriterInvoice290(current)
    invoice.visit(error)
    if(invoice.nodes>Int64.Max/512){throw IllegalStateException("original JSON writer node invoice overflow")}
    payment.ensureRetainedPeak(hostLiveStepAdd248(9437184,hostLiveStepAdd248(invoice.peak,invoice.nodes*512)))
    let measured=HostLiveErrorWriter290(None<((Int64,Array<Byte>)->Result<Unit>)>,current)
    error.writeJson(measured,options:JsonWriteOptions.defaults)
    let expected=measured.finish()
    match(rpc.beginReceiptError(ordinal,expected[0],expected[1])){
        case Result.Err(error)=>return Result<(Int64,String)>.Err(error);case Result.Ok(_)=>()}
    let sent=HostLiveErrorWriter290(Some({at,raw=>rpc.appendReceiptError(ordinal,at,raw)}),current)
    error.writeJson(sent,options:JsonWriteOptions.defaults)
    let actual=sent.finish()
    if(actual[0]!=expected[0] || actual[1]!=expected[1]){
        return hostPluginResourceError("plugin.live_history_error_changed","whole original error JSON changed between the two complete writer passes")}
    match(rpc.endReceiptError(ordinal)){
        case Result.Err(error)=>Result<(Int64,String)>.Err(error);case Result.Ok(_)=>Result<(Int64,String)>.Ok(actual)}
}

class HostLiveErrorWriter290 <: OutputStream {
    private let send:?((Int64,Array<Byte>)->Result<Unit>)
    private let current:()->Result<Unit>
    private let hash=SHA256()
    private var count:Int64=0
    private var ended=false
    init(send:?((Int64,Array<Byte>)->Result<Unit>),current:()->Result<Unit>){this.send=send;this.current=current}
    public func write(value:Array<Byte>):Unit{
        if(ended){throw IllegalStateException("whole original error JSON output followed EOF")}
        var at:Int64=0
        while(at<value.size){let end=min(value.size,at+65536);let raw=value[at..end]
            match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
            hash.write(raw)
            match(send){case Some(consume)=>match(consume(count,raw)){
                case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()};case None=>()}
            count=hostLiveStepAdd248(count,raw.size);at=end}
    }
    public func flush():Unit{}
    func finish():(Int64,String){
        match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
        if(ended){throw IllegalStateException("whole original error EOF repeated")};ended=true
        (count,hostArtifactHex(hash.finish()))
    }
}

class HostLiveErrorWriterInvoice290 {
    private let ancestors=ArrayList<JsonNode>()
    private let current:()->Result<Unit>
    var peak:Int64=0
    var nodes:Int64=0
    init(current:()->Result<Unit>){this.current=current}
    private func check():Unit{
        match(current()){case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(_)=>()}
    }
    // Pinned c91859 writer/native helper: rawData is a borrowed input handle;
    // native escape allocates one exactly measured escaped Array, plus one
    // Int64 written count. The stream target uses a 4096-byte buffer and
    // passes large arrays directly to this synchronous fixed-chunk sink.
    // The original Store owner already pays the complete input String/DOM.
    // Count exact original htmlSafe=false escapes before any writer allocation.
    private func scalar(value:String):Unit{
        var required:Int64=2;var escaped=false;var inspected:Int64=0
        unsafe{let raw=value.rawData()
            for(byte in raw){
                if(inspected%65536==0){check()};inspected+=1
                if(byte>=0x20u8 && byte!=b'"' && byte!=b'\\'){required=hostLiveStepAdd248(required,1)}
                else if(byte==b'"' || byte==b'\\' || byte==b'\b' || byte==b'\f' || byte==b'\n' || byte==b'\r' || byte==b'\t'){
                    escaped=true;required=hostLiveStepAdd248(required,2)
                }else{escaped=true;required=hostLiveStepAdd248(required,6)}
            }}
        if(escaped){peak=max(peak,hostLiveStepAdd248(required,8))}
    }
    func visit(value:AgentValue):Unit{
        nodes=hostLiveStepAdd248(nodes,1)
        if(nodes%1024==1){check()}
        match(value.kind()){
            case JsonKind.String=>scalar(value.asString())
            case JsonKind.Number=>peak=max(peak,value.asNumberText().size)
            case JsonKind.Array | JsonKind.Object=>
                if(ancestors.size>=JsonWriteOptions.defaults.maxDepth){throw IllegalStateException("original JSON writer depth exceeded")}
                for(parent in ancestors){if(refEq(parent,value)){throw IllegalStateException("cyclic original JSON error data")}}
                ancestors.add(value)
                try{
                    if(value.kind()==JsonKind.Array){let array=value.asArray()
                        for(index in 0..array.size()){visit(array.get(index).getOrThrow())}}
                    else{let object=value.asObject()
                        for(index in 0..object.size()){
                            nodes=hostLiveStepAdd248(nodes,1);scalar(object.nameAt(index));visit(object.valueAt(index))}}
                }finally{ancestors.remove(at:ancestors.size-1)}
            case _=>()
        }
    }
}
