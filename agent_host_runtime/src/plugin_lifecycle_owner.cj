package agent_host_runtime



import agent_domain.*
import agent_extension_runtime.*
import process4cj as process
import agent_ports.*
import agent_runtime.*
import agent_store.*
import tool_runtime.*
import std.collection.*
import std.convert.*
import std.deriving.*
import std.fs.*
import std.sync.*
import std.time.*
import yjson.*
import yjson_support.*

public let HOST_PLUGIN_LIFECYCLE_TOOL = "host.plugin.lifecycle.start"
class HostLifecycleOwnerSeal {}
@Derive[Equatable]
enum HostLifecycleLeaseState { Opening | Pending | Sealed | Activating | Active | Closing | Released }

// Ephemeral resource ownership only. SQLite remains the sole canonical fact
// store, ProcessPort owns native resources, and ToolCatalog owns publications.
public class HostPluginLifecycleOwner {
    private let database: SqliteDatabase
    private let operations: DurableOperationStore
    private let processes: ProcessPort
    private let seal = HostLifecycleOwnerSeal()
    private let payloadArtifacts: ?HostArtifactStore
    private let lock = Mutex()
    private let leases = ArrayList<HostPluginLifecycleLease>()
    private var closed = false
    private let cleanupObserver:?HostManagedChannelCleanupObserver

    public init(database: SqliteDatabase, processes: ProcessPort, operations!: DurableOperationStore, payloadArtifacts!: ?HostArtifactStore = None,
        cleanupObserver!:?HostManagedChannelCleanupObserver=None) {
        this.database = database; this.processes = processes; this.payloadArtifacts = payloadArtifacts
        this.operations = operations
        this.cleanupObserver=cleanupObserver
    }

    func stagePayload(context: ToolInvocationContext, call: ToolCall, binding: AgentValue, id: String, hex: String): Result<AgentValue> {
        match (payloadArtifacts) { case Some(value) => value.stageServicePayload(context, call, binding, id, hex)
            case None => hostLifecycleLeaseError("plugin.payload_store_unavailable") }
    }

    func retainObservation(context: ToolInvocationContext, prepared: PreparedToolInvocation, output: AgentValue): Result<OperationObservation> {
        match (payloadArtifacts) { case Some(value) => value.retainServiceObservation(context, prepared, output)
            case None => hostLifecycleLeaseError("plugin.payload_store_unavailable") }
    }

