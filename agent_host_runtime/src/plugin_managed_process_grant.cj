package agent_host_runtime

import agent_domain.*
import agent_plugin_registry.*
import agent_extension_runtime.*
import agent_runtime.*
import agent_ports.*
import tool_runtime.*
import sandbox4cj.*
import process4cj as process
import std.time.*
import std.collection.*
import std.fs.*
import std.sync.*
import yjson.*
import yjson_support.*

// The actual caller holds Prepared values. This comparison cannot manufacture
// their roots from operation IDs, a lease ID, or a plugin-provided binding.
func hostManagedChannelSameRoot(parent:PreparedToolInvocation,child:PreparedToolInvocation):Bool{
    if(parent.source.operationRoot.isNone() || child.source.operationRoot.isNone()){return false}
    match((parent.source.operationRoot.getOrThrow(),child.source.operationRoot.getOrThrow())){
        case(OperationRootSource.Direct(left),OperationRootSource.Direct(right))=>refEq(left,right)
        case(OperationRootSource.Committed(left),OperationRootSource.Committed(right))=>refEq(left,right)
        case _=>false}
}

func hostManagedChannelContext(context:ToolInvocationContext,parent:PreparedToolInvocation,
    childContext:ToolInvocationContext,child:PreparedToolInvocation):Result<Unit>{
    if(context.trustedControl || childContext.trustedControl ||
        !isManagedChannelOwnedParentPlan(parent.operationPlan) ||
        !managedChannelOwnedChildAllowed(parent.operationPlan,child.operationPlan) ||
        child.source.kind!=PreparedInvocationSourceKind.Derived ||
        child.authorization==PreparedAuthorization.ApprovalRequired || child.authorization==PreparedAuthorization.ParentIntent ||
        child.source.parentOperationId.isNone() || child.source.parentOperationId.getOrThrow().value!=parent.operationId.value ||
        child.source.parentCallId!=parent.call.callId || !hostManagedChannelSameRoot(parent,child) ||
        child.source.requestKey!=managedChannelOwnedRequestKey(parent.call.callId,child.operationPlan) ||
        parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value ||
        parent.source.epoch!=context.epoch || child.source.runId.value!=context.runId.value ||
        child.source.sessionId.value!=context.sessionId.value || child.source.epoch!=context.epoch ||
        childContext.runId.value!=context.runId.value || childContext.sessionId.value!=context.sessionId.value ||
        childContext.epoch!=context.epoch || !refEq(childContext.budget,context.budget) ||
        !refEq(childContext.cancellation,context.cancellation) || childContext.workspaceRoot!=context.workspaceRoot ||
        childContext.cwd!=context.cwd){return hostLifecycleLeaseError("managed_channel.actual_child_required")}
    let left=context.environment.entries();let right=childContext.environment.entries()
    if(left.size!=right.size){return hostLifecycleLeaseError("managed_channel.environment_changed")}
    for(index in 0..left.size){if(left[index].name!=right[index].name || left[index].value!=right[index].value){
        return hostLifecycleLeaseError("managed_channel.environment_changed")}}
    for(capability in childContext.capabilities.values){
        if(!context.capabilities.allows(capability.kind,resource:capability.resource)){
            return hostLifecycleLeaseError("managed_channel.capability_widened")}}
    for(capability in child.operationPlan.requiredCapabilities){
        if(!childContext.capabilities.allows(capability.kind,resource:capability.resource)){
            return hostLifecycleLeaseError("managed_channel.capability_denied")}}
    if(context.cancellation.isCancelled() || (context.budget.deadlineMillis>0 && agentUtcMillis()>=context.budget.deadlineMillis)){
        return hostLifecycleIoCancelled()}
    Result.Ok(())
}

func hostManagedChannelVerifyExecuting(port:OperationRuntimePort,context:ToolInvocationContext,
    parent:PreparedToolInvocation,childContext:ToolInvocationContext,child:PreparedToolInvocation,
    current:()->Result<Unit>):Result<Unit>{
    match(hostManagedChannelContext(context,parent,childContext,child)){case Result.Err(error)=>return Result.Err(error);case _=>()}
    match(current()){case Result.Err(error)=>return Result.Err(error);case _=>()}
    port.verifyManagedChannelOwnedEffectExecuting(parent.source.operationRoot.getOrThrow(),parent.operationId,
        child.operationId,context.runId,ThreadId(context.sessionId.value),context.epoch,parent.operationPlan,
        child.operationPlan,child.source.requestKey,child.call.callId,child.approval,{=>
            match(hostManagedChannelContext(context,parent,childContext,child)){case Result.Err(error)=>return Result.Err(error);case _=>()}
            current()})
}

