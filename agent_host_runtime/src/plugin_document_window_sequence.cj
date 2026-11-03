package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import agent_ports.*
import agent_extension_runtime.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

public func hostPrepareWindowDocumentRead(host:HostJavaScriptPluginHost,context:ToolInvocationContext,args:AgentValue):Result<AgentValue>{
    if(!pluginDocumentRowJournalReadRequestValid(args) || httpIntentText(args,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)){
        return hostPluginResourceError("plugin.document_window_read_request","window read requires its exact current projection")}
    let binding=args.field("binding").getOrThrow()
    let configuration=match(host.documentConfiguration(httpIntentText(binding,"namespace"),httpIntentText(binding,"package_digest"))){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    match(hostDocumentPreparationCurrent(host,configuration,UInt64.parse(httpIntentText(binding,"generation")),context,binding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let prefix="plugin."+configuration.namespace+".";let name=httpIntentText(binding,"contribution")
    if(!name.startsWith(prefix) || !configuration.readWindows(name[prefix.size..]) ||
        !configuration.payloadReferences(name[prefix.size..]) || !configuration.permits(name[prefix.size..],httpIntentText(args,"key"),false)){
        return hostPluginResourceError("plugin.document_window_profile_changed","window read is not explicitly selected by this exact operator profile")}
    Result.Ok(parseUnifiedJson(stringifyUnifiedJson(args),maxBytes:65536))
}

// Captured by the real catalog resolver. It retains compact requests/pages
// only; Runtime still creates and approves every canonical ContextRead root.
class HostDocumentWindowSequence {
    private let host:HostJavaScriptPluginHost
    private let configuration:HostPluginDocumentConfiguration
    private let generation:UInt64
    private let key:String
    private let bindingJson:String
    private let projection:String
    private let original:String
    private let lock=Mutex()
    private let requests=ArrayList<String>()
    private var pages:?String=None
    init(host:HostJavaScriptPluginHost,configuration:HostPluginDocumentConfiguration,generation:UInt64,
        key:String,binding:AgentValue,context:ToolInvocationContext,call:ToolCall){
        this.host=host;this.configuration=configuration;this.generation=generation;this.key=key
        bindingJson=stringifyUnifiedJson(binding);projection=contextReadProjectionDigest(context.contextProjection)
        original=stringifyUnifiedJson(call.arguments)
    }
    private func binding():AgentValue{parseUnifiedJson(bindingJson,maxBytes:16384)}
    private func current(context:ToolInvocationContext):Result<Unit>{
        if(contextReadProjectionDigest(context.contextProjection)!=projection){
            return hostPluginResourceError("plugin.document_window_projection_changed","window prefix cannot cross actual projections")}
        hostDocumentPreparationCurrent(host,configuration,generation,context,binding())
    }
    private func currentData(context:ToolInvocationContext):Result<Unit>{
        let bound=binding()
        if(context.cancellation.isCancelled() || context.sessionId.value!=httpIntentText(bound,"thread_id") ||
            context.runId.value!=httpIntentText(bound,"run_id") || context.epoch.toString()!=bound.field("epoch").getOrThrow().asNumberText() ||
            !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:configuration.namespace)){
            return hostPluginResourceError("plugin.document_window_scope_changed","window prefix lost its original caller ceiling")}
        configuration.validateTransferWitness()
    }
    private func request(window:AgentValue,facts:Array<ContextReadFact>):AgentValue{
        objectValue([ValueField("schema",textValue(PLUGIN_DOCUMENT_ROW_JOURNAL_READ_SCHEMA)),ValueField("binding",binding()),
            ValueField("projection_digest",textValue(projection)),ValueField("key",textValue(key)),ValueField("window",window),
            ValueField("prior_facts",contextReadFactLinksValue(facts.map{fact=>fact.link()}))])
    }
    private func read(value:AgentValue,first:Bool):ToolPreparationRead{
        if(!pluginDocumentRowJournalReadRequestValid(value)){throw IllegalArgumentException("invalid frozen window selector")}
        let encoded=stringifyUnifiedJson(value);requests.add(encoded)
        let sequence:?ToolPreparationReadSequence=if(first){Some(ToolPreparationReadSequence(8,{context,facts=>advance(context,facts)}))}else{None}
        ToolPreparationRead(configuration.namespace,configuration.packageDigest,configuration.digest,value,
            {context,facts=>ready(context,facts)},boundary:Some({context,arguments=>
                if(canonicalAgentValue(arguments)!=canonicalAgentValue(parseUnifiedJson(encoded,maxBytes:65536))){
                    return hostPluginResourceError("plugin.document_window_read_changed","actual read differs from its retained selector")}
                current(context)}),sequence:sequence)
    }
    func begin():ToolPreparationRead{read(request(objectValue([ValueField("kind",textValue("manifest"))]),[]),true)}
    private func validateFacts(context:ToolInvocationContext,facts:Array<ContextReadFact>):Result<Unit>{
        match(current(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(facts.isEmpty() || facts.size!=requests.size || facts.size>8){
            return hostPluginResourceError("plugin.document_window_fact_changed","window sequence lacks its entire expected fact prefix")}
        let ids=HashSet<String>();let first=facts[0].origin
        for(index in 0..facts.size){let fact=facts[index];let origin=fact.origin
            if(ids.contains(fact.operationId.value) || fact.runId.value!=context.runId.value || origin.parentCallItemId=="" ||
                origin.ownerNamespace!=configuration.namespace || origin.packageDigest!=configuration.packageDigest ||
                origin.configurationDigest!=configuration.digest || origin.projectionDigest!=projection ||
                origin.parentCallItemId!=first.parentCallItemId || origin.parentKind!=first.parentKind ||
                origin.parentOperationId!=first.parentOperationId || origin.parentDecisionId!=first.parentDecisionId ||
                origin.parentScopedCallId!=first.parentScopedCallId ||
                !pluginDocumentRowJournalReadResultValid(fact.output(),parseUnifiedJson(requests[index],maxBytes:65536))){
                return hostPluginResourceError("plugin.document_window_fact_changed","window sequence has a substituted fact or actual owner")}
            ids.add(fact.operationId.value)}
        Result.Ok(())
    }
    private func ready(context:ToolInvocationContext,facts:Array<ContextReadFact>):Result<AgentValue>{
        match(validateFacts(context,facts)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(pages.isNone() || facts.size!=parseUnifiedJson(pages.getOrThrow(),maxBytes:65536).items.size+1){
            return hostPluginResourceError("plugin.document_window_incomplete","complete manifest ranges are required before Native preparation")}
        Result.Ok(contextReadSequenceInput(parseUnifiedJson(original,maxBytes:8388608),facts))
    }
    private func advance(context:ToolInvocationContext,facts:Array<ContextReadFact>):Result<ToolPreparationReadNext>{
        lock.lock()
        try{
            match(validateFacts(context,facts)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(pages.isNone()){
                let owner=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                let links=facts.map{fact=>fact.link()};let data=listValue(facts.map{fact=>fact.output()})
                let reference=parsePluginDocumentPayloadReference(facts[0].output().field("documents").getOrThrow().items[0].field("payload").getOrThrow()).value().getOrThrow()
                let revoked=AtomicBool(false)
                let registration=match(host.observeServiceRevocation(configuration.namespace,generation,{=>revoked.store(true)})){
                    case Result.Err(error)=>let _=owner.close();return Result.Err(error);case Result.Ok(value)=>value}
                let guard={=>if(revoked.load()){
                        return hostPluginResourceError<Unit>("plugin.document_window_revoked","window selector owner was revoked")}
                    currentData(context)}
                let outcome=try{owner.run({session=>
                    match(host.commitDocumentEffect(configuration.namespace,generation,configuration.packageDigest,{=>
                        session.authorizeWindowPrefix(links,binding(),data,guard)})){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                    session.readWindowManifestPages(reference,guard)})}finally{registration.dispose()}
                let selected=match(outcome){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                pages=Some(stringifyUnifiedJson(selected))
            }
            let ranges=parseUnifiedJson(pages.getOrThrow(),maxBytes:65536)
            if(facts.size<=ranges.items.size){
                let range=ranges.items[facts.size-1]
                let window=objectValue([ValueField("kind",textValue("rows")),ValueField("manifest_fact",integerValue(0)),
                    ValueField("offset",range.field("offset").getOrThrow()),ValueField("count",range.field("count").getOrThrow())])
                return Result.Ok(ToolPreparationReadNext.Read(read(request(window,facts),false)))}
            match(ready(context,facts)){case Result.Err(error)=>Result.Err(error);case Result.Ok(value)=>Result.Ok(ToolPreparationReadNext.Ready(value))}
        }finally{lock.unlock()}
    }
}

public func hostCreateWindowDocumentRead(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    configuration:HostPluginDocumentConfiguration,namespace:String,tool:String,generation:UInt64,implementation:String,schemaDigest:String,
    context:ToolInvocationContext,call:ToolCall,binding:AgentValue,response:HostJavaScriptPluginInvocationResult):Result<?ToolPreparationRead>{
    let _=operations;let _=implementation;let _=schemaDigest
    if(response.isError || !httpIntentExactFields(response.value,["document_read"])){
        return hostPluginResourceError("plugin.document_window_read_request","window provider must return one explicit manifest selector")}
    let request=response.value.field("document_read").getOrThrow()
    if(!httpIntentExactFields(request,["key","window"]) || !httpIntentExactFields(request.field("window")??nullValue(),["kind"]) ||
        httpIntentText(request.field("window").getOrThrow(),"kind")!="manifest" ||
        !configuration.payloadReferences(tool) || !configuration.readWindows(tool) || !configuration.permits(tool,httpIntentText(request,"key"),false)){
        return hostPluginResourceError("plugin.document_window_read_request","window provider cannot select tables, ranges or an implicit profile")}
    match(hostDocumentPreparationCurrent(host,configuration,generation,context,binding)){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let owner=HostDocumentWindowSequence(host,configuration,generation,httpIntentText(request,"key"),binding,context,call)
    Result.Ok(Some(owner.begin()))
}
