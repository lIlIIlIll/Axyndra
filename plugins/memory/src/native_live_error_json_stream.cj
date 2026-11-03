package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.io.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Data decoding only. Neither complete JSON, its hash, nor a typed error is
// Source/approval/handoff/Receipt authority. The actual Host must still supply
// the original persisted child tuple; Native's original replay gate remains.
private class MemoryLiveErrorFrame321 {
    let object:Bool
    var phase:Int64=0
    var key=""
    let names=HashSet<String>()
    let fields=ArrayList<ValueField>()
    let items=ArrayList<AgentValue>()
    init(object:Bool){this.object=object}
}

// Incrementally construct the complete original error DOM. Escaped wire
// bytes never accumulate. One scalar's growable UTF8 backing is temporary;
// all completed String backings, array/map/frame and typed-error reference
// cells remain prepaid as a SUM under the caller's original reservation.
class MemoryLiveErrorStream321 {
    private let temporary:LogicalJsonOwnerReservation
    private let retain:(Int64)->Unit
    private let expectedBytes:Int64
    private let expectedDigest:String
    private let hash=SHA256()
    private var frames=ArrayList<MemoryLiveErrorFrame321>()
    private var result:?AgentValue=None
    private var text=ArrayList<Byte>()
    private var utf8=ArrayList<Byte>()
    private var textAllowance:Int64=0
    private var decodedBytes:Int64=0
    private var decodedAllowance:Int64=0
    private var nodes:Int64=0
    private var offset:Int64=0
    private var root:Int64=0
    private var mode:Int64=0
    private var stringKey=false
    private var escape=false
    private var unicodeDigits:Int64=0
    private var unicode:UInt32=0
    private var high:UInt32=0
    private var lowStep:Int64=0
    private var remaining:Int64=0
    private var scalar:UInt32=0
    private var minimum:UInt32=0
    private var finished=false
    private var closed=false
    private var typedBytes:Int64=0
    init(bytes:Int64,digest:String,temporary:LogicalJsonOwnerReservation,retain:(Int64)->Unit){
        if(bytes<1 || !httpIntentDigest(digest)){memoryLiveInvalid("complete original error extent/hash required")}
        this.expectedBytes=bytes;this.expectedDigest=digest;this.temporary=temporary;this.retain=retain
        temporary.ensureRetainedPeak(2097152)
        chargeRetained(0)
    }
    private func chargeRetained(extra:Int64):Unit{
        //1024 per key/value/container prepays concurrently live growable
        // frame arrays/maps, final DOM arrays, temporary detached views,
        // typed ErrorField array and original diagnostics/observation cells.
        // Decoded String backing is counted once for each actual decoding,
        // then shared by immutable String value references, not reserialized.
        retain(memoryLiveAdd(1048576,memoryLiveAdd(decodedAllowance,
            memoryLiveAdd(memoryLiveMul(nodes,1024),extra))))
    }
    private func top():MemoryLiveErrorFrame321{frames[frames.size-1]}
    private func expectsValue():Bool{
        if(frames.isEmpty()){return root==0}
        if(top().object){return top().phase==2};top().phase==0 || top().phase==2
    }
    private func startValue():Unit{
        if(!expectsValue()){memoryLiveInvalid("error JSON value is outside original grammar")}
        nodes=memoryLiveAdd(nodes,1);chargeRetained(0)
        if(frames.isEmpty()){root=1}else{top().phase=if(top().object){3}else{1}}
    }
    private func attach(value:AgentValue):Unit{
        if(frames.isEmpty()){
            if(root!=1 || result.isSome()){memoryLiveInvalid("error JSON contains multiple root values")}
            result=Some(value);root=2
        }else if(top().object){top().fields.add(ValueField(top().key,value));top().key=""}
        else{top().items.add(value)}
    }
    private func textRoom(bytes:Int64):Unit{
        let wanted=memoryLiveAdd(text.size,bytes)
        if(wanted>textAllowance){
            let blocks=memoryLiveAdd(wanted,65535)/65536
            textAllowance=memoryLiveMul(blocks,65536)
            // Old+new growing ArrayList backings, toArray and UTF8 conversion
            // coexist here. The final String has separate retained payment.
            temporary.ensureRetainedPeak(memoryLiveAdd(2097152,memoryLiveMul(textAllowance,4)))
        }
        // Prepay final backing before its first byte or String is allocated.
        decodedBytes=memoryLiveAdd(decodedBytes,bytes)
        if(decodedBytes>decodedAllowance){
            decodedAllowance=memoryLiveMul(memoryLiveAdd(decodedBytes,65535)/65536,65536)
            chargeRetained(0)
        }
    }
    private func emit(bytes:Array<Byte>):Unit{textRoom(bytes.size);text.add(all:bytes)}
    private func emitAscii(byte:Byte):Unit{textRoom(1);text.add(byte)}
    private func beginString():Unit{
        stringKey=!frames.isEmpty() && top().object && (top().phase==0 || top().phase==4)
        if(stringKey){nodes=memoryLiveAdd(nodes,1);chargeRetained(0)}else{startValue()}
        text=ArrayList<Byte>();textAllowance=0;utf8=ArrayList<Byte>()
        escape=false;unicodeDigits=0;unicode=0;high=0;lowStep=0;remaining=0;mode=1
    }
    private func endString():Unit{
        if(remaining!=0 || high!=0 || lowStep!=0){memoryLiveInvalid("incomplete original error UTF8/surrogate pair")}
        // The temporary payment stays live through both conversion calls.
        let value=String.fromUtf8(text.toArray())
        if(stringKey){
            if(top().names.contains(value)){memoryLiveInvalid("original error JSON repeats an object key")}
            top().names.add(value);top().key=value;top().phase=1
        }else{attach(textValue(value))}
        // Replace instead of clear: ArrayList.clear retains its capacity.
        text=ArrayList<Byte>();textAllowance=0;utf8=ArrayList<Byte>();mode=0
    }
    private func stringByte(byte:Byte):Unit{
        if(remaining>0){
            if(byte<0x80 || byte>0xBF){memoryLiveInvalid("invalid original error UTF8 continuation")}
            scalar=(scalar<<6)|UInt32(byte&0x3F);utf8.add(byte);remaining--
            if(remaining==0){
                if(scalar<minimum || scalar>0x10FFFF || (scalar>=0xD800 && scalar<=0xDFFF)){
                    memoryLiveInvalid("invalid original error UTF8 scalar")}
                emit(utf8.toArray());utf8=ArrayList<Byte>()}
            return
        }
        if(unicodeDigits>0){
            unicode=(unicode<<4)|memoryEventStreamHex(byte);unicodeDigits--
            if(unicodeDigits==0){
                if(high!=0){
                    if(unicode<0xDC00 || unicode>0xDFFF){memoryLiveInvalid("invalid original error low surrogate")}
                    emit(memoryEventStreamScalar(0x10000+((high-0xD800)<<10)+(unicode-0xDC00)));high=0
                }else if(unicode>=0xD800 && unicode<=0xDBFF){high=unicode;lowStep=1}
                else{emit(memoryEventStreamScalar(unicode))}
            };return
        }
        if(lowStep>0){
            if((lowStep==1 && byte!=b'\\') || (lowStep==2 && byte!=b'u')){
                memoryLiveInvalid("original error high surrogate requires complete low pair")}
            if(lowStep==1){lowStep=2}else{lowStep=0;unicode=0;unicodeDigits=4};return
        }
        if(escape){
            escape=false
            match(byte){
                case b'"' | b'\\' | b'/'=>emit([byte])
                case b'b'=>emit([UInt8(8)])
                case b'f'=>emit([UInt8(12)])
                case b'n'=>emit([UInt8(10)])
                case b'r'=>emit([UInt8(13)])
                case b't'=>emit([UInt8(9)])
                case b'u'=>unicode=0;unicodeDigits=4
                case _=>memoryLiveInvalid("invalid original error JSON escape")}
            return
        }
        if(byte==b'"'){endString();return}
        if(byte==b'\\'){escape=true;return}
        if(byte<0x20){memoryLiveInvalid("unescaped original error control character")}
        if(byte<0x80){emitAscii(byte);return}
        if(byte>=0xC2 && byte<=0xDF){remaining=1;scalar=UInt32(byte&0x1F);minimum=0x80}
        else if(byte>=0xE0 && byte<=0xEF){remaining=2;scalar=UInt32(byte&0x0F);minimum=0x800}
        else if(byte>=0xF0 && byte<=0xF4){remaining=3;scalar=UInt32(byte&0x07);minimum=0x10000}
        else{memoryLiveInvalid("invalid original error UTF8 leading byte")}
        utf8.add(byte)
    }
    private func scalarDone():Unit{
        let token=String.fromUtf8(text.toArray())
        // Original parser keeps the exact original numeric/literal grammar
        // and precision. Only this scalar token, never the complete wire, is
        // temporarily parsed. Strings/keys were decoded incrementally above.
        let value=parseUnifiedJson(token,maxBytes:token.size,maxDepth:256)
        if(value.unifiedKind!=ValueKind.Number && value.unifiedKind!=ValueKind.Boolean && value.unifiedKind!=ValueKind.Null){
            memoryLiveInvalid("original error JSON scalar token changed kind")}
        attach(value);text=ArrayList<Byte>();textAllowance=0;mode=0
    }
    private func syntax(byte:Byte):Unit{
        if(byte==b' ' || byte==b'\t' || byte==b'\r' || byte==b'\n'){return}
        if(byte==b'"'){beginString();return}
        if(byte==b'{' || byte==b'['){
            startValue();if(frames.size>=256){memoryLiveInvalid("original error JSON exceeds depth256")}
            frames.add(MemoryLiveErrorFrame321(byte==b'{'));return
        }
        if(byte==b'}' || byte==b']'){
            if(frames.isEmpty() || top().object!=(byte==b'}') ||
                (top().object && top().phase!=0 && top().phase!=3) ||
                (!top().object && top().phase!=0 && top().phase!=1)){
                memoryLiveInvalid("original error JSON container is incomplete")}
            let frame=frames.remove(at:frames.size-1)
            let value=if(frame.object){objectValue(frame.fields.toArray())}else{listValue(frame.items.toArray())}
            attach(value);return
        }
        if(byte==b':'){
            if(frames.isEmpty() || !top().object || top().phase!=1){memoryLiveInvalid("original error JSON key lacks value")}
            top().phase=2;return
        }
        if(byte==b','){
            if(frames.isEmpty() || (top().object && top().phase!=3) || (!top().object && top().phase!=1)){
                memoryLiveInvalid("invalid original error JSON comma")}
            top().phase=if(top().object){4}else{2};return
        }
        startValue();mode=2;text=ArrayList<Byte>();textAllowance=0;emitAscii(byte)
    }
    func position():Int64{offset}
    func append(expectedOffset:Int64,bytes:Array<Byte>):Unit{
        if(closed || finished || expectedOffset!=offset || bytes.isEmpty() || bytes.size>65536 || bytes.size>expectedBytes-offset){
            memoryLiveInvalid("original error stream overlaps/skips/exceeds exact extent")}
        hash.write(bytes)
        for(byte in bytes){
            if(mode==1){stringByte(byte)}
            else if(mode==2){
                if(byte==b' ' || byte==b'\t' || byte==b'\r' || byte==b'\n' || byte==b',' || byte==b']' || byte==b'}'){
                    scalarDone();syntax(byte)}else{emitAscii(byte)}
            }else{syntax(byte)}
        }
        offset=memoryLiveAdd(offset,bytes.size)
    }
    func finish():AgentError{
        if(closed || finished || offset!=expectedBytes || mode==1){memoryLiveInvalid("complete original error EOF required")}
        if(mode==2){scalarDone()}
        if(root!=2 || !frames.isEmpty() || result.isNone() || logicalJsonEncodeHex(hash.finish())!=expectedDigest){
            memoryLiveInvalid("complete original error JSON/hash changed")}
        // Original Observation stores an independently frozen canonical
        // String. Its existing65536 bound is checked by the ORIGINAL pinned
        // writer, after paying its temporary largest scalar. An observation
        // exceeding that existing bound cannot be constructed; no error-wire
        // cap or substitute numeric/string serializer is introduced here.
        let decoded=result.getOrThrow()
        var observationBytes:Int64=0
        match(decoded.field("observation")){
            case Some(observation)=>if(observation.unifiedKind!=ValueKind.Null){
                memoryDocumentFields(observation,["schema","trust","authorizes_effects","content"])
                if(memoryDocumentText(observation,"schema")!="axyndra.operation-observation/v1" ||
                    memoryDocumentText(observation,"trust")!="untrusted_data" || memoryLiveBool(observation,"authorizes_effects")){
                    memoryLiveInvalid("observation cannot become effect authority")}
                let content=observation.field("content").getOrThrow()
                memoryLiveErrorObservationScalar321(content)
                let payment=MemoryLiveWriterPayment();payment.visit(content)
                temporary.ensureRetainedPeak(memoryLiveAdd(payment.peak,1048576))
                let counter=MemoryLiveErrorObservationCounter321()
                content.writeJson(counter,options:JsonWriteOptions.defaults)
                observationBytes=counter.bytes
                chargeRetained(memoryLiveMul(counter.bytes,8))
            }
            case None=>()}
        let error=match(memoryLiveErrorFrom(decoded)){case Some(value)=>value
            case None=>memoryLiveInvalid("streamed error must contain the complete typed eight fields")}
        // Permanent custody follows the ACTUAL typed fields. Parser keys,
        // unused DOM arrays, rounding padding and its fixed temporary buffer
        // are not charged once per settlement as though still retained.
        typedBytes=memoryLiveAdd(4096,memoryLiveAdd(error.code.size,error.message.size))
        for(field in error.fields){typedBytes=memoryLiveAdd(typedBytes,
            memoryLiveAdd(256,memoryLiveAdd(field.name.size,field.value.size)))}
        if(error.attemptFailure.isSome()){typedBytes=memoryLiveAdd(typedBytes,512)}
        if(error.observation.isSome()){typedBytes=memoryLiveAdd(typedBytes,memoryLiveAdd(512,observationBytes))}
        // The completed typed fields retain the same paid String backings.
        // Its additional arrays/cells were paid before their construction.
        finished=true;error
    }
    func typedRetainedBytes():Int64{
        if(!finished || typedBytes<4096){memoryLiveInvalid("same completed actual typed error required")};typedBytes
    }
    func close():Unit{
        if(!closed){
            result=None;frames=ArrayList<MemoryLiveErrorFrame321>();text=ArrayList<Byte>();utf8=ArrayList<Byte>()
            temporary.close();closed=true
        }
    }
}

// The original writer cannot encode a String using fewer than rawUTF8+2
// bytes. Reject only this mathematically certain violation of the EXISTING
// observation bound before a giant escaped temporary could be allocated.
// All accepted scalar formatting/counting is done by the pinned writer.
private func memoryLiveErrorObservationScalar321(value:AgentValue):Unit{
    match(value.unifiedKind){
        case ValueKind.Text=>if(value.text.size>65534){throw IllegalArgumentException("operation observation exceeds its inline byte bound")}
        case ValueKind.List=>
            for(item in value.items){memoryLiveErrorObservationScalar321(item)}
        case ValueKind.Object=>
            for(field in value.fields){
                if(field.name.size>65534){throw IllegalArgumentException("operation observation exceeds its inline byte bound")}
                memoryLiveErrorObservationScalar321(field.value)}
        case _=>()
    }
}
private class MemoryLiveErrorObservationCounter321 <: OutputStream {
    var bytes:Int64=0
    public func write(value:Array<Byte>):Unit{
        if(value.size>65536-bytes){throw IllegalArgumentException("operation observation exceeds its inline byte bound")}
        bytes+=value.size
    }
    public func flush():Unit{}
}
