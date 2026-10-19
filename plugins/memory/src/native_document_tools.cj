package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

let MEMORY_JOURNAL_KEY = "journal"
let MEMORY_NATIVE_TOOLS = ["retain","recall","reflect","memory_edit","learn","manage_skill","memory_context"]

func memoryDocumentFields(value: AgentValue, names: Array<String>): Unit {
    if(!httpIntentExactFields(value,names)){throw PureProviderError("memory.document_shape","exact document fields required")}
}
func memoryDocumentText(value: AgentValue,name: String): String {
    let item=value.field(name).getOrThrow()
    if(item.unifiedKind!=ValueKind.Text){throw PureProviderError("memory.document_shape","text field required")};item.text
}
func memoryDocumentInteger(value: AgentValue,name: String): Int64 {
    let item=value.field(name).getOrThrow()
    if(item.unifiedKind!=ValueKind.Number){throw PureProviderError("memory.document_shape","canonical integer required")}
    let number=Int64.parse(item.asNumberText())
    if(number.toString()!=item.asNumberText()){throw PureProviderError("memory.document_shape","canonical integer required")};number
}
func memoryDocumentSnapshot(input: AgentValue): AgentValue {
    let envelope=input.field(CONTEXT_READ_INPUT_FIELD)??nullValue();let data=envelope.field("data")??nullValue()
    if(httpIntentText(envelope,"schema")!="axyndra.context-read-input/v1" ||
        httpIntentText(data,"schema")!="axyndra.plugin-document-read-result/v1"){
        throw PureProviderError("memory.document_fact_missing","Native Memory requires its completed document observation")}
    let documents=data.field("documents")??nullValue()
    if(documents.unifiedKind!=ValueKind.List || documents.items.size!=1 ||
        httpIntentText(documents.items[0],"key")!=MEMORY_JOURNAL_KEY){
        throw PureProviderError("memory.document_fact_ambiguous","one exact journal observation is required")}
    let selected=documents.items[0];let raw=memoryDocumentText(selected,"json")
    if(raw=="" || modelPolicySha256Text(raw)!=httpIntentText(selected,"sha256")){
        throw PureProviderError("memory.document_fact_invalid","journal bytes differ from their observed digest")}
    let value=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32)
    memoryDocumentFields(value,["schema","layout","rows","events","journal_chain_sha256","next_event_id","annotations"])
    if(httpIntentText(value,"schema")!="axyndra.opaque-row-journal/v1" || httpIntentText(value,"layout")!="opaque-fact-events-v3" ||
        !httpIntentDigest(httpIntentText(value,"journal_chain_sha256")) || memoryDocumentInteger(value,"next_event_id")<1){
        throw PureProviderError("memory.document_version_readonly","unsupported journal version remains read-only")}
    let annotations=value.field("annotations").getOrThrow()
    memoryDocumentFields(annotations,["workspace_root","settings_root","thread_id","lane_id"])
    for(name in ["workspace_root","settings_root","thread_id","lane_id"]){let _=memoryDocumentText(annotations,name)}
    if(memoryDocumentText(annotations,"thread_id")=="" || memoryDocumentText(annotations,"lane_id")==""){
        throw PureProviderError("memory.document_fact_invalid","observed address is incomplete")}
    value
}

// Preserve the original event parser, original history order, and exact
// latest-row bytes. Unknown old bytes are rejected before any proposal;
// Native never repairs or replaces a malformed history while reading it.
// Same ordered map, with one direct result allocation. UnifiedJsonItems is
// an indexed view, not an Array or Iterable constructor argument.
func memoryDocumentRowKeys(value:AgentValue):Array<String>{
    let rows=value.field("rows").getOrThrow().items
    Array<String>(rows.size,{index=>memoryDocumentText(rows[index],"key")})
}

