package agent_host_runtime

import agent_domain.*
import agent_extension_runtime.*
import agent_runtime.*
import tool_runtime.*
import process4cj as process
import std.collection.*
import std.convert.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

// Host-installed protocol composition, never decoded from plugin data. Any
// backend discovery I/O belongs in this actual canonical startup window.
public type HostPluginManagedStartup = (HostPinnedNativeServiceEndpoint, HostPluginLifecycleLease,
    ToolInvocationContext, PreparedToolInvocation) -> Result<AgentValue>

type HostHttpManagedTransportFactory = (HostHttpServiceGrant) -> HostManagedServiceTransport
public type HostManagedJobLauncher = (ToolInvocationContext, PreparedToolInvocation, () -> Bool) -> Result<ToolResult>

public class HostPluginManagedStart {
    public let outcome: ToolInvocationResult
    public let service: ?HostPluginManagedService
    init(outcome: ToolInvocationResult, service: ?HostPluginManagedService) {
        this.outcome = outcome; this.service = service
    }
}

// Resource inventory only: canonical facts stay in Store and every directory
// is published through the existing ToolCatalog. Closing handles retain quota.
public class HostPluginLifecycleManager {
    private let catalog: ToolCatalog
    private let host: HostJavaScriptPluginHost
    private let owner: HostPluginLifecycleOwner
    private let control: HostPluginLifecycleControl
    private let refreshControl: HostPluginLifecycleRefreshControl
    private let runtime: HostJavaScriptPluginServiceRuntime
    private let httpControl: ?HostHttpLifecycleControl
    private let httpRefreshControl: ?HostPluginLifecycleRefreshControl
    private let httpTransportFactory: ?HostHttpManagedTransportFactory
    private let managedJobLauncher: ?HostManagedJobLauncher
    private let ownedChannelPort:?OperationRuntimePort
    private let lock = Mutex()
    private let services = ArrayList<HostPluginManagedService>()
    private var closed = false
    init(catalog: ToolCatalog, host: HostJavaScriptPluginHost,
        owner: HostPluginLifecycleOwner, control: HostPluginLifecycleControl,
        runtime: HostJavaScriptPluginServiceRuntime, refreshControl: HostPluginLifecycleRefreshControl,
        httpControl!: ?HostHttpLifecycleControl = None,
        httpRefreshControl!: ?HostPluginLifecycleRefreshControl = None,
        httpTransportFactory!: ?HostHttpManagedTransportFactory = None,
        managedJobLauncher!: ?HostManagedJobLauncher = None,ownedChannelPort!:?OperationRuntimePort=None) {
        this.catalog = catalog; this.host = host; this.owner = owner; this.control = control; this.runtime = runtime
        this.refreshControl = refreshControl
        this.httpControl = httpControl; this.httpRefreshControl = httpRefreshControl; this.httpTransportFactory = httpTransportFactory
        this.managedJobLauncher = managedJobLauncher;this.ownedChannelPort=ownedChannelPort
    }

