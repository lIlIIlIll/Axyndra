package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.convert.*
import std.sync.*
import yjson.*
import yjson_support.*

// v2 execution only consumes Host-frozen intents and complete result bytes.
// No pure worker cache or business algorithm is consulted after approval.
public func hostExecuteFrozenDocument(host:HostJavaScriptPluginHost,namespace:String,tool:String,generation:UInt64,
    context:ToolInvocationContext,prepared:PreparedToolInvocation,observer:HostJavaScriptPluginInvocationObserver):Result<ToolResult>{
    let plan=prepared.operationPlan;let parent=plan.canonicalArguments
    let frozen=parent.field("host_plan").getOrThrow()
    if(!isFrozenPluginDocumentParentPlan(plan) || !pluginDocumentFrozenResultValid(frozen)){
        return hostPluginResourceError("plugin.document_result_missing","public reference execution requires its complete frozen result")}
    let binding=frozen.field("binding").getOrThrow()
    let configuration=match(host.documentConfiguration(namespace,httpIntentText(binding,"package_digest"))){
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let provider=match(configuration.preparationProvider(tool)){case Some(value)=>value
        case None=>return hostPluginResourceError("plugin.document_preparation_provider_missing","frozen result lost its exact pure preparation Provider")}
    if(!configuration.payloadReferences(tool)){return hostPluginResourceError("plugin.document_payload_profile_changed","public payload representation changed after approval")}
    if(httpIntentText(frozen,"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA && !configuration.readWindows(tool)){
        return hostPluginResourceError("plugin.document_window_profile_changed","window result lost its explicitly selected operator profile")}
    let reference=parsePluginDocumentPayloadReference(frozen.field("result_payload").getOrThrow()).value().getOrThrow()
    let session=match(host.documentDataSession()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
    let revoked=AtomicBool(false)
    let registration=match(host.observeServiceRevocation(namespace,generation,{=>revoked.store(true)})){
        case Result.Err(error)=>let _=session.close();return Result.Err(error);case Result.Ok(value)=>value}
    // This guard runs under existing Host/artifact/Store gates and never
    // reacquires Host or Runtime locks. It validates the same complete config.
    let guard={=>
        if(revoked.load() || context.cancellation.isCancelled() ||
            !context.capabilities.allows(CapabilityKind.ExtensionInvoke,resource:namespace)){
            return hostPluginResourceError<Unit>("plugin.document_result_revoked","frozen result source was cancelled or revoked")}
        if(httpIntentText(frozen,"version")==PLUGIN_DOCUMENT_ROW_JOURNAL_PARENT_SCHEMA){
            match(pluginDocumentRowJournalFrozenResultCurrent(frozen,agentUtcMillis())){
                case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}}
        match(pluginDocumentFrozenResultCurrent(frozen,agentUtcMillis())){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        configuration.validateTransferWitness()}
    let full: () -> Result<Unit> ={=>
        match(guard()){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        match(hostDocumentPreparationCurrent(host,configuration,generation,context,binding)){
            case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(_)=>()}
        let actual=match(host.policyProviderBinding(namespace,provider)){case Result.Err(error)=>return Result<Unit>.Err(error);case Result.Ok(value)=>value}
        if(actual.generation!=generation || actual.namespace!=namespace || actual.contribution!=provider || actual.digest!=configuration.packageDigest){
            return hostPluginResourceError<Unit>("plugin.document_preparation_provider_changed","frozen result package changed before consumption")}
        guard()}
    var transferred=false
    try{
        let outcome=session.run({owner=>
            match(full()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            // Validate full raw/hash/schema/canonical and durable codec before
            // any actual CAS. Its transient DOM is discarded before the child
            // current/next-payload proofs need their own shared-pool leases.
            match(owner.readFrozenResult(reference,{=>host.commitDocumentEffect(namespace,generation,configuration.packageDigest,
                {=>owner.verifyFrozenResult(context,prepared,guard)})},guard)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            for(intent in frozen.field("intents").getOrThrow().items){
                match(full()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
                let id=httpIntentText(intent,"id")
                match(observer.onServiceRequest("frozen-document-result",id,"document.store",
                    stringifyUnifiedJson(objectValue([ValueField("intent_id",textValue(id))])))){
                    case JavaScriptHostResult.Err(error)=>return Result<AgentValue>.Err(hostJavascriptPluginAgentError(error));case JavaScriptHostResult.Ok(_)=>()}}
            match(observer.finishDocument()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            match(full()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            // The same actual frozen ref is reverified after every actual
            // Completed child Receipt/plan/handoff, then decoded, never rebuilt.
            let value=match(owner.readFrozenResult(reference,{=>host.commitDocumentEffect(namespace,generation,configuration.packageDigest,
                {=>owner.verifyFrozenResult(context,prepared,guard,completedChildren:true)})},guard,retain:true)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(full()){case Result.Err(error)=>return Result<AgentValue>.Err(error);case Result.Ok(_)=>()}
            Result.Ok(value)})
        let value=match(outcome){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let isError=frozen.field("is_error").getOrThrow().asBool()
        match(context.outputSink.emit(ToolOutputChunk(prepared.call.callId,
            if(isError){ToolOutputChannel.Stderr}else{ToolOutputChannel.Stdout},stringifyUnifiedJson(value)))){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let result=ToolResult(prepared.call.callId,value,isError:isError,
            payloadLease:Some(ToolResultPayloadLease({=>session.acknowledgeOutput()})))
        transferred=true;Result.Ok(result)
    }finally{
        registration.dispose()
        if(!transferred){session.acknowledgeOutput();let _=session.close()}
    }
}