func memoryDocumentHistory(value: AgentValue): Array<MemoryV3Record> {
    let rows=value.field("rows").getOrThrow();let events=value.field("events").getOrThrow()
    if(rows.unifiedKind!=ValueKind.List || events.unifiedKind!=ValueKind.List || rows.items.size>4096 || events.items.size>8192){
        throw PureProviderError("memory.document_version_readonly","journal shape exceeds this bounded version")}
    let seenRows=HashSet<String>();let latest=HashMap<String,AgentValue>();let history=ArrayList<MemoryV3Record>()
    for(row in rows.items){
        memoryDocumentFields(row,["key","kind","payload_sha256","revision"])
        let key=memoryDocumentText(row,"key")
        if(key=="" || seenRows.contains(key) || !httpIntentDigest(memoryDocumentText(row,"payload_sha256")) ||
            memoryDocumentInteger(row,"revision")<1){throw PureProviderError("memory.document_fact_invalid","current row index is invalid")}
        seenRows.add(key)
    }
    var previous:Int64=0
    for(event in events.items){
        memoryDocumentFields(event,["id","key","revision","operation","payload","created_at_millis"])
        let id=memoryDocumentInteger(event,"id");let key=memoryDocumentText(event,"key");let raw=memoryDocumentText(event,"payload")
        if(id<=previous || id>=memoryDocumentInteger(value,"next_event_id") || !seenRows.contains(key) ||
            memoryDocumentInteger(event,"created_at_millis")<1){throw PureProviderError("memory.document_fact_invalid","journal event sequence is invalid")}
        let encoded=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32)
        let record=match(memoryV3DecodeEvent(encoded)){case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(item)=>item}
        if(record.id!=key || record.revision!=memoryDocumentInteger(event,"revision") ||
            httpIntentText(encoded,"operation")!=memoryDocumentText(event,"operation")){
            throw PureProviderError("memory.document_fact_invalid","event metadata disagrees with its original payload")}
        previous=id;history.add(record);latest[key]=event
    }
    for(row in rows.items){
        let key=memoryDocumentText(row,"key")
        if(!latest.contains(key)){throw PureProviderError("memory.document_fact_invalid","current row has no accessible latest event")}
        let event=latest[key];let raw=memoryDocumentText(event,"payload")
        let record=parseUnifiedJson(raw,maxBytes:8388608,maxDepth:32).field("record").getOrThrow()
        if(modelPolicySha256Text(raw)!=memoryDocumentText(row,"payload_sha256") ||
            memoryDocumentInteger(event,"revision")!=memoryDocumentInteger(row,"revision") ||
            httpIntentText(record,"kind")!=memoryDocumentText(row,"kind")){
            throw PureProviderError("memory.document_fact_invalid","current row and latest original event differ")}
    }
    history.toArray()
}

func memoryDocumentNext(previous: AgentValue, appended: Array<AgentValue>): AgentValue {
    let rows=ArrayList<AgentValue>()
    for(row in previous.field("rows").getOrThrow().items){rows.add(row)}
    let events=ArrayList<AgentValue>()
    for(event in previous.field("events").getOrThrow().items){events.add(event)}
    var next=memoryDocumentInteger(previous,"next_event_id");var chain=memoryDocumentText(previous,"journal_chain_sha256")
    if(appended.size>128){throw PureProviderError("memory.document_output_bound","one invocation exceeds the bounded append batch")}
    for(value in appended){
        let record=match(memoryV3DecodeEvent(value)){case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(item)=>item}
        let raw=stringifyUnifiedJson(value)
        let event=objectValue([ValueField("id",integerValue(next)),ValueField("key",textValue(record.id)),
            ValueField("revision",integerValue(record.revision)),ValueField("operation",value.field("operation").getOrThrow()),
            ValueField("payload",textValue(raw)),ValueField("created_at_millis",integerValue(record.updatedAt))])
        if(next==Int64.Max){throw PureProviderError("memory.document_output_bound","journal event sequence exhausted")}
        next++;chain=modelPolicySha256Text(chain+canonicalAgentValue(event));events.add(event)
        let row=objectValue([ValueField("key",textValue(record.id)),ValueField("kind",textValue(memoryV3KindName(record.kind))),
            ValueField("payload_sha256",textValue(modelPolicySha256Text(raw))),ValueField("revision",integerValue(record.revision))])
        var replaced=false
        for(index in 0..rows.size where memoryDocumentText(rows[index],"key")==record.id){rows[index]=row;replaced=true}
        if(!replaced){rows.add(row)}
    }
    objectValue([ValueField("schema",previous.field("schema").getOrThrow()),ValueField("layout",previous.field("layout").getOrThrow()),
        ValueField("rows",listValue(rows.toArray())),ValueField("events",listValue(events.toArray())),
        ValueField("journal_chain_sha256",textValue(chain)),ValueField("next_event_id",integerValue(next)),
        ValueField("annotations",previous.field("annotations").getOrThrow())])
}

