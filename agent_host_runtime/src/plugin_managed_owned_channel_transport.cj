package agent_host_runtime

import agent_domain.*
import agent_runtime.*
import tool_runtime.*
import yjson.*
import yjson_support.*
import std.collection.*

class HostManagedOwnedChannelTransport <: HostManagedServiceTransport {
    let resource:HostManagedOwnedChannelResource
    let port:OperationRuntimePort
    init(resource:HostManagedOwnedChannelResource,port:OperationRuntimePort){this.resource=resource;this.port=port}
    public func requestedCapability():String{"process.channel"}
    public func preparationArguments(_:HostManagedServicePhase,_:String,_:AgentValue):AgentValue{
        throw IllegalStateException("owned channel preparation requires the actual invocation context")
    }
    func preparationArgumentsFor(context:ToolInvocationContext,localName:String,input:AgentValue):Result<AgentValue>{
        let configuration=match(resource.businessConfiguration(context)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        Result.Ok(objectValue([ValueField("action",textValue("channel_prepare")),ValueField("tool",textValue(localName)),
            ValueField("input",input),ValueField("configuration",configuration)]))
    }
    public func freezeIntents(context:ToolInvocationContext,_:ToolCall,input:AgentValue,
        pure:AgentValue,binding:AgentValue):Result<AgentValue>{
        if(!httpIntentExactFields(pure,["intents"]) || pure.field("intents").getOrThrow().unifiedKind!=ValueKind.List ||
            !pure.field("intents").getOrThrow().items.isEmpty() || validateManagedChannelRuntimeBinding(binding).isError()){
            return managedChannelDriverError("managed_channel.pure_preparation_changed")}
        let configuration=match(resource.businessConfiguration(context)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        Result.Ok(objectValue([ValueField("input",input),ValueField("configuration",configuration),
            ValueField("host_plan",objectValue([ValueField("version",textValue(HOST_MANAGED_CHANNEL_OWNED_VERSION)),
                ValueField("binding",binding)]))]))
    }
    public func validateParent(context:ToolInvocationContext,parent:PreparedToolInvocation,binding:AgentValue):Result<Unit>{
        if(!isManagedChannelOwnedParentPlan(parent.operationPlan)){
            return managedChannelDriverError("managed_channel.actual_parent_required")}
        resource.validateInvocation(context,parent,binding)
    }
    public func beginInvocation(_:HostPluginManagedService,_:HostPinnedNativeServiceEndpoint,
        _:ToolInvocationContext,_:PreparedToolInvocation,_:AgentValue):Result<HostManagedServiceInvocation>{
        managedChannelDriverError("managed_channel.owned_entry_required")}
    public func beginMaintenance(_:HostPluginManagedService,_:HostPinnedNativeServiceEndpoint,
        _:ToolInvocationContext,_:PreparedToolInvocation,_:HostServiceAction):Result<HostManagedServiceInvocation>{
        managedChannelDriverError("managed_channel.maintenance_owned_entry_required")}
}

// Catalog contains this exact class through the original service publication.
// Waiting retains the same service.invocation object, never an endpoint lookup
// that recreates a Session or Root from serialized IDs.
class HostManagedChannelActualOwnedEndpoint <: HostManagedChannelOwnedEndpoint {
    private let service:HostPluginManagedService
    private let revision:Int64
    init(service:HostPluginManagedService,revision:Int64){this.service=service;this.revision=revision}
    public func begin(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<HostManagedChannelOwnedSession>{
        service.beginOwnedChannelInvocation(context,parent,revision)
    }
    public func acquireHandoffLease(context:ToolInvocationContext,parent:PreparedToolInvocation):Result<ToolExecutionHandoffLease>{
        match(service.validateOwnedChannelParent(context,parent,revision)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        service.acquireRegistryHandoff(revision:Some(revision))
    }
    public func cancel(_:RunId):Result<Unit>{service.revoke()}
}
