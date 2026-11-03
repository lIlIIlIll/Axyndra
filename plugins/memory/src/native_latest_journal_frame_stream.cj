package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import stdx.crypto.digest.SHA256
import yjson.*
import yjson_support.*

let MEMORY_LATEST_JOURNAL_FRAME_MAGIC="AXYNDRJ3\n"
let MEMORY_LATEST_JOURNAL_FRAME_HEADER_BYTES:Int64=16384

func memoryLatestJournalFrameInvalid(message:String):Nothing{
    throw PureProviderError("memory.journal_stream_invalid",message)
}
func memoryLatestJournalFrameInteger(value:AgentValue):Int64{
    if(value.unifiedKind!=ValueKind.Number){memoryLatestJournalFrameInvalid("frame integer has another type")}
    let text=value.asNumberText();let number=Int64.parse(text)
    if(number.toString()!=text){memoryLatestJournalFrameInvalid("frame integer is not canonical Int64")};number
}
func memoryLatestJournalFrameAdd(left:Int64,right:Int64):Int64{
    if(left<0 || right<0 || left>Int64.Max-right){memoryLatestJournalFrameInvalid("frame extent overflow")};left+right
}
class MemoryLatestJournalStreamCompletion {
    let reference:PluginDocumentLatestJournalStreamReference
    let revision:Int64
    let rows:Int64
    let events:Int64
    let rawRows:Int64
    let rawEvents:Int64
    init(reference:PluginDocumentLatestJournalStreamReference,revision:Int64,rows:Int64,events:Int64,rawRows:Int64,rawEvents:Int64){
        this.reference=reference;this.revision=revision;this.rows=rows;this.events=events;this.rawRows=rawRows;this.rawEvents=rawEvents}
}