func memoryDocumentProposal(name: String,input: AgentValue): AgentValue {
    if(!MEMORY_NATIVE_TOOLS.contains(name)){throw PureProviderError("memory.tool_unknown","unknown Native Memory tool")}
    let previous=memoryDocumentSnapshot(input);let history=memoryDocumentHistory(previous)
    let annotations=previous.field("annotations").getOrThrow();let thread=memoryDocumentText(annotations,"thread_id")
    let workspace=memoryDocumentText(annotations,"workspace_root");let settings=memoryDocumentText(annotations,"settings_root")
    let arguments=objectValue(input.fields.toArray().filter{field=>field.name!=CONTEXT_READ_INPUT_FIELD})
    // Filesystem proposals require a distinct, completed Workspace Root fact.
    // This document-only profile cannot fabricate file presence or emit a
    // Created/Updated result before the actual file effect is consumed.
    if(name=="manage_skill" || (name=="learn" && arguments.field("skill").isSome())){
        throw PureProviderError("memory.workspace_fact_required","managed skill execution requires the configured generic Workspace effect profile")}
    let order=memoryDocumentRowKeys(previous)
    let journal=NativeMemoryJournal(history,DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),firstAppearance:order)
    let skills=NativeManagedSkillProposals([]);let runtime=NativeMemoryTools(journal,skills,settings,workspace,[])
    let context=NativeMemoryToolContext(SessionId(thread),workspace);let call=ToolCall("native-memory",name,arguments)
    let result:Result<ToolResult>
    match(name){
        case "retain"=>result=runtime.retain(context,call)
        case "recall"=>result=runtime.recall(context,call)
        case "reflect"=>result=runtime.reflect(context,call)
        case "memory_edit"=>result=runtime.edit(context,call)
        case "learn"=>result=runtime.learn(context,call)
        case "memory_context"=>
            memoryDocumentFields(arguments,["query","max_bytes"])
            result=match(runtime.contextFor(memoryDocumentText(arguments,"query"),SessionId(thread),workspace,memoryDocumentInteger(arguments,"max_bytes"))){
                case Result.Err(error)=>Result.Err(error)
                case Result.Ok(value)=>
                    let fields=ArrayList<ValueField>([ValueField("content",textValue(value))])
                    if(runtime.contextValidUntilMillis()>0){fields.add(ValueField("valid_until_millis",integerValue(runtime.contextValidUntilMillis())))}
                    Result.Ok(ToolResult(call.callId,objectValue(fields.toArray())))}
        case _=>throw PureProviderError("memory.tool_unknown","unknown Native Memory tool")
    }
    let output:AgentValue;let isError:Bool
    match(result){case Result.Ok(value)=>output=value.output;isError=value.isError
        case Result.Err(error)=>output=objectValue([ValueField("code",textValue(error.code)),ValueField("message",textValue(error.message))]);isError=true}
    let pending=journal.pendingEvents()
    // Preserve legacy sequential retain semantics: an earlier valid draft
    // may have been authored before a later business error. Its original
    // events remain a real CAS proposal, never an uncommitted success.
    let fields=ArrayList<ValueField>([ValueField("changed",boolValue(pending.size>0)),ValueField("document",memoryDocumentNext(previous,pending)),
        ValueField("output",output),ValueField("is_error",boolValue(isError))])
    let validity=if(name=="memory_context"){runtime.contextValidUntilMillis()}else{runtime.retrievalValidUntilMillis()}
    if(validity>0){fields.add(ValueField("valid_until_millis",integerValue(validity)))}
    objectValue(fields.toArray())
}

func memoryDocumentPrepare(name:String,value:AgentValue):AgentValue {
    memoryDocumentFields(value,["input"])
    if(!MEMORY_NATIVE_TOOLS.contains(name) || value.field("input").getOrThrow().unifiedKind!=ValueKind.Object){
        throw PureProviderError("memory.tool_unknown","unsupported Native Memory preparation")}
    if(value.field("input").getOrThrow().field(CONTEXT_READ_INPUT_FIELD).isNone()){
        return objectValue([ValueField("document_read",objectValue([ValueField("keys",listValue([textValue(MEMORY_JOURNAL_KEY)]))]))])}
    // Every proposal contains an ID/timestamp or presentation clock. The
    // actual Host freezes the chunked pure result; execution must not rerun it.
    throw PureProviderError("memory.frozen_payload_required","Memory requires the frozen document-data preparation profile")
}
func memoryDocumentExecute(_name:String,_input:AgentValue,_broker:DocumentPolicyBroker):DocumentPolicyToolResult {
    throw PureProviderError("memory.frozen_payload_required","actual Host frozen execution must consume the prepared intents and result")
}
func memoryDocumentTools():AgentValue {
    let definitions=[memoryRetainDefinition(),memoryRecallDefinition(),memoryReflectDefinition(),memoryEditDefinition(),learnDefinition(),manageSkillDefinition(),
        ModelToolDefinition("memory_context","Prepare bounded request-time Memory context.",objectSchema([
            schemaProperty("query","string"),schemaProperty("max_bytes","integer")],["query","max_bytes"]))]
    listValue(definitions.map{definition=>objectValue([ValueField("name",textValue(definition.name)),
        ValueField("description",textValue(definition.description)),ValueField("input_schema",definition.inputSchema)])})
}
func memoryDocumentPolicy(name:String,value:AgentValue):AgentValue {
    if(name=="prepare_document" && httpIntentText(value,"schema")==MEMORY_LIVE_READ_PREPARATION_QUERY){
        return memoryLiveReadPreparation(value)}
    if(name=="memory"){return memoryPolicy(value)}
    memoryDocumentFields(value,["schema","tool","input"])
    if(name!="prepare_document" || httpIntentText(value,"schema")!="axyndra.tool-preparation-query/v1"){
        throw PureProviderError("memory.preparation_query_invalid","exact Tool preparation query required")}
    memoryDocumentPrepare(memoryDocumentText(value,"tool"),objectValue([ValueField("input",value.field("input").getOrThrow())]))
}
