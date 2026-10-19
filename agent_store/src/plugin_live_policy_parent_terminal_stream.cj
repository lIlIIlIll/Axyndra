package agent_store

import agent_domain.*
import std.io.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// The pinned node's original writeJson uses the same complete codec visitor
// and default options as encodeAgentValue. This sink retains no JSON bytes.
// The pinned stream writer may pass a whole scalar slice/native escaped
// array; that real temporary is prepaid before writeJson is called.
private class LivePolicyTerminalHashStream <: OutputStream{
    private let hash=SHA256()
    private let guard:()->Result<Unit>
    private var bytes:Int64=0
    private var finished=false
    init(guard:()->Result<Unit>){this.guard=guard}
    public func write(value:Array<Byte>):Unit{
        if(finished || value.size>PLUGIN_DOCUMENT_MAX_BYTES-bytes){
            throw IllegalStateException("terminal output exceeds its original complete JSON bound")}
        journalStreamCheck(guard)
        var at:Int64=0
        while(at<value.size){
            let end=min(value.size,at+65536)
            // Only this fixed sliced overlap is added by the sink. Every
            // original writer byte enters SHA256, including final EOF.
            let part=value[at..end];hash.write(part);at=end
            journalStreamCheck(guard)
        }
        bytes=journalStreamAdd(bytes,value.size);journalStreamCheck(guard)
    }
    public func flush():Unit{journalStreamCheck(guard)}
    func finish(): (Int64,String){
        if(finished){throw IllegalStateException("terminal hash stream already finished")}
        journalStreamCheck(guard);finished=true
        let digest=hash.finish();let digits="0123456789abcdef";let encoded=Array<Byte>(digest.size*2,repeat:0)
        for(index in 0..digest.size){
            let byte=Int64(digest[index]);encoded[index*2]=digits[byte/16];encoded[index*2+1]=digits[byte%16]}
        (bytes,String.fromUtf8(encoded))
    }
}

func livePolicyTerminalOutputIdentityOwned(output:AgentValue,owner:LogicalJsonOwnerReservation,
    guard:()->Result<Unit>,consume:(Int64,String)->Unit,extraRetained!:Int64=0):Unit{
    if(extraRetained<0){throw IllegalStateException("terminal identity retained payment is negative")}
    owner.ensureRetainedPeak(journalStreamAdd(1048576,extraRetained));journalStreamCheck(guard)
    let _=JsonNode.nullValue.toJson()
    let extent=LivePolicyTerminalJsonExtent(JsonWriteOptions.defaults,owner,extraRetained:extraRetained)
    let exact=extent.visit(output)
    if(exact && extent.bytes>PLUGIN_DOCUMENT_MAX_BYTES){
        throw IllegalStateException("terminal output exceeds its original complete JSON bound")}
    // Exact successful output is at most the original 8 MiB. Prepay
    // its possible full raw slice and native escaped scalar concurrently,
    // plus writer state and the 64 KiB sliced hashing overlap. The output
    // DOM is already retained by the caller's original result reservation.
    if(extent.bytes>(Int64.Max-1048576)/2){throw IllegalStateException("terminal stream payment overflow")}
    owner.ensureRetainedPeak(journalStreamAdd(1048576+extent.bytes*2,extraRetained))
    let sink=LivePolicyTerminalHashStream(guard)
    output.writeJson(sink,options:JsonWriteOptions.defaults)
    let identity=sink.finish()
    if(!exact || identity[0]!=extent.bytes){throw IllegalStateException("terminal stream differs from its original full JSON extent")}
    journalStreamCheck(guard);consume(identity[0],identity[1]);journalStreamCheck(guard)
}

// The same actual aggregate pays only the original streaming writer's
// additional scalar/native-escape storage and fixed overlap, not a second
// full DOM/String encoding. The caller retains the original output lease.
public func withPluginLivePolicyTerminalOutputIdentity(output:AgentValue,
    allocate:(Int64)->LogicalJsonOwnerReservation,guard:()->Result<Unit>,consume:(Int64,String)->Unit):Unit{
    journalStreamCheck(guard)
    let owner=allocate(65536)
    try{
        livePolicyTerminalOutputIdentityOwned(output,owner,guard,consume)
    }finally{owner.close()}
}
