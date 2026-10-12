package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

let MEMORY_JOURNAL_FRAME_MAGIC="AXYNDRJ2\n"
let MEMORY_JOURNAL_FRAME_HEADER_BYTES:Int64=16384

func memoryJournalFrameInvalid(message:String):Nothing{
    throw PureProviderError("memory.journal_stream_invalid",message)
}
func memoryJournalFrameInteger(value:AgentValue):Int64{
    if(value.unifiedKind!=ValueKind.Number){memoryJournalFrameInvalid("frame integer has another type")}
    let text=value.asNumberText();let number=Int64.parse(text)
    if(number.toString()!=text){memoryJournalFrameInvalid("frame integer is not canonical Int64")};number
}
func memoryJournalFrameAdd(left:Int64,right:Int64):Int64{
    if(left<0 || right<0 || left>Int64.Max-right){memoryJournalFrameInvalid("frame extent overflow")};left+right
}
func memoryJournalFrameStateValid(value:AgentValue):Bool{
    try{
        if(!httpIntentExactFields(value,["codec","rows","events","payload_bytes","sequence","sequence_present","sha256"]) ||
            httpIntentText(value,"codec")!="fixed-cells/v2" || !httpIntentDigest(httpIntentText(value,"sha256")) ||
            value.field("sequence_present").getOrThrow().unifiedKind!=ValueKind.Boolean){return false}
        let rows=memoryJournalFrameInteger(value.field("rows").getOrThrow())
        let events=memoryJournalFrameInteger(value.field("events").getOrThrow())
        let payload=memoryJournalFrameInteger(value.field("payload_bytes").getOrThrow())
        let _=memoryJournalFrameInteger(value.field("sequence").getOrThrow())
        rows>=0 && events>=0 && payload>=0
    }catch(_:Exception){false}
}

// This callback value describes Native-decoded data from one body of the
// immutable actual stream. It grants no read/write and is valid only during
// the callback. A coordinator retaining a record, prefix or descriptor must
// reserve its own live business owner before the decoder releases this body.
class MemoryJournalDecodedFrame {
    let kind:String
    let ordinal:Int64
    let bodyOffset:Int64
    let bodyBytes:Int64
    let bodyDigest:String
    let index:?AgentValue
    let event:MemoryStreamedEvent
    init(kind:String,ordinal:Int64,bodyOffset:Int64,bodyBytes:Int64,bodyDigest:String,
        index:?AgentValue,event:MemoryStreamedEvent){
        this.kind=kind;this.ordinal=ordinal;this.bodyOffset=bodyOffset;this.bodyBytes=bodyBytes
        this.bodyDigest=bodyDigest;this.index=index;this.event=event}
}
class MemoryJournalStreamCompletion {
    let reference:PluginDocumentJournalStreamReference
    let revision:Int64
    let rows:Int64
    let events:Int64
    let rawRows:Int64
    let rawEvents:Int64
    init(reference:PluginDocumentJournalStreamReference,revision:Int64,rows:Int64,events:Int64,rawRows:Int64,rawEvents:Int64){
        this.reference=reference;this.revision=revision;this.rows=rows;this.events=events;this.rawRows=rawRows;this.rawEvents=rawEvents}
}

