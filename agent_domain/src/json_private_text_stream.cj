package agent_domain

import std.collection.*
import stdx.crypto.digest.SHA256

// Descriptive private state for a trusted data owner. This is not a grant,
// Source, grouping rule, JSON selector supplied by a plugin, or public frame.
public class JsonPrivateTextStreamObservation {
    public let kind:String
    public let bytes:Int64
    public let digest:String
    init(kind:String,bytes:Int64,digest:String){this.kind=kind;this.bytes=bytes;this.digest=digest}
}

// The actual operator assembly chooses this path and owns its callback.
// Only decoded UTF8 bytes of a STRING at this exact path reach the callback.
// No private value String or unbounded byte array is constructed here.
public class JsonFieldStreamPrivateTextSink {
    public let path:Array<String>
    let consume:(Int64,Array<Byte>)->Unit
    public init(path:Array<String>,consume:(Int64,Array<Byte>)->Unit){
        if(path.isEmpty() || path.size>32){throw LogicalJsonPayloadError("private text path exceeds its structural bound")}
        var bytes:Int64=0
        for(part in path){
            if(part=="" || part.size>LOGICAL_JSON_HARD_BYTES-bytes){
                throw LogicalJsonPayloadError("private text path is empty or exceeds its structural bound")}
            bytes+=part.size
        }
        this.path=Array<String>(path.size,{index=>path[index]});this.consume=consume
    }
}

// Shares the parser's actual prepaid owner. The parser adds the simultaneous
// fixed retained peak to its grammar/key charge before constructing this state.
class JsonFieldStreamPrivateTextState {
    private let sink:JsonFieldStreamPrivateTextSink
    private let buffer=ArrayList<Byte>()
    private let hash=SHA256()
    private var kind="missing"
    private var bytes:Int64=0
    private var emitted:Int64=0
    private var seen=false
    private var done=false
    private var digest=""
    init(sink:JsonFieldStreamPrivateTextSink){this.sink=sink}
    func begin(value:String):Unit{
        if(seen){throw LogicalJsonPayloadError("private text path repeats")}
        seen=true;kind=value;done=value!="string"
    }
    func append(value:Array<Byte>):Unit{
        if(kind!="string"){return}
        if(done || value.isEmpty() || value.size>4 || value.size>Int64.Max-bytes){
            throw LogicalJsonPayloadError("decoded private text scalar exceeds its exact stream state")}
        bytes+=value.size
        for(byte in value){buffer.add(byte);if(buffer.size==65536){flush()}}
    }
    private func flush():Unit{
        if(buffer.isEmpty()){return}
        let raw=buffer.toArray()
        hash.write(raw)
        // A failed callback aborts the enclosing parser. It cannot be retried
        // as a successful observation or silently acknowledged.
        sink.consume(emitted,raw)
        emitted+=raw.size;buffer.clear()
    }
    func finishScalar():Unit{
        if(kind=="string"){
            if(done){throw LogicalJsonPayloadError("private text scalar completes twice")}
            flush();digest=logicalJsonEncodeHex(hash.finish());done=true
            if(emitted!=bytes){throw LogicalJsonPayloadError("private decoded text lost a byte")}
        }
    }
    func observation():JsonPrivateTextStreamObservation{
        if(kind=="string" && !done){throw LogicalJsonPayloadError("private decoded text is incomplete")}
        JsonPrivateTextStreamObservation(kind,if(kind=="string"){bytes}else{0},if(kind=="string"){digest}else{""})
    }
}
