package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

// Native-only incremental original-event decoder. This accepts data, never a
// Source/ReadGrant/path/SQL selector. The actual Host/Store must independently
// pin the complete stream and current full journal fence before its output is
// consumed. No caller-visible "complete" flag authorizes a journal mutation.
let MEMORY_EVENT_STREAM_MAX_BYTES:Int64=67108864
let MEMORY_EVENT_STREAM_CHUNK_BYTES:Int64=65536

func memoryEventStreamInvalid(message:String):Nothing{
    throw PureProviderError("memory.stream_json_invalid",message)
}
func memoryEventStreamHex(byte:Byte):UInt32{
    if(byte>=b'0' && byte<=b'9'){return UInt32(byte-b'0')}
    if(byte>=b'a' && byte<=b'f'){return UInt32(byte-b'a')+10}
    if(byte>=b'A' && byte<=b'F'){return UInt32(byte-b'A')+10}
    memoryEventStreamInvalid("invalid original JSON Unicode escape")
}
func memoryEventStreamScalar(value:UInt32):Array<Byte>{
    if(value>0x10FFFF || (value>=0xD800 && value<=0xDFFF)){
        memoryEventStreamInvalid("invalid original JSON Unicode scalar")}
    if(value<=0x7F){return [UInt8(value)]}
    if(value<=0x7FF){return [UInt8(0xC0|(value>>6)),UInt8(0x80|(value&0x3F))]}
    if(value<=0xFFFF){return [UInt8(0xE0|(value>>12)),UInt8(0x80|((value>>6)&0x3F)),UInt8(0x80|(value&0x3F))]}
    [UInt8(0xF0|(value>>18)),UInt8(0x80|((value>>12)&0x3F)),UInt8(0x80|((value>>6)&0x3F)),UInt8(0x80|(value&0x3F))]
}

class MemoryStreamText {
    let name:String
    let rawOffset:Int64
    var rawBytes:Int64=0
    var bytes:Int64=0
    var digest=""
    private let hash=SHA256()
    private let prefix=ArrayList<Byte>()
    private let fragment=ArrayList<Byte>()
    private let consume:(String,Int64,String)->Unit
    private var emitted:Int64=0
    private var prefixStopped=false
    init(name:String,rawOffset:Int64,consume:(String,Int64,String)->Unit){
        this.name=name;this.rawOffset=rawOffset;this.consume=consume}
    func append(scalar:Array<Byte>):Unit{
        if(bytes>MEMORY_EVENT_STREAM_MAX_BYTES-scalar.size){memoryEventStreamInvalid("decoded event string exceeds the original codec")}
        bytes+=scalar.size
        // Keep only a complete UTF8 prefix usable by the original inline
        // fragment/context algorithm. This prefix is not the field itself.
        if(!prefixStopped){
            if(prefix.size+scalar.size<=65537){prefix.add(all:scalar)}else{prefixStopped=true}}
        fragment.add(all:scalar)
        if(fragment.size>=MEMORY_EVENT_STREAM_CHUNK_BYTES){flush()}
    }
    func appendAscii(byte:Byte):Unit{
        if(bytes==MEMORY_EVENT_STREAM_MAX_BYTES){memoryEventStreamInvalid("decoded event string exceeds the original codec")}
        bytes++
        if(!prefixStopped){if(prefix.size<65537){prefix.add(byte)}else{prefixStopped=true}}
        fragment.add(byte);if(fragment.size>=MEMORY_EVENT_STREAM_CHUNK_BYTES){flush()}
    }
    private func flush():Unit{
        if(fragment.isEmpty()){return}
        let raw=fragment.toArray();hash.write(raw)
        let value=String.fromUtf8(raw);consume(name,emitted,value)
        emitted+=fragment.size;fragment.clear()
    }
    func finish(rawBytes:Int64):Unit{
        this.rawBytes=rawBytes;flush();digest=logicalJsonEncodeHex(hash.finish())
        if(emitted!=bytes){memoryEventStreamInvalid("decoded original field did not complete")}
    }
    func inlinePrefix():String{String.fromUtf8(prefix.toArray())}
}

