package memory_plugin

import agent_domain.*
import pure_provider_runtime.*
import std.collection.*
import std.convert.*
import std.time.*
import yjson.*
import yjson_support.*

// All lifecycle, ranking, deduplication and presentation remain Native
// business. The Host owns the preceding actual parentless ContextRead and
// validates this optional generic validity ceiling at consumption time.
// This is a descriptive, untrusted input check. Actual package ownership
// is verified by Host/Store from the frozen provider and canonical fact.
// Keep the existing raw SHA pure-data dialect and accept the real tagged
// PluginPackageDescriptor identity without creating any allowance.
func memoryContextPackageDigest(value:String):Bool{
    httpIntentDigest(value) || httpServicePackageDigest(value)
}

func memoryDocumentContextResult(input: AgentValue): AgentValue {
    memoryDocumentFields(input,["schema","query","max_bytes",CONTEXT_READ_INPUT_FIELD,"_axyndra_context_provider"])
    if(memoryDocumentText(input,"schema")!="axyndra.memory-context-query/v1"){
        throw PureProviderError("memory.context_query_invalid","unsupported exact Memory context query")}
    let identity=input.field("_axyndra_context_provider").getOrThrow()
    memoryDocumentFields(identity,["namespace","package_digest","generation","provider"])
    if(!httpServicePluginNamespace(memoryDocumentText(identity,"namespace")) ||
        !memoryContextPackageDigest(memoryDocumentText(identity,"package_digest")) ||
        memoryDocumentText(identity,"provider")!="memory_context"){
        throw PureProviderError("memory.context_identity_invalid","exact observed package description required")}
    let generation=memoryDocumentText(identity,"generation")
    try {if(UInt64.parse(generation)<1 || UInt64.parse(generation).toString()!=generation){
        throw PureProviderError("memory.context_identity_invalid","canonical package generation required")}
    }catch(_:Exception){throw PureProviderError("memory.context_identity_invalid","canonical package generation required")}
    let previous=memoryDocumentSnapshot(input);let history=memoryDocumentHistory(previous)
    let annotations=previous.field("annotations").getOrThrow()
    let workspace=memoryDocumentText(annotations,"workspace_root")
    let journal=NativeMemoryJournal(history,DateTime.nowUTC().toUnixTimeStamp().toMilliseconds(),
        firstAppearance:memoryDocumentRowKeys(previous))
    let runtime=NativeMemoryTools(journal,NativeManagedSkillProposals([]),memoryDocumentText(annotations,"settings_root"),workspace,[])
    let content=match(runtime.contextFor(memoryDocumentText(input,"query"),
        SessionId(memoryDocumentText(annotations,"thread_id")),workspace,memoryDocumentInteger(input,"max_bytes"))){
        case Result.Err(error)=>throw PureProviderError(error.code,error.message);case Result.Ok(value)=>value}
    let rows=ArrayList<AgentValue>()
    if(content!=""){
        let fields=ArrayList<ValueField>([ValueField("id",textValue("memory")),ValueField("content",textValue(content)),
            ValueField("references",listValue([]))])
        if(runtime.contextValidUntilMillis()>0){fields.add(ValueField("valid_until_millis",integerValue(runtime.contextValidUntilMillis())))}
        rows.add(objectValue(fields.toArray()))
    }
    objectValue([ValueField("schema",textValue("axyndra.context-result/v1")),ValueField("contributions",listValue(rows.toArray()))])
}
