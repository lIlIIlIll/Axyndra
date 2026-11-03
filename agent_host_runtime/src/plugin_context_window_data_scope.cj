package agent_host_runtime

import agent_plugin_registry.*
import agent_ports.*

import agent_domain.*
import agent_extension_runtime.*
import tool_runtime.*
import std.time.*
import yjson.*
import yjson_support.*

// One logical query borrows one actual typed ContextProvider connection. The
// caller supplies its original monotonic deadline and source-current checks;
// this class creates no Run, Operation, source authority or second timeout.
public class HostContextWindowDataScope {
    private let host:HostJavaScriptPluginHost
    private let configuration:HostPluginDocumentContextWindowConfiguration
    private let provider:String
    private let generation:UInt64
    private let thread:ThreadId
    private let cancellation:CancellationToken
    private let limits:ExecutionResourceLimits
    private let callId:String
    private let deadline:MonoTime
    private let localCurrent:()->Result<Unit>
    private let completeCurrent:()->Result<Unit>
    private var worker:?HostDocumentDataWorker=None
    private var session:?HostDocumentDataSession=None
    private var entered=false
    private var released=false
    private var exchanges:Int64=0
    public init(host:HostJavaScriptPluginHost,configuration:HostPluginDocumentContextWindowConfiguration,provider:String,generation:UInt64,
        thread:ThreadId,cancellation:CancellationToken,limits:ExecutionResourceLimits,callId:String,deadline:MonoTime,
        localCurrent:()->Result<Unit>,completeCurrent:()->Result<Unit>){
        this.host=host;this.configuration=configuration;this.provider=provider;this.generation=generation
        this.thread=thread;this.cancellation=cancellation;this.limits=limits;this.callId=callId;this.deadline=deadline
        this.localCurrent=localCurrent;this.completeCurrent=completeCurrent
    }
    // Safe inside the already-held Host generation/artifact/Store gates.
    public func local():Result<Unit>{
        if(MonoTime.now()>=deadline || cancellation.isCancelled()){
            return hostPluginResourceError("plugin.document_query_timeout","the original pure data query expired or was cancelled")}
        match(localCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        configuration.validateCurrent()
    }
    public func current():Result<Unit>{
        match(local()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let actual=match(host.servicePackageData81(configuration.namespace,generation)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(actual.contentDigest!=configuration.packageDigest){
            return hostPluginResourceError("plugin.document_owner_stale","fixed Provider package generation changed")}
        Result.Ok(())
    }
    public func validate():Result<Unit>{
        match(current()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(configuration.validateCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(completeCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let actual=match(host.contentProviderBinding(configuration.namespace,provider,false)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(actual.namespace!=configuration.namespace || actual.contribution!=provider ||
            actual.digest!=configuration.packageDigest || actual.generation!=generation){
            return hostPluginResourceError("plugin.document_preparation_provider_changed","fixed pure Provider binding changed")}
        current()
    }
    public func run(owner:HostDocumentDataSession,action:(HostContextWindowDataScope)->Result<AgentValue>):Result<AgentValue>{
        if(entered){return hostPluginResourceError("plugin.document_query_reused","fixed Provider data scope is single use")}
        entered=true
        match(validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let selected=match(host.contextDataWorker(configuration.namespace,generation,thread.value,"pure-context-data:"+configuration.digest+":"+provider)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        worker=Some(selected);session=Some(owner)
        try{
            // Adopt before begin can allocate a worker cache. Disposal always
            // addresses the captured process, never a replacement generation.
            match(owner.retainWorkerCleanup({=>selected.abortAndCollect()})){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(validate()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let result=action(this)
            // A cache-release ACK is not physical process collection. Each
            // ordinary-wire logical context query owns this exact process;
            // close/collect it before clearing its retained cleanup callback.
            selected.actual.close()
            if(!selected.actual.cleanupComplete){
                return hostPluginResourceError("context.document_worker_cleanup_pending","actual context data worker remains owned")}
            owner.acknowledgeWorkerRelease()
            result
        }finally{
            // Failure retains the same actual process in the session callback
            // until cleanupComplete acknowledges collection. Never reset a
            // connection's 4096-ID counter while that connection is alive.
            if(!selected.actual.cleanupComplete){let _=selected.abortAndCollect()}
            selected.finishTransfer();worker=None;session=None
        }
    }
    public func exchange(value:AgentValue,checkpoint!:Bool=false):Result<AgentValue>{
        if(!entered || worker.isNone() || released){return hostPluginResourceError("plugin.document_query_closed","fixed Provider data scope is closed")}
        // Preserve the original ordinary native wire's complete per-worker
        // 4096 distinct-ID ceiling. A logical query owns/collects this process;
        // the counter is never reset for chunks or reused generations.
        if(exchanges>=4096){return hostPluginResourceError("context.document_worker_limit","context data query exhausted its original invocation bound")}
        exchanges++
        match(if(checkpoint){validate()}else{current()}){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let remaining=(deadline-MonoTime.now()).toMilliseconds()
        if(remaining<1){return hostPluginResourceError("plugin.document_query_timeout","pure data transport cannot extend its original deadline")}
        let request=value
        let encodedBound=logicalJsonWriteReservationBytes(request,262144)
        // The session's 16 MiB metadata lease covers the bounded request,
        // response clone and 64 KiB raw/128 KiB hex transport representations.
        if(encodedBound>262144){return hostPluginResourceError("plugin.document_query_shape","data phase exceeds its logical transport envelope")}
        let response=match(host.invoke(configuration.namespace,provider,stringifyUnifiedJson(request),
            identity:JavaScriptHostInvocationIdentity(threadId:thread.value,runId:"",epoch:0,operationId:"",callId:callId,kind:"context_provider"),
            cancellation:cancellation,processLimits:limits,timeoutMillis:remaining,expectedInstanceGeneration:generation,
            authorityScope:"pure-context-data:"+configuration.digest+":"+provider,expectedContextDataWorker:Some(worker.getOrThrow().actual))){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
            if(response.isError){
                return hostPluginResourceError("plugin.document_query_rejected","pure Provider data phase was rejected")}
            let result=response.value
            let measure=logicalJsonWriteReservationBytes(result,262144)
            if(measure>262144){return hostPluginResourceError("plugin.document_query_shape","data phase reply exceeds its compact envelope")}
            match(if(checkpoint){validate()}else{current()}){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let frozen=parseUnifiedJson(stringifyUnifiedJson(result),maxBytes:262144,maxDepth:16)
            if(httpIntentText(value,"action")=="release"){
                if(!httpIntentExactFields(frozen,["released"]) || frozen.field("released").getOrThrow().unifiedKind!=ValueKind.Boolean ||
                    !frozen.field("released").getOrThrow().asBool()){
                    return hostPluginResourceError("plugin.document_query_cleanup_pending","pure worker did not acknowledge release")}
                released=true
            }
            Result.Ok(frozen)
        }catch(_:Exception){hostPluginResourceError("plugin.document_query_shape","data phase reply is malformed")}
        finally{response.releasePayload()}
    }
}