class MemoryEventStreamFrame {
    let object:Bool
    let tag:String
    var phase:Int64=0
    var key=""
    init(object:Bool,tag:String){this.object=object;this.tag=tag}
}
class MemoryStreamedEvent {
    // The content/context/source strings in this metadata DTO are explicit
    // parser placeholders. It must not enter whole-record business methods;
    // stream-aware Native policy uses the complete field descriptors below.
    let metadataRecord:MemoryV3Record
    let fields:Array<MemoryStreamText>
    let rawBytes:Int64
    let digest:String
    init(record:MemoryV3Record,fields:Array<MemoryStreamText>,rawBytes:Int64,digest:String){
        this.metadataRecord=record;this.fields=fields;this.rawBytes=rawBytes;this.digest=digest}
    func field(name:String):?MemoryStreamText{
        for(value in fields where value.name==name){return Some(value)};None
    }
}

class MemoryEventStreamDecoder {
    private let owner:LogicalJsonOwnerReservation
    private let expectedBytes:Int64
    private let expectedDigest:String
    private let consume:(String,Int64,String)->Unit
    private let metadata=ArrayList<Byte>()
    private let frames=ArrayList<MemoryEventStreamFrame>()
    private let fields=ArrayList<MemoryStreamText>()
    private let rawHash=SHA256()
    private var offset:Int64=0
    private var root:Int64=0
    private var mode:Int64=0 // 0 syntax, 1 string, 2 scalar token
    private var stringKey=false
    private var field:?MemoryStreamText=None
    private var stringOffset:Int64=0
    private let keyBytes=ArrayList<Byte>()
    private var escape=false
    private var unicodeDigits:Int64=0
    private var unicode:UInt32=0
    private var high:UInt32=0
    private var lowStep:Int64=0
    private var remaining:Int64=0
    private var scalar:UInt32=0
    private var minimum:UInt32=0
    private let utf8=ArrayList<Byte>()
    private var nodes:Int64=0
    private var finished=false
    private let boundedMetadata:Bool
    private var validationOwner:?LogicalJsonOwnerReservation=None
    private var validation:?JsonFieldStreamProjector=None
    private var discardedDepth:Int64= -1
    private var keyTruncated=false
    private var ignoredKeyCounter:Int64=0
    private var closed=false
    init(bytes:Int64,digest:String,owner:LogicalJsonOwnerReservation,
        consume!:(String,Int64,String)->Unit={_,_,_=>()},boundedMetadata!:Bool=false,
        validationAllocate!:(Int64)->LogicalJsonOwnerReservation={_=>reservePurePolicyRawData()}){
        if(bytes<1 || bytes>MEMORY_EVENT_STREAM_MAX_BYTES || !httpIntentDigest(digest)){
            memoryEventStreamInvalid("event extent differs from its original codec")}
        this.expectedBytes=bytes;this.expectedDigest=digest;this.owner=owner;this.consume=consume;this.boundedMetadata=boundedMetadata
        owner.ensureRetainedPeak(1048576+MEMORY_EVENT_STREAM_CHUNK_BYTES*16)
        if(boundedMetadata){
            // This is a separate live reservation in the same actual Native
            // pool. It validates ALL original bytes, including every ignored
            // subtree/key/number/UTF8/depth/duplicate, not a completion DTO.
            let lease=validationAllocate(65536)
            try{
                validation=Some(JsonFieldStreamProjector(bytes,digest,[JsonFieldProjectionRule(["__syntax_only__"])],lease))
                validationOwner=Some(lease)
            }catch(error:Exception){lease.close();throw error}}
    }
    private func charge(extra:Int64):Unit{
        // Raw chunks, all growing backing copies, reduced original JSON, its
        // eventual DOM and metadata record coexist. There is no node/item
        // truncation: the real shared pool rejects an unpaid live allocation.
        if(extra<0 || metadata.size>Int64.Max/16-extra || nodes>Int64.Max/1024){
            memoryEventStreamInvalid("event metadata charge overflow")}
        owner.ensureRetainedPeak(1048576+MEMORY_EVENT_STREAM_CHUNK_BYTES*16+(metadata.size+extra)*16+nodes*1024+fields.size*524288)
    }
    func close():Unit{
        if(!closed){closed=true;match(validationOwner){case Some(lease)=>lease.close();case None=>()}
            validationOwner=None;validation=None}}
    private func meta(byte:Byte):Unit{
        if(boundedMetadata && (discardedDepth>=0 || (mode==1 && stringKey))){return};metadata.add(byte)}
    private func originalKnownKey(tag:String,key:String):Bool{
        if(tag=="root"){return ["version","operation","record"].contains(key)}
        if(tag=="record"){return ["id","kind","scopeKind","scopeKey","content","context","source","importancePermille",
            "status","expiresAt","correctionOf","replacementId","conflictIds","conflictReason","deletionReason",
            "createdAt","updatedAt","deletedAt","revision"].contains(key)};true}
    private func ignoredValue():Bool{
        boundedMetadata && discardedDepth<0 && !frames.isEmpty() && top().object && top().phase==2 &&
            (top().tag=="root" || top().tag=="record") && !originalKnownKey(top().tag,top().key)}
    private func finishDiscard():Unit{if(boundedMetadata && discardedDepth==frames.size){discardedDepth= -1}}
    private func keyScalar(bytes:Array<Byte>):Unit{
        if(!boundedMetadata){keyBytes.add(all:bytes);return}
        if(!keyTruncated){if(keyBytes.size+bytes.size<=128){keyBytes.add(all:bytes)}else{keyTruncated=true}}}
    private func keyAscii(byte:Byte):Unit{
        if(!boundedMetadata){keyBytes.add(byte);return}
        if(!keyTruncated){if(keyBytes.size<128){keyBytes.add(byte)}else{keyTruncated=true}}}
    private func top():MemoryEventStreamFrame{frames[frames.size-1]}
    private func expectsValue():Bool{
        if(frames.isEmpty()){return root==0}
        let frame=top();if(frame.object){return frame.phase==2};frame.phase==0 || frame.phase==2
    }
    private func startValue():Unit{
        if(!expectsValue()){memoryEventStreamInvalid("value is outside the original JSON grammar")}
        if(ignoredValue()){
            // Both original codec functions never inspect these field names.
            // Keep one null value in reduced JSON, then discard only the live
            // representation; the separate complete validator scans its bytes.
            metadata.add(all:"null".toArray());discardedDepth=frames.size;nodes++}
        if(!boundedMetadata || discardedDepth<0){nodes++}
        charge(0)
        if(frames.isEmpty()){root=1}else{top().phase=if(top().object){3}else{1}}
    }
    private func scalarDone():Unit{mode=0;if(frames.isEmpty()){root=2};finishDiscard()}
    private func emit(bytes:Array<Byte>):Unit{
        if(stringKey){keyScalar(bytes)}
        match(field){case Some(value)=>value.append(bytes);case None=>()}
    }
    private func emitAscii(byte:Byte):Unit{
        if(stringKey){keyAscii(byte)}
        match(field){case Some(value)=>value.appendAscii(byte);case None=>()}
    }
    private func beginString(position:Int64):Unit{
        stringKey=!frames.isEmpty() && top().object && (top().phase==0 || top().phase==4)
        field=None;keyBytes.clear();keyTruncated=false;stringOffset=position
        if(!stringKey){
            if(frames.size==2 && top().tag=="record" && top().phase==2 && ["content","context","source"].contains(top().key)){
                for(previous in fields where previous.name==top().key){
                    memoryEventStreamInvalid("original JSON repeats a streamed record string key")}
                // Every live prefix/fragment descriptor is paid before its
                // construction, including failed duplicate-input attempts.
                owner.ensureRetainedPeak(1048576+MEMORY_EVENT_STREAM_CHUNK_BYTES*16+
                    (metadata.size+128)*16+nodes*1024+(fields.size+1)*524288)
                field=Some(MemoryStreamText(top().key,position,consume))}
            startValue()
        }
        if(field.isNone() && (!boundedMetadata || !stringKey)){meta(b'"')}
        escape=false;unicodeDigits=0;unicode=0;high=0;lowStep=0;remaining=0;utf8.clear();mode=1
    }
    private func endString(position:Int64):Unit{
        if(remaining!=0 || high!=0 || lowStep!=0){memoryEventStreamInvalid("incomplete original UTF8 or surrogate pair")}
        match(field){case Some(value)=>
            value.finish(position-stringOffset+1);fields.add(value)
            let replacement=quoteUnifiedJson(if(value.bytes==0){""}else{"streamed"}).toArray()
            metadata.add(all:replacement)
            case None=>meta(b'"')}
        if(stringKey){
            let decodedKey=if(keyTruncated){""}else{String.fromUtf8(keyBytes.toArray())}
            if(boundedMetadata && (keyTruncated || !originalKnownKey(top().tag,decodedKey))){
                // Unknown keys remain unique in reduced JSON, without keeping
                // their potentially huge private literals. Full duplicate-key
                // semantics belong to the original-byte validator above.
                if(ignoredKeyCounter==Int64.Max){memoryEventStreamInvalid("ignored field counter overflow")}
                ignoredKeyCounter++;top().key="__ignored_"+ignoredKeyCounter.toString()
            }else{top().key=decodedKey}
            if(boundedMetadata && discardedDepth<0){metadata.add(all:quoteUnifiedJson(top().key).toArray())}
            top().phase=1
        }else{if(frames.isEmpty()){root=2};finishDiscard()}
        field=None;keyBytes.clear();mode=0
    }
    private func stringByte(byte:Byte,position:Int64):Unit{
        // Preserve every ordinary token byte exactly. Streamed string tokens
        // are replaced only after the complete original literal validates.
        if(field.isNone() && byte!=b'"'){meta(byte)}
        if(remaining>0){
            if(byte<0x80 || byte>0xBF){memoryEventStreamInvalid("invalid original UTF8 continuation")}
            scalar=(scalar<<6)|UInt32(byte&0x3F);utf8.add(byte);remaining--
            if(remaining==0){
                if(scalar<minimum || scalar>0x10FFFF || (scalar>=0xD800 && scalar<=0xDFFF)){
                    memoryEventStreamInvalid("invalid original UTF8 scalar")}
                emit(utf8.toArray());utf8.clear()}
            return
        }
        if(unicodeDigits>0){
            unicode=(unicode<<4)|memoryEventStreamHex(byte);unicodeDigits--
            if(unicodeDigits==0){
                if(high!=0){
                    if(unicode<0xDC00 || unicode>0xDFFF){memoryEventStreamInvalid("invalid original low surrogate")}
                    emit(memoryEventStreamScalar(0x10000+((high-0xD800)<<10)+(unicode-0xDC00)));high=0
                }else if(unicode>=0xD800 && unicode<=0xDBFF){high=unicode;lowStep=1}
                else{emit(memoryEventStreamScalar(unicode))}
            };return
        }
        if(lowStep>0){
            if((lowStep==1 && byte!=b'\\') || (lowStep==2 && byte!=b'u')){
                memoryEventStreamInvalid("original high surrogate requires its complete low pair")}
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
                case _=>memoryEventStreamInvalid("invalid original JSON string escape")}
            // A quote following an escape remains inside the literal and
            // must be retained in the ordinary reduced JSON token.
            if(field.isNone() && byte==b'"'){meta(byte)}
            return
        }
        if(byte==b'"'){endString(position);return}
        if(byte==b'\\'){escape=true;return}
        if(byte<0x20){memoryEventStreamInvalid("unescaped original JSON control character")}
        if(byte<0x80){emitAscii(byte);return}
        if(byte>=0xC2 && byte<=0xDF){remaining=1;scalar=UInt32(byte&0x1F);minimum=0x80}
        else if(byte>=0xE0 && byte<=0xEF){remaining=2;scalar=UInt32(byte&0x0F);minimum=0x800}
        else if(byte>=0xF0 && byte<=0xF4){remaining=3;scalar=UInt32(byte&0x07);minimum=0x10000}
        else{memoryEventStreamInvalid("invalid original UTF8 leading byte")}
        utf8.add(byte)
    }
    private func syntax(byte:Byte,position:Int64):Unit{
        if(byte==b' ' || byte==b'\t' || byte==b'\r' || byte==b'\n'){meta(byte);return}
        if(byte==b'"'){beginString(position);return}
        if(byte==b'{' || byte==b'['){
            let tag=if(frames.isEmpty()){"root"}
                else if(frames.size==1 && top().object && top().tag=="root" && top().key=="record"){"record"}else{"other"}
            startValue();if(frames.size>=32){memoryEventStreamInvalid("original event exceeds depth32")}
            frames.add(MemoryEventStreamFrame(byte==b'{',tag));meta(byte);return
        }
        if(byte==b'}' || byte==b']'){
            if(frames.isEmpty() || top().object!=(byte==b'}') ||
                (top().object && top().phase!=0 && top().phase!=3) ||
                (!top().object && top().phase!=0 && top().phase!=1)){
                memoryEventStreamInvalid("original JSON container is incomplete")}
            let _=frames.remove(at:frames.size-1);meta(byte);if(frames.isEmpty()){root=2};finishDiscard();return
        }
        if(byte==b':'){
            if(frames.isEmpty() || !top().object || top().phase!=1){memoryEventStreamInvalid("original JSON key lacks its value")}
            top().phase=2;meta(byte);return
        }
        if(byte==b','){
            if(frames.isEmpty() || (top().object && top().phase!=3) || (!top().object && top().phase!=1)){
                memoryEventStreamInvalid("invalid original JSON comma")}
            top().phase=if(top().object){4}else{2};meta(byte);return
        }
        startValue();mode=2;meta(byte)
    }
    func append(expectedOffset:Int64,bytes:Array<Byte>):Unit{
        if(closed || finished || expectedOffset!=offset || bytes.isEmpty() || bytes.size>MEMORY_EVENT_STREAM_CHUNK_BYTES || bytes.size>expectedBytes-offset){
            memoryEventStreamInvalid("event stream overlaps, skips or exceeds its exact extent")}
        match(validation){case Some(checker)=>checker.append(expectedOffset,bytes);case None=>()}
        charge(bytes.size+128);rawHash.write(bytes)
        for(index in 0..bytes.size){let byte=bytes[index];let position=offset+index
            if(mode==1){stringByte(byte,position)}
            else{
                if(mode==2){
                    if(byte==b' ' || byte==b'\t' || byte==b'\r' || byte==b'\n' || byte==b',' || byte==b']' || byte==b'}'){
                        scalarDone();syntax(byte,position)}else{meta(byte)}
                }else{syntax(byte,position)}
            }
        };offset+=bytes.size;charge(0)
    }
    func complete():MemoryStreamedEvent{
        if(closed || finished || offset!=expectedBytes || mode==1){memoryEventStreamInvalid("original event stream is incomplete")}
        if(mode==2){scalarDone()}
        match(validation){case Some(checker)=>let _=checker.finish();case None=>()}
        if(root!=2 || !frames.isEmpty()){memoryEventStreamInvalid("original event JSON is incomplete")}
        let digest=logicalJsonEncodeHex(rawHash.finish())
        if(digest!=expectedDigest){memoryEventStreamInvalid("complete event differs from its observed hash")}
        charge(128);let raw=String.fromUtf8(metadata.toArray())
        // Retain original parser duplicate-key, numeric, depth and optional
        // field semantics. Only the three fully validated string values were
        // substituted; no event version/operation/record checks are moved to
        // Host and no historical event is skipped because it is inaccessible.
        let decoded=parseUnifiedJson(raw,maxBytes:MEMORY_EVENT_STREAM_MAX_BYTES,maxDepth:32)
        let record=match(memoryV3DecodeEvent(decoded)){
            case Result.Err(error)=>throw PureProviderError(error.code,error.message)
            case Result.Ok(value)=>value}
        finished=true;MemoryStreamedEvent(record,fields.toArray(),expectedBytes,digest)
    }
}
