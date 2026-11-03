package agent_store

import agent_domain.*
import std.convert.*
import yjson.*
import yjson_support.*

// Historical fact loading grants no new consumption. Revalidate every actual
// parentless read's admission against the same live Run before exposing bytes
// to either a prefix worker or the final ContextProvider.
func requireDocumentContextWindowInput(tx:SqliteTransaction,links:Array<ContextReadFactLink>,
    binding:AgentValue,dataList:AgentValue,complete:Bool):OpaqueRowJournalWindowObservation{
    if(!pluginDocumentContextBindingValid(binding) || links.isEmpty() || links.size>8){
        throw IllegalStateException("context window input requires its exact nine-field provider binding")}
    let thread=ThreadId(httpIntentText(binding,"thread_id"))
    let epoch=Int64.parse(binding.field("epoch").getOrThrow().asNumberText())
    for(link in links){
        let fact=requireContextReadFact(tx,link.operationId,link.runId)
        if(canonicalAgentValue(fact.reference())!=canonicalAgentValue(link.toValue())){
            throw IllegalStateException("context window descriptor differs from its complete actual fact")}
        let read=journalWindowFactPlan(tx,link)
        let origin=fact.origin
        if(link.runId.value!=httpIntentText(binding,"run_id") || !isContextReadPlan(read) ||
            !pluginDocumentContextWindowReadAuthority(read) ||
            !pluginDocumentContextWindowReadResultValid(fact.output(),read.canonicalArguments) ||
            canonicalAgentValue(read.canonicalArguments.field("binding").getOrThrow())!=canonicalAgentValue(binding) ||
            origin.ownerNamespace!=httpIntentText(binding,"namespace") ||
            origin.packageDigest!=httpIntentText(binding,"package_digest") ||
            origin.configurationDigest!=httpIntentText(binding,"configuration_digest") ||
            origin.projectionDigest!=httpIntentText(read.canonicalArguments,"projection_digest") ||
            origin.parentCallItemId!="" || origin.parentKind!="" || origin.parentOperationId!="" ||
            origin.parentDecisionId!="" || origin.parentScopedCallId!=""){
            throw IllegalStateException("context window input is not its original parentless provider read")}
        requireContextReadOriginBinding(tx,link.operationId,link.runId,fact.sourceItemId,false)
        if(requirePluginDocumentLane(tx,thread,link.runId,epoch).value!=httpIntentText(binding,"lane_id")){
            throw IllegalStateException("context window input lost its actual current lane")}
    }
    // The shared predicate proves every complete normalized plan, original
    // ordered prefix, unique actual observation, exact immutable payload,
    // continuous row interval and full current SQL state/revision fence.
    requirePluginDocumentWindowFacts(tx,links,binding,dataList,complete)
}

public func verifyObservedPluginDocumentContextWindowPrefix(tx:SqliteTransaction,
    links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue):Result<Unit>{
    try{let observed=requireDocumentContextWindowInput(tx,links,binding,dataList,false);observed.close();Result.Ok(())}
    catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
    catch(_:Exception){documentPayloadError("plugin.document_context_window_prefix_stale")}
}

public func verifyPreparedPluginDocumentContextWindowInput(tx:SqliteTransaction,
    links:Array<ContextReadFactLink>,binding:AgentValue,dataList:AgentValue):Result<Unit>{
    try{let observed=requireDocumentContextWindowInput(tx,links,binding,dataList,true);observed.close();Result.Ok(())}
    catch(error:PluginDocumentGuardFailure){Result.Err(error.failure)}
    catch(_:Exception){documentPayloadError("plugin.document_context_window_input_stale")}
}
