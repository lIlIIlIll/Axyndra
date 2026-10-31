package agent_product

import agent_host_runtime.*
import agent_extension_runtime.*
import agent_core.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Explicit opt-in to a generic structural stream. Both protocol schemas come
// from the same current operator bytes, not a Native callback or a registry.
func parseInitialContextJournalSelection(settingsRoot:String,value:AgentValue,configurationText:String,
    runtime:?ProductPluginRuntime):Result<ProductInitialContextSelection>{
    if(!httpIntentExactFields(value,["version","namespace","package_digest","provider","preparation_provider","resources","query","prompt_field","data_schema","preparation_schema"])){
        return initialContextError("context.initial_configuration_invalid")}
    for(name in ["data_schema","preparation_schema"]){
        let field=value.field(name).getOrThrow()
        if(field.unifiedKind!=ValueKind.Text || field.text.trimAscii()=="" || field.text.size>128 || field.text.contains("\u{0000}")){
            return initialContextError("context.initial_configuration_invalid")}}
    let fields=ArrayList<ValueField>()
    for(field in value.fields where !["data_schema","preparation_schema"].contains(field.name)){
        fields.add(if(field.name=="version"){ValueField("version",integerValue(7))}else{field})}
    // All original strict v7 provider/key/prompt/config validations are reused.
    match(parseInitialContextSelection(settingsRoot,stringifyUnifiedJson(objectValue(fields.toArray())),runtime,
        configurationText:Some(configurationText))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    if(value.field("query").getOrThrow().field("_axyndra_context_provider").isSome() ||
        httpIntentText(value,"prompt_field")=="_axyndra_context_provider"){
        return initialContextError("context.initial_configuration_invalid")}
    Result.Ok(ProductInitialContextSelection(settingsRoot,value,configurationText,runtime,[],Option<ProductContextComponentSnapshot>.None))
}

func journalContextObservedParameters(query:AgentValue,finalBinding:ProductPluginContentBinding):Result<AgentValue>{
    if(query.unifiedKind!=ValueKind.Object || query.field(CONTEXT_READ_INPUT_FIELD).isSome() || query.field("_axyndra_context_provider").isSome()){
        return initialContextError("context.initial_configuration_invalid")}
    let fields=ArrayList<ValueField>()
    for(field in query.fields){fields.add(field)}
    fields.add(ValueField("_axyndra_context_provider",objectValue([ValueField("namespace",textValue(finalBinding.namespace)),
        ValueField("package_digest",textValue(finalBinding.digest)),ValueField("generation",textValue(finalBinding.generation.toString())),
        ValueField("provider",textValue(finalBinding.contribution))])))
    Result.Ok(objectValue(fields.toArray()))
}
func journalContextParameterDescription(value:AgentValue):Result<AgentValue>{
    let bound=try{logicalJsonWriteReservationBytes(value,CONTENT_PAYLOAD_MESSAGE_BYTES)}
        catch(_:Exception){return initialContextError("context.query_limit")}
    if(bound>CONTENT_PAYLOAD_MESSAGE_BYTES){return initialContextError("context.query_limit")}
    let phase=try{reserveNativeContentJson(value,CONTENT_PAYLOAD_MESSAGE_BYTES)}
        catch(_:Exception){return initialContextError("context.query_limit")}
    try{
        // Pay raw encoding, bytes and scalar fields before allocation. The
        // descriptor escapes only after every full parameter byte is hashed.
        phase.ensureRetainedPeak(2097152+bound*4)
        let raw=stringifyUnifiedJson(value);let bytes=raw.toArray()
        if(bytes.size<2 || bytes.size>CONTENT_PAYLOAD_MESSAGE_BYTES){return initialContextError("context.query_limit")}
        Result.Ok(objectValue([ValueField("bytes",integerValue(bytes.size)),ValueField("sha256",textValue(modelPolicySha256(bytes)))]))
    }catch(_:Exception){initialContextError("context.query_limit")}
    finally{phase.close()}
}
class InitialJournalContextConfigurations {
    let read:HostPluginDocumentJournalReadConfiguration
    let compute:HostPluginDocumentJournalReadConfiguration
    init(read:HostPluginDocumentJournalReadConfiguration,compute:HostPluginDocumentJournalReadConfiguration){this.read=read;this.compute=compute}
}
func initialJournalContextConfigurations(host:ProductJavaScriptPluginHost,selection:ProductInitialContextSelection,
    finalBinding:ProductPluginContentBinding):Result<InitialJournalContextConfigurations>{
    let preparation=match(host.contentProviderBinding(selection.namespace,selection.preparationProvider,false)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(finalBinding.digest!=selection.packageDigest || preparation.digest!=finalBinding.digest || preparation.generation!=finalBinding.generation){
        return initialContextError("context.initial_binding_changed")}
    // Invoke the existing trusted backend owner callback. This binds data
    // access only, never an Operation, ReadGrant, Root or approval allowance.
    match(host.documentConfiguration(selection.namespace,finalBinding.digest)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let read=match(host.documentJournalReadConfiguration(selection.namespace,finalBinding.digest,selection.preparationProvider,"",true)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let compute=match(host.documentJournalReadConfiguration(selection.namespace,finalBinding.digest,selection.provider,"",true)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    for(key in selection.resources().items){
        if(!read.permits(key.text) || !compute.permits(key.text) || read.access(key.text).isNone() || read.view(key.text).isNone() ||
            compute.access(key.text).isNone() || compute.view(key.text).isNone() ||
            read.access(key.text).getOrThrow().digest!=compute.access(key.text).getOrThrow().digest ||
            read.view(key.text).getOrThrow().digest!=compute.view(key.text).getOrThrow().digest){
            return initialContextError("context.document_rights_denied")}}
    match(read.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    match(compute.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result.Ok(InitialJournalContextConfigurations(read,compute))
}
func preflightInitialJournalContextSelection(host:ProductJavaScriptPluginHost,selection:ProductInitialContextSelection,
    finalBinding:ProductPluginContentBinding,prompt:String):Result<Unit>{
    match(initialJournalContextConfigurations(host,selection,finalBinding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let parameters=match(journalContextObservedParameters(selection.query(prompt),finalBinding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(journalContextParameterDescription(parameters)){
        case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(())}
}

func productInitialJournalContextPreparation(host:ProductJavaScriptPluginHost,operations:OperationRuntimePort,
    selection:ProductInitialContextSelection,finalBinding:ProductPluginContentBinding,before:ActiveRunSnapshot,
    context:ToolInvocationContext,prompt:String,ids:ProductIds):Result<InitialContextPreparation>{
    let configurations=match(initialJournalContextConfigurations(host,selection,finalBinding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let lane=match(operations.pluginDocumentLane(before.threadId,before.runId,before.epoch)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let binding=objectValue([ValueField("namespace",textValue(selection.namespace)),ValueField("package_digest",textValue(finalBinding.digest)),
        ValueField("generation",textValue(finalBinding.generation.toString())),ValueField("configuration_digest",textValue(configurations.read.digest)),
        ValueField("thread_id",textValue(before.threadId.value)),ValueField("lane_id",textValue(lane.value)),ValueField("run_id",textValue(before.runId.value)),
        ValueField("epoch",integerValue(before.epoch)),ValueField("provider",textValue(selection.preparationProvider))])
    let continuation=ProductInitialJournalContextSequence(host,selection,configurations,finalBinding,before,context,prompt,binding,ids)
    match(continuation.validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let parameters=match(journalContextObservedParameters(selection.query(prompt),finalBinding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let description=match(journalContextParameterDescription(parameters)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let preparation=match(host.contentProviderBinding(selection.namespace,selection.preparationProvider,false)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let response=match(contentProviderQuery(host,preparation,objectValue([ValueField("schema",textValue(selection.journalPreparationSchema)),
        ValueField("provider",textValue(selection.provider)),ValueField("input_payload",description)]),before.threadId,context.cancellation,ids.nextInvocationId())){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let selected=try{continuation.select(response.value,context)}finally{response.close()}
    let read=match(selected){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    Result.Ok(InitialContextPreparation(read,validity:{=>continuation.validate()},
        sequence:Some(ContextReadSequence(1,{actual,facts=>continuation.advance(actual,facts)}))))
}

class ProductInitialJournalContextSequence {
    private let host:ProductJavaScriptPluginHost
    private let selection:ProductInitialContextSelection
    private let configurations:InitialJournalContextConfigurations
    private let finalBinding:ProductPluginContentBinding
    private let before:ActiveRunSnapshot
    private let initial:ToolInvocationContext
    private let prompt:String
    private let identity:String
    private let ids:ProductIds
    private var requestJson=""
    private var completed=false
    init(host:ProductJavaScriptPluginHost,selection:ProductInitialContextSelection,configurations:InitialJournalContextConfigurations,
        finalBinding:ProductPluginContentBinding,before:ActiveRunSnapshot,initial:ToolInvocationContext,prompt:String,binding:AgentValue,ids:ProductIds){
        this.host=host;this.selection=selection;this.configurations=configurations;this.finalBinding=finalBinding;this.before=before
        this.initial=initial;this.prompt=prompt;this.identity=stringifyUnifiedJson(binding);this.ids=ids}
    func validate():Result<Unit>{
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(configurations.read.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(configurations.compute.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(initial.cancellation.isCancelled()){return initialContextError("context.read_update_cancelled")}
        for(provider in [selection.preparationProvider,selection.provider]){
            let binding=match(host.contentProviderBinding(selection.namespace,provider,false)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(binding.generation!=finalBinding.generation || binding.digest!=finalBinding.digest){
                return initialContextError("context.initial_binding_changed")}}
        Result.Ok(())
    }
    private func caller(actual:ToolInvocationContext):Result<Unit>{
        if(actual.sessionId.value!=before.threadId.value || actual.runId.value!=before.runId.value || actual.epoch!=before.epoch ||
            contextReadProjectionDigest(actual.contextProjection)!=contextReadProjectionDigest(before.contextSnapshot)){
            return initialContextError("context.read_binding_invalid")}
        validate()
    }
    func select(value:AgentValue,actual:ToolInvocationContext):Result<ToolPreparationRead>{
        match(caller(actual)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(requestJson!="" || completed || !httpIntentExactFields(value,["document_read"]) ||
            !httpIntentExactFields(value.field("document_read").getOrThrow(),["key","stream"]) ||
            httpIntentText(value.field("document_read").getOrThrow(),"stream")!="event-latest-structural-read"){
            return initialContextError("context.journal_selection_invalid")}
        let key=httpIntentText(value.field("document_read").getOrThrow(),"key");var selected=false
        for(item in selection.resources().items where item.text==key){selected=true}
        if(!selected || !configurations.read.permits(key) || !configurations.compute.permits(key)){
            return initialContextError("context.document_rights_denied")}
        let binding=parseUnifiedJson(identity,maxBytes:16384)
        let request=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_CONTEXT_LATEST_JOURNAL_STREAM_READ_SCHEMA)),ValueField("binding",binding),
            ValueField("projection_digest",textValue(contextReadProjectionDigest(before.contextSnapshot))),ValueField("key",textValue(key)),
            ValueField("access_policy_digest",textValue(configurations.read.access(key).getOrThrow().digest)),
            ValueField("view_policy_digest",textValue(configurations.read.view(key).getOrThrow().digest))])
        let frozen=match(hostPrepareLatestJournalRead(host,actual,request)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        requestJson=stringifyUnifiedJson(frozen);let exact=canonicalAgentValue(frozen)
        Result.Ok(ToolPreparationRead(selection.namespace,finalBinding.digest,configurations.read.digest,frozen,
            {_,_=>initialContextError<AgentValue>("context.sequence_required")},boundary:Some({current,args=>
                if(canonicalAgentValue(args)!=exact){return initialContextError<Unit>("context.read_binding_invalid")}
                match(caller(current)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                hostLatestJournalPreparationCurrent(host,configurations.read,finalBinding.generation,current,args)})))
    }
    func advance(actual:ToolInvocationContext,facts:Array<ContextReadFact>):Result<ContextReadNext>{
        match(caller(actual)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(completed || requestJson=="" || facts.size!=1){return initialContextError("context.sequence_fact_invalid")}
        let fact=facts[0];let origin=fact.origin;let request=parseUnifiedJson(requestJson,maxBytes:16384)
        if(fact.runId.value!=before.runId.value || origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
            origin.parentDecisionId!="" || origin.parentScopedCallId!="" || origin.ownerNamespace!=selection.namespace ||
            origin.packageDigest!=finalBinding.digest || origin.configurationDigest!=configurations.read.digest ||
            origin.projectionDigest!=contextReadProjectionDigest(before.contextSnapshot) ||
            !pluginDocumentContextLatestJournalStreamReadResultValid(fact.output(),request)){
            return initialContextError("context.sequence_fact_invalid")}
        let query=selection.query(prompt)
        // This full actual link/output is reloaded by129 in the same TX; the
        // early Core DTO is not the authorizer for any byte or final write.
        let output=match(runPreparedLatestJournalContext(host,configurations.read,configurations.compute,finalBinding.generation,actual,
            ids.nextInvocationId(),fact.link(),request.field("binding").getOrThrow(),request,fact.output(),query,selection.journalDataSchema,{=>validate()})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        var cleanup:Result<Unit> = Result.Ok(())
        let ready=try{complete(actual,facts,query,output.value)}finally{cleanup=output.close()}
        match(cleanup){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let projection=match(ready){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        completed=true;Result.Ok(projection)
    }
    private func complete(actual:ToolInvocationContext,facts:Array<ContextReadFact>,query:AgentValue,value:AgentValue):Result<ContextReadNext>{
        // Real output owner remains paid through codec/projection checks,
        // complete snapshot merge and full actual fact provenance digest.
        let input=match(journalContextObservedParameters(query,finalBinding)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        input.put(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",textValue("axyndra.context-read-input/v2")),
            ValueField("data",listValue([facts[0].output()])),ValueField("facts",contextReadFactLinksValue([facts[0].link()]))]))
        let selected=match(resolveObservedProductContextValue(host,finalBinding,input,[],actual.cancellation,value,[])){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(caller(actual)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let owner=selection.namespace+"/context/"+selection.provider;let items=ArrayList<InvocationContextContribution>()
        for(item in before.contextSnapshot.contributions() where item.owner!=owner){items.add(item)}
        for(item in selected.contributions()){
            if(item.owner!=owner){return initialContextError("context.document_owner_invalid")};items.add(item)}
        let snapshot=InvocationContextProjection(contributions:items.toArray())
        Result.Ok(ContextReadNext.Ready(InvocationContextProjection(contributions:items.toArray(),sourceDigest:
            modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("configuration_digest",textValue(selection.digest)),
                ValueField("context",contextSnapshotValue(snapshot)),ValueField("facts",contextReadFactLinksValue([facts[0].link()]))]))))))
    }
}