// Structural retained-memory measurement, without constructing a canonical
// string. Original StoredValue's depth 64 and million-node bound remain the
// limits; this owner is not a new JSON wire, Source, or capability restriction.
class HostManagedGrantRetainedMeasure{
    private var nodes:Int64=0
    private var bytes:Int64=0
    func add(value:AgentValue,depth!:Int64=0):Unit{
        nodes+=1
        if(depth>64 || nodes>1000000){throw LogicalJsonPayloadError("managed retained value exceeds original StoredValue shape")}
        bytes+=64
        match(value.unifiedKind){
            case ValueKind.Text=>bytes+=value.text.size
            case ValueKind.Number=>bytes+=value.asNumberText().size
            case ValueKind.Object=>for(field in value.fields){nodes+=1;bytes+=field.name.size+64;add(field.value,depth:depth+1)}
            case ValueKind.List=>for(item in value.items){add(item,depth:depth+1)}
            case ValueKind.Boolean | ValueKind.Null=>()
            case _=>throw LogicalJsonPayloadError("managed retained value has unsupported kind")}
        if(bytes>1073741824){throw LogicalJsonPayloadError("managed retained value overflows aggregate accounting")}
    }
    func text(value:String):Unit{
        nodes+=1;bytes+=64+value.size
        if(bytes>1073741824 || nodes>1000000){throw LogicalJsonPayloadError("managed retained text overflows aggregate accounting")}
    }
    func peak():Int64{bytes*4+nodes*512+1048576}
    func encodedUpperBound():Int64{bytes*6}
    func retainedCounts159():(Int64,Int64){(bytes,nodes)}
    func applyRetainedCounts159(actualBytes:Int64,actualNodes:Int64):Unit{
        if(actualBytes<bytes || actualNodes<nodes || actualBytes>1073741824 || actualNodes>1000000){
            throw LogicalJsonPayloadError("managed retained text overflows aggregate accounting")}
        bytes=actualBytes;nodes=actualNodes
    }
}

// No public constructor. Only the Host's actual Derived executor creates this
// after the complete executing/handoff/ordinary-policy proof above. The old
// configured grant supplies operator ceilings; it never authorizes this child.
class HostManagedProcessGrant <: HostLifecycleProcessLaunchGrant{
    private var retainedBase:?HostPluginLifecycleLaunchGrant
    prop base:HostPluginLifecycleLaunchGrant{get(){retainedBase.getOrThrow()}}
    private var retainedParent:?PreparedToolInvocation
    private var retainedChild:?PreparedToolInvocation
    private var retainedContext:?ToolInvocationContext
    private var retainedChildContext:?ToolInvocationContext
    prop parent:PreparedToolInvocation{get(){retainedParent.getOrThrow()}}
    prop child:PreparedToolInvocation{get(){retainedChild.getOrThrow()}}
    prop context:ToolInvocationContext{get(){retainedContext.getOrThrow()}}
    prop childContext:ToolInvocationContext{get(){retainedChildContext.getOrThrow()}}
    let port:OperationRuntimePort
    private var currentCallback:?()->Result<Unit>
    let role:String
    private var held:?LogicalJsonOwnerReservation
    private var operation:?AgentValue
    private var retainedExecutable:?HostPluginLifecycleExecutable
    private var retainedCwd:?String
    private var retainedConfiguredRequest:?ProcessRequest
    private prop executable:HostPluginLifecycleExecutable{get(){retainedExecutable.getOrThrow()}}
    private prop cwd:String{get(){retainedCwd.getOrThrow()}}
    private prop configuredRequest:ProcessRequest{get(){retainedConfiguredRequest.getOrThrow()}}
    private let ownership=Mutex()
    private var active:Int64=0
    private var released=false
    private var actualAdapter:?HostPluginLifecycleLease=None<HostPluginLifecycleLease>
    private var retainedCeiling:?HostPluginLifecycleLaunchGrant=None<HostPluginLifecycleLaunchGrant>
    private prop processCeiling:HostPluginLifecycleLaunchGrant{get(){match(retainedCeiling){case Some(value)=>value;case None=>base}}}
    private var namespaces:?process.ProcessSandboxNamespaces=None<process.ProcessSandboxNamespaces>
    private let namespaceLock=Mutex()

