package agent_store

import agent_domain.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Identity of the ORIGINAL appendStoredValue grammar. No durable format,
// Source, admission or metadata receipt is created here. UTF-8 strings and
// child values stay in their existing paid owner; only fixed chunks survive
// a hash write. Stored object insertion order and numeric spelling are kept.
private class LivePolicyStoredIdentityStream {
    private let hash=SHA256()
    private let guard:()->Result<Unit>
    private var bytes:Int64=0
    private var finished=false
    init(guard:()->Result<Unit>){this.guard=guard}
    private func add(value:Array<Byte>):Unit{
        if(finished || value.size>8388608-bytes){
            throw IllegalStateException("input preparation exceeds its original durable codec")}
        journalStreamCheck(guard);hash.write(value)
        bytes=journalStreamAdd(bytes,value.size);journalStreamCheck(guard)
    }
    private func text(value:String):Unit{
        journalStreamCheck(guard)
        unsafe{
            let raw=value.rawData();var at:Int64=0
            while(at<raw.size){
                let end=min(raw.size,at+65536)
                // The slice is bounded even when the actual scalar is 8 MiB.
                add(raw[at..end]);at=end
            }
        }
        journalStreamCheck(guard)
    }
    private func frame(value:String):Unit{
        text(value.size.toString());add([b':']);text(value)
    }
    func visit(value:AgentValue,depth:Int64):Unit{
        if(depth>64){throw IllegalStateException("stored value exceeds its original depth")}
        journalStreamCheck(guard)
        match(value.unifiedKind){
            case ValueKind.Null=>add([b'n'])
            case ValueKind.Boolean=>add([if(value.asBool()){b't'}else{b'f'}])
            case ValueKind.Number=>
                let raw=value.asNumberText()
                // The original StoredValue meter calls this same constructor.
                let _=numberValue(raw);add([b'd']);frame(raw)
            case ValueKind.Text=>add([b's']);frame(value.text)
            case ValueKind.List=>
                let array=value.asArray()
                if(array.size()>1000000){throw IllegalStateException("stored collection count is out of bounds")}
                add([b'l']);frame(array.size().toString())
                for(index in 0..array.size()){visit(array.get(index).getOrThrow(),depth+1)}
            case ValueKind.Object=>
                let object=value.asObject()
                if(object.size()>1000000){throw IllegalStateException("stored collection count is out of bounds")}
                add([b'o']);frame(object.size().toString())
                for(index in 0..object.size()){
                    frame(object.nameAt(index));visit(object.valueAt(index),depth+1)}
        }
        journalStreamCheck(guard)
    }
    func finish(): (Int64,String){
        if(finished){throw IllegalStateException("stored identity stream is once-only")}
        journalStreamCheck(guard);finished=true
        let digest=hash.finish();let digits="0123456789abcdef"
        let result=Array<Byte>(digest.size*2,repeat:0)
        for(index in 0..digest.size){
            let byte=Int64(digest[index]);result[index*2]=digits[byte/16];result[index*2+1]=digits[byte%16]}
        (bytes,String.fromUtf8(result))
    }
}

func livePolicyInputStoredDigestStreamedOwned(arguments:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,extraRetained!:Int64=0):String{
    if(extraRetained<0){throw IllegalStateException("input identity retained payment is negative")}
    owner.ensureRetainedPeak(journalStreamAdd(1048576,extraRetained))
    let extent=livePolicyStoredExtent(arguments)
    if(extent.bytes>8388608 || extent.nodes>(Int64.Max-1048576)/512){
        throw IllegalStateException("input preparation exceeds its original durable codec")}
    // No full encoded ArrayList/toArray/String or second DOM exists in
    // this path. This pays fixed hash overlap and the original traversal.
    owner.ensureRetainedPeak(journalStreamAdd(1048576+extent.nodes*512,extraRetained))
    let stream=LivePolicyStoredIdentityStream(guard);stream.visit(arguments,0)
    let identity=stream.finish()
    if(identity[0]!=extent.bytes){throw IllegalStateException("input preparation framing extent changed")}
    journalStreamCheck(guard);identity[1]
}

func livePolicyInputStoredDigestStreamed(arguments:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>):String{
    journalStreamCheck(guard);let owner=allocate(65536)
    try{
        livePolicyInputStoredDigestStreamedOwned(arguments,owner,guard)
    }finally{owner.close()}
}

func livePolicyInputPayloadIdentityOwned(input:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(Int64,String)->Unit,extraRetained!:Int64=0):Unit{
    if(extraRetained<0){throw IllegalStateException("input identity retained payment is negative")}
    let fields=match(input as JsonObject){case Some(value)=>value.size();case None=>0}
    if(fields>(Int64.Max-1048576)/2048){throw IllegalStateException("business projection wrapper payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(1048576+fields*2048,extraRetained))
    // Exactly the original business projection, followed by the pinned
    // original complete default JSON writer used by terminal stream2.
    let business=contextReadBusinessInput(input)
    livePolicyTerminalOutputIdentityOwned(business,owner,guard,consume,extraRetained:journalStreamAdd(1048576+fields*2048,extraRetained))
    journalStreamCheck(guard)
}

func withPluginLivePolicyInputPayloadIdentity(input:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(Int64,String)->Unit):Unit{
    journalStreamCheck(guard);let owner=allocate(65536)
    try{
        livePolicyInputPayloadIdentityOwned(input,owner,guard,consume)
    }finally{owner.close()}
}
