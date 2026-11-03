package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

let MEMORY_WINDOW_DOCUMENT_QUERY="axyndra.document-data-query/v2"
class MemoryWindowRecordSource {
    let fact:Int64
    let row:Int64
    let record:MemoryV3Record
    init(fact:Int64,row:Int64,record:MemoryV3Record){this.fact=fact;this.row=row;this.record=record}
}
class MemoryWindowState {
    let manifest:AgentValue
    let manifestDigest:String
    let records:Array<MemoryV3Record>
    let sources:Array<MemoryWindowRecordSource>
    let retainedPeak:Int64
    init(manifest:AgentValue,digest:String,records:Array<MemoryV3Record>,sources:Array<MemoryWindowRecordSource>,peak:Int64){
        this.manifest=manifest;this.manifestDigest=digest;this.records=records;this.sources=sources;this.retainedPeak=peak}
}
func memoryWindowPrepare(value:AgentValue):AgentValue {
    memoryDocumentFields(value,["schema","tool","input"])
    if(httpIntentText(value,"schema")!="axyndra.tool-preparation-query/v1" || !MEMORY_NATIVE_TOOLS.contains(memoryDocumentText(value,"tool")) ||
        value.field("input").getOrThrow().unifiedKind!=ValueKind.Object || value.field("input").getOrThrow().field(CONTEXT_READ_INPUT_FIELD).isSome()){
        throw PureProviderError("memory.window_prepare","window preparation requires its original unfrozen tool input")}
    objectValue([ValueField("document_read",objectValue([ValueField("key",textValue(MEMORY_JOURNAL_KEY)),
        ValueField("window",objectValue([ValueField("kind",textValue("manifest"))]))]))])
}
// Whole compact outputs remain untrusted data. Only the actual Host/Store
// source and pin checks authorize uploads; Native never produces a grant.
func memoryWindowState(input:AgentValue,uploads:Array<MemoryDocumentUpload>,owner:LogicalJsonOwnerReservation,
    rawBytes:Int64,parameterBytes:Int64,partial!:Bool=false):MemoryWindowState {
    let envelope=input.field(CONTEXT_READ_INPUT_FIELD).getOrThrow()
    memoryDocumentFields(envelope,["schema","data","facts"])
    let data=envelope.field("data").getOrThrow();let facts=envelope.field("facts").getOrThrow()
    if(httpIntentText(envelope,"schema")!="axyndra.context-read-input/v2" || data.unifiedKind!=ValueKind.List ||
        facts.unifiedKind!=ValueKind.List || data.items.size<1 || data.items.size>8 || facts.items.size!=data.items.size || uploads.size!=data.items.size){
        throw PureProviderError("memory.window_fact","complete ordered window facts are required")}
    let records=ArrayList<MemoryV3Record>();let sources=ArrayList<MemoryWindowRecordSource>();var manifest:?AgentValue=None
    var manifestDigest="";var offset:Int64=0;var metadataNodes:Int64=0;var bodyNodes:Int64=0;var recordBytes:Int64=0
    var retainedPeak=rawBytes*4+parameterBytes*8+1048576
    for(index in 0..data.items.size){
        let result=data.items[index]
        memoryDocumentFields(result,["schema","request_digest","documents"])
        if(httpIntentText(result,"schema")!="axyndra.plugin-document-row-journal-read-result/v1" ||
            !httpIntentDigest(memoryDocumentText(result,"request_digest")) || result.field("documents").getOrThrow().items.size!=1){
            throw PureProviderError("memory.window_fact","one exact generic journal window is required per actual read")}
        let item=result.field("documents").getOrThrow().items[0];memoryDocumentFields(item,["key","revision","payload"])
        if(memoryDocumentText(item,"key")!=MEMORY_JOURNAL_KEY || memoryDocumentInteger(item,"revision")<1){
            throw PureProviderError("memory.window_fact","window belongs to another observed journal")}
        var selected:?MemoryDocumentUpload=None
        for(upload in uploads where upload.id=="read-"+index.toString()){selected=Some(upload)}
        let uploaded=selected.getOrThrow();let reference=item.field("payload").getOrThrow()
        if(documentDataInteger(reference,"bytes")!=uploaded.bytes || memoryDocumentText(reference,"sha256")!=uploaded.digest){
            throw PureProviderError("memory.window_fact","uploaded window differs from its full compact fact")}
        let raw=uploaded.complete();let nodes=logicalJsonNodeCount(raw)
        // Each bounded manifest/body decoder has its original node ceiling.
        // Record payloads are opaque strings until one DTO is decoded; there
        // is no aggregate history DOM or 128/4096 business item limit.
        if(nodes>65536){throw PureProviderError("memory.window_shape","one bounded window exceeds the original decoder ceiling")}
        retainedPeak=rawBytes*4+parameterBytes*8+(metadataNodes+bodyNodes+nodes)*512+records.size*8192+recordBytes*3+1048576
        owner.ensureRetainedPeak(retainedPeak)
        let value=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32)
        if(index==0){
            memoryDocumentFields(value,["schema","layout","state","rows","annotations"])
            if(httpIntentText(value,"schema")!="axyndra.opaque-row-journal-manifest/v1" || httpIntentText(value,"layout")!="opaque-fact-events-v3"){
                throw PureProviderError("memory.window_version_readonly","unsupported fixed journal version remains read-only")}
            let state=value.field("state").getOrThrow();memoryDocumentFields(state,["sha256","chain_sha256","next_event_id","rows","events"])
            if(!httpIntentDigest(memoryDocumentText(state,"sha256")) || !httpIntentDigest(memoryDocumentText(state,"chain_sha256")) ||
                memoryDocumentInteger(state,"next_event_id")<1 || memoryDocumentInteger(state,"rows")<0 || memoryDocumentInteger(state,"events")<0){
                throw PureProviderError("memory.window_fact","complete blind journal fence is invalid")}
            let annotations=value.field("annotations").getOrThrow();memoryDocumentFields(annotations,["workspace_root","settings_root","thread_id","lane_id"])
            let seen=HashSet<String>();var first:Int64=0
            for(row in value.field("rows").getOrThrow().items){
                memoryDocumentFields(row,["key","kind","revision","payload_sha256","payload_bytes","payload_json_bytes","first_event_id"])
                let id=memoryDocumentText(row,"key");let order=memoryDocumentInteger(row,"first_event_id")
                if(id=="" || seen.contains(id) || order<=first || memoryDocumentInteger(row,"revision")<1 ||
                    !httpIntentDigest(memoryDocumentText(row,"payload_sha256")) || memoryDocumentInteger(row,"payload_bytes")<1 ||
                    memoryDocumentInteger(row,"payload_bytes")>8388608 || memoryDocumentInteger(row,"payload_json_bytes")<2){
                    throw PureProviderError("memory.window_fact","ordered current row manifest is invalid")}
                first=order;seen.add(id)}
            manifest=Some(value);manifestDigest=uploaded.digest;metadataNodes=nodes;continue
        }
        memoryDocumentFields(value,["schema","manifest_sha256","offset","rows"])
        if(httpIntentText(value,"schema")!="axyndra.opaque-row-journal-rows/v1" || memoryDocumentText(value,"manifest_sha256")!=manifestDigest ||
            memoryDocumentInteger(value,"offset")!=offset || value.field("rows").getOrThrow().unifiedKind!=ValueKind.List){
            throw PureProviderError("memory.window_fact","body page is not the exact next manifest range")}
        let headers=manifest.getOrThrow().field("rows").getOrThrow().items;let rows=value.field("rows").getOrThrow().items
        if(rows.isEmpty() || rows.size>headers.size-offset){throw PureProviderError("memory.window_fact","body page repeats or exceeds its manifest")}
        for(position in 0..rows.size){
            let row=rows[position];memoryDocumentFields(row,["key","revision","payload_sha256","payload"])
            let header=headers[offset+position];let payload=memoryDocumentText(row,"payload")
            if(memoryDocumentText(row,"key")!=memoryDocumentText(header,"key") || memoryDocumentInteger(row,"revision")!=memoryDocumentInteger(header,"revision") ||
                memoryDocumentText(row,"payload_sha256")!=memoryDocumentText(header,"payload_sha256") ||
                payload.size!=memoryDocumentInteger(header,"payload_bytes") || modelPolicySha256Text(payload)!=memoryDocumentText(header,"payload_sha256")){
                throw PureProviderError("memory.window_fact","body bytes differ from the complete observed current manifest")}
            let recordNodes=logicalJsonNodeCount(payload)
            if(recordNodes>65536){throw PureProviderError("memory.window_shape","one original record exceeds its existing decoder")}
            retainedPeak=rawBytes*4+parameterBytes*8+(metadataNodes+nodes+recordNodes)*512+(records.size+1)*8192+(recordBytes+payload.size)*3+1048576
            owner.ensureRetainedPeak(retainedPeak)
            let decoded=parseUnifiedJson(payload,maxBytes:8388608,maxDepth:32)
            let record=match(memoryV3DecodeEvent(decoded)){case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(result)=>result}
            if(record.id!=memoryDocumentText(header,"key") || record.revision!=memoryDocumentInteger(header,"revision") ||
                memoryV3KindName(record.kind)!=memoryDocumentText(header,"kind")){
                throw PureProviderError("memory.window_fact","original record and observed index disagree")}
            records.add(record);sources.add(MemoryWindowRecordSource(index,position,record));recordBytes+=payload.size
        };offset+=rows.size;bodyNodes=max(bodyNodes,nodes)
    }
    if(manifest.isNone() || (!partial && offset!=manifest.getOrThrow().field("rows").getOrThrow().items.size)){
        throw PureProviderError("memory.window_fact","every observed current record is required before the original algorithm runs")}
    retainedPeak=rawBytes*4+parameterBytes*8+(metadataNodes+bodyNodes)*512+records.size*8192+recordBytes*3+1048576
    owner.ensureRetainedPeak(retainedPeak)
    MemoryWindowState(manifest.getOrThrow(),manifestDigest,records.toArray(),sources.toArray(),retainedPeak)
}
func memoryWindowCopies(event:AgentValue,sources:Array<MemoryWindowRecordSource>):AgentValue {
    let record=event.field("record").getOrThrow();let copies=ArrayList<AgentValue>();let fields=ArrayList<ValueField>()
    for(field in record.fields){var selected:?MemoryWindowRecordSource=None
        if(["content","context","source"].contains(field.name) && field.value.unifiedKind==ValueKind.Text && field.value.text.size>4096){
            for(source in sources where selected.isNone()){
                let original=if(field.name=="content"){source.record.content}else if(field.name=="context"){source.record.context}else{source.record.source}
                if(original==field.value.text){selected=Some(source)}}}
        match(selected){case Some(source)=>
            let path=listValue([textValue("record"),textValue(field.name)])
            copies.add(objectValue([ValueField("path",path),ValueField("from",objectValue([ValueField("fact",integerValue(source.fact)),
                ValueField("row",integerValue(source.row)),ValueField("path",path)]))]));fields.add(ValueField(field.name,nullValue()))
            case None=>fields.add(field)}
    }
    let values=event.fields.toArray().map{field=>if(field.name=="record"){ValueField("record",objectValue(fields.toArray()))}else{field}}
    objectValue([ValueField("event",objectValue(values)),ValueField("copies",listValue(copies.toArray()))])
}
func memoryWindowProposal(name:String,input:AgentValue,state:MemoryWindowState):AgentValue {
    let annotations=state.manifest.field("annotations").getOrThrow();let thread=memoryDocumentText(annotations,"thread_id")
    let workspace=memoryDocumentText(annotations,"workspace_root");let settings=memoryDocumentText(annotations,"settings_root")
    let args=objectValue(input.fields.toArray().filter{field=>field.name!=CONTEXT_READ_INPUT_FIELD})
    if(name=="manage_skill" || (name=="learn" && args.field("skill").isSome())){
        throw PureProviderError("memory.workspace_fact_required","managed skill execution still requires actual generic file effects")}
    let journal=NativeMemoryJournal(state.records,DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
        firstAppearance:memoryDocumentRowKeys(state.manifest))
    let runtime=NativeMemoryTools(journal,NativeManagedSkillProposals([]),settings,workspace,[])
    let context=NativeMemoryToolContext(SessionId(thread),workspace);let call=ToolCall("native-memory",name,args);let result:Result<ToolResult>
    match(name){case "retain"=>result=runtime.retain(context,call);case "recall"=>result=runtime.recall(context,call)
        case "reflect"=>result=runtime.reflect(context,call);case "memory_edit"=>result=runtime.edit(context,call);case "learn"=>result=runtime.learn(context,call)
        case "memory_context"=>
            memoryDocumentFields(args,["query","max_bytes"])
            result=match(runtime.contextFor(memoryDocumentText(args,"query"),SessionId(thread),workspace,memoryDocumentInteger(args,"max_bytes"))){
                case Result.Err(error)=>Result.Err(error);case Result.Ok(content)=>Result.Ok(ToolResult(call.callId,objectValue([ValueField("content",textValue(content))])))}
        case _=>throw PureProviderError("memory.tool_unknown","unknown Native Memory tool")}
    let output:AgentValue;let isError:Bool
    match(result){case Result.Ok(value)=>output=value.output;isError=value.isError
        case Result.Err(error)=>output=objectValue([ValueField("code",textValue(error.code)),ValueField("message",textValue(error.message))]);isError=true}
    let entries=ArrayList<AgentValue>();var eventId=memoryDocumentInteger(state.manifest.field("state").getOrThrow(),"next_event_id")
    for(event in journal.pendingEvents()){
        if(eventId==Int64.Max){throw PureProviderError("memory.window_sequence","original journal event sequence is exhausted")}
        let record=match(memoryV3DecodeEvent(event)){case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value}
        let copied=memoryWindowCopies(event,state.sources)
        entries.add(objectValue([ValueField("id",integerValue(eventId)),ValueField("key",textValue(record.id)),ValueField("revision",integerValue(record.revision)),
            ValueField("operation",event.field("operation").getOrThrow()),ValueField("created_at_millis",integerValue(record.updatedAt)),
            ValueField("event",copied.field("event").getOrThrow()),ValueField("copies",copied.field("copies").getOrThrow())]));eventId++}
    let proposal=objectValue([ValueField("changed",boolValue(!entries.isEmpty())),ValueField("output",output),ValueField("is_error",boolValue(isError)),
        ValueField("append",objectValue([ValueField("schema",textValue("axyndra.opaque-row-journal-append/v1")),
            ValueField("manifest_sha256",textValue(state.manifestDigest)),ValueField("entries",listValue(entries.toArray()))]))])
    let ceiling=if(name=="memory_context"){runtime.contextValidUntilMillis()}else{runtime.retrievalValidUntilMillis()}
    if(ceiling>0){proposal.put("valid_until_millis",integerValue(ceiling))};proposal
}
