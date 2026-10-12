package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

let MEMORY_LATEST_CONTEXT_QUERY="axyndra.memory-latest-context-data/v3"
let MEMORY_LATEST_CONTEXT_PREPARATION="axyndra.context-journal-preparation-query/v3"

func memoryLatestContextParameters(value:AgentValue,observed:Bool):Unit{
    memoryDocumentFields(value,if(observed){["schema","query","max_bytes","_axyndra_context_provider"]}
        else{["schema","query","max_bytes"]})
    if(memoryDocumentText(value,"schema")!="axyndra.memory-context-query/v1" ||
        value.field("query").getOrThrow().unifiedKind!=ValueKind.Text){
        memoryLatestJournalFrameInvalid("exact original context parameters required")}
    if(logicalJsonWriteReservationBytes(value,CONTENT_PAYLOAD_MESSAGE_BYTES)>CONTENT_PAYLOAD_MESSAGE_BYTES){
        memoryLatestJournalFrameInvalid("original complete content-message parameter ceiling required")}
    let maximum=documentDataInteger(value,"max_bytes")
    if(maximum<1 || maximum>65536){memoryLatestJournalFrameInvalid("original bounded context maximum required")}
    if(observed){
        let identity=value.field("_axyndra_context_provider").getOrThrow()
        memoryDocumentFields(identity,["namespace","package_digest","generation","provider"])
        if(!httpServicePluginNamespace(memoryDocumentText(identity,"namespace")) ||
            !memoryContextPackageDigest(memoryDocumentText(identity,"package_digest")) ||
            memoryDocumentText(identity,"provider")!="memory_context"){
            memoryLatestJournalFrameInvalid("exact observed final typed context provider required")}
        let serial=memoryDocumentText(identity,"generation")
        let generation=UInt64.parse(serial)
        if(generation<1u64 || generation.toString()!=serial){memoryLatestJournalFrameInvalid("canonical observed generation required")}
    }
}
func memoryLatestContextPrepare(value:AgentValue):AgentValue{
    let descriptor=value.field("input_payload").isSome()
    memoryDocumentFields(value,if(descriptor){["schema","provider","input_payload"]}else{["schema","provider","input"]})
    if(memoryDocumentText(value,"schema")!=MEMORY_LATEST_CONTEXT_PREPARATION ||
        memoryDocumentText(value,"provider")!="memory_context"){
        memoryLatestJournalFrameInvalid("exact new stream context preparation required")}
    if(descriptor){
        let input=value.field("input_payload").getOrThrow();memoryDocumentFields(input,["bytes","sha256"])
        let bytes=documentDataInteger(input,"bytes")
        if(bytes<2 || bytes>CONTENT_PAYLOAD_MESSAGE_BYTES || !httpIntentDigest(memoryDocumentText(input,"sha256"))){
            memoryLatestJournalFrameInvalid("original complete parameter descriptor required")}
        // Descriptive bytes only: full parameters are checked by the existing
        // Native upload/hash/UTF8/full-JSON EOF before any history computation.
    }else{memoryLatestContextParameters(value.field("input").getOrThrow(),false)}
    // An untrusted logical selector. Host freezes the operator purpose and
    // actual Source/approval before any byte, never a Native read grant.
    objectValue([ValueField("document_read",objectValue([ValueField("key",textValue(MEMORY_JOURNAL_KEY)),
        ValueField("stream",textValue("event-latest-structural-read"))]))])
}