// Native owns the full old codec, including all history before any tool or
// context computation. Host may only replay mechanically paid 64KiB bytes
// from the same actual pinned ReadFact/artifact. Neither a ref nor completion
// grants permission or substitutes for Host/Store Source/fence validation.
class MemoryLatestJournalFrameStreamDecoder {
    private let reference:PluginDocumentLatestJournalStreamReference
    private let requestDigest:String
    private let accessPolicyDigest:String
    private let viewPolicyDigest:String
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
    init(reference:PluginDocumentLatestJournalStreamReference,requestDigest:String,accessPolicyDigest:String,viewPolicyDigest:String,
        annotations:AgentValue,owner:LogicalJsonOwnerReservation,allocate:(Int64)->LogicalJsonOwnerReservation,
        consume!:(MemoryJournalDecodedFrame)->Unit={_=>()},
        consumeText!:(String,Int64,String,Int64,String)->Unit={_,_,_,_,_=>()},current!:()->Unit={=>()}){
        if(!httpIntentDigest(requestDigest) || !httpIntentDigest(accessPolicyDigest) || !httpIntentDigest(viewPolicyDigest) ||
            !httpIntentExactFields(annotations,["workspace_root","settings_root","thread_id","lane_id"])){
            memoryLatestJournalFrameInvalid("frame request has another frozen descriptor")}
        for(field in annotations.fields){if(field.value.unifiedKind!=ValueKind.Text){
            memoryLatestJournalFrameInvalid("frame annotation has another type")}}
        owner.ensureRetainedPeak(1048576+65536*16+16384*32)
        this.reference=reference;this.requestDigest=requestDigest;this.accessPolicyDigest=accessPolicyDigest;this.viewPolicyDigest=viewPolicyDigest
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
        let header=parseUnifiedJson(text,maxBytes:MEMORY_LATEST_JOURNAL_FRAME_HEADER_BYTES,maxDepth:8)
        headerBytes.clear();length=0;digits=0;firstZero=false
        let nextKind=memoryDocumentText(header,"kind")
        let extent=memoryLatestJournalFrameInteger(header.field("body_bytes").getOrThrow())
        if(nextKind=="start"){
            if(started || stage!=0 || extent!=0 ||
                !httpIntentExactFields(header,["kind","schema","body_bytes","request_digest","access_policy_digest","view_policy_digest","revision","annotations"]) ||
                httpIntentText(header,"schema")!="axyndra.row-journal-frames/v3" ||
                httpIntentText(header,"request_digest")!=requestDigest || httpIntentText(header,"access_policy_digest")!=accessPolicyDigest ||
                canonicalAgentValue(header.field("annotations").getOrThrow())!=expectedAnnotations ||
                httpIntentText(header,"view_policy_digest")!=viewPolicyDigest){
                memoryLatestJournalFrameInvalid("stream start differs from its exact observed descriptor")}
            revision=memoryLatestJournalFrameInteger(header.field("revision").getOrThrow())
            if(revision<1){memoryLatestJournalFrameInvalid("logical journal revision is invalid")}
            // The complete projected history count is the only public
            // revision. The ignored SQL/cache fence stays outside Native.
            expectedEvents=revision-1
            started=true;mode=1;return
        }
        if(!started){memoryLatestJournalFrameInvalid("stream body preceded its actual start")}
        if(nextKind=="end"){
            if(stage==2 || extent!=0 || !httpIntentExactFields(header,["kind","body_bytes","rows","events","raw_events"]) ||
                memoryLatestJournalFrameInteger(header.field("rows").getOrThrow())!=rows || rawRows!=rows ||
                memoryLatestJournalFrameInteger(header.field("events").getOrThrow())!=events || events!=expectedEvents ||
                memoryLatestJournalFrameInteger(header.field("raw_events").getOrThrow())!=rawEvents){
                memoryLatestJournalFrameInvalid("end cannot erase missing or substituted history/current frames")}
            stage=2;mode=4;return
        }
        if(nextKind!="event" && nextKind!="row"){memoryLatestJournalFrameInvalid("unsupported frame kind")}
        let visible=memoryDocumentText(header,"visibility")
        if((visible!="raw" && visible!="projection") || (nextKind=="row" && visible!="raw")){
            memoryLatestJournalFrameInvalid("latest rows must disclose only actually readable complete raw records")}
        let fields=["kind","ordinal","visibility","body_bytes","body_sha256"]
        if(!httpIntentExactFields(header,fields) || extent<1 || extent>67108864 ||
            (visible=="projection" && extent>16384) || !httpIntentDigest(httpIntentText(header,"body_sha256"))){
            memoryLatestJournalFrameInvalid("frame extent or exact fields changed")}
        let nextOrdinal=memoryLatestJournalFrameInteger(header.field("ordinal").getOrThrow())
        if(nextKind=="event"){
            if(stage!=0 || nextOrdinal!=events || events>=expectedEvents){memoryLatestJournalFrameInvalid("original history order is incomplete")}
        }else{
            if(stage==2 || events!=expectedEvents || nextOrdinal!=rows){
                memoryLatestJournalFrameInvalid("independent current order is incomplete")};stage=1
        }
        bodyIndex=None
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
                if(event.rawBytes!=bodyBytes || event.digest!=bodyDigest){memoryLatestJournalFrameInvalid("raw original body changed")}
                consume(MemoryJournalDecodedFrame(kind,ordinal,bodyOffset,bodyBytes,bodyDigest,bodyIndex,event))
                if(kind=="event"){rawEvents=memoryLatestJournalFrameAdd(rawEvents,1)}else{rawRows=memoryLatestJournalFrameAdd(rawRows,1)}
            }else{
                let text=String.fromUtf8(projectionBytes.toArray())
                if(text.size!=bodyBytes || modelPolicySha256Text(text)!=bodyDigest){memoryLatestJournalFrameInvalid("private structural body changed")}
                let value=parseUnifiedJson(text,maxBytes:16384,maxDepth:8)
                match(memoryV3ValidateProjectedEventV2(value)){case Result.Ok(_)=>();case Result.Err(error)=>
                    throw PureProviderError(error.code,error.message)}
            }
            if(kind=="event"){events=memoryLatestJournalFrameAdd(events,1)}else{rows=memoryLatestJournalFrameAdd(rows,1)}
            mode=1
        }finally{releaseBody()}
    }
    func append(expectedOffset:Int64,bytes:Array<Byte>):Unit{
        if(closed || completed || expectedOffset!=offset || bytes.isEmpty() || bytes.size>65536 ||
            bytes.size>reference.bytes-offset){memoryLatestJournalFrameInvalid("stream upload extent is not contiguous")}
        current();streamHash.write(bytes);var cursor:Int64=0
        try{
            while(cursor<bytes.size){
                if(mode==4){memoryLatestJournalFrameInvalid("bytes followed the complete end frame")}
                if(mode==3){
                    let size=min(bytes.size-cursor,bodyBytes-bodySeen);let piece=bytes[cursor..cursor+size]
                    if(visibility=="raw"){eventDecoder.getOrThrow().append(bodySeen,piece)}else{projectionBytes.add(all:piece)}
                    cursor+=size;offset=memoryLatestJournalFrameAdd(offset,size);bodySeen+=size
                    if(bodySeen==bodyBytes){finishBody()};continue
                }
                let byte=bytes[cursor];cursor++;offset=memoryLatestJournalFrameAdd(offset,1)
                if(mode==0){
                    let magic=MEMORY_LATEST_JOURNAL_FRAME_MAGIC.toArray()
                    if(magicOffset>=magic.size || byte!=magic[magicOffset]){memoryLatestJournalFrameInvalid("stream magic changed")}
                    magicOffset++;if(magicOffset==magic.size){mode=1};continue
                }
                if(mode==1){
                    if(byte==b':'){
                        if(digits==0 || length<1 || length>16384){memoryLatestJournalFrameInvalid("frame header length is invalid")}
                        mode=2
                    }else{
                        if(byte<b'0' || byte>b'9' || digits>=5 || (digits>0 && firstZero)){
                            memoryLatestJournalFrameInvalid("frame header length is not canonical bounded decimal")}
                        if(digits==0){firstZero=byte==b'0'};digits++;length=length*10+Int64(byte-b'0')
                        if(length>16384){memoryLatestJournalFrameInvalid("frame header exceeds its paid bound")}
                    };continue
                }
                headerBytes.add(byte);if(headerBytes.size==length){takeHeader()}
            }
            current()
        }catch(error:Exception){close();throw error}
    }
    func complete():MemoryLatestJournalStreamCompletion{
        if(closed || completed || !started || mode!=4 || stage!=2 || offset!=reference.bytes){
            memoryLatestJournalFrameInvalid("every history and current body must reach the immutable stream EOF")}
        current();let digest=logicalJsonEncodeHex(streamHash.finish())
        if(digest!=reference.digest){close();memoryLatestJournalFrameInvalid("whole actual stream digest changed")}
        completed=true;MemoryLatestJournalStreamCompletion(reference,revision,rows,events,rawRows,rawEvents)
    }
}
