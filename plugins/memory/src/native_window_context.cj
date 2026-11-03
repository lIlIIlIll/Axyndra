package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

// Context queries use a separately published typed ContextProvider and
// actual parentless ContextRead. No ToolCall or prepared Tool parent is
// inferred from these untrusted data bytes.
func memoryWindowContextPrepare(value:AgentValue):AgentValue {
    memoryDocumentFields(value,["schema","provider","input"])
    if(memoryDocumentText(value,"schema")!="axyndra.context-window-preparation-query/v1" ||
        memoryDocumentText(value,"provider")!="memory_context"){
        throw PureProviderError("memory.context_prepare","unknown exact parentless preparation query")}
    let input=value.field("input").getOrThrow()
    memoryDocumentFields(input,["schema","query","max_bytes"])
    if(memoryDocumentText(input,"schema")!="axyndra.memory-context-query/v1" ||
        input.field("query").getOrThrow().unifiedKind!=ValueKind.Text || memoryDocumentInteger(input,"max_bytes")<1){
        throw PureProviderError("memory.context_prepare","original bounded context parameters are required")}
    objectValue([ValueField("document_read",objectValue([ValueField("key",textValue(MEMORY_JOURNAL_KEY)),
        ValueField("window",objectValue([ValueField("kind",textValue("manifest"))]))]))])
}
func memoryWindowContextInput(input:AgentValue,preparation:Bool):Unit{
    memoryDocumentFields(input,["schema","query","max_bytes",CONTEXT_READ_INPUT_FIELD,"_axyndra_context_provider"])
    if(memoryDocumentText(input,"schema")!="axyndra.memory-context-query/v1" ||
        input.field("query").getOrThrow().unifiedKind!=ValueKind.Text || memoryDocumentInteger(input,"max_bytes")<1){
        throw PureProviderError("memory.context_query_invalid","unsupported exact Memory context query")}
    let identity=input.field("_axyndra_context_provider").getOrThrow()
    memoryDocumentFields(identity,["namespace","package_digest","generation","provider"])
    if(!httpServicePluginNamespace(memoryDocumentText(identity,"namespace")) ||
        !memoryContextPackageDigest(memoryDocumentText(identity,"package_digest")) ||
        memoryDocumentText(identity,"provider")!=(if(preparation){"prepare_window_context"}else{"memory_context"})){
        throw PureProviderError("memory.context_identity_invalid","exact observed typed context provider required")}
    let generation=memoryDocumentText(identity,"generation")
    try{if(UInt64.parse(generation)<1 || UInt64.parse(generation).toString()!=generation){
        throw PureProviderError("memory.context_identity_invalid","canonical package generation required")}}
    catch(_:Exception){throw PureProviderError("memory.context_identity_invalid","canonical package generation required")}
}
func memoryWindowContextNext(input:AgentValue,state:MemoryWindowState):AgentValue{
    memoryWindowContextInput(input,true)
    let headers=state.manifest.field("rows").getOrThrow().items;let offset=state.records.size
    if(offset==headers.size){return objectValue([ValueField("ready",boolValue(true))])}
    // Exact JSON metadata plus observed SQL json_quote(payload) byte length.
    // Native selects a continuous interval only; actual Store reconstructs
    // the selection from its own immutable manifest and full prior facts.
    let prefix=objectValue([ValueField("schema",textValue("axyndra.opaque-row-journal-rows/v1")),
        ValueField("manifest_sha256",textValue(state.manifestDigest)),ValueField("offset",integerValue(offset)),ValueField("rows",listValue([]))])
    var bytes=stringifyUnifiedJson(prefix).size;var count:Int64=0
    for(index in offset..headers.size){
        let header=headers[index]
        let empty=objectValue([ValueField("key",header.field("key").getOrThrow()),ValueField("revision",header.field("revision").getOrThrow()),
            ValueField("payload_sha256",header.field("payload_sha256").getOrThrow()),ValueField("payload",textValue(""))])
        let added=stringifyUnifiedJson(empty).size-2+memoryDocumentInteger(header,"payload_json_bytes")+(if(count>0){1}else{0})
        if(added>8388608-bytes){break};bytes+=added;count++
    }
    if(count<1){throw PureProviderError("memory.context_fragment_required","observed large record requires its original bounded fragment stream")}
    objectValue([ValueField("document_read",objectValue([ValueField("key",textValue(MEMORY_JOURNAL_KEY)),
        ValueField("window",objectValue([ValueField("kind",textValue("rows")),ValueField("manifest_fact",integerValue(0)),
            ValueField("offset",integerValue(offset)),ValueField("count",integerValue(count))]))]))])
}
func memoryWindowContextResult(input:AgentValue,state:MemoryWindowState):AgentValue{
    memoryWindowContextInput(input,false)
    let annotations=state.manifest.field("annotations").getOrThrow();let workspace=memoryDocumentText(annotations,"workspace_root")
    let journal=NativeMemoryJournal(state.records,DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
        firstAppearance:memoryDocumentRowKeys(state.manifest))
    let runtime=NativeMemoryTools(journal,NativeManagedSkillProposals([]),memoryDocumentText(annotations,"settings_root"),workspace,[])
    let content=match(runtime.contextFor(memoryDocumentText(input,"query"),SessionId(memoryDocumentText(annotations,"thread_id")),
        workspace,memoryDocumentInteger(input,"max_bytes"))){case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value}
    let rows=ArrayList<AgentValue>()
    if(content!=""){
        let fields=ArrayList<ValueField>([ValueField("id",textValue("memory")),ValueField("content",textValue(content)),ValueField("references",listValue([]))])
        if(runtime.contextValidUntilMillis()>0){fields.add(ValueField("valid_until_millis",integerValue(runtime.contextValidUntilMillis())))}
        rows.add(objectValue(fields.toArray()))
    }
    objectValue([ValueField("schema",textValue("axyndra.context-result/v1")),ValueField("contributions",listValue(rows.toArray()))])
}