// One Native pure worker owns one active computation. Input/reference data
// does not authorize a read: Host's actual completed-fact proof supplies every
// byte and independently verifies every replay's hash/EOF/current fence.
class MemoryLatestContextData {
    private let allocate:(Int64)->LogicalJsonOwnerReservation
    private let clock:()->Int64
    private let renderClock:()->Int64
    private var sequence:Int64=0
    private var lastSequence:Int64=0
    private var pass:Int64=0
    private var offset:Int64=0
    private var hasPass=false
    private var ready=false
    private var outputOffset:Int64=0
    private var output:?Array<Byte>=None
    private var outputDigest=""
    private var reference:?PluginDocumentLatestJournalStreamReference=None
    private var requestDigest=""
    private var accessDigest=""
    private var viewDigest=""
    private var queryText=""
    private var maximum:Int64=0
    private var now:Int64=0
    private var parameterOwner:?LogicalJsonOwnerReservation=None
    private var parameterUpload:?MemoryDocumentUpload=None
    private var parameterBytes:Int64=0
    private var parametersReady=false
    private var bootstrap:?ArrayList<Byte>=None
    private var bootstrapOwner:?LogicalJsonOwnerReservation=None
    private var collector:?MemoryLatestJournalContextCollector=None
    init(allocate!:(Int64)->LogicalJsonOwnerReservation={_=>reservePurePolicyRawData()},
        clock!:()->Int64={=>DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()},
        renderClock!:()->Int64={=>DateTime.nowUTC().toUnixTimeStamp().toMilliseconds()}){
        this.allocate=allocate;this.clock=clock;this.renderClock=renderClock}
    func close():Unit{
        // Byte/DOM references leave before their actual reservation closes.
        output=None;bootstrap=None;parameterUpload=None;reference=None;queryText="";outputDigest=""
        match(collector){case Some(value)=>value.close();case None=>()};collector=None
        match(parameterOwner){case Some(value)=>value.close();case None=>()};parameterOwner=None
        match(bootstrapOwner){case Some(value)=>value.close();case None=>()};bootstrapOwner=None
        sequence=0;pass=0;offset=0;hasPass=false;ready=false;outputOffset=0
        requestDigest="";accessDigest="";viewDigest="";maximum=0;now=0;parameterBytes=0;parametersReady=false
        // lastSequence is the physical worker lifetime counter, never reset.
    }
    private func current(value:AgentValue):Unit{
        if(sequence<1 || documentDataInteger(value,"sequence")!=sequence){
            memoryLatestJournalFrameInvalid("another computation owns this Native stream state")}
    }
    private func live():Unit{
        if(sequence<1){memoryLatestJournalFrameInvalid("Native stream owner is no longer active")}
    }
    private func installParameters(parameters:AgentValue):Unit{
        memoryLatestContextParameters(parameters,true)
        let text=memoryDocumentText(parameters,"query");let limit=documentDataInteger(parameters,"max_bytes")
        let actualNow=clock();if(actualNow<1){memoryLatestJournalFrameInvalid("actual Native retrieval clock required")}
        bootstrapOwner.getOrThrow().ensureRetainedPeak(2097152+text.size*3)
        queryText=text;maximum=limit;now=actualNow;parametersReady=true
    }
    private func begin(value:AgentValue):AgentValue{
        let chunked=value.field("input_payload").isSome()
        memoryDocumentFields(value,if(chunked){["schema","action","sequence","input_payload","stream"]}
            else{["schema","action","sequence","input","stream"]})
        if(sequence!=0){memoryLatestJournalFrameInvalid("another Native stream computation is still live")}
        let serial=documentDataInteger(value,"sequence")
        if(serial<=lastSequence || serial==Int64.Max){memoryLatestJournalFrameInvalid("stale or exhausted Native computation sequence")}
        let charge=allocate(65536)
        try{
            let source=value.field("stream").getOrThrow()
            memoryDocumentFields(source,["reference","request_digest","access_policy_digest","view_policy_digest"])
            let selected=parsePluginDocumentLatestJournalStreamReference(source.field("reference").getOrThrow()).value().getOrThrow()
            let request=memoryDocumentText(source,"request_digest");let access=memoryDocumentText(source,"access_policy_digest")
            let view=memoryDocumentText(source,"view_policy_digest")
            if(!httpIntentDigest(request) || !httpIntentDigest(access) || !httpIntentDigest(view)){
                memoryLatestJournalFrameInvalid("canonical observed stream digests required")}
            // This is the original content-message ceiling, separate from
            // the196608-byte RPC frame. Large original query text is uploaded
            // as exact sequential64KiB bytes and decoded only after full EOF.
            charge.ensureRetainedPeak(2097152)
            reference=Some(selected);requestDigest=request;accessDigest=access;viewDigest=view
            bootstrapOwner=Some(charge);sequence=serial;lastSequence=serial
            if(chunked){
                let descriptor=value.field("input_payload").getOrThrow();memoryDocumentFields(descriptor,["bytes","sha256"])
                let bytes=documentDataInteger(descriptor,"bytes");let digest=memoryDocumentText(descriptor,"sha256")
                if(bytes<2 || bytes>CONTENT_PAYLOAD_MESSAGE_BYTES || !httpIntentDigest(digest)){
                    memoryLatestJournalFrameInvalid("parameter upload exceeds its original content-message codec")}
                // This temporary phase is an actually separate reservation,
                // not borrowed credit. It stays live through complete UTF8/DOM
                // and is retired only after retained scalar handoff returns.
                let phase=allocate(65536);parameterOwner=Some(phase)
                phase.ensureRetainedPeak(2097152+bytes*4)
                parameterBytes=bytes;parameterUpload=Some(MemoryDocumentUpload("context-parameters",bytes,digest))
            }else{installParameters(value.field("input").getOrThrow())}
            bootstrap=Some(ArrayList<Byte>())
            objectValue([ValueField("accepted",boolValue(true))])
        }catch(error:Exception){charge.close();close();throw error}
    }
    private func appendParameters(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","offset","bytes_hex"])
        if(parametersReady || parameterUpload.isNone() || collector.isSome()){
            memoryLatestJournalFrameInvalid("no mutable parameter upload belongs to this computation")}
        parameterUpload.getOrThrow().append(documentDataInteger(value,"offset"),memoryDocumentText(value,"bytes_hex"))
        objectValue([ValueField("accepted",boolValue(true))])
    }
    private func finishParameters(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence"])
        if(parametersReady || parameterUpload.isNone() || collector.isSome()){
            memoryLatestJournalFrameInvalid("parameter EOF is single use before stream data")}
        let raw=parameterUpload.getOrThrow().complete()
        let nodes=logicalJsonNodeCount(raw)
        parameterOwner.getOrThrow().ensureRetainedPeak(2097152+parameterBytes*8+nodes*512)
        parameterOwner.getOrThrow().ensureDecoded(raw.size,nodes)
        let parameters=parseUnifiedJson(raw,maxBytes:CONTENT_PAYLOAD_MESSAGE_BYTES,maxDepth:32)
        installParameters(parameters)
        // Retained query/provider scalar data and annotations remain paid by
        // this same owner. No raw parameter upload or large DOM escapes.
        parameterUpload=None
        objectValue([ValueField("accepted",boolValue(true))])
    }
    private func annotations():?AgentValue{
        let bytes=bootstrap.getOrThrow();let magic=MEMORY_LATEST_JOURNAL_FRAME_MAGIC.toArray()
        for(index in 0..min(bytes.size,magic.size)){
            if(bytes[index]!=magic[index]){memoryLatestJournalFrameInvalid("stream bootstrap magic changed")}}
        if(bytes.size<=magic.size){return None}
        var cursor=magic.size;var length:Int64=0;var digits:Int64=0;var firstZero=false
        while(cursor<bytes.size && bytes[cursor]!=b':'){
            let byte=bytes[cursor]
            if(byte<b'0' || byte>b'9' || digits>=5 || (digits>0 && firstZero)){
                memoryLatestJournalFrameInvalid("stream start header length is not canonical")}
            if(digits==0){firstZero=byte==b'0'};digits++;length=length*10+Int64(byte-b'0');cursor++
            if(length>16384){memoryLatestJournalFrameInvalid("stream start header exceeds its original bound")}
        }
        if(cursor==bytes.size){return None}
        if(digits==0 || length<1){memoryLatestJournalFrameInvalid("stream start header is empty")};cursor++
        if(bytes.size-cursor<length){return None}
        let raw=bytes.toArray();let text=String.fromUtf8(raw[cursor..cursor+length])
        let header=parseUnifiedJson(text,maxBytes:16384,maxDepth:8)
        memoryDocumentFields(header,["kind","schema","body_bytes","request_digest","access_policy_digest","view_policy_digest","revision","annotations"])
        if(memoryDocumentText(header,"kind")!="start" || memoryDocumentText(header,"schema")!="axyndra.row-journal-frames/v3" ||
            documentDataInteger(header,"body_bytes")!=0 || memoryDocumentText(header,"request_digest")!=requestDigest ||
            memoryDocumentText(header,"access_policy_digest")!=accessDigest || memoryDocumentText(header,"view_policy_digest")!=viewDigest ||
            documentDataInteger(header,"revision")<1){memoryLatestJournalFrameInvalid("exact first actual stream header required")}
        let result=header.field("annotations").getOrThrow()
        memoryDocumentFields(result,["workspace_root","settings_root","thread_id","lane_id"])
        for(field in result.fields){if(field.value.unifiedKind!=ValueKind.Text){memoryLatestJournalFrameInvalid("original stream annotation text required")}}
        // This untrusted header is validated again by the complete decoder
        // and full reference hash before any context output can be produced.
        Some(result)
    }
    private func append(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","offset","bytes_hex"])
        if(!parametersReady || ready || documentDataInteger(value,"offset")!=offset){memoryLatestJournalFrameInvalid("stream chunk is stale or overlaps")}
        let hex=memoryDocumentText(value,"bytes_hex")
        if(hex.size<2 || hex.size%2!=0 || hex.size>131072 || hex.size/2>reference.getOrThrow().bytes-offset){
            memoryLatestJournalFrameInvalid("stream chunk exceeds its existing64KiB bound")}
        // The actual incoming wire owner holds the hexadecimal text. The
        // collector/bootstrap owner prepays these raw <=64KiB copies.
        let encoded=hex.toArray();let bytes=Array<Byte>(encoded.size/2,repeat:0)
        for(index in 0..bytes.size){bytes[index]=UInt8(documentDataNibble(encoded[index*2])*16+documentDataNibble(encoded[index*2+1]))}
        if(collector.isNone()){
            let prefix=bootstrap.getOrThrow()
            if(prefix.size+bytes.size>98304){memoryLatestJournalFrameInvalid("bounded first-header bootstrap did not complete")}
            prefix.add(all:bytes)
            match(annotations()){case None=>offset+=bytes.size;return objectValue([ValueField("accepted",boolValue(true))])
                case Some(metadata)=>
                    let charge=bootstrapOwner.getOrThrow()
                    let actual=MemoryLatestJournalContextCollector(reference.getOrThrow(),requestDigest,accessDigest,viewDigest,
                        metadata,queryText,maximum,now,allocate:allocate,current:{=>live()},renderNow:renderClock,retainedOwner:Some(charge),compactQuery:true)
                    collector=Some(actual);bootstrapOwner=None
                    // The new normalized query is prepaid in the collector.
                    // Retire the protocol's original scalar before scoring.
                    queryText=""
                    actual.beginPass();hasPass=true
                    let retained=prefix.toArray();var at:Int64=0
                    while(at<retained.size){let end=min(retained.size,at+65536);actual.append(at,retained[at..end]);at=end}
                    bootstrap=None
            }
        }else{
            if(!hasPass){if(offset!=0){memoryLatestJournalFrameInvalid("next replay did not start at zero")}
                collector.getOrThrow().beginPass();hasPass=true}
            collector.getOrThrow().append(offset,bytes)
        }
        offset+=bytes.size;objectValue([ValueField("accepted",boolValue(true))])
    }
    private func end(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","pass"])
        if(ready || !hasPass || collector.isNone() || offset!=reference.getOrThrow().bytes ||
            documentDataInteger(value,"pass")!=pass){memoryLatestJournalFrameInvalid("complete exact replay EOF required")}
        let finished=collector.getOrThrow().finishPass();hasPass=false
        if(!finished){
            if(pass==Int64.Max){memoryLatestJournalFrameInvalid("replay index overflow")};pass++;offset=0
            return objectValue([ValueField("ready",boolValue(false))])}
        let raw=collector.getOrThrow().freezeOutput();output=Some(raw);outputDigest=modelPolicySha256(raw);ready=true
        objectValue([ValueField("ready",boolValue(true)),ValueField("output",objectValue([
            ValueField("bytes",integerValue(raw.size)),ValueField("sha256",textValue(outputDigest))]))])
    }
    private func download(value:AgentValue):AgentValue{
        memoryDocumentFields(value,["schema","action","sequence","offset","max_bytes"])
        let maximum=documentDataInteger(value,"max_bytes")
        if(!ready || output.isNone() || documentDataInteger(value,"offset")!=outputOffset ||
            outputOffset>=output.getOrThrow().size || maximum<1 || maximum>16384){
            memoryLatestJournalFrameInvalid("final output download is exact and bounded")}
        let raw=output.getOrThrow();let end=min(raw.size,outputOffset+maximum)
        let result=objectValue([ValueField("offset",integerValue(outputOffset)),
            ValueField("bytes_hex",textValue(logicalJsonEncodeHex(raw[outputOffset..end]))),ValueField("eof",boolValue(end==raw.size))])
        outputOffset=end;result
    }
    func query(value:AgentValue):AgentValue{
        if(memoryDocumentText(value,"schema")!=MEMORY_LATEST_CONTEXT_QUERY){memoryLatestJournalFrameInvalid("unknown Native context stream protocol")}
        let action=memoryDocumentText(value,"action")
        if(action=="begin"){return begin(value)}
        // A wrong sequence cannot destroy a different active computation.
        current(value)
        try{
            if(action=="append_input"){return appendParameters(value)}
            if(action=="finish_input"){
                let result=finishParameters(value)
                // finishParameters has returned: its raw text/large DOM and
                // byte arrays no longer escape. Retained query metadata was
                // prepaid in bootstrapOwner before this actual phase release.
                match(parameterOwner){case Some(phase)=>phase.close();parameterOwner=None;case None=>()}
                return result}
            if(action=="append"){return append(value)}
            if(action=="end"){return end(value)}
            if(action=="download"){return download(value)}
            if(action=="release"){
                memoryDocumentFields(value,["schema","action","sequence"])
                if(!ready || output.isNone() || outputOffset!=output.getOrThrow().size){
                    memoryLatestJournalFrameInvalid("full final output consumer ACK required before release")}
                close();return objectValue([ValueField("released",boolValue(true))])}
            memoryLatestJournalFrameInvalid("unknown exact Native context stream action")
        }catch(error:Exception){close();throw error}
    }
}