    private init(base:HostPluginLifecycleLaunchGrant,context:ToolInvocationContext,parent:PreparedToolInvocation,
        childContext:ToolInvocationContext,child:PreparedToolInvocation,port:OperationRuntimePort,current:()->Result<Unit>,
        operation:AgentValue,executable:HostPluginLifecycleExecutable,cwd:String,request:ProcessRequest,
        owner:LogicalJsonOwnerReservation,adapter:?HostPluginLifecycleLease,ceiling:?HostPluginLifecycleLaunchGrant){
        this.retainedBase=Some(base);this.retainedContext=Some(context);this.retainedParent=Some(parent)
        this.retainedChildContext=Some(childContext);this.retainedChild=Some(child)
        this.port=port;this.currentCallback=Some(current);this.role=hostLifecycleText(operation,"role")
        this.operation=Some(operation);this.retainedExecutable=Some(executable);this.retainedCwd=Some(cwd);this.retainedConfiguredRequest=Some(request);this.held=Some(owner)
        actualAdapter=adapter;retainedCeiling=ceiling
    }
    static func prepare(base:HostPluginLifecycleLaunchGrant,context:ToolInvocationContext,parent:PreparedToolInvocation,
        childContext:ToolInvocationContext,child:PreparedToolInvocation,port:OperationRuntimePort,
        current:()->Result<Unit>,adapter!:?HostPluginLifecycleLease=None<HostPluginLifecycleLease>,
        ceiling!:?HostPluginLifecycleLaunchGrant=None<HostPluginLifecycleLaunchGrant>):Result<HostManagedProcessGrant>{
        match(hostManagedChannelVerifyExecuting(port,context,parent,childContext,child,current)){
            case Result.Err(error)=>return Result.Err(error);case _=>()}
        let owner=try{reserveNativeDocumentPayload(1)}catch(_:Exception){return hostLifecycleLeaseError("managed_channel.grant_capacity")}
        var adopted=false
        try{
            let binding=child.operationPlan.canonicalArguments.field("binding").getOrThrow()
            let operation=child.operationPlan.canonicalArguments.field("operation").getOrThrow()
            let auxiliary=hostLifecycleText(operation,"role")=="auxiliary"
            if(auxiliary!=(adapter.isSome()) || (auxiliary && hostLifecycleText(binding,"resource_state")!="active")){
                return hostLifecycleLeaseError("managed_channel.auxiliary_actual_resource_required")}
            if(hostLifecycleText(operation,"kind")!="spawn"){return hostLifecycleLeaseError("managed_channel.spawn_required")}
            let measure=HostManagedGrantRetainedMeasure()
            measure.add(parent.operationPlan.canonicalArguments);measure.add(child.operationPlan.canonicalArguments)
            measure.add(parent.call.arguments);measure.add(child.call.arguments)
            match(parent.source.operationRoot.getOrThrow()){
                case OperationRootSource.Direct(root)=>measure.add(root.call.arguments)
                case OperationRootSource.Committed(root)=>measure.add(root.block.arguments)}
            // The independent escaping grant pays the coexistence of every
            // retained actual plan/call plus its resolved process metadata.
            measure.text(context.workspaceRoot);measure.text(context.cwd)
            for(field in context.environment.entries()){measure.text(field.name);measure.text(field.value)}
            for(field in childContext.environment.entries()){measure.text(field.name);measure.text(field.value)}
            owner.ensureRetainedPeak(measure.peak()+base.managedRuntimePlanRetainedPeak()+hostManagedChannelTerminalReferencePeak(context,parent)+hostManagedChannelTerminalReferencePeak(childContext,parent))
            let plan=base.launchPlan
            let configured=match(ceiling){case Some(value)=>value;case None=>base}
            match(ceiling){case None=>();case Some(selected)=>
                // A Native string is insufficient: this is an actual ceiling
                // lent by the SAME configured resource, with complete Source
                // still verified independently before the physical effect.
                owner.ensureRetainedPeak(measure.peak()+base.managedRuntimePlanRetainedPeak()+
                    selected.managedRuntimePlanRetainedPeak()*3+HOST_PLUGIN_LIFECYCLE_CONFIGURATION_BYTES*16+
                    hostManagedChannelTerminalReferencePeak(context,parent)+hostManagedChannelTerminalReferencePeak(childContext,parent))
                if(!hostManagedConfiguredScopeEqual(base,selected)){
                    return hostLifecycleLeaseError("managed_channel.configured_process_scope_changed")}
                if(!auxiliary && (operation.field("configured_process").isNone() ||
                    hostLifecycleText(operation,"configured_process")!=hostLifecycleText(selected.launchPlan,"service_id"))){
                    return hostLifecycleLeaseError("managed_channel.configured_process_changed")}
                match(selected.stillCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
            if(ceiling.isNone() && operation.field("configured_process").isSome()){
                return hostLifecycleLeaseError("managed_channel.configured_process_unavailable")}
            if(validateManagedChannelRuntimeBinding(binding).isError() || base.targetThread.value!=context.sessionId.value ||
                base.instanceIdentity!=hostLifecycleText(binding,"instance_identity") || base.digest!=hostLifecycleText(binding,"launch_digest") ||
                hostLifecycleText(plan,"namespace")!=hostLifecycleText(binding,"plugin") ||
                hostPluginInvocationAuthorityScope(context)!=hostLifecycleText(binding,"permission_domain") ||
                context.workspaceRoot!=hostLifecycleText(binding,"workspace_root")){
                return hostLifecycleLeaseError("managed_channel.configured_binding_changed")}
            for(key in ["package_digest","configuration_digest","workspace_root","workspace_mode"]){
                if(hostLifecycleText(plan,key)!=hostLifecycleText(binding,key)){
                    return hostLifecycleLeaseError("managed_channel.configured_binding_changed")}}
            if(canonicalAgentValue(plan.field("network").getOrThrow())!=canonicalAgentValue(binding.field("network").getOrThrow()) ||
                canonicalAgentValue(plan.field("lifecycle_policy").getOrThrow())!=canonicalAgentValue(binding.field("lifecycle_policy").getOrThrow()) ||
                canonicalAgentValue(operation.field("network").getOrThrow())!=canonicalAgentValue(binding.field("network").getOrThrow()) ||
                hostLifecycleText(operation,"workspace_mode")!=hostLifecycleText(binding,"workspace_mode")){
                return hostLifecycleLeaseError("managed_channel.process_scope_changed")}
            let request=match(configured.processRequest(child.operationId)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let authoredCwd=hostLifecycleText(operation,"cwd")
            let cwd=hostLifecycleDirectory(if(auxiliary){hostLifecycleRelativePath(context.cwd,authoredCwd)}else{authoredCwd})
            let executable=if(auxiliary){hostLifecycleServiceExecutable(hostLifecycleText(operation,"executable"),cwd)}
                else{hostLifecycleExecutable(hostLifecycleText(operation,"executable"))}
            if((!auxiliary && (cwd!=authoredCwd || executable.resolved!=hostLifecycleText(operation,"executable"))) ||
                !hostManagedChannelPathVisible(request,hostLifecycleText(plan,"workspace_root"),cwd,true) || !hostManagedChannelPathVisible(request,hostLifecycleText(plan,"workspace_root"),executable.resolved,false)){
                return hostLifecycleLeaseError("managed_channel.resolved_path_changed")}
            let resources=request.processLimits;let budgetCeiling=context.budget.processLimits
            if(!hostLifecycleResourceFits(resources.maxOutputBytes,budgetCeiling.maxOutputBytes) ||
                !hostLifecycleResourceFits(resources.addressSpaceBytes,budgetCeiling.addressSpaceBytes) ||
                !hostLifecycleResourceFits(resources.fileSizeBytes,budgetCeiling.fileSizeBytes) ||
                !hostLifecycleResourceFits(resources.openFiles,budgetCeiling.openFiles) ||
                !hostLifecycleResourceFits(resources.processes,budgetCeiling.processes) ||
                !hostLifecycleResourceFits(resources.cpuSeconds,budgetCeiling.cpuSeconds)){
                return hostLifecycleLeaseError("managed_channel.process_ceiling")}
            if(hostLifecycleText(operation,"role")=="adapter"){
                if(executable.resolved!=request.executable ||
                    operation.field("args").getOrThrow().items.size!=request.arguments.size ||
                    canonicalAgentValue(operation.field("environment").getOrThrow())!=canonicalAgentValue(configured.launchPlan.field("environment").getOrThrow())){
                    return hostLifecycleLeaseError("managed_channel.adapter_selection_changed")}
                for(index in 0..request.arguments.size){if(operation.field("args").getOrThrow().items[index].text!=request.arguments[index]){
                    return hostLifecycleLeaseError("managed_channel.adapter_selection_changed")}}
            }else{
                for(field in operation.field("environment").getOrThrow().fields){
                    if(!hostManagedChannelLiteralEnvironmentName(field.name) || hostProcessEnvironmentSecretName(field.name) ||
                        field.value.unifiedKind!=ValueKind.Text || field.value.text.contains("\u{0}")){
                        return hostLifecycleLeaseError("managed_channel.auxiliary_environment_invalid")}}
            }
            match(hostManagedChannelVerifyExecuting(port,context,parent,childContext,child,current)){
                case Result.Err(error)=>return Result.Err(error);case _=>()}
            if(auxiliary){match(adapter.getOrThrow().verifyManagedResource(context,parent,binding,port)){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
            let grant=HostManagedProcessGrant(base,context,parent,childContext,child,port,current,operation,executable,cwd,request,owner,adapter,ceiling)
            adopted=true;Result.Ok(grant)
        }catch(_:Exception){hostLifecycleLeaseError("managed_channel.grant_invalid")}
        finally{if(!adopted){owner.close()}}
    }
    func enterRegistryEffect():Result<PluginRegistryExecutionFence>{
        if(!beginBorrow()){return hostLifecycleLeaseError("managed_channel.grant_released")}
        try{
            match(verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(stillCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let fence=match(base.enterRegistryEffect()){
                case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            match(verifyExecuting()){case Result.Err(error)=>fence.close();return Result.Err(error);case Result.Ok(_)=>()}
            match(stillCurrent()){case Result.Err(error)=>fence.close();return Result.Err(error);case Result.Ok(_)=>()}
            Result.Ok(fence)
        }finally{endBorrow()}
    }
    func verifyExecuting():Result<Unit>{
        if(!beginBorrow()){return hostLifecycleLeaseError("managed_channel.grant_released")}
        try{hostManagedChannelVerifyExecuting(port,context,parent,childContext,child,currentCallback.getOrThrow())}
        finally{endBorrow()}
    }
    func stillCurrent():Result<Unit>{
        if(!beginBorrow()){return hostLifecycleLeaseError("managed_channel.grant_released")}
        try{
        match(immutableShutdownIdentityCurrent()){case Result.Err(error)=>return Result.Err(error);case _=>()}
        match(currentCallback.getOrThrow()()){case Result.Err(error)=>return Result.Err(error);case _=>()}
        try{
            match(actualAdapter){case Some(adapter)=>if(!adapter.isActive()){
                return hostLifecycleLeaseError("managed_channel.actual_adapter_changed")};case None=>()}
            match(namespaces){case Some(value)=>if(!value.current()){
                return hostLifecycleLeaseError("managed_channel.actual_namespace_changed")};case None=>()}
            Result.Ok(())
        }catch(_:Exception){hostLifecycleLeaseError("managed_channel.executable_changed")}
        }finally{endBorrow()}
    }
    // Only cleanup custody survives caller-resource revocation. This does not
    // admit an effect: original operator/configuration/executable identities
    // remain exact, while ordinary stillCurrent still checks caller authority.
    func stillCurrentForCleanup():Result<Unit>{
        if(!beginBorrow()){return hostLifecycleLeaseError("managed_channel.grant_released")}
        try{immutableShutdownIdentityCurrent()}finally{endBorrow()}
    }
    private func immutableShutdownIdentityCurrent():Result<Unit>{
        match(base.stillCurrent()){case Result.Err(error)=>return Result.Err(error);case _=>()}
        match(retainedCeiling){case Some(value)=>match(value.stillCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()};case None=>()}
        try{
            let operationValue=operation.getOrThrow()
            let observed=if(role=="auxiliary"){
                hostLifecycleServiceExecutable(hostLifecycleText(operationValue,"executable"),cwd)
            }else{hostLifecycleExecutable(executable.authored)}
            let observedCwd=if(role=="auxiliary"){
                hostLifecycleDirectory(hostLifecycleRelativePath(context.cwd,hostLifecycleText(operationValue,"cwd")))
            }else{hostLifecycleDirectory(cwd)}
            if(observed.resolved!=executable.resolved || observed.digest!=executable.digest || observed.size!=executable.size ||
                observedCwd!=cwd){return hostLifecycleLeaseError("managed_channel.executable_changed")}
            Result.Ok(())
        }catch(_:Exception){hostLifecycleLeaseError("managed_channel.executable_changed")}
    }
    public func processRequest(operationId:OperationId):Result<ProcessRequest>{
        if(!beginBorrow()){return hostLifecycleLeaseError("managed_channel.grant_released")}
        try{
        if(operationId.value!=child.operationId.value){return hostLifecycleLeaseError("managed_channel.launch_operation_changed")}
        match(verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case _=>()}
        match(stillCurrent()){case Result.Err(error)=>return Result.Err(error);case _=>()}
        let value=operation.getOrThrow()
        Result.Ok(ProcessRequest(executable.resolved,operationId:operationId,
            arguments:value.field("args").getOrThrow().items.toArray().map{item=>item.text},workingDirectory:cwd,
            timeoutMillis:if(retainedCeiling.isSome()){min(configuredRequest.timeoutMillis,hostLifecycleInt(base.launchPlan,"lifetime_ms",3600000))}
                else{configuredRequest.timeoutMillis},sandboxMode:configuredRequest.sandboxMode,
            filesystemRoot:configuredRequest.filesystemRoot,readOnlyMounts:configuredRequest.readOnlyMounts.clone(),
            networkPolicy:configuredRequest.networkPolicy,processLimits:configuredRequest.processLimits))
        }finally{endBorrow()}
    }
    func resolveProcessEnvironment():Result<HostResolvedProcessEnvironment>{
        if(!beginBorrow()){return hostLifecycleLeaseError("managed_channel.grant_released")}
        try{
        match(verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case _=>()}
        match(stillCurrent()){case Result.Err(error)=>return Result.Err(error);case _=>()}
        if(role=="adapter"){return processCeiling.resolveProcessEnvironment()}
        let entries=ArrayList<SandboxEnvironmentEntry>()
        for(field in operation.getOrThrow().field("environment").getOrThrow().fields){entries.add(SandboxEnvironmentEntry(field.name,field.value.text))}
        Result.Ok(HostResolvedProcessEnvironment(entries.toArray(),[],[]))
        }finally{endBorrow()}
    }
    func belongsToAdapter(adapter:HostPluginLifecycleLease):Bool{
        ownership.lock();try{!released && role=="auxiliary" && actualAdapter.isSome() && refEq(actualAdapter.getOrThrow(),adapter)}
        finally{ownership.unlock()}
    }
    func ownsActualPrepared(actual:PreparedToolInvocation):Bool{
        ownership.lock();try{!released && retainedChild.isSome() && refEq(retainedChild.getOrThrow(),actual)}finally{ownership.unlock()}
    }
    // Descriptor acquisition occurs only AFTER the original owner inventory
    // has adopted this paid actual grant. Even a failed post-capture proof
    // retains the exact descriptors for that lease's physical cleanup retry.
    func withBorrowedNamespaces<T>(body:(process.ProcessSandboxNamespaces)->Result<T>):Result<T>{
        if(!beginBorrow()){return hostLifecycleLeaseError("managed_channel.grant_released")}
        namespaceLock.lock();try{
            if(role!="auxiliary" || actualAdapter.isNone()){
                return hostLifecycleLeaseError("managed_channel.actual_namespace_required")}
            match(verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(namespaces.isNone()){
                match(actualAdapter.getOrThrow().captureManagedNamespaces(context,parent,
                    child.operationPlan.canonicalArguments.field("binding").getOrThrow(),port,
                    {value=>namespaces=Some(value)})){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}}
            match(verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(stillCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            body(namespaces.getOrThrow())
        }finally{namespaceLock.unlock();endBorrow()}
    }
    func observeAuxiliaryPayload(channel:ProcessChannel):Result<Int64>{
        let actual=match(channel as HostManagedChannelNamespaceObservation){
            case Some(value)=>value;case None=>return hostLifecycleLeaseError("managed_channel.actual_payload_observation_unavailable")}
        withBorrowedNamespaces<Int64>({owned=>
            let until=MonoTime.now()+Duration.millisecond*min(2000,configuredRequest.timeoutMillis)
            while(MonoTime.now()<until){
                match(verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(actual.observedManagedPayload(owned,executable.resolved)){
                    case Result.Ok(value)=>
                        match(verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        match(stillCurrent()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                        if(value.namespacePid<1){return hostLifecycleLeaseError<Int64>("managed_channel.actual_payload_unavailable")}
                        return Result.Ok(value.namespacePid)
                    case Result.Err(_)=>()}
                sleep(Duration.millisecond*5)
            }
            hostLifecycleLeaseError<Int64>("managed_channel.actual_payload_unavailable")})
    }
    func hasConfiguredProcessCeiling():Bool{retainedCeiling.isSome()}
    func configuredProcessCeiling():?HostPluginLifecycleLaunchGrant{retainedCeiling}
    func managedLeasePlan():AgentValue{
        if(retainedCeiling.isNone()){return base.launchPlan}
        hostManagedConfiguredLeasePlan(base,processCeiling)
    }
    func maximumInputBytes():Int64{hostLifecycleInt(managedLeasePlan(),"max_input_bytes",HOST_PLUGIN_LIFECYCLE_IO_BYTES)}
    func actualProcessResources():ExecutionResourceLimits{configuredRequest.processLimits}
    func initialOutputWindowBytes():Int64{
        hostLifecycleInt(managedLeasePlan().field("startup").getOrThrow(),"max_output_bytes",HOST_PLUGIN_LIFECYCLE_IO_BYTES)
    }
    // Called only by the original lifecycle lease AFTER native owner, pumps,
    // and outstanding I/O scopes all acknowledge physical cleanup.
    func releaseAfterPhysicalCleanup():Bool{releaseAfterPhysicalCleanup({=>()})}
    func releaseAfterPhysicalCleanup(clearRetained:()->Unit):Bool{
        ownership.lock();try{
            if(released){return true};if(active!=0){return false}
            // Raw namespace Unit close is not a cleanup acknowledgement.
            // Keep the same grant, adapter reference and payment on failure;
            // retry does not require a live adapter, current Source or Run.
            match(namespaces){case Some(value)=>if(!value.acknowledgeClose()){return false}
                namespaces=None<process.ProcessSandboxNamespaces>;case None=>()}
            clearRetained()
            released=true;operation=None;retainedParent=None;retainedChild=None
            retainedContext=None;retainedChildContext=None;currentCallback=None
            retainedExecutable=None;retainedCwd=None;retainedConfiguredRequest=None;retainedBase=None;actualAdapter=None<HostPluginLifecycleLease>
            retainedCeiling=None<HostPluginLifecycleLaunchGrant>
            match(held){case Some(owner)=>held=None;owner.close();case None=>()};true
        }finally{ownership.unlock()}
    }
    func cleanupBorrowState():(Int64,Bool,Bool,Bool){
        ownership.lock();try{(active,held.isSome(),released,namespaces.isSome())}finally{ownership.unlock()}
    }
    func observeCleanupBorrow(observer:HostManagedChannelCleanupObserver,lease:HostPluginLifecycleLease):Unit{
        // The grant's already paid full retained SUM includes its fixed
        // metadata/callback cells. No allocation pool or second owner exists.
        observer.observe(HostManagedChannelCleanupBorrow(this,lease))
    }
    // The actual grants remain borrowed across all proof reads. Neither
    // caller fields nor operation IDs can manufacture these private inputs.
    func compareExecutingScope(other:HostManagedProcessGrant,
        attempt:(()->Result<HostManagedProcessGrant>,HostManagedProcessGrant)->Result<Unit>):Result<HostManagedChannelExecutingScopeState>{
        if(refEq(this,other) || !beginBorrow()){return hostLifecycleLeaseError("managed_channel.distinct_actual_scope_required")}
        try{
            if(!other.beginBorrow()){return hostLifecycleLeaseError("managed_channel.peer_grant_released")}
            try{
                match(verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                match(other.verifyExecuting()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                let sameRoot=hostManagedChannelSameRoot(parent,other.child)
                if(sameRoot){return hostLifecycleLeaseError("managed_channel.foreign_actual_root_required")}
                let sameRun=context.runId.value==other.childContext.runId.value
                let sameThread=context.sessionId.value==other.childContext.sessionId.value
                let sameEpoch=context.epoch==other.childContext.epoch
                let samePermission=hostPluginInvocationAuthorityScope(context)==hostPluginInvocationAuthorityScope(other.childContext)
                // This is the same real production admission path used by
                // openManaged. It must reject the original foreign Derived
                // child BEFORE its reserve1 or any native effect. The caller
                // receives no grant, parent, child, Source or dispatch right.
                match(attempt({=>HostManagedProcessGrant.prepare(base,context,parent,
                    other.childContext,other.child,port,currentCallback.getOrThrow(),
                    adapter:actualAdapter,ceiling:retainedCeiling)},other)){
                    case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                Result.Ok(HostManagedChannelExecutingScopeState(sameRoot,sameRun,sameThread,sameEpoch,samePermission))
            }finally{other.endBorrow()}
        }finally{endBorrow()}
    }
    func retainUnpublishedScopePeerPayment():Bool{beginBorrow()}
    func acknowledgeUnpublishedScopePeerPayment():Unit{endBorrow()}
    func withRetainedRuntime(body:()->Result<Unit>):Result<Unit>{
        if(!beginBorrow()){return hostLifecycleLeaseError("managed_channel.grant_released")}
        try{body()}finally{endBorrow()}
    }
    private func beginBorrow():Bool{ownership.lock();try{if(released){false}else{active+=1;true}}finally{ownership.unlock()}}
    private func endBorrow():Unit{ownership.lock();try{active-=1}finally{ownership.unlock()}}
}

func hostManagedChannelPathVisible(request:ProcessRequest,workspaceRoot:String,path:String,directory:Bool):Bool{
    let root=if(request.filesystemRoot!=""){request.filesystemRoot}else{workspaceRoot}
    if(hostLifecycleWithin(root,path)){return true}
    for(mount in request.readOnlyMounts){
        if(hostLifecycleWithin(mount,path) && (!directory || FileInfo(mount).isDirectory())){return true}}
    if(!directory){for(system in ["/usr","/bin","/lib","/lib64","/sbin"]){if(hostLifecycleWithin(system,path)){return true}}}
    false
}
func hostManagedChannelLiteralEnvironmentName(value:String):Bool{
    if(value==""){return false}
    let bytes=value.toArray()
    for(index in 0..bytes.size){let byte=bytes[index]
        if(!((byte>=b'A' && byte<=b'Z') || (byte>=b'a' && byte<=b'z') || byte==b'_' ||
            (index>0 && byte>=b'0' && byte<=b'9'))){return false}}
    true
}

// Used only after the writer prepays its complete actual encoded/raw coexistence.
func hostManagedChannelUnhex(encoded:String,maximum:Int64):Array<Byte>{
    if(encoded.size%2!=0 || encoded.size/2>maximum){throw IllegalArgumentException("managed bytes exceed original channel limit")}
    let source=encoded.toArray();let bytes=Array<Byte>(source.size/2,repeat:0)
    for(index in 0..bytes.size){
        let left=hostOutputHex(source[index*2]);let right=hostOutputHex(source[index*2+1])
        if(left<0 || right<0){throw IllegalArgumentException("managed write contains invalid hexadecimal")}
        bytes[index]=UInt8(left*16+right)
    }
    bytes
}
