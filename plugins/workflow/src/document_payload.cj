package workflow_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

let WORKFLOW_DOCUMENT_QUERY = "axyndra.document-data-query/v1"
let WORKFLOW_DOCUMENT_CHUNK: Int64 = 65536

func documentDataInteger(value: AgentValue, name: String): Int64 {
    let field=value.field(name).getOrThrow()
    if(field.unifiedKind!=ValueKind.Number){throw PureProviderError("document.data_shape","integer required")}
    let parsed=Int64.parse(field.asNumberText())
    if(parsed<0 || parsed.toString()!=field.asNumberText()){throw PureProviderError("document.data_shape","canonical nonnegative integer required")}
    parsed
}
func documentDataName(value: String): Bool {
    if(value=="" || value.size>128){return false}
    for(b in value.toArray() where !((b>=b'a' && b<=b'z') || (b>=b'A' && b<=b'Z') ||
        (b>=b'0' && b<=b'9') || b==b'_' || b==b'-' || b==b'.')){return false}
    true
}
func documentDataNibble(value: Byte): Int64 {
    if(value>=b'0' && value<=b'9'){return Int64(value-b'0')}
    if(value>=b'a' && value<=b'f'){return Int64(value-b'a')+10}
    throw PureProviderError("document.data_chunk","lowercase canonical hexadecimal required")
}

class WorkflowDocumentUpload {
    let id:String
    let bytes:Int64
    let digest:String
    var data: ?Array<Byte>
    var text:?String=None
    private var received:Int64=0
    init(id:String,bytes:Int64,digest:String){
        this.id=id;this.bytes=bytes;this.digest=digest
        this.data=Some(Array<Byte>(bytes,repeat:0))
    }
    func append(offset:Int64,hex:String):Unit {
        if(text.isSome() || offset!=received || hex.size==0 || hex.size%2!=0 || hex.size>WORKFLOW_DOCUMENT_CHUNK*2 ||
            hex.size/2>bytes-received){throw PureProviderError("document.data_chunk","chunk overlaps, repeats or exceeds its declaration")}
        let target=data.getOrThrow()
        // The original extent/offset checks prove every pair and destination
        // index. Reuse the logical receiver's synchronous pinned decoder;
        // neither pointer escapes, and even invalid hex unpins both arrays.
        unsafe {
            let source=acquireArrayRawData(hex.rawData())
            try {
                let destination=acquireArrayRawData(target)
                try {
                    for(i in 0..hex.size/2){
                        let high=documentDataNibble(source.pointer.read(i*2))
                        let low=documentDataNibble(source.pointer.read(i*2+1))
                        destination.pointer.write(offset+i,UInt8(high*16+low))
                    }
                } finally {releaseArrayRawData(destination)}
            } finally {releaseArrayRawData(source)}
        }
        received+=hex.size/2
    }
    func complete():String {
        if(text.isSome()){return text.getOrThrow()}
        if(received!=bytes){throw PureProviderError("document.data_incomplete","all declared bytes are required")}
        let raw=data.getOrThrow()
        if(modelPolicySha256(raw)!=digest){throw PureProviderError("document.data_hash","uploaded data differs from the frozen content digest")}
        let value=String.fromUtf8(raw);text=Some(value);data=None;value
    }
}

class WorkflowDocumentDownload {
    let id:String
    let bytes:Array<Byte>
    let digest:String
    var offset:Int64=0
    var finished=false
    init(id:String,text:String){let raw=text.toArray();this.id=id;this.bytes=raw;this.digest=modelPolicySha256(raw)}
    func descriptor():AgentValue {objectValue([ValueField("id",textValue(id)),ValueField("bytes",integerValue(bytes.size)),ValueField("sha256",textValue(digest))])}
    func read(expected:Int64,maximum:Int64):AgentValue {
        if(finished || expected!=offset || maximum<1 || maximum>WORKFLOW_DOCUMENT_CHUNK){throw PureProviderError("document.data_offset","download is exact and sequential")}
        let end=min(bytes.size,offset+maximum)
        // Raw byte chunks may split a UTF-8 scalar; only the final Host
        // receiver decodes after complete size/hash verification.
        let result=objectValue([ValueField("offset",integerValue(offset)),ValueField("bytes_hex",textValue(logicalJsonEncodeHex(bytes[offset..end]))),
            ValueField("eof",boolValue(end==bytes.size))])
        offset=end;finished=end==bytes.size;result
    }
}

