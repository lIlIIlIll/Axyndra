package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import std.convert.*
import yjson.*
import yjson_support.*

// Created only by the actual ContextRead executor below. A reference to this
// object is a restriction on reading one same-root member, never a start lease.
public class HostPluginPeerReadCustody111 {
    private let host: HostJavaScriptPluginHost
    private let operations: OperationRuntimePort
    private let context: ToolInvocationContext
    private let prepared: PreparedToolInvocation
    private let configuration: HostPrimitiveConfiguration111
    private let generation: UInt64
    private let localTool: String
    init(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,context:ToolInvocationContext,
        prepared:PreparedToolInvocation,configuration:HostPrimitiveConfiguration111,generation:UInt64,localTool:String) {
        this.host=host;this.operations=operations;this.context=context;this.prepared=prepared
        this.configuration=configuration;this.generation=generation;this.localTool=localTool
    }
    public func check():Result<Unit> {
        let args=prepared.operationPlan.canonicalArguments
        if (!isContextReadPlan(prepared.operationPlan) || !pluginPeerReadAuthority111(prepared.operationPlan) ||
            prepared.source.contextReadPreparation.isNone()) {
            return hostPluginResourceError("peer.read_source_invalid","member read lost its canonical preparation") }
        let source=match(prepared.source.operationRoot) {
            case Some(OperationRootSource.Direct(value))=>value
            case _=>return hostPluginResourceError("peer.read_source_invalid","member read requires its actual ContextRead Source") }
        let origin=match(source.origin) {
            case DirectCallOrigin.ContextRead(value)=>value
            case _=>return hostPluginResourceError("peer.read_source_invalid","a normal Direct call cannot become a member read") }
        let read=prepared.source.contextReadPreparation.getOrThrow()
        if (source.runId.value!=context.runId.value || source.threadId.value!=context.sessionId.value ||
            source.epoch!=context.epoch || source.operationId.value!=prepared.operationId.value ||
            origin.parentCallItemId=="" || origin.parentOperationId=="" ||
            origin.ownerNamespace!=configuration.namespace || origin.packageDigest!=configuration.packageDigest ||
            origin.configurationDigest!=configuration.digest || read.ownerNamespace!=origin.ownerNamespace ||
            read.packageDigest!=origin.packageDigest || read.configurationDigest!=origin.configurationDigest) {
            return hostPluginResourceError("peer.read_scope_invalid","member observation has another original parent") }
        match(read.validateBoundary(context,args)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(hostChildPreparationCurrent111(host,configuration,generation,localTool,context,
            args.field("binding").getOrThrow(),service:"peer.send")) {
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
        if (httpIntentText(args,"invocation_capability")!=configuration.invocationName(localTool,service:"peer.send")) {
            return hostPluginResourceError("peer.read_profile_changed","member read cannot choose another invocation capability") }
        operations.verifyContextReadExecuting(source,prepared.operationPlan)
    }
    public func retainObservation(bytes:Int64,nodes:Int64,build:()->AgentValue):AgentValue {
        configuration.retainObservation(bytes,nodes,build)
    }
}

func hostPeerReadConfiguration111(host:HostJavaScriptPluginHost,context:ToolInvocationContext,args:AgentValue)
    :Result<(HostPrimitiveConfiguration111,UInt64,String)> {
    if (!pluginPeerReadRequestValid111(args) ||
        httpIntentText(args,"projection_digest")!=contextReadProjectionDigest(context.contextProjection)) {
        return hostPluginResourceError("peer.read_request_invalid","member read requires this Run's exact projection") }
    let binding=args.field("binding").getOrThrow()
    let namespace=httpIntentText(binding,"namespace");let prefix="plugin."+namespace+"."
    let contribution=httpIntentText(binding,"contribution")
    if (!contribution.startsWith(prefix)) {return hostPluginResourceError("peer.read_contribution_invalid","member read changed contribution")}
    let local=contribution[prefix.size..]
    let generation=try {UInt64.parse(httpIntentText(binding,"generation"))}
        catch(_:Exception){return hostPluginResourceError("peer.read_generation_invalid","invalid member read generation")}
    let configuration=match(host.primitiveConfiguration111(namespace,local,generation)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(Some(value))=>value
        case Result.Ok(None)=>return hostPluginResourceError("peer.read_profile_missing","no exact operator-selected peer contribution") }
    if (!configuration.permitsService(local,"peer.send") ||
        httpIntentText(args,"invocation_capability")!=configuration.invocationName(local,service:"peer.send")) {
        return hostPluginResourceError("peer.read_profile_changed","member read has no original peer-send selection") }
    match(hostChildPreparationCurrent111(host,configuration,generation,local,context,binding,service:"peer.send")) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>() }
    Result.Ok((configuration,generation,local))
}

func hostPreparePeerRead111(host:HostJavaScriptPluginHost,context:ToolInvocationContext,args:AgentValue):Result<AgentValue> {
    let (configuration,_,_)=match(hostPeerReadConfiguration111(host,context,args)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    Result.Ok(configuration.copyPreparedPlan(args))
}

func hostExecutePeerRead111(host:HostJavaScriptPluginHost,operations:OperationRuntimePort,
    context:ToolInvocationContext,prepared:PreparedToolInvocation):Result<ToolResult> {
    let args=prepared.operationPlan.canonicalArguments
    let (configuration,generation,local)=match(hostPeerReadConfiguration111(host,context,args)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    // Charge this retained callback frame in the original installed bank
    // before constructing it. Returning the raw fact is not a consumer ACK.
    let _=configuration.retainObservation(4096,64,{=>nullValue()})
    let read=HostPluginPeerReadCustody111(host,operations,context,prepared,configuration,generation,local)
    match(read.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    let output=match(host.readPeerMember111(context,args,read)) {
        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value }
    if (!pluginPeerReadResultValid111(output,args)) {
        return hostPluginResourceError("peer.read_result_invalid","member read returned a different frozen observation") }
    match(read.check()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
    Result.Ok(ToolResult(prepared.call.callId,output))
}