// Native owns the full old codec, including all history before any tool or
// context computation. Host may only replay mechanically paid 64KiB bytes
// from the same actual pinned ReadFact/artifact. Neither a ref nor completion
// grants permission or substitutes for Host/Store Source/fence validation.
class MemoryJournalFrameStreamDecoder {
    private let reference:PluginDocumentJournalStreamReference
    private let requestDigest:String
    private let accessPolicyDigest:String
    private let expectedAnnotations:String
    private let owner:LogicalJsonOwnerReservation
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let consume:(MemoryJournalDecodedFrame)->Unit
    private let consumeText:(String,Int64,String,Int64,String)->Unit
    private let current:()->Unit
    private let streamHash=SHA256()
    private let headerBytes=ArrayList<Byte>()
    private let projectionBytes=ArrayList<Byte>()
    private var offset:Int64=0
    private var magicOffset:Int64=0
    private var mode:Int64=0 // magic, decimal header length, header, body, end
    private var length:Int64=0
    private var digits:Int64=0
    private var firstZero=false
    private var started=false
    private var completed=false
    private var closed=false
    private var stage:Int64=0 // events, independent current rows, end
    private var stateText=""
    private var expectedRows:Int64=0
    private var expectedEvents:Int64=0
    private var revision:Int64=0
    private var rows:Int64=0
    private var events:Int64=0
    private var rawRows:Int64=0
    private var rawEvents:Int64=0
    private var kind=""
    private var ordinal:Int64=0
    private var visibility=""
    private var bodyBytes:Int64=0
    private var bodyOffset:Int64=0
    private var bodySeen:Int64=0
    private var bodyDigest=""
    private var bodyIndex:?AgentValue=None
    private var eventDecoder:?MemoryEventStreamDecoder=None
    private var eventOwner:?LogicalJsonOwnerReservation=None
    init(reference:PluginDocumentJournalStreamReference,requestDigest:String,accessPolicyDigest:String,
        annotations:AgentValue,owner:LogicalJsonOwnerReservation,allocate:(Int64)->LogicalJsonOwnerReservation,
        consume!:(MemoryJournalDecodedFrame)->Unit={_=>()},
        consumeText!:(String,Int64,String,Int64,String)->Unit={_,_,_,_,_=>()},current!:()->Unit={=>()}){
        if(!httpIntentDigest(requestDigest) || !httpIntentDigest(accessPolicyDigest) ||
            !httpIntentExactFields(annotations,["workspace_root","settings_root","thread_id","lane_id"])){
            memoryJournalFrameInvalid("frame request has another frozen descriptor")}
        for(field in annotations.fields){if(field.value.unifiedKind!=ValueKind.Text){
            memoryJournalFrameInvalid("frame annotation has another type")}}
        owner.ensureRetainedPeak(1048576+65536*16+16384*32)
        this.reference=reference;this.requestDigest=requestDigest;this.accessPolicyDigest=accessPolicyDigest
        this.expectedAnnotations=canonicalAgentValue(annotations);this.owner=owner;this.allocate=allocate
        this.consume=consume;this.consumeText=consumeText;this.current=current
    }
    private func releaseBody():Unit{
        match(eventDecoder){case Some(value)=>value.close();case None=>()};eventDecoder=None
        match(eventOwner){case Some(value)=>value.close();case None=>()};eventOwner=None
        projectionBytes.clear();bodyIndex=None
    }
    func close():Unit{if(!closed){closed=true;releaseBody();headerBytes.clear()}}
    private func takeHeader():Unit{
        current()
        // The fixed owner was paid before UTF8/DOM and header copies coexist.
        let text=String.fromUtf8(headerBytes.toArray())
        let header=parseUnifiedJson(text,maxBytes:MEMORY_JOURNAL_FRAME_HEADER_BYTES,maxDepth:8)
        headerBytes.clear();length=0;digits=0;firstZero=false
        let nextKind=memoryDocumentText(header,"kind")
        let extent=memoryJournalFrameInteger(header.field("body_bytes").getOrThrow())
        if(nextKind=="start"){
            if(started || stage!=0 || extent!=0 ||
                !httpIntentExactFields(header,["kind","schema","body_bytes","request_digest","access_policy_digest","revision","annotations","state"]) ||
                httpIntentText(header,"schema")!="axyndra.row-journal-frames/v2" ||
                httpIntentText(header,"request_digest")!=requestDigest || httpIntentText(header,"access_policy_digest")!=accessPolicyDigest ||
                canonicalAgentValue(header.field("annotations").getOrThrow())!=expectedAnnotations ||
                !memoryJournalFrameStateValid(header.field("state").getOrThrow())){
                memoryJournalFrameInvalid("stream start differs from its exact observed descriptor")}
            revision=memoryJournalFrameInteger(header.field("revision").getOrThrow())
            if(revision<1){memoryJournalFrameInvalid("logical journal revision is invalid")}
            let state=header.field("state").getOrThrow();stateText=canonicalAgentValue(state)
            expectedRows=memoryJournalFrameInteger(state.field("rows").getOrThrow())
            expectedEvents=memoryJournalFrameInteger(state.field("events").getOrThrow())
            started=true;mode=1;return
        }
        if(!started){memoryJournalFrameInvalid("stream body preceded its actual start")}
        if(nextKind=="end"){
            if(stage==2 || extent!=0 || !httpIntentExactFields(header,["kind","body_bytes","rows","events","raw_rows","raw_events","state"]) ||
                memoryJournalFrameInteger(header.field("rows").getOrThrow())!=rows || rows!=expectedRows ||
                memoryJournalFrameInteger(header.field("events").getOrThrow())!=events || events!=expectedEvents ||
                memoryJournalFrameInteger(header.field("raw_rows").getOrThrow())!=rawRows ||
                memoryJournalFrameInteger(header.field("raw_events").getOrThrow())!=rawEvents ||
                canonicalAgentValue(header.field("state").getOrThrow())!=stateText){
                memoryJournalFrameInvalid("end cannot erase missing or substituted history/current frames")}
            stage=2;mode=4;return
        }
        if(nextKind!="event" && nextKind!="row"){memoryJournalFrameInvalid("unsupported frame kind")}
        let visible=memoryDocumentText(header,"visibility")
        if(visible!="raw" && visible!="projection"){memoryJournalFrameInvalid("unsupported body disclosure")}
        let withIndex=nextKind=="row" && visible=="raw"
        let fields=if(withIndex){["kind","ordinal","visibility","body_bytes","body_sha256","index"]}
            else{["kind","ordinal","visibility","body_bytes","body_sha256"]}
        if(!httpIntentExactFields(header,fields) || extent<1 || extent>67108864 ||
            (visible=="projection" && extent>16384) || !httpIntentDigest(httpIntentText(header,"body_sha256"))){
            memoryJournalFrameInvalid("frame extent or exact fields changed")}
        let nextOrdinal=memoryJournalFrameInteger(header.field("ordinal").getOrThrow())
        if(nextKind=="event"){
            if(stage!=0 || nextOrdinal!=events || events>=expectedEvents){memoryJournalFrameInvalid("original history order is incomplete")}
        }else{
            if(stage==2 || events!=expectedEvents || nextOrdinal!=rows || rows>=expectedRows){
                memoryJournalFrameInvalid("independent current order is incomplete")};stage=1
        }
        if(withIndex){
            let index=header.field("index").getOrThrow()
            if(!httpIntentExactFields(index,["key_bytes","key_sha256","revision","first_event_id"]) ||
                memoryJournalFrameInteger(index.field("key_bytes").getOrThrow())<0 || !httpIntentDigest(httpIntentText(index,"key_sha256"))){
                memoryJournalFrameInvalid("current index descriptor changed")}
            let _=memoryJournalFrameInteger(index.field("revision").getOrThrow())
            let first=index.field("first_event_id").getOrThrow()
            if(first.unifiedKind!=ValueKind.Null){let _=memoryJournalFrameInteger(first)}
            bodyIndex=Some(index)
        }else{bodyIndex=None}
        kind=nextKind;ordinal=nextOrdinal;visibility=visible;bodyBytes=extent
        bodyDigest=httpIntentText(header,"body_sha256");bodySeen=0;bodyOffset=offset;mode=3
        if(visible=="raw"){
            let lease=allocate(65536)
            try{
                let actualKind=nextKind;let actualOrdinal=nextOrdinal
                eventDecoder=Some(MemoryEventStreamDecoder(extent,bodyDigest,lease,boundedMetadata:true,
                    validationAllocate:allocate,consume:{field,fieldOffset,text=>consumeText(actualKind,actualOrdinal,field,fieldOffset,text)}))
                eventOwner=Some(lease)
            }catch(error:Exception){lease.close();throw error}
        }
    }
    private func finishBody():Unit{
        current()
        try{
            if(visibility=="raw"){
                let event=eventDecoder.getOrThrow().complete()
                if(event.rawBytes!=bodyBytes || event.digest!=bodyDigest){memoryJournalFrameInvalid("raw original body changed")}
                consume(MemoryJournalDecodedFrame(kind,ordinal,bodyOffset,bodyBytes,bodyDigest,bodyIndex,event))
                if(kind=="event"){rawEvents=memoryJournalFrameAdd(rawEvents,1)}else{rawRows=memoryJournalFrameAdd(rawRows,1)}
            }else{
                let text=String.fromUtf8(projectionBytes.toArray())
                if(text.size!=bodyBytes || modelPolicySha256Text(text)!=bodyDigest){memoryJournalFrameInvalid("private structural body changed")}
                let value=parseUnifiedJson(text,maxBytes:16384,maxDepth:8)
                match(memoryV3ValidateProjectedEventV2(value)){case Result.Ok(_)=>();case Result.Err(error)=>
                    throw PureProviderError(error.code,error.message)}
            }
            if(kind=="event"){events=memoryJournalFrameAdd(events,1)}else{rows=memoryJournalFrameAdd(rows,1)}
            mode=1
        }finally{releaseBody()}
    }
    func append(expectedOffset:Int64,bytes:Array<Byte>):Unit{
        if(closed || completed || expectedOffset!=offset || bytes.isEmpty() || bytes.size>65536 ||
            bytes.size>reference.bytes-offset){memoryJournalFrameInvalid("stream upload extent is not contiguous")}
        current();streamHash.write(bytes);var cursor:Int64=0
        try{
            while(cursor<bytes.size){
                if(mode==4){memoryJournalFrameInvalid("bytes followed the complete end frame")}
                if(mode==3){
                    let size=min(bytes.size-cursor,bodyBytes-bodySeen);let piece=bytes[cursor..cursor+size]
                    if(visibility=="raw"){eventDecoder.getOrThrow().append(bodySeen,piece)}else{projectionBytes.add(all:piece)}
                    cursor+=size;offset=memoryJournalFrameAdd(offset,size);bodySeen+=size
                    if(bodySeen==bodyBytes){finishBody()};continue
                }
                let byte=bytes[cursor];cursor++;offset=memoryJournalFrameAdd(offset,1)
                if(mode==0){
                    let magic=MEMORY_JOURNAL_FRAME_MAGIC.toArray()
                    if(magicOffset>=magic.size || byte!=magic[magicOffset]){memoryJournalFrameInvalid("stream magic changed")}
                    magicOffset++;if(magicOffset==magic.size){mode=1};continue
                }
                if(mode==1){
                    if(byte==b':'){
                        if(digits==0 || length<1 || length>16384){memoryJournalFrameInvalid("frame header length is invalid")}
                        mode=2
                    }else{
                        if(byte<b'0' || byte>b'9' || digits>=5 || (digits>0 && firstZero)){
                            memoryJournalFrameInvalid("frame header length is not canonical bounded decimal")}
                        if(digits==0){firstZero=byte==b'0'};digits++;length=length*10+Int64(byte-b'0')
                        if(length>16384){memoryJournalFrameInvalid("frame header exceeds its paid bound")}
                    };continue
                }
                headerBytes.add(byte);if(headerBytes.size==length){takeHeader()}
            }
            current()
        }catch(error:Exception){close();throw error}
    }
    func complete():MemoryJournalStreamCompletion{
        if(closed || completed || !started || mode!=4 || stage!=2 || offset!=reference.bytes){
            memoryJournalFrameInvalid("every history and current body must reach the immutable stream EOF")}
        current();let digest=logicalJsonEncodeHex(streamHash.finish())
        if(digest!=reference.digest){close();memoryJournalFrameInvalid("whole actual stream digest changed")}
        completed=true;MemoryJournalStreamCompletion(reference,revision,rows,events,rawRows,rawEvents)
    }
}