// One bounded query-local cache in one pure worker. The caller never passes
// this object to a Tool broker. A prepared call cannot depend on this cache:
// Host must consume every output and release it before approval/execution.
class WorkflowDocumentData {
    private var lastSequence:Int64=0
    private var sequence:Int64=0
    private var sourceDigest=""
    private var input:?AgentValue=None
    private var parameterUpload:?WorkflowDocumentUpload=None
    private var tool=""
    private var deadline:MonoTime=MonoTime.now()
    private var reservation:?LogicalJsonOwnerReservation=None
    private let uploads=ArrayList<WorkflowDocumentUpload>()
    private let downloads=ArrayList<WorkflowDocumentDownload>()
    private var computed=false
    private var totalBytes:Int64=0
    private var parameterBytes:Int64=0

    func close():Unit {
        input=None;parameterUpload=None;uploads.clear();downloads.clear();tool="";sourceDigest="";sequence=0;computed=false;totalBytes=0;parameterBytes=0
        match(reservation){case Some(value)=>value.close();case None=>()};reservation=None
    }
    private func current(query:AgentValue):Unit {
        if(sequence==0 || documentDataInteger(query,"sequence")!=sequence || workflowText(query,"source_digest")!=sourceDigest){
            throw PureProviderError("document.data_identity","query does not own this retained data")}
        if(MonoTime.now()>=deadline){close();throw PureProviderError("document.data_timeout","the original query deadline expired")}
    }
    private func begin(query:AgentValue):AgentValue {
        let until=MonoTime.now()+Duration.second*5
        let chunked=query.field("input_payload").isSome()
        workflowFields(query,if(chunked){["schema","action","sequence","source_digest","tool","input_payload","documents"]}
            else{["schema","action","sequence","source_digest","tool","input","documents"]})
        if(sequence!=0 && MonoTime.now()>=deadline){close()}
        if(sequence!=0){throw PureProviderError("document.data_busy","another query still owns this worker cache")}
        let selected=documentDataInteger(query,"sequence");let digest=workflowText(query,"source_digest")
        let name=workflowText(query,"tool");let descriptors=query.field("documents").getOrThrow()
        if(selected<=lastSequence || !httpIntentDigest(digest) || !["todo","goal","goal_continuation"].contains(name) ||
            descriptors.unifiedKind!=ValueKind.List || descriptors.items.size<1 || descriptors.items.size>8 ||
            (!chunked && query.field("input").getOrThrow().unifiedKind!=ValueKind.Object)){
            throw PureProviderError("document.data_begin","unsupported, stale or oversized declaration")}
        var count:Int64=0;let names=HashSet<String>()
        for(item in descriptors.items){
            workflowFields(item,["id","bytes","sha256"])
            let id=workflowText(item,"id");let size=documentDataInteger(item,"bytes")
            if(!documentDataName(id) || names.contains(id) || size<1 || size>8388608 || !httpIntentDigest(workflowText(item,"sha256")) ||
                size>16777216-count){throw PureProviderError("document.data_begin","invalid declaration or shared allocation bound")}
            names.add(id);count+=size
        }
        if(name=="goal_continuation" && (count>8388608 || names.size!=2 || !names.contains("approved") || !names.contains("current"))){
            throw PureProviderError("document.data_begin","continuation requires its two exact bounded data slots")}
        // The uploaded representation uses the existing ordinary message
        // ceiling, including Host-added ContextRead metadata. It carries no
        // authority and does not raise the ordinary user input ceiling.
        let original=if(chunked){objectValue([])}else{query.field("input").getOrThrow()}
        var parameterDigest=""
        let measure=if(chunked){
            let descriptor=query.field("input_payload").getOrThrow()
            workflowFields(descriptor,["bytes","sha256"])
            let bytes=documentDataInteger(descriptor,"bytes");let hash=workflowText(descriptor,"sha256")
            if(bytes<2 || bytes>ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX || !httpIntentDigest(hash)){
                throw PureProviderError("document.data_input","parameter declaration exceeds the existing ordinary message ceiling")}
            parameterDigest=hash;bytes
        }else{logicalJsonWriteReservationBytes(original,65536)}
        let charge=reservePurePolicyRawData()
        try {
            let parameterNodes=logicalJsonValueNodeCount(original)
            charge.ensureDecoded(measure,parameterNodes)
            // The declared upload extent is funded before allocating its
            // fixed byte storage. Keep the original conservative four input
            // extents and independently live wire charges unchanged.
            charge.ensureRetainedPeak(count*4+measure*8+parameterNodes*512+1048576)
            let frozen:?AgentValue=if(chunked){None}else{
                let encoded=stringifyUnifiedJson(original)
                if(encoded.size>65536){throw PureProviderError("document.data_input","initial parameter envelope exceeds the current bounded input path")}
                Some(parseUnifiedJson(encoded,maxBytes:65536,maxDepth:32))}
            for(item in descriptors.items){uploads.add(WorkflowDocumentUpload(workflowText(item,"id"),documentDataInteger(item,"bytes"),workflowText(item,"sha256")))}
            input=frozen;parameterUpload=if(chunked){Some(WorkflowDocumentUpload("parameters",measure,parameterDigest))}else{None}
            totalBytes=count;parameterBytes=measure;tool=name;sourceDigest=digest;sequence=selected;lastSequence=selected
            deadline=until;reservation=Some(charge)
            if(MonoTime.now()>=until){throw PureProviderError("document.data_timeout","begin exceeded the original query deadline")}
            objectValue([ValueField("accepted",boolValue(true))])
        } catch(error:Exception){charge.close();close();throw error}
    }
    func query(value:AgentValue):AgentValue {
        if(workflowText(value,"schema")!=WORKFLOW_DOCUMENT_QUERY){throw PureProviderError("document.data_schema","unknown pure document data protocol")}
        let action=workflowText(value,"action")
        if(action=="begin"){
            try{return begin(value)}catch(_:LogicalJsonPayloadError){
                throw PureProviderError("document.data_capacity","the original shared allocation or bounded data shape is exhausted")}
        }
        // Wrong-query requests cannot destroy a different retained query.
        current(value)
        try {
            if(action=="append_input"){
                workflowFields(value,["schema","action","sequence","source_digest","offset","bytes_hex"])
                if(computed || parameterUpload.isNone()){
                    throw PureProviderError("document.data_reused","no mutable parameter upload belongs to this query")}
                parameterUpload.getOrThrow().append(documentDataInteger(value,"offset"),workflowText(value,"bytes_hex"))
                current(value);return objectValue([ValueField("accepted",boolValue(true))])
            }
            if(action=="append"){
                workflowFields(value,["schema","action","sequence","source_digest","id","offset","bytes_hex"])
                if(computed){throw PureProviderError("document.data_reused","completed input cannot be changed")}
                let id=workflowText(value,"id");var found=false
                for(upload in uploads where upload.id==id){upload.append(documentDataInteger(value,"offset"),workflowText(value,"bytes_hex"));found=true}
                if(!found){throw PureProviderError("document.data_unknown","unknown input slot")}
                current(value);return objectValue([ValueField("accepted",boolValue(true))])
            }
            if(action=="compute"){
                workflowFields(value,["schema","action","sequence","source_digest"])
                if(computed){throw PureProviderError("document.data_reused","pure computation is single use")}
                computed=true
                match(parameterUpload){case Some(upload)=>
                    let raw=upload.complete();let nodes=logicalJsonNodeCount(raw)
                    reservation.getOrThrow().ensureRetainedPeak(totalBytes*4+parameterBytes*8+nodes*512+1048576)
                    let decoded=parseUnifiedJson(raw,maxBytes:ORDINARY_TOOL_PAYLOAD_MESSAGE_MAX,maxDepth:32)
                    if(decoded.unifiedKind!=ValueKind.Object){throw PureProviderError("document.data_input","complete parameters must be one object")}
                    input=Some(decoded);parameterUpload=None
                    case None=>()}
                let result=compute();current(value);return result
            }
            if(action=="read"){
                workflowFields(value,["schema","action","sequence","source_digest","id","offset","max_bytes"])
                if(!computed){throw PureProviderError("document.data_unprepared","no output exists before compute")}
                for(output in downloads where output.id==workflowText(value,"id")){
                    let result=output.read(documentDataInteger(value,"offset"),documentDataInteger(value,"max_bytes"));current(value);return result}
                throw PureProviderError("document.data_unknown","unknown output slot")
            }
            if(action=="release"){
                workflowFields(value,["schema","action","sequence","source_digest"]);close()
                return objectValue([ValueField("released",boolValue(true))])
            }
            throw PureProviderError("document.data_action","unsupported pure document phase")
        }catch(_:LogicalJsonPayloadError){close();throw PureProviderError("document.data_capacity","the original shared allocation or bounded data shape is exhausted")}
        catch(error:Exception){close();throw error}
    }
    private func computeContinuation():AgentValue {
        let original=input.getOrThrow()
        workflowFields(original,["schema","selector","approved_document","current_document","facts"])
        var nodes:Int64=0
        // Uploaded descriptors are powerless bytes. The actual Host validates
        // its completed historical/UserOwner proof before opening a source.
        for(name in ["approved_document","current_document"]){
            let selected=original.field(name).getOrThrow();workflowFields(selected,["id","bytes","sha256"])
            let expected=if(name=="approved_document"){"approved"}else{"current"}
            if(workflowText(selected,"id")!=expected){throw PureProviderError("document.data_fact","continuation slot identity changed")}
            for(upload in uploads where upload.id==expected){
                if(documentDataInteger(selected,"bytes")!=upload.bytes || workflowText(selected,"sha256")!=upload.digest){
                    throw PureProviderError("document.data_fact","continuation slot differs from its frozen source descriptor")}
                let raw=upload.complete();nodes+=logicalJsonNodeCount(raw)
                if(nodes>65536){throw PureProviderError("document.data_shape","combined continuation shape exceeds its bounded decoder")}
            }
        }
        reservation.getOrThrow().ensureRetainedPeak(totalBytes*6+nodes*1024+parameterBytes*8+1048576)
        let fields=ArrayList<ValueField>(original.fields.toArray().filter{field=>field.name!="approved_document" && field.name!="current_document"})
        for(upload in uploads){
            fields.add(ValueField(if(upload.id=="approved"){"approved_document"}else{"current_document"},
                parseUnifiedJson(upload.complete(),maxBytes:8388608,maxDepth:32)))}
        // Exactly the existing restrict-only algorithm; no new evaluator,
        // state mutation, persistence, service request or resume authority.
        workflowGoalContinuation(objectValue(fields.toArray()))
    }
    private func compute():AgentValue {
        if(tool=="goal_continuation"){return computeContinuation()}
        let original=input.getOrThrow()
        let envelope=original.field(CONTEXT_READ_INPUT_FIELD).getOrThrow();let data=envelope.field("data").getOrThrow()
        if(httpIntentText(data,"schema")!="axyndra.plugin-document-read-result/v2"){throw PureProviderError("document.data_fact","a compact Host fact is required")}
        let documents=ArrayList<AgentValue>();let seen=HashSet<String>();var nodes:Int64=0
        for(item in data.field("documents").getOrThrow().items){
            let key=workflowText(item,"key");var found:?WorkflowDocumentUpload=None
            if(seen.contains(key)){throw PureProviderError("document.data_fact","duplicate observed key")};seen.add(key)
            for(upload in uploads where upload.id==key){found=Some(upload)}
            if(found.isNone()){throw PureProviderError("document.data_fact","the complete observed key is missing")}
            let selected=found.getOrThrow();let reference=item.field("payload").getOrThrow()
            if(documentDataInteger(reference,"bytes")!=selected.bytes || workflowText(reference,"sha256")!=selected.digest){
                throw PureProviderError("document.data_fact","data bytes differ from the exact observed digest")}
            let raw=selected.complete();nodes+=logicalJsonNodeCount(raw)
            if(nodes>65536){throw PureProviderError("document.data_shape","combined document shape exceeds the bounded decoder")}
            documents.add(objectValue([ValueField("key",textValue(key)),ValueField("revision",item.field("revision").getOrThrow()),
                ValueField("json",textValue(raw)),ValueField("sha256",textValue(selected.digest))]))
        }
        if(documents.size!=uploads.size){throw PureProviderError("document.data_fact","unused or duplicated upload declaration")}
        let fields=ArrayList<ValueField>(data.fields.toArray().filter{field=>field.name!="schema" && field.name!="documents"})
        fields.add(ValueField("schema",textValue("axyndra.plugin-document-read-result/v1")));fields.add(ValueField("documents",listValue(documents.toArray())))
        let args=objectValue(original.fields.toArray().filter{field=>field.name!=CONTEXT_READ_INPUT_FIELD})
        args.put(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",textValue("axyndra.context-read-input/v1")),
            ValueField("data",objectValue(fields.toArray())),ValueField("facts",envelope.field("facts").getOrThrow())]))
        // Peak ledger before the unchanged algorithm parses/clones: six
        // input-byte extents (upload growth/copy, UTF-8 text, parse text and
        // legacy clone text/strings), two 512-byte cells per source node,
        // plus the already bounded parameter/metadata representation.
        let algorithmPeak=totalBytes*6+nodes*1024+parameterBytes*8+1048576
        reservation.getOrThrow().ensureRetainedPeak(algorithmPeak)
        let proposal=workflowDocumentProposal(tool,args)
        let changed=proposal.field("changed").getOrThrow().asBool() || proposal.field("user_control").isSome()
        let output=proposal.field("output").getOrThrow()
        let nextBytes=if(changed){logicalJsonWriteReservationBytes(proposal.field("document").getOrThrow(),8388608)}else{0}
        let resultBytes=logicalJsonWriteReservationBytes(output,8388608)
        let outputNodes=logicalJsonValueNodeCount(proposal)
        // Each retained output has one serialization string and one byte
        // array. Both outputs coexist with the input/proposal DOM. Pay before
        // either stringify or WorkflowDocumentDownload.toArray allocation.
        reservation.getOrThrow().ensureRetainedPeak(algorithmPeak+outputNodes*512+nextBytes*2+resultBytes*2)
        if(changed){
            let next=proposal.field("document").getOrThrow()
            let text=stringifyUnifiedJson(next)
            if(text.size>8388608){throw PureProviderError("document.data_output","next document exceeds its durable bound")}
            downloads.add(WorkflowDocumentDownload("next",text))
        }
        let result=stringifyUnifiedJson(output)
        if(result.size>8388608){throw PureProviderError("document.data_output","full pure result exceeds this output path")}
        downloads.add(WorkflowDocumentDownload("result",result))
        let response=objectValue([ValueField("intents",listValue([objectValue([ValueField("id",textValue(tool+"-1")),ValueField("key",textValue(tool)),
            ValueField("mode",textValue(if(changed){"compare_exchange"}else{"read"})),ValueField("next_slot",if(changed){textValue("next")}else{nullValue()})])])),
            ValueField("outputs",listValue(downloads.toArray().map{value=>value.descriptor()})),ValueField("result_slot",textValue("result")),
            ValueField("is_error",proposal.field("is_error").getOrThrow())])
        match(proposal.field("user_control")){case Some(control)=>response.put("user_control",control);case None=>()}
        // Returned metadata is small; the cache charge remains until every
        // download consumer has copied/verified it and explicitly releases.
        response
    }
}

