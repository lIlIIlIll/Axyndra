package agent_product

import agent_host_runtime.*
import agent_core.*
import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.collection.*
import yjson.*
import yjson_support.*

// Operator configuration chooses logical keys and two actual typed providers.
// Native preparation may select windows, never Source, paths or read rights.
func parseInitialContextWindowSelection(settingsRoot:String,value:AgentValue,configurationText:String,
    runtime:?ProductPluginRuntime):Result<ProductInitialContextSelection>{
    if(!httpIntentExactFields(value,["version","namespace","package_digest","provider","preparation_provider","resources","query","prompt_field"]) ||
        value.field("preparation_provider").getOrThrow().unifiedKind!=ValueKind.Text){
        return initialContextError("context.initial_configuration_invalid")}
    let preparation=httpIntentText(value,"preparation_provider")
    if(preparation.trimAscii()=="" || preparation.size>128 || preparation.contains("\u{0000}") ||
        preparation==httpIntentText(value,"provider")){
        return initialContextError("context.initial_configuration_invalid")}
    // Reuse every original strict v5 validation before constructing v7.
    let fields=ArrayList<ValueField>()
    for(field in value.fields where field.name!="preparation_provider"){
        fields.add(if(field.name=="version"){ValueField("version",integerValue(5))}else{field})}
    match(parseInitialContextSelection(settingsRoot,stringifyUnifiedJson(objectValue(fields.toArray())),runtime,
        configurationText:Some(configurationText))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result.Ok(ProductInitialContextSelection(settingsRoot,value,configurationText,runtime,[],Option<ProductContextComponentSnapshot>.None))
}

func initialDocumentWindowConfiguration(host:ProductJavaScriptPluginHost,selection:ProductInitialContextSelection,
    finalBinding:ProductPluginContentBinding):Result<HostPluginDocumentContextWindowConfiguration>{
    let preparation=match(host.contentProviderBinding(selection.namespace,selection.preparationProvider,false)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    if(finalBinding.digest!=selection.packageDigest || preparation.digest!=finalBinding.digest ||
        preparation.generation!=finalBinding.generation){return initialContextError("context.initial_binding_changed")}
    let configuration=match(host.documentContextWindowConfiguration(selection.namespace,finalBinding.digest,selection.preparationProvider)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    for(key in selection.resources().items where !configuration.permits(key.text)){
        return initialContextError("context.document_rights_denied")}
    match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result.Ok(configuration)
}
func preflightInitialDocumentWindowSelection(host:ProductJavaScriptPluginHost,selection:ProductInitialContextSelection,
    finalBinding:ProductPluginContentBinding):Result<Unit>{
    match(initialDocumentWindowConfiguration(host,selection,finalBinding)){
        case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(())}
}

func productInitialDocumentWindowPreparation(host:ProductJavaScriptPluginHost,operations:OperationRuntimePort,
    selection:ProductInitialContextSelection,finalBinding:ProductPluginContentBinding,before:ActiveRunSnapshot,
    context:ToolInvocationContext,prompt:String,ids:ProductIds):Result<InitialContextPreparation>{
    let configuration=match(initialDocumentWindowConfiguration(host,selection,finalBinding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let lane=match(operations.pluginDocumentLane(before.threadId,before.runId,before.epoch)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let query=selection.query(prompt)
    if(query.field(CONTEXT_READ_INPUT_FIELD).isSome() || query.field("_axyndra_context_provider").isSome()){
        return initialContextError("context.initial_configuration_invalid")}
    let identity=objectValue([ValueField("namespace",textValue(selection.namespace)),ValueField("package_digest",textValue(finalBinding.digest)),
        ValueField("generation",textValue(finalBinding.generation.toString())),ValueField("configuration_digest",textValue(configuration.digest)),
        ValueField("thread_id",textValue(before.threadId.value)),ValueField("lane_id",textValue(lane.value)),
        ValueField("run_id",textValue(before.runId.value)),ValueField("epoch",integerValue(before.epoch)),
        ValueField("provider",textValue(selection.preparationProvider))])
    let sequence=ProductInitialDocumentWindowSequence(host,selection,configuration,finalBinding,before,context,identity,query,ids)
    match(sequence.validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    // This first query is pure, bounded metadata. No document byte is read.
    let preparation=match(host.contentProviderBinding(selection.namespace,selection.preparationProvider,false)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let response=match(contentProviderQuery(host,preparation,objectValue([
        ValueField("schema",textValue("axyndra.context-window-preparation-query/v1")),
        ValueField("provider",textValue(selection.provider)),ValueField("input",query)]),
        before.threadId,context.cancellation,ids.nextInvocationId())){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let first=try{sequence.select(response.value,context,[])}finally{response.close()}
    let read=match(first){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(sequence.validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result.Ok(InitialContextPreparation(read,validity:{=>sequence.validate()},
        sequence:Some(ContextReadSequence(8,{actual,facts=>sequence.advance(actual,facts)},
            transition:Some({old,next=>sequence.validateTransition(old,next)})))))
}

class ProductInitialDocumentWindowSequence {
    private let host:ProductJavaScriptPluginHost
    private let selection:ProductInitialContextSelection
    private let configuration:HostPluginDocumentContextWindowConfiguration
    private let finalBinding:ProductPluginContentBinding
    private let before:ActiveRunSnapshot
    private let initial:ToolInvocationContext
    private let identityJson:String
    private let queryJson:String
    private let ids:ProductIds
    private let requests=ArrayList<String>()
    private var documentKey:String=""
    private var transitionFrom:?String=None
    private var transitionTo:?String=None
    private var completed:Bool=false
    init(host:ProductJavaScriptPluginHost,selection:ProductInitialContextSelection,
        configuration:HostPluginDocumentContextWindowConfiguration,finalBinding:ProductPluginContentBinding,
        before:ActiveRunSnapshot,initial:ToolInvocationContext,identity:AgentValue,query:AgentValue,ids:ProductIds){
        this.host=host;this.selection=selection;this.configuration=configuration;this.finalBinding=finalBinding
        this.before=before;this.initial=initial;this.identityJson=stringifyUnifiedJson(identity)
        this.queryJson=stringifyUnifiedJson(query);this.ids=ids
    }
    func validate():Result<Unit>{
        match(selection.current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(initial.cancellation.isCancelled()){return initialContextError("context.read_update_cancelled")}
        for(provider in [selection.provider,selection.preparationProvider]){
            let binding=match(host.contentProviderBinding(selection.namespace,provider,false)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            if(binding.generation!=finalBinding.generation || binding.digest!=finalBinding.digest){
                return initialContextError("context.initial_binding_changed")}}
        Result.Ok(())
    }
    private func binding():AgentValue{parseUnifiedJson(identityJson,maxBytes:16384)}
    private func caller(actual:ToolInvocationContext):Result<Unit>{
        if(actual.sessionId.value!=before.threadId.value || actual.runId.value!=before.runId.value || actual.epoch!=before.epoch ||
            contextReadProjectionDigest(actual.contextProjection)!=contextReadProjectionDigest(before.contextSnapshot)){
            return initialContextError("context.read_binding_invalid")}
        match(validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        hostDocumentContextWindowPreparationCurrent(host,configuration,finalBinding.generation,actual,binding())
    }
    func select(value:AgentValue,actual:ToolInvocationContext,facts:Array<ContextReadFact>):Result<ToolPreparationRead>{
        match(caller(actual)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(completed || requests.size>=8 || !httpIntentExactFields(value,["document_read"]) ||
            !httpIntentExactFields(value.field("document_read").getOrThrow(),["key","window"])){
            return initialContextError("context.window_selection_invalid")}
        let selected=value.field("document_read").getOrThrow();let key=httpIntentText(selected,"key")
        var allowed=false
        for(item in selection.resources().items where item.text==key){allowed=true}
        if(!allowed || !configuration.permits(key) || (documentKey!="" && key!=documentKey)){
            return initialContextError("context.document_rights_denied")}
        let request=objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_CONTEXT_WINDOW_READ_SCHEMA)),
            ValueField("binding",binding()),ValueField("projection_digest",textValue(contextReadProjectionDigest(before.contextSnapshot))),
            ValueField("key",textValue(key)),ValueField("window",selected.field("window").getOrThrow()),
            ValueField("prior_facts",contextReadFactLinksValue(facts.map{fact=>fact.link()}))])
        let frozen=match(hostPrepareDocumentContextWindowRead(host,actual,request)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let encoded=stringifyUnifiedJson(frozen);let exact=canonicalAgentValue(frozen)
        if(!requests.isEmpty()){transitionFrom=Some(canonicalAgentValue(parseUnifiedJson(requests[requests.size-1],maxBytes:16384)));transitionTo=Some(exact)}
        documentKey=key;requests.add(encoded)
        Result.Ok(ToolPreparationRead(selection.namespace,finalBinding.digest,configuration.digest,frozen,
            {_,_=>initialContextError<AgentValue>("context.sequence_required")},boundary:Some({current,args=>
                if(canonicalAgentValue(args)!=exact){return initialContextError<Unit>("context.read_binding_invalid")}
                caller(current)})))
    }
    func validateTransition(old:ToolPreparationRead,next:ToolPreparationRead):Result<Unit>{
        match(validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(transitionFrom.isNone() || transitionTo.isNone() || old.ownerNamespace!=selection.namespace ||
            next.ownerNamespace!=selection.namespace || old.packageDigest!=finalBinding.digest || next.packageDigest!=finalBinding.digest ||
            old.configurationDigest!=configuration.digest || next.configurationDigest!=configuration.digest ||
            canonicalAgentValue(old.request())!=transitionFrom.getOrThrow() || canonicalAgentValue(next.request())!=transitionTo.getOrThrow()){
            return initialContextError("context.read_update_next_invalid")}
        transitionFrom=None;transitionTo=None;Result.Ok(())
    }
    private func input(provider:String,data:AgentValue,facts:Array<ContextReadFact>):AgentValue{
        let fields=ArrayList<ValueField>();for(field in parseUnifiedJson(queryJson,maxBytes:65536).fields){fields.add(field)}
        fields.add(ValueField("_axyndra_context_provider",objectValue([ValueField("namespace",textValue(selection.namespace)),
            ValueField("package_digest",textValue(finalBinding.digest)),ValueField("generation",textValue(finalBinding.generation.toString())),
            ValueField("provider",textValue(provider))])))
        fields.add(ValueField(CONTEXT_READ_INPUT_FIELD,objectValue([ValueField("schema",textValue("axyndra.context-read-input/v2")),
            ValueField("data",data),ValueField("facts",contextReadFactLinksValue(facts.map{fact=>fact.link()}))])))
        objectValue(fields.toArray())
    }
    func advance(actual:ToolInvocationContext,facts:Array<ContextReadFact>):Result<ContextReadNext>{
        match(caller(actual)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(completed || facts.isEmpty() || facts.size!=requests.size || facts.size>8){
            return initialContextError("context.sequence_fact_invalid")}
        let seen=HashSet<String>();let values=ArrayList<AgentValue>()
        for(index in 0..facts.size){let fact=facts[index];let origin=fact.origin
            if(seen.contains(fact.operationId.value) || fact.runId.value!=before.runId.value ||
                origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
                origin.parentDecisionId!="" || origin.parentScopedCallId!="" || origin.ownerNamespace!=selection.namespace ||
                origin.packageDigest!=finalBinding.digest || origin.configurationDigest!=configuration.digest ||
                origin.projectionDigest!=contextReadProjectionDigest(before.contextSnapshot) ||
                !pluginDocumentContextWindowReadResultValid(fact.output(),parseUnifiedJson(requests[index],maxBytes:16384))){
                return initialContextError("context.sequence_fact_invalid")}
            seen.add(fact.operationId.value);values.add(fact.output())}
        let data=listValue(values.toArray());let links=facts.map{fact=>fact.link()}
        let prefix=match(hostQueryDocumentContextWindowPrefix(host,configuration,actual,binding(),
            input(selection.preparationProvider,data,facts),links,data,ids.nextInvocationId(),{=>validate()})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        var prefixClosed:Result<Unit> = Result.Ok(())
        let selectedRead=try{selectPaidPrefix(prefix.value,actual,facts)}finally{prefixClosed=prefix.close()}
        match(prefixClosed){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let selectedPrefixRead=match(selectedRead){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(let Some(read)<-selectedPrefixRead){return Result.Ok(ContextReadNext.Read(read))}
        // Store checks the entire continuous corpus again before this final
        // pure query; a descriptive ready flag never replaces that proof.
        let finalInput=input(selection.provider,data,facts)
        let response=match(hostQueryDocumentContextWindowFinal(host,configuration,actual,binding(),selection.provider,
            finalInput,links,data,ids.nextInvocationId(),{=>validate()})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        // Document windows attest opaque rows, not filesystem metadata.
        // The exact full fact links still bind finalInput and the Context cut;
        // no document byte can mint an observed-path filesystem locator.
        var responseClosed:Result<Unit> = Result.Ok(())
        let ready=try{completePaidResult(actual,facts,finalInput,response.value)}finally{responseClosed=response.close()}
        match(responseClosed){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let readyProjection=match(ready){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        completed=true
        Result.Ok(readyProjection)
    }

    // The original small selector and all parse/canonical/selection copies
    // remain within the real prefix owner's paid lifetime. Only the bounded
    // Core request DTO is transferred after physical owner cleanup.
    private func selectPaidPrefix(decision:AgentValue,actual:ToolInvocationContext,
        facts:Array<ContextReadFact>):Result<?ToolPreparationRead>{
        let encoded=try{stringifyUnifiedJson(decision)}catch(_:Exception){return initialContextError("context.window_selection_invalid")}
        match(caller(actual)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let selected=parseUnifiedJson(encoded,maxBytes:16384)
        if(!httpIntentExactFields(selected,["ready"]) || selected.field("ready").getOrThrow().unifiedKind!=ValueKind.Boolean ||
            !selected.field("ready").getOrThrow().asBool()){
            let next=match(select(selected,actual,facts)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            return Result.Ok(Some(next))}
        Result.Ok(Option<ToolPreparationRead>.None)
    }

    // Final codec/provenance validation, merge, canonical facts and digest
    // finish before the actual response reservation and worker are released.
    // The caller marks completion only after cleanup succeeds.
    private func completePaidResult(actual:ToolInvocationContext,facts:Array<ContextReadFact>,
        finalInput:AgentValue,value:AgentValue):Result<ContextReadNext>{
        let projection=resolveObservedProductContextValue(host,finalBinding,finalInput,[],actual.cancellation,value,[])
        let selectedContext=match(projection){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        match(caller(actual)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let owner=selection.namespace+"/context/"+selection.provider;let items=ArrayList<InvocationContextContribution>()
        for(item in before.contextSnapshot.contributions() where item.owner!=owner){items.add(item)}
        for(item in selectedContext.contributions()){
            if(item.owner!=owner){return initialContextError("context.document_owner_invalid")};items.add(item)}
        let snapshot=InvocationContextProjection(contributions:items.toArray())
        let links=facts.map{fact=>fact.link()}
        Result.Ok(ContextReadNext.Ready(InvocationContextProjection(contributions:items.toArray(),sourceDigest:
            modelPolicySha256Text(canonicalAgentValue(objectValue([ValueField("configuration_digest",textValue(selection.digest)),
                ValueField("context",contextSnapshotValue(snapshot)),ValueField("facts",contextReadFactLinksValue(links))]))))))
    }
}