    public func start(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        grant: HostPluginLifecycleLaunchGrant): Result<HostPluginLifecycleLease> {
        match (hostValidateLifecycleLaunchSource(database, context, prepared, grant)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let request = match (grant.processRequest(prepared.operationId)) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        let entropy = match (hostNewPluginInstanceIdentity()) {
            case Result.Err(error) => return Result.Err(error)
            case Result.Ok(value) => value
        }
        let plan = grant.launchPlan
        let namespace = hostLifecycleText(plan, "namespace")
        let maximum = hostLifecycleInt(plan, "max_instances", 32)
        let lease: HostPluginLifecycleLease
        lock.lock()
        try {
            if (closed) { return hostLifecycleLeaseError("plugin.lifecycle_owner_closed") }
            collectReleasedLocked()
            // Closed identities with an unresolved canonical root remain
            // tombstones, so failed opens cannot be retried under the same op.
            if (leases.size >= 256) { return hostLifecycleLeaseError("plugin.lifecycle_history_pending") }
            var count: Int64 = 0
            var matching: Int64 = 0
            for (item in leases) {
                if (item.operationId.value == prepared.operationId.value) {
                    return hostLifecycleLeaseError("plugin.lifecycle_operation_reused")
                }
                if (!item.resourcesReleased()) {
                    count += 1
                    if (item.namespace == namespace) { matching += 1 }
                    if (item.namespace == namespace && item.instanceIdentity == grant.instanceIdentity &&
                        item.targetThread.value == grant.targetThread.value &&
                        item.permissionDomain == hostLifecycleText(plan, "permission_domain") &&
                        item.serviceId == hostLifecycleText(plan, "service_id")) {
                        return hostLifecycleLeaseError("plugin.lifecycle_instance_busy")
                    }
                }
            }
            if (count >= 32 || matching >= maximum) { return hostLifecycleLeaseError("plugin.lifecycle_capacity") }
            lease = HostPluginLifecycleLease(seal, database, operations, processes, context, prepared, grant,
                "service-lease-" + entropy, payloadArtifacts: payloadArtifacts)
            leases.add(lease)
        } finally { lock.unlock() }
        match (lease.beginWatching()) {
            case Result.Err(error) => lease.openFailed(); return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let opened = try {
            let maximum = hostLifecycleInt(plan, "max_input_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES)
            // Every typed lifecycle launch must honor its explicit
            // lifecycle transport ceiling, including grants below 16 MiB.
            match (processes as HostLifecycleProcessLauncher) {
                case Some(launcher) => launcher.openLifecycleChannel(request, grant, lease.cancellationToken(), maximum)
                case None => if (grant.hasProcessEnvironment() || networkPolicyModeIsHost(request.networkPolicy.mode) ||
                    request.processLimits.maxOutputBytes > HOST_PLUGIN_LIFECYCLE_IO_BYTES) {
                    hostLifecycleLeaseError<ProcessChannel>("plugin.lifecycle_private_launcher_unavailable")
                } else { processes.openChannel(request, lease.cancellationToken(), maximum) }
            }
        }
            catch (_: Exception) { hostLifecycleLeaseError<ProcessChannel>("plugin.lifecycle_open_failed") }
        match (opened) {
            case Result.Err(error) => lease.openFailed(); Result.Err(error)
            case Result.Ok(channel) => match (lease.attach(channel)) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(_) => Result.Ok(lease)
            }
        }
    }

    // The original inventory owns every dynamic managed launch. The actual
    // Derived/ordinary-policy/Store handoff is proved before any raw launch;
    // the configured grant supplies ceilings, never child authorization.
    func startManaged(context: ToolInvocationContext, parent: PreparedToolInvocation,
        childContext: ToolInvocationContext, child: PreparedToolInvocation,
        base: HostPluginLifecycleLaunchGrant, port: OperationRuntimePort,
        current: () -> Result<Unit>, adapter!: ?HostPluginLifecycleLease = None<HostPluginLifecycleLease>,
        ceiling!: ?HostPluginLifecycleLaunchGrant = None<HostPluginLifecycleLaunchGrant>): Result<HostPluginLifecycleLease> {
        match(adapter){case Some(value)=>if(!owns(value)){return hostLifecycleLeaseError("plugin.lifecycle_owner_mismatch")};case None=>()}
        let actual = match (HostManagedProcessGrant.prepare(base, context, parent, childContext, child, port, current, adapter:adapter,ceiling:ceiling)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        var adopted = false
        try {
            let request = match (actual.processRequest(child.operationId)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let entropy = match (hostNewPluginInstanceIdentity()) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            let plan = base.launchPlan
            let namespace = hostLifecycleText(plan, "namespace")
            let maximum = if(actual.hasConfiguredProcessCeiling()){hostLifecycleInt(actual.managedLeasePlan(), "max_instances", 32)}
                else{hostLifecycleInt(plan, "max_instances", 32)}
            let lease: HostPluginLifecycleLease
            lock.lock()
            try {
                if (closed) { return hostLifecycleLeaseError("plugin.lifecycle_owner_closed") }
                collectReleasedLocked()
                if (leases.size >= 256) { return hostLifecycleLeaseError("plugin.lifecycle_history_pending") }
                var count: Int64 = 0; var matching: Int64 = 0
                for (item in leases) {
                    if (item.operationId.value == child.operationId.value) {
                        return hostLifecycleLeaseError("plugin.lifecycle_operation_reused") }
                    if (!item.resourcesReleased()) {
                        count += 1
                        if (item.namespace == namespace) { matching += 1 }
                        if (item.namespace == namespace && item.instanceIdentity == base.instanceIdentity &&
                            item.targetThread.value == base.targetThread.value && item.permissionDomain == hostLifecycleText(plan, "permission_domain") &&
                            item.serviceId == hostLifecycleText(plan, "service_id")) {
                            let sameActualFamily=actual.role=="auxiliary" && adapter.isSome() &&
                                (refEq(item,adapter.getOrThrow()) || item.managedAuxiliaryFor(adapter.getOrThrow()))
                            if(!sameActualFamily){return hostLifecycleLeaseError("plugin.lifecycle_instance_busy")}
                        }
                    }
                }
                if (count >= 32 || matching >= maximum) { return hostLifecycleLeaseError("plugin.lifecycle_capacity") }
                lease = HostPluginLifecycleLease(seal, database, operations, processes, context, child, base,
                    "service-lease-" + entropy, payloadArtifacts: payloadArtifacts, managedGrant: Some(actual))
                leases.add(lease); adopted = true
            } finally { lock.unlock() }
            match (lease.beginWatching()) {
                case Result.Err(error) => lease.openFailed(); return Result.Err(error); case Result.Ok(_) => () }
            let opened: Result<ProcessChannel> = try {
                match (processes as HostLifecycleProcessLauncher) {
                    case Some(launcher) => launcher.openLifecycleChannel(request, actual, lease.cancellationToken(),
                        if(actual.hasConfiguredProcessCeiling()){actual.maximumInputBytes()}
                            else{hostLifecycleInt(plan,"max_input_bytes",HOST_PLUGIN_LIFECYCLE_IO_BYTES)})
                    case None => hostLifecycleLeaseError("plugin.lifecycle_private_launcher_unavailable") }
            } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_open_failed") }
            match (opened) {
                case Result.Err(error) => lease.openFailed(); Result.Err(error)
                case Result.Ok(channel) => match (lease.attach(channel)) {
                    case Result.Err(error) => Result.Err(error); case Result.Ok(_) =>
                        match(cleanupObserver){case Some(observer)=>
                            try{actual.observeCleanupBorrow(observer,lease)}catch(_:Exception){lease.openFailed();return hostLifecycleLeaseError("managed_channel.cleanup_observer_failed")}
                            case None=>()}
                        Result.Ok(lease) } }
        } finally {
            // No raw resource was created before inventory adoption. Once
            // adopted, only that exact lease can refund after physical ACK.
            if (!adopted) { let _ = actual.releaseAfterPhysicalCleanup() }
        }
    }

    // Selection is by actual object references held by the same paid grant,
    // never a startup ID, caller lease ID or reconstructed Source. These
    // helpers query the sole original inventory; they create no new inventory.
    func managedAuxiliaryLease(adapter:HostPluginLifecycleLease,child:PreparedToolInvocation):Result<HostPluginLifecycleLease>{
        lock.lock();try{
            for(item in leases where item.managedAuxiliaryFor(adapter) && item.managedOwnsPrepared(child)){
                return Result.Ok(item)}
            hostLifecycleLeaseError("managed_channel.actual_auxiliary_missing")
        }finally{lock.unlock()}
    }
    func revokeManagedAuxiliaries(adapter:HostPluginLifecycleLease):Result<Unit>{
        lock.lock();let selected=try{
            let values=ArrayList<HostPluginLifecycleLease>()
            for(item in leases where !item.resourcesReleased() && item.managedAuxiliaryFor(adapter)){values.add(item)}
            values.toArray()
        }finally{lock.unlock()}
        var pending=false
        for(item in selected){try{if(revoke(item).isError() || !item.resourcesReleased()){pending=true}}
            catch(_:Exception){pending=true}}
        if(pending){hostLifecycleLeaseError("managed_channel.actual_auxiliary_cleanup_pending")}else{Result.Ok(())}
    }
    func managedAuxiliariesReleased(adapter:HostPluginLifecycleLease):Bool{
        lock.lock();try{
            for(item in leases where item.managedAuxiliaryFor(adapter) && !item.resourcesReleased()){return false}
            true
        }finally{lock.unlock()}
    }

    // Observe the existing canonical Run row. This creates no Source.
    func managedChannelRunLane(context:ToolInvocationContext):Result<String>{
        try{let actual=SqliteRunStore(database).load(context.runId)
            if(actual.threadId.value!=context.sessionId.value || actual.epoch!=context.epoch ||
                actual.executionLaneId.value==""){return hostLifecycleLeaseError("managed_channel.actual_run_changed")}
            Result.Ok(actual.executionLaneId.value)
        }catch(_:Exception){hostLifecycleLeaseError("managed_channel.actual_run_missing")}
    }

    func startupSummary(lease: HostPluginLifecycleLease, data: AgentValue): Result<AgentValue> {
        if (!owns(lease)) { return hostLifecycleLeaseError("plugin.lifecycle_owner_mismatch") }
        lease.sealSummary(data)
    }
    public func activate(lease: HostPluginLifecycleLease): Result<Unit> {
        if (!owns(lease)) { return hostLifecycleLeaseError("plugin.lifecycle_owner_mismatch") }
        lease.activateCommitted()
    }
    public func revoke(lease: HostPluginLifecycleLease): Result<Unit> {
        if (!owns(lease)) { return hostLifecycleLeaseError("plugin.lifecycle_owner_mismatch") }
        lease.revoke()
    }
    // Scalar observation only; never revoke, join, ACK or rebuild a grant.
    func hasOwnerLifetimeDebt180(): Bool {
        lock.lock(); try {
            for (lease in leases) { if (lease.hasOwnerLifetimeDebt180()) { return true } }
            false
        } finally { lock.unlock() }
    }
    public func close(): Result<Unit> {
        let selected: Array<HostPluginLifecycleLease>
        lock.lock()
        try { closed = true; selected = leases.toArray() } finally { lock.unlock() }
        var pending = false
        for (lease in selected) {
            try { if (lease.revoke().isError()) { pending = true } }
            catch (_: Exception) { pending = true }
        }
        if (pending) { hostLifecycleLeaseError("plugin.lifecycle_cleanup_pending") } else { Result.Ok(()) }
    }
    public func retainedCount(): Int64 {
        lock.lock()
        try {
            var count: Int64 = 0
            for (lease in leases where !lease.resourcesReleased()) { count += 1 }
            count
        } finally { lock.unlock() }
    }
    // A failed open can retain native cleanup even when start returned no
    // lease to its caller. This is resource inspection, never admission.
    func retainsLaunch(launchDigest: String): Bool {
        lock.lock()
        try {
            for (lease in leases where lease.launchDigest == launchDigest && !lease.resourcesReleased()) { return true }
            false
        } finally { lock.unlock() }
    }
    private func owns(lease: HostPluginLifecycleLease): Bool {
        if (!refEq(lease.ownerSeal, seal)) { return false }
        lock.lock()
        try { for (item in leases where refEq(item, lease)) { return true }; false }
        finally { lock.unlock() }
    }
    private func collectReleasedLocked(): Unit {
        var index: Int64 = 0
        while (index < leases.size) {
            let lease = leases[index]
            var terminal = false
            if (lease.resourcesReleased()) {
                try {
                    let rows = database.query("SELECT state FROM operations WHERE id=? AND run_id=?", [
                        SqlParameter.Text(lease.operationId.value), SqlParameter.Text(lease.runId.value)])
                    terminal = rows.size == 1 && ["committed", "failed", "rejected", "cancelled", "timed_out", "recovery_required"]
                        .contains(rows[0].required(0))
                } catch (_: Exception) { terminal = false }
            }
            if (terminal) { leases.remove(at: index) } else { index += 1 }
        }
    }
}

// No public constructor or JSON decoder. The random lookup id is descriptive;
// authority remains the host-held object and its exact canonical source.
public class HostPluginLifecycleLease {
    public let leaseId: String
    public let launchDigest: String
    public let operationId: OperationId
    public let runId: RunId
    public let namespace: String
    public let instanceIdentity: String
    public let targetThread: ThreadId
    public let permissionDomain: String
    public let serviceId: String
    let ownerSeal: HostLifecycleOwnerSeal
    private let payloadArtifacts: ?HostArtifactStore
    private let database: SqliteDatabase
    private let processes: ProcessPort
    private var heldContext: ?ToolInvocationContext
    private var heldPrepared: ?PreparedToolInvocation
    private var heldGrant: ?HostPluginLifecycleLaunchGrant
    private prop context: ToolInvocationContext { get() { heldContext.getOrThrow() } }
    private prop prepared: PreparedToolInvocation { get() { heldPrepared.getOrThrow() } }
    private prop grant: HostPluginLifecycleLaunchGrant { get() { heldGrant.getOrThrow() } }
    private let callerCancellation: CancellationToken
    private let managedGrant: ?HostManagedProcessGrant
    private let source: CancellationSource
    // One bounded parsing memo per actual lease. Every use still reads all
    // canonical startup facts in the same current Store transaction.
    private let invocationStore: DurableOperationStore
    private let revocation = CancellationSource()
    private let expiresAt: Int64
    private let startupUntil: Int64
    private let maxStartupInput: Int64
    private let maxStartupOutput: Int64
    private let maxStartupWrites: Int64
    private let maxTotalInput: Int64
    private let maxTotalOutput: Int64
    private let lock = Mutex()
    private let writer = Mutex()
    private let stdout = HostProcessChannelQueue()
    private let stderr = HostProcessChannelQueue()
    private var state = HostLifecycleLeaseState.Opening
    private var opening = true
    private var channel: ?ProcessChannel = None
    private var startupOutputWindow: ?ProcessChannelOutputWindow = None
    private var refreshOutputWindow: ?HostLifecycleRefreshWindow = None
    private var startupCancellation: ?CancellationRegistration = None
    private var summaryText: ?String = None
    private var inputBytes: Int64 = 0
    private var outputBytes: Int64 = 0
    private var writes: Int64 = 0
    private let attemptedWrites = HashSet<String>()
    private let attemptedRefreshes = HashSet<String>()
    private let ioScopes = ArrayList<HostLifecycleIoScope>()
    private var cleanupRunning = false
    private let frozenShutdownGrace:Int64
    private var gracefulCleanup:?Int64=None<Int64>
    private var managedCloseAcknowledged=false
    private var managedPhysicalCustodyObserved=false
    private var managedPhysicalCloseHadError=false
    private var managedPhysicalCloseWasPending=false
    private var managedPhysicalCloseError:?AgentError=None<AgentError>
    // Default None. An impossible successful foreign-scope diagnostic must
    // enter this already inventoried actual lease's cleanup custody. Its
    // original peer payment remains borrowed until the new owner truly ACKs.
    private var managedScopeProbeUsed=false
    private var unpublishedManagedScopeDebt:?HostManagedProcessGrant=None<HostManagedProcessGrant>
    private var unpublishedManagedScopePeer:?HostManagedProcessGrant=None<HostManagedProcessGrant>
    private let startupCancelled = AtomicBool(false)
    private let stdoutDone = AtomicBool(true)
    private let stderrDone = AtomicBool(true)
    private let monitorStop=AtomicBool(false)
    private var monitor: ?Future<Unit> = None
    private var stdoutPump: ?Future<Unit> = None
    private var stderrPump: ?Future<Unit> = None
    private var cleanup: ?Future<Unit> = None

    init(ownerSeal: HostLifecycleOwnerSeal, database: SqliteDatabase, operations: DurableOperationStore, processes: ProcessPort,
        context: ToolInvocationContext, prepared: PreparedToolInvocation,
        grant: HostPluginLifecycleLaunchGrant, leaseId: String, payloadArtifacts!: ?HostArtifactStore = None,
        managedGrant!: ?HostManagedProcessGrant = None) {
        this.ownerSeal = ownerSeal; this.database = database; this.processes = processes; this.payloadArtifacts = payloadArtifacts
        this.heldContext = Some(context); this.heldPrepared = Some(prepared); this.heldGrant = Some(grant); this.leaseId = leaseId
        this.callerCancellation = context.cancellation
        this.managedGrant = managedGrant
        this.invocationStore = operations
        this.launchDigest = grant.digest; this.operationId = prepared.operationId; this.runId = context.runId
        this.instanceIdentity = grant.instanceIdentity
        this.targetThread = grant.targetThread
        let plan = grant.launchPlan
        this.permissionDomain = hostLifecycleText(plan, "permission_domain")
        this.serviceId = hostLifecycleText(plan, "service_id")
        this.namespace = hostLifecycleText(plan, "namespace")
        let now = agentUtcMillis()
        let limitsPlan=match(managedGrant){case Some(actual)=>if(actual.hasConfiguredProcessCeiling()){actual.managedLeasePlan()}else{plan};case None=>plan}
        this.expiresAt = now + hostLifecycleInt(limitsPlan, "lifetime_ms", 3600000)
        let startup = limitsPlan.field("startup").getOrThrow()
        this.startupUntil = now + hostLifecycleInt(startup, "timeout_ms", 60000)
        this.maxStartupInput = hostLifecycleInt(startup, "max_input_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES)
        this.maxStartupOutput = hostLifecycleInt(startup, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES)
        this.maxStartupWrites = hostLifecycleInt(startup, "max_writes", 256)
        this.maxTotalInput = hostLifecycleInt(limitsPlan, "max_input_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES)
        this.maxTotalOutput = hostLifecycleInt(limitsPlan, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES)
        let frozenPolicy=match(managedGrant){case Some(actual)=>
            actual.child.operationPlan.canonicalArguments.field("binding").getOrThrow().field("lifecycle_policy").getOrThrow()
            case None=>prepared.operationPlan.canonicalArguments.field("lifecycle_policy").getOrThrow()}
        hostLifecycleLeaseAssert(canonicalAgentValue(frozenPolicy)==canonicalAgentValue(plan.field("lifecycle_policy").getOrThrow()))
        this.frozenShutdownGrace=processShutdownPlanGrace(prepared.operationPlan).value().getOrThrow()
        this.source = CancellationSource(deadlineMillis: expiresAt)
    }
    public func cancellationToken(): CancellationToken { source.token }
    // Registration is linearized by CancellationState. A callback registered
    // after revocation runs immediately, outside every lease/owner lock.
    public func observeRevocation(callback: () -> Unit): CancellationRegistration {
        revocation.token.onCancel({ _ => callback() })
    }
    func hasOwnerLifetimeDebt180(): Bool {
        lock.lock(); try {
            if (state != HostLifecycleLeaseState.Released || opening || cleanupRunning ||
                channel.isSome() || !ioScopes.isEmpty() || startupCancellation.isSome() ||
                unpublishedManagedScopeDebt.isSome() || unpublishedManagedScopePeer.isSome() ||
                managedPhysicalCloseError.isSome()) { return true }
            try {
                match (monitor) { case Some(value) => if (value.tryGet().isNone()) { return true }; case None => () }
                match (stdoutPump) { case Some(value) => if (value.tryGet().isNone()) { return true }; case None => () }
                match (stderrPump) { case Some(value) => if (value.tryGet().isNone()) { return true }; case None => () }
                match (cleanup) { case Some(value) => if (value.tryGet().isNone()) { return true }; case None => () }
                false
            } catch (_: Exception) { true }
        } finally { lock.unlock() }
    }
    public func resourcesReleased(): Bool {
        lock.lock();let (released,returned)=try{(state==HostLifecycleLeaseState.Released,cleanup)}finally{lock.unlock()}
        if(!released){return false}
        // Join the cleanup Future as well as its terminal marker.
        try{match(returned){case Some(value)=>value.get();case None=>()};true}catch(_:Exception){false}
    }
    public func isActive(): Bool {
        lock.lock(); try { state == HostLifecycleLeaseState.Active && agentUtcMillis() < expiresAt }
        finally { lock.unlock() }
    }
    func beginWatching(): Result<Unit> {
        try {
            let registration = callerCancellation.onCancel({ _ => cancelStartup() })
            lock.lock(); try { startupCancellation = Some(registration) } finally { lock.unlock() }
            monitor = Some(spawn {
                var nextConfigurationCheck = agentUtcMillis()
                while (!monitorStop.load()) {
                    var stopping = false
                    var graceful = false
                    var pending = false
                    var exited = false
                    lock.lock()
                    try {
                        stopping = state == HostLifecycleLeaseState.Closing
                        graceful = gracefulCleanup.isSome()
                        pending = state == HostLifecycleLeaseState.Opening || state == HostLifecycleLeaseState.Pending ||
                            state == HostLifecycleLeaseState.Sealed || state == HostLifecycleLeaseState.Activating
                        exited = !opening && channel.isSome() && stdoutDone.load() && stderrDone.load()
                    } finally { lock.unlock() }
                    lock.lock(); let scopes = try { ioScopes.toArray() } finally { lock.unlock() }
                    for (scope in scopes) { scope.checkDeadline() }
                    if (stopping) {
                        if(graceful && (source.token.isCancelled() || agentUtcMillis()>=expiresAt)){let _=revoke()}
                        else if(graceful && agentUtcMillis()>=nextConfigurationCheck){
                            let current=match(managedGrant){case Some(actual)=>actual.stillCurrentForCleanup();case None=>grant.stillCurrent()}
                            if(current.isError()){let _=revoke()}
                            nextConfigurationCheck=agentUtcMillis()+250
                        }
                        tryCleanup()
                    }
                    else if (exited || source.token.isCancelled() || agentUtcMillis() >= expiresAt ||
                        (pending && (callerCancellation.isCancelled() || agentUtcMillis() >= startupUntil))) { let _ = revoke() }
                    else if (agentUtcMillis() >= nextConfigurationCheck) {
                        let current = match (managedGrant) {
                            case Some(actual) => actual.stillCurrent(); case None => grant.stillCurrent() }
                        if (current.isError()) { let _ = revoke() }
                        // Full configuration and bounded executable hashing is
                        // separate from the faster cancellation/lifetime poll.
                        nextConfigurationCheck = agentUtcMillis() + 250
                    }
                    sleep(Duration.millisecond * 25)
                }
            })
            Result.Ok(())
        } catch (_: Exception) {
            let _ = revoke()
            hostLifecycleLeaseError("plugin.lifecycle_monitor_unavailable")
        }
    }
    public func attach(value: ProcessChannel): Result<Unit> {
        // Retain the actual owner before asking any adapter for its phase
        // primitive. Unsupported/custom adapters fail closed without losing
        // cleanup ownership. Actual LocalProcessPort installs this ticket
        // before native pumps; a wrapper may restrict existing ingress only.
        // The monitor must continue to regard this as opening until both
        // output pump ownership flags have been established. Holding the raw
        // channel alone is not evidence that both streams reached EOF.
        lock.lock(); try { channel = Some(value) } finally { lock.unlock() }
        let window: Result<ProcessChannelOutputWindow> = try {
            match (value.currentOutputWindow()) {
                case Result.Err(error) => Result.Err(error)
                case Result.Ok(Some(ticket)) => if (ticket.baselineBytes == 0 &&
                    ticket.maximumBytes > 0 && ticket.maximumBytes <= maxStartupOutput) {
                    Result.Ok(ticket)
                } else { hostLifecycleLeaseError<ProcessChannelOutputWindow>("plugin.lifecycle_startup_window_invalid") }
                case Result.Ok(None) => value.beginOutputWindow(maxStartupOutput, true)
            }
        } catch (_: Exception) { hostLifecycleLeaseError<ProcessChannelOutputWindow>("plugin.lifecycle_startup_window_unverified") }
        let ticket = match (window) {
            case Result.Err(error) => openFailed(); return Result.Err(error)
            case Result.Ok(value) => value
        }
        lock.lock()
        try {
            if (state == HostLifecycleLeaseState.Opening && !startupCancelled.load() && agentUtcMillis() < expiresAt) {
                startupOutputWindow = Some(ticket)
                state = HostLifecycleLeaseState.Pending
                stdoutDone.store(false); stderrDone.store(false)
            }
            // On a cancellation race the retained owner is already Closing;
            // clearing opening here lets the existing cleanup path run.
            opening = false
        } finally { lock.unlock() }
        if (!startupOpen()) {
            stdoutDone.store(true); stderrDone.store(true)
            let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_start_cancelled")
        }
        try {
            stdoutPump = Some(spawn { pump(value, ProcessChannelStream.Stdout, stdout, stdoutDone) })
            stderrPump = Some(spawn { pump(value, ProcessChannelStream.Stderr, stderr, stderrDone) })
            Result.Ok(())
        } catch (_: Exception) {
            if (stdoutPump.isNone()) { stdoutDone.store(true) }
            if (stderrPump.isNone()) { stderrDone.store(true) }
            let _ = revoke()
            hostLifecycleLeaseError("plugin.lifecycle_reader_unavailable")
        }
    }
    func openFailed(): Unit {
        lock.lock(); try { opening = false } finally { lock.unlock() }
        let _ = revoke()
    }
    private func startupOpen(): Bool {
        let cancelled = context.cancellation.isCancelled() || source.token.isCancelled()
        lock.lock()
        try { state == HostLifecycleLeaseState.Pending && !cancelled && !startupCancelled.load() &&
            agentUtcMillis() < startupUntil }
        finally { lock.unlock() }
    }
    private func checkStartup(): Result<Unit> {
        if (managedGrant.isSome()) { return hostLifecycleLeaseError("managed_channel.typed_entry_required") }
        if (!startupOpen()) { return hostLifecycleLeaseError("plugin.lifecycle_startup_closed") }
        hostValidateLifecycleLaunchSource(database, context, prepared, grant)
    }
    public func startupWrite(bytes: Array<Byte>): Result<Unit> {
        if (bytes.isEmpty() || bytes.size > 65536) { return hostLifecycleLeaseError("plugin.lifecycle_write_bounds") }
        let frozen = bytes.clone()
        writer.lock()
        try {
            match (checkStartup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
            let selected: ProcessChannel
            lock.lock()
            try {
                if (state != HostLifecycleLeaseState.Pending || writes >= maxStartupWrites ||
                    frozen.size > maxStartupInput - inputBytes || channel.isNone()) {
                    return hostLifecycleLeaseError("plugin.lifecycle_startup_input_limit")
                }
                inputBytes += frozen.size; writes += 1; selected = channel.getOrThrow()
            } finally { lock.unlock() }
            let result = try { selected.write(frozen) }
                catch (_: Exception) { hostLifecycleLeaseError<Unit>("plugin.lifecycle_write_unknown") }
            if (result.isError() || !startupOpen()) {
                let _ = revoke()
                return hostLifecycleLeaseError("plugin.lifecycle_write_unknown")
            }
            Result.Ok(())
        } finally { writer.unlock() }
    }
    public func startupRead(stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        if (maxBytes < 1 || maxBytes > 65536 || waitMillis < 0 || waitMillis > 1000) {
            return hostLifecycleLeaseError("plugin.lifecycle_read_bounds")
        }
        match (checkStartup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let queue = match (stream) { case ProcessChannelStream.Stdout => stdout; case ProcessChannelStream.Stderr => stderr }
        let deadline = MonoTime.now() + Duration.millisecond * waitMillis
        while (startupOpen()) {
            match (queue.poll(maxBytes)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) => if (!value.bytes.isEmpty() || value.eof || MonoTime.now() >= deadline) {
                    return Result.Ok(value)
                }
            }
            sleep(Duration.millisecond)
        }
        hostLifecycleLeaseError("plugin.lifecycle_startup_closed")
    }
    // expectedBinding is obtained from the host manager's actual publication,
    // never from a plugin frame. This lease verifies every field it owns; the
    // pinned broker additionally compares endpoint and catalog identity.
    private func checkInvocation(context: ToolInvocationContext, binding: AgentValue,
        source: ?OperationRootSource): Result<Unit> {
        let delegated = hostManagedJobSource(source).isSome()
        if (delegated) {
            match (hostValidateManagedJobResource(context, source, targetThread, permissionDomain, binding: Some(binding))) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        }
        if (validateChannelServiceBinding(binding).isError()) { return hostLifecycleLeaseError("plugin.lifecycle_binding_invalid") }
        if (context.trustedControl || !isActive() || (!delegated && context.sessionId.value != targetThread.value) ||
            hostPluginInvocationAuthorityScope(context) != permissionDomain || context.cancellation.isCancelled() ||
            (context.budget.deadlineMillis > 0 && agentUtcMillis() >= context.budget.deadlineMillis)) {
            return hostLifecycleLeaseError("plugin.lifecycle_invocation_stale")
        }
        let plan = grant.launchPlan
        if (hostLifecycleText(binding, "plugin") != namespace || hostLifecycleText(binding, "lease_id") != leaseId ||
            hostLifecycleText(binding, "launch_digest") != launchDigest ||
            hostLifecycleText(binding, "startup_operation_id") != operationId.value ||
            hostLifecycleText(binding, "instance_identity") != instanceIdentity ||
            hostLifecycleText(binding, "target_thread_id") != targetThread.value ||
            hostLifecycleText(binding, "permission_domain") != permissionDomain ||
            context.workspaceRoot != hostLifecycleText(plan, "workspace_root")) {
            return hostLifecycleLeaseError("plugin.lifecycle_binding_mismatch")
        }
        for (key in ["package_digest", "configuration_digest", "workspace_root", "workspace_mode"]) {
            if (hostLifecycleText(binding, key) != hostLifecycleText(plan, key)) {
                return hostLifecycleLeaseError("plugin.lifecycle_binding_mismatch")
            }
        }
        if (canonicalAgentValue(binding.field("network").getOrThrow()) != canonicalAgentValue(plan.field("network").getOrThrow())) {
            return hostLifecycleLeaseError("plugin.lifecycle_binding_mismatch")
        }
        let required = channelServiceRequiredCapabilities(binding).value().getOrThrow()
        for (capability in required where !context.capabilities.allows(capability.kind, resource: capability.resource)) {
            return hostLifecycleLeaseError("plugin.lifecycle_capability_denied")
        }
        let resources = hostLifecycleResources(plan.field("resources").getOrThrow())
        let ceiling = context.budget.processLimits
        if (!hostLifecycleResourceFits(resources.maxOutputBytes, ceiling.maxOutputBytes) ||
            !hostLifecycleResourceFits(resources.addressSpaceBytes, ceiling.addressSpaceBytes) ||
            !hostLifecycleResourceFits(resources.fileSizeBytes, ceiling.fileSizeBytes) ||
            !hostLifecycleResourceFits(resources.openFiles, ceiling.openFiles) ||
            !hostLifecycleResourceFits(resources.processes, ceiling.processes) ||
            !hostLifecycleResourceFits(resources.cpuSeconds, ceiling.cpuSeconds)) {
            return hostLifecycleLeaseError("plugin.lifecycle_resource_ceiling")
        }
        match (grant.stillCurrent()) {
            case Result.Err(error) => let _ = revoke(); Result.Err(error)
            case Result.Ok(_) => Result.Ok(())
        }
    }

    private func invocationScope(context: ToolInvocationContext, additionalDeadline!: Int64 = 0): Result<HostLifecycleIoScope> {
        var deadline = if (additionalDeadline > 0) { min(expiresAt, additionalDeadline) } else { expiresAt }
        for (value in [context.cancellation.deadlineMillis, context.budget.deadlineMillis] where value > 0) {
            deadline = min(deadline, value)
        }
        let scope = HostLifecycleIoScope(deadline, { => let _ = revoke() })
        lock.lock()
        try {
            if (state != HostLifecycleLeaseState.Active || ioScopes.size >= 32) {
                return hostLifecycleLeaseError("plugin.lifecycle_io_gate_unavailable")
            }
            ioScopes.add(scope)
        } finally { lock.unlock() }
        try { scope.arm(context.cancellation); Result.Ok(scope) }
        catch (_: Exception) {
            let _ = finishInvocationScope(scope)
            hostLifecycleLeaseError("plugin.lifecycle_io_gate_unavailable")
        }
    }
    private func finishInvocationScope(scope: HostLifecycleIoScope): Bool {
        let cancelled = scope.finish()
        lock.lock()
        try { for (index in 0..ioScopes.size where refEq(ioScopes[index], scope)) { ioScopes.remove(at: index); break } }
        finally { lock.unlock() }
        tryCleanup()
        cancelled
    }

    func openArtifactWriter(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        binding: AgentValue): Result<HostServiceArtifactWriter> {
        match (verifyInvocationRoot(context, prepared, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (payloadArtifacts) { case Some(value) => value.openServiceArtifactWriter()
            case None => hostLifecycleLeaseError("artifact.observation_store_required") }
    }
    func artifactObservationMaximum(): Int64 {
        min(16777216, hostLifecycleInt(grant.launchPlan, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_TRANSPORT_OUTPUT_BYTES))
    }
    func retainArtifact(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        binding: AgentValue, stream: String, writer: HostServiceArtifactWriter): Result<AgentValue> {
        match (verifyInvocationRoot(context, prepared, binding)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (payloadArtifacts) {
            case Some(value) => value.retainServiceArtifact(context, prepared, binding, stream, writer)
            case None => hostLifecycleLeaseError("artifact.observation_store_required") }
    }

    func verifyInvocationRoot(context: ToolInvocationContext, root: PreparedToolInvocation,
        binding: AgentValue): Result<Unit> {
        let diagnosticStarted = hostChannelIoDiagnosticStart()
        try {

        if (managedGrant.isSome()) { return hostLifecycleLeaseError("managed_channel.typed_entry_required") }
        if (root.source.kind == PreparedInvocationSourceKind.Derived || root.source.operationRoot.isNone() ||
            root.source.parentOperationId.isSome() || root.source.requestKey != "" ||
            root.source.runId.value != context.runId.value || root.source.sessionId.value != context.sessionId.value ||
            root.source.epoch != context.epoch || root.authorization == PreparedAuthorization.ApprovalRequired) {
            return hostLifecycleLeaseError("plugin.lifecycle_root_required")
        }
        match (checkInvocation(context, binding, root.source.operationRoot)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        invocationStore.verifyChannelInvocationRoot(root.operationId, context.runId,
            ThreadId(context.sessionId.value), context.epoch, root.source.operationRoot.getOrThrow(), root.operationPlan, binding)
    
        } finally { hostChannelIoDiagnosticRecord(1, diagnosticStarted) }
    }

    func invocationRead(actualContext: ToolInvocationContext, rootPrepared: PreparedToolInvocation,
        expectedBinding: AgentValue, stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64
    ): Result<ProcessChannelRead> {
        let diagnosticStarted = hostChannelIoDiagnosticStart()
        try {

        if (maxBytes < 1 || maxBytes > 65536 || waitMillis < 0 || waitMillis > 1000) {
            return hostLifecycleLeaseError("plugin.lifecycle_read_bounds")
        }
        let binding = try { parseUnifiedJson(stringifyUnifiedJson(expectedBinding), maxBytes: 196608) }
            catch (_: Exception) { return hostLifecycleLeaseError("plugin.lifecycle_binding_invalid") }
        match (verifyInvocationRoot(actualContext, rootPrepared, binding)) {
            case Result.Err(error) => hostManagedJobIoDiagnostic(rootPrepared.source.operationRoot, "read-root-before", error); return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let scope = match (invocationScope(actualContext)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        try {
            let queue = match (stream) { case ProcessChannelStream.Stdout => stdout; case ProcessChannelStream.Stderr => stderr }
            let deadline = MonoTime.now() + Duration.millisecond * waitMillis
            while (!scope.isCancelled()) {
                match (queue.poll(maxBytes)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(value) => if (!value.bytes.isEmpty() || value.eof || MonoTime.now() >= deadline) {
                        // Dequeued bytes are never put back after a scope loss.
                        match (verifyInvocationRoot(actualContext, rootPrepared, binding)) {
                            case Result.Err(error) => hostManagedJobIoDiagnostic(rootPrepared.source.operationRoot, "read-root-after", error); return Result.Err(error)
                            case Result.Ok(_) => ()
                        }
                        if (finishInvocationScope(scope)) { return hostLifecycleIoCancelled() }
                        return Result.Ok(value)
                    }
                }
                sleep(Duration.millisecond)
            }
            hostLifecycleIoCancelled()
        } finally { let _ = finishInvocationScope(scope) }
    
        } finally { hostChannelIoDiagnosticRecord(2, diagnosticStarted) }
    }

    // This binding is descriptive; the complete current Source/receipt proof
    // remains a separate Store Unit on every activation/read/effect boundary.
    private func managedBindingMatches(actualContext: ToolInvocationContext, parent: PreparedToolInvocation,
        binding: AgentValue, pending: Bool): Result<Unit> {
        if (managedGrant.isNone()) { return hostLifecycleLeaseError("managed_channel.actual_resource_required") }
        managedGrant.getOrThrow().withRetainedRuntime({ => managedBindingMatchesBorrowed(actualContext, parent, binding, pending) })
    }
    private func managedBindingMatchesBorrowed(actualContext: ToolInvocationContext, parent: PreparedToolInvocation,
        binding: AgentValue, pending: Bool): Result<Unit> {
        if (managedGrant.isNone() || validateManagedChannelRuntimeBinding(binding).isError() ||
            actualContext.trustedControl || parent.source.kind == PreparedInvocationSourceKind.Derived ||
            parent.source.operationRoot.isNone() || parent.source.parentOperationId.isSome() || parent.source.requestKey != "" ||
            parent.authorization == PreparedAuthorization.ApprovalRequired || !isManagedChannelOwnedParentPlan(parent.operationPlan) ||
            parent.source.runId.value != actualContext.runId.value || parent.source.sessionId.value != actualContext.sessionId.value ||
            parent.source.epoch != actualContext.epoch || actualContext.sessionId.value != targetThread.value ||
            hostPluginInvocationAuthorityScope(actualContext) != permissionDomain || actualContext.cancellation.isCancelled() ||
            (actualContext.budget.deadlineMillis > 0 && agentUtcMillis() >= actualContext.budget.deadlineMillis)) {
            return hostLifecycleLeaseError("managed_channel.actual_resource_required") }
        lock.lock()
        let available = try { let usable = if (pending) { state == HostLifecycleLeaseState.Pending || state == HostLifecycleLeaseState.Activating }
            else { state == HostLifecycleLeaseState.Active }; usable && channel.isSome() && agentUtcMillis() < expiresAt }
            finally { lock.unlock() }
        if (!available || hostLifecycleText(binding, "resource_state") != "active" ||
            hostLifecycleText(binding, "lease_id") != leaseId || hostLifecycleText(binding, "startup_operation_id") != operationId.value ||
            hostLifecycleText(binding, "launch_digest") != launchDigest || hostLifecycleText(binding, "instance_identity") != instanceIdentity ||
            hostLifecycleText(binding, "plugin") != namespace || hostLifecycleText(binding, "target_thread_id") != targetThread.value ||
            hostLifecycleText(binding, "permission_domain") != permissionDomain || actualContext.workspaceRoot != hostLifecycleText(binding, "workspace_root")) {
            return hostLifecycleLeaseError("managed_channel.resource_binding_changed") }
        let initial = managedGrant.getOrThrow().child.operationPlan.canonicalArguments.field("binding").getOrThrow()
        for (key in ["package_digest", "configuration_digest", "endpoint_identity", "directory_revision", "directory_digest",
            "implementation_version", "implementation_fingerprint", "schema_digest", "workspace_root", "workspace_mode", "network", "lifecycle_policy"]) {
            if (canonicalAgentValue(initial.field(key).getOrThrow()) != canonicalAgentValue(binding.field(key).getOrThrow())) {
                return hostLifecycleLeaseError("managed_channel.resource_binding_changed") }
        }
        let required = match (managedChannelRuntimeRequiredCapabilities(binding)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        for (capability in required) { if (!actualContext.capabilities.allows(capability.kind, resource: capability.resource)) {
            return hostLifecycleLeaseError("managed_channel.capability_denied") } }
        let resources = managedGrant.getOrThrow().actualProcessResources()
        let ceiling = actualContext.budget.processLimits
        if (!hostLifecycleResourceFits(resources.maxOutputBytes, ceiling.maxOutputBytes) ||
            !hostLifecycleResourceFits(resources.addressSpaceBytes, ceiling.addressSpaceBytes) ||
            !hostLifecycleResourceFits(resources.fileSizeBytes, ceiling.fileSizeBytes) ||
            !hostLifecycleResourceFits(resources.openFiles, ceiling.openFiles) ||
            !hostLifecycleResourceFits(resources.processes, ceiling.processes) ||
            !hostLifecycleResourceFits(resources.cpuSeconds, ceiling.cpuSeconds)) {
            return hostLifecycleLeaseError("plugin.lifecycle_resource_ceiling") }
        managedGrant.getOrThrow().stillCurrent()
    }
    func verifyManagedResource(actualContext: ToolInvocationContext, parent: PreparedToolInvocation,
        binding: AgentValue, port: OperationRuntimePort, pending!: Bool = false): Result<Unit> {
        match (managedBindingMatches(actualContext, parent, binding, pending)) { case Result.Err(error) => return Result.Err(error); case _ => () }
        port.verifyManagedChannelOwnedResource(parent.source.operationRoot.getOrThrow(), parent.operationId,
            actualContext.runId, ThreadId(actualContext.sessionId.value), actualContext.epoch, parent.operationPlan, binding,
            { => managedBindingMatches(actualContext, parent, binding, pending) })
    }
    func activateManaged(actualContext: ToolInvocationContext, parent: PreparedToolInvocation,
        binding: AgentValue, port: OperationRuntimePort): Result<Unit> {
        match (verifyManagedResource(actualContext, parent, binding, port, pending: true)) {
            case Result.Err(error) => let _ = revoke(); return Result.Err(error); case _ => () }
        let selected: ProcessChannel; let ticket: ProcessChannelOutputWindow
        lock.lock()
        try {
            if (state != HostLifecycleLeaseState.Pending || channel.isNone() || startupOutputWindow.isNone() ||
                startupCancelled.load() || agentUtcMillis() >= startupUntil) { return hostLifecycleLeaseError("plugin.lifecycle_activation_stale") }
            state = HostLifecycleLeaseState.Activating; selected = channel.getOrThrow(); ticket = startupOutputWindow.getOrThrow()
        } finally { lock.unlock() }
        match (verifyManagedResource(actualContext, parent, binding, port, pending: true)) {
            case Result.Err(error) => let _ = revoke(); return Result.Err(error); case _ => () }
        let promotion = try { selected.endOutputWindow(ticket) } catch (_: Exception) { hostLifecycleLeaseError<Int64>("plugin.lifecycle_startup_window_unverified") }
        match (promotion) { case Result.Err(error) => let _ = revoke(); return Result.Err(error); case _ => () }
        var registration: ?CancellationRegistration = None
        lock.lock()
        let active = try {
            if (state == HostLifecycleLeaseState.Activating && !startupCancelled.load() && !actualContext.cancellation.isCancelled() &&
                agentUtcMillis() < startupUntil && agentUtcMillis() < expiresAt) {
                startupOutputWindow = None; state = HostLifecycleLeaseState.Active
                registration = startupCancellation; startupCancellation = None; true
            } else { false }
        } finally { lock.unlock() }
        match (registration) { case Some(value) => value.dispose(); case None => () }
        if (!active) { let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_activation_stale") }
        verifyManagedResource(actualContext, parent, binding, port)
    }
    func attemptManagedForeignScope(action:()->Result<HostManagedProcessGrant>,peer:HostManagedProcessGrant):Result<Unit>{
        lock.lock();try{
            if(managedGrant.isNone() || managedScopeProbeUsed || state==HostLifecycleLeaseState.Closing || state==HostLifecycleLeaseState.Released){
                return hostLifecycleLeaseError("managed_channel.scope_probe_unavailable")}
            managedScopeProbeUsed=true
        }finally{lock.unlock()}
        // Never hold an owner/lease lock while running Source/Store reads.
        let outcome=action()
        match(outcome){
            case Result.Err(error)=>
                if(error.code!="managed_channel.actual_child_required"){return Result.Err(error)}
                Result.Ok(())
            case Result.Ok(actual)=>
                let paidPeer=peer.retainUnpublishedScopePeerPayment()
                lock.lock();try{
                    unpublishedManagedScopeDebt=Some(actual)
                    if(paidPeer){unpublishedManagedScopePeer=Some(peer)}
                }finally{lock.unlock()}
                // No close, ACK or effect right is exported to the observer.
                // Its caller must fail, then use the original Product close;
                // the same original lease keeps this actual debt on failure.
                hostLifecycleLeaseError("managed_channel.foreign_scope_unexpected_grant")
        }
    }
    private func acknowledgeUnpublishedManagedScopeDebt():Bool{
        match(unpublishedManagedScopeDebt){case Some(actual)=>
            if(!actual.releaseAfterPhysicalCleanup()){return false}
            unpublishedManagedScopeDebt=None<HostManagedProcessGrant>
            case None=>()}
        match(unpublishedManagedScopePeer){case Some(peer)=>
            peer.acknowledgeUnpublishedScopePeerPayment();unpublishedManagedScopePeer=None<HostManagedProcessGrant>
            case None=>()}
        true
    }
    // Called only with the original lease lock held. This helper's error
    // aliases end before its caller clears the Task Result and publishes a
    // retry window. The original private error remains paid until full ACK.
    private func managedPhysicalCloseAccepted(observed:?Result<Unit>):Bool{
        // The original Result alias stays in this helper frame. Only its
        // boolean escapes, before the Task clears observedClose and retries.
        match(observed){case Some(value)=>value.isOk();case None=>false}
    }
    private func retainManagedPhysicalCloseError(observed:?Result<Unit>):Unit{
        if(!managedPhysicalCustodyObserved){return}
        // Opt-in checked exact Native channel and actual Local Port; their
        // fixed original transport errors fit original grant owner overhead.
        // No arbitrary custom Port error or serialized copy is retained.
        match(observed){case Some(value)=>match(value.error()){case Some(error)=>
            managedPhysicalCloseHadError=true
            if(managedPhysicalCloseError.isNone()){
                managedPhysicalCloseError=Some(error)
                managedPhysicalCloseWasPending=error.code=="process.channel_close_pending"}
            case None=>()};case None=>()}
    }
    func withManagedPhysicalCustodyBorrow(body:()->Result<Unit>):Result<Unit>{
        lock.lock();let actual=try{
            if(managedGrant.isNone() || state!=HostLifecycleLeaseState.Active || channel.isNone() ||
                (processes as HostLocalProcessPort).isNone()){
                return hostLifecycleLeaseError("managed_channel.physical_custody_unavailable")}
            match(channel.getOrThrow() as HostNativeProcessChannel){
                case Some(value)=>managedPhysicalCustodyObserved=true;value
                case None=>return hostLifecycleLeaseError("managed_channel.physical_custody_unavailable")}
        }finally{lock.unlock()}
        // The original dynamic grant remains borrowed by the opaque caller.
        // No lifecycle, Store or owner lock is held while borrowing native IO.
        actual.withManagedReadOnlyIoCustody(body)
    }
    func managedCleanupPhysicalState():(Bool,Bool,Bool,Bool,Bool,Bool){
        lock.lock();try{
            // No raw error alias is borrowed by this readonly snapshot.
            let pending=managedPhysicalCloseError.isSome() && managedPhysicalCloseWasPending
            (managedCloseAcknowledged,stdoutDone.load() && stderrDone.load(),ioScopes.isEmpty(),managedPhysicalCloseHadError,managedPhysicalCloseError.isSome(),pending)
        }finally{lock.unlock()}
    }
    func managedConfiguredProcessCeiling():Result<?HostPluginLifecycleLaunchGrant>{
        lock.lock();try{
            if(state!=HostLifecycleLeaseState.Active || managedGrant.isNone()){
                return hostLifecycleLeaseError("managed_channel.actual_adapter_changed")}
            Result.Ok(managedGrant.getOrThrow().configuredProcessCeiling())
        }finally{lock.unlock()}
    }
    func managedAuxiliaryFor(adapter:HostPluginLifecycleLease):Bool{
        match(managedGrant){case Some(value)=>value.belongsToAdapter(adapter);case None=>false}
    }
    func managedOwnsPrepared(child:PreparedToolInvocation):Bool{
        match(managedGrant){case Some(value)=>value.ownsActualPrepared(child);case None=>false}
    }
    func captureManagedNamespaces(actualContext:ToolInvocationContext,parent:PreparedToolInvocation,binding:AgentValue,
        port:OperationRuntimePort,adopt:(process.ProcessSandboxNamespaces)->Unit):Result<Unit>{
        match(verifyManagedResource(actualContext,parent,binding,port)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        let scope=match(invocationScope(actualContext)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(value)=>value}
        try{
            lock.lock();let selected=try{
                if(state!=HostLifecycleLeaseState.Active || channel.isNone()){
                    return hostLifecycleLeaseError("managed_channel.actual_adapter_changed")}
                channel.getOrThrow()
            }finally{lock.unlock()}
            let actual=match(selected as HostManagedChannelNamespaceObservation){
                case Some(value)=>value;case None=>return hostLifecycleLeaseError("managed_channel.actual_namespace_observation_unavailable")}
            match(actual.captureManagedNamespaces(adopt)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            match(verifyManagedResource(actualContext,parent,binding,port)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            if(scope.isCancelled()){return hostLifecycleIoCancelled()}
            Result.Ok(())
        }finally{let _=finishInvocationScope(scope)}
    }
    func managedObservedProcessId():Result<Int64>{
        lock.lock();let actual=try{
            if(managedGrant.isNone() || channel.isNone() ||
                (state!=HostLifecycleLeaseState.Pending && state!=HostLifecycleLeaseState.Active)){
                return hostLifecycleLeaseError<Int64>("managed_channel.actual_process_unavailable")}
            channel.getOrThrow()
        }finally{lock.unlock()}
        if(managedGrant.getOrThrow().role=="auxiliary"){return managedGrant.getOrThrow().observeAuxiliaryPayload(actual)}
        match(actual as HostManagedChannelPhysicalProcessObservation){
            case Some(value)=>value.observedManagedProcessId()
            case None=>hostLifecycleLeaseError("managed_channel.actual_process_observation_unavailable")}
    }

    func managedRead(actualContext: ToolInvocationContext, parent: PreparedToolInvocation, binding: AgentValue,
        port: OperationRuntimePort, stream: ProcessChannelStream, maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        if (maxBytes < 1 || maxBytes > 65536 || waitMillis < 0 || waitMillis > 1000) { return hostLifecycleLeaseError("plugin.lifecycle_read_bounds") }
        match (verifyManagedResource(actualContext, parent, binding, port)) { case Result.Err(error) => return Result.Err(error); case _ => () }
        let scope = match (invocationScope(actualContext)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        try {
            let queue = match (stream) { case ProcessChannelStream.Stdout => stdout; case ProcessChannelStream.Stderr => stderr }
            let deadline = MonoTime.now() + Duration.millisecond * waitMillis
            while (!scope.isCancelled()) {
                match (queue.poll(maxBytes)) {
                    case Result.Err(error) => return Result.Err(error)
                    case Result.Ok(value) => if (!value.bytes.isEmpty() || value.eof || MonoTime.now() >= deadline) {
                        match (verifyManagedResource(actualContext, parent, binding, port)) { case Result.Err(error) => return Result.Err(error); case _ => () }
                        if (finishInvocationScope(scope)) { return hostLifecycleIoCancelled() }; return Result.Ok(value) }
                }
                sleep(Duration.millisecond)
            }
            hostLifecycleIoCancelled()
        } finally { let _ = finishInvocationScope(scope) }
    }
    func managedWrite(rootContext: ToolInvocationContext, parent: PreparedToolInvocation, childContext: ToolInvocationContext,
        child: PreparedToolInvocation, binding: AgentValue, port: OperationRuntimePort): Result<Unit> {
        let current = { => verifyManagedResource(rootContext, parent, binding, port) }
        match (hostManagedChannelVerifyExecuting(port, rootContext, parent, childContext, child, current)) {
            case Result.Err(error) => return Result.Err(error); case _ => () }
        let operation = child.operationPlan.canonicalArguments.field("operation").getOrThrow()
        if (hostLifecycleText(operation, "kind") != "write" || hostLifecycleText(operation, "lease_id") != leaseId) {
            return hostLifecycleLeaseError("managed_channel.write_required") }
        let encoded = hostLifecycleText(operation, "bytes_hex")
        if (encoded.size / 2 > maxTotalInput || encoded.size % 2 != 0) { return hostLifecycleLeaseError("plugin.lifecycle_write_not_admitted") }
        let payment = try { reserveNativeDocumentPayload(1) } catch (_: Exception) { return hostLifecycleLeaseError("managed_channel.write_capacity") }
        try {
            let measure = HostManagedGrantRetainedMeasure()
            measure.add(child.operationPlan.canonicalArguments); measure.add(child.call.arguments); measure.add(binding)
            payment.ensureRetainedPeak(measure.peak() + encoded.size * 2 + 131072)
            let bytes = hostManagedChannelUnhex(encoded, maxTotalInput)
            let scope = match (invocationScope(rootContext)) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
            try {
                writer.lock()
                try {
                    match (hostManagedChannelVerifyExecuting(port, rootContext, parent, childContext, child, current)) {
                        case Result.Err(error) => return Result.Err(error); case _ => () }
                    let selected: ProcessChannel
                    lock.lock()
                    try {
                        if (state != HostLifecycleLeaseState.Active || channel.isNone() || attemptedWrites.contains(child.operationId.value) ||
                            attemptedWrites.size >= 4096 || bytes.size > maxTotalInput - inputBytes) { return hostLifecycleLeaseError("plugin.lifecycle_write_not_admitted") }
                        attemptedWrites.add(child.operationId.value); inputBytes += bytes.size; writes += 1; selected = channel.getOrThrow()
                    } finally { lock.unlock() }
                    let written = hostLifecycleWritePreparedChunks(bytes, { part => selected.write(part) }, { =>
                        if (scope.isCancelled()) { return hostLifecycleIoCancelled<Unit>() }
                        hostManagedChannelVerifyExecuting(port, rootContext, parent, childContext, child, current) })
                    if (written.isError()) { let _ = revoke(); return hostLifecycleIoUnknown() }
                    match (hostManagedChannelVerifyExecuting(port, rootContext, parent, childContext, child, current)) {
                        case Result.Err(_) => let _ = revoke(); return hostLifecycleIoUnknown(); case _ => () }
                    if (finishInvocationScope(scope)) { let _ = revoke(); return hostLifecycleIoCancelled() }; Result.Ok(())
                } finally { writer.unlock() }
            } finally { let _ = finishInvocationScope(scope) }
        } catch (_: Exception) { hostLifecycleLeaseError("managed_channel.write_capacity") }
        finally { payment.close() }
    }

    func managedClose(rootContext: ToolInvocationContext, parent: PreparedToolInvocation, childContext: ToolInvocationContext,
        child: PreparedToolInvocation, binding: AgentValue, port: OperationRuntimePort): Result<Unit> {
        let operation = child.operationPlan.canonicalArguments.field("operation").getOrThrow()
        if (hostLifecycleText(operation, "kind") != "close" || hostLifecycleText(operation, "lease_id") != leaseId) {
            return hostLifecycleLeaseError("managed_channel.close_required") }
        match (hostManagedChannelVerifyExecuting(port, rootContext, parent, childContext, child,
            { => verifyManagedResource(rootContext, parent, binding, port) })) {
            case Result.Err(error) => return Result.Err(error); case _ => () }
        writer.lock()
        try {
            match (hostManagedChannelVerifyExecuting(port, rootContext, parent, childContext, child,
                { => verifyManagedResource(rootContext, parent, binding, port) })) {
                case Result.Err(error) => return Result.Err(error); case _ => () }
            let grace=match(operation.field("grace_ms")){case Some(value)=>Int64.parse(value.asNumberText());case None=>frozenShutdownGrace}
            if(grace<0 || grace>frozenShutdownGrace){return hostLifecycleLeaseError("managed_channel.close_grace_ceiling")}
            match(beginGracefulClose(grace)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
            let started=MonoTime.now()
            while (!resourcesReleased()) {
                if(rootContext.cancellation.isCancelled() ||
                    (rootContext.budget.deadlineMillis>0 && agentUtcMillis()>=rootContext.budget.deadlineMillis)){
                    let _=revoke();return hostLifecycleIoCancelled()}
                let elapsed=(MonoTime.now()-started).toMilliseconds()
                if(elapsed>=grace && elapsed-grace>=2000){return hostLifecycleIoUnknown()}
                tryCleanup(); sleep(Duration.millisecond)
            }
            // Only after the real close ACK, prove the exact still-executing
            // child again. Its resource's closed audit is written solely by
            // normal Pipeline settlement of this actual completed output.
            // The released Lease never supplies a replacement source/grant.
            port.verifyManagedChannelOwnedEffectExecuting(parent.source.operationRoot.getOrThrow(), parent.operationId,
                child.operationId, rootContext.runId, ThreadId(rootContext.sessionId.value), rootContext.epoch,
                parent.operationPlan, child.operationPlan, child.source.requestKey, child.call.callId, child.approval,
                { => hostManagedChannelContext(rootContext, parent, childContext, child) })
        } finally { writer.unlock() }
    }

    private func verifyInvocationChild(rootContext: ToolInvocationContext, childContext: ToolInvocationContext,
        child: PreparedToolInvocation, binding: AgentValue): Result<Unit> {
        if (childContext.trustedControl || child.source.kind != PreparedInvocationSourceKind.Derived ||
            child.authorization != PreparedAuthorization.ParentIntent || child.source.operationRoot.isNone() ||
            child.source.parentOperationId.isNone() || child.source.runId.value != rootContext.runId.value ||
            child.source.sessionId.value != rootContext.sessionId.value || child.source.epoch != rootContext.epoch ||
            childContext.runId.value != rootContext.runId.value || childContext.sessionId.value != rootContext.sessionId.value ||
            childContext.epoch != rootContext.epoch || !refEq(childContext.cancellation, rootContext.cancellation) ||
            !refEq(childContext.budget, rootContext.budget) || childContext.workspaceRoot != rootContext.workspaceRoot ||
            childContext.cwd != rootContext.cwd || child.operationPlan.toolName != HOST_CHANNEL_WRITE_TOOL) {
            return hostLifecycleLeaseError("plugin.lifecycle_child_context_mismatch")
        }
        let left = rootContext.environment.entries(); let right = childContext.environment.entries()
        if (left.size != right.size) { return hostLifecycleLeaseError("plugin.lifecycle_child_context_mismatch") }
        for (index in 0..left.size where left[index].name != right[index].name || left[index].value != right[index].value) {
            return hostLifecycleLeaseError("plugin.lifecycle_child_context_mismatch")
        }
        for (capability in childContext.capabilities.values where
            !rootContext.capabilities.allows(capability.kind, resource: capability.resource)) {
            return hostLifecycleLeaseError("plugin.lifecycle_child_capability_widened")
        }
        for (capability in child.operationPlan.requiredCapabilities where
            !childContext.capabilities.allows(capability.kind, resource: capability.resource)) {
            return hostLifecycleLeaseError("plugin.lifecycle_child_capability_denied")
        }
        let contextTimer = channelWriteMemoDiagnosticStart()
        try {
            match (checkInvocation(rootContext, binding, child.source.operationRoot)) {
                case Result.Err(error) => hostManagedJobIoDiagnostic(child.source.operationRoot, "child-scope", error); return Result.Err(error)
                case Result.Ok(_) => () }
        } finally { channelWriteMemoDiagnosticRecord(5, contextTimer) }
        let storeTimer = channelWriteMemoDiagnosticStart()
        let result = try {
            invocationStore.verifyChannelWriteExecution(child.operationId,
                child.source.parentOperationId.getOrThrow(), childContext.runId, ThreadId(childContext.sessionId.value),
                childContext.epoch, child.source.operationRoot.getOrThrow(), child.source.requestKey, child.operationPlan, binding)
        } finally { channelWriteMemoDiagnosticRecord(6, storeTimer) }
        match (result) { case Result.Err(error) => hostManagedJobIoDiagnostic(child.source.operationRoot, "child-store", error); case _ => () }
        result
    }

    func writePreparedChild(rootContext: ToolInvocationContext, childContext: ToolInvocationContext,
        childPrepared: PreparedToolInvocation, expectedBinding: AgentValue): Result<Unit> {
        let binding = try { parseUnifiedJson(stringifyUnifiedJson(expectedBinding), maxBytes: 196608) }
            catch (_: Exception) { return hostLifecycleLeaseError("plugin.lifecycle_binding_invalid") }
        match (verifyInvocationChild(rootContext, childContext, childPrepared, binding)) {
            case Result.Err(error) => hostManagedJobIoDiagnostic(childPrepared.source.operationRoot, "write-preflight", error); return Result.Err(error)
            case Result.Ok(_) => ()
        }
        let intent = childPrepared.operationPlan.canonicalArguments.field("intent").getOrThrow()
        let loaded = if (intent.field("payload").isSome()) {
            match (payloadArtifacts) {
                case Some(store) => store.readServicePayload(intent.field("payload").getOrThrow(),
                    servicePayloadLimits(binding).value().getOrThrow().getOrThrow().maxWriteBytes)
                case None => hostLifecycleLeaseError<Array<Byte>>("plugin.payload_store_unavailable")
            }
        } else { channelServiceWriteBytes(intent, maximumBytes: serviceProtocolLimits(binding).value().getOrThrow().requestBytes) }
        let bytes = match (loaded) { case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value }
        let scope = match (invocationScope(rootContext)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        try {
            writer.lock()
            try {
                match (verifyInvocationChild(rootContext, childContext, childPrepared, binding)) {
                    case Result.Err(error) => hostManagedJobIoDiagnostic(childPrepared.source.operationRoot, "write-under-lock", error); return Result.Err(error)
                    case Result.Ok(_) => ()
                }
                let selected: ProcessChannel
                lock.lock()
                try {
                    if (state != HostLifecycleLeaseState.Active || channel.isNone() ||
                        attemptedWrites.contains(childPrepared.operationId.value) || attemptedWrites.size >= 4096 ||
                        bytes.size > maxTotalInput - inputBytes) {
                        return hostLifecycleLeaseError("plugin.lifecycle_write_not_admitted")
                    }
                    // Total includes startup bytes and every later attempt. A
                    // partial/failed write never refunds bytes or its identity.
                    attemptedWrites.add(childPrepared.operationId.value)
                    inputBytes += bytes.size; writes += 1; selected = channel.getOrThrow()
                } finally { lock.unlock() }
                let result = hostLifecycleWritePreparedChunks(bytes, { part =>
                    let physical = selected.write(part)
                    match (physical) { case Result.Err(error) => hostManagedJobIoDiagnostic(childPrepared.source.operationRoot, "physical-write", error); case _ => () }
                    physical
                }, { =>
                    if (scope.isCancelled()) { return hostLifecycleIoCancelled<Unit>() }
                    match (verifyInvocationChild(rootContext, childContext, childPrepared, binding)) {
                        case Result.Err(error) => hostManagedJobIoDiagnostic(childPrepared.source.operationRoot, "write-chunk-guard", error); return Result.Err(error)
                        case Result.Ok(_) => ()
                    }
                    lock.lock()
                    try {
                        if (state != HostLifecycleLeaseState.Active || channel.isNone() || inputBytes > maxTotalInput) {
                            return hostLifecycleLeaseError<Unit>("plugin.lifecycle_write_not_admitted")
                        }
                        Result.Ok(())
                    } finally { lock.unlock() }
                })
                if (result.isError()) {
                    hostManagedJobIoDiagnostic(childPrepared.source.operationRoot, "write-loop", result.error().getOrThrow())
                    let _ = revoke(); return if (scope.isCancelled()) { hostLifecycleIoCancelled() } else { hostLifecycleIoUnknown() } }
                if (scope.isCancelled()) { let _ = revoke(); return hostLifecycleIoCancelled() }
                match (verifyInvocationChild(rootContext, childContext, childPrepared, binding)) {
                    case Result.Err(error) =>
                        hostManagedJobIoDiagnostic(childPrepared.source.operationRoot, "write-postcheck", error)
                        let _ = revoke()
                        return if (scope.isCancelled()) { hostLifecycleIoCancelled() } else { hostLifecycleIoUnknown() }
                    case Result.Ok(_) => ()
                }
                if (finishInvocationScope(scope)) { return hostLifecycleIoCancelled() }
                Result.Ok(())
            } finally { writer.unlock() }
        } finally { let _ = finishInvocationScope(scope) }
    }

    // A refresh is a new approved canonical maintenance Operation. The old
    // startup receipt is only the retained resource identity, never permission
    // to send arbitrary bytes outside this finite window.
    func refreshWindow(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        expectedPlan: AgentValue): Result<HostLifecycleRefreshWindow> {
        let plan = try { parseUnifiedJson(stringifyUnifiedJson(expectedPlan), maxBytes: 131072) }
            catch (_: Exception) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_plan_invalid") }
        match (verifyRefresh(context, prepared, plan)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        lock.lock()
        try {
            if (state != HostLifecycleLeaseState.Active || attemptedRefreshes.contains(prepared.operationId.value) ||
                attemptedRefreshes.size >= 4096) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_replayed") }
            attemptedRefreshes.add(prepared.operationId.value)
        } finally { lock.unlock() }
        let limits = plan.field("window").getOrThrow()
        let scope = match (invocationScope(context,
            additionalDeadline: agentUtcMillis() + hostLifecycleInt(limits, "timeout_ms", 60000))) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(value) => value
        }
        lock.lock(); let selected = try { channel } finally { lock.unlock() }
        let ticket = match (selected) {
            case Some(value) => try { value.beginOutputWindow(hostLifecycleInt(limits, "max_output_bytes", HOST_PLUGIN_LIFECYCLE_IO_BYTES), false) }
                catch (_: Exception) { hostLifecycleLeaseError<ProcessChannelOutputWindow>("plugin.lifecycle_refresh_window_unverified") }
            case None => hostLifecycleLeaseError<ProcessChannelOutputWindow>("plugin.lifecycle_refresh_stale")
        }
        let outputTicket = match (ticket) {
            case Result.Err(error) =>
                let _ = revoke(); let _ = finishInvocationScope(scope); return Result.Err(error)
            case Result.Ok(value) => value
        }
        let window = HostLifecycleRefreshWindow(this, context, prepared, plan, scope, outputTicket)
        lock.lock()
        let published = try {
            if (state == HostLifecycleLeaseState.Active && refreshOutputWindow.isNone()) {
                refreshOutputWindow = Some(window); true
            } else { false }
        } finally { lock.unlock() }
        if (!published) {
            let _ = revoke(); let _ = finishInvocationScope(scope)
            return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale")
        }
        Result.Ok(window)
    }

    private func verifyRefresh(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        plan: AgentValue): Result<Unit> {
        match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!isActive()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale") }
        try {
            hostLifecycleExact(plan, ["schema", "launch", "lease_id", "endpoint_identity", "expected_revision", "directory_digest", "window"])
            let window = grant.launchPlan.field("refresh").getOrThrow()
            hostLifecycleLeaseAssert(window.unifiedKind == ValueKind.Object &&
                hostLifecycleText(plan, "schema") == "axyndra.lifecycle-refresh/v1" &&
                hostLifecycleText(plan, "lease_id") == leaseId &&
                hostLifecycleText(plan, "endpoint_identity") != "" &&
                hostLifecycleInt(plan, "expected_revision", 2147483646) > 0 &&
                canonicalAgentValue(plan.field("launch").getOrThrow()) == canonicalAgentValue(grant.launchPlan) &&
                canonicalAgentValue(plan.field("window").getOrThrow()) == canonicalAgentValue(window))
            let root = hostLifecyclePreparedHostSource(context, prepared, grant,
                toolName: HOST_PLUGIN_LIFECYCLE_REFRESH_TOOL, action: HostServiceAction.Refresh,
                expectedArguments: Some(plan))
            database.transaction { transaction => hostRequireLifecycleDurableOrigin(transaction, prepared, root, true) }
            Result.Ok(())
        } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_refresh_uncommitted") }
    }

    func readRefresh(window: HostLifecycleRefreshWindow, stream: ProcessChannelStream,
        maxBytes: Int64, waitMillis: Int64): Result<ProcessChannelRead> {
        if (!window.ownedBy(this) || maxBytes < 1 || maxBytes > 65536 || waitMillis < 0 || waitMillis > 25) {
            return hostLifecycleLeaseError("plugin.lifecycle_refresh_window_invalid")
        }
        match (verifyRefresh(window.context, window.prepared, window.plan)) {
            case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
        }
        let queue = match (stream) { case ProcessChannelStream.Stdout => stdout; case ProcessChannelStream.Stderr => stderr }
        let deadline = MonoTime.now() + Duration.millisecond * waitMillis
        while (!window.closedOrCancelled()) {
            let received = match (refreshOutputMeter()) {
                case Result.Err(error) => let _ = revoke(); return Result.Err(error)
                case Result.Ok(value) => value
            }
            if (received < window.outputBaseline || received - window.outputBaseline > window.maxOutput) {
                let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_refresh_output_limit")
            }
            match (queue.poll(maxBytes)) {
                case Result.Err(error) => return Result.Err(error)
                case Result.Ok(value) => if (!value.bytes.isEmpty() || value.eof || MonoTime.now() >= deadline) {
                    if (!window.reserveRead(value.bytes.size)) {
                        let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_refresh_output_limit")
                    }
                    match (verifyRefresh(window.context, window.prepared, window.plan)) {
                        case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
                    }
                    if (window.closedOrCancelled()) { return hostLifecycleIoCancelled() }
                    return Result.Ok(value)
                }
            }
            sleep(Duration.millisecond)
        }
        hostLifecycleIoCancelled()
    }

    private func refreshOutputMeter(): Result<Int64> {
        let selected: ?ProcessChannel
        lock.lock()
        try { selected = channel } finally { lock.unlock() }
        // Every lifecycle channel now has the same atomic native phase meter,
        // including queued bytes and withheld secret prefixes. Never call a
        // Port while holding the owner lock.
        match (selected) {
            case None => hostLifecycleLeaseError("plugin.lifecycle_refresh_stale")
            case Some(value) => try {
                match (value.receivedOutputBytes()) {
                    case Result.Ok(count) => if (count >= 0 && count <= maxTotalOutput) {
                        Result.Ok(count)
                    } else { hostLifecycleLeaseError("plugin.lifecycle_refresh_output_limit") }
                    case Result.Err(_) => hostLifecycleLeaseError("plugin.lifecycle_refresh_output_unverified")
                }
            } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_refresh_output_unverified") }
        }
    }

    func writeRefresh(window: HostLifecycleRefreshWindow, bytes: Array<Byte>): Result<Unit> {
        if (!window.ownedBy(this) || bytes.isEmpty() || bytes.size > 65536) {
            return hostLifecycleLeaseError("plugin.lifecycle_refresh_window_invalid")
        }
        let frozen = bytes.clone()
        writer.lock()
        try {
            match (verifyRefresh(window.context, window.prepared, window.plan)) {
                case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => ()
            }
            if (!window.reserveWrite(frozen.size)) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_input_limit") }
            let selected: ProcessChannel
            lock.lock()
            try {
                if (state != HostLifecycleLeaseState.Active || channel.isNone() || frozen.size > maxTotalInput - inputBytes) {
                    return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale")
                }
                inputBytes += frozen.size; writes += 1; selected = channel.getOrThrow()
            } finally { lock.unlock() }
            let result = try { selected.write(frozen) } catch (_: Exception) { hostLifecycleIoUnknown<Unit>() }
            if (result.isError() || window.closedOrCancelled()) {
                let _ = revoke()
                return if (window.scope.isCancelled()) { hostLifecycleIoCancelled() } else { hostLifecycleIoUnknown() }
            }
            match (verifyRefresh(window.context, window.prepared, window.plan)) {
                case Result.Err(_) => let _ = revoke(); hostLifecycleIoUnknown()
                case Result.Ok(_) => Result.Ok(())
            }
        } finally { writer.unlock() }
    }

    func closeRefresh(window: HostLifecycleRefreshWindow): Bool {
        if (!window.ownedBy(this)) { return true }
        finishInvocationScope(window.scope)
    }

    func refreshCommitted(context: ToolInvocationContext, prepared: PreparedToolInvocation,
        expectedPlan: AgentValue, expectedOutput: AgentValue): Result<Unit> {
        // Serialize promotion with refresh writes and other promotion attempts;
        // the ordinary owner mutex is never held across a Port callback.
        writer.lock()
        try {
        if (hostManagedChannelCallerCancelled(context)) { return hostLifecycleIoCancelled() }
        match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        if (!isActive()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale") }
        lock.lock()
        let (capturedChannel, capturedWindow) = try { (channel, refreshOutputWindow) } finally { lock.unlock() }
        if (capturedChannel.isNone() || capturedWindow.isNone()) { return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale") }
        let selected = capturedChannel.getOrThrow()
        let window = capturedWindow.getOrThrow()
        if (window.prepared.operationId.value != prepared.operationId.value ||
            !window.readyForCommit() || canonicalAgentValue(window.plan) != canonicalAgentValue(expectedPlan)) {
            return hostLifecycleLeaseError("plugin.lifecycle_refresh_stale")
        }
        try {
            let root = hostLifecyclePreparedHostSource(context, prepared, grant,
                toolName: HOST_PLUGIN_LIFECYCLE_REFRESH_TOOL, action: HostServiceAction.Refresh,
                expectedArguments: Some(expectedPlan))
            database.transaction { transaction =>
                hostRequireLifecycleDurableOrigin(transaction, prepared, root, false)
                let receipts = transaction.query("SELECT id,outcome,detail FROM operation_receipts WHERE operation_id=?",
                    [SqlParameter.Text(root.operationId.value)])
                hostLifecycleLeaseAssert(receipts.size == 1 && receipts[0].required(1) == "completed" &&
                    canonicalAgentValue(decodeStoredValue(receipts[0].required(2))) == canonicalAgentValue(expectedOutput))
                let results = transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
                    [SqlParameter.Text(root.threadId.value), SqlParameter.Text(root.turnId.value)])
                var matches: Int64 = 0
                for (row in results) {
                    match (decodeStoredThreadContent(row.required(0))) {
                        case ThreadItemContent.ToolResult(callId, operationId, receiptId, output, isError) =>
                            if (operationId.value == root.operationId.value) {
                                hostLifecycleLeaseAssert(!isError && callId.value == root.call.callId && receiptId == receipts[0].required(0) &&
                                    canonicalAgentValue(output) == canonicalAgentValue(expectedOutput))
                                matches += 1
                            }
                        case _ => ()
                    }
                }
                hostLifecycleLeaseAssert(matches == 1)
            }
            // The actual Completed Receipt/ToolResult above is the only
            // promotion trigger. Closing the protocol window alone leaves its
            // raw ingress ceiling installed, even while commit is delayed.
            match (grant.stillCurrent()) { case Result.Err(error) => let _ = revoke(); return Result.Err(error); case Result.Ok(_) => () }
            if (hostManagedChannelCallerCancelled(context) || !isActive()) { let _ = revoke(); return hostLifecycleIoCancelled() }
            match (selected.endOutputWindow(window.outputTicket)) {
                case Result.Err(_) => let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_refresh_output_limit")
                case Result.Ok(_) => ()
            }
            lock.lock()
            let promoted = try {
                if (state == HostLifecycleLeaseState.Active && refreshOutputWindow.isSome() &&
                    refEq(refreshOutputWindow.getOrThrow(), window)) {
                    refreshOutputWindow = None; true
                } else { false }
            } finally { lock.unlock() }
            if (!promoted || hostManagedChannelCallerCancelled(context)) { let _ = revoke(); return hostLifecycleIoCancelled() }
            Result.Ok(())
        } catch (_: Exception) { let _ = revoke(); hostLifecycleLeaseError("plugin.lifecycle_refresh_uncommitted") }
        } finally { writer.unlock() }
    }

    func sealSummary(data: AgentValue): Result<AgentValue> {
        writer.lock()
        try {
        match (checkStartup()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let summary = try { parseUnifiedJson(stringifyUnifiedJson(objectValue([
            ValueField("lease_id", textValue(leaseId)), ValueField("launch_digest", textValue(launchDigest)),
            ValueField("result", data)])), maxBytes: hostManagedServiceSummaryLimit(grant.launchPlan, 65536)) }
            catch (_: Exception) { return hostLifecycleLeaseError("plugin.lifecycle_summary_limit") }
        if (!hostManagedServiceDurableValueFits(summary)) { return hostLifecycleIoUnknown<AgentValue>() }
        lock.lock()
        try {
            if (state != HostLifecycleLeaseState.Pending || startupCancelled.load() ||
                agentUtcMillis() >= startupUntil || agentUtcMillis() >= expiresAt) {
                return hostLifecycleLeaseError("plugin.lifecycle_startup_closed")
            }
            summaryText = Some(stringifyUnifiedJson(summary)); state = HostLifecycleLeaseState.Sealed
            Result.Ok(summary)
        } finally { lock.unlock() }
        } finally { writer.unlock() }
    }
    func activateCommitted(): Result<Unit> {
        if (managedGrant.isSome()) { return hostLifecycleLeaseError("managed_channel.typed_entry_required") }
        match (grant.stillCurrent()) { case Result.Err(error) => let _ = revoke(); return Result.Err(error); case Result.Ok(_) => () }
        let cancelled = context.cancellation.isCancelled() || source.token.isCancelled()
        let selected: ProcessChannel
        let ticket: ProcessChannelOutputWindow
        let summary: String
        lock.lock()
        try {
            if (state != HostLifecycleLeaseState.Sealed || summaryText.isNone() || channel.isNone() ||
                startupOutputWindow.isNone() || cancelled || startupCancelled.load() || agentUtcMillis() >= startupUntil) {
                return hostLifecycleLeaseError("plugin.lifecycle_activation_stale")
            }
            state = HostLifecycleLeaseState.Activating
            selected = channel.getOrThrow(); ticket = startupOutputWindow.getOrThrow(); summary = summaryText.getOrThrow()
        } finally { lock.unlock() }
        // Neither SQL nor a Port callback executes under the lease lock.
        match (hostValidateLifecycleStartupReceipt(database, context, prepared, grant, summary)) {
            case Result.Err(error) => let _ = revoke(); return Result.Err(error)
            case Result.Ok(_) => ()
        }
        match (grant.stillCurrent()) { case Result.Err(error) => let _ = revoke(); return Result.Err(error); case Result.Ok(_) => () }
        if (startupCancelled.load() || context.cancellation.isCancelled() || source.token.isCancelled() ||
            agentUtcMillis() >= startupUntil || agentUtcMillis() >= expiresAt) {
            let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_activation_stale")
        }
        let promotion = try { selected.endOutputWindow(ticket) }
            catch (_: Exception) { hostLifecycleLeaseError<Int64>("plugin.lifecycle_startup_window_unverified") }
        match (promotion) { case Result.Err(error) => let _ = revoke(); return Result.Err(error); case Result.Ok(_) => () }
        var registration: ?CancellationRegistration = None
        lock.lock()
        let active = try {
            if (state == HostLifecycleLeaseState.Activating && !startupCancelled.load() &&
                agentUtcMillis() < startupUntil && agentUtcMillis() < expiresAt &&
                (context.cancellation.deadlineMillis <= 0 || agentUtcMillis() < context.cancellation.deadlineMillis)) {
                startupOutputWindow = None; state = HostLifecycleLeaseState.Active
                registration = startupCancellation; startupCancellation = None; true
            } else { false }
        } finally { lock.unlock() }
        match (registration) { case Some(value) => value.dispose(); case None => () }
        if (!active) { let _ = revoke(); return hostLifecycleLeaseError("plugin.lifecycle_activation_stale") }
        Result.Ok(())
    }
    private func cancelStartup(): Unit {
        startupCancelled.store(true)
        var pending = false
        var selected: ?ProcessChannel = None
        lock.lock()
        try { pending = state == HostLifecycleLeaseState.Opening || state == HostLifecycleLeaseState.Pending ||
            state == HostLifecycleLeaseState.Sealed || state == HostLifecycleLeaseState.Activating
            if (pending) { invalidateOutputWindowsLocked(); state = HostLifecycleLeaseState.Closing; selected = channel }
        }
        finally { lock.unlock() }
        if (pending) { finishRevocation(selected) }
    }
    // Normal stop reads policy only from the original normalized plan.
    func stopFrozen():Result<Unit>{
        lock.lock();let already=try{state==HostLifecycleLeaseState.Closing || state==HostLifecycleLeaseState.Released}finally{lock.unlock()}
        if(!already){
            match(grant.stillCurrent()){case Result.Err(error)=>let _=revoke();return Result.Err(error);case Result.Ok(_)=>()}
            if(managedGrant.isNone()){
                match(summaryText){case Some(summary)=>
                    match(hostValidateLifecycleStartupReceipt(database,context,prepared,grant,summary)){
                        case Result.Err(error)=>let _=revoke();return Result.Err(error);case Result.Ok(_)=>()}
                    case None=>let _=revoke();return hostLifecycleLeaseError("process.shutdown_startup_missing")}
            }else{
                // The actual admitted spawn retained these immutable contexts;
                // cleanup rechecks their capability/resource ceiling, never a
                // Native boolean or a new descriptor-derived authorization.
                let actual=managedGrant.getOrThrow()
                match(actual.stillCurrentForCleanup()){case Result.Err(error)=>return Result.Err(error);case _=>()}
                let binding=actual.child.operationPlan.canonicalArguments.field("binding").getOrThrow()
                for(required in actual.child.operationPlan.requiredCapabilities){
                    if(!actual.childContext.capabilities.allows(required.kind,resource:required.resource)){
                        let _=revoke();return hostLifecycleLeaseError("managed_channel.capability_denied")}}
                let resources=actual.actualProcessResources();let ceiling=actual.childContext.budget.processLimits
                if(!hostLifecycleResourceFits(resources.maxOutputBytes,ceiling.maxOutputBytes) ||
                    !hostLifecycleResourceFits(resources.addressSpaceBytes,ceiling.addressSpaceBytes) ||
                    !hostLifecycleResourceFits(resources.fileSizeBytes,ceiling.fileSizeBytes) ||
                    !hostLifecycleResourceFits(resources.openFiles,ceiling.openFiles) ||
                    !hostLifecycleResourceFits(resources.processes,ceiling.processes) ||
                    !hostLifecycleResourceFits(resources.cpuSeconds,ceiling.cpuSeconds) ||
                    processShutdownPolicyGrace(binding.field("lifecycle_policy").getOrThrow()).value().getOrThrow()!=frozenShutdownGrace){
                    let _=revoke();return hostLifecycleLeaseError("managed_channel.process_ceiling")}
            }
            if(processShutdownPolicyGrace(grant.launchPlan.field("lifecycle_policy").getOrThrow()).value().getOrThrow()!=frozenShutdownGrace){
                let _=revoke();return hostLifecycleLeaseError("process.shutdown_policy_changed")}
            match(beginGracefulClose(frozenShutdownGrace)){case Result.Err(error)=>return Result.Err(error);case Result.Ok(_)=>()}
        }
        tryCleanup()
        if(resourcesReleased()){Result.Ok(())}else{hostLifecycleLeaseError("plugin.lifecycle_cleanup_pending")}
    }
    private func beginGracefulClose(grace:Int64):Result<Unit>{
        lock.lock();try{
            if(state==HostLifecycleLeaseState.Released){return Result.Ok(())}
            if(state!=HostLifecycleLeaseState.Active || opening || channel.isNone() || grace<0 || grace>frozenShutdownGrace){
                return hostLifecycleLeaseError("process.shutdown_not_active")}
            invalidateOutputWindowsLocked();state=HostLifecycleLeaseState.Closing;gracefulCleanup=Some(grace)
        }finally{lock.unlock()}
        // Caller authority is withdrawn immediately. Only private bounded
        // draining continues, without any new read/write/tool/network right.
        let _=revocation.cancel()
        stdout.finish(error:Some(hostLifecycleLeaseFailure("plugin.lifecycle_closed")))
        stderr.finish(error:Some(hostLifecycleLeaseFailure("plugin.lifecycle_closed")))
        tryCleanup();Result.Ok(())
    }
    public func revoke(): Result<Unit> {
        let selected: ?ProcessChannel
        lock.lock()
        try {
            if (state == HostLifecycleLeaseState.Released) { return Result.Ok(()) }
            invalidateOutputWindowsLocked()
            gracefulCleanup=None<Int64>
            state = HostLifecycleLeaseState.Closing; selected = channel
        } finally { lock.unlock() }
        finishRevocation(selected)
        if (resourcesReleased()) { Result.Ok(()) } else { hostLifecycleLeaseError("plugin.lifecycle_cleanup_pending") }
    }
    private func invalidateOutputWindowsLocked(): Unit {
        match (startupOutputWindow) { case Some(ticket) => ticket.invalidate(); case None => () }
        match (refreshOutputWindow) { case Some(window) => window.outputTicket.invalidate(); case None => () }
    }
    private func finishRevocation(selected: ?ProcessChannel): Unit {
        // State is already Closing. Withdraw catalog authority before native
        // teardown; a throwing callback cannot prevent the remaining fanout.
        let _ = revocation.cancel()
        let _ = source.cancel()
        match (selected) { case Some(value) => try { let _ = value.abort() } catch (_: Exception) {}; case None => () }
        stdout.finish(error: Some(hostLifecycleLeaseFailure("plugin.lifecycle_closed")))
        stderr.finish(error: Some(hostLifecycleLeaseFailure("plugin.lifecycle_closed")))
        tryCleanup()
    }
    private func tryCleanup(): Unit {
        lock.lock()
        try {
            if (state != HostLifecycleLeaseState.Closing || opening || cleanupRunning) { return }
            cleanupRunning = true
            try {
                let graceful=gracefulCleanup
                cleanup = Some(spawn {
                    var observedClose:?Result<Unit>=try{
                        match((graceful,channel)){case(Some(duration),Some(actual))=>
                            match(actual.closeGracefully(prepared.operationPlan,duration)){case Result.Err(_)=>let _=actual.abort();case Result.Ok(_)=>()}
                            case _=>()}
                        Some(processes.closeChannelOperation(operationId))}
                        catch(_:Exception){None<Result<Unit>>}
                    var released=managedPhysicalCloseAccepted(observedClose)
                    if(released){
                        // Done/EOF are hints, never acknowledgement: join both
                        // original Host reader Futures before final release.
                        try{for(reader in [stdoutPump,stderrPump]){match(reader){case Some(value)=>value.get();case None=>()}}}
                        catch(_:Exception){released=false}
                        lock.lock();let readersAndScopesReturned=try{ioScopes.isEmpty()}finally{lock.unlock()}
                        if(released && readersAndScopesReturned){
                            monitorStop.store(true)
                            try{match(monitor){case Some(value)=>value.get();case None=>()}}
                            catch(_:Exception){released=false}
                        }
                    }
                    var registration: ?CancellationRegistration = None
                    lock.lock();var dependenciesReturned=try{
                        if(released && ioScopes.isEmpty()){
                            registration=startupCancellation;startupCancellation=None;true
                        }else{false}
                    }finally{lock.unlock()}
                    if(dependenciesReturned){
                        try{match(registration){case Some(value)=>value.dispose();case None=>()}
                            registration=None;source.close();revocation.close()}
                        catch(_:Exception){dependenciesReturned=false}
                    }
                    lock.lock()
                    try {
                        if(managedGrant.isSome()){
                            if(released){managedCloseAcknowledged=true}
                            retainManagedPhysicalCloseError(observedClose)
                        }
                        // The helper's actual error alias frame has ENDED.
                        // Drop this Task's original Result reference BEFORE
                        // publishing cleanupRunning=false or refunding. A
                        // racing next retry cannot outrun a paid old error.
                        observedClose=None<Result<Unit>>
                        cleanupRunning = false
                        if (released && dependenciesReturned && stdoutDone.load() && stderrDone.load() && ioScopes.isEmpty() &&
                            acknowledgeUnpublishedManagedScopeDebt() && match (managedGrant) { case Some(actual) => actual.releaseAfterPhysicalCleanup({ =>
                                heldContext = None; heldPrepared = None; heldGrant = None
                                // The original namespace close really ACKed.
                                // Clear the first physical error reference
                                // BEFORE this SAME grant refunds its payment.
                                managedPhysicalCloseError=None<AgentError> })
                                case None => true }) {
                            state = HostLifecycleLeaseState.Released; channel = None
                        }
                    } finally { lock.unlock() }
                })
            } catch (_: Exception) { cleanupRunning = false }
        } finally { lock.unlock() }
    }
    private func pump(channel: ProcessChannel, stream: ProcessChannelStream,
        queue: HostProcessChannelQueue, done: AtomicBool): Unit {
        try {
            while (!source.token.isCancelled()) {
                let value = match (channel.read(stream, 4096, 25)) {
                    case Result.Err(_) => let _ = revoke(); return
                    case Result.Ok(value) => value
                }
                let received = match (channel.receivedOutputBytes()) {
                    case Result.Err(_) => let _ = revoke(); return
                    case Result.Ok(value) => value
                }
                if (received < 0 || received > maxTotalOutput) { let _ = revoke(); return }
                if (!value.bytes.isEmpty()) {
                    var allowed = false
                    lock.lock()
                    try {
                        allowed = value.bytes.size <= maxTotalOutput - outputBytes &&
                            (state == HostLifecycleLeaseState.Active || state == HostLifecycleLeaseState.Pending ||
                                state == HostLifecycleLeaseState.Sealed || state == HostLifecycleLeaseState.Activating)
                        if (allowed) { outputBytes += value.bytes.size }
                    } finally { lock.unlock() }
                    lock.lock();let draining=try{state==HostLifecycleLeaseState.Closing && gracefulCleanup.isSome()}finally{lock.unlock()}
                    if(draining){continue}
                    if (!allowed || !queue.append(value.bytes)) { let _ = revoke(); return }
                }
                if (value.eof) { queue.finish(); return }
            }
        } catch (_: Exception) { let _ = revoke() }
        finally { done.store(true) }
    }
}

func hostLifecycleLeaseFailure(code: String): AgentError { hostResourceFailure(code) }
public func hostLifecycleLeaseError<T>(code: String): Result<T> { hostResourceError<T>(code) }

func hostLifecycleLeaseAssert(condition: Bool): Unit {
    if (!condition) { throw IllegalStateException("lifecycle canonical binding mismatch") }
}

public func hostLifecycleNonReplayableLaunchPlan(plan: NormalizedOperationPlan): Bool {
    plan.effectClass == OperationEffectClass.ExternalMutation &&
        plan.retryDisposition == OperationRetryDisposition.Never &&
        match (plan.replayDisposition) { case ReplayDisposition.NeverReplay => true; case _ => false }
}

func hostLifecyclePreparedHostSource(context: ToolInvocationContext, prepared: PreparedToolInvocation,
    grant: HostPluginLifecycleLaunchGrant, toolName!: String = HOST_PLUGIN_LIFECYCLE_TOOL,
    action!: HostServiceAction = HostServiceAction.Start, expectedArguments!: ?AgentValue = None): DirectToolCallRef {
    hostLifecycleLeaseAssert(context.trustedControl && prepared.source.kind == PreparedInvocationSourceKind.Direct &&
        prepared.source.runId.value == context.runId.value && prepared.source.sessionId.value == context.sessionId.value &&
        prepared.source.epoch == context.epoch && prepared.source.parentOperationId.isNone() &&
        prepared.source.requestKey == "" && prepared.authorization != PreparedAuthorization.ApprovalRequired &&
        prepared.call.name == toolName && prepared.operationPlan.toolName == toolName &&
        hostLifecycleNonReplayableLaunchPlan(prepared.operationPlan))
    let root = match (prepared.source.operationRoot) {
        case Some(OperationRootSource.Direct(value)) => value
        case _ => throw IllegalStateException("lifecycle requires a sealed Direct root")
    }
    let origin = match (root.origin) {
        case DirectCallOrigin.HostService(value) => value
        case _ => throw IllegalStateException("lifecycle requires a host service origin")
    }
    let plan = grant.launchPlan
    hostLifecycleLeaseAssert(root.operationId.value == prepared.operationId.value && root.runId.value == context.runId.value &&
        root.epoch == context.epoch && root.threadId.value == context.sessionId.value &&
        root.call.callId == prepared.call.callId && root.call.name == prepared.call.name &&
        context.sessionId.value != grant.targetThread.value && origin.action == action &&
        origin.serviceId == hostLifecycleText(plan, "service_id") && origin.ownerNamespace == hostLifecycleText(plan, "namespace") &&
        origin.packageDigest == hostLifecycleText(plan, "package_digest") &&
        origin.configurationDigest == hostLifecycleText(plan, "configuration_digest") &&
        origin.instanceIdentity == grant.instanceIdentity &&
        hostLifecycleText(plan, "thread_id") == grant.targetThread.value &&
        hostLifecycleText(plan, "permission_domain") == hostPluginInvocationAuthorityScope(context) &&
        canonicalize(Path(context.workspaceRoot)).toString() == hostLifecycleText(plan, "workspace_root") &&
        canonicalAgentValue(prepared.operationPlan.canonicalArguments) == canonicalAgentValue(match (expectedArguments) {
            case Some(value) => value; case None => plan }))
    let network = parseNetworkPolicy(plan.field("network").getOrThrow()).value().getOrThrow()
    hostLifecycleLeaseAssert(networkPoliciesEqual(network, prepared.operationPlan.networkPolicy))
    var processCapability = false
    var extensionCapability = false
    for (capability in prepared.operationPlan.requiredCapabilities) {
        hostLifecycleLeaseAssert(context.capabilities.allows(capability.kind, resource: capability.resource))
        if (capability.kind == CapabilityKind.ProcessSpawn) { processCapability = true }
        if (capability.kind == CapabilityKind.ExtensionInvoke) { extensionCapability = true }
    }
    hostLifecycleLeaseAssert(processCapability && extensionCapability)
    let resources = hostLifecycleResources(plan.field("resources").getOrThrow())
    let ceiling = context.budget.processLimits
    hostLifecycleLeaseAssert(hostLifecycleResourceFits(resources.maxOutputBytes, ceiling.maxOutputBytes) &&
        hostLifecycleResourceFits(resources.addressSpaceBytes, ceiling.addressSpaceBytes) &&
        hostLifecycleResourceFits(resources.fileSizeBytes, ceiling.fileSizeBytes) &&
        hostLifecycleResourceFits(resources.openFiles, ceiling.openFiles) &&
        hostLifecycleResourceFits(resources.processes, ceiling.processes) &&
        hostLifecycleResourceFits(resources.cpuSeconds, ceiling.cpuSeconds))
    let mode = hostLifecycleText(plan, "workspace_mode")
    if (mode == "workspace_readonly" || mode == "workspace_readwrite") {
        let expected = if (mode == "workspace_readwrite") { CapabilityKind.WorkspaceWrite } else { CapabilityKind.WorkspaceRead }
        var found = false
        for (capability in prepared.operationPlan.requiredCapabilities where capability.kind == expected &&
            (capability.resource == "" || capability.resource == hostLifecycleText(plan, "workspace_root"))) { found = true }
        hostLifecycleLeaseAssert(found)
    }
    for (resource in networkPolicyCapabilityResources(network)) {
        var found = false
        for (capability in prepared.operationPlan.requiredCapabilities where capability.kind == CapabilityKind.NetworkAccess &&
            (capability.resource == "" || capability.resource == resource)) { found = true }
        hostLifecycleLeaseAssert(found)
    }
    root
}

func hostLifecycleResourceFits(requested: Int64, ceiling: Int64): Bool {
    requested > 0 && (ceiling == 0 || requested <= ceiling)
}

// Read-only inspection of the same durable facts used by the execution store.
// No new audit, operation, receipt, scheduler or source is minted here.
func hostRequireLifecycleDurableOrigin(transaction: SqliteTransaction, prepared: PreparedToolInvocation,
    root: DirectToolCallRef, executing: Bool): Unit {
    let rows = transaction.query("SELECT o.run_id,o.tool_call_item_id,o.normalized_plan,o.state,s.state," +
        "r.thread_id,r.turn_id,r.epoch,r.state,COALESCE(t.active_turn_id,''),call.payload,call.provenance," +
        "initial.kind,initial.provenance,initial.id,e.normalized_plan,turn.state,COALESCE(turn.active_run_id,'') " +
        "FROM operations o JOIN operation_state_registers s ON s.operation_id=o.id " +
        "JOIN operation_effect_records e ON e.operation_id=o.id AND e.run_id=o.run_id AND e.tool_call_item_id=o.tool_call_item_id " +
        "JOIN runs r ON r.id=o.run_id JOIN threads t ON t.id=r.thread_id JOIN turns turn ON turn.id=r.turn_id " +
        "JOIN items call ON call.id=o.tool_call_item_id AND call.thread_id=r.thread_id AND call.turn_id=r.turn_id " +
        "JOIN items initial ON initial.id=turn.user_item_id AND initial.thread_id=r.thread_id AND initial.turn_id=r.turn_id " +
        "WHERE o.id=? AND call.kind='tool_call'", [SqlParameter.Text(prepared.operationId.value)])
    hostLifecycleLeaseAssert(rows.size == 1)
    let row = rows[0]
    hostLifecycleLeaseAssert(row.required(0) == root.runId.value && row.required(1) == root.canonicalItemId.value &&
        row.required(5) == root.threadId.value && row.required(6) == root.turnId.value &&
        row.required(7) == root.epoch.toString() && row.required(2) == row.required(15) &&
        storedOperationPlanMatches(row.required(2), prepared.operationPlan))
    if (executing) {
        hostLifecycleLeaseAssert(row.required(3) == "executing" && row.required(4) == "executing" &&
            row.required(8) == "running" && row.required(9) == root.turnId.value)
    } else {
        hostLifecycleLeaseAssert(row.required(3) == "committed" && row.required(4) == "committed" &&
            row.required(8) == "completed" && row.required(9) != root.turnId.value &&
            row.required(16) == "completed" && row.required(17) == "")
    }
    let call = decodeStoredProvenance(row.required(11))
    let initial = decodeStoredProvenance(row.required(13))
    hostLifecycleLeaseAssert(row.required(12) == "system_note" && initial.source == "host_service" &&
        initial.runId.isSome() && initial.runId.getOrThrow().value == root.runId.value && initial.operationId.isNone() &&
        call.source == "direct_tool" && call.runId.isSome() && call.runId.getOrThrow().value == root.runId.value &&
        call.operationId.isSome() && call.operationId.getOrThrow().value == root.operationId.value &&
        sameDirectCallOrigin(effectiveDirectCallOrigin(call), root.origin) &&
        sameDirectCallOrigin(effectiveDirectCallOrigin(initial), root.origin))
    match (decodeStoredThreadContent(row.required(10))) {
        case ThreadItemContent.ToolCall(id, name, arguments) => hostLifecycleLeaseAssert(id.value == root.call.callId &&
            name == root.call.name && canonicalAgentValue(arguments) == canonicalAgentValue(root.call.arguments))
        case _ => throw IllegalStateException("lifecycle canonical call missing")
    }
    hostLifecycleLeaseAssert(transaction.query("SELECT operation_id FROM derived_operation_admissions WHERE operation_id=?",
        [SqlParameter.Text(root.operationId.value)]).isEmpty() &&
        transaction.query("SELECT operation_id FROM decision_operations WHERE operation_id=?",
        [SqlParameter.Text(root.operationId.value)]).isEmpty() &&
        transaction.query("SELECT item_id FROM canonical_decision_items WHERE item_id=?",
        [SqlParameter.Text(root.canonicalItemId.value)]).isEmpty())
    let handoffs = transaction.query("SELECT id FROM audit_events WHERE kind='operation_execution_handoff' " +
        "AND operation_id=? AND run_id=? AND thread_id=?", [SqlParameter.Text(root.operationId.value),
        SqlParameter.Text(root.runId.value), SqlParameter.Text(root.threadId.value)])
    hostLifecycleLeaseAssert(handoffs.size == 1)
    let audits = transaction.query("SELECT payload FROM audit_events WHERE kind='operation_host_origin_bound' " +
        "AND operation_id=? AND run_id=? AND thread_id=?", [SqlParameter.Text(root.operationId.value),
        SqlParameter.Text(root.runId.value), SqlParameter.Text(root.threadId.value)])
    let evidence = encodeStoredValue(objectValue([
        ValueField("origin", directCallOriginValue(root.origin)), ValueField("thread_id", textValue(root.threadId.value)),
        ValueField("turn_id", textValue(root.turnId.value)), ValueField("run_id", textValue(root.runId.value)),
        ValueField("epoch", textValue(root.epoch.toString())), ValueField("initiator_item_id", textValue(row.required(14))),
        ValueField("tool_call_item_id", textValue(root.canonicalItemId.value)), ValueField("operation_id", textValue(root.operationId.value)),
        ValueField("call_digest", textValue(modelPolicySha256Text(row.required(10))))]))
    hostLifecycleLeaseAssert(audits.size == 1 && audits[0].required(0) == evidence)
}

func hostValidateLifecycleLaunchSource(database: SqliteDatabase, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, grant: HostPluginLifecycleLaunchGrant): Result<Unit> {
    match (context.cancellation.check()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    match (grant.stillCurrent()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
    try {
        let root = hostLifecyclePreparedHostSource(context, prepared, grant)
        database.transaction { transaction => hostRequireLifecycleDurableOrigin(transaction, prepared, root, true) }
        Result.Ok(())
    } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_source_invalid") }
}

public func hostValidateLifecycleStartupReceipt(database: SqliteDatabase, context: ToolInvocationContext,
    prepared: PreparedToolInvocation, grant: HostPluginLifecycleLaunchGrant, summaryText: String): Result<Unit> {
    try {
        let root = hostLifecyclePreparedHostSource(context, prepared, grant)
        let summary = canonicalAgentValue(parseUnifiedJson(summaryText, maxBytes: hostManagedServiceSummaryLimit(grant.launchPlan, 65536)))
        database.transaction { transaction =>
            hostRequireLifecycleDurableOrigin(transaction, prepared, root, false)
            let receipts = transaction.query("SELECT id,outcome,detail FROM operation_receipts WHERE operation_id=?",
                [SqlParameter.Text(root.operationId.value)])
            hostLifecycleLeaseAssert(receipts.size == 1 && receipts[0].required(1) == "completed" &&
                canonicalAgentValue(decodeStoredValue(receipts[0].required(2))) == summary)
            let results = transaction.query("SELECT payload FROM items WHERE thread_id=? AND turn_id=? AND kind='tool_result'",
                [SqlParameter.Text(root.threadId.value), SqlParameter.Text(root.turnId.value)])
            var matches: Int64 = 0
            for (row in results) {
                match (decodeStoredThreadContent(row.required(0))) {
                    case ThreadItemContent.ToolResult(callId, operationId, receiptId, output, isError) =>
                        if (operationId.value == root.operationId.value) {
                            hostLifecycleLeaseAssert(!isError && callId.value == root.call.callId && receiptId == receipts[0].required(0) &&
                                canonicalAgentValue(output) == summary)
                            matches += 1
                        }
                    case _ => ()
                }
            }
            hostLifecycleLeaseAssert(matches == 1)
        }
        Result.Ok(())
    } catch (_: Exception) { hostLifecycleLeaseError("plugin.lifecycle_startup_uncommitted") }
}

// The caller retains one writer lock, canonical child and full-byte reservation.
// Raw channel writes remain bounded to 64 KiB; a later chunk never receives a
// new authorization or a refunded budget, and partial failure is not replayable.
public func hostLifecycleWritePreparedChunks(bytes: Array<Byte>, write: (Array<Byte>) -> Result<Unit>,
    validate: () -> Result<Unit>): Result<Unit> {
    var offset: Int64 = 0
    while (offset < bytes.size) {
        match (validate()) { case Result.Err(error) => return Result.Err(error); case Result.Ok(_) => () }
        let end = if (bytes.size - offset > 65536) { offset + 65536 } else { bytes.size }
        let result = try { write(bytes[offset..end]) } catch (_: Exception) { hostLifecycleIoUnknown<Unit>() }
        if (result.isError()) { return hostLifecycleIoUnknown() }
        offset = end
    }
    Result.Ok(())
}

public func hostLifecycleIoCancelled<T>(): Result<T> { hostResourceCancelled<T>() }
func hostLifecycleIoUnknown<T>(): Result<T> {
    Result.Err(AgentError(AgentErrorKind.RecoveryRequired, "plugin.lifecycle_write_unknown",
        "service channel write has no verified completion and must not be replayed",
        retryable: false, fallbackAllowed: false))
}