    // Only the explicitly selected configured transport uses this route.
    // Startup pins a powerless Native endpoint and publishes its pure directory.
    // Every backend process/write/close is a later independently approved child.
    public func startOwnedChannelProtocol(vnext:HostServiceToolControl,targetContext:ToolInvocationContext,maintenanceThread:ThreadId,
        configuration:HostPluginLifecycleConfiguration,serviceId:String,route:String,expectedGeneration:UInt64,
        approval:ApprovalDecision,budget!:ExecutionBudget=ExecutionBudget(maxToolCalls:1,maxConcurrentTools:1)):Result<HostPluginManagedStart>{
        let port=match(ownedChannelPort){case Some(value)=>value
            case None=>return managedChannelDriverError("managed_channel.actual_factory_not_installed")}
        let grant=match(host.bindLifecycleService(configuration,serviceId,ThreadId(targetContext.sessionId.value),
            targetContext.workspaceRoot,budget.processLimits,hostPluginInvocationAuthorityScope(targetContext),expectedGeneration)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(maintenanceThread.value==grant.targetThread.value || targetContext.cancellation.isCancelled()){
            return managedChannelDriverError("managed_channel.maintenance_scope_invalid")}
        let resource:HostManagedOwnedChannelResource
        let managed:HostPluginManagedService
        lock.lock();try{
            if(closed){return managedChannelDriverError("managed_channel.actual_manager_closed")}
            var index:Int64=0
            while(index<services.size){if(services[index].resourcesReleased()){services.remove(at:index)}else{index+=1}}
            if(services.size>=32){return managedChannelDriverError("managed_channel.actual_manager_capacity")}
            var count:Int64=0
            for(item in services where item.namespace==configuration.namespace){count+=1
                if(item.sameLaunch(grant)){return managedChannelDriverError("managed_channel.actual_scope_busy")}}
            if(count>=hostLifecycleInt(grant.launchPlan,"max_instances",32)){
                return managedChannelDriverError("managed_channel.actual_manager_capacity")}
            resource=try{HostManagedOwnedChannelResource(owner,grant,configuration.configuration)}
                catch(_:Exception){return managedChannelDriverError<HostPluginManagedStart>("managed_channel.configuration_capacity")}
            managed=HostPluginManagedService(catalog,host,resource,HostManagedOwnedChannelTransport(resource,port),
                refreshControl,payloadOwner:Some(owner))
            services.add(managed)
        }finally{lock.unlock()}
        // Keep caller cancellation linked through directory I/O and promotion,
        // not merely checked after a blocked canonical startup returns.
        let startupScope=HostLifecycleIoScope(targetContext.cancellation.deadlineMillis,{=>let _=managed.revoke()})
        startupScope.arm(targetContext.cancellation)
        var published=false
        try{
            let started=match(control.launch(vnext,SessionId(maintenanceThread.value),grant,targetContext.capabilities,
                {_,_,_=>managedChannelDriverError<AgentValue>("managed_channel.fixed_startup_forbidden")},
                approvalDecision:Some(approval),budget:budget,callerCancellation:Some(targetContext.cancellation),
                nativeDirectoryStartup:Some({context,prepared=>
                    let endpoint=match(host.pinServiceEndpoint(grant,targetContext,maintenanceThread,route,expectedGeneration,
                        startupContext:Some(context),leaseCancellation:Some(resource.cancellation()))){
                        case HostServiceEndpointSelection.Ready(value)=>managed.captureEndpoint(value);value
                        case HostServiceEndpointSelection.Rejected(error)=>return Result<AgentValue>.Err(error)
                        case HostServiceEndpointSelection.CleanupRequired(value,original,_)=>managed.captureEndpoint(value);return Result<AgentValue>.Err(original)}
                    let response=match(host.prepareService(endpoint,stringifyUnifiedJson(objectValue([ValueField("action",textValue("channel_directory"))])),
                        JavaScriptHostInvocationIdentity(threadId:context.sessionId.value,runId:context.runId.value,
                            epoch:context.epoch,operationId:prepared.operationId.value,callId:prepared.call.callId,kind:"service_prepare"),context)){
                        case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
                    try{if(response.isError){return managedChannelDriverError<AgentValue>("managed_channel.pure_directory_rejected")}
                        managed.freezeDirectory(response.value)}finally{response.releasePayload()}
                }))){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
            let complete=match(started.outcome){case ToolInvocationResult.Completed(value)=>!value.isError;case _=>false}
            if(!complete){return Result.Ok(HostPluginManagedStart(started.outcome,None<HostPluginManagedService>))}
            match(managed.publish()){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            startupScope.checkDeadline()
            if(startupScope.finish() || targetContext.cancellation.isCancelled()){return managedChannelDriverError("managed_channel.startup_cancelled")}
            published=true;Result.Ok(HostPluginManagedStart(started.outcome,Some(managed)))
        }finally{let _=startupScope.finish();managed.finishStartup();if(!published){let _=managed.revoke()}}
    }
    func acquireOwnedChannelEffectHandoff(context:ToolInvocationContext,child:PreparedToolInvocation):Result<ToolExecutionHandoffLease>{
        if(!isManagedChannelOwnedChildPlan(child.operationPlan)){return managedChannelDriverError("managed_channel.actual_child_family_changed")}
        lock.lock();let selected=try{if(closed){return managedChannelDriverError<ToolExecutionHandoffLease>("managed_channel.actual_manager_closed")}
            services.toArray()}finally{lock.unlock()}
        for(service in selected){
            let result=service.acquireOwnedChannelChildHandoff(context,child)
            if(result.isOk()){return result}}
        managedChannelDriverError("managed_channel.actual_installed_child_endpoint_missing")
    }

    public func start(vnext: HostServiceToolControl, targetContext: ToolInvocationContext, maintenanceThread: ThreadId,
        configuration: HostPluginLifecycleConfiguration, serviceId: String, route: String,
        expectedGeneration: UInt64, startup: HostPluginManagedStartup, approvalDecision: ApprovalDecision,
        budget!: ExecutionBudget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
    ): Result<HostPluginManagedStart> {
        let grant = match (host.bindLifecycleService(configuration, serviceId, ThreadId(targetContext.sessionId.value),
            targetContext.workspaceRoot, budget.processLimits, hostPluginInvocationAuthorityScope(targetContext), expectedGeneration)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        if (maintenanceThread.value == grant.targetThread.value || targetContext.cancellation.isCancelled()) {
            return hostLifecycleLeaseError("plugin.lifecycle_manager_scope_invalid")
        }
        let resource = HostManagedChannelResource(owner, grant)
        let managed = HostPluginManagedService(catalog, host, resource,
            HostManagedChannelTransport(resource, runtime, configuration.configuration), refreshControl, payloadOwner: Some(owner), managedJobLauncher: managedJobLauncher)
        lock.lock()
        try {
            if (closed) { return hostLifecycleLeaseError("plugin.lifecycle_manager_closed") }
            var index: Int64 = 0
            while (index < services.size) {
                if (services[index].resourcesReleased()) { services.remove(at: index) } else { index += 1 }
            }
            if (services.size >= 32) { return hostLifecycleLeaseError("plugin.lifecycle_manager_capacity") }
            var matching: Int64 = 0
            for (item in services where item.namespace == configuration.namespace) {
                matching += 1
                if (item.sameLaunch(grant)) { return hostLifecycleLeaseError("plugin.lifecycle_manager_scope_busy") }
            }
            if (matching >= hostLifecycleInt(grant.launchPlan, "max_instances", 32)) {
                return hostLifecycleLeaseError("plugin.lifecycle_manager_capacity")
            }
            services.add(managed)
        } finally { lock.unlock() }
        // This scope ends at publication, not at lease expiry. Its finish()
        // lock linearizes concurrent caller cancellation against promotion.
        let startupScope = HostLifecycleIoScope(targetContext.cancellation.deadlineMillis,
            { => let _ = managed.revoke() })
        startupScope.arm(targetContext.cancellation)
        var published = false
        try {
            let started = match (control.launch(vnext, SessionId(maintenanceThread.value), grant,
                targetContext.capabilities, { lease, context, prepared =>
                    resource.capture(lease)
                    let endpoint = match (host.pinServiceEndpoint(grant, targetContext, maintenanceThread, route, expectedGeneration,
                        startupContext: Some(context), leaseCancellation: Some(lease.cancellationToken()))) {
                        case HostServiceEndpointSelection.Ready(value) => managed.captureEndpoint(value); value
                        case HostServiceEndpointSelection.Rejected(error) => return Result.Err(error)
                        case HostServiceEndpointSelection.CleanupRequired(value, original, _) =>
                            managed.captureEndpoint(value); return Result.Err(original)
                    }
                    match (startup(endpoint, lease, context, prepared)) {
                        case Result.Err(error) => Result.Err(error)
                        case Result.Ok(value) => managed.freezeDirectory(value)
                    }
                }, approvalDecision: Some(approvalDecision), budget: budget,
                    callerCancellation: Some(targetContext.cancellation))) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) => value
            }
            if (started.lease.isNone()) { return Result.Ok(HostPluginManagedStart(started.outcome, Option<HostPluginManagedService>.None)) }
            match (managed.publish()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            startupScope.checkDeadline()
            if (startupScope.finish()) { return hostLifecycleStartupCancelled() }
            published = true
            Result.Ok(HostPluginManagedStart(started.outcome, Some(managed)))
        } catch (_: Exception) {
            hostLifecycleLeaseError("plugin.lifecycle_manager_failed")
        } finally {
            let _ = startupScope.finish()
            managed.finishStartup()
            if (!published) { let _ = managed.revoke() }
        }
    }

    // Native endpoint plus finite HTTP maintenance. This uses the same resource
    // inventory, publication owner, target Thread and cleanup-ACK accounting as
    // channel services; it creates neither a ProcessSpawn lease nor a registry.
    public func startHttpProtocol(vnext: HostServiceToolControl, targetContext: ToolInvocationContext, maintenanceThread: ThreadId,
        configuration: HostPluginHttpConfiguration, serviceId: String, route: String,
        expectedGeneration: UInt64, approval: ApprovalDecision,
        budget!: ExecutionBudget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)): Result<HostPluginManagedStart> {
        if (httpControl.isNone() || httpRefreshControl.isNone() || httpTransportFactory.isNone()) {
            return hostLifecycleLeaseError("plugin.http_service_not_installed")
        }
        let grant = try { HostHttpServiceGrant(host, configuration, targetContext, serviceId, route, expectedGeneration) }
            catch (_: Exception) { return hostLifecycleLeaseError("plugin.http_service_grant_invalid") }
        if (maintenanceThread.value == grant.targetThread.value || targetContext.cancellation.isCancelled()) {
            return hostLifecycleLeaseError("plugin.lifecycle_manager_scope_invalid")
        }
        let control = httpControl.getOrThrow()
        let resource = try { HostManagedHttpResource(grant, control.store) }
            catch (_: Exception) { return hostLifecycleLeaseError("plugin.http_service_resource_unavailable") }
        let transport = try { httpTransportFactory.getOrThrow()(grant) }
            catch (_: Exception) { let _ = resource.revoke(); return hostLifecycleLeaseError("plugin.http_service_transport_unavailable") }
        let managed = HostPluginManagedService(catalog, host, resource, transport, httpRefreshControl.getOrThrow(), payloadOwner: Some(owner))
        lock.lock()
        try {
            if (closed) { return hostLifecycleLeaseError("plugin.lifecycle_manager_closed") }
            var index: Int64 = 0
            while (index < services.size) {
                if (services[index].resourcesReleased()) { services.remove(at: index) } else { index += 1 }
            }
            if (services.size >= 32) { return hostLifecycleLeaseError("plugin.lifecycle_manager_capacity") }
            var matching: Int64 = 0
            for (item in services where item.namespace == configuration.namespace) {
                matching += 1
                if (item.sameLaunch(grant)) { return hostLifecycleLeaseError("plugin.lifecycle_manager_scope_busy") }
            }
            if (matching >= hostLifecycleInt(grant.launchPlan, "max_instances", 32)) { return hostLifecycleLeaseError("plugin.lifecycle_manager_capacity") }
            services.add(managed)
        } finally { lock.unlock() }
        let startupScope = HostLifecycleIoScope(targetContext.cancellation.deadlineMillis, { => let _ = managed.revoke() })
        startupScope.arm(targetContext.cancellation)
        var published = false
        try {
            let outcome = match (control.launch(vnext, targetContext, SessionId(maintenanceThread.value), resource,
                { context, prepared =>
                    // Approval and canonical handoff happened before this callback.
                    let endpoint = match (host.pinServiceEndpoint(grant, targetContext, maintenanceThread, route, expectedGeneration,
                        startupContext: Some(context), leaseCancellation: Some(resource.cancellation()))) {
                        case HostServiceEndpointSelection.Ready(value) => managed.captureEndpoint(value); value
                        case HostServiceEndpointSelection.Rejected(error) => return Result.Err(error)
                        case HostServiceEndpointSelection.CleanupRequired(value, original, _) =>
                            managed.captureEndpoint(value); return Result.Err(original)
                    }
                    let directory = match (managed.executeStartup(context, prepared)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
                    }
                    let frozen = match (managed.freezeDirectory(directory)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
                    }
                    resource.startupSummary(endpoint, frozen)
                }, approval, budget)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
            }
            let succeeded = match (outcome) { case ToolInvocationResult.Completed(value) => !value.isError; case _ => false }
            if (!succeeded) { return Result.Ok(HostPluginManagedStart(outcome, Option<HostPluginManagedService>.None)) }
            if (!resource.isActive()) { return hostLifecycleLeaseError("plugin.http_service_start_stale") }
            match (managed.publish()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            startupScope.checkDeadline()
            if (startupScope.finish()) { return hostLifecycleStartupCancelled() }
            published = true; Result.Ok(HostPluginManagedStart(outcome, Some(managed)))
        } catch (_: Exception) { hostManagedChannelUnknown() }
        finally {
            let _ = startupScope.finish(); managed.finishStartup()
            if (!published) { let _ = managed.revoke() }
        }
    }

    public func hasOwnerLifetimeDebt180(): Bool {
        lock.lock(); try {
            if (owner.hasOwnerLifetimeDebt180()) { return true }
            for (service in services) { if (service.hasOwnerLifetimeDebt180()) { return true } }
            false
        } finally { lock.unlock() }
    }
    public func statuses(): Array<AgentValue> {
        lock.lock(); let selected = try { services.toArray() } finally { lock.unlock() }
        selected.map({ value => value.status() })
    }
    public func stop(target: ThreadId, namespace: String, serviceId: String): Result<Unit> {
        lock.lock(); let selected = try { services.toArray() } finally { lock.unlock() }
        var found = false; var pending = false
        for (service in selected where service.matches(target, namespace, serviceId)) {
            found = true
            if (service.stopFrozen().isError()) { pending = true }
        }
        if (!found) { hostLifecycleLeaseError("plugin.service_not_active") }
        else if (pending) { hostLifecycleLeaseError("plugin.lifecycle_manager_cleanup_pending") }
        else { Result.Ok(()) }
    }

    public func stopThread(target: ThreadId): Result<Unit> {
        lock.lock(); let selected = try { services.toArray() } finally { lock.unlock() }
        var pending = false
        for (service in selected where service.matchesThread(target)) {
            if (service.revoke().isError()) { pending = true }
        }
        if (pending) { hostLifecycleLeaseError("plugin.lifecycle_manager_cleanup_pending") } else { Result.Ok(()) }
    }

    // Same canonical startup entry, with a generic bounded service-protocol
    // adapter. Neither method nor backend protocol names are host dispatch keys.
    public func startProtocol(vnext: HostServiceToolControl, targetContext: ToolInvocationContext, maintenanceThread: ThreadId,
        configuration: HostPluginLifecycleConfiguration, serviceId: String, route: String,
        expectedGeneration: UInt64, approvalDecision: ApprovalDecision,
        budget!: ExecutionBudget = ExecutionBudget(maxToolCalls: 1, maxConcurrentTools: 1)
    ): Result<HostPluginManagedStart> {
        start(vnext, targetContext, maintenanceThread, configuration, serviceId, route, expectedGeneration,
            { endpoint, lease, context, prepared =>
                hostInvokeManagedProtocolStartup(host, endpoint, lease, context, prepared, configuration.configuration)
            }, approvalDecision, budget: budget)
    }

    public func refresh(vnext: HostServiceToolControl, context: ToolInvocationContext,
        namespace: String, serviceId: String, approval: ApprovalDecision, budget: ExecutionBudget): Result<ToolInvocationResult> {
        lock.lock(); let retained = try { if (closed) { return hostLifecycleLeaseError("plugin.lifecycle_manager_closed") }; services.toArray() }
            finally { lock.unlock() }
        for (service in retained where service.matches(ThreadId(context.sessionId.value), namespace, serviceId) && service.active()) {
            return service.refresh(vnext, context, approval, budget)
        }
        hostLifecycleLeaseError("plugin.service_not_active")
    }

    func writeInvocation(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (prepared.source.parentOperationId.isNone() || prepared.source.kind != PreparedInvocationSourceKind.Derived ||
            !isChannelServiceChildPlan(prepared.operationPlan)) {
            return hostPluginResourceError("channel.source_invalid", "channel writer requires its exact admitted child source")
        }
        lock.lock(); let selected = try { if (closed) { return hostLifecycleLeaseError("plugin.lifecycle_manager_closed") }; services.toArray() }
            finally { lock.unlock() }
        for (service in selected) {
            match (service.invocationFor(prepared)) {
                case Some(value) => return value.executeChild(context, prepared)
                case None => ()
            }
        }
        hostPluginResourceError("channel.invocation_closed", "no host-held active invocation owns this child")
    }

    func executeHttpStreamChild(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        if (prepared.source.parentOperationId.isNone() || prepared.source.kind != PreparedInvocationSourceKind.Derived ||
            !isHttpStreamServiceChildPlan(prepared.operationPlan)) {
            return hostPluginResourceError("http.stream_source_invalid", "HTTP stream requires its exact admitted child source")
        }
        lock.lock(); let selected = try { if (closed) { return hostLifecycleLeaseError("plugin.lifecycle_manager_closed") }; services.toArray() }
            finally { lock.unlock() }
        for (service in selected) {
            match (service.invocationFor(prepared)) {
                case Some(value) => return value.executeChild(context, prepared)
                case None => ()
            }
        }
        hostPluginResourceError("http.stream_invocation_closed", "no host-held active invocation owns this child")
    }

    public func retainedCount(): Int64 {
        lock.lock()
        try { var count: Int64 = 0; for (item in services where !item.resourcesReleased()) { count += 1 }; count }
        finally { lock.unlock() }
    }
    public func close(): Result<Unit> {
        lock.lock()
        let selected = try { closed = true; services.toArray() } finally { lock.unlock() }
        var pending = false
        for (item in selected) { if (item.revoke().isError()) { pending = true } }
        let ownerClosed = owner.close().isOk()
        if (pending || !ownerClosed) { hostLifecycleLeaseError("plugin.lifecycle_manager_cleanup_pending") } else { Result.Ok(()) }
    }
}

public class HostPluginManagedService {
    public let namespace: String
    private let catalog: ToolCatalog
    private let host: HostJavaScriptPluginHost
    private let resource: HostManagedServiceResource
    private let transport: HostManagedServiceTransport
    private let refreshController: HostPluginLifecycleRefreshControl
    private let grant: HostNativeServiceEndpointGrant
    private let payloadOwner: ?HostPluginLifecycleOwner
    private let managedJobLauncher: ?HostManagedJobLauncher
    private let managedJobPreparations = HashMap<String, HostManagedJobPreparation>()
    private let managedJobIds = HostIds()
    // Scheduling reservation only; the sealed Task source remains authority.
    // It prevents another call stealing this one persistent worker between the
    // parent launch Receipt and the child invocation or its cleanup ACK.
    private var pendingManagedJob: ?String = None
    private var invocation: ?HostManagedServiceInvocation = None
    private var invocationOpening = false
    private var refreshing = false
    private var preparations: Int64 = 0
    private var refreshError = ""
    private let lock = Mutex()
    private var endpoint: ?HostPinnedNativeServiceEndpoint = None
    private var directoryText: ?String = None
    private var catalogOwner: ?ToolCatalogOwner = None
    private var publication: ?ToolCatalogPublication = None
    private var leaseRegistration: ?CancellationRegistration = None
    private var endpointRegistration: ?process.CancellationRegistration = None
    private var closing = false
    private var normalShutdown=false
    private var released = false
    private var startupFinished = false
    private var cleanupRunning = false
    private let monitorStop=AtomicBool(false)
    private var monitor: ?Future<Unit> = None
    private var cleanup: ?Future<Unit> = None
    init(catalog: ToolCatalog, host: HostJavaScriptPluginHost,
        resource: HostManagedServiceResource, transport: HostManagedServiceTransport,
        refreshController: HostPluginLifecycleRefreshControl, payloadOwner!: ?HostPluginLifecycleOwner = None,
        managedJobLauncher!: ?HostManagedJobLauncher = None) {
        this.catalog = catalog; this.host = host; this.resource = resource; this.transport = transport
        this.refreshController = refreshController
        this.payloadOwner = payloadOwner; this.managedJobLauncher = managedJobLauncher
        this.grant = resource.endpointGrant()
        this.namespace = hostLifecycleText(grant.endpointBinding(), "namespace")
    }
    // Only the manager's actual pinned endpoint mints the connection identity.
    // The binding still conveys no capability or child admission by itself.
    func filePlanIdentity(selected: HostPinnedNativeServiceEndpoint): Result<HostPluginServiceIdentity> {
        lock.lock()
        try {
            if (closing || endpoint.isNone() || !refEq(endpoint.getOrThrow(), selected) || publication.isNone()) {
                return hostLifecycleLeaseError("plugin.lifecycle_endpoint_stale")
            }
            Result.Ok(HostPluginServiceIdentity(host, namespace, selected.generation.instanceGeneration))
        } finally { lock.unlock() }
    }
    func acquireRegistryHandoff(revision!: ?Int64 = None): Result<ToolExecutionHandoffLease> {
        lock.lock()
        let selected = try {
            if (closing || endpoint.isNone() || publication.isNone() ||
                (revision.isSome() && revision.getOrThrow() != publication.getOrThrow().revision)) {
                return hostLifecycleLeaseError("plugin.lifecycle_endpoint_stale")
            }
            endpoint.getOrThrow()
        } finally { lock.unlock() }
        hostRegistryHandoff(selected.generation.enterRegistryEffect())
    }
    func matchesThread(target: ThreadId): Bool { grant.endpointTargetThread().value == target.value }
    func matches(target: ThreadId, plugin: String, serviceId: String): Bool {
        namespace == plugin && grant.endpointTargetThread().value == target.value &&
            hostLifecycleText(grant.endpointBinding(), "service_id") == serviceId
    }
    public func status(): AgentValue {
        let acknowledged=resourcesReleased()
        lock.lock()
        try {
            objectValue([ValueField("plugin", textValue(namespace)),
                ValueField("service_id", grant.endpointBinding().field("service_id").getOrThrow()),
                ValueField("target_thread_id", textValue(grant.endpointTargetThread().value)),
                ValueField("state", textValue(if (acknowledged) { "released" } else if (closing) { "draining" }
                    else if (publication.isSome()) { "ready" } else { "starting" })),
                ValueField("directory_revision", match (publication) { case Some(value) => integerValue(value.revision); case None => integerValue(0) }),
                ValueField("refresh_error", textValue(refreshError)), ValueField("refreshing", boolValue(refreshing)),
                ValueField("cleanup_acknowledged", boolValue(acknowledged))])
        } finally { lock.unlock() }
    }
    func captureEndpoint(value: HostPinnedNativeServiceEndpoint): Unit {
        lock.lock(); let stopping = try { endpoint = Some(value); closing } finally { lock.unlock() }
        if (stopping) { value.revoke() }
    }
    func finishStartup(): Unit { lock.lock(); try { startupFinished = true } finally { lock.unlock() } }
    func sameLaunch(other: HostNativeServiceEndpointGrant): Bool {
        resource.launchKey() == hostManagedServiceLaunchKey(other)
    }
    // Inspect the actual private owners, not allocated status DTOs. A
    // completed Future is observed here; original cleanup joins stay in close.
    func hasOwnerLifetimeDebt180(): Bool {
        lock.lock(); try {
            if (!released || !startupFinished || cleanupRunning || invocationOpening ||
                invocation.isSome() || refreshing || preparations != 0 || pendingManagedJob.isSome() ||
                !managedJobPreparations.isEmpty() || leaseRegistration.isSome() || endpointRegistration.isSome()) { return true }
            try {
                match (monitor) { case Some(value) => if (value.tryGet().isNone()) { return true }; case None => () }
                match (cleanup) { case Some(value) => if (value.tryGet().isNone()) { return true }; case None => () }
                false
            } catch (_: Exception) { true }
        } finally { lock.unlock() }
    }
    public func resourcesReleased():Bool{
        lock.lock();let (done,returned)=try{(released,cleanup)}finally{lock.unlock()}
        if(!done){return false}
        try{match(returned){case Some(value)=>value.get();case None=>()};true}catch(_:Exception){false}
    }
    public func active(): Bool {
        lock.lock()
        let selectedEndpoint = try { if (closing || publication.isNone()) { return false }; endpoint }
            finally { lock.unlock() }
        resource.isActive() && selectedEndpoint.isSome() && selectedEndpoint.getOrThrow().available()
    }
    private func protocolLimits(): ServiceProtocolLimits { serviceProtocolLimits(grant.endpointBinding()).value().getOrThrow() }
    func freezeDirectory(value: AgentValue): Result<AgentValue> {
        try {
            match(resource as HostManagedOwnedChannelResource){case Some(actual)=>
                match(actual.retainDirectoryMetadata(value)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
                case None=>()}
            let frozen = parseUnifiedJson(stringifyUnifiedJson(value), maxBytes: protocolLimits().maxDirectoryBytes)
            hostLifecycleRequire(hostManagedServiceDurableValueFits(frozen), "plugin.service_result_codec_limit")
            hostLifecycleExact(frozen, ["tools"])
            let tools = frozen.field("tools").getOrThrow()
            hostLifecycleRequire(tools.unifiedKind == ValueKind.List && tools.items.size <= protocolLimits().maxTools)
            let names = HashSet<String>()
            for (item in tools.items) {
                hostLifecycleExact(item, ["name", "description", "input_schema"])
                let name = hostLifecycleText(item, "name")
                hostLifecycleRequire(hostLifecycleIdentifier(name, 128) && !name.contains(":") && !name.contains(".") && !names.contains(name))
                names.add(name)
                hostLifecycleRequire(hostLifecycleText(item, "description").size <= 4096 &&
                    item.field("input_schema").getOrThrow().unifiedKind == ValueKind.Object)
            }
            lock.lock()
            try { if (closing) { return hostLifecycleLeaseError("plugin.lifecycle_manager_revoked") }
                directoryText = Some(stringifyUnifiedJson(frozen))
            } finally { lock.unlock() }
            Result.Ok(frozen)
        } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_directory_invalid") }
    }

    public func publish(): Result<Unit> {
        lock.lock()
        let (selectedEndpoint, frozenDirectory) = try {
            if (closing) { return hostLifecycleLeaseError("plugin.lifecycle_publication_stale") }
            (endpoint.getOrThrow(), directoryText.getOrThrow())
        } finally { lock.unlock() }
        if (!resource.isActive() || !selectedEndpoint.available() || grant.stillCurrent().isError()) {
            return hostLifecycleLeaseError("plugin.lifecycle_publication_stale")
        }
        let instance = modelPolicySha256Text(selectedEndpoint.endpointIdentity + ":" + resource.resourceIdentity())
        let prefix = "plugin." + hostLifecycleText(grant.endpointBinding(), "namespace") + ".service." +
            hostLifecycleText(grant.endpointBinding(), "service_id") + "."
        let owned = match (catalog.createContributionOwner("service-" + instance, prefix, threadId: Some(grant.endpointTargetThread()), maximumEntries: protocolLimits().maxTools,
            maximumDirectoryBytes: if (protocolLimits().isExplicit) { protocolLimits().maxDirectoryBytes } else { 1048576 })) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        lock.lock(); try { catalogOwner = Some(owned) } finally { lock.unlock() }
        let leaseObserver = resource.observeRevocation({ => let _ = revoke() })
        let endpointObserver = selectedEndpoint.observeRevocation({ => let _ = revoke() })
        lock.lock()
        let stopping = try {
            if (!closing) { leaseRegistration = Some(leaseObserver); endpointRegistration = Some(endpointObserver) }
            closing
        } finally { lock.unlock() }
        if (stopping) {
            leaseObserver.dispose(); endpointObserver.dispose(); let _ = catalog.revokeOwned(owned)
            return hostLifecycleLeaseError("plugin.lifecycle_publication_stale")
        }
        let entries = registrations(frozenDirectory, 1)
        let binding = ToolContributionBinding(hostLifecycleText(grant.endpointBinding(), "package_digest"),
            hostLifecycleText(grant.endpointBinding(), "configuration_digest"), instance, 1)
        let result = match (catalog.replaceOwnedBatch(owned, 0, binding, entries)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        lock.lock()
        try { publication = Some(result) } finally { lock.unlock() }
        // A revocation before the CAS makes it fail. A revocation after the
        // CAS withdraws the same owner; neither can leave a usable late entry.
        if (!active() || grant.stillCurrent().isError()) {
            let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_publication_stale")
        }
        // Register the actual Task under the same lock used by cleanup.
        // finishStartup runs only after this publication frame returns.
        lock.lock()
        try{
            if(!closing && !released){monitor = Some(spawn {
                while (!monitorStop.load()) {
                    lock.lock();let shuttingDown=try{closing}finally{lock.unlock()}
                    if (!shuttingDown && !active()) { let _ = revoke() }
                    sleep(Duration.millisecond * 25)
                }
            })}
        }finally{lock.unlock()}
        Result.Ok(())
    }

    private func ownedChannelRegistrations(frozenDirectory:String,revision:Int64,instance:String,prefix:String):Array<ToolCatalogRegistration>{
        let entries=ArrayList<ToolCatalogRegistration>()
        let directory=parseUnifiedJson(frozenDirectory,maxBytes:protocolLimits().maxDirectoryBytes)
        let required=resource.requiredCapabilities().clone()
        if(required.isEmpty()){throw IllegalStateException("owned channel has no ordinary capability boundary")}
        for(item in directory.field("tools").getOrThrow().items){
            let name=prefix+hostLifecycleText(item,"name")
            entries.add(ToolCatalogRegistration(ToolDescriptor(ModelToolDefinition(name,
                hostLifecycleText(item,"description"),item.field("input_schema").getOrThrow()),required[0],
                sideEffecting:true,neverReplay:true,
                additionalCapabilityResolver:Some({_=>required[1..].clone()}),
                networkPolicyResolver:Some({_=>resource.networkPolicy()}),
                implementationVersion:HOST_MANAGED_CHANNEL_OWNED_VERSION,implementationFingerprint:"owned-v1:"+instance,
                preparationReadResolver:Some({context,call=>preparationRead(context,call,revision)}),
                canonicalArgumentsResolver:Some({context,call=>canonicalize(context,call,revision)})),
                HostManagedChannelOwnedDriver(HostManagedChannelActualOwnedEndpoint(this,revision))))
        };entries.toArray()
    }
    private func registrations(frozenDirectory: String, revision: Int64): Array<ToolCatalogRegistration> {
        let entries = ArrayList<ToolCatalogRegistration>()
        let instance = modelPolicySha256Text(endpoint.getOrThrow().endpointIdentity + ":" + resource.resourceIdentity())
        let prefix = "plugin." + namespace + ".service." + hostLifecycleText(grant.endpointBinding(), "service_id") + "."
        match(transport as HostManagedOwnedChannelTransport){case Some(_)=>return ownedChannelRegistrations(frozenDirectory,revision,instance,prefix)
            case None=>()}
        let directory = parseUnifiedJson(frozenDirectory, maxBytes: protocolLimits().maxDirectoryBytes)
        let required = resource.requiredCapabilities().clone()
        if (required.isEmpty()) { throw IllegalStateException("managed service has no capability boundary") }
        for (item in directory.field("tools").getOrThrow().items) {
            let localName = hostLifecycleText(item, "name")
            let name = prefix + localName
            entries.add(ToolCatalogRegistration(ToolDescriptor(ModelToolDefinition(name,
                hostLifecycleText(item, "description"), item.field("input_schema").getOrThrow()),
                required[0], sideEffecting: !serviceGrantDeclaresReadOnly(grant.endpointBinding(), localName), neverReplay: true,
                additionalCapabilityResolver: Some({ call =>
                    let values = ArrayList<Capability>(required[1..].clone())
                    match (call.arguments.field("host_plan")) { case Some(plan) =>
                        if (plan.field("managed_job").isSome()) { values.add(Capability(CapabilityKind.Delegate, resource: "managed-job")) }
                        case None => () }
                    values.toArray()
                }),
                networkPolicyResolver: Some({ _ => resource.networkPolicy() }),
                implementationVersion: "plugin-managed-service-v1",
                implementationFingerprint: "plugin-managed-service-v1:" + instance,
                preparationReadResolver: Some({ context, call => preparationRead(context, call, revision) }),
                canonicalArgumentsResolver: Some({ context, call => canonicalize(context, call, revision) })),
                HostPluginManagedToolExecutor(this, localName, revision)))
        }
        entries.toArray()
    }

    private func validateReadBoundary(context: ToolInvocationContext, tool: String, revision: Int64,
        frozenBinding: String, arguments: AgentValue): Result<Unit> {
        match (checkContext(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        try {
            if (closing || refreshing || publication.isNone() || publication.getOrThrow().revision != revision) {
                return hostLifecycleLeaseError("context.read_directory_changed") }
        } finally { lock.unlock() }
        let current = match (bindingForPreparation(context,tool)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        if (canonicalAgentValue(current) != frozenBinding || arguments.field("binding").isNone() ||
            canonicalAgentValue(arguments.field("binding").getOrThrow()) != frozenBinding) {
            return hostLifecycleLeaseError("context.read_binding_changed") }
        Result.Ok(())
    }

    // Pure protocol query may request a bounded read. Only Core can turn this
    // data into the same Run's sealed read source and canonical Operation.
    private func preparationRead(context: ToolInvocationContext, call: ToolCall, revision: Int64): Result<?ToolPreparationRead> {
        if (call.arguments.field(CONTEXT_READ_INPUT_FIELD).isSome()) {
            return hostLifecycleLeaseError("context.read_input_unattested") }
        lock.lock()
        try {
            if (closing || refreshing || publication.isNone() || publication.getOrThrow().revision != revision) {
                return hostLifecycleLeaseError("plugin.lifecycle_directory_stale") }
            preparations += 1
        } finally { lock.unlock() }
        try { preparationReadCurrent(context, call, revision) }
        finally { lock.lock(); try { preparations -= 1 } finally { lock.unlock() } }
    }

    private func preparationReadCurrent(context: ToolInvocationContext, call: ToolCall, revision: Int64): Result<?ToolPreparationRead> {
        match (checkContext(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let binding = match (bindingForPreparation(context,call.name)) { case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        let frozenBinding = canonicalAgentValue(binding)
        let prefix = "plugin." + namespace + ".service." + hostLifecycleText(grant.endpointBinding(), "service_id") + "."
        if (!call.name.startsWith(prefix)) { return hostLifecycleLeaseError("plugin.lifecycle_tool_not_published") }
        let limits = servicePayloadLimits(grant.endpointBinding()).value().getOrThrow()
        let input = try { parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes:
            match (limits) { case Some(value) => value.maxInputBytes; case None => protocolLimits().maxInputBytes }) }
            catch (_: Exception) { return hostLifecycleLeaseError("plugin.lifecycle_input_limit") }
        lock.lock(); let selected = try { endpoint.getOrThrow() } finally { lock.unlock() }
        if (!selected.generation.descriptor.requestedCapabilities.contains(transport.requestedCapability())) {
            return hostLifecycleLeaseError("plugin.service_capability_not_requested") }
        let response = match (host.prepareService(selected,
            stringifyUnifiedJson(preparationArgumentsFor(context,call.name[prefix.size..],input)),
            JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
                epoch: context.epoch, operationId: "", callId: call.callId, kind: "service_prepare"), context)) {
            case Result.Ok(value) => value; case Result.Err(error) => return Result.Err(error) }
        try {
            if (response.isError) { return hostLifecycleLeaseError("plugin.lifecycle_preparation_invalid") }
            if (httpIntentExactFields(response.value, ["intents"])) { return Result.Ok(Option<ToolPreparationRead>.None) }
            // Managed preparation is another pure no-read result. This
            // validates its data only; canonicalizeCurrent must still freeze
            // the exact plan and the ordinary capability/approval barrier.
            if (response.value.field("managed_job").isSome()) {
                if (transport.requestedCapability() != "process.channel" || managedJobLauncher.isNone() ||
                    !selected.supportsPreparationReference() || !httpIntentExactFields(response.value, ["intents", "managed_job"])) {
                    return hostLifecycleLeaseError("task.managed_job_endpoint_unsupported") }
                match (managedJobRequestedTimeout(response.value.field("managed_job").getOrThrow())) {
                    case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                return Result.Ok(Option<ToolPreparationRead>.None)
            }
            if (!httpIntentExactFields(response.value, ["context_read"]) ||
                !httpIntentExactFields(response.value.field("context_read").getOrThrow(), ["resources"])) {
                return hostLifecycleLeaseError("context.read_request_invalid") }
            let raw = response.value.field("context_read").getOrThrow().field("resources").getOrThrow()
            if (raw.unifiedKind != ValueKind.List || raw.items.size < 1 || raw.items.size > 32) {
                return hostLifecycleLeaseError("context.read_resource_limit") }
            for (item in raw.items) {
                if (!httpIntentExactFields(item, ["source", "path", "mode"])) {
                    return hostLifecycleLeaseError("context.read_request_invalid") }
            }
            let request = objectValue([ValueField("schema", textValue(CONTEXT_READ_RESOURCE_SCHEMA)),
                ValueField("binding", binding), ValueField("resources", raw)])
            match (validateReadBoundary(context, call.name, revision, frozenBinding, request)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            // Freeze values while the response still owns its payload charge.
            let requestJson = stringifyUnifiedJson(request); let originalJson = stringifyUnifiedJson(input)
            let _ = parseUnifiedJson(requestJson, maxBytes: 65536)
            let tool = call.name; let owner = namespace
            let packageDigest = httpIntentText(binding, "package_digest")
            let configurationDigest = httpIntentText(binding, "configuration_digest")
            Result.Ok(Some(ToolPreparationRead(owner, packageDigest, configurationDigest,
                parseUnifiedJson(requestJson, maxBytes: 65536), { actual, facts =>
                    match (validateReadBoundary(actual, tool, revision, frozenBinding, parseUnifiedJson(requestJson, maxBytes: 65536))) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                    if (facts.size != 1 || facts[0].runId.value != actual.runId.value ||
                        facts[0].origin.ownerNamespace != owner || facts[0].origin.packageDigest != packageDigest ||
                        facts[0].origin.configurationDigest != configurationDigest) {
                        return hostLifecycleLeaseError("context.read_fact_changed") }
                    let data = facts[0].output()
                    if (!httpIntentExactFields(data, ["schema", "resources"]) ||
                        httpIntentText(data, "schema") != "axyndra.context-read-result/v1") {
                        return hostLifecycleLeaseError("context.read_fact_invalid") }
                    let original = parseUnifiedJson(originalJson, maxBytes: 8388608)
                    let fields = ArrayList<ValueField>(original.fields.toArray())
                    fields.add(ValueField(CONTEXT_READ_INPUT_FIELD, objectValue([
                        ValueField("schema", textValue("axyndra.context-read-input/v1")), ValueField("data", data),
                        ValueField("facts", contextReadFactLinksValue([facts[0].link()]))])))
                    Result.Ok(objectValue(fields.toArray()))
                }, boundary: Some({ actual, args => validateReadBoundary(actual, tool, revision, frozenBinding, args) }))))
        } catch (_: Exception) { hostLifecycleLeaseError("context.read_request_invalid") }
        finally { response.releasePayload() }
    }

    public func canonicalize(context: ToolInvocationContext, call: ToolCall, revision: Int64): Result<AgentValue> {
        lock.lock()
        try {
            if (closing || refreshing || publication.isNone() || publication.getOrThrow().revision != revision) {
                return hostLifecycleLeaseError("plugin.lifecycle_directory_stale")
            }
            preparations += 1
        } finally { lock.unlock() }
        try { canonicalizeCurrent(context, call) }
        finally { lock.lock(); try { preparations -= 1 } finally { lock.unlock() } }
    }

    private func canonicalizeCurrent(context: ToolInvocationContext, call: ToolCall): Result<AgentValue> {
        match (checkContext(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let payload = servicePayloadLimits(grant.endpointBinding()).value().getOrThrow()
        if (payload.isSome() && !hostManagedServiceDurableValueFits(call.arguments)) { return hostLifecycleLeaseError("plugin.lifecycle_input_codec_limit") }
        let input = try { parseUnifiedJson(stringifyUnifiedJson(call.arguments), maxBytes:
            match (payload) { case Some(limits) => limits.maxInputBytes; case None => protocolLimits().maxInputBytes }) }
            catch (_: Exception) { return hostLifecycleLeaseError("plugin.lifecycle_input_limit") }
        let binding = match (bindingForPreparation(context,call.name)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let prefix = "plugin." + namespace + ".service." + hostLifecycleText(grant.endpointBinding(), "service_id") + "."
        if (!call.name.startsWith(prefix)) { return hostLifecycleLeaseError("plugin.lifecycle_tool_not_published") }
        lock.lock(); let selectedEndpoint = try { endpoint.getOrThrow() } finally { lock.unlock() }
        if (!selectedEndpoint.generation.descriptor.requestedCapabilities.contains(transport.requestedCapability())) {
            return hostLifecycleLeaseError("plugin.service_capability_not_requested")
        }
        let response = match (host.prepareService(selectedEndpoint,
            stringifyUnifiedJson(preparationArgumentsFor(context,call.name[prefix.size..],input)),
            JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
                epoch: context.epoch, operationId: "", callId: call.callId, kind: "service_prepare"), context)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        try {
            if (response.isError) { return hostLifecycleLeaseError("plugin.lifecycle_preparation_invalid") }
            let jobRequest = response.value.field("managed_job")
            let pure = if (jobRequest.isSome()) {
                if (transport.requestedCapability() != "process.channel" || managedJobLauncher.isNone() ||
                    !selectedEndpoint.supportsPreparationReference() || !httpIntentExactFields(response.value, ["intents", "managed_job"])) {
                    return hostLifecycleLeaseError("task.managed_job_endpoint_unsupported") }
                objectValue([ValueField("intents", response.value.field("intents").getOrThrow())])
            } else { response.value }
            let frozen = match (transport.freezeIntents(context, call, input, pure, binding)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
            }
            match (jobRequest) { case Some(value) =>
                match (freezeManagedJob(context, call, frozen, value)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
                case None => () }
            match (checkContext(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            Result.Ok(frozen)
        } finally { response.releasePayload() }
    }
    private func managedJobRequestedTimeout(requested: AgentValue): Result<Int64> {
        if (!httpIntentExactFields(requested, ["timeout_ms"]) || requested.field("timeout_ms").getOrThrow().unifiedKind != ValueKind.Number) {
            return hostLifecycleLeaseError("task.managed_job_request_invalid") }
        let timeout = try { Int64.parse(requested.field("timeout_ms").getOrThrow().asNumberText()) }
            catch (_: Exception) { return hostLifecycleLeaseError("task.managed_job_request_invalid") }
        if (timeout < 1 || timeout > min(3600000, protocolLimits().callTimeoutMillis) ||
            requested.field("timeout_ms").getOrThrow().asNumberText() != timeout.toString()) {
            return hostLifecycleLeaseError("task.managed_job_request_invalid") }
        Result.Ok(timeout)
    }

    private func freezeManagedJob(context: ToolInvocationContext, call: ToolCall,
        frozen: AgentValue, requested: AgentValue): Result<Unit> {
        let timeout = match (managedJobRequestedTimeout(requested)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let key = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("thread", textValue(context.sessionId.value)), ValueField("run", textValue(context.runId.value)),
            ValueField("epoch", integerValue(context.epoch)), ValueField("call", textValue(call.callId))])))
        let digest = modelPolicySha256Text(canonicalAgentValue(objectValue([
            ValueField("tool", textValue(call.name)), ValueField("frozen", frozen), ValueField("request", requested)])))
        lock.lock()
        try {
            match (managedJobPreparations.get(key)) { case Some(previous) =>
                if (previous.digest != digest) { return hostLifecycleLeaseError("task.managed_job_preparation_changed") }
                frozen.field("host_plan").getOrThrow().put("managed_job", parseUnifiedJson(previous.declaration))
                return Result.Ok(())
                case None => () }
            if (managedJobPreparations.size >= 4096) { return hostLifecycleLeaseError("task.managed_job_preparation_capacity") }
            var deadline = agentUtcMillis() + timeout
            for (limit in [context.cancellation.deadlineMillis, context.budget.deadlineMillis] where limit > 0) { deadline = min(deadline, limit) }
            if (deadline <= agentUtcMillis()) { return hostLifecycleLeaseError("task.managed_job_deadline_invalid") }
            let count = frozen.field("host_plan").getOrThrow().field("intents").getOrThrow().items.size + 1
            if (count > context.budget.maxToolCalls) { return hostLifecycleLeaseError("task.managed_job_budget_invalid") }
            let declaration = managedJobDeclarationValue(ManagedJobDeclaration(managedJobIds.nextInvocationId(),
                ThreadId(managedJobIds.nextSessionId().value), managedJobIds.nextRunId(), deadline, count))
            managedJobPreparations[key] = HostManagedJobPreparation(digest, stringifyUnifiedJson(declaration))
            frozen.field("host_plan").getOrThrow().put("managed_job", declaration)
            Result.Ok(())
        } finally { lock.unlock() }
    }
    private func checkContext(context: ToolInvocationContext): Result<Unit> {
        lock.lock()
        let reserved = try { pendingManagedJob.isSome() } finally { lock.unlock() }
        if (reserved) { return hostLifecycleLeaseError("plugin.lifecycle_invocation_busy") }
        if (!active()) { return hostLifecycleLeaseError("plugin.lifecycle_invocation_stale") }
        resource.validateActive(context)
    }

    // Host-only metadata for the later exact-byte intent canonicalizer. Every
    // descriptor identity is the final owned publication, never plugin input.
    public func bindingFor(toolName: String): Result<AgentValue> {
        if (!active()) { return hostLifecycleLeaseError("plugin.lifecycle_invocation_stale") }
        lock.lock()
        let (published, selectedEndpoint) = try { (publication.getOrThrow(), endpoint.getOrThrow()) } finally { lock.unlock() }
        let metadata = match (resource.bindingMetadata(selectedEndpoint)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        match(transport as HostManagedOwnedChannelTransport){case Some(_)=>
            for(descriptor in published.descriptors where descriptor.definition.name==toolName){
                let fields=ArrayList<ValueField>(metadata.fields.toArray())
                for(name in ["directory_revision","directory_digest","implementation_version","implementation_fingerprint","schema_digest"] where metadata.field(name).isSome()){
                    return hostLifecycleLeaseError("plugin.lifecycle_binding_collision")}
                fields.add(ValueField("directory_revision",integerValue(published.revision)))
                fields.add(ValueField("directory_digest",textValue(published.directoryDigest)))
                fields.add(ValueField("implementation_version",textValue(descriptor.implementationVersion)))
                fields.add(ValueField("implementation_fingerprint",textValue(descriptor.implementationFingerprint)))
                fields.add(ValueField("schema_digest",textValue(descriptor.schemaDigest)))
                return Result.Ok(objectValue(fields.toArray()))
            };return hostLifecycleLeaseError("plugin.lifecycle_tool_not_published")
            case None=>()}
        for (descriptor in published.descriptors where descriptor.definition.name == toolName) {
            let values = ArrayList<ValueField>(metadata.fields.toArray())
            for (name in ["directory_revision", "directory_digest", "implementation_version", "implementation_fingerprint", "schema_digest", "read_only_tool", "protocol_limits", "payload_limits"]) {
                if (metadata.field(name).isSome()) { return hostLifecycleLeaseError("plugin.lifecycle_binding_collision") }
            }
            if (protocolLimits().isExplicit) { values.add(ValueField("protocol_limits", protocolLimits().toValue())) }
            match (servicePayloadLimits(grant.endpointBinding()).value().getOrThrow()) {
                case Some(limits) => values.add(ValueField("payload_limits", limits.toValue()))
                case None => ()
            }
            values.add(ValueField("directory_revision", integerValue(published.revision)))
            values.add(ValueField("directory_digest", textValue(published.directoryDigest)))
            values.add(ValueField("implementation_version", textValue(descriptor.implementationVersion)))
            values.add(ValueField("implementation_fingerprint", textValue(descriptor.implementationFingerprint)))
            values.add(ValueField("schema_digest", textValue(descriptor.schemaDigest)))
            if (!descriptor.sideEffecting) {
                let prefix = "plugin." + namespace + ".service." + hostLifecycleText(grant.endpointBinding(), "service_id") + "."
                if (!toolName.startsWith(prefix) || !serviceGrantDeclaresReadOnly(grant.endpointBinding(), toolName[prefix.size..])) {
                    return hostLifecycleLeaseError("plugin.lifecycle_effect_grant_stale")
                }
                values.add(ValueField("read_only_tool", textValue(toolName[prefix.size..])))
            }
            return Result.Ok(objectValue(values.toArray()))
        }
        hostLifecycleLeaseError("plugin.lifecycle_tool_not_published")
    }

    func validateInvocation(context: ToolInvocationContext, prepared: PreparedToolInvocation, binding: AgentValue): Result<Unit> {
        if (!active()) { return hostLifecycleLeaseError("plugin.lifecycle_invocation_stale") }
        match (resource.validateInvocation(context, prepared, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (prepared.source.operationRoot.isNone() || prepared.source.kind == PreparedInvocationSourceKind.Derived ||
            prepared.source.runId.value != context.runId.value || prepared.source.sessionId.value != context.sessionId.value ||
            prepared.source.epoch != context.epoch) {
            return hostLifecycleLeaseError("plugin.lifecycle_canonical_source_required")
        }
        match (transport.validateParent(context, prepared, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let current = match (bindingFor(prepared.call.name)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let registered = match (catalog.resolvedDescriptor(prepared.call, threadId: Some(grant.endpointTargetThread()))) {
            case Some(value) => value
            case None => return hostLifecycleLeaseError("plugin.lifecycle_tool_not_published")
        }
        if (canonicalAgentValue(current) != canonicalAgentValue(binding) ||
            registered.implementationFingerprint != hostLifecycleText(current, "implementation_fingerprint") ||
            registered.implementationVersion != hostLifecycleText(current, "implementation_version") ||
            registered.schemaDigest != hostLifecycleText(current, "schema_digest") ||
            canonicalAgentValue(prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
                .field("binding").getOrThrow()) != canonicalAgentValue(current)) {
            return hostLifecycleLeaseError("plugin.lifecycle_prepared_binding_mismatch")
        }
        Result.Ok(())
    }

    private func managedExecutionAcknowledged(jobId: String): Bool {
        lock.lock()
        let stopped = try {
            if (pendingManagedJob != Some(jobId)) { return true }
            if (invocationOpening || invocation.isSome()) { return false }
            closing
        } finally { lock.unlock() }
        // A normal persistent service is still live after a known command.
        // Once revoked, actual endpoint and backend ACK are both required.
        if (stopped && !resourcesReleased()) { return false }
        lock.lock()
        try {
            if (pendingManagedJob != Some(jobId)) { return true }
            if (invocationOpening || invocation.isSome() || closing != stopped) { return false }
            pendingManagedJob = None; true
        } finally { lock.unlock() }
    }

    func invocationFor(child: PreparedToolInvocation): ?HostManagedServiceInvocation {
        lock.lock()
        let current = try {
            if (closing || invocation.isNone() || child.source.parentOperationId.isNone()) { return None }
            invocation.getOrThrow()
        } finally { lock.unlock() }
        // Never call transport-owned locking/callback code under the catalog
        // owner's mutex. The executor still rechecks its exact live source.
        if (current.owns(child)) { Some(current) } else { None }
    }

    private func bindingForPreparation(context:ToolInvocationContext,tool:String):Result<AgentValue>{
        match(transport as HostManagedOwnedChannelTransport){
            case Some(_)=>lock.lock();let revision=try{publication.getOrThrow().revision}finally{lock.unlock()}
                ownedChannelBinding(context,tool,revision)
            case None=>bindingFor(tool)}
    }
    private func preparationArgumentsFor(context:ToolInvocationContext,localName:String,input:AgentValue):AgentValue{
        match(transport as HostManagedOwnedChannelTransport){case Some(actual)=>
            match(actual.preparationArgumentsFor(context,localName,input)){
                case Result.Err(error)=>throw HostArtifactOperationFailure(error);case Result.Ok(value)=>value}
            case None=>transport.preparationArguments(HostManagedServicePhase.Call,localName,input)}
    }
    func ownedChannelBinding(context:ToolInvocationContext,tool:String,revision:Int64):Result<AgentValue>{
        let actual=match(transport as HostManagedOwnedChannelTransport){case Some(value)=>value
            case None=>return managedChannelDriverError("managed_channel.actual_transport_missing")}
        match(actual.resource.validateActive(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        lock.lock();try{
            if(closing || publication.isNone() || publication.getOrThrow().revision!=revision){
                return managedChannelDriverError("managed_channel.publication_changed")}
        }finally{lock.unlock()}
        let base=match(bindingFor(tool)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let lane=match(actual.resource.runLane(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let fields=ArrayList<ValueField>(base.fields.toArray())
        for(name in ["lane_id","run_id","epoch"] where base.field(name).isSome()){
            return managedChannelDriverError("managed_channel.binding_collision")}
        fields.add(ValueField("lane_id",textValue(lane)));fields.add(ValueField("run_id",textValue(context.runId.value)))
        fields.add(ValueField("epoch",integerValue(context.epoch)))
        let binding=objectValue(fields.toArray())
        match(validateManagedChannelRuntimeBinding(binding)){case Result.Err(error)=>Result.Err(error);case Result.Ok(_)=>Result.Ok(binding)}
    }
    func validateOwnedChannelParent(context:ToolInvocationContext,parent:PreparedToolInvocation,revision:Int64):Result<Unit>{
        let actual=match(transport as HostManagedOwnedChannelTransport){case Some(value)=>value
            case None=>return managedChannelDriverError("managed_channel.actual_transport_missing")}
        if(context.trustedControl || parent.source.kind==PreparedInvocationSourceKind.Derived ||
            parent.source.operationRoot.isNone() ||
            parent.source.runId.value!=context.runId.value || parent.source.sessionId.value!=context.sessionId.value ||
            parent.source.epoch!=context.epoch || !isManagedChannelOwnedParentPlan(parent.operationPlan)){
            return managedChannelDriverError("managed_channel.actual_parent_required")}
        let current=match(ownedChannelBinding(context,parent.call.name,revision)){
            case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        let frozen=parent.operationPlan.canonicalArguments.field("host_plan").getOrThrow().field("binding").getOrThrow()
        for(field in frozen.fields where !["resource_state","lease_id","startup_operation_id"].contains(field.name)){
            if(current.field(field.name).isNone() || canonicalAgentValue(field.value)!=canonicalAgentValue(current.field(field.name).getOrThrow())){
                return managedChannelDriverError("managed_channel.parent_binding_changed")}}
        let registered=match(catalog.resolvedDescriptor(parent.call,threadId:Some(grant.endpointTargetThread()))){
            case Some(value)=>value;case None=>return managedChannelDriverError("managed_channel.actual_publication_missing")}
        if(registered.implementationFingerprint!=parent.operationPlan.implementation.implementationFingerprint ||
            registered.implementationVersion!=parent.operationPlan.implementation.toolVersion ||
            registered.schemaDigest!=parent.operationPlan.implementation.schemaDigest){
            return managedChannelDriverError("managed_channel.actual_publication_changed")}
        actual.resource.validateInvocation(context,parent,frozen)
    }
    func beginOwnedChannelInvocation(context:ToolInvocationContext,parent:PreparedToolInvocation,
        revision:Int64):Result<HostManagedChannelOwnedSession>{
        match(validateOwnedChannelParent(context,parent,revision)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let actual=match(transport as HostManagedOwnedChannelTransport){case Some(value)=>value
            case None=>return managedChannelDriverError("managed_channel.actual_transport_missing")}
        lock.lock()
        let selected=try{
            if(closing || refreshing || invocationOpening || invocation.isSome() || pendingManagedJob.isSome()){
                return managedChannelDriverError("managed_channel.actual_invocation_busy")}
            invocationOpening=true;endpoint.getOrThrow()
        }finally{lock.unlock()}
        let session=try{HostManagedChannelActualOwnedSession(this,host,actual.resource,selected,actual.port,revision,context,parent)}
            catch(_:Exception){lock.lock();try{invocationOpening=false}finally{lock.unlock()}
                return managedChannelDriverError<HostManagedChannelOwnedSession>("managed_channel.actual_invocation_capacity")}
        lock.lock();let stopped=try{invocation=Some(session);invocationOpening=false;closing}finally{lock.unlock()}
        if(stopped){let _=session.close();return managedChannelDriverError("managed_channel.actual_invocation_revoked")}
        Result.Ok(session)
    }
    func acknowledgeOwnedChannelInvocation(actual:HostManagedServiceInvocation):Result<Unit>{
        lock.lock();try{
            if(invocation.isSome() && hostSameManagedServiceInvocation(invocation.getOrThrow(),actual)){invocation=None}
            Result.Ok(())
        }finally{lock.unlock()}
    }
    func acquireOwnedChannelChildHandoff(context:ToolInvocationContext,child:PreparedToolInvocation):Result<ToolExecutionHandoffLease>{
        if((transport as HostManagedOwnedChannelTransport).isNone() || !isManagedChannelOwnedChildPlan(child.operationPlan)){
            return managedChannelDriverError("managed_channel.actual_child_family_changed")}
        let frozen=child.operationPlan.canonicalArguments.field("binding").getOrThrow()
        lock.lock();let selected=try{
            if(closing || publication.isNone() || endpoint.isNone() ||
                endpoint.getOrThrow().endpointIdentity!=httpIntentText(frozen,"endpoint_identity") ||
                publication.getOrThrow().revision.toString()!=frozen.field("directory_revision").getOrThrow().asNumberText()){
                return managedChannelDriverError<ToolExecutionHandoffLease>("managed_channel.actual_child_publication_changed")}
            publication.getOrThrow().revision
        }finally{lock.unlock()}
        let actual=match(transport as HostManagedOwnedChannelTransport){case Some(value)=>value
            case None=>return managedChannelDriverError("managed_channel.actual_transport_missing")}
        match(actual.resource.validateActive(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let lane=match(actual.resource.runLane(context)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        if(httpIntentText(frozen,"run_id")!=context.runId.value || httpIntentText(frozen,"target_thread_id")!=context.sessionId.value ||
            httpIntentText(frozen,"lane_id")!=lane || frozen.field("epoch").getOrThrow().asNumberText()!=context.epoch.toString()){
            return managedChannelDriverError("managed_channel.actual_child_run_changed")}
        acquireRegistryHandoff(revision:Some(selected))
    }

    public func invoke(localName: String, context: ToolInvocationContext, prepared: PreparedToolInvocation, revision: Int64): Result<ToolResult> {
        lock.lock()
        try {
            if (closing || refreshing || invocationOpening || invocation.isSome() || publication.isNone() || publication.getOrThrow().revision != revision) {
                return hostLifecycleLeaseError("plugin.lifecycle_directory_stale")
            }
        } finally { lock.unlock() }
        let binding = match (bindingFor(prepared.call.name)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        match (validateInvocation(context, prepared, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let delegated = hostManagedJobSource(prepared.source.operationRoot)
        if (isManagedJobLaunchPlan(prepared.operationPlan) && delegated.isNone()) {
            let launch = match (managedJobLauncher) { case Some(value) => value
                case None => return hostLifecycleLeaseError("task.managed_job_launcher_unavailable") }
            let jobId = managedJobDeclarationFromValue(prepared.operationPlan.canonicalArguments.field("host_plan").getOrThrow()
                .field("managed_job").getOrThrow()).jobId
            lock.lock()
            try {
                if (closing || refreshing || invocationOpening || invocation.isSome() || pendingManagedJob.isSome()) {
                    return hostLifecycleLeaseError("plugin.lifecycle_invocation_busy") }
                pendingManagedJob = Some(jobId)
            } finally { lock.unlock() }
            let outcome = try { launch(context, prepared, { => managedExecutionAcknowledged(jobId) }) }
                catch (_: Exception) { hostLifecycleLeaseError<ToolResult>("task.managed_job_launch_failed") }
            if (outcome.isError()) { let _ = managedExecutionAcknowledged(jobId) }
            return outcome
        }
        lock.lock()
        let selectedEndpoint = try {
            if (closing || refreshing || invocationOpening || invocation.isSome() ||
                (pendingManagedJob.isSome() && (delegated.isNone() ||
                    delegated.getOrThrow().managedJob.getOrThrow().binding.declaration.jobId != pendingManagedJob.getOrThrow()))) {
                return hostLifecycleLeaseError("plugin.lifecycle_invocation_busy") }
            invocationOpening = true; endpoint.getOrThrow()
        } finally { lock.unlock() }
        let opened = try { transport.beginInvocation(this, selectedEndpoint, context, prepared, binding) }
            catch (_: Exception) {
                lock.lock(); try { invocationOpening = false } finally { lock.unlock() }
                let _ = revoke(); return hostManagedChannelUnknown()
            }
        let observer = match (opened) {
            case Result.Err(error) =>
                lock.lock(); try { invocationOpening = false } finally { lock.unlock() }
                let _ = revoke(); return Result.Err(error)
            case Result.Ok(value) => value
        }
        lock.lock(); let stopped = try { invocation = Some(observer); invocationOpening = false; closing } finally { lock.unlock() }
        var payloadResult: ?HostJavaScriptPluginInvocationResult = None
        var retainedObservation: ?OperationObservation = None
        try {
            if (stopped) { return hostLifecycleLeaseError("plugin.lifecycle_invocation_stale") }
            let response = host.invokeService(selectedEndpoint, stringifyUnifiedJson(hostManagedServiceExecutionArguments(localName, prepared)),
                JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value, epoch: context.epoch,
                    operationId: prepared.operationId.value, callId: prepared.call.callId, kind: "service"), context, timeoutMillis: protocolLimits().callTimeoutMillis, observer: Some(observer), prepared: Some(prepared))
            match (response) { case Result.Ok(value) => payloadResult = Some(value); case _ => () }
            let current = validateInvocation(context, prepared, binding)
            let delivered = if (response.isOk() && current.isError()) { Result<HostJavaScriptPluginInvocationResult>.Err(current.error().getOrThrow()) } else { response }
            var outcome = match (observer.finish(delivered)) {
                case Result.Ok(value) => hostManagedServiceDurableResult(prepared, value)
                case Result.Err(error) => Result<ToolResult>.Err(error)
            }
            if (outcome.isError() && response.isOk() && payloadOwner.isSome() && servicePayloadLimits(binding).value().getOrThrow().isSome()) {
                let error = outcome.error().getOrThrow()
                // Preserve a complete filtered observation when either a
                // terminal Unknown or the final durable codec bound rejected
                // success. The observation cannot change that outcome.
                if (error.kind == AgentErrorKind.RecoveryRequired && stringifyUnifiedJson(response.value().getOrThrow().value).size > 65536) {
                    let observed = payloadOwner.getOrThrow().retainObservation(context, prepared, response.value().getOrThrow().value)
                    if (observed.isOk()) {
                        outcome = Result.Err(AgentError(error.kind, error.code, error.message, fields: error.fields,
                            retryable: error.retryable, fallbackAllowed: error.fallbackAllowed, attemptFailure: error.attemptFailure,
                            observation: Some(observed.value().getOrThrow())))
                    }
                }
            }
            retainedObservation = match (outcome) { case Result.Err(error) => error.observation; case _ => None }
            if (observer.close().isError()) {
                var observed: ?OperationObservation = match (outcome) { case Result.Err(error) => error.observation; case _ => None }
                if (observed.isNone() && response.isOk()) {
                    observed = hostServicePayloadRetainedObservation(context, prepared, response.value().getOrThrow().value, payloadOwner)
                }
                retainedObservation = observed
                let _ = revoke()
                return Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plugin.channel_outcome_unknown",
                    "service cleanup has not acknowledged release; reconciliation is required", observation: retainedObservation))
            }
            if (outcome.isError()) { let _ = revoke() }
            outcome
        } catch (_: Exception) {
            if (retainedObservation.isNone()) {
                match (payloadResult) {
                    case Some(value) =>
                        try { retainedObservation = hostServicePayloadRetainedObservation(context, prepared, value.value, payloadOwner) } catch (_: Exception) {}
                    case None => ()
                }
            }
            try { let _ = revoke() } catch (_: Exception) {}
            Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plugin.channel_outcome_unknown",
                "service outcome requires reconciliation", observation: retainedObservation))
        } finally {
            match (payloadResult) { case Some(value) => value.releasePayload(); case None => () }
            let acknowledged = try { observer.close().isOk() } catch (_: Exception) { false }
            if (acknowledged) {
                lock.lock(); try { if (invocation.isSome() && hostSameManagedServiceInvocation(invocation.getOrThrow(), observer)) { invocation = None } } finally { lock.unlock() }
            } else { try { let _ = revoke() } catch (_: Exception) {} }
        }
    }

    public func requiredCapabilities(): Array<Capability> { resource.requiredCapabilities() }
    public func networkPolicy(): Result<NetworkPolicy> { resource.networkPolicy() }
    func resourceCancellation(): CancellationToken { resource.cancellation() }
    func maintenancePlan(context: ToolInvocationContext, prepared: PreparedToolInvocation, action: HostServiceAction): Result<AgentValue> {
        lock.lock()
        let valid = try { !closing && endpoint.isSome() && endpoint.getOrThrow().maintenanceThread.value == context.sessionId.value }
            finally { lock.unlock() }
        if (!valid) { return hostLifecycleLeaseError("plugin.lifecycle_maintenance_scope_invalid") }
        resource.maintenancePlan(context, prepared, action)
    }
    public func refresh(vnext: HostServiceToolControl, context: ToolInvocationContext, approval: ApprovalDecision, budget: ExecutionBudget): Result<ToolInvocationResult> {
        refreshController.refresh(vnext, this, context, approval, budget)
    }
    func executeStartup(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<AgentValue> {
        let plan = match (maintenancePlan(context, prepared, HostServiceAction.Start)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let window = plan.field("grant").getOrThrow().field("startup").getOrThrow()
        performMaintenance(context, prepared, HostServiceAction.Start, hostLifecycleInt(window, "timeout_ms", 60000))
    }

    func refreshMaintenanceThread(): Result<SessionId> {
        lock.lock()
        try {
            if (closing || endpoint.isNone()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale") }
            // The endpoint pins this host-owned Thread. Reuse its idle Runtime
            // for a new actual Refresh Run; never widen endpoint Thread access.
            Result.Ok(SessionId(endpoint.getOrThrow().maintenanceThread.value))
        } finally { lock.unlock() }
    }

    func beginRefresh(context: ToolInvocationContext, maintenance: SessionId): Result<AgentValue> {
        match (checkContext(context)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (maintenance.value == grant.endpointTargetThread().value) { return hostLifecycleLeaseError("plugin.lifecycle_maintenance_thread_required") }
        lock.lock()
        let (selectedEndpoint, selectedPublication) = try {
            if (closing || refreshing || pendingManagedJob.isSome() || preparations != 0 || invocationOpening || invocation.isSome() || publication.isNone() ||
                endpoint.isNone() || endpoint.getOrThrow().maintenanceThread.value != maintenance.value || publication.getOrThrow().revision >= 2147483646) {
                return hostLifecycleLeaseError("plugin.lifecycle_refresh_busy")
            }
            refreshing = true; refreshError = ""; (endpoint.getOrThrow(), publication.getOrThrow())
        } finally { lock.unlock() }
        let plan = resource.refreshPlan(selectedEndpoint, selectedPublication.revision, selectedPublication.directoryDigest)
        if (plan.isError()) { finishRefresh() }
        plan
    }

    func finishRefresh(): Unit { lock.lock(); try { refreshing = false } finally { lock.unlock() } }
    func noteRefreshFailure(): Unit {
        lock.lock(); try { refreshError = "plugin.lifecycle_refresh_not_published" } finally { lock.unlock() }
    }

    func validateRefreshCandidate(plan: AgentValue): Result<AgentValue> {
        if (!active()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale") }
        lock.lock()
        let (selectedEndpoint, selectedPublication) = try {
            if (closing || !refreshing || publication.isNone() || endpoint.isNone()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale") }
            (endpoint.getOrThrow(), publication.getOrThrow())
        } finally { lock.unlock() }
        match (resource.validateRefresh(plan, selectedEndpoint, selectedPublication.revision, selectedPublication.directoryDigest)) {
            case Result.Err(error) => Result.Err(error)
            case Result.Ok(_) => Result.Ok(parseUnifiedJson(stringifyUnifiedJson(plan), maxBytes: 131072))
        }
    }

    func executeRefresh(context: ToolInvocationContext, prepared: PreparedToolInvocation, plan: AgentValue): Result<AgentValue> {
        match (validateRefreshCandidate(plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let directory = match (performMaintenance(context, prepared, HostServiceAction.Refresh,
            hostLifecycleInt(plan.field("window").getOrThrow(), "timeout_ms", 60000))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        match (validateRefreshCandidate(plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        resource.refreshResult(plan, directory)
    }
    private func performMaintenance(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        action: HostServiceAction, timeoutMillis: Int64): Result<AgentValue> {
        match (maintenancePlan(context, prepared, action)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock()
        let selectedEndpoint = try {
            if (closing || (action == HostServiceAction.Refresh && !refreshing) || invocationOpening || invocation.isSome()) {
                return hostLifecycleLeaseError("plugin.lifecycle_maintenance_stale")
            }
            invocationOpening = true; endpoint.getOrThrow()
        } finally { lock.unlock() }
        let opened = try { transport.beginMaintenance(this, selectedEndpoint, context, prepared, action) }
            catch (_: Exception) {
                lock.lock(); try { invocationOpening = false } finally { lock.unlock() }
                let _ = revoke(); return hostManagedChannelUnknown()
            }
        let observer = match (opened) {
            case Result.Err(error) =>
                lock.lock(); try { invocationOpening = false } finally { lock.unlock() }
                let _ = revoke(); return Result.Err(error)
            case Result.Ok(value) => value
        }
        lock.lock(); let stopped = try { invocation = Some(observer); invocationOpening = false; closing } finally { lock.unlock() }
        var payloadResult: ?HostJavaScriptPluginInvocationResult = None
        try {
            if (stopped) { return hostLifecycleLeaseError("plugin.lifecycle_maintenance_stale") }
            let phase = if (action == HostServiceAction.Start) { HostManagedServicePhase.Start } else { HostManagedServicePhase.Refresh }
            let response = host.invokeService(selectedEndpoint,
                stringifyUnifiedJson(transport.preparationArguments(phase, "", objectValue([]))),
                JavaScriptHostInvocationIdentity(threadId: context.sessionId.value, runId: context.runId.value,
                    epoch: context.epoch, operationId: prepared.operationId.value, callId: prepared.call.callId, kind: "service"),
                context, timeoutMillis: timeoutMillis, observer: Some(observer))
            match (response) { case Result.Ok(value) => payloadResult = Some(value); case _ => () }
            let current = maintenancePlan(context, prepared, action)
            let delivered = if (response.isOk() && current.isError()) { Result<HostJavaScriptPluginInvocationResult>.Err(current.error().getOrThrow()) } else { response }
            let outcome = match (observer.finish(delivered)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            if (observer.close().isError()) { let _ = revoke(); return hostManagedChannelUnknown() }
            if (outcome.isError) { return hostLifecycleLeaseError("plugin.lifecycle_maintenance_rejected") }
            Result.Ok(outcome.output)
        } catch (_: Exception) { hostManagedChannelUnknown() }
        finally {
            match (payloadResult) { case Some(value) => value.releasePayload(); case None => () }
            let acknowledged = try { observer.close().isOk() } catch (_: Exception) { false }
            if (acknowledged) { lock.lock(); invocation = None; lock.unlock() } else { let _ = revoke() }
        }
    }

    func commitRefresh(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        plan: AgentValue, output: AgentValue): Result<Unit> {
        match (validateRefreshCandidate(plan)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        lock.lock(); let (selectedEndpoint, owned) = try { (endpoint.getOrThrow(), catalogOwner.getOrThrow()) } finally { lock.unlock() }
        let directory = match (resource.commitRefresh(context, prepared, plan, output)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        let text = stringifyUnifiedJson(hostCheckedManagedRefreshDirectory(directory, limits: protocolLimits()))
        let expected = hostLifecycleInt(plan, "expected_revision", 2147483646)
        let instance = modelPolicySha256Text(selectedEndpoint.endpointIdentity + ":" + resource.resourceIdentity())
        let binding = ToolContributionBinding(hostLifecycleText(grant.endpointBinding(), "package_digest"),
            hostLifecycleText(grant.endpointBinding(), "configuration_digest"), instance, expected + 1)
        let published = match (catalog.replaceOwnedBatch(owned, expected, binding, registrations(text, expected + 1))) {
            case Result.Err(_) => return hostLifecycleLeaseError("plugin.lifecycle_refresh_publication_failed"); case Result.Ok(value) => value
        }
        lock.lock(); let stopping = try { publication = Some(published); directoryText = Some(text); closing } finally { lock.unlock() }
        if (stopping || !active() || grant.stillCurrent().isError()) { let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_refresh_publication_failed") }
        Result.Ok(())
    }

    private func closeResourceNormally():Result<Unit>{
        match(resource as HostManagedChannelResource){case Some(value)=>return value.stopFrozen();case None=>()}
        match(resource as HostManagedOwnedChannelResource){case Some(value)=>value.stopFrozen();case None=>resource.revoke()}
    }
    func stopFrozen():Result<Unit>{
        lock.lock();let stopping=try{closing || released}finally{lock.unlock()}
        if(!stopping){match(grant.stillCurrent()){case Result.Err(error)=>let _=revoke();return Result.Err(error);case Result.Ok(_)=>()}}
        lock.lock()
        let (first,selectedOwner,selectedEndpoint,leaseObserver,endpointObserver,busy)=try{
            if(released){return Result.Ok(())}
            // Active invocations keep their immediate cancellation path.
            let busy=invocationOpening || invocation.isSome() || refreshing || preparations>0
            let first=!closing && !busy
            let leases=if(busy){None<CancellationRegistration>}else{leaseRegistration}
            let endpoints=if(busy){None<process.CancellationRegistration>}else{endpointRegistration}
            if(!busy){closing=true;if(first){normalShutdown=true};leaseRegistration=None;endpointRegistration=None}
            (first,catalogOwner,endpoint,leases,endpoints,busy)
        }finally{lock.unlock()}
        if(busy){return revoke()}
        match(leaseObserver){case Some(value)=>value.dispose();case None=>()}
        match(endpointObserver){case Some(value)=>value.dispose();case None=>()}
        if(first){
            try{match(selectedOwner){case Some(value)=>let _=catalog.revokeOwned(value);case None=>()}}catch(_:Exception){}
            try{match(selectedEndpoint){case Some(value)=>value.revoke();case None=>()}}catch(_:Exception){}
            try{let _=closeResourceNormally()}catch(_:Exception){let _=resource.revoke()}
        }
        startCleanup()
        if(resourcesReleased()){Result.Ok(())}else{hostLifecycleLeaseError("plugin.lifecycle_manager_cleanup_pending")}
    }
    public func revoke(): Result<Unit> {
        lock.lock()
        let (first, selectedOwner, selectedEndpoint, selectedInvocation) = try {
            if (released) { return Result.Ok(()) }; let previous = closing; closing = true;normalShutdown=false
            (!previous, catalogOwner, endpoint, invocation)
        }
            finally { lock.unlock() }
        if (first) {
            try { match (selectedInvocation) { case Some(value) => let _ = value.close(); case None => () } } catch (_: Exception) {}
            try { match (selectedOwner) { case Some(value) => let _ = catalog.revokeOwned(value); case None => () } } catch (_: Exception) {}
            try { match (selectedEndpoint) { case Some(value) => value.revoke(); case None => () } } catch (_: Exception) {}
            try { let _ = resource.revoke() } catch (_: Exception) {}
        }
        // Safety revocation overrides a normal grace even after authority was
        // already withdrawn; it must not wait for that grace to elapse.
        if(!first){try{let _=resource.revoke()}catch(_:Exception){}}
        startCleanup()
        if (resourcesReleased()) { Result.Ok(()) } else { hostLifecycleLeaseError("plugin.lifecycle_manager_cleanup_pending") }
    }
    private func startCleanup(): Unit {
        lock.lock()
        try {
            if (cleanupRunning || released) { return }
            cleanupRunning = true
            cleanup = Some(spawn {
                while (true) {
                    lock.lock()
                    let (selectedEndpoint, selectedInvocation, finished) = try { (endpoint, invocation, startupFinished && !invocationOpening) }
                        finally { lock.unlock() }
                    let endpointClosed = try { match (selectedEndpoint) { case Some(value) => value.close(timeoutMillis: 100).isOk(); case None => true } }
                        catch (_: Exception) { false }
                    let invocationClosed = try { match (selectedInvocation) { case Some(value) => value.close().isOk(); case None => true } }
                        catch (_: Exception) { false }
                    lock.lock();let normal=try{normalShutdown}finally{lock.unlock()}
                    let resourceClosed = try { let _ = if(normal){closeResourceNormally()}else{resource.revoke()}; resource.resourcesReleased() && !resource.retainsStartup() }
                        catch (_: Exception) { false }
                    if (finished && endpointClosed && invocationClosed && resourceClosed) {
                        monitorStop.store(true)
                        try{match(monitor){case Some(value)=>value.get();case None=>()}}
                        catch(_:Exception){lock.lock();try{cleanupRunning=false}finally{lock.unlock()};return}
                        match(resource as HostManagedOwnedChannelResource){case Some(actual)=>
                            lock.lock();try{directoryText=None;publication=None;catalogOwner=None;endpoint=None}finally{lock.unlock()}
                            if(actual.acknowledgeMetadataAfterPhysicalCleanup().isError()){continue}
                            case None=>()}
                        lock.lock()
                        let (leaseObserver, endpointObserver) = try {
                            let selected=(leaseRegistration,endpointRegistration)
                            leaseRegistration=None;endpointRegistration=None;selected
                        } finally { lock.unlock() }
                        match (leaseObserver) { case Some(value) => value.dispose(); case None => () }
                        match (endpointObserver) { case Some(value) => value.dispose(); case None => () }
                        lock.lock();try{released=true;cleanupRunning=false;invocation=None}finally{lock.unlock()}
                        return
                    }
                    sleep(Duration.millisecond * 25)
                }
            })
        } catch (_: Exception) { cleanupRunning = false }
        finally { lock.unlock() }
    }
}

class HostPluginManagedToolExecutor <: ToolExecutor {
    private let service: HostPluginManagedService
    private let name: String
    private let revision: Int64
    init(service: HostPluginManagedService, name: String, revision: Int64) {
        this.service = service; this.name = name; this.revision = revision
    }
    public func acquireHandoffLease(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolExecutionHandoffLease> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        service.acquireRegistryHandoff(revision: Some(revision))
    }
    public func execute(context: ToolInvocationContext, prepared: PreparedToolInvocation): Result<ToolResult> {
        service.invoke(name, context, prepared, revision)
    }
    public func cancel(_: RunId): Result<Unit> { service.revoke() }
}

// Interface implementations may be values. Only actual class objects can
// share identity; a value implementation never releases another owner's slot.
func hostSameManagedServiceInvocation(left: HostManagedServiceInvocation,
    right: HostManagedServiceInvocation): Bool {
    match (left as Object) {
        case Some(leftObject) => match (right as Object) {
            case Some(rightObject) => refEq(leftObject, rightObject)
            case None => false
        }
        case None => false
    }
}
