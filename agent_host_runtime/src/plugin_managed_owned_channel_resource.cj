package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.sync.*
import yjson.*
import yjson_support.*

// Configured Native endpoint lifetime, plus a pointer to the actual adapter
// in the ORIGINAL lifecycle inventory. Configuration is a ceiling only.
// No startup approval authorizes any later owned adapter/auxiliary effect.
class HostManagedOwnedChannelResource <: HostManagedServiceResource {
    let grant:HostPluginLifecycleLaunchGrant
    private let owner:HostPluginLifecycleOwner
    private let lock=Mutex()
    private let cancellationSource:CancellationSource
    private let metadata:LogicalJsonOwnerReservation
    private var configuration:?AgentValue
    private var lease:?HostPluginLifecycleLease=None<HostPluginLifecycleLease>
    private var closing=false
    private var metadataReleased=false
    private var configuredCeilings:?Array<HostPluginLifecycleLaunchGrant>=None<Array<HostPluginLifecycleLaunchGrant>>
    init(owner:HostPluginLifecycleOwner,grant:HostPluginLifecycleLaunchGrant,configuration:AgentValue){
        let paid=reserveNativeDocumentPayload(1)
        var fixed:?Array<HostPluginLifecycleLaunchGrant>=None<Array<HostPluginLifecycleLaunchGrant>>
        try{let measure=HostManagedGrantRetainedMeasure();measure.add(configuration);measure.add(grant.launchPlan)
            // Original operator file/normalized service ceilings remain fixed.
            paid.ensureRetainedPeak(measure.peak()+HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES*16+1048576)
            match(hostManagedConfiguredProcessIds(configuration)){case None=>();case Some(ids)=>
                // Full selected plan/DOM/encoded/environment coexistence is
                // charged before the original bindService constructs them.
                paid.ensureRetainedPeak(measure.peak()+HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES*16+
                    grant.managedConfiguredPreparationPeak(ids)+1048576)
                let actual=ArrayList<HostPluginLifecycleLaunchGrant>()
                for(id in ids){
                    let ceiling=match(grant.managedConfiguredCeiling(id)){case Result.Err(error)=>throw IllegalStateException(error.describe());case Result.Ok(value)=>value}
                    actual.add(ceiling)}
                fixed=Some(actual.toArray())}}
        catch(error:Exception){paid.close();throw error}
        this.owner=owner;this.grant=grant;this.configuration=Some(configuration);metadata=paid
        configuredCeilings=fixed
        cancellationSource=CancellationSource(deadlineMillis:agentUtcMillis()+hostLifecycleInt(grant.launchPlan,"lifetime_ms",3600000))
    }
    func callTimeoutMillis():Int64{serviceProtocolLimits(grant.launchPlan).value().getOrThrow().callTimeoutMillis}
    func configurationValue():Result<AgentValue>{
        lock.lock();try{
            if(closing || metadataReleased || configuration.isNone()){
                return managedChannelDriverError("managed_channel.configuration_closed")}
            Result.Ok(configuration.getOrThrow())
        }finally{lock.unlock()}
    }
    func businessConfiguration(context:ToolInvocationContext):Result<AgentValue>{
        let configured=match(configurationValue()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let plan=grant.launchPlan
        let fields=ArrayList<ValueField>()
        // Generic finite process metadata, not Host DAP action or protocol logic.
        let reserved=ArrayList<String>(["executable","args","environment","workspace_mode","network","workspace_root","context_cwd"])
        if(configuredCeilings.isSome()){reserved.add("configured_processes")}
        for(field in configured.fields where !reserved.contains(field.name)){fields.add(field)}
        fields.add(ValueField("executable",plan.field("executable").getOrThrow()))
        fields.add(ValueField("args",plan.field("arguments").getOrThrow()))
        fields.add(ValueField("environment",plan.field("environment").getOrThrow()))
        fields.add(ValueField("workspace_mode",plan.field("workspace_mode").getOrThrow()))
        fields.add(ValueField("network",plan.field("network").getOrThrow()))
        fields.add(ValueField("workspace_root",textValue(context.workspaceRoot)))
        fields.add(ValueField("context_cwd",textValue(context.cwd)))
        match(configuredCeilings){case None=>();case Some(ceilings)=>
            let choices=ArrayList<AgentValue>()
            for(ceiling in ceilings){let actual=ceiling.launchPlan
                choices.add(objectValue([ValueField("service_id",actual.field("service_id").getOrThrow()),
                    ValueField("executable",actual.field("executable").getOrThrow()),ValueField("args",actual.field("arguments").getOrThrow()),
                    ValueField("environment",actual.field("environment").getOrThrow()),
                    ValueField("compatible_scope",boolValue(hostManagedConfiguredScopeEqual(grant,ceiling)))]))}
            // Never forward a caller-authored table over these actual frozen
            // operator objects. The Native choice remains descriptive data.
            fields.add(ValueField("configured_processes",listValue(choices.toArray())))}
        let result=objectValue(fields.toArray())
        let measure=HostManagedGrantRetainedMeasure();measure.add(result);measure.add(configured);measure.add(plan)
        metadata.ensureRetainedPeak(measure.peak()+HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES*16+1048576)
        Result.Ok(result)
    }
    func runLane(context:ToolInvocationContext):Result<String>{owner.managedChannelRunLane(context)}
    func retainDirectoryMetadata(value:AgentValue):Result<Unit>{
        try{let measure=HostManagedGrantRetainedMeasure();measure.add(value);measure.add(grant.launchPlan)
            match(configuration){case Some(actual)=>measure.add(actual);case None=>()}
            // The pure directory, canonical Strings, published schemas and
            // exact descriptor clones stay paid by this configured resource.
            metadata.ensureRetainedPeak(measure.peak()+measure.encodedUpperBound()*8+
                HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES*16+1048576);Result.Ok(())}
        catch(_:Exception){managedChannelDriverError("managed_channel.directory_capacity")}
    }
    public func endpointGrant():HostNativeServiceEndpointGrant{grant}
    public func launchKey():String{hostManagedServiceLaunchKey(grant)}
    public func resourceIdentity():String{"owned-channel-"+grant.digest}
    public func requiredCapabilities():Array<Capability>{
        let values=ArrayList<Capability>([Capability(CapabilityKind.ProcessSpawn)])
        values.add(all:hostLifecycleControlCapabilities(grant.launchPlan));values.toArray()
    }
    public func networkPolicy():Result<NetworkPolicy>{parseNetworkPolicy(grant.launchPlan.field("network").getOrThrow())}
    public func bindingMetadata(endpoint:HostPinnedNativeServiceEndpoint):Result<AgentValue>{
        if(!isActive()){return managedChannelDriverError("managed_channel.configured_resource_closed")}
        let plan=grant.launchPlan
        let fields=ArrayList<ValueField>([
            ValueField("plugin",plan.field("namespace").getOrThrow()),ValueField("package_digest",plan.field("package_digest").getOrThrow()),
            ValueField("configuration_digest",plan.field("configuration_digest").getOrThrow()),
            ValueField("instance_identity",textValue(grant.instanceIdentity)),ValueField("endpoint_identity",textValue(endpoint.endpointIdentity)),
            ValueField("launch_digest",textValue(grant.digest)),ValueField("target_thread_id",textValue(grant.targetThread.value)),
            ValueField("permission_domain",plan.field("permission_domain").getOrThrow()),ValueField("workspace_root",plan.field("workspace_root").getOrThrow()),
            ValueField("workspace_mode",plan.field("workspace_mode").getOrThrow()),ValueField("network",plan.field("network").getOrThrow())])
        lock.lock();try{
            let active=lease.isSome() && !lease.getOrThrow().resourcesReleased()
            fields.add(ValueField("resource_state",textValue(if(active){"active"}else{"planned"})))
            if(active){fields.add(ValueField("lease_id",textValue(lease.getOrThrow().leaseId)))
                fields.add(ValueField("startup_operation_id",textValue(lease.getOrThrow().operationId.value)))}
        }finally{lock.unlock()}
        Result.Ok(objectValue(fields.toArray()))
    }
    public func isActive():Bool{
        lock.lock();try{!closing && !metadataReleased && !cancellationSource.token.isCancelled()}finally{lock.unlock()}
    }
    public func validateActive(context:ToolInvocationContext):Result<Unit>{
        if(!isActive() || context.cancellation.isCancelled() || context.sessionId.value!=grant.targetThread.value ||
            context.workspaceRoot!=httpIntentText(grant.launchPlan,"workspace_root") ||
            hostPluginInvocationAuthorityScope(context)!=httpIntentText(grant.launchPlan,"permission_domain")){
            return managedChannelDriverError("managed_channel.configured_resource_changed")}
        grant.stillCurrent()
    }
    public func validateInvocation(context:ToolInvocationContext,parent:PreparedToolInvocation,binding:AgentValue):Result<Unit>{
        if(parent.source.kind==PreparedInvocationSourceKind.Derived || parent.source.operationRoot.isNone() ||
            parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value ||
            parent.source.epoch!=context.epoch || !isManagedChannelOwnedParentPlan(parent.operationPlan) ||
            validateManagedChannelRuntimeBinding(binding).isError()){
            return managedChannelDriverError("managed_channel.actual_parent_required")}
        validateActive(context)
    }
    public func observeRevocation(callback:()->Unit):CancellationRegistration{cancellationSource.token.onCancel({_=>callback()})}
    public func cancellation():CancellationToken{cancellationSource.token}
    func adapterLease():Result<HostPluginLifecycleLease>{
        lock.lock();try{
            if(closing || lease.isNone() || !lease.getOrThrow().isActive()){
                return managedChannelDriverError("managed_channel.actual_adapter_missing")}
            Result.Ok(lease.getOrThrow())
        }finally{lock.unlock()}
    }
    private func configuredProcess(operation:AgentValue,adapter:?HostPluginLifecycleLease):Result<?HostPluginLifecycleLaunchGrant>{
        let selected=operation.field("configured_process")
        if(httpIntentText(operation,"role")=="auxiliary"){
            if(selected.isSome() || adapter.isNone()){return managedChannelDriverError("managed_channel.auxiliary_actual_resource_required")}
            return adapter.getOrThrow().managedConfiguredProcessCeiling()
        }
        if(selected.isNone()){return Result.Ok(None<HostPluginLifecycleLaunchGrant>)}
        if(configuredCeilings.isNone()){return managedChannelDriverError("managed_channel.configured_process_unavailable")}
        for(actual in configuredCeilings.getOrThrow() where hostLifecycleText(actual.launchPlan,"service_id")==selected.getOrThrow().text){
            if(!hostManagedConfiguredScopeEqual(grant,actual)){return managedChannelDriverError("managed_channel.configured_process_scope_changed")}
            match(actual.stillCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            return Result.Ok(Some(actual))}
        managedChannelDriverError("managed_channel.configured_process_unavailable")
    }
    func execute(context:ToolInvocationContext,parent:PreparedToolInvocation,childContext:ToolInvocationContext,
        child:PreparedToolInvocation,binding:AgentValue,port:OperationRuntimePort):Result<AgentValue>{
        match(validateInvocation(context,parent,parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow())){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let operation=child.operationPlan.canonicalArguments.field("operation").getOrThrow()
        let kind=httpIntentText(operation,"kind")
        if(kind=="spawn"){
            let auxiliary=httpIntentText(operation,"role")=="auxiliary"
            let selectedAdapter:?HostPluginLifecycleLease=if(auxiliary){
                match(adapterLease()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>Some(value)}
            }else{None<HostPluginLifecycleLease>}
            lock.lock();try{
                if(closing || (!auxiliary && lease.isSome() && !lease.getOrThrow().resourcesReleased())){
                    return managedChannelDriverError("managed_channel.actual_adapter_busy")}
            }finally{lock.unlock()}
            let selectedCeiling=match(configuredProcess(operation,selectedAdapter)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let actual=match(owner.startManaged(context,parent,childContext,child,grant,port,{=>
                // This callback outlives the original Run, so it checks only
                // this real installation/configuration/endpoint resource.
                if(!isActive()){return managedChannelDriverError("managed_channel.configured_resource_closed")}
                grant.stillCurrent()},adapter:selectedAdapter,ceiling:selectedCeiling)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            lock.lock();let stopped=try{if(!auxiliary){lease=Some(actual)};closing}finally{lock.unlock()}
            if(stopped){let _=owner.revoke(actual);return managedChannelDriverError("managed_channel.actual_spawn_revoked")}
            let process=match(actual.managedObservedProcessId()){
                case Result.Err(error)=>let _=owner.revoke(actual);return Result.Err(error);case Result.Ok(value)=>value}
            let fields=ArrayList<ValueField>()
            for(field in binding.fields where !["resource_state","lease_id","startup_operation_id"].contains(field.name)){fields.add(field)}
            fields.add(ValueField("resource_state",textValue("active")));fields.add(ValueField("lease_id",textValue(actual.leaseId)))
            fields.add(ValueField("startup_operation_id",textValue(child.operationId.value)))
            let active=objectValue(fields.toArray())
            match(validateManagedChannelRuntimeBinding(active)){case Result.Err(error)=>let _=owner.revoke(actual);return Result.Err(error);case Result.Ok(_)=>()}
            return Result.Ok(objectValue([ValueField("schema",textValue("axyndra.managed-channel-spawn-result/v1")),
                ValueField("lease_id",textValue(actual.leaseId)),ValueField("launch_digest",textValue(actual.launchDigest)),
                ValueField("resource_binding",active),ValueField("process_id",integerValue(process))]))
        }
        let actual=match(adapterLease()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(kind=="write"){
            match(actual.managedWrite(context,parent,childContext,child,binding,port)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            return Result.Ok(objectValue([ValueField("schema",textValue("axyndra.managed-channel-write-result/v1")),
                ValueField("lease_id",textValue(actual.leaseId)),ValueField("intent_id",operation.field("id").getOrThrow()),
                ValueField("written_bytes",integerValue(httpIntentText(operation,"bytes_hex").size/2))]))
        }
        if(kind!="close"){return managedChannelDriverError("managed_channel.actual_effect_invalid")}
        // The exact ordinary admitted Derived close must be executing before
        // releasing any real dependent auxiliary resource. Their original
        // leases retain every process/pump/I/O scope until individual ACK.
        match(hostManagedChannelVerifyExecuting(port,context,parent,childContext,child,{=>validateActive(context)})){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(actual.verifyManagedResource(context,parent,binding,port)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(owner.revokeManagedAuxiliaries(actual)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        match(actual.managedClose(context,parent,childContext,child,binding,port)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        if(!actual.resourcesReleased()){return managedChannelDriverError("managed_channel.actual_close_pending")}
        Result.Ok(objectValue([ValueField("schema",textValue("axyndra.managed-channel-close-result/v1")),
            ValueField("lease_id",textValue(actual.leaseId)),ValueField("resources_released",boolValue(true))]))
    }
    func activateSpawn(context:ToolInvocationContext,parent:PreparedToolInvocation,child:PreparedToolInvocation,
        result:ToolResult,port:OperationRuntimePort):Result<Unit>{
        let operation=child.operationPlan.canonicalArguments.field("operation").getOrThrow()
        let auxiliary=httpIntentText(operation,"role")=="auxiliary"
        let actual:?HostPluginLifecycleLease=if(auxiliary){
            let adapter=match(adapterLease()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(owner.managedAuxiliaryLease(adapter,child)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>Some(value)}
        }else{lock.lock();try{lease}finally{lock.unlock()}}
        if(actual.isNone() || actual.getOrThrow().operationId.value!=child.operationId.value ||
            httpIntentText(result.output,"lease_id")!=actual.getOrThrow().leaseId){
            return managedChannelDriverError("managed_channel.actual_spawn_changed")}
        actual.getOrThrow().activateManaged(context,parent,result.output.field("resource_binding").getOrThrow(),port)
    }
    public func revoke():Result<Unit>{
        let _=cancellationSource.cancel()
        lock.lock();let selected=try{closing=true;lease}finally{lock.unlock()}
        match(selected){case Some(value)=>
            let auxiliary=owner.revokeManagedAuxiliaries(value)
            let adapter=owner.revoke(value)
            match(auxiliary){case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>adapter}
            case None=>Result.Ok(())}
    }
    public func resourcesReleased():Bool{
        lock.lock();try{closing && (lease.isNone() ||
            (lease.getOrThrow().resourcesReleased() && owner.managedAuxiliariesReleased(lease.getOrThrow())))}finally{lock.unlock()}
    }
    public func retainsStartup():Bool{owner.retainsLaunch(grant.digest)}
    // This method is called only after actual endpoint+invocation+adapter ACK
    // in the existing manager cleanup path. No Source/current gate is used.
    func acknowledgeMetadataAfterPhysicalCleanup():Result<Unit>{
        lock.lock();try{
            if(!closing || (lease.isSome() && (!lease.getOrThrow().resourcesReleased() ||
                !owner.managedAuxiliariesReleased(lease.getOrThrow())))){
                return managedChannelDriverError("managed_channel.resource_cleanup_pending")}
            configuration=None<AgentValue>;lease=None<HostPluginLifecycleLease>
            configuredCeilings=None<Array<HostPluginLifecycleLaunchGrant>>
            // Original public service handles retain an immutable configured
            // grant after physical cleanup. Keep its SAME metadata payment;
            // do not claim alias retirement or mint capacity via early refund.
            if(!metadataReleased){metadataReleased=true;cancellationSource.close()}
            Result.Ok(())
        }finally{lock.unlock()}
    }
    public func maintenancePlan(_:ToolInvocationContext,_:PreparedToolInvocation,_:HostServiceAction):Result<AgentValue>{
        managedChannelDriverError("managed_channel.maintenance_owned_entry_required")}
    public func refreshPlan(_:HostPinnedNativeServiceEndpoint,_:Int64,_:String):Result<AgentValue>{
        managedChannelDriverError("managed_channel.refresh_not_selected")}
    public func validateRefresh(_:AgentValue,_:HostPinnedNativeServiceEndpoint,_:Int64,_:String):Result<Unit>{
        managedChannelDriverError("managed_channel.refresh_not_selected")}
    public func refreshResult(_:AgentValue,_:AgentValue):Result<AgentValue>{
        managedChannelDriverError("managed_channel.refresh_not_selected")}
    public func commitRefresh(_:ToolInvocationContext,_:PreparedToolInvocation,_:AgentValue,_:AgentValue):Result<AgentValue>{
        managedChannelDriverError("managed_channel.refresh_not_selected")}
}

// Private raw observation only; it never supplies Source or execution rights.
interface HostManagedChannelPhysicalProcessObservation {
    func observedManagedProcessId():Result<Int64>
}
